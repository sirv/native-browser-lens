# Native Browser Lens collector

A Manifest V3 Chrome extension for the native notebook. It sends evidence only to the registered local Native Messaging host; its extension-page CSP disallows network connections.

## Build and connect

```sh
npm ci
npm run build
npm test
```

Load `extension/dist` using **Load unpacked** in `chrome://extensions`. Register the native host using the extension ID shown on this extension's settings page and the application install script. The stable extension ID is `mfpclfngcgiahifebjbjlgagmlflcjpg` (derive with `node scripts/extension-id.mjs`). The host name is `studio.sirv.native_browser_lens`.

Add profiles in the native application. Open extension settings and press **Enable** for each project origin. Importing a profile or receiving one from the app never grants browser access by itself. Collection starts for existing matching tabs; it does not reload them. Incognito tabs are excluded.

Use the extension button, Control+Shift+L on Mac, or Alt+Shift+L on Linux to capture. Chrome's shortcuts page can change the binding. A `capture-started` message marks `initiatedBy:extension` or `initiatedBy:native` and creates durable pending metadata before acquisition and lets the app start native fallback capture. It must not focus the notebook. Pixels are captured before the final capture message opens the notebook. The native app can also request a capture by tab ID. A tab that cannot provide a browser screenshot returns an explicit omission for native ScreenCaptureKit fallback.

## Evidence and limits

- Each capture carries project, tab, window, document, time, and any observed build identity. Only the selected tab in the focused Chrome window has `active:true`; absent OS focus is never inferred. Main-document navigation replaces that tab's current document buffer. Late responses with an older document identity are discarded.
- At most 16 project tabs are armed. Each retains the last two minutes, capped at 256 events or 384 KiB, with explicit eviction coverage. The service worker checkpoints bounded evidence in `chrome.storage.session`, preserving it across worker suspension/restart. Browser termination ends uncommitted rolling history; saved observations live in the native store.
- Network evidence includes metadata, cache provenance, request IDs, available initiators, failures, and same-origin response bodies. Text/JSON bodies are limited to 16 KiB; binary, document, third-party, encoded, oversized, and unavailable bodies report omissions. Request payloads and cookie values are excluded.
- Console and exceptions retain bounded values and available stacks. Recursive child targets include iframes and workers. Frame probes use granted origins; inaccessible frames are explicitly incomplete.
- Storage snapshots contain bounded local/session storage, IndexedDB database names/versions, and CacheStorage names. Sensitive keys and nested credential values are redacted. Records and cache bodies require an explicit project adapter.
- A passive pointer listener records the clicked element's historical bounds, selector, and nearest `data-sirv-source` or `data-source` stamp. Fast visible-element probes bracket each screenshot, covering interactive and source-stamped candidates up to250 elements or48KiB. Snapshot context binds current element bounds and source metadata only when each connected element, document, source stamp, and viewport stay stable across capture. Replaced, hidden, moved, or mismatched elements produce a coverage gap; historical click evidence remains in the timeline. An explicit MAIN-world `window.__NATIVE_BROWSER_LENS__` getter or `script#native-lens-context[type="application/json"]` exposes bounded project diagnostics. A working-tree source label is preserved with `sourceBuildVerified:false`.
- Opening DevTools switches to its network API and DOM/storage probes with reduced-channel coverage. Closing DevTools reconnects deep capture. Canceling Chrome's debugger attachment banner leaves the tab detached until **Resume tab**.

The collector does not send background evidence to an AI provider. Native handling owns Markdown, image masks, selected cloud artifacts, investigation, filing review, and persisted observations.

## Real browser proof

```sh
npx playwright install chromium
npm run smoke
HEADED=1 DEVTOOLS=1 npm run smoke
SOAK_SECONDS=1800 npm run smoke
```

`CHROME_PATH` selects an existing Chrome for Testing executable. `HEADED=1` opens test windows. `OUTPUT_DIR` changes the evidence output directory; the default is `output/playwright`.

The smoke runner uses a temporary Chrome profile, two local fixture origins in distinct windows, a test-only exact-host permission manifest, and a real framed Native Messaging receiver registered only under that temporary profile. It removes its temporary registration/profile on exit. No default-profile manifest or browser preference is changed.

Assertions inspect the resulting native capture: real PNG bytes, expected failed response and exception, sanitized storage and response bodies, source stamp, project isolation, document navigation, pause/resume, and (with `DEVTOOLS=1`) DevTools network collection/navigation/deep reconnection. The fixture's transient menu is retained in the captured screenshot. Default-profile consent, ScreenCaptureKit permission and pixel geometry, and speech/device acceptance remain native integration checks.

The optional soak compares timer delay, request latency, page JS heap, checkpoint bytes and browser-process CPU/RSS with an uninstrumented local fixture in another browser. Both browsers use four pages in two windows; selected-tab state and visibility are recorded. Raw samples and limits are written to `soak-progress.json` and `soak-result.json`. Process RSS sums can count shared pages more than once; this is a shared-host fixture benchmark.

With `LENS_SOAK_APP=/absolute/path/to/release-folder` and `NATIVE_HOST_PATH` set to that release's `lens-host`, the soak also opens the actual GTK notebook on private fixture data. It captures about every 30 seconds, waits for persistence and a real Cairo canvas paint, and records notebook/native-host CPU/RSS, saved storage, helper peaks and capture-to-paint samples. Samples include time to helper startup, helper work, UI completion and the following paint, using timestamps from the actual helper and UI callbacks. Both progress and final results retain capture timings. Set `LENS_SOAK_SEED_REPORTS=60` to start with 60 additional valid portable reports imported from the fixture capture (maximum 200); these are private benchmark copies. Run this Linux variant inside Xvfb with the usual GTK dependencies. It excludes physical input, portal video, microphone and provider calls. Saved observations intentionally accumulate. This is not default-profile or physical-shortcut acceptance.

Set `NATIVE_HOST_PATH` to the compiled Swift `lens-host` executable to exercise the actual file mailbox, per-client stamping and filesystem-watched native capture command roundtrip in the temporary profile.
