# Linux

The Linux notebook uses GTK 4 and the same Swift LensCore, SQLite format, Chrome collector and Native Messaging protocol as the macOS app. It runs under Wayland and X11. The macOS SwiftUI app remains a separate build target.

## Install the prebuilt app

Run `sh native-browser-lens-0.10.3-linux-x86_64.run` and choose **Install and open Lens**. Running it with `sh` avoids a separate executable-permission step after download. The archive also includes `Install.sh`, or use `python3 install.py --launch` for a terminal. The self-extracting installer checks its payload checksum; the installer verifies the release manifest, CPU architecture and desktop dependencies before replacing the app. Swift, its runtime, Codex and the English dictation engine/model are bundled. No Swift or Node.js installation is required for the prebuilt app.

Installation is per user. On a desktop, the `.run` and `Install.sh` entry points can request missing Python/GTK components through `pkexec` and the host package manager before opening the installer. Canceling authorization preserves the installed app. **Install desktop components** offers the same package setup inside the graphical installer. If the desktop has no authorization helper, install the printed packages in a terminal first. Native Chrome/Chromium or Firefox, a running desktop session and a window-capable XDG portal are needed for their respective integrations.

The precompiled candidate passes fresh Ubuntu 24.04 and Fedora 44 container checks without installed Swift or Node.js: verified install/update/rollback, notebook preservation, the GTK workflow including actual H.264 playback, and bundled offline speech recognition. Fedora's official OpenH264 encoder uses its supported baseline profile; its playback path also needs `h264parse`, the Cairo typelib and the OpenGL ES runtime. The dependency checks and package lists cover those requirements. Container checks do not establish physical portal, microphone or compositor behavior. See [reproducible distro checks](linux/tests/containers/README.md).

**Browser setup** opens on first installation. Updates open the main notebook; use **Browser setup** when you need to reload or configure a collector. Enter a project URL, click **Open browser extensions**, turn on Chrome's Developer mode, choose **Load unpacked**, and paste the copied folder. Then use **Open project permissions** to approve the exact origin and open the project site. The wizard shows connection, collector-version and ready-tab state and offers a test capture. Each browser profile requires its own load and approval. Chrome does not permit an unsigned user installer to silently install an extension or grant site access; no browser preferences or security policies are changed.

AI reports use the existing Codex ChatGPT sign-in. Settings provides **Sign in with ChatGPT** and a connection check. Lens invokes the bundled CLI with tools, user configuration and rules disabled, denies access to the private notebook store, and supplies only reviewed evidence and copied reviewed images in an ephemeral workspace. No API key is needed and Lens never reads or copies Codex tokens. Subscription allowance and network access still apply to report generation.

**Notebook → App updates** checks GitHub on demand and offers verified release downloads or installation from an extracted release folder. Downloads require the repository's GitHub asset SHA-256 digest and are checked before extraction and again before install. There is no automatic network check. Public Linux release assets and a Chrome Web Store listing have not been published. The local `.run`, `.tar.gz`, extension ZIP and checksum files are in `dist/releases/`.

Installers stage the replacement before requesting a normal save and quit. Busy jobs, dictation or open review/settings dialogs prevent replacement. The previous app build and registrations are retained, and ordinary write failures roll back the replacement. Restore the previous app build with `python3 install.py --rollback --launch`; the notebook is preserved.

## Build from source

Requirements: Swift 6+, Node.js/npm, Python 3 with PyGObject and Pycairo, GTK 4, SQLite, OpenSSL, `pkg-config`, Chrome or Chromium. Media requires GStreamer with PipeWire, PulseAudio, JPEG, video conversion and appsink plugins, FFmpeg with libx264, libportal's Xdp typelib, and a running XDG desktop portal with window capture support. The tray helper requires GTK 3 and the AyatanaAppIndicator3 typelib; it runs separately from GTK 4. `secret-tool` and an unlocked Secret Service keyring are required for VibeQ credentials. Codex manages its own ChatGPT sign-in; dictation runs offline. Local capture, notes, investigation and export work without credentials.

On this Manjaro host, Swift is provided by `swift-bin`. The base packages are `gtk4 python-gobject python-cairo sqlite openssl pkgconf libsecret`. Media/tray packages include `gstreamer gst-plugins-base gst-plugins-good gst-plugin-pipewire gst-libav ffmpeg libportal libsoup3 libayatana-appindicator`; install the portal backend for your desktop too. Swift and package names vary by distribution. On Debian/Ubuntu, install a Swift toolchain and the corresponding development packages and GI typelibs, including GTK's GStreamer media backend for video review. Install Node.js/npm separately if needed. The build checks the required typelibs, GStreamer elements and encoder.

```sh
npm --prefix extension ci
swift test
python3 -m unittest discover -s linux/tests
bash scripts/build-app.sh
python3 scripts/install-local.py
~/.local/bin/native-browser-lens
```

The Linux installer copies the app and collector into `$XDG_DATA_HOME/native-browser-lens/app` (default `~/.local/share/native-browser-lens/app`), creates an application-menu entry and `~/.local/bin/native-browser-lens`, and registers the host for Google Chrome, Chromium and the exact Firefox add-on ID. It preserves previous app builds and registrations as timestamped backups. No root access is required for the app files and browser registration. This source build requires the installed Swift runtime libraries. Build a self-contained release with `python3 scripts/package-linux.py`; the first release build also needs Git, CMake and a C++ compiler to build the pinned Whisper helper and download its checksummed model.

Open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select the installed `app/extension` directory printed by the installer. The stable ID is `mfpclfngcgiahifebjbjlgagmlflcjpg`. In Lens Settings, add a project name, exact origins and optional repository directory; enable capture and save. Then grant each project's origins in the extension Options page. No browser preferences or site permissions are granted by installation.

Keep the notebook running while working. Use the extension button or **Alt+Shift+L** in the browser to capture and reveal the notebook after saving the image. Alternatively select a connected tab in Lens and press **Capture tab**. Select an observation to add a capture to it, or use **New note** to start another observation. Press **Save note** / **Ctrl+S** to save text. Unsent capture envelopes remain on disk while the notebook is closed and replay when it opens.

Notes also autosave after a short pause in typing. Failed saves retain the editable draft; closing or quitting cannot silently discard it. Search and project selection filter the observation history. Investigation returns an editable suggested report without replacing manual notes; **Use this draft** applies it explicitly.

**Browser setup** distinguishes a missing collector from a connected profile with no matching project tabs. It provides the installed extension folder and opens the correct browser's extensions/options pages. Only configured, enabled origins appear in the tab picker. A host registration alone cannot discover tabs. Standard ports, host casing and trailing origin slashes are normalized to Chrome's origin format.

Settings provides **Tokyo Night Storm**, **Tokyo Night Day** and **Follow system**. The app styles its own GTK windows and leaves desktop theme files unchanged. Palettes are adapted from [Tokyo Night](https://github.com/folke/tokyonight.nvim), with secondary text and light-mode blue adjusted for normal-text contrast.

**Set desktop capture shortcut** uses the XDG GlobalShortcuts portal. On desktops that do not assign a key (including the checked [Hyprland portal](https://github.com/hyprwm/xdg-desktop-portal-hyprland/blob/v1.4.1/src/portals/GlobalShortcuts.cpp)), bind a shortcut in the compositor to `gapplication action studio.sirv.NativeBrowserLens capture`. Lens reports registration separately from a reported keybinding. The browser's **Alt+Shift+L** remains available. In Lens, **Ctrl+N**, **Ctrl+S**, **Ctrl+Alt+D**, **Ctrl+Shift+E** and **Ctrl+,** create, save, dictate, export and open settings.

After updating, reload the unpacked extension in `chrome://extensions` so it reports the selected tab. For native fallback, select the target tab in Chrome, choose it in Lens, press **Share window**, and choose that browser window in the system dialog. Some portal choosers also offer displays despite the window-only request; Lens rejects those choices. Capture normally; the browser PNG is preferred, with a recent native frame used only if it is unavailable. Native images include browser chrome and do not use DOM annotation bindings.

For video, allow the local video ring for the project in Settings, then press **Rolling video** and share its browser window. Lens holds at most 30 seconds / 48 MiB in memory at 5 fps and at most 1440×900. A capture saves the preceding frames as a private MP4 without audio. **Review video** opens playback and an explicit review checkbox; only reviewed recordings enter exports or VibeQ attachments. Video never enters AI requests. Sharing stops and clears the ring when the tab/document/profile/title changes, collection pauses, or the project is disabled. The portal window is user-selected; Lens cannot independently prove that it belongs to the collector's tab, and records that coverage limit.

For English dictation, select an observation and press **Dictate**. The app holds up to two minutes of 16 kHz mono audio in memory. **Finish dictation** runs the bundled Whisper base.en model locally and appends the completed text to the original observation, even if another note is selected. Transcription happens after recording, without an API request or an audio file. A transcript that cannot be inserted is retained for explicit recovery. The desktop's default PulseAudio/PipeWire input is used. Physical microphone quality remains to be checked; automated recognition uses synthetic speech. The current Codex realtime interface rejected subscription authentication in a separate no-audio probe, so Linux dictation uses the local engine.

On desktops with a StatusNotifier tray host, Lens shows capture, pause, open and quit controls plus recording/dictation state. Closing the notebook hides it to the tray; **Quit Lens** stops capture and exits after notes and dictation are settled. Without a tray host, the window remains the main control surface.

## Available behavior and limits

- Browser PNG capture, diagnostic evidence, multiple projects/profiles, pause/resume and explicit tab selection.
- Autosaved Markdown notes, observation search and project filtering, rectangle/arrow/pen annotations, opaque masks, annotation undo and portable sanitized exports. Private originals remain local. Annotations use the frozen image coordinates. The shared spatial resolver binds annotations only to stable source-stamped elements from the same frozen capture.
- Local investigation with source links and report suggestions, reviewed cloud investigation with explicit capture selection, and reviewed VibeQ filing with member/owner selection, actual progress, durable recovery and amendments. Changed review versions are rejected before sending. The tracker token uses Secret Service, with no plaintext fallback; Codex keeps its own managed ChatGPT login. The VibeQ backend must implement the contract in `integrations/vibeq.md`; no production filing is implied by the local tests.
- Voice dictation, rolling video, a tray indicator and native window screenshot fallback. Native capture depends on desktop portal support and explicit sharing; unavailable screenshots retain a visible coverage gap. Desktop shortcut registration is available through the portal or a compositor binding.
- The installer supports native Google Chrome, Chromium and Firefox. Sandboxed Flatpak/Snap browsers need a compatible native-messaging portal/proxy. The checked Zen Flatpak 1.21.5b has only the older WebExtensions portal client, while this host has neither that portal nor a NativeMessagingProxy service. A proxy package alone cannot fix the missing browser-side proxy client. See [Mozilla’s transport design](https://firefox-source-docs.mozilla.org/toolkit/components/extensions/webextensions/native-messaging-portal-design.html) and the current inspection in [GAPS.md](GAPS.md). A supported sandbox/browser transport must pass a real native-host capture before it is advertised as supported.

Storage is `$XDG_DATA_HOME/native-browser-lens`, defaulting to `~/.local/share/native-browser-lens`. `LENS_DATA_DIR` selects an isolated notebook for tests. Inbox processing is event-driven: GIO monitors the notebook inbox; the host uses inotify. Starts and chunks are acknowledged only after the complete observation and image are saved. Invalid envelopes are retained in a private diagnostic artifact before acknowledgement.

## Verification

Current 0.10.3 checks on 2026-10-17 pass 52 Swift, 15 collector and 42 Python tests, a clean source review, fresh Ubuntu/Fedora package workflows, real Chromium/Firefox native-host capture and installed Wayland launch. All 141 installed files verify and the current observation/twelve artifacts match their pre-install hashes. Earlier real Wayland portal/PipeWire, tray/DBusMenu and default-profile capture evidence remains separately recorded in [the feature parity record](LINUX_PARITY.md). Local filing/recovery uses actual isolated Secret Service and workerd/D1/R2; production filing remains open. The installed bundle also passed synthetic speech → reviewed Codex text/image reporting with a source-build gap retained in 9.49 seconds. This single sample excludes physical input and human review and is not a p95 claim. The frozen bundle also completed a 30-minute fixture with 69 captures: 355.34 ms median, 392.04 ms p95 and 552.26 ms maximum capture-to-paint (one sample over 500 ms). [GAPS.md](GAPS.md) records the full samples and physical-input/resource-measurement limits.

```sh
swift test
python3 -m unittest discover -s linux/tests
GDK_BACKEND=x11 GTK_THEME=Adwaita GTK_A11Y=none GIO_USE_VFS=local GSK_RENDERER=cairo \
  xvfb-run -a -s '-screen 0 1440x1100x24' dbus-run-session -- python3 linux/tests/smoke.py
python3 linux/tests/tray_smoke.py  # Requires a running StatusNotifier host.
python3 linux/tests/portal_smoke.py  # Choose only the synthetic "Lens capture test" window.
npm --prefix extension test
npm --prefix extension run build
cd extension
NATIVE_HOST_PATH="$(cd .. && swift build --show-bin-path)/lens-host" \
  CHROME_PATH=/usr/bin/chromium OUTPUT_DIR=../.build/linux-browser-smoke npm run smoke
```

The GTK smoke additionally requires Xvfb and ImageMagick. It exercises project configuration, notes, local investigation, inbox-triggered captures, masks, native fallback, saved rolling video, reviewed/unreviewed exports, transcript routing, settings and review windows. The browser smoke uses an isolated profile, real native-host framing and inotify command delivery. It does not prove default-profile consent, production VibeQ requests, physical microphone quality or macOS behavior. Test screenshots and logs stay under ignored `.build/`.

## Apple compatibility projects checked on 2026-10-17

- [QuillUI](https://github.com/Lore-Hex/QuillUI) is the closest source-compatibility approach: SwiftUI/AppKit source rebuilt for GTK or Qt. At `006b072e38158a15ff39554d6acde2b839a964ab`, a focused SwiftUI target build with Swift 6.4.1 failed with a circular dependency between `Observation` and `FoundationEssentials`. Its [coverage ledger](https://github.com/Lore-Hex/QuillUI/blob/main/docs/apple-package-function-coverage.md) lists file dialogs as fallbacks, audio-engine I/O as incomplete and keychain items as process-local. No ScreenCaptureKit implementation was found in this checkout.
- [SwiftOpenUI](https://github.com/codelynx/SwiftOpenUI) provides SwiftUI-compatible controls through GTK 4. Its HelloWorld example compiled at `4afcacda74dec9e0bae18403c4427b05c8586943` on this Linux host. Its [feature matrix](https://github.com/codelynx/SwiftOpenUI/blob/develop/docs/architecture/swiftui-parity-matrix.md) describes incomplete API behavior. It does not provide the Apple platform services Lens uses.
- [SwiftCrossUI](https://github.com/moreSwift/swift-cross-ui) has a native GTK backend, but explicitly does not promise exact SwiftUI API compatibility.
- [Darling/VibeDarling](https://github.com/VibeDarling/darling) targets macOS binary execution. The [September GUI status report](https://github.com/darlinghq/darling/discussions/1563) describes only a handful of usable apps and ongoing SwiftUI rendering work. It was not installed or tested for Lens.
- [OpenSwiftUIProject/OpenSwiftUI](https://github.com/OpenSwiftUIProject/OpenSwiftUI) currently documents Linux stdout rendering without desktop UI integration. [helbertgs/OpenSwiftUI](https://github.com/helbertgs/OpenSwiftUI) is a separate OpenGL-based implementation, not the same project; its compatibility with Lens was not tested. [Tokamak](https://github.com/TokamakUI/Tokamak) primarily documents browser/Wasm rendering and is seeking maintainers.

These projects can reduce some UI porting work. None established an unchanged, working Lens application in these checks, so the Linux notebook uses GTK directly and retains the shared Swift core.

## Notebook management and evidence

Archive and Trash are separate history scopes. Restore returns an observation to its prior archive state. **Storage and backups** shows storage totals, creates a private checksummed backup, and offers reviewed full restore with an automatic safety backup and crash recovery. Portable report import creates a new local observation, preserving evidence and baked image masks without reusing old filing receipts or overwriting notes. Backup folders exclude credentials, the app and browser queues; protect them as private evidence.

Permanent deletion requires a reviewed Trash selection and unchanged edit versions. Pending filings cannot be deleted. Optional age and size limits apply only to Trash and are disabled by default. Active and archived notes are preserved. Backups provide manual transfer between machines; concurrent cloud sync is not implemented.

The evidence pane includes filterable console messages and request timelines, available durations, failure/body/header details, and capture coverage. Missing request starts or completions remain explicit; the viewer does not invent timings. Raw sanitized evidence remains available.

## Firefox

Choose Firefox in Browser setup. Open **about:debugging → This Firefox → Load Temporary Add-on** and select the copied `extension-firefox/manifest.json` path. This unsigned collector lasts until Firefox restarts. A permanent install requires [Mozilla signing](https://support.mozilla.org/en-US/kb/add-on-signing-in-firefox); the release includes an explicitly unsigned XPI for that workflow. Lens leaves signature checks enabled.

Use **Open project permissions** to open the connected collector's settings in the correct profile. Firefox does not restrict host grants by port; the permission button describes the wider host grant before approval. Lens still observes only the configured exact project origins, and Firefox page probes use only the main frame. The default project/permissions files grant no browser access automatically.

Firefox's limited mode captures granted webRequest metadata, main-frame actions and page/storage context. It records explicit gaps for unavailable debugger console/worker channels, response bodies and detailed cache provenance. No response stream is intercepted or modified. The collector toolbar button grants activeTab and captures a PNG; native-app requests without that grant use an explicit omission or separately approved native window fallback. The real Firefox UI, PNG/DOM binding, two-project isolation, navigation replacement and notebook persistence passed in a fresh test profile with synthetic pages.

```sh
GDK_BACKEND=x11 xvfb-run -n 213 -s '-screen 0 1440x1100x24' \
  python3 extension/scripts/firefox-smoke.py --headed \
  --host dist/releases/native-browser-lens-0.10.3-linux-x86_64/lens-host \
  --extension dist/releases/native-browser-lens-0.10.3-linux-x86_64/extension-firefox
```

The Firefox smoke uses the installed Firefox executable, its built-in Marionette testing protocol, an isolated profile/home, test-only localhost host grants and the real bundled native host/service. It never opens the user's Firefox profile. It checks the configured shortcut but uses the toolbar action for screenshot acceptance; physical shortcut timing is not proven.

On the checked Hyprland desktop, Ctrl+Alt+Shift+L is now configured in the active Lua user keybind file with a timestamped backup. Compositor reload and binding readback passed; a physical keypress was not tested. The app's portal shortcut control is separate from bindings in desktop configuration. To remove the manual Hyprland binding, remove its named `Capture browser evidence in Native Browser Lens` line from `~/.config/hypr/UserConfigs/user_keybinds.lua` and reload the compositor.

## Incident debugging (since 0.9.0)

Evidence → Timeline links same-request and explicit trace identifiers while labeling nearby events as context. Review for AI includes an exact bounded selection preview and omission counts. Local investigation can resolve stack frames through maps stored in the captured commit. Diagnostics creates a reviewed HTTP reproduction handoff and imports HAR, trace ZIP, CPU profile and before/after results. Exported evidence is queryable through `native-browser-lens evidence --help`; agents receive portable reviewed reports, not private notebook access. [DEBUGGING.md](DEBUGGING.md) has the workflow, proof and format limits.
