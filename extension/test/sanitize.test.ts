import test from 'node:test';
import assert from 'node:assert/strict';
import { sanitize, sanitizeURL, bodyEvidence } from '../src/sanitize.js';

test('secrets are removed from nested objects, headers, strings and URL parameters', () => {
  const result = sanitize({ Authorization: 'Bearer abc', nested: { password: 'bad', text: 'Authorization: Bearer xyz; token=shh' }, headers: [{ name: 'Set-Cookie', value: 'sid=private' }], url: 'https://example.test/a?access_token=abc&view=list#token=secret' });
  const text = JSON.stringify(result);
  for (const secret of ['Bearer abc', 'bad', 'Bearer xyz', 'shh', 'sid=private', 'access_token=abc', 'token=secret']) assert.ok(!text.includes(secret), secret);
  assert.equal(sanitizeURL('https://user:pass@host.test/a?q=ok&token=secret'), 'https://host.test/a?q=ok&token=%5BREDACTED%5D');
});

test('same-origin response JSON is sanitized and bodies outside origin or size budget explain omissions', () => {
  assert.equal(bodyEvidence('{"token":"private","result":"ok"}', 'application/json', 'https://a.test/api', 'https://a.test').body, '{"token":"[REDACTED]","result":"ok"}');
  assert.match(String(bodyEvidence('x', 'text/plain', 'https://third-party.test', 'https://a.test').omission), /origin/);
  assert.match(String(bodyEvidence('x'.repeat(32769), 'text/plain', 'https://a.test', 'https://a.test').omission), /limit/);
  assert.match(String(bodyEvidence('xx', 'image/png', 'https://a.test', 'https://a.test').omission), /Binary/);
});
