# Collector verification — 8 September 2026

The Chrome collector builds and its 10 focused tests pass. The real-browser checks use Chrome for Testing 151.0.7922.34 in disposable profiles, with exact local fixture grants. The user's default browser remains a separate integration check.

## Current implementation proof

[Release-host smoke](output/playwright/native-host/smoke-result.json) identifies the compiled collector and native-host SHA-256 digests. It verifies:

- Two projects in distinct Chrome windows, with only the selected tab of the focused window active.
- Failed transport, HTTP 503, actual browser cache provenance, sanitized response bodies and storage, an exception and available stack, and source-stamped DOM context.
- Frozen source/geometry for clicked and unclicked visible controls; a replacement node receives a new identity, and moved nodes cannot inherit a capture binding.
- A MAIN-world project diagnostic getter, with working-tree source explicitly unverified.
- `capture-started` identity before artifacts for both extension and native commands, native filesystem-watched command delivery, client identity stamping, and PNG reassembly.
- Main-document navigation, pause/resume, and real DevTools opening, network collection, navigation and deep-mode reconnection after closing.

The [captured PNG](output/playwright/native-host/collector-capture.png) retains the transient menu. Spatial candidates are bounded to 250 elements or 48 KiB; scan and revalidation omissions remain explicit.

## Capture latency

[20 release-host samples](output/playwright/profile-control/capture-latency.json): median **229 ms**, p95 **378 ms** from requesting a browser capture through native-host persistence. This includes browser PNG acquisition, DOM/storage/source probes, image transfer and receiver polling. ScreenCaptureKit acquisition and native notebook rendering are separate measurements.

## Scheduling and resource controls

An early comparison left the instrumented fixture behind another selected tab while the baseline remained selected. Its timer delay was not a valid measurement of collection overhead.

The [same-tab foreground control](output/playwright/tab-selection-control/soak-result.json) kept code and workload unchanged and measured actual Chrome `tab.active`:

| Phase | Selected fixture tab | Timer delay p95 | Ticks in approximately 30 seconds |
|---|---:|---:|---:|
| Fixture selected | Yes | 1.1 ms | 301 |
| Options selected | No | 52.2 ms | 241 |
| Fixture selected again | Yes | 1.0 ms | 299 |

Headless `document.visibilityState` continued to report visible, so selected-tab scheduling is the observed distinction. A separate [120-second selected-tab comparison](output/playwright/visibility-comparison/soak-result.json) measured timer p95 1.0 ms armed versus 1.1 ms baseline, with request p95 3.7 versus 3.8 ms at the final sample.

The [same-browser collection control](output/playwright/collection-control/soak-result.json) kept the fixture selected and retained identical pages and process topology:

| Collection phase | Chrome CPU, percent of one core | Timer delay p95 | Chrome process RSS sum |
|---|---:|---:|---:|
| Paused | 4.56% | 1.3 ms | 1,076,576 KiB |
| Armed | 7.58% | 1.4 ms | 1,107,312 KiB |
| Paused again | 4.21% | 1.3 ms | 1,033,104 KiB |

These are local fixture samples, not device-wide guarantees. CPU covers all fixture Chrome processes; RSS sums can count shared pages multiple times. The armed snapshot rose approximately 30 MiB relative to the first paused snapshot. Comparing the separate instrumented and baseline browsers directly would also include their differing numbers of pages and extension processes.

## Retention run

The [30-minute run](output/playwright/soak-result.json) completed at 20:36:44 UTC after 1,800.116 seconds. Both fixture tabs remained in deep mode in all 60 samples. The evidence checkpoint ranged from 176,786 to 195,324 bytes; instrumented page JS heap ranged from 2,281,324 to 5,208,616 bytes. The process exited successfully and removed its temporary profile/native-host registration.

This run started before the focus/spatial follow-up changes and was retained to verify ambient collection lifetime. Its scheduling values carry the selected-tab confound described above; use the controlled measurements for overhead and the current release-host smoke for the subsequent behavior changes.
