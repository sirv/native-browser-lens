import { createRequire } from 'node:module';
import { readFile, writeFile, mkdir, cp } from 'node:fs/promises';
import path from 'node:path';
const require = createRequire(path.join(process.cwd(), 'package.json'));
const { chromium } = require('playwright');
const root = process.env.LENS_AGENT_QA;
const bundle = process.env.LENS_AGENT_BUNDLE;
const extension = path.join(root, 'collector');
await cp(process.env.LENS_AGENT_EXTENSION, extension, { recursive: true });
const manifest = JSON.parse(await readFile(path.join(extension, 'manifest.json'), 'utf8'));
manifest.host_permissions = [process.env.LENS_AGENT_ORIGIN + '/*'];
await writeFile(path.join(extension, 'manifest.json'), JSON.stringify(manifest));
const profile = path.join(root, 'browser-profile');
const context = await chromium.launchPersistentContext(profile, { executablePath: process.env.CHROME_PATH, channel: 'chromium', headless: true, args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`, '--no-first-run'] });
try {
  const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
  const id = new URL(worker.url()).host;
  const host = path.join(root, 'native-host');
  await writeFile(host, '#!/usr/bin/python3\nimport os,sys\nos.environ["LENS_DATA_DIR"]='+JSON.stringify(path.join(root,'notebook'))+'\nos.execv('+JSON.stringify(path.join(bundle,'lens-host'))+',['+JSON.stringify(path.join(bundle,'lens-host'))+']+sys.argv[1:])\n', { mode: 0o700 });
  const hosts = path.join(profile, 'NativeMessagingHosts');await mkdir(hosts, { recursive: true });
  await writeFile(path.join(hosts,'studio.sirv.native_browser_lens.json'), JSON.stringify({ name: 'studio.sirv.native_browser_lens', description: 'Owned agent acceptance fixture', path: host, type: 'stdio', allowed_origins: [`chrome-extension://${id}/`] }));
  const options = await context.newPage();await options.goto(`chrome-extension://${id}/options.html`);
  await options.getByRole('button', { name: 'Reconnect', exact: true }).click();
  const page = await context.newPage();await page.goto(process.env.LENS_AGENT_ORIGIN);
  let tab;
  for (let i=0;i<150;i++) { const state=await options.evaluate(()=>chrome.runtime.sendMessage({kind:'getState'}));tab=state.tabs.find(tab=>tab.mode==='deep');if(tab)break;await new Promise(resolve=>setTimeout(resolve,100)); }
  if (!tab) throw Error('Collector did not arm the controlled project');
  await page.getByRole('button', { name: 'Calculate total', exact: true }).click();
  await page.getByText('Calculation failed', { exact: true }).waitFor();
  await new Promise(resolve=>setTimeout(resolve,500));
  const captured=await options.evaluate(tabId=>chrome.runtime.sendMessage({kind:'capture',tabId}),tab.tabId);
  if(captured.error)throw Error(captured.error);
  console.log(JSON.stringify({captureId:captured.captureId,actualBrowserFailure:500,collectorVersion:manifest.version}));
  await new Promise(resolve=>setTimeout(resolve,1200));
} finally { await context.close(); }
