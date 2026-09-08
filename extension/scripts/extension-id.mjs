import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
const manifest = JSON.parse(await readFile(new URL('../public/manifest.json', import.meta.url), 'utf8'));
if (!manifest.key) throw new Error('Manifest is missing stable public key');
const bytes = createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest().subarray(0, 16);
console.log([...bytes].map(byte => String.fromCharCode(97 + (byte >> 4), 97 + (byte & 15))).join(''));
