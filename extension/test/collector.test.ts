import test from 'node:test';
import assert from 'node:assert/strict';
import { Collector } from '../src/collector.js';

const project = { id: 'studio', name: 'Studio', origins: ['https://dev.sirv.studio'], repositoryPath: '/studio', documentationPaths: [], recording: 'diagnostics' as const, enabled: true, adapter: 'sirv' as const, ownership: [], logPaths: [] };

test('capture only contains the selected tab and current document even with two projects and windows', () => {
  // Fails if a navigation or second tab leaks previous document evidence into a capture.
  const c = new Collector(() => 1000);
  c.configure([project, { ...project, id: 'vibeq', origins: ['https://vibeq.test'] }]);
  c.track({ id: 1, windowId: 11, url: 'https://dev.sirv.studio/a', title: 'Studio', active: true }, 'doc-a');
  c.track({ id: 2, windowId: 22, url: 'https://vibeq.test/b', title: 'VibeQ', active: true }, 'doc-b');
  c.record(1, 'console', { text: 'studio before navigation' });
  c.record(2, 'console', { text: 'vibeq' });
  c.navigate(1, 'doc-c', 'https://dev.sirv.studio/new');
  c.record(1, 'console', { text: 'studio after navigation' });
  const capture = c.capture(1);
  assert.equal(capture.identity.projectId, 'studio');
  assert.equal(capture.identity.windowId, 11);
  assert.equal(capture.identity.documentId, 'doc-c');
  assert.deepEqual(capture.events.map(x => x.data.text).filter(Boolean), ['studio after navigation']);
  assert.equal(c.capture(2).events[0].data.text, 'vibeq');
});

test('two-minute buffer is bounded by count and byte size and reports evictions', () => {
  let now = 1000;
  const c = new Collector(() => now);
  c.configure([project]); c.track({ id: 1, windowId: 1, url: project.origins[0], active: true }, 'doc');
  c.record(1, 'console', { text: 'expired' }); now += 120001;
  c.record(1, 'console', { text: 'recent' });
  assert.deepEqual(c.capture(1).events.map(x => x.data.text), ['recent']);
  for (let i = 0; i < 600; i++) c.record(1, 'console', { text: 'x'.repeat(16000), i });
  const capture = c.capture(1);
  assert.ok(capture.events.length <= 256);
  assert.ok(Buffer.byteLength(JSON.stringify(capture.events)) <= 384 * 1024);
  assert.ok(capture.gaps.some(x => x.channel === 'buffer' && x.reason.includes('evict')));
});

test('unsupported origins and late events from replaced documents are excluded', () => {
  const c = new Collector(); c.configure([project]);
  c.track({ id: 1, windowId: 1, url: project.origins[0], active: true }, 'old');
  c.navigate(1, 'new', project.origins[0]);
  c.record(1, 'response', { secret: 'late old body' }, 'old');
  assert.equal(c.capture(1).events.length, 0);
  c.navigate(1, 'other', 'https://unconfigured.test');
  assert.equal(c.status(1), undefined);
  assert.equal(c.projectFor('https://dev.sirv.studio.attacker.test'), undefined);
});

test('only the selected tab in the focused window is active and focus changes preserve capture identity', () => {
  const c = new Collector(); c.configure([project]);
  c.track({ id: 1, windowId: 11, url: project.origins[0], active: true }, 'doc-one');
  c.track({ id: 2, windowId: 22, url: project.origins[0], active: true }, 'doc-two');
  c.focusWindow(11);
  assert.deepEqual(c.statuses().filter(t => t.active).map(t => t.tabId), [1]);
  c.record(1, 'console', { text: 'one' }); c.record(2, 'console', { text: 'two' });
  c.focusWindow(22);
  assert.deepEqual(c.statuses().filter(t => t.active).map(t => t.tabId), [2]);
  assert.equal(c.capture(1).identity.documentId, 'doc-one');
  assert.equal(c.capture(1).events[0].data.text, 'one');
  c.focusWindow(undefined);
  assert.deepEqual(c.statuses().filter(t => t.active), []);
  c.focusWindow(22);
  c.track({ id: 2, windowId: 22, url: project.origins[0], active: false }, 'doc-two');
  assert.deepEqual(c.statuses().filter(t => t.active), []);
});
