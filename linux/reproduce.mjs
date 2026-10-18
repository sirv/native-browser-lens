import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Resolve the agent's installed Playwright; the Lens desktop needs no Node runtime.
const require = createRequire(path.join(process.cwd(), 'package.json'));
const { chromium } = require('playwright');
const folder = path.dirname(fileURLToPath(import.meta.url));
const phase = process.argv[2];
const hash = value => createHash('sha256').update(value).digest('hex');
const stable = value => Array.isArray(value) ? value.map(stable) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, stable(value[key])])) : value;
const config = JSON.parse(await readFile(path.join(folder, 'handoff.json'), 'utf8'));
if (!['before', 'after'].includes(phase) || !process.argv.includes('--reviewed')) throw Error('Review handoff.json, then run before|after --reviewed');
if (!Array.isArray(config.steps) || !config.steps.length || config.steps.length > 100) throw Error('Fill 1–100 reviewed reproduction steps; no steps are inferred from nearby clicks');
if (hash(JSON.stringify(stable(config.contract))) !== config.contractSHA256) throw Error('Condition changed after handoff. Create a new handoff for a different condition.');
const condition = config.contract.condition;
if (condition.type !== 'http-status' || !Number.isInteger(condition.failureStatus) || !Number.isInteger(condition.successStatus)) throw Error('Invalid HTTP condition');
const validURL = value => { const url = new URL(value); if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw Error('Only HTTP(S) page URLs without embedded credentials are allowed'); return url; };
const expected = validURL(condition.url);
const localOrigin = process.env.LENS_REPRO_ORIGIN ? validURL(process.env.LENS_REPRO_ORIGIN) : null;
if (localOrigin && (localOrigin.protocol !== 'http:' || localOrigin.hostname !== '127.0.0.1' || localOrigin.pathname !== '/' || localOrigin.search || localOrigin.hash)) throw Error('Local reproduction origin must be an HTTP 127.0.0.1 origin');
const localURL = address => { const result = new URL(localOrigin); result.pathname = address.pathname; result.search = address.search; result.hash = address.hash; if (result.origin !== localOrigin.origin) throw Error('Local origin changed'); return result; };
const target = localOrigin ? localURL(expected) : expected;
const pageOrigin = localOrigin ? validURL(config.pageURL).origin : expected.origin;
if (localOrigin && expected.origin !== pageOrigin) throw Error('Automatic local verification requires a same-origin captured failure');
for (const step of config.steps) {
  if (!['goto', 'click', 'fill', 'expectVisible'].includes(step.op)) throw Error('Unsupported step operation');
  if (step.op === 'goto') { const address = validURL(step.url); if (localOrigin && address.origin !== pageOrigin) throw Error('Local verification steps cannot navigate to another origin'); }
  else if (typeof step.selector !== 'string' || step.selector.length > 2048) throw Error('Invalid step selector');
  if (step.op === 'fill' && typeof step.value !== 'string') throw Error('Fill value must be explicit text');
}
const output = path.join(process.env.LENS_REPRO_OUTPUT_DIR || folder, `${phase}-${Date.now()}`);
await mkdir(output, { mode: 0o700 });
const startedAt = Date.now();
const browser = await chromium.launch({ executablePath: process.env.LENS_REPRO_BROWSER || undefined, headless: true });
const context = await browser.newContext({ recordHar: { path: path.join(output, 'network.har'), content: 'omit' } });
await context.tracing.start({ screenshots: true, snapshots: true, sources: false });
const page = await context.newPage();
const cdp = await context.newCDPSession(page);
await cdp.send('Profiler.enable');
await cdp.send('Profiler.start');
let observedStatus = null, executionComplete = false, failure = null, profile;
const statuses = [];
page.on('response', response => {
  const url = new URL(response.url());
  if (url.origin === target.origin && url.pathname === target.pathname && response.request().method() === condition.method) statuses.push(response.status());
});
try {
  for (const step of config.steps) {
    if (step.op === 'goto') { const address = validURL(step.url); await page.goto(localOrigin ? localURL(address).href : step.url, { waitUntil: 'domcontentloaded', timeout: 30000 }); }
    if (step.op === 'click') await page.locator(step.selector).click({ timeout: 15000 });
    if (step.op === 'fill') await page.locator(step.selector).fill(step.value, { timeout: 15000 });
    if (step.op === 'expectVisible') await page.locator(step.selector).waitFor({ state: 'visible', timeout: 15000 });
  }
  const deadline = Date.now() + 10000;
  while (!statuses.length && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 50));
  executionComplete = true;
} catch (error) { failure = String(error.message).slice(0, 2000); }
finally {
  profile = (await cdp.send('Profiler.stop')).profile;
  await writeFile(path.join(output, 'profile.json'), JSON.stringify(profile));
  await context.tracing.stop({ path: path.join(output, 'trace.zip') });
  await context.close();
  await browser.close();
}
// Shutdown can deliver more responses; only the final unique match is usable.
observedStatus = statuses.length === 1 ? statuses[0] : null;
const artifacts = [];
for (const [type, file] of [['har', 'network.har'], ['trace', 'trace.zip'], ['profile', 'profile.json']]) {
  const data = await readFile(path.join(output, file));
  artifacts.push({ type, file, sha256: hash(data), bytes: data.length });
}
const result = { formatVersion: 1, ...config.contract, phase, contractSHA256: config.contractSHA256, stepsSHA256: hash(JSON.stringify(stable(config.steps))), scriptSHA256: hash(await readFile(fileURLToPath(import.meta.url))), buildId: process.env.LENS_REPRO_BUILD || null, testOrigin: localOrigin?.origin || null, startedAt, finishedAt: Date.now(), observedStatus, matchingResponseCount: statuses.length, executionComplete, failure, tool: 'playwright', artifacts };
await writeFile(path.join(output, 'result.json'), JSON.stringify(result, null, 2));
console.log(JSON.stringify({ result: path.join(output, 'result.json'), executionComplete, observedStatus, expectedStatus: phase === 'before' ? condition.failureStatus : condition.successStatus }));
if (!executionComplete || observedStatus !== (phase === 'before' ? condition.failureStatus : condition.successStatus)) process.exitCode = 1;
