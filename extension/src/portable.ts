import type { Collector } from './collector.js';

/** Browser webRequest metadata only; it never intercepts or changes response streams. */
export class WebRequestEvidence {
  readonly pending = new Map<string, { tabId: number; documentId: string; redirectResponse?: { status: number; url: string } }>();
  constructor(private collector: Collector, private record: (tab: number, kind: string, data: Record<string, unknown>, document: string) => void, private gap: (tab: number, channel: string, reason: string) => void, private paused: () => boolean) {}
  clear(tabId?: number) { for (const [key, value] of this.pending) if (tabId === undefined || value.tabId === tabId) this.pending.delete(key); }
  event(kind: string, details: { tabId: number; requestId: string; url: string; [key: string]: any }) {
    const tabId = details.tabId, status = this.collector.status(tabId), key = `${tabId}:${details.requestId}`;
    if (this.paused() || status?.mode !== 'limited') { this.pending.delete(key); return; }
    const previous = this.pending.get(key);
    const redirectResponse = previous?.documentId === status.documentId ? previous.redirectResponse : undefined;
    if (kind === 'request') {
      if (details.type === 'main_frame') return;
      if (this.pending.size >= 256) { const oldest = this.pending.keys().next().value!; const evicted = this.pending.get(oldest)!; this.pending.delete(oldest); this.gap(evicted.tabId, 'network', 'Pending request metadata evicted at 256 requests'); }
      this.pending.set(key, { tabId, documentId: status.documentId });
    }
    const pending = this.pending.get(key);
    if (!pending || pending.documentId !== status.documentId) { this.pending.delete(key); return; }
    const data: Record<string, unknown> = { requestId: 'web:' + details.requestId, url: details.url, frameId: details.frameId, source: 'webRequest', monotonicTime: performance.now() / 1000 };
    if (kind === 'request') Object.assign(data, { method: details.method, resourceType: details.type, redirectResponse });
    if (kind === 'response' || kind === 'redirect') Object.assign(data, { status: details.statusCode, headers: details.responseHeaders, fromCache: details.fromCache });
    if (kind === 'network-failure') Object.assign(data, { errorText: details.error });
    if (kind === 'redirect') { Object.assign(data, { redirectURL: details.redirectUrl }); pending.redirectResponse = { status: details.statusCode, url: details.url }; }
    this.record(tabId, kind === 'redirect' ? 'response' : kind, data, pending.documentId);
    if (kind === 'network-complete' || kind === 'network-failure') this.pending.delete(key);
  }
  listen(request: typeof chrome.webRequest) {
    const filter = { urls: ['http://*/*', 'https://*/*'] };
    request.onBeforeRequest.addListener(d => { this.event('request', d); return undefined; }, filter);
    request.onHeadersReceived.addListener(d => { this.event('response', d); return undefined; }, filter, ['responseHeaders']);
    request.onBeforeRedirect.addListener(d => this.event('redirect', d), filter);
    request.onCompleted.addListener(d => this.event('network-complete', d), filter);
    request.onErrorOccurred.addListener(d => this.event('network-failure', d), filter);
  }
}

export function documentToken() {
  const local = globalThis as typeof globalThis & { __nativeLensDocumentToken?: string };
  return local.__nativeLensDocumentToken ??= crypto.randomUUID();
}
