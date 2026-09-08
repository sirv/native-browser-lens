import http from 'node:http';
export async function startFixture(port = 0) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname === '/api/fail') { res.writeHead(503, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: 'fixture unavailable', token: 'fixture-response-secret' })); return; }
    if (url.pathname === '/api/cache') { res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'public, max-age=3600', 'etag': 'fixture-v1', 'x-request-id': 'fixture-request-id' }); res.end(JSON.stringify({ result: 'fixture-cached-result', secret: 'fixture-response-secret' })); return; }
    if (url.pathname === '/api/ok') { res.writeHead(200, { 'content-type': 'application/json', 'x-request-id': 'fixture-request-id' }); res.end(JSON.stringify({ result: 'fixture-ok-result', token: 'fixture-response-secret' })); return; }
    if (url.pathname === '/frame') { res.writeHead(200, { 'content-type': 'text/html' }); res.end('<!doctype html><html><body><button id="frame-button" data-sirv-source="src/frame.tsx:9:2">Frame action</button><script>console.log("fixture-child-frame");localStorage.setItem("frameState","ready")</script></body></html>'); return; }
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="build-sha" content="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"><title>Lens fixture ${url.pathname}</title><style>body{font:18px system-ui;padding:50px;background:#f4f6f2;color:#173425}button{font:inherit;padding:14px 20px}#menu{padding:20px;background:white;border:1px solid #59715f;width:300px}iframe{display:block;margin-top:20px}</style></head><body><h1>Browser evidence fixture</h1><p id="state">Ready</p><button id="reproduce" data-sirv-source="src/Fixture.tsx:12:3">Reproduce defect</button><button id="unclicked" data-sirv-source="src/OtherControl.tsx:22:4">Other control</button><div id="menu" hidden>Transient menu stays open in capture.</div><iframe src="/frame" title="Same-origin frame"></iframe><script>
Object.defineProperty(window,'__NATIVE_BROWSER_LENS__',{get:()=>({version:1,build:{commit:'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',environment:'development',sourceState:'working-tree'},session:{status:'authenticated',organizationSelected:true,sirvConnected:true},featureFlags:{fixture:true},queryCache:{total:1,omitted:0,queries:[{family:'assets',status:'success',fetchStatus:'idle',isInvalidated:false}]}})});
const secret='fixture-storage-secret';localStorage.setItem('access_token',secret);localStorage.setItem('view',JSON.stringify({selected:'assets',token:secret}));sessionStorage.setItem('session_id',secret);sessionStorage.setItem('filter','recent');
window.metrics={delays:[],requests:[],ticks:0};let last=performance.now();setInterval(()=>{const now=performance.now();metrics.delays.push(Math.max(0,now-last-100));last=now;metrics.ticks++;if(metrics.delays.length>20000)metrics.delays.shift()},100);
async function work(){let t=performance.now();await fetch('/api/ok?iteration='+metrics.ticks);metrics.requests.push(performance.now()-t);if(metrics.requests.length>20000)metrics.requests.shift();console.log('fixture-busy',metrics.ticks)}
window.startBusy=()=>{window.busy=setInterval(work,200)};window.stopBusy=()=>clearInterval(window.busy);
document.querySelector('#reproduce').addEventListener('click',async()=>{document.querySelector('#menu').hidden=false;document.querySelector('#state').textContent='Reproduced';console.error('fixture-console-error');await fetch('/api/fail');await (await fetch('/api/cache')).json();await (await fetch('/api/cache')).json();fetch('http://127.0.0.1:1/unreachable').catch(()=>{});setTimeout(()=>{throw new Error('fixture-exception')},0)});
</script></body></html>`);
  });
  await new Promise(resolve => server.listen(port, '127.0.0.1', resolve));
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
}
if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) { const fixture = await startFixture(Number(process.env.PORT || 43117)); console.log(fixture.origin); }
