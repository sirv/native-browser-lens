import { api, isFirefox } from './browser.js';
import { originPattern } from './permissions.js';
import { WebRequestEvidence, documentToken } from './portable.js';
import { Collector } from './collector.js';
import { AttachmentPolicy } from './lifecycle.js';
import { bodyEvidence, sanitize, sanitizeURL } from './sanitize.js';
import { applicationSnapshot, installActionProbe, pageSnapshot, spatialSnapshot } from './probe.js';
import { bindSpatialCapture, type SpatialSnapshot } from './spatial.js';
import type { ProjectProfile, WireMessage } from './types.js';

const HOST = 'studio.sirv.native_browser_lens';
const collector = new Collector();
const policy = new AttachmentPolicy();
let projects: ProjectProfile[] = [];
let paused = false;
let nativePort: chrome.runtime.Port | undefined;
let nativeError = 'Native application is not connected';
let clientId = '';
const attached = new Set<number>();
const attaching = new Set<number>();
const expectedDetach = new Set<number>();
const devtoolsPorts = new Map<number, chrome.runtime.Port>();
const inflight = new Map<string, { documentId: string; url: string; mimeType: string; size?: number }>();
let persistTimer: ReturnType<typeof setTimeout> | undefined;
let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
let reconnectDelay = 1000;
const captureQueue = new Map<number, Promise<void>>();
const tabQueue = new Map<number, Promise<void>>();
const debuggerAvailable = typeof api.debugger?.attach === 'function';
const documentEpoch = new Map<number, number>();
const portable = new WebRequestEvidence(collector, record, gap, () => paused);
if (!debuggerAvailable) portable.listen(api.webRequest);

function errorText(error: unknown) { return error instanceof Error ? error.message : String(error); }
function safe(data: unknown) { return sanitize(data) as Record<string, unknown>; }
function post(kind: string, payload: Record<string, unknown>): boolean {
  if (!nativePort) return false;
  const message: WireMessage = { version: 1, kind, id: crypto.randomUUID(), payload };
  if (new TextEncoder().encode(JSON.stringify(message)).length > 500 * 1024) { console.error('Native message omitted: exceeds 500 KiB', kind); return false; }
  try { nativePort.postMessage(message); return true; } catch { return false; }
}
function sendStatus() {
  post('status', { browser: isFirefox ? 'firefox' : 'chromium', extensionVersion: api.runtime.getManifest().version, tabs: collector.statuses().map(s => ({ ...s, url: sanitizeURL(s.url) })) });
  for (const s of collector.statuses()) {
    const on = ['deep', 'devtools', 'limited'].includes(s.mode);
    void api.action.setBadgeText({ tabId: s.tabId, text: on ? 'ON' : s.mode === 'paused' ? 'Ⅱ' : '!' }).catch(() => {});
    void api.action.setBadgeBackgroundColor({ tabId: s.tabId, color: on ? '#26704b' : '#946d25' }).catch(() => {});
    void api.action.setTitle({ tabId: s.tabId, title: `Native Browser Lens · ${s.mode}${s.reason ? ` · ${s.reason}` : ''}` }).catch(() => {});
  }
}
function persist() {
  if (persistTimer) return;
  persistTimer = setTimeout(() => {
    persistTimer = undefined;
    void api.storage.session.set({ evidenceCheckpoint: collector.serialize(), blockedTabs: [...policy.blocked] }).catch(e => console.warn('Evidence checkpoint unavailable', errorText(e)));
  }, 1500);
}
function record(tabId: number, kind: string, data: Record<string, unknown>, documentId?: string) {
  if (paused) return;
  collector.record(tabId, kind, safe(data), documentId); persist();
}
function gap(tabId: number, channel: string, reason: string) { collector.gap(tabId, channel, reason); persist(); }
function connectNative() {
  if (nativePort) return;
  try {
    const port = api.runtime.connectNative(HOST); nativePort = port;
    port.onMessage.addListener((m: WireMessage) => {
      if (m?.version !== 1 || !m.payload || typeof m.kind !== 'string') return;
      nativeError = ''; reconnectDelay = 1000;
      void command(m).catch(e => post('error', { message: errorText(e), observationId: m.payload.observationId, captureId: m.payload.captureId }));
    });
    port.onDisconnect.addListener(() => {
      nativeError = api.runtime.lastError?.message || 'Native host disconnected'; nativePort = undefined;
      if (!reconnectTimer) reconnectTimer = setTimeout(() => { reconnectTimer = undefined; connectNative(); }, reconnectDelay);
      reconnectDelay = Math.min(60000, reconnectDelay * 2);
    });
    post('hello', { clientId }); sendStatus();
  } catch (e) { nativeError = errorText(e); }
}
function validProjects(value: unknown): ProjectProfile[] {
  if (!Array.isArray(value)) throw new Error('Projects must be an array');
  return value.slice(0, 32).filter((p): p is ProjectProfile => !!p && typeof p.id === 'string' && typeof p.name === 'string' && Array.isArray(p.origins) && p.origins.every((o: unknown) => typeof o === 'string' && /^https?:\/\//.test(o) && new URL(o).origin === o) && typeof p.enabled === 'boolean');
}
async function command(message: WireMessage) {
  const p = message.payload;
  switch (message.kind) {
    case 'configure':
      projects = validProjects(p.projects); collector.configure(projects);
      await api.storage.local.set({ projects }); await refreshTabs(); break;
    case 'openOptions':
      await api.runtime.openOptionsPage(); break;
    case 'capture':
      await enqueueCapture(Number(p.tabId), String(p.observationId), String(p.captureId)); break;
    case 'snapshot':
      await enqueueCapture(Number(p.tabId), String(p.observationId), crypto.randomUUID(), true); break;
    case 'pause':
      paused = p.paused === true; if (paused) portable.clear(); await api.storage.local.set({ paused }); await refreshTabs(); break;
    case 'resumeTab':
      policy.resume(Number(p.tabId)); await synchronizeTab(Number(p.tabId)); persist(); break;
  }
  sendStatus();
}
async function grantsFor(url: string) {
  try { return await api.permissions.contains({ origins: [originPattern(new URL(url).origin, isFirefox)] }); } catch { return false; }
}
async function documentFor(tabId: number) {
  const frame = await api.webNavigation.getFrame({ tabId, frameId: 0 });
  if (frame?.documentId) return frame.documentId;
  const result = await api.scripting.executeScript({ target: { tabId, frameIds: [0] }, func: documentToken });
  const token = result.find(x => x.frameId === 0)?.result;
  if (!token) throw new Error('Main-document identity is unavailable');
  return token + ':' + (documentEpoch.get(tabId) ?? 0);
}
function frameDocument(tabId: number, result: chrome.scripting.InjectionResult<any>) {
  return result.documentId ?? (result.result?.documentToken ? result.result.documentToken + ':' + (documentEpoch.get(tabId) ?? 0) : undefined);
}
function synchronizeTab(tabId: number): Promise<void> {
  const queued = (tabQueue.get(tabId) ?? Promise.resolve()).catch(() => {}).then(() => synchronizeTabNow(tabId));
  tabQueue.set(tabId, queued);
  void queued.finally(() => { if (tabQueue.get(tabId) === queued) tabQueue.delete(tabId); }).catch(() => {});
  return queued;
}
async function synchronizeTabNow(tabId: number) {
  let tab: chrome.tabs.Tab;
  try { tab = await api.tabs.get(tabId); } catch { collector.remove(tabId); return; }
  const url = tab.url ?? '';
  const project = collector.projectFor(url);
  if (!project || tab.incognito) {
    portable.clear(tabId); await detach(tabId); collector.remove(tabId); await api.action.setBadgeText({ tabId, text: '' }); sendStatus(); return;
  }
  if (!collector.status(tabId) && collector.statuses().length >= 16) { post('error', { message: 'Collector tab limit (16) reached; close or pause an enabled project tab' }); return; }
  const granted = await grantsFor(url);
  const doc = paused || !granted ? collector.status(tabId)?.documentId ?? crypto.randomUUID() : await documentFor(tabId);
  collector.track({ id: tabId, windowId: tab.windowId, url, title: tab.title, active: tab.active }, doc);
  if (paused) { await detach(tabId); collector.mode(tabId, 'paused', 'Paused by user'); sendStatus(); return; }
  if (!granted) { portable.clear(tabId); await detach(tabId); collector.mode(tabId, 'unavailable', 'Grant this project origin in extension settings'); sendStatus(); return; }
  if (policy.devtools.has(tabId)) {
    await detach(tabId); collector.mode(tabId, 'devtools', 'DevTools network mode');
    devtoolsPorts.get(tabId)?.postMessage({ kind: 'enabled', documentId: doc, projectOrigin: new URL(url).origin });
    await probeActions(tabId); sendStatus(); return;
  }
  if (!debuggerAvailable) {
    collector.mode(tabId, 'limited', 'Firefox webRequest and page probes; debugger channels unavailable');
    gap(tabId, 'history', 'Evidence starts when this document is armed; earlier requests are unavailable');
    gap(tabId, 'debugger', 'Browser debugger API unavailable: console, worker exceptions, child-frame probes, response bodies and detailed cache provenance are not collected. DevTools can supply available response bodies.');
    gap(tabId, 'network', 'WebRequest covers granted resource origins only; main-document navigation and ungranted third-party requests may be missing. Request payloads and request headers are not collected.');
    await probeActions(tabId); sendStatus(); return;
  }
  if (policy.blocked.has(tabId)) { collector.mode(tabId, 'unavailable', 'Debugger detached; choose Resume tab to reattach'); sendStatus(); return; }
  if (attached.has(tabId)) { collector.mode(tabId, 'deep'); await probeActions(tabId); sendStatus(); return; }
  if (attaching.has(tabId)) return;
  attaching.add(tabId); collector.mode(tabId, 'handover', 'Connecting browser evidence'); sendStatus();
  try {
    await api.debugger.attach({ tabId }, '1.3'); attached.add(tabId);
    if (policy.devtools.has(tabId) || paused || !collector.projectFor((await api.tabs.get(tabId)).url ?? '')) { await detach(tabId); return; }
    await enableDomains({ tabId });
    collector.mode(tabId, 'deep'); gap(tabId, 'history', 'Evidence starts when this tab is armed; earlier requests are unavailable');
    await probeActions(tabId);
  } catch (e) {
    if (!policy.devtools.has(tabId)) { policy.detached(tabId); collector.mode(tabId, 'unavailable', errorText(e)); }
    gap(tabId, 'debugger', errorText(e));
  } finally { attaching.delete(tabId); sendStatus(); persist(); }
}
async function detach(tabId: number) {
  devtoolsPorts.get(tabId)?.postMessage({ kind: 'disabled' });
  if (!attached.has(tabId)) return;
  expectedDetach.add(tabId); attached.delete(tabId);
  try { await api.debugger.detach({ tabId }); } catch { expectedDetach.delete(tabId); }
}
async function enableDomains(source: chrome.debugger.DebuggerSession) {
  const tabId = source.tabId!;
  for (const [method, params] of [
    ['Network.enable', { maxTotalBufferSize: 1048576, maxResourceBufferSize: 65536, maxPostDataSize: 0 }],
    ['Runtime.enable', {}], ['Page.enable', {}], ['Log.enable', {}],
    ['Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true, filter: [{ type: 'iframe', exclude: false }, { type: 'worker', exclude: false }, { exclude: true }] }]
  ] as const) {
    try { await api.debugger.sendCommand(source, method, params); } catch (e) { gap(tabId, method, `Channel unavailable: ${errorText(e)}`); }
  }
}
async function probeActions(tabId: number) {
  try { await api.scripting.executeScript({ target: { tabId, allFrames: !isFirefox }, func: installActionProbe, args: [collector.status(tabId)?.documentId] }); }
  catch (e) { gap(tabId, 'dom-actions', `Frames without host grants or restricted documents omitted: ${errorText(e)}`); }
}
async function refreshTabs() {
  const tabs = await api.tabs.query({}); const ids = new Set(tabs.flatMap(t => t.id === undefined ? [] : [t.id]));
  for (const s of collector.statuses()) if (!ids.has(s.tabId)) { collector.remove(s.tabId); policy.remove(s.tabId); }
  await Promise.allSettled(tabs.filter(t => t.id !== undefined).map(t => synchronizeTab(t.id!))); sendStatus(); persist();
}

api.debugger?.onEvent.addListener((source, method, params) => { void debuggerEvent(source, method, params as Record<string, any> ?? {}).catch(e => { if (source.tabId) gap(source.tabId, method, errorText(e)); }); });
async function debuggerEvent(source: chrome.debugger.DebuggerSession, method: string, p: Record<string, any>) {
  const tabId = source.tabId; if (tabId === undefined || paused || !attached.has(tabId)) return;
  const status = collector.status(tabId); if (!status || !collector.projectFor(status.url)) return;
  const sessionId = source.sessionId;
  const key = `${tabId}:${sessionId ?? 'main'}:${p.requestId ?? ''}`;
  const scope = { targetSession: sessionId ?? 'main', frameId: p.frameId };
  switch (method) {
    case 'Target.attachedToTarget': {
      const child = { tabId, sessionId: p.sessionId };
      record(tabId, 'frame', { target: p.targetInfo, targetSession: p.sessionId });
      await enableDomains(child); break;
    }
    case 'Target.detachedFromTarget': record(tabId, 'coverage', { ...scope, channel: 'child-target', reason: 'Child target detached' }); break;
    case 'Network.requestWillBeSent': {
      const request = p.request ?? {};
      if (inflight.size >= 1024) { inflight.delete(inflight.keys().next().value!); gap(tabId, 'network', 'Request correlation limit reached; oldest request omitted'); }
      inflight.set(key, { documentId: status.documentId, url: request.url ?? '', mimeType: '' });
      record(tabId, 'request', { ...scope, requestId: p.requestId, monotonicTime: p.timestamp, method: request.method, url: request.url, headers: request.headers, initiator: p.initiator, resourceType: p.type, redirectResponse: p.redirectResponse, postDataOmission: request.hasPostData ? 'Request body intentionally omitted' : undefined }); break;
    }
    case 'Network.responseReceived': {
      const response = p.response ?? {}; const request = inflight.get(key);
      if (request) { request.mimeType = response.mimeType ?? ''; request.size = Number(response.encodedDataLength); }
      record(tabId, 'response', { ...scope, requestId: p.requestId, monotonicTime: p.timestamp, url: response.url, status: response.status, statusText: response.statusText, mimeType: response.mimeType, headers: response.headers, protocol: response.protocol, fromDiskCache: response.fromDiskCache ?? false, fromServiceWorker: response.fromServiceWorker ?? false, fromPrefetchCache: response.fromPrefetchCache ?? false, timing: response.timing, remoteIPAddress: response.remoteIPAddress }, request?.documentId); break;
    }
    case 'Network.requestServedFromCache': record(tabId, 'cache', { ...scope, requestId: p.requestId, source: 'browser-http-cache' }, inflight.get(key)?.documentId); break;
    case 'Network.loadingFailed': { const request = inflight.get(key); record(tabId, 'network-failure', { ...scope, requestId: p.requestId, monotonicTime: p.timestamp, errorText: p.errorText, canceled: p.canceled, blockedReason: p.blockedReason, corsErrorStatus: p.corsErrorStatus }, request?.documentId); inflight.delete(key); break; }
    case 'Network.loadingFinished': {
      const request = inflight.get(key); inflight.delete(key); if (!request || request.documentId !== status.documentId) break;
      record(tabId, 'network-complete', { ...scope, requestId: p.requestId, monotonicTime: p.timestamp, encodedDataLength: p.encodedDataLength }, request.documentId);
      if (p.encodedDataLength > 65536) { record(tabId, 'response-body', { ...scope, requestId: p.requestId, omission: 'Encoded body exceeds 64 KiB retrieval limit' }, request.documentId); break; }
      const eligibility = bodyEvidence('', request.mimeType, request.url, status.url);
      if (eligibility.omission) { record(tabId, 'response-body', { ...scope, requestId: p.requestId, ...eligibility }, request.documentId); break; }
      try {
        const body = await api.debugger.sendCommand(source, 'Network.getResponseBody', { requestId: p.requestId }) as { body: string; base64Encoded: boolean };
        const evidence = body.base64Encoded ? { omission: 'Base64 body omitted; request metadata retained' } : bodyEvidence(body.body, request.mimeType, request.url, status.url);
        record(tabId, 'response-body', { ...scope, requestId: p.requestId, ...evidence }, request.documentId);
      } catch (e) { record(tabId, 'response-body', { ...scope, requestId: p.requestId, omission: errorText(e) }, request.documentId); }
      break;
    }
    case 'Runtime.consoleAPICalled': record(tabId, 'console', { ...scope, type: p.type, args: (p.args ?? []).slice(0, 12).map((x: any) => ({ type: x.type, value: x.value, description: x.description, preview: x.preview })), stackTrace: p.stackTrace }); break;
    case 'Runtime.exceptionThrown': record(tabId, 'exception', { ...scope, details: p.exceptionDetails }); break;
    case 'Log.entryAdded': record(tabId, 'console', { ...scope, entry: p.entry }); break;
    case 'Runtime.executionContextCreated': record(tabId, 'frame', { ...scope, executionContext: { id: p.context?.id, origin: p.context?.origin, name: p.context?.name, auxData: p.context?.auxData } }); break;
  }
}
api.debugger?.onDetach.addListener((source, reason) => {
  const tabId = source.tabId; if (tabId === undefined) return;
  attached.delete(tabId);
  if (expectedDetach.delete(tabId)) return;
  policy.detached(tabId);
  collector.mode(tabId, policy.devtools.has(tabId) ? 'devtools' : 'handover', 'Debugger detached');
  gap(tabId, 'handover', `Debugger detached (${reason}); DevTools may provide reduced coverage`);
  setTimeout(() => { if (!policy.devtools.has(tabId) && policy.blocked.has(tabId)) { collector.mode(tabId, 'unavailable', 'Debugger detached; choose Resume tab to reattach'); sendStatus(); persist(); } }, 1200);
  sendStatus();
});

function enqueueCapture(tabId: number, observationId: string, captureId: string, snapshotOnly = false, extensionInitiated = false) {
  const queued = (captureQueue.get(tabId) ?? Promise.resolve()).catch(() => {}).then(() => capture(tabId, observationId, captureId, snapshotOnly, extensionInitiated)).catch(e => { if (extensionInitiated) post('error', { observationId, captureId, message: errorText(e) }); throw e; });
  captureQueue.set(tabId, queued);
  void queued.finally(() => { if (captureQueue.get(tabId) === queued) captureQueue.delete(tabId); }).catch(() => {});
  return queued;
}
async function capture(tabId: number, observationId: string, captureId: string, snapshotOnly = false, extensionInitiated = false) {
  if (!nativePort) throw new Error('Open the native application and connect the host before capturing');
  if (!observationId || !captureId || observationId === 'undefined' || captureId === 'undefined') throw new Error('Observation and capture identities are required');
  const status = collector.status(tabId); if (!status) throw new Error('Tab is not enabled for a configured project');
  if (paused || !(await grantsFor(status.url))) throw new Error('Capture is paused or this origin has not been granted');
  const initialDoc = await documentFor(tabId);
  if (initialDoc !== status.documentId) { await synchronizeTab(tabId); throw new Error('Document changed before capture; capture the current page again'); }
  const frozen = collector.capture(tabId);
  frozen.identity.url = sanitizeURL(frozen.identity.url);
  if (!post('capture-started', { observationId, captureId, initiatedBy: extensionInitiated ? 'extension' : 'native', identity: frozen.identity, tab: { ...status, url: sanitizeURL(status.url) } })) throw new Error('Native host disconnected before capture started');
  const readSpatial = async (): Promise<SpatialSnapshot | undefined> => {
    try { const results = await api.scripting.executeScript({ target: { tabId, frameIds: [0] }, func: spatialSnapshot }); const main = results.find(x => x.frameId === 0); const documentId = main && frameDocument(tabId, main); return main?.result && documentId ? { ...main.result, documentId } : undefined; } catch { return undefined; }
  };
  const beforePixels = await readSpatial();
  let screenshot: string | undefined;
  let screenshotOmission: string | undefined;
  // Freeze pixels before any UI activation. capture-started creates only pending metadata and may start synchronized native fallback.
  if (!snapshotOnly && attached.has(tabId)) {
    try { screenshot = (await api.debugger.sendCommand({ tabId }, 'Page.captureScreenshot', { format: 'png', fromSurface: true, captureBeyondViewport: false }) as { data: string }).data; }
    catch (e) { screenshotOmission = `Browser screenshot unavailable: ${errorText(e)}`; }
  } else if (!snapshotOnly) {
    try {
      const tab = await api.tabs.get(tabId);
      const active = await api.tabs.query({ active: true, windowId: tab.windowId });
      if (active[0]?.id !== tabId) throw new Error('Target tab is not the active tab in its window');
      const dataURL = await api.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
      const stillActive = await api.tabs.query({ active: true, windowId: tab.windowId });
      if (stillActive[0]?.id !== tabId) throw new Error('Active tab changed while capturing');
      screenshot = dataURL.replace(/^data:image\/png;base64,/, '');
    } catch (e) { screenshotOmission = `Native window capture required: ${errorText(e)}`; }
  } else screenshotOmission = 'Snapshot requested without screenshot';
  const afterPixels = await readSpatial();
  const spatial = bindSpatialCapture(beforePixels, afterPixels, { tabId, documentId: initialDoc, captureId });
  const context: Record<string, unknown> = { captureId, documentId: initialDoc, coordinateSpace: 'browser-viewport', capturedAt: frozen.identity.capturedAt };
  try {
    const results = await api.scripting.executeScript({ target: { tabId, allFrames: !isFirefox }, func: pageSnapshot });
    const main = results.find(x => x.frameId === 0 && frameDocument(tabId, x) === initialDoc);
    if (main?.result) {
      Object.assign(context, safe(main.result));
      const buildId = main.result.buildId; if (buildId) frozen.identity.buildId = String(buildId);
      for (const g of main.result.gaps) frozen.gaps.push({ ...g, startedAt: frozen.identity.capturedAt });
    } else frozen.gaps.push({ channel: 'dom', reason: 'No main-document snapshot matching capture identity', startedAt: Date.now() });
    context.childFrames = results.filter(x => x.frameId !== 0).slice(0, 12).map(x => ({ frameId: x.frameId, documentId: x.documentId, context: safe(x.result) }));
    if (JSON.stringify(context).length > 64000) { delete context.childFrames; frozen.gaps.push({ channel: 'frames', reason: 'Child frame snapshots exceed context budget', startedAt: Date.now() }); }
    frozen.gaps.push({ channel: 'frames', reason: 'Restricted or ungranted frames are not readable; listed frame URLs do not prove frame contents were captured', startedAt: Date.now() });
  } catch (e) { frozen.gaps.push({ channel: 'dom-storage', reason: errorText(e), startedAt: Date.now() }); }
  try {
    const results = await api.scripting.executeScript({ target: { tabId, frameIds: [0] }, world: 'MAIN', func: applicationSnapshot });
    const result = results.find(x => x.frameId === 0 && (x.documentId === initialDoc || (!debuggerAvailable && !x.documentId)))?.result;
    if (result?.application) {
      context.application = safe(result.application);
      const build = result.application.build as { commit?: unknown; sourceState?: unknown } | undefined;
      if (build?.sourceState === 'working-tree') { context.sourceBuildVerified = false; frozen.gaps.push({ channel: 'source-build', reason: 'Diagnostic adapter identifies an unsealed working tree; commit label is not exact deployed source proof', startedAt: Date.now() }); }
      if (typeof build?.commit === 'string') frozen.identity.buildId = build.commit;
      frozen.gaps = frozen.gaps.filter(g => g.channel !== 'application-cache');
      if (Array.isArray(context.gaps)) context.gaps = context.gaps.filter((g: any) => g.channel !== 'application-cache');
    } else if (result?.omission) frozen.gaps.push({ channel: 'application-cache', reason: result.omission, startedAt: Date.now() });
  } catch (e) { frozen.gaps.push({ channel: 'application-cache', reason: `Project adapter unavailable: ${errorText(e)}`, startedAt: Date.now() }); }
  if (spatial.viewport) context.viewport = spatial.viewport;
  context.elements = screenshot ? spatial.elements.map(element => safe(element)) : [];
  context.spatialCoverage = beforePixels?.coverage;
  context.spatialBinding = screenshot && spatial.elements.length ? 'stable-across-capture' : 'unresolved';
  if (spatial.omission || !screenshot) frozen.gaps.push({ channel: 'spatial-binding', reason: spatial.omission || 'Browser screenshot unavailable; DOM references are not bound to a later native image', startedAt: Date.now() });
  if (new TextEncoder().encode(JSON.stringify(context)).length > 80 * 1024) { delete context.childFrames; delete context.storage; frozen.gaps.push({ channel: 'snapshot-budget', reason: 'Storage and child frame snapshots omitted by 80 KiB aggregate context budget', startedAt: Date.now() }); }
  if (await documentFor(tabId) !== initialDoc || collector.status(tabId)?.documentId !== initialDoc) throw new Error('Document changed during capture; image and DOM association discarded. Capture again.');
  frozen.identity.url = sanitizeURL(frozen.identity.url);
  if (screenshot && screenshot.length > 32 * 1024 * 1024) { screenshot = undefined; screenshotOmission = 'Screenshot exceeds 32 MiB base64 limit'; }
  if (screenshot) {
    const partSize = 192 * 1024; const total = Math.ceil(screenshot.length / partSize);
    for (let index = 0; index < total; index++) if (!post('artifact', { observationId, captureId, index, total, mimeType: 'image/png', data: screenshot.slice(index * partSize, (index + 1) * partSize) })) throw new Error('Native host disconnected while transferring screenshot; capture again');
  }
  if (!post('capture', { observationId, captureId, ...frozen, context, ...(screenshotOmission ? { screenshotOmission } : {}) })) throw new Error('Native host disconnected while saving capture');
}

api.runtime.onConnect.addListener(port => {
  if (port.name !== 'lens-devtools') return;
  let tabId: number | undefined;
  port.onMessage.addListener(message => {
    if (message.kind === 'open' && Number.isInteger(message.tabId)) {
      tabId = message.tabId; policy.openDevtools(tabId!); devtoolsPorts.set(tabId!, port);
      gap(tabId!, 'devtools', 'DevTools mode lacks complete console, exception, worker, and cache-provenance coverage');
      void synchronizeTab(tabId!).catch(() => {});
    } else if (message.kind === 'network' && tabId !== undefined && policy.devtools.has(tabId) && !paused) {
      const status = collector.status(tabId);
      if (!status || status.mode !== 'devtools' || status.documentId !== message.documentId) return;
      record(tabId, 'devtools-network', message.data, message.documentId);
    }
  });
  port.onDisconnect.addListener(() => {
    if (tabId === undefined || devtoolsPorts.get(tabId) !== port) return;
    devtoolsPorts.delete(tabId); policy.closeDevtools(tabId);
    gap(tabId, 'handover', 'DevTools closed; browser collector reconnecting');
    void synchronizeTab(tabId).catch(() => {});
  });
});
api.runtime.onMessage.addListener((message, sender, respond) => {
  if (message?.kind === 'pageAction') {
    const tabId = sender.tab?.id; const status = tabId === undefined ? undefined : collector.status(tabId);
    if (tabId !== undefined && status && ['deep','devtools','limited'].includes(status.mode) && ((sender.documentId && (sender.frameId !== 0 || sender.documentId === status.documentId)) || (!debuggerAvailable && message.documentId === status.documentId))) {
      const expected = status.documentId;
      void documentFor(tabId).then(current => { if (current === expected && collector.status(tabId)?.documentId === expected) record(tabId, 'action', { element: message.element, frameId: sender.frameId, frameDocumentId: sender.documentId, source: 'isolated-page-probe' }, expected); }).catch(() => {});
    }
    return false;
  }
  // Options-page commands must originate from extension UI, never a content script.
  if (sender.id !== api.runtime.id || !sender.url?.startsWith(api.runtime.getURL(''))) return false;
  const run = async () => {
    if (message.kind === 'getState') return { projects, paused, tabs: collector.statuses(), nativeError, extensionId: api.runtime.id, host: HOST };
    if (message.kind === 'configure') { await command({ version: 1, id: crypto.randomUUID(), kind: 'configure', payload: { projects: message.projects } }); return { ok: true }; }
    if (message.kind === 'refresh') { await refreshTabs(); return { ok: true }; }
    if (message.kind === 'reconnect') { connectNative(); return { ok: true }; }
    if (message.kind === 'pause' || message.kind === 'resumeTab') { await command({ version: 1, id: crypto.randomUUID(), kind: message.kind, payload: message }); return { ok: true }; }
    if (message.kind === 'capture') { const observationId = crypto.randomUUID(), captureId = crypto.randomUUID(); await enqueueCapture(Number(message.tabId), observationId, captureId, false, true); return { ok: true, observationId, captureId }; }
    return { error: 'Unknown command' };
  };
  void run().then(respond, e => respond({ error: errorText(e) })); return true;
});
api.tabs.onUpdated.addListener((tabId, change) => {
  if (change.title !== undefined) { const status = collector.status(tabId); if (status) status.title = change.title; sendStatus(); persist(); }
  if (change.title !== undefined || change.url || change.status === 'complete') void synchronizeTab(tabId).catch(() => {});
});
api.tabs.onActivated.addListener(info => { collector.selectTab(info.tabId, info.windowId); sendStatus(); persist(); void refreshTabs(); });
api.windows.onFocusChanged.addListener(windowId => { collector.focusWindow(windowId === api.windows.WINDOW_ID_NONE ? undefined : windowId); sendStatus(); persist(); });
api.tabs.onRemoved.addListener(tabId => { portable.clear(tabId); documentEpoch.delete(tabId); collector.remove(tabId); attached.delete(tabId); policy.remove(tabId); for (const key of inflight.keys()) if (key.startsWith(`${tabId}:`)) inflight.delete(key); sendStatus(); persist(); });
api.webNavigation.onCommitted.addListener(details => {
  if (details.frameId === 0) {
    portable.clear(details.tabId);
    if (!collector.projectFor(details.url)) { documentEpoch.delete(details.tabId); collector.remove(details.tabId); }
    else { documentEpoch.set(details.tabId, (documentEpoch.get(details.tabId) ?? 0) + 1); collector.navigate(details.tabId, details.documentId ?? crypto.randomUUID(), details.url); }
    sendStatus(); persist();
    void synchronizeTab(details.tabId).catch(() => {});
  }
  else if (collector.status(details.tabId)) void probeActions(details.tabId);
});
api.permissions.onAdded.addListener(() => { void refreshTabs(); });
api.permissions.onRemoved.addListener(() => { void refreshTabs(); });
api.action.onClicked.addListener(tab => {
  if (tab.id === undefined || !collector.status(tab.id) || nativeError) { void api.runtime.openOptionsPage(); return; }
  void enqueueCapture(tab.id, crypto.randomUUID(), crypto.randomUUID(), false, true).catch(e => { post('error', { message: errorText(e) }); void api.runtime.openOptionsPage(); });
});
api.commands.onCommand.addListener(command => {
  if (command !== 'capture-observation') return;
  void api.tabs.query({ active: true, lastFocusedWindow: true }).then(async tabs => {
    const tab = tabs[0]; if (!tab?.id || !collector.status(tab.id)) { await api.runtime.openOptionsPage(); return; }
    await enqueueCapture(tab.id, crypto.randomUUID(), crypto.randomUUID(), false, true);
  }).catch(e => post('error', { message: errorText(e) }));
});
api.alarms.onAlarm.addListener(alarm => { if (alarm.name === 'lens-maintenance') { connectNative(); persist(); sendStatus(); } });
async function start() {
  const stored = await api.storage.local.get(['projects', 'paused', 'clientId']);
  projects = validProjects(stored.projects ?? []); paused = stored.paused === true; clientId = typeof stored.clientId === 'string' ? stored.clientId : crypto.randomUUID();
  await api.storage.local.set({ clientId }); collector.configure(projects);
  const session = await api.storage.session.get(['evidenceCheckpoint', 'blockedTabs']);
  if (Array.isArray(session.evidenceCheckpoint)) collector.restore(session.evidenceCheckpoint);
  for (const id of Array.isArray(session.blockedTabs) ? session.blockedTabs : []) if (typeof id === 'number') policy.blocked.add(id);
  const windows = await api.windows.getAll(); collector.focusWindow(windows.find(w => w.focused)?.id);
  connectNative(); await refreshTabs(); await api.alarms.create('lens-maintenance', { periodInMinutes: 0.5 });
}
void start().catch(e => console.error('Lens collector startup failed', errorText(e)));
