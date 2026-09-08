import test from 'node:test';
import assert from 'node:assert/strict';
import { bindSpatialCapture } from '../src/spatial.js';
const snapshot = () => ({ documentId: 'doc', viewport: { width: 1200, height: 900, devicePixelRatio: 2, scrollX: 0, scrollY: 100, visualScale: 1 }, elements: [{ anchorId: 'anchor', source: 'src/Button.tsx:12:3', selector: '#button', bounds: { x: 30, y: 100, width: 200, height: 50 } }] });

test('stable current element receives capture binding and refreshed viewport coordinates', () => {
  const result = bindSpatialCapture(snapshot(), snapshot(), { documentId: 'doc', captureId: 'capture', tabId: 1 });
  assert.equal(result.elements[0]?.captureId, 'capture');
  assert.equal(result.elements[0]?.documentId, 'doc');
  assert.equal(result.elements[0]?.tabId, 1);
  assert.equal(result.elements[0]?.binding, 'stable-across-capture');
  assert.equal(result.elements[0]?.bounds.y, 100);
});

test('scroll, reflow, replacement and document mismatch cannot assert source binding to captured pixels', () => {
  const before = snapshot();
  const cases = [
    { ...snapshot(), documentId: 'other-doc' },
    { ...snapshot(), viewport: { ...snapshot().viewport, scrollY: 140 } },
    { ...snapshot(), elements: [{ ...snapshot().elements[0], bounds: { x: 30, y: 150, width: 200, height: 50 } }] },
    { ...snapshot(), elements: [{ ...snapshot().elements[0], anchorId: 'replacement' }] },
    { ...snapshot(), elements: [] }
  ];
  for (const after of cases) {
    const result = bindSpatialCapture(before, after, { documentId: 'doc', captureId: 'capture', tabId: 1 });
    assert.deepEqual(result.elements, []);
    assert.ok(result.omission);
  }
});

test('independent stable visible elements remain bound while moved or replaced candidates are omitted', () => {
  const before = snapshot();
  before.elements.push({ ...before.elements[0], anchorId: 'second', selector: '#second', bounds: { x: 10, y: 300, width: 120, height: 40 } });
  before.elements.push({ ...before.elements[0], anchorId: 'third', selector: '#third', bounds: { x: 10, y: 400, width: 120, height: 40 } });
  const after = structuredClone(before);
  after.elements[1].bounds.y = 320;
  const result = bindSpatialCapture(before, after, { documentId: 'doc', captureId: 'capture', tabId: 1 });
  assert.deepEqual(result.elements.map(e => e.anchorId), ['anchor', 'third']);
  assert.ok(result.omission?.includes('1'));
});
