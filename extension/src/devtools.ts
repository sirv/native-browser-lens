import { bodyEvidence, sanitize } from './sanitize.js';
let port: chrome.runtime.Port;
let documentId: string | undefined;
let projectOrigin: string | undefined;
let generation = 0;
function connect() {
  port = chrome.runtime.connect({ name: 'lens-devtools' });
  port.postMessage({ kind: 'open', tabId: chrome.devtools.inspectedWindow.tabId });
  port.onMessage.addListener(message => {
    if (message.kind === 'enabled') { if (message.documentId !== documentId) generation++; documentId = message.documentId; projectOrigin = message.projectOrigin; }
    if (message.kind === 'disabled') { documentId = undefined; projectOrigin = undefined; generation++; }
  });
  port.onDisconnect.addListener(() => { documentId = undefined; generation++; setTimeout(connect, 1000); });
}
connect();
chrome.devtools.network.onNavigated.addListener(() => { documentId = undefined; generation++; });
chrome.devtools.network.onRequestFinished.addListener(request => {
  if (!documentId || !projectOrigin) return;
  const document = documentId; const origin = projectOrigin; const epoch = generation;
  const req = request as chrome.devtools.network.Request & { request: { url: string; method: string; headers: unknown }; response: { status: number; headers: unknown; content: { mimeType: string; size: number } }; startedDateTime: string; time: number; timings: unknown };
  const metadata = { url: req.request.url, method: req.request.method, requestHeaders: req.request.headers, status: req.response.status, responseHeaders: req.response.headers, mimeType: req.response.content.mimeType, startedDateTime: req.startedDateTime, durationMs: req.time, timings: req.timings, source: 'devtools-network' };
  const emit = (body: Record<string, unknown>) => { if (epoch === generation && documentId === document) port.postMessage({ kind: 'network', documentId: document, data: sanitize({ ...metadata, ...body }) }); };
  if (req.response.content.size > 16384) { emit({ omission: 'Response body exceeds 16 KiB limit' }); return; }
  const eligibility = bodyEvidence('', req.response.content.mimeType, req.request.url, origin);
  if (eligibility.omission) { emit(eligibility); return; }
  request.getContent((content, encoding) => emit(encoding ? { omission: 'Encoded DevTools body omitted' } : bodyEvidence(content, req.response.content.mimeType, req.request.url, origin)));
});
