import type { CaptureMode, CapturePayload, CoverageGap, EvidenceEvent, ProjectProfile, TabInput, TabStatus } from './types.js';
interface Entry { activeInWindow: boolean; status: TabStatus; events: EvidenceEvent[]; gaps: CoverageGap[] }
const byteSize = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).length;
export const MAX_EVENT_BYTES = 24 * 1024;
export const MAX_BUFFER_BYTES = 384 * 1024;
export class Collector {
  private projects: ProjectProfile[] = [];
  private focusedWindowId: number | undefined;
  private entries = new Map<number, Entry>();
  constructor(private now = Date.now) {}
  configure(projects: ProjectProfile[]) { this.projects = projects; for (const [id, e] of this.entries) if (this.projectFor(e.status.url)?.id !== e.status.projectId) this.entries.delete(id); }
  projectFor(url: string) { try { const origin = new URL(url).origin; return this.projects.find(p => p.enabled && p.origins.includes(origin)); } catch { return undefined; } }
  focusWindow(windowId: number | undefined) { this.focusedWindowId = windowId; for (const e of this.entries.values()) e.status.active = e.activeInWindow && e.status.windowId === windowId; }
  track(tab: TabInput, documentId: string) {
    const project = this.projectFor(tab.url); if (!project) { this.entries.delete(tab.id); return undefined; }
    const current = this.entries.get(tab.id);
    if (current?.status.projectId === project.id && current.status.documentId === documentId) { current.activeInWindow = tab.active; Object.assign(current.status, { url: tab.url, title: tab.title ?? '', active: tab.active && tab.windowId === this.focusedWindowId, windowId: tab.windowId }); return current.status; }
    const status: TabStatus = { tabId: tab.id, windowId: tab.windowId, projectId: project.id, url: tab.url, title: tab.title ?? '', active: tab.active && tab.windowId === this.focusedWindowId, documentId, mode: 'handover', armedAt: this.now(), capabilities: [] };
    this.entries.set(tab.id, { activeInWindow: tab.active, status, events: [], gaps: [] }); return status;
  }
  navigate(tabId: number, documentId: string, url: string) { const old = this.entries.get(tabId); if (old) this.track({ id: tabId, windowId: old.status.windowId, url, title: old.status.title, active: old.activeInWindow }, documentId); }
  status(tabId: number) { return this.entries.get(tabId)?.status; }
  statuses() { return [...this.entries.values()].map(x => ({ ...x.status })); }
  remove(tabId: number) { this.entries.delete(tabId); }
  mode(tabId: number, mode: CaptureMode, reason?: string) { const e = this.entries.get(tabId); if (e) Object.assign(e.status, { mode, reason, capabilities: mode === 'deep' ? ['network', 'response-bodies', 'console', 'exceptions', 'dom', 'storage', 'screenshot'] : mode === 'devtools' ? ['network', 'available-response-bodies', 'dom', 'storage'] : [] }); }
  gap(tabId: number, channel: string, reason: string) { const e = this.entries.get(tabId); if (e) { const existing = e.gaps.find(x => x.channel === channel && x.reason === reason); if (existing) existing.endedAt = this.now(); else e.gaps.push({ channel, reason, startedAt: this.now() }); if (e.gaps.length > 40) e.gaps.shift(); } }
  record(tabId: number, kind: string, data: Record<string, unknown>, documentId?: string) { const e = this.entries.get(tabId); if (!e || (documentId && documentId !== e.status.documentId)) return; const event: EvidenceEvent = { id: crypto.randomUUID(), projectId: e.status.projectId, tabId, documentId: e.status.documentId, timestamp: this.now(), kind, data }; if (byteSize(event) > MAX_EVENT_BYTES) event.data = { omission: 'Event exceeded 24 KiB limit', originalKind: kind }; e.events.push(event); this.prune(e); return event; }
  private prune(e: Entry) {
    const cutoff = this.now() - 120000;
    e.events = e.events.filter(x => x.timestamp >= cutoff);
    let evicted = false;
    while (e.events.length > 256 || byteSize(e.events) > MAX_BUFFER_BYTES) { e.events.shift(); evicted = true; }
    if (evicted) this.gap(e.status.tabId, 'buffer', 'Oldest evidence evicted by count or byte budget');
  }
  serialize() { for (const e of this.entries.values()) this.prune(e); return [...this.entries.values()]; }
  restore(entries: Entry[]) { for (const e of entries.slice(0, 16)) if (this.projectFor(e.status.url)?.id === e.status.projectId) { this.prune(e); e.activeInWindow = e.activeInWindow === true; e.status.active = e.activeInWindow && e.status.windowId === this.focusedWindowId; this.entries.set(e.status.tabId, e); this.gap(e.status.tabId, 'collector', 'Collector restarted; evidence between last checkpoint and reconnect may be missing'); } }
  capture(tabId: number): CapturePayload { const e = this.entries.get(tabId); if (!e) throw new Error('Tab is not enabled for a configured project'); this.prune(e); const { projectId, tabId: id, windowId, documentId, url, title } = e.status; return { identity: { projectId, tabId: id, windowId, documentId, url, title, capturedAt: this.now() }, events: [...e.events], gaps: [...e.gaps] }; }
}
