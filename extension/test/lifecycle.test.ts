import test from 'node:test';
import assert from 'node:assert/strict';
import { AttachmentPolicy } from '../src/lifecycle.js';

test('closing DevTools permits one deep reconnect; user cancellation does not auto-reattach', () => {
  const p = new AttachmentPolicy();
  assert.equal(p.canAttach(1), true);
  p.openDevtools(1); assert.equal(p.canAttach(1), false);
  p.detached(1); p.closeDevtools(1); assert.equal(p.canAttach(1), true);
  p.detached(1); assert.equal(p.canAttach(1), false);
  assert.equal(p.canAttach(2), true);
  p.resume(1); assert.equal(p.canAttach(1), true);
});
