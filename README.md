# Native Browser Lens

A native notebook for browser defects on macOS and Linux: capture a moment, annotate the frozen image, write Markdown or dictate, investigate selected evidence, and review a durable VibeQ submission.

This is a standalone repository. Sirv Studio and VibeQ are project adapters and integrations. The macOS UI follows VibeQ's cool neutral palette, indigo accent, typography, and compact operator surfaces. The upload disclosure is a native adaptation of [beUI's agent todo list](https://beui.dev/components/agents/todo-list), driven by actual preparation, attachment, submission, and receipt events.

## Local installation

For Linux build, installation, verification and feature limits, see [Linux support](LINUX.md) and [feature parity](LINUX_PARITY.md). Linux includes Tokyo Night Storm dark mode, Tokyo Night Day light mode and a follow-system option.

The Linux release installer bundles the Swift runtime, Codex CLI and offline English dictation. Use `sh native-browser-lens-0.10.3-linux-x86_64.run`, choose **Install and open Lens**, then follow **Browser setup** on first installation. Missing desktop components use the system package manager and authorization dialog. No Swift or Node.js installation is required. AI investigation uses the existing Codex ChatGPT sign-in; **Settings → Sign in with ChatGPT** connects a new account. The installer registers native hosts for Chrome/Chromium and Firefox and copies their collector folders; Chrome still requires **Load unpacked** and explicit project-origin approval. Updates and verified local release installation are under **Notebook → App updates**. The local release artifacts are prepared; no public Linux release or Chrome Web Store listing has been published. Firefox setup loads the separate collector temporarily; permanent installation needs Mozilla signing. Its limited mode includes network metadata, actions, page state and toolbar-action screenshots, with explicit debugger-channel gaps. [Store handoff](extension/STORE.md) records the publication and extension-identity steps.

The macOS build requires macOS 15+, Xcode's Swift toolchain, Node.js/npm, and Chrome. The build was verified on this Mac with the Xcode beta Swift 6.4 toolchain; an older-toolchain build is not yet verified.

```sh
npm --prefix extension ci
swift test
bash scripts/build-app.sh
python3 scripts/install-local.py
```

The installer copies the signed local build to `~/Applications/Native Browser Lens.app`, preserving an existing install as a timestamped backup. It registers only `chrome-extension://mfpclfngcgiahifebjbjlgagmlflcjpg/` with the Native Messaging host. This is an ad hoc development signature, not a notarized public release.

In Chrome, open `chrome://extensions`, choose **Load unpacked**, and select this repository's `extension/dist` folder. Open Lens and add projects in Settings. Enable a project and grant its exact origins in the extension's Options page. Existing tabs activate without a reload. Project profiles start disabled; microphone capture starts only when you press Dictate.

On macOS, use **⌘⌥⇧L** from Chrome to capture through the native app, or **Control+Shift+L** / the extension button to start in Chrome. On Linux, use **Alt+Shift+L** / the extension button, **Capture tab**, or configure a desktop shortcut in Settings. Native capture opens the notebook after acquiring pixels. Choose a tab explicitly when its native window cannot be identified uniquely. The menu-bar/tray indicator provides pause/resume and capture state.

## The notebook

- Start with a capture or a Markdown note. Multiple captures belong to one observation; a new observation always has a new identity, even on the same element.
- Draw rectangles, arrows, freehand marks, or opaque masks. Coordinates use the frozen image, independent of Retina scaling. DOM/source links require a stable matching capture, document, and tab. Native window images have separate geometry and no invented viewport mapping.
- Diagnostics retain two minutes locally. Optional video keeps a bounded 30-second window ring per selected project/tab identity. Recordings require an explicit review before export or filing and never enter AI requests.
- On Linux, AI reports use Codex with the existing ChatGPT subscription. Only the reviewed evidence is sent; tools are disabled and the raw notebook store is denied to the report process. English dictation runs locally with the bundled Whisper model after **Finish dictation**; audio is bounded to two minutes in memory. Completed speech appends to its original observation. AI report suggestions preserve manual edits. The macOS app retains its original Keychain/API integration.
- Local investigation works without a provider. Cloud investigation has an evidence-review step and includes only selected sanitized captures and reviewed notebook text. Mask private visual content before selecting an image. Source, tests, and documentation are read through bounded local tools; unmatched builds are explicitly labeled.
- Export creates a new portable folder containing Markdown, sanitized evidence JSON, reviewed PNG derivatives, and explicitly reviewed recordings. Raw images stay in the private local store.

## Debug with an agent

Linux adds a linked failure timeline under **Evidence**, structured failure-first Codex input with an omission preview, and commit-matched stack source maps. **Diagnostics** imports HAR, Playwright trace ZIPs, CPU profiles and before/after verification results. Raw files remain local until separately reviewed for export or filing; screenshots masks do not redact those files.

Export a reviewed observation, then query it without opening the private notebook:

```sh
native-browser-lens evidence /path/to/export inspect
native-browser-lens evidence /path/to/export timeline CAPTURE_ID
native-browser-lens evidence /path/to/export event EVENT_ID
native-browser-lens evidence /path/to/export stack EVENT_ID
```

**Create reproduction handoff** selects a captured HTTP failure and an explicit expected success status. It exports an editable Playwright workflow; an agent reviews and fills its exact steps, reproduces the failure, fixes the application, runs the same steps again and imports both results. Lens compares the condition, steps, script and observed statuses. The runner requires Node/Playwright in the agent's workspace; the desktop app does not. It uses an isolated browser, so authenticated reproductions need their own reviewed authentication setup. See [debugging workflow and boundaries](DEBUGGING.md).

## VibeQ

Configure the endpoint and a personal VibeQ token in Settings. Review the text, assignment, and attachments before filing. The client saves a frozen revision and submission ID before network traffic, verifies the authenticated member, reconciles earlier outcomes, and uploads only missing evidence. A timed-out request cannot silently get a fresh identity. Token rotation for the same member works; changing members cannot retry another member's uncertain submission.

Failed submissions retain the reviewed snapshot across restart. Retry that snapshot before editing an amendment. A confirmed receipt and its attachment coverage are separate states. New reviewed revisions update the same task; distinct observations remain distinct.

The ingestion backend and migration 0070 are deployed at `https://work.sirv.studio` from commit `4f710861`. CI artifact verification, live checks and all three production capture tables are verified. An authenticated, explicitly reviewed native-client production filing remains separate acceptance work. See [the exact ingestion contract and release evidence](integrations/vibeq.md).

## Source and browser integration

[Studio setup](integrations/sirv-studio.md) documents the opt-in diagnostic bridge and existing source stamps. The bridge exposes bounded session/feature/cache metadata without query values or credentials. Development working-tree source is never treated as a verified deployed commit.

[Collector instructions](extension/README.md) document deep capture, DevTools handover, fixtures, and evidence limits. Chrome DevTools owns its debugger connection; Lens switches to reduced network/probe evidence and marks gaps instead of fighting it. Browser cache provenance, CacheStorage, app query cache, and correlated server logs remain separate sources.

## Storage and transport

On macOS, SQLite and media live under `~/Library/Application Support/Native Browser Lens`. On Linux they use `$XDG_DATA_HOME/native-browser-lens` (default `~/.local/share/native-browser-lens`). `LENS_DATA_DIR` overrides the location for isolated tests. Credentials are in Keychain on macOS and Secret Service on Linux, not in the database or export.

Native Messaging frames pass through private file queues awakened by filesystem events (vnode notifications on macOS, inotify on Linux). Capture envelopes are acknowledged only after the complete observation is saved. Unacknowledged starts, chunks, and captures replay after restart; status updates coalesce while the notebook is closed. Profile-specific host client IDs prevent overlapping Chrome tab numbers from sharing evidence.

## Verification

See [ACCEPTANCE.md](ACCEPTANCE.md) for measured proof, limits, and remaining live checks. Tests and local installation do not constitute acceptance of the complete personal workflow.

Official API references: [Chrome debugger](https://developer.chrome.com/docs/extensions/reference/api/debugger), [DevTools network](https://developer.chrome.com/docs/extensions/reference/api/devtools/network), [Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/), [Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription), [Responses function calling](https://developers.openai.com/api/docs/guides/function-calling).
