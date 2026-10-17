# Browser store handoff

No store listing, signing request, upload or publication has been performed. The current Chrome ID is the local development ID `mfpclfngcgiahifebjbjlgagmlflcjpg`. The Firefox ID is `native-browser-lens@sirv.studio`.

## Publication authority and release feed

The authenticated GitHub metadata check on 2026-10-17 reports that `VKrachun/native-browser-lens` is private and has no detected project license; this checkout also contains no project license file or README license grant. Distribution terms and publication authority must be supplied by the owner/publisher. No license has been chosen on their behalf. See [GitHub's repository licensing guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository).

The app's on-demand updater points to the upstream repository. Public distribution needs an accessible publisher-owned release feed and matching release assets; local folder installation remains available. The user authorized private source landing and the VibeQ backend release. Public desktop/store distribution still needs the owner/publisher inputs above. Prepared installer and submission packages remain local review material.

## Current install path

Run the Linux `.run` installer, then use **Browser setup**. Chrome/Chromium requires Developer mode → Load unpacked and explicit project-origin approval. Firefox uses about:debugging → This Firefox → Load Temporary Add-on; it lasts until Firefox restarts. No browser security setting or enterprise policy is changed.

`python3 scripts/package-linux.py` creates the Chrome ZIP and clearly marked unsigned Firefox XPI beside the Linux artifacts in `dist/releases`. Both packages include PNG icons at 16, 32, 48 and 128 pixels. The SVG source is `public/icons/lens.svg`.

## Chrome publication

The publisher needs a Chrome Web Store developer account, a hosted privacy policy based on [PRIVACY.md](PRIVACY.md), and support/contact details. The [prepared listing images](store-assets/README.md) include a 440×280 promotional tile, an actual 1280×800 Chromium collector setup screenshot, and three 1280×800 GTK screenshots using isolated browser fixtures, with dimensions and hashes recorded. They show the current 0.10.3 UI, including the linked failure timeline. The ZIP includes the 128-pixel package icon. Upload the prepared ZIP and images as a draft only when publication work is authorized. Never use a user's notebook for listing screenshots.

The store assigns its own item identity. Copy **Package → View public key** into `public/manifest.json`'s `key` field, rebuild, and compare the derived ID with the dashboard item ID. Do not assume that the current local ID will be the store ID. Rebuild the native app installer too: it derives the one allowed Chrome origin from this key. Update ID-specific fixtures and docs, then repeat real native-host install/capture tests. A different ID also needs its own site approval; do not migrate permissions silently. Only add an **Install from Chrome Web Store** link to Browser setup after the real listing URL and matching native-host identity are verified.

The extension has one purpose: collect reviewed project browser evidence for a local notebook. Suggested listing description: “Capture project browser screenshots, console errors, failed requests and page context into a private local notebook. Review, annotate and mask captures before creating a report. Requires the Native Browser Lens desktop app.” Do not advertise complete Firefox debugger coverage or automatic installation.

Permission justifications:

| Permission | Use |
| --- | --- |
| debugger (Chrome) | Bounded console, network and frame/worker diagnostics on approved project tabs; explicit limited coverage when unavailable. |
| webRequest (Firefox) | Bounded request/response metadata in limited mode. |
| nativeMessaging | Send captures to, and receive project configuration from, the exact locally registered Lens host. |
| storage | Persist project settings and bounded collector checkpoints locally. |
| scripting / optional host permissions | Read approved project page, action and storage context. Host access is granted by user gesture. |
| tabs / webNavigation | Match configured project tabs and separate document identities across navigation. |
| activeTab | Obtain user-invoked screenshots, including Firefox toolbar captures. |
| alarms | Recover collector coordination after service-worker suspension. |

The store's privacy questionnaire must reflect the evidence categories above even though rolling evidence is local. Review the complete policy and listing against the actual release before submission. External service use belongs to explicit notebook review actions; do not describe it as automatic browser collection.

Primary instructions: [Chrome publishing](https://developer.chrome.com/docs/webstore/publish), [consistent extension IDs](https://developer.chrome.com/docs/extensions/reference/manifest/key), [listing images](https://developer.chrome.com/docs/webstore/images).

## Firefox signing

The publisher needs a Mozilla developer account. Submit the built Firefox package and reproducible source to Mozilla for signing, with the exact Gecko ID above. An unlisted signed distribution can support direct permanent installation without an AMO search listing. Do not disable signature checks. Verify the returned signed XPI against a native Firefox profile and the bundled native host before adding its real download URL to Browser setup. The unsigned XPI is not a permanent-install deliverable.

The local review source archive is `dist/releases/native-browser-lens-firefox-source-0.10.3-private-review.zip`, with an adjacent SHA-256 file. It contains 38 source/build/metadata files plus its source manifest; no notebook, credentials, node_modules or generated collector output is included. After extraction, `npm ci`, `npm run build` and `npm test` reproduce all 15 files in each frozen Chrome/Firefox output directory byte-for-byte and pass 15 tests. `BUILDING.txt` records the build steps and unresolved publication/license status. The proof is `.build/firefox-source-v0103-proof.json`. This archive is local review material pending owner/publisher authority; it has not been uploaded.

Primary instructions: [Mozilla signing and distribution](https://extensionworkshop.com/documentation/publish/signing-and-distribution-overview/).
