import { build } from 'esbuild';
import { mkdir, cp } from 'node:fs/promises';
await mkdir('dist', { recursive: true });
await build({ entryPoints: ['src/background.ts', 'src/devtools.ts', 'src/options.ts'], outdir: 'dist', bundle: true, format: 'esm', target: 'chrome125', sourcemap: true });
await cp('public', 'dist', { recursive: true });
console.log('Load unpacked extension from extension/dist in chrome://extensions.');
