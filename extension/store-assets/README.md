# Listing images

Prepared locally for Lens 0.10.3. No image or listing was submitted to a store.

- `promo-440x280.png`: required small promotional tile; editable source is the adjacent SVG. It uses the app's Tokyo Night Storm palette and lens motif.
- `collector-setup-1280x800.png`: actual Chromium collector setup with the real native host and two isolated fixture projects. Regenerate this image after a store-assigned extension ID replaces the local development ID.
- `notebook-storm-1280x800.png`: actual GTK network-evidence view in dark mode.
- `notebook-day-1280x800.png`: actual GTK capture view in light mode.
- `notebook-timeline-1280x800.png`: actual GTK linked failure timeline with the captured HTTP 503 selected.
- `manifest.json`: PNG dimensions and SHA-256 hashes.

The notebook screenshots use the actual 0.10.3 packaged UI and a real capture from an isolated Chromium/native-host fixture, imported into a disposable notebook and exported locally. The report text is explicitly a demo. Their disconnected-browser message is accurate: saved evidence remains available offline. The evidence split and scroll position were adjusted through the real UI controls to show the failure and details at 1280×800. The collector screenshot uses a separate disposable browser profile and actual Native Messaging connection. No user's notebook, project, credentials or desktop is included. The listing must state that the extension requires the native app.

`manifest.json` records the frozen bundle manifest hash and source capture hash, as well as each PNG's dimensions and checksum. The four screenshots were regenerated for 0.10.3; the promotional SVG/PNG is unchanged brand artwork. The prepared images were checked against the linked Chrome requirements on 2026-10-17.

The package's 128-pixel icon is `../public/icons/lens-128.png`, with 16-pixel transparent padding around its 96-pixel artwork. The [Chrome image requirements](https://developer.chrome.com/docs/webstore/images) specify a 440×280 promotional image and 1280×800 or 640×400 screenshots. See [the publication handoff](../STORE.md) for account, privacy-policy and extension-identity requirements.
