/** Serialized by chrome.scripting. Keep dependencies inside this function. */
export async function pageSnapshot() {
  const omitted: { channel: string; reason: string }[] = [];
  const secret = /authorization|cookie|password|passwd|secret|token|api.?key|session.?id|credential|csrf|xsrf/i;
  function readStorage(storage: Storage) {
    const entries: Record<string, unknown> = {};
    let bytes = 0;
    for (let i = 0; i < Math.min(storage.length, 40); i++) {
      const key = storage.key(i); if (!key) continue;
      if (secret.test(key)) { entries[key] = '[REDACTED: sensitive key]'; continue; }
      const value = storage.getItem(key) ?? '';
      if (value.length > 2048 || bytes + value.length > 12288) { entries[key] = '[OMITTED: storage value budget]'; continue; }
      bytes += value.length; try { entries[key] = JSON.parse(value); } catch { entries[key] = value; }
    }
    return { entries, totalKeys: storage.length, omittedKeys: Math.max(0, storage.length - 40) };
  }
  const state: Record<string, unknown> = {};
  try { state.localStorage = readStorage(localStorage); } catch { omitted.push({ channel: 'localStorage', reason: 'Storage inaccessible in this document' }); }
  try { state.sessionStorage = readStorage(sessionStorage); } catch { omitted.push({ channel: 'sessionStorage', reason: 'Storage inaccessible in this document' }); }
  try {
    const databases = await indexedDB.databases();
    state.indexedDB = databases.slice(0, 20).map(x => ({ name: x.name, version: x.version }));
    omitted.push({ channel: 'indexedDB', reason: 'Database names and versions only; records are not read without a project adapter' });
  } catch { omitted.push({ channel: 'indexedDB', reason: 'Database enumeration unavailable' }); }
  try {
    const names = await caches.keys();
    state.cacheStorage = names.slice(0, 10).map(name => ({ name }));
    omitted.push({ channel: 'cacheStorage', reason: 'Cache names only; cache bodies and keys are not enumerated' });
  } catch { omitted.push({ channel: 'cacheStorage', reason: 'CacheStorage unavailable' }); }
  let buildId = document.querySelector('meta[name="build-sha"],meta[name="source-sha"],meta[name="git-commit"],meta[name="sirv-build-sha"]')?.getAttribute('content') ?? document.documentElement.getAttribute('data-build-sha') ?? undefined;
  const buildElement = document.querySelector('script#native-lens-context[type="application/json"]');
  let adapter: unknown;
  if (buildElement?.textContent) { try { adapter = JSON.parse(buildElement.textContent.slice(0, 16384)); if (typeof (adapter as {buildId?: unknown}).buildId === 'string') buildId = (adapter as {buildId:string}).buildId; } catch { omitted.push({ channel: 'application', reason: 'Invalid native-lens-context JSON' }); } }
  if (!adapter) omitted.push({ channel: 'application-cache', reason: 'No explicit project diagnostic adapter available' });
  omitted.push({ channel: 'cookies', reason: 'Cookie values intentionally excluded; cookie state is not extracted' });
  return { url: location.href, title: document.title, buildId, viewport: { width: innerWidth, height: innerHeight, devicePixelRatio, scrollX, scrollY, visualScale: visualViewport?.scale ?? 1 }, storage: state, application: adapter, frames: [...document.querySelectorAll('iframe')].slice(0, 20).map(x => ({ src: x.src, title: x.title })), gaps: omitted };
}

/** A passive listener only. Does not prevent or synthesize user interaction. */
export function installActionProbe() {
  const global = globalThis as typeof globalThis & { __nativeLensInstalled?: boolean; __nativeLensLastElement?: unknown; __nativeLensLastTarget?: WeakRef<Element>; __nativeLensAnchorId?: string };
  if (global.__nativeLensInstalled) return;
  global.__nativeLensInstalled = true;
  document.addEventListener('pointerdown', event => {
    const el = event.composedPath().find(x => x instanceof Element) as Element | undefined;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const sourceElement = el.closest('[data-sirv-source], [data-source]');
    const element = { tag: el.tagName.toLowerCase(), role: el.getAttribute('role'), label: (el.getAttribute('aria-label') || (el instanceof HTMLInputElement ? el.labels?.[0]?.textContent : el.textContent) || '').trim().slice(0, 160), selector: el.id ? `#${CSS.escape(el.id)}` : el.tagName.toLowerCase() + [...el.classList].slice(0, 3).map(x => `.${CSS.escape(x)}`).join(''), source: sourceElement?.getAttribute('data-sirv-source') ?? sourceElement?.getAttribute('data-source'), bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }, point: { x: event.clientX, y: event.clientY }, viewport: { width: innerWidth, height: innerHeight, devicePixelRatio }, observedAt: Date.now() };
    global.__nativeLensLastElement = element;
    global.__nativeLensLastTarget = new WeakRef(el);
    global.__nativeLensAnchorId = crypto.randomUUID();
    void chrome.runtime.sendMessage({ kind: 'pageAction', element }).catch(() => {});
  }, { capture: true, passive: true });
}

/** Synchronous, cheap probes bracket the screenshot before slower storage reads. */
export function spatialSnapshot() {
  const global = globalThis as typeof globalThis & { __nativeLensLastTarget?: WeakRef<Element>; __nativeLensElementIds?: WeakMap<Element, string> };
  const ids = global.__nativeLensElementIds ??= new WeakMap<Element, string>();
  const viewport = { width: innerWidth, height: innerHeight, devicePixelRatio, scrollX, scrollY, visualScale: visualViewport?.scale ?? 1 };
  const clicked = global.__nativeLensLastTarget?.deref();
  const interactive = document.querySelectorAll('button,a[href],input,select,textarea,[role="button"],[role="link"]');
  const stamped = document.querySelectorAll('[data-sirv-source],[data-source]');
  const candidates = new Set<Element>();
  if (clicked?.isConnected) candidates.add(clicked);
  for (const element of interactive) { if (candidates.size >= 2500) break; candidates.add(element); }
  for (const element of stamped) { if (candidates.size >= 2500) break; candidates.add(element); }
  const elements = []; let scanned = 0, bytes = 0, truncated = interactive.length + stamped.length > 2500;
  for (const target of candidates) {
    scanned++;
    if (!target.isConnected) continue;
    const rect = target.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0 || rect.right <= 0 || rect.bottom <= 0 || rect.x >= innerWidth || rect.y >= innerHeight) continue;
    const style = getComputedStyle(target);
    if (style.visibility !== 'visible' || style.display === 'none' || style.opacity === '0') continue;
    const sourceElement = target.closest('[data-sirv-source], [data-source]');
    let anchorId = ids.get(target); if (!anchorId) { anchorId = crypto.randomUUID(); ids.set(target, anchorId); }
    const element = { anchorId, tag: target.tagName.toLowerCase(), role: target.getAttribute('role'), label: (target.getAttribute('aria-label') || (target instanceof HTMLInputElement ? target.labels?.[0]?.textContent : target.textContent) || '').trim().slice(0, 96), selector: (target.id ? `#${CSS.escape(target.id)}` : target.tagName.toLowerCase() + [...target.classList].slice(0, 3).map(x => `.${CSS.escape(x)}`).join('')).slice(0, 256), source: (sourceElement?.getAttribute('data-sirv-source') ?? sourceElement?.getAttribute('data-source'))?.slice(0, 512) ?? null, bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } };
    const size = new TextEncoder().encode(JSON.stringify(element)).length;
    if (bytes + size > 48 * 1024 || elements.length >= 250) { truncated = true; break; }
    bytes += size; elements.push(element);
  }
  return { viewport, elements, capturedAt: Date.now(), coverage: { scanned, candidates: candidates.size, truncated, bytes }, ...(elements.length ? {} : { omission: 'No visible interactive or source-stamped element candidates in the captured viewport' }) };
}

/** MAIN-world project opt-in. Browser state remains behind an explicit read-only adapter. */
export function applicationSnapshot() {
  const adapter = (globalThis as typeof globalThis & { __NATIVE_BROWSER_LENS__?: unknown }).__NATIVE_BROWSER_LENS__;
  if (!adapter || typeof adapter !== 'object') return { omission: 'No explicit project diagnostic adapter available' };
  try {
    const json = JSON.stringify(adapter);
    if (json.length > 16384) return { omission: 'Project diagnostic adapter exceeds 16 KiB limit' };
    return { application: JSON.parse(json) as Record<string, unknown> };
  } catch { return { omission: 'Project diagnostic adapter cannot be serialized' }; }
}
