# Linux feature parity

Checked against `Sources/NativeLens` on 2026-10-17. GTK replaces the macOS UI and desktop services; LensCore, collector, storage and reviewed filing remain shared. The base implementation is landed in private origin/main at `5a64f7d`; public desktop/store distribution remains separate. The VibeQ backend release is recorded in `integrations/vibeq.md`.

| macOS feature | Linux implementation | Verification |
|---|---|---|
| Project profiles and exact browser origin grants | Project settings, canonical origins, repository chooser, adapters, documentation/log paths, ownership mappings, explicit browser setup | Swift origin tests, service tests, GTK settings workflow, live Chrome connection |
| Multiple projects, profiles and observations | Project filtering, observation search, independent capture/client/document identities | Core isolation tests, two-window Chromium smoke, GTK project switching |
| Editable notebook with retained work | Debounced autosave, explicit save, retained drafts after storage failure, safe quit | GTK failure/retry and autosave checks |
| Browser capture before notebook reveal | Native-host capture requests, durable inbox replay, browser PNG first | Real installed Chrome capture: 1912×1021 PNG, 103 events; isolated native-host smoke |
| Native screenshot fallback | Window-only XDG portal/PipeWire, recent frozen frame, separate native coordinates | Real Wayland fixture window, GStreamer/GTK workflow |
| Rectangle, arrow, pen, mask and undo | Frozen-image geometry, private originals, burned masks, shared source binding | Annotation/core tests, GTK masked export |
| Evidence and findings navigation | Filterable console, request timelines and details, explicit missing timing, coverage, raw JSON, typed findings and source links | Helper tests and GTK structured-evidence workflow |
| Local and reviewed Codex investigation | Shared bounded tools, managed ChatGPT login, reviewed text/capture IDs and edit version, tools disabled, raw store denied, separate report suggestion | Live subscription text/image report; core Codex failure/isolation tests; stale-review rejection and GTK draft workflow |
| Agent evidence and autonomous fix | Local stdio MCP over reviewed exports; reviewed subscription repair in private worktrees with frozen before/baseline/after checks | Actual Codex MCP client and collector-to-source decimal-price repair; fresh patch application, dirty source/manual-note preservation and sandbox canaries |
| Dictation | Bundled offline English Whisper, bounded in-memory 16 kHz PCM, explicit microphone start, original-observation routing and retained failed insertion | Real synthetic speech recognition, GStreamer PCM fixture, cancellation/stale completion and GTK routing tests |
| Bounded rolling video | User-approved window, 30 s / 48 MiB / 150 frames in memory, H.264 MP4, review before export/filing | Real GStreamer frames, FFmpeg/ffprobe, reviewed/unreviewed export |
| Tray status and controls | Separate GTK 3 helper, open/capture/pause/settings/quit, truthful connection state | Live StatusNotifier + DBusMenu registration, state, action and shutdown |
| Global capture | Standard GlobalShortcuts portal; focused-tab GApplication action for compositor bindings; Chrome's shortcut also works | D-Bus binding/activation/session isolation tests and real installed capture action |
| Appearance preference | Tokyo Night Storm, Tokyo Night Day, follow-system mode, persisted choice, local GTK styling | CSS parser and text-contrast tests; full and compact screenshots |
| Reviewed VibeQ filing and amendments | Frozen review, member list/owner suggestions, actual progress, durable receipt, retry and amendment state | Core recovery tests; isolated real Secret Service and HTTP smoke with interrupted response, restart recovery, no duplicate task/uploads and preserved edits |
| Portable export | Sanitized Markdown/JSON, reviewed PNG derivatives and reviewed video | Core export tests and GTK workflow |
| Secret storage | Secret Service, explicit removal, no plaintext fallback | Real isolated keyring store/read/remove in filing smoke |

## Agent workflow 0.11.0

[The current agent acceptance record](ACCEPTANCE.md#linux-0110-agent-acceptance) covers the bundled Codex runtime, hoisted dependencies, fresh patch application and private-network verification. MCP reads explicit exports; it does not expose the notebook or browser controls. Automatic fix verification currently covers same-origin HTTP conditions in a fresh local browser.

## Historical 0.10.4 delivery verification

Installed 0.10.4 passes 52 Swift, 45 Linux and 15 collector tests, clean final review, full GTK setup and fresh Ubuntu/Fedora delivery checks. Native Firefox and Firefox 158 Flatpak/NativeMessagingProxy complete actual native-host captures; proxy modes 1 and 2 both pass. The setup wizard detects Firefox Flatpak and prepares one complete private XPI, with explicit host/permission/preference instructions. The clean collector source rebuild matches all fifteen files in each frozen output tree. Version 0.10.4 is installed and running. All 141 installed files verify; the current observation and twelve artifacts match their pre-install hashes exactly. The actual Chrome profile reports one active/selected deep project tab. Proof is `.build/flatpak-v0104-install-verification.json` and `live-status.json` under that prefix. Reload the unpacked collector in `chrome://extensions` after the app update; this session has no enabled browser automation surface for that UI action.

The frozen 0.10.4 bundle completed 1800.73 seconds with sixty seeded reports and 69 measured captures: ten consecutive requests awaited through GTK paint and 59 periodic captures. Capture-to-paint median was 358.67 ms, p95 387.72 ms and maximum 439.34 ms; no sample exceeded 500 ms. The captured project tab stayed selected at every sample and both collector tabs stayed deep; the other project tab's selected state was not independently sampled throughout. Checkpoint storage stayed below 188 KiB, GTK RSS ranged from 204.3 to 261.1 MiB, and all capture stages and 59 resource samples were retained. The process exited 0 and all 141 frozen files verify. Proof is `.build/flatpak-v0104-soak/{soak-result,summary,runtime}.json`. This shared-host Xvfb fixture excludes physical input, portal video, microphone and provider timing; summed process RSS can count shared pages more than once.

Historical 0.10.3 proof follows. Records use `.build/flatpak-v0104-*` and `.build/flatpak-qa/capture-proof-v0104-mode2/`.

Historical 0.10.3 had 141 verified files, preserved the current observation and all twelve artifacts with exact hashes, and saw the actual Chrome profile's active/selected deep project tab. The code review is clean. Fresh Ubuntu 24.04 and Fedora 44 checks pass installer/update/rollback, bundled-Codex discovery without a global CLI, service, full GTK, video and offline recognition. Suites pass: 52 Swift, 42 Python and 15 collector tests. Real Chromium and Firefox/native-host capture pass for this bundle. The packaged local HTTP/Playwright workflow reproduces 503 and verifies the explicit 200 condition after a fixture change, imports eight checked diagnostic artifacts, rejects a corrupt artifact and preserves manual notes. [DEBUGGING.md](DEBUGGING.md) records the five debugging features, review fixes, commands and bounds. Records are `.build/headers-v0103-*`.

The frozen 0.10.3 bundle completed 1800.50 seconds with sixty seeded reports and 69 measured captures: ten consecutive requests awaited through GTK paint and 59 periodic captures. Capture-to-paint median was 355.34 ms, p95 392.04 ms and maximum 552.26 ms; one sample exceeded 500 ms. The captured project tab stayed selected at every sample and both collector tabs stayed in deep mode; the other project tab's selected state was not independently sampled throughout. Checkpoint storage stayed below 188 KiB, GTK RSS ranged from 174.6 to 246.3 MiB, and all capture stages and 59 resource samples were retained. The process exited 0 and the frozen bundle manifest was unchanged. Proof is `.build/headers-v0103-soak/{soak-result,summary,runtime}.json`. This shared-host Xvfb fixture excludes physical input, portal video, microphone and provider timing; summed process RSS can count shared pages more than once.

Physical workflow timing remains open. Installed-client filing/recovery/amendment passed against actual local D1/R2 with a disposable Secret Service token. The backend is deployed, and installed 0.10.4 production filing, same-receipt retry and amendment pass with two explicitly reviewed synthetic reports and six checksum-verified attachments.

## Desktop and external-service boundaries

- The collector must be loaded in each Chrome/Chromium profile and granted exact project origins. Installation does not bypass browser consent. The installed Chrome profile is now connected and a real capture has been saved.
- Window sharing needs the system chooser. Lens checks collector identity but cannot independently map the user-selected OS window to a Chrome tab; evidence records this limitation. Full-display selections are rejected.
- Some compositors, including the checked Hyprland portal, register shortcut actions without assigning keys. Settings reports this accurately and provides `gapplication action studio.sirv.NativeBrowserLens capture` for a desktop binding. The browser's **Alt+Shift+L** shortcut needs no compositor binding. Lens must be running.
- Live Codex subscription reports passed with synthetic reviewed evidence and an image. Dictation is offline and uses no API key. Automated speech is synthetic; physical microphone input and recognition quality are not established.
- VibeQ commit `4f710861` and migration 0070 are deployed at `https://work.sirv.studio`; CI artifact verification, the exact live Worker tag, all three capture tables and live gates pass. Version 0.10.4 successfully reads production members with the existing keyring credential. Explicitly reviewed 0.10.4 native-client synthetic filing, same-receipt retry and amendment passed; all six downloaded attachments match their frozen checksums. The earlier HTTP smoke used a local fixture.
- The macOS build is not executable on this host. Native Firefox, Firefox 158 Flatpak/proxy, Zen 1.23.3b Flatpak/proxy and Ubuntu Firefox Snap 158/WebExtensions portal pass real limited-mode capture. Zen is updated locally with a verified user proxy and scoped D-Bus grant; its actual-profile temporary add-on gesture remains. The Snap check retains strict AppArmor enforcement and preapproves only the synthetic host in an owned guest. Permanent signing and physical consent remain separate acceptance work. [Linux setup](LINUX.md#zen-flatpak) records version boundaries and removal.

## Local proof

Logs, screenshots and build hashes are under ignored `.build/`: `parity-*-tests.log`, `parity-ui-smoke.log`, `parity-tray-smoke.log`, `parity-filing-smoke.log`, `parity-browser-smoke.log`, `parity-default-profile.json`, `linux-tokyo-storm.png`, `linux-tokyo-day.png` and `linux-tokyo-compact.png`.

```sh
swift test
python3 -m unittest discover -s linux/tests -v
GDK_BACKEND=x11 GTK_THEME=Adwaita GTK_A11Y=none GIO_USE_VFS=local GSK_RENDERER=cairo \
  xvfb-run -a -s '-screen 0 1440x1100x24' python3 linux/tests/smoke.py
python3 linux/tests/tray_smoke.py
LENS_PRIVATE_BUS=1 dbus-run-session -- python3 linux/tests/filing_smoke.py
```

The filing smoke additionally needs `gnome-keyring-daemon`; it uses a private bus and temporary XDG directories, and never reads or replaces the user's credentials.
