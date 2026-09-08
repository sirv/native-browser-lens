export interface SpatialElement { anchorId: string; selector: string; source?: string | null; bounds: { x: number; y: number; width: number; height: number }; [key: string]: unknown }
export interface SpatialSnapshot { documentId: string; viewport: { width: number; height: number; devicePixelRatio: number; scrollX: number; scrollY: number; visualScale: number }; elements: SpatialElement[]; omission?: string; capturedAt?: number; coverage?: { scanned: number; candidates: number; truncated: boolean; bytes: number } }
export interface BoundElement extends SpatialElement { tabId: number; documentId: string; captureId: string; binding: 'stable-across-capture' }
export function bindSpatialCapture(before: SpatialSnapshot | undefined, after: SpatialSnapshot | undefined, identity: { tabId: number; documentId: string; captureId: string }): { elements: BoundElement[]; omission?: string; viewport?: SpatialSnapshot['viewport'] } {
  const missing = (reason: string) => ({ elements: [] as BoundElement[], omission: reason, viewport: before?.viewport });
  if (!before || !after) return missing('Spatial probes unavailable around screenshot');
  if (before.documentId !== identity.documentId || after.documentId !== identity.documentId) return missing('Spatial document identity changed during screenshot');
  const viewportKeys = ['width', 'height', 'devicePixelRatio', 'scrollX', 'scrollY', 'visualScale'] as const;
  if (viewportKeys.some(k => Math.abs(before.viewport[k] - after.viewport[k]) > 0.01)) return missing('Viewport changed during screenshot; element-to-image binding omitted');
  if (before.omission || after.omission || before.elements.length === 0 || after.elements.length === 0) return missing(before.omission || after.omission || 'No connected target element for this screenshot');
  const afterById = new Map(after.elements.map(e => [e.anchorId, e]));
  const elements: BoundElement[] = [];
  let omitted = 0;
  for (const a of before.elements) {
    const b = afterById.get(a.anchorId);
    if (!b || a.source !== b.source || a.selector !== b.selector || ['x', 'y', 'width', 'height'].some(k => Math.abs(a.bounds[k as keyof typeof a.bounds] - b.bounds[k as keyof typeof b.bounds]) > 0.5)) { omitted++; continue; }
    elements.push({ ...a, ...identity, binding: 'stable-across-capture' });
  }
  const gaps = [];
  if (omitted) gaps.push(`${omitted} moved, replaced, or source-changed element candidates omitted`);
  if (before.coverage?.truncated || after.coverage?.truncated) gaps.push('Visible candidate enumeration reached scan, count, or byte budget');
  return { elements, viewport: before.viewport, ...(gaps.length ? { omission: gaps.join('; ') } : {}) };
}
