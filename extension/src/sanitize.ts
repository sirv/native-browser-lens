const sensitive = /authorization|cookie|password|passwd|secret|token|api.?key|session.?id|credential|csrf|xsrf/i;
const REDACTED = '[REDACTED]';
export function sanitizeURL(input: string): string {
  try { const u = new URL(input); u.username = ''; u.password = ''; u.hash = ''; for (const key of u.searchParams.keys()) if (sensitive.test(key)) u.searchParams.set(key, REDACTED); return u.toString(); } catch { return sanitizeText(input); }
}
export function sanitizeText(text: string): string {
  return text.slice(0, 16384)
    .replace(/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/-]+=*/gi, '$1 [REDACTED]')
    .replace(/((?:authorization|cookie|password|passwd|secret|[\w-]*token|api[_-]?key|session[_-]?id|csrf|xsrf)\s*["']?\s*[:=]\s*["']?)[^\s"'&,;}]+/gi, '$1[REDACTED]')
    .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, REDACTED)
    .replace(/\bsk-[A-Za-z0-9_-]{16,}\b/g, REDACTED);
}
export function sanitize(value: unknown, depth = 0): unknown {
  if (depth > 7) return '[OMITTED: depth limit]';
  if (typeof value === 'string') return /^https?:\/\//.test(value) ? sanitizeURL(value) : sanitizeText(value);
  if (Array.isArray(value)) return value.slice(0, 80).map(item => sanitize(item, depth + 1));
  if (value && typeof value === 'object') {
    const record = value as Record<string, unknown>;
    if (typeof record.name === 'string' && (sensitive.test(record.name) || /session/i.test(record.name)) && ('value' in record || 'binaryValue' in record)) return { name: sanitizeText(record.name), value: REDACTED };
    return Object.fromEntries(Object.entries(record).slice(0, 80).map(([key, v]) => [key, sensitive.test(key) ? REDACTED : sanitize(v, depth + 1)]));
  }
  return value;
}
export function bodyEvidence(body: string, mimeType: string, url: string, projectURL: string): Record<string, unknown> {
  try { if (new URL(url).origin !== new URL(projectURL).origin) return { omission: 'Response body outside configured page origin' }; } catch { return { omission: 'Response URL unavailable' }; }
  if (new TextEncoder().encode(body).length > 16384) return { omission: 'Response body exceeds 16 KiB limit' };
  if (!/json|text\/plain|javascript|text\/css/.test(mimeType)) return { omission: 'Binary or document body excluded; metadata retained' };
  try { return { body: JSON.stringify(sanitize(JSON.parse(body))), format: 'json' }; } catch { return { body: sanitizeText(body), format: 'text' }; }
}
