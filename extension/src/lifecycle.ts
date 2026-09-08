export class AttachmentPolicy {
  readonly devtools = new Set<number>();
  readonly blocked = new Set<number>();
  canAttach(tabId: number) { return !this.devtools.has(tabId) && !this.blocked.has(tabId); }
  openDevtools(tabId: number) { this.devtools.add(tabId); this.blocked.delete(tabId); }
  closeDevtools(tabId: number) { this.devtools.delete(tabId); }
  detached(tabId: number) { if (!this.devtools.has(tabId)) this.blocked.add(tabId); }
  resume(tabId: number) { this.blocked.delete(tabId); }
  remove(tabId: number) { this.devtools.delete(tabId); this.blocked.delete(tabId); }
}
