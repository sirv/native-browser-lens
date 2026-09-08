# Sirv Studio diagnostic bridge

The local Studio checkout at `/Users/veniaminkrachun/.codex/worktrees/8b53/sirv-studio` now contains an opt-in development bridge. Start Studio with `VITE_SIRV_STUDIO_NATIVE_BROWSER_LENS=1`; no property is installed in production or in an unarmed development session. This name uses Studio's existing `VITE_SIRV_STUDIO_` client environment prefix.

The collector reads `window.__NATIVE_BROWSER_LENS__` in the page's main JavaScript world. It is a read-only getter object, not an executable command interface. It supplies:

- `version: 1`.
- `build: {commit?,environment:"development",sourceState:"working-tree"}`. A commit appears only for a full 40-character SHA. Development builds may contain uncommitted code, so this is a reference commit rather than proof of exact source equivalence.
- `session: {status,organizationSelected,sirvConnected,shopifyConnected,hasResourceRestrictions}`. Identities, tenant names, tokens, cookies, permissions, and account values are excluded.
- `featureFlags: {dataGridVirtualizerDisabled}`, from Studio's canonical public-environment getter.
- `queryCache: {total,omitted,queries}`. At most 100 entries expose a known family label or `other`, query and fetch status, invalidation, update timestamps, and observer count. Query hashes, key arguments, cached records, exception contents, and responses are excluded.

The getter reads the actual mounted TanStack Query client and current auth context. It takes a fresh snapshot on each read and does not fetch, invalidate, or mutate the application cache. Unmount and session transitions remove stale installations. The app loads the adapter through a development-only dynamic import, keeping its code outside production bootstrap.

Element attribution remains separate: Studio's existing Vite transform stamps `data-sirv-source="relative/path:line:column"`. The collector binds that stamp only to a matching capture identity. Application-cache coverage does not imply access to HTTP cache entries, service-worker cache bodies, or server caches.

Local verification: 13 focused tests passed, including the existing provider tests; the edit and final session gates passed on all five changed files. The production build and public-bootstrap leak guard passed, and production browser JavaScript contains no diagnostic bridge module or getter. Gate log: `/tmp/native-lens-studio-gate-session-final.log`; build log: `/tmp/native-lens-studio-build.log`.

A real isolated Chrome session at `http://127.0.0.1:3993/` read the version-1 getter from the mounted Studio app, verified its read-only descriptor, and observed unauthenticated session metadata and an empty query cache. The snapshot carried commit `e82995e1f1d4a47dfe711b96a30e2750dad8aa86` with `sourceState: working-tree`. The same page contained 684 source-stamped elements. Browser proof: `/tmp/native-lens-studio-browser-proof.json`; source-stamp proof: `/tmp/native-lens-studio-source-proof.json`. The isolated browser session and local server were closed after verification. This does not prove an authenticated capture or deployed integration.
