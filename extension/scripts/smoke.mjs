import { chromium } from 'playwright';
import { startFixture } from './fixture.mjs';
import { mkdtemp, cp, readFile, readdir, writeFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir, homedir } from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash, randomUUID } from 'node:crypto';

const temporary = await mkdtemp(path.join(tmpdir(), 'lens-chrome-proof-'));
const extension = path.join(temporary, 'extension');
await cp('dist', extension, { recursive: true });
const fixture = await startFixture();
const fixture2 = await startFixture();
const profile = (id, origin) => ({ id, name: id, origins: [origin], repositoryPath: temporary, documentationPaths: [], enabled: true, adapter: 'generic', recording: 'diagnostics', ownership: [], logPaths: [] });
const projects = [profile('fixture-a', fixture.origin), profile('fixture-b', fixture2.origin)];
const manifest = JSON.parse(await readFile(path.join(extension, 'manifest.json'), 'utf8'));
manifest.host_permissions = projects.flatMap(p => p.origins.map(x => `${x}/*`));
await writeFile(path.join(extension, 'manifest.json'), JSON.stringify(manifest));
const background = await readFile(path.join(extension, 'background.js'), 'utf8');
const hostName = process.env.NATIVE_HOST_PATH ? 'studio.sirv.native_browser_lens' : 'studio.sirv.native_browser_lens.fixture';
await writeFile(path.join(extension, 'background.js'), background.replace('studio.sirv.native_browser_lens', hostName));
const outfile = path.join(temporary, 'native-messages.jsonl');
const python = '/usr/bin/python3';
const host = path.join(temporary, 'native-host');
await writeFile(host, `#!${python}\nimport sys,struct,json,time\nOUT=${JSON.stringify(outfile)}\nPROJECTS=json.loads(${JSON.stringify(JSON.stringify(projects))})\nwhile True:\n h=sys.stdin.buffer.read(4)\n if len(h)!=4:break\n n=struct.unpack('<I',h)[0]\n raw=sys.stdin.buffer.read(n)\n if len(raw)!=n:break\n m=json.loads(raw)\n with open(OUT,'a') as f:f.write(json.dumps(m)+'\\n')\n if m['kind']=='hello':\n  reply=json.dumps({'version':1,'kind':'configure','id':'fixture-configure','payload':{'projects':PROJECTS}}).encode()\n  sys.stdout.buffer.write(struct.pack('<I',len(reply))+reply);sys.stdout.buffer.flush()\n`, { mode: 0o700 });
const mailbox = path.join(temporary,'lens-data','bridge');
if (process.env.NATIVE_HOST_PATH) {
  await mkdir(path.join(mailbox,'inbox'),{recursive:true});
  await writeFile(path.join(mailbox,'projects.json'),JSON.stringify(projects));
  const nativeBinary=path.join(temporary,'lens-host');await cp(path.resolve(process.env.NATIVE_HOST_PATH),nativeBinary);
  await writeFile(host, `#!${python}\nimport os,sys\nos.environ['LENS_DATA_DIR']=${JSON.stringify(path.join(temporary,'lens-data'))}\nos.execv(${JSON.stringify(nativeBinary)},[${JSON.stringify(nativeBinary)}]+sys.argv[1:])\n`,{mode:0o700});
}
let context;
const manifestPaths = [];
const output = path.resolve(process.env.OUTPUT_DIR || 'output/playwright'); await mkdir(output, { recursive: true });
try {
  context = await chromium.launchPersistentContext(path.join(temporary, 'profile'), { channel: 'chromium', executablePath: process.env.CHROME_PATH, headless: process.env.HEADED !== '1', args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`, '--no-first-run'], viewport: { width: 1200, height: 900 } });
  const worker = context.serviceWorkers()[0] ?? await context.waitForEvent('serviceworker');
  const extensionId = new URL(worker.url()).host;
  const nativeManifest = { name: hostName, description: 'Native Lens isolated runtime fixture receiver', path: host, type: 'stdio', allowed_origins: [`chrome-extension://${extensionId}/`] };
  for (const dir of [path.join(temporary, 'profile', 'NativeMessagingHosts')]) { await mkdir(dir, { recursive: true });
    const filename = path.join(dir, `${nativeManifest.name}.json`); await writeFile(filename, JSON.stringify(nativeManifest)); manifestPaths.push(filename);
  }
  const options = await context.newPage(); await options.goto(`chrome-extension://${extensionId}/options.html`);
  await options.getByRole('button', { name: 'Reconnect', exact: true }).click();
  await poll(async () => { const s = await options.evaluate(() => chrome.runtime.sendMessage({kind:'getState'})); return !s.nativeError; }, 'native connection', 20000).catch(async error=>{console.error('Native connection state:',JSON.stringify(await options.evaluate(()=>chrome.runtime.sendMessage({kind:'getState'}))));throw error;});
  const first = await context.newPage(); await first.goto(`${fixture.origin}/a`);
  const secondReady = context.waitForEvent('page'); await options.evaluate(url=>chrome.windows.create({url}), `${fixture2.origin}/b`); const second = await secondReady; await second.waitForLoadState();
  const state = () => options.evaluate(() => chrome.runtime.sendMessage({ kind: 'getState' }));
  await poll(async () => (await state()).tabs.filter(t => t.mode === 'deep').length === 2, 'two deep tabs');
  await first.getByRole('button', { name: 'Reproduce defect' }).click();
  await second.getByRole('button', { name: 'Reproduce defect' }).click();
  await new Promise(r => setTimeout(r, 1800));
  let tabs = (await state()).tabs;
  const tabA = tabs.find(t => t.projectId === 'fixture-a'); const tabB = tabs.find(t => t.projectId === 'fixture-b');
  assert.ok(tabA && tabB); assert.notEqual(tabA.windowId, tabB.windowId, 'fixture tabs use distinct Chrome windows');
  if (process.env.HEADED === '1') {
    await options.evaluate(async tab=>{await chrome.tabs.update(tab.tabId,{active:true});await chrome.windows.update(tab.windowId,{focused:true})},tabA);
    await poll(async()=>{const s=await state();return s.tabs.filter(t=>t.active).length===1 && s.tabs.some(t=>t.tabId===tabA.tabId && t.active)},'focused first window only');
    await options.evaluate(async tab=>{await chrome.tabs.update(tab.tabId,{active:true});await chrome.windows.update(tab.windowId,{focused:true})},tabB);
    await poll(async()=>(await state()).tabs.filter(t=>t.active).length===1 && (await state()).tabs.some(t=>t.tabId===tabB.tabId && t.active),'focused second window only');
  } else {
    const focused = (await options.evaluate(()=>chrome.windows.getAll())).filter(w=>w.focused).map(w=>w.id);
    assert.ok((await state()).tabs.filter(t=>t.active).every(t=>focused.includes(t.windowId)),'headless collector never invents OS window focus');
  }
  const currentBounds = await first.evaluate(()=>{const button=document.querySelector('#reproduce');button.style.marginTop='35px';const r=button.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}});
  const cap = await options.evaluate(tabId => chrome.runtime.sendMessage({ kind: 'capture', tabId }), tabA.tabId);
  assert.ok(!cap.error, cap.error);
  await waitCapture(cap.captureId);
  const messages = (await readMessages());
  const capture = messages.findLast(x => x.kind === 'capture')?.payload;
  const started = messages.find(m=>m.kind==='capture-started' && m.payload.captureId===capture.captureId);
  assert.ok(started,'extension-initiated capture has durable start identity');
  assert.equal(started.payload.initiatedBy,'extension');
  assert.equal(started.payload.tab.documentId,capture.identity.documentId);
  assert.equal(started.payload.identity.tabId,tabA.tabId);
  assert.ok(messages.indexOf(started)<messages.findIndex(m=>m.kind==='artifact' && m.payload.captureId===capture.captureId),'start precedes image chunks');
  assert.equal(capture.identity.projectId, 'fixture-a');
  assert.equal(capture.identity.documentId, tabA.documentId);
  assert.ok(capture.events.every(e => e.projectId === 'fixture-a' && e.tabId === tabA.tabId));
  assert.ok(capture.events.some(e => e.kind === 'exception' && JSON.stringify(e).includes('fixture-exception')));
  assert.ok(capture.events.some(e => e.kind === 'response' && e.data.status === 503));
  assert.ok(capture.events.some(e=>e.kind==='network-failure'),'failed transport has explicit captured event');
  assert.ok(capture.events.some(e=>e.kind==='cache' || e.kind==='response' && (e.data.fromDiskCache || e.data.fromServiceWorker)),'actual cache provenance observed for repeated cached response');
  assert.ok(capture.events.some(e => e.kind === 'response-body' && JSON.stringify(e).includes('fixture-cached-result')));
  assert.equal(capture.context.storage.localStorage.entries.access_token, '[REDACTED]');
  assert.ok(!JSON.stringify(capture).includes('fixture-storage-secret'));
  assert.ok(!JSON.stringify(capture).includes('fixture-response-secret'));
  assert.equal(capture.context.elements[0].source, 'src/Fixture.tsx:12:3');
  assert.equal(capture.context.elements[0].binding,'stable-across-capture');
  assert.ok(capture.context.elements.some(e=>e.selector==='#unclicked' && e.source==='src/OtherControl.tsx:22:4' && e.binding==='stable-across-capture'),'unclicked visible element has frozen spatial binding');
  assert.deepEqual(capture.context.elements[0].bounds,currentBounds,'reflowed element is located at capture-time bounds');
  assert.equal(capture.context.application.session.status,'authenticated');
  assert.equal(capture.context.application.queryCache.queries[0].family,'assets');
  assert.ok(!capture.gaps.some(g=>g.channel==='application-cache'));
  assert.equal(capture.context.application.build.sourceState,'working-tree');
  assert.equal(capture.context.sourceBuildVerified,false);
  await first.evaluate(()=>{const el=document.querySelector('#reproduce');el.replaceWith(el.cloneNode(true))});
  const replaced=await options.evaluate(tabId=>chrome.runtime.sendMessage({kind:'capture',tabId}),tabA.tabId); assert.ok(!replaced.error,replaced.error);
  const replacementCapture=await waitCapture(replaced.captureId);
  const oldAnchor=capture.context.elements.find(e=>e.selector==='#reproduce').anchorId;
  const newAnchor=replacementCapture.context.elements.find(e=>e.selector==='#reproduce').anchorId;
  assert.notEqual(oldAnchor,newAnchor,'replacement receives new current DOM identity, never historical click identity');
  if (process.env.NATIVE_HOST_PATH) {
    const statusMessage=(await readMessages()).findLast(m=>m.kind==='status' && m.payload.tabs?.some(t=>t.tabId===tabA.tabId));
    const clientId=statusMessage.payload.clientId; assert.ok(clientId);
    const requestedCaptureId=randomUUID();
    const command={version:1,kind:'capture',id:randomUUID(),payload:{tabId:tabA.tabId,observationId:randomUUID(),captureId:requestedCaptureId,clientId}};
    await writeFile(path.join(mailbox,'clients',clientId,`${Date.now()}-${randomUUID()}.json`),JSON.stringify(command));
    const roundtrip=await waitCapture(requestedCaptureId);
    assert.equal(roundtrip.identity.clientId,clientId,'real native-host watcher routes capture command and reply to same browser client');
    const nativeStarted=(await readMessages()).find(m=>m.kind==='capture-started' && m.payload.captureId===requestedCaptureId);
    assert.equal(nativeStarted?.payload.initiatedBy,'native','native capture start is durable and identifies its origin');
    assert.equal(nativeStarted?.payload.observationId,command.payload.observationId,'native capture reuses the existing observation identity');
  }
  const parts = messages.filter(x => x.kind === 'artifact' && x.payload.captureId === capture.captureId).sort((a,b) => a.payload.index-b.payload.index);
  assert.ok(parts.length > 0); assert.equal(parts.length, parts[0].payload.total);
  const png = Buffer.from(parts.map(x => x.payload.data).join(''), 'base64'); assert.equal(png.subarray(1,4).toString(), 'PNG');
  await writeFile(path.join(output, 'collector-capture.png'), png);
  await writeFile(path.join(output, 'collector-capture.json'), JSON.stringify(capture, null, 2));
  await options.screenshot({ path: path.join(output, 'connection.png'), fullPage: true });
  const oldDoc = tabA.documentId; await first.goto(`${fixture.origin}/new-document`);
  await poll(async () => (await state()).tabs.some(t => t.tabId === tabA.tabId && t.documentId !== oldDoc && t.mode === 'deep'), 'navigation document change');
  const after = await options.evaluate(tabId => chrome.runtime.sendMessage({ kind: 'capture', tabId }), tabA.tabId); assert.ok(!after.error, after.error); await poll(async()=>{const m=(await readMessages()).findLast(x=>x.kind==='capture');return m?.payload.identity.documentId!==oldDoc;},'native receiver persisted current-document capture');
  const latest = await waitCapture(after.captureId);
  assert.ok(!latest.events.some(x => JSON.stringify(x).includes('fixture-exception')));
  await options.evaluate(() => chrome.runtime.sendMessage({ kind: 'pause', paused: true }));
  await poll(async () => (await state()).tabs.every(t => t.mode === 'paused'), 'pause');
  await options.evaluate(() => chrome.runtime.sendMessage({ kind: 'pause', paused: false }));
  await poll(async () => (await state()).tabs.every(t => t.mode === 'deep'), 'resume');
  let devtoolsVerified = false;
  if (process.env.DEVTOOLS === '1') {
    const session = await context.newCDPSession(first);
    const info = await session.send('Target.getTargetInfo');
    const browserSession = await context.browser().newBrowserCDPSession();
    const opened = await browserSession.send('Target.openDevTools', { targetId: info.targetInfo.targetId, panelId: 'network' });
    await poll(async () => (await state()).tabs.some(t => t.tabId === tabA.tabId && t.mode === 'devtools'), 'DevTools automatic handover');
    await first.evaluate(() => fetch('/api/ok?devtools-proof=1'));
    await new Promise(r => setTimeout(r, 1600));
    const result = await options.evaluate(tabId => chrome.runtime.sendMessage({kind:'capture',tabId}), tabA.tabId); assert.ok(!result.error, result.error);
    const devCapture = await waitCapture(result.captureId);
    assert.ok(devCapture.events.some(e=>e.kind==='devtools-network' && JSON.stringify(e).includes('devtools-proof')),'DevTools HAR entry reaches observation');
    assert.ok(devCapture.gaps.some(g=>g.channel==='devtools'));
    await writeFile(path.join(output,'devtools-capture.json'),JSON.stringify(devCapture,null,2));
    const beforeDevNav = (await state()).tabs.find(t=>t.tabId===tabA.tabId).documentId;
    await first.goto(`${fixture.origin}/devtools-navigation`);
    await poll(async ()=>(await state()).tabs.some(t=>t.tabId===tabA.tabId && t.documentId!==beforeDevNav && t.mode==='devtools'),'DevTools navigation identity');
    await first.evaluate(()=>fetch('/api/ok?devtools-after-navigation=1'));
    await new Promise(r=>setTimeout(r,1600));
    const navResult = await options.evaluate(tabId=>chrome.runtime.sendMessage({kind:'capture',tabId}),tabA.tabId);assert.ok(!navResult.error,navResult.error);
    await poll(async()=>{const m=(await readMessages()).findLast(x=>x.kind==='capture');return m?.payload.identity.documentId!==beforeDevNav;},'native receiver persisted DevTools navigation');
    const navCapture=await waitCapture(navResult.captureId);
    assert.ok(navCapture.events.some(e=>e.kind==='devtools-network' && JSON.stringify(e).includes('devtools-after-navigation')),'DevTools evidence resumes after navigation');
    await browserSession.send('Target.closeTarget',{targetId:opened.targetId});
    await poll(async () => (await state()).tabs.some(t=>t.tabId===tabA.tabId && t.mode==='deep'),'DevTools close restores deep capture');
    await first.evaluate(()=>fetch('/api/ok?deep-restored=1'));
    devtoolsVerified = true;
    await session.detach(); await browserSession.detach();
  }
  const captureSamples=[];
  if (Number(process.env.CAPTURE_SAMPLES)>0) {
    await first.getByRole('button',{name:'Reproduce defect'}).click();
    for(let i=0;i<Math.min(50,Number(process.env.CAPTURE_SAMPLES));i++) {
      const start=performance.now();const result=await options.evaluate(tabId=>chrome.runtime.sendMessage({kind:'capture',tabId}),tabA.tabId);assert.ok(!result.error,result.error);const persisted=await waitCapture(result.captureId);
      captureSamples.push({milliseconds:performance.now()-start,events:persisted.events.length,screenshotOmission:persisted.screenshotOmission??null});
    }
    const sorted=captureSamples.map(s=>s.milliseconds).sort((a,b)=>a-b);await writeFile(path.join(output,'capture-latency.json'),JSON.stringify({nativeHost:process.env.NATIVE_HOST_PATH??'fixture',samples:captureSamples,p50:sorted[Math.floor(sorted.length*.5)],p95:sorted[Math.min(sorted.length-1,Math.floor(sorted.length*.95))],definition:'Browser capture request to real native host persisted capture; includes PNG acquisition, DOM/storage/source probes and framed PNG parts. Excludes native ScreenCaptureKit and notebook rendering.'},null,2));
  }
  const summary = { productionCollectorSHA256:createHash('sha256').update(background).digest('hex'), nativeHostSHA256:process.env.NATIVE_HOST_PATH?createHash('sha256').update(await readFile(path.join(temporary,'lens-host'))).digest('hex'):null, devtoolsVerified, focusedWindowVerified: process.env.HEADED === '1', at: new Date().toISOString(), browser: context.browser()?.version(), fixtureOrigin: fixture.origin, extensionId, nativeHost: process.env.NATIVE_HOST_PATH ? path.resolve(process.env.NATIVE_HOST_PATH) : 'isolated real Native Messaging fixture receiver', assertions: ['two-project two-window isolation', ...(process.env.HEADED === '1' ? ['focused-window active status'] : ['absent OS-focus remains inactive']), 'capture-time reflow revalidation', 'replacement node receives fresh spatial identity', 'MAIN-world diagnostic adapter', 'debugger network and 503 response', 'console exception with stack', 'sanitized same-origin body', 'sanitized storage', 'source stamp and viewport', 'durable extension capture-started before artifacts', 'real PNG capture via chunked native host', ...(process.env.NATIVE_HOST_PATH ? ['filesystem-watched native command roundtrip and client identity'] : []), 'navigation replacement', 'pause and resume'], captureEvents: capture.events.length, imageBytes: png.length, gaps: capture.gaps, defaultsNotVerified: ['default Chrome profile consent', 'native ScreenCaptureKit', ...(devtoolsVerified ? [] : ['DevTools window handover'])] };
  await writeFile(path.join(output, 'smoke-result.json'), JSON.stringify(summary, null, 2));
  console.log(JSON.stringify(summary, null, 2));
  const duration = Number(process.env.SOAK_SECONDS || 0);
  if (duration > 0) await soak({ context, worker, first, options, state, fixture, duration, output });
} finally { await context?.close(); fixture.server.close(); fixture2.server.close(); for (const f of manifestPaths) await rm(f, { force: true }); if (process.env.KEEP_FIXTURE !== '1') await rm(temporary, { recursive: true, force: true }); else console.log('Fixture kept:', temporary); }
async function readMessages() { if (!process.env.NATIVE_HOST_PATH) return (await readFile(outfile,'utf8')).trim().split('\n').filter(Boolean).map(x=>JSON.parse(x)); const dir=path.join(mailbox,'inbox');const names=(await readdir(dir)).filter(n=>n.endsWith('.json')).sort();return Promise.all(names.map(async n=>JSON.parse(await readFile(path.join(dir,n),'utf8')))); }
async function waitCapture(captureId) { let payload; await poll(async()=>{const messages=(await readMessages()); payload=messages.findLast(x=>x.kind==='capture' && x.payload.captureId===captureId)?.payload;return !!payload;},'native capture persistence');return payload; }
async function poll(fn, label, timeout = 20000) { const start = Date.now(); while (Date.now() - start < timeout) { if (await fn()) return; await new Promise(r => setTimeout(r, 200)); } throw new Error(`Timed out: ${label}`); }
async function soak({ context, worker, first, options, state, fixture, duration, output }) {
  const baselineContext = await chromium.launchPersistentContext(path.join(temporary, 'baseline'), { channel: 'chromium', executablePath: process.env.CHROME_PATH, headless: true, viewport: { width: 1200, height: 900 } });
  const baseline = await baselineContext.newPage(); await baseline.goto(`${fixture.origin}/baseline`);
  await first.bringToFront(); await baseline.bringToFront();
  if(process.env.COLLECTION_CONTROL==='1') await options.evaluate(()=>chrome.runtime.sendMessage({kind:'pause',paused:true}));
  await first.evaluate(() => { window.metrics={delays:[],requests:[],ticks:0};window.startBusy(); }); await baseline.evaluate(() => { window.metrics={delays:[],requests:[],ticks:0};window.startBusy(); });
  const samples = []; const startedAt = Date.now();let visibilityPhase=0;const fixtureTabId=(await state()).tabs.find(t=>t.url===first.url())?.tabId;
  const armedSession = await context.browser().newBrowserCDPSession();const baselineSession=await baselineContext.browser().newBrowserCDPSession();
  const resources=async session=>{const {processInfo}=await session.send('SystemInfo.getProcessInfo');const ids=processInfo.map(p=>p.id);const {stdout}=await promisify(execFile)('ps',['-o','rss=','-p',ids.join(',')]);return {cpuSeconds:processInfo.reduce((n,p)=>n+p.cpuTime,0),rssKiB:stdout.trim().split(/\s+/).map(Number).filter(Number.isFinite).reduce((a,b)=>a+b,0),processCount:ids.length};};
  const initialResources={armed:await resources(armedSession),baseline:await resources(baselineSession)};
  try {
    while (Date.now() - startedAt < duration * 1000) {
      await new Promise(r => setTimeout(r, Math.min(30000, duration * 1000 - (Date.now() - startedAt))));
      const summarize = () => { const m=window.metrics; const percentile=a=>{const sorted=[...a].sort((a,b)=>a-b);return sorted[Math.floor(sorted.length*.95)]??0}; return {visibility:document.visibilityState,focused:document.hasFocus(),ticks:m.ticks,timerDelayP95:percentile(m.delays),requestP95:percentile(m.requests),jsHeap:performance.memory?.usedJSHeapSize}; };
      const checkpoint = await worker.evaluate(() => chrome.storage.session.get('evidenceCheckpoint'));
      const activeTabIds=await options.evaluate(()=>chrome.tabs.query({active:true}).then(tabs=>tabs.map(t=>t.id)));
      const sample = { armedSelectedTab:activeTabIds.includes(fixtureTabId),phase:visibilityPhase, resources:{armed:await resources(armedSession),baseline:await resources(baselineSession)}, elapsedSeconds: (Date.now()-startedAt)/1000, armed: await first.evaluate(summarize), baseline: await baseline.evaluate(summarize), evidenceBytes: Buffer.byteLength(JSON.stringify(checkpoint)), tabModes: (await state()).tabs.map(x=>x.mode) };
      samples.push(sample); await writeFile(path.join(output,'soak-progress.json'),JSON.stringify({startedAt:new Date(startedAt).toISOString(),requestedSeconds:duration,samples},null,2));
      console.log('SOAK', JSON.stringify(sample));
      if(process.env.COLLECTION_CONTROL==='1' && visibilityPhase===0 && sample.elapsedSeconds>=30) {await options.evaluate(()=>chrome.runtime.sendMessage({kind:'pause',paused:false}));await first.evaluate(()=>window.metrics={delays:[],requests:[],ticks:0});visibilityPhase=1;}
      else if(process.env.COLLECTION_CONTROL==='1' && visibilityPhase===1 && sample.elapsedSeconds>=60) {await options.evaluate(()=>chrome.runtime.sendMessage({kind:'pause',paused:true}));await first.evaluate(()=>window.metrics={delays:[],requests:[],ticks:0});visibilityPhase=2;}
      else if(process.env.VISIBILITY_CONTROL==='1' && visibilityPhase===0 && sample.elapsedSeconds>=30) {await options.bringToFront();await first.evaluate(()=>window.metrics={delays:[],requests:[],ticks:0});visibilityPhase=1;}
      else if(process.env.VISIBILITY_CONTROL==='1' && visibilityPhase===1 && sample.elapsedSeconds>=60) {await first.bringToFront();await first.evaluate(()=>window.metrics={delays:[],requests:[],ticks:0});visibilityPhase=2;}
    }
    assert.ok(samples.every(s=>s.evidenceBytes<8*1024*1024),'evidence memory bound');
    await writeFile(path.join(output,'soak-result.json'),JSON.stringify({startedAt:new Date(startedAt).toISOString(),completedAt:new Date().toISOString(),durationSeconds:(Date.now()-startedAt)/1000,initialResources,samples,limits:'Fixture-only JS heap, timers, request latency and extension evidence checkpoint. Selected tabs are brought forward and metric histories reset before workload; visibility is recorded. Concurrent browsers share host load. Chrome SystemInfo CPU totals and per-process ps RSS include all browser fixture pages/extensions; RSS sum may count shared pages more than once. Not default-profile acceptance.'},null,2));
  } finally { await baselineContext.close(); }
}
