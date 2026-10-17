# Native Browser Lens collector privacy

The collector connects a browser to the Native Browser Lens notebook on the same computer. It does not contain analytics, advertising, an external API client or a remote code loader. Its extension-page content security policy blocks network connections. Your normal website requests still run in their original pages.

Collection starts only for enabled project origins after you approve their browser permissions. Incognito tabs are excluded. The collector can retain page URLs and titles, screenshots, page and element state, click metadata, console messages and errors, request/response metadata, bounded eligible response bodies, and storage summaries. Sensitive credential keys and values are redacted where recognized. Redaction cannot guarantee that arbitrary page content is free of private information; review captures before sharing them.

Rolling evidence is bounded in local browser storage. Completed captures go through Native Messaging to the local notebook, which stores them on your computer. The collector does not send evidence directly to an AI provider or task service. The notebook can send reviewed text and selected, masked images through your signed-in Codex session, or reviewed reports and attachments to your configured VibeQ endpoint, only after the corresponding review action. Notebook microphone dictation is processed locally with bundled Whisper; microphone audio stays in memory.

When you request AI investigation, the notebook can also inspect bounded source, documentation and correlated log references inside the local project paths you configured. Derived excerpts can be included in the Codex input. Source/build mismatches and missing evidence are reported explicitly. The Codex process has tools disabled and is denied access to the private notebook store; it receives the selected evidence and copied reviewed images in an ephemeral workspace.

HAR, trace, CPU-profile and runner-result files that you choose to import are stored locally. Eligible same-origin HAR metadata is normalized into capture evidence with recognized credential fields redacted; bodies and cookies are omitted from that normalized view. Raw diagnostic files are excluded from AI input and remain local until you separately review them for export or filing. Raw traces and HARs can contain private information that image masks do not redact. The evidence CLI reads an explicitly selected portable export; it does not implicitly open the private notebook or file a report.

You can pause collection, revoke site access in the browser, disable a project, or remove the collector. Removing the collector does not remove saved notebook observations. Use the notebook's Trash and reviewed permanent deletion controls to remove saved observations; backups and exports remain wherever you saved them. Browser collector storage is removed according to the browser's extension removal behavior.

Notebook backups and exports are local files and must be protected as private evidence. Backups exclude credentials, the installed application and browser queues. A backup restore preserves the prior notebook in a safety backup. Checking for app updates contacts GitHub for release metadata on demand; it does not upload notebook evidence or run an automatic background update check.

Firefox uses a limited collection mode and may require a toolbar action for screenshots. Its host permissions cover all ports of an approved host; Lens still selects project tabs using exact configured origins. Unavailable evidence is recorded as a coverage gap.

This file describes the included collector and notebook behavior. A public store listing must link to a publisher-hosted copy and provide that publisher's support contact before submission.
