# Native Browser Lens

A native Mac notebook for browser defects: capture a moment, annotate the frozen image, write or dictate Markdown, investigate selected evidence, and review a durable VibeQ submission.

This is a standalone repository. Sirv Studio and VibeQ are project adapters and integrations. The native UI follows VibeQ's cool neutral palette, indigo accent, typography, and compact operator surfaces. The upload disclosure is a native adaptation of [beUI's agent todo list](https://beui.dev/components/agents/todo-list), driven by actual preparation, attachment, submission, and receipt events.

## Local installation

Requires macOS 15+, Xcode's Swift toolchain, Node.js/npm, and Chrome. The build was verified on this Mac with the Xcode beta Swift 6.4 toolchain; an older-toolchain build is not yet verified.

```sh
npm --prefix extension ci
swift test
bash scripts/build-app.sh
python3 scripts/install-local.py
```

The installer copies the signed local build to `~/Applications/Native Browser Lens.app`, preserving an existing install as a timestamped backup. It registers only `chrome-extension://mfpclfngcgiahifebjbjlgagmlflcjpg/` with the Native Messaging host. This is an ad hoc development signature, not a notarized public release.

In Chrome, open `chrome://extensions`, choose **Load unpacked**, and select this repository's `extension/dist` folder. Open Lens and add projects in Settings. Enable a project and grant its exact origins in the extension's Options page. Existing tabs activate without a reload. Project profiles start disabled; microphone capture starts only when you press Dictate.

Use **⌘⌥⇧L** from Chrome to capture through the native app, or **Control+Shift+L** / the extension button to start in Chrome. Native capture opens the notebook after acquiring pixels. Choose a tab explicitly when its native window cannot be identified uniquely. The menu-bar indicator provides pause/resume and capture state.

## The notebook

- Start with a capture or a Markdown note. Multiple captures belong to one observation; a new observation always has a new identity, even on the same element.
- Draw rectangles, arrows, freehand marks, or opaque masks. Coordinates use the frozen image, independent of Retina scaling. DOM/source links require a stable matching capture, document, and tab. Native window images have separate geometry and no invented viewport mapping.
- Diagnostics retain two minutes locally. Optional video keeps a bounded 30-second window ring per selected project/tab identity. Recordings require an explicit review before export or filing and never enter AI requests.
- Put the OpenAI API key in Settings → AI. It is stored in Keychain. Model IDs are configurable; defaults are `gpt-live-transcribe` and `gpt-5.6-terra`. Voice uses 24 kHz PCM Realtime transcription. Interim speech stays outside the Markdown editor; completed speech appends to its original observation. Late AI drafts remain suggestions when the text has been edited.
- Local investigation works without a provider. Cloud investigation has an evidence-review step and includes only selected sanitized captures and reviewed notebook text. Mask private visual content before selecting an image. Source, tests, and documentation are read through bounded local tools; unmatched builds are explicitly labeled.
- Export creates a new portable folder containing Markdown, sanitized evidence JSON, reviewed PNG derivatives, and explicitly reviewed recordings. Raw images stay in the private local store.

## VibeQ

Configure the endpoint and a personal VibeQ token in Settings. Review the text, assignment, and attachments before filing. The client saves a frozen revision and submission ID before network traffic, verifies the authenticated member, reconciles earlier outcomes, and uploads only missing evidence. A timed-out request cannot silently get a fresh identity. Token rotation for the same member works; changing members cannot retry another member's uncertain submission.

Failed submissions retain the reviewed snapshot across restart. Retry that snapshot before editing an amendment. A confirmed receipt and its attachment coverage are separate states. New reviewed revisions update the same task; distinct observations remain distinct.

The ingestion backend is implemented in `/Users/veniaminkrachun/git/vibequeue-native-browser-lens` and **has not been deployed**. Existing production VibeQ will not accept this new contract until its migration and Worker release are completed. See [the exact ingestion contract](integrations/vibeq.md).

## Source and browser integration

[Studio setup](integrations/sirv-studio.md) documents the opt-in diagnostic bridge and existing source stamps. The bridge exposes bounded session/feature/cache metadata without query values or credentials. Development working-tree source is never treated as a verified deployed commit.

[Collector instructions](extension/README.md) document deep capture, DevTools handover, fixtures, and evidence limits. Chrome DevTools owns its debugger connection; Lens switches to reduced network/probe evidence and marks gaps instead of fighting it. Browser cache provenance, CacheStorage, app query cache, and correlated server logs remain separate sources.

## Storage and transport

SQLite and media live under `~/Library/Application Support/Native Browser Lens`. `LENS_DATA_DIR` overrides the location for isolated tests. Credentials are in the app's Keychain service, not in the database or export.

Native Messaging frames pass through private file queues awakened by macOS filesystem events. Capture envelopes are acknowledged only after the complete observation is saved. Unacknowledged starts, chunks, and captures replay after restart; status updates coalesce while the notebook is closed. Profile-specific host client IDs prevent overlapping Chrome tab numbers from sharing evidence.

## Verification

See [ACCEPTANCE.md](ACCEPTANCE.md) for measured proof, limits, and remaining live checks. Tests and local installation do not constitute acceptance of the complete personal workflow.

Official API references: [Chrome debugger](https://developer.chrome.com/docs/extensions/reference/api/debugger), [DevTools network](https://developer.chrome.com/docs/extensions/reference/api/devtools/network), [Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/), [Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription), [Responses function calling](https://developers.openai.com/api/docs/guides/function-calling).
