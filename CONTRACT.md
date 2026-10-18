# Version 1 shared contract

All wire timestamps are Unix milliseconds (Double), IDs are UUID strings. JSON field names are camelCase. The app/root owns Swift Models.swift and LensCore, package manifest, scripts and documentation. UI agent owns Sources/NativeLens. Collector agent owns extension/. VibeQ agent owns isolated backend worktree and integrations/vibeq.md. Do not change others' files without coordinating.

## Native Messaging

Every message is {version:1, kind:string, id:string, payload:object}. The extension connects to `studio.sirv.native_browser_lens`. Native host speaks length-prefixed JSON over stdio, persists inbound messages in a local private mailbox, sends commands from app. Only the registered extension may connect. Host sends project configuration after hello. Keep individual messages below 512KiB; artifact parts below 256KiB base64. No internet from collector.

App -> extension:
- `configure`: {projects:ProjectProfile[]}
- `capture`: {tabId:number, observationId:string, captureId:string}
- `snapshot`: {tabId:number, observationId:string}
- `pause`: {paused:boolean}
- `resumeTab`: {tabId:number}
- `openOptions`: {clientId:string}; opens only the selected connected collector profile settings.

Extension -> app:
- `hello`: {clientId:string}
- `status`: {tabs:TabStatus[]}
- `event`: EvidenceEvent
- `capture-started`: {observationId,captureId,initiatedBy:"extension"|"native",identity:CaptureIdentity,tab:TabStatus}; sent before acquisition. App prepares pending state without showing UI. Starts, chunks, and final capture stay unacknowledged until the complete notebook transaction succeeds.
- `capture`: {observationId,captureId,identity:CaptureIdentity,events:EvidenceEvent[],gaps:CoverageGap[],context:object,screenshotBase64?:string,screenshotOmission?:string}; screenshot is PNG. If payload large, send `artifact` parts first instead: {observationId,captureId,index,total,mimeType:"image/png",data:base64}, then capture with screenshotOmission absent. App joins parts.
- `error`: {message:string,observationId?:string}

ProjectProfile: {id,name,origins:string[],repositoryPath:string,documentationPaths:string[],recording:"diagnostics"|"video",enabled:bool,adapter:"generic"|"sirv-studio" (legacy "sirv" accepted),ownership:OwnerRule[],logPaths:string[]}. OwnerRule: {pattern:string,memberId:string,label:string}. Exact origin grants requested in extension settings on user gesture. App config alone cannot grant browser permissions.

TabStatus: {tabId:number,windowId:number,projectId:string,url:string,title:string,mode:"deep"|"limited"|"devtools"|"handover"|"paused"|"unavailable",documentId:string,armedAt:number,capabilities:string[],reason?:string,active:bool,selected?:bool}. `active` requires OS window focus; `selected` identifies the selected tab within its browser window even while Lens has focus. Older collectors omit `selected`; Linux native capture requires an updated collector.

The collector applies activation event identities immediately, including unconfigured tabs, and publishes that status before asynchronous browser queries. Main-document commits and title-only updates also publish identity changes promptly. The native host stamps status payloads with `selectionEpoch`, a UUID changed whenever the selected tab/document/profile/window/title/mode set changes. The stamp survives status coalescing, including switching away and back while notebook helpers are busy. Linux carries it onto its tab copies and invalidates native media on a change. Window sharing requires a stamped status; an old connected host needs an extension reload. The stamp does not establish ownership of the portal-selected OS window.

CaptureIdentity: {projectId:string,tabId:number,windowId:number,documentId:string,url:string,title:string,capturedAt:number,buildId?:string}
EvidenceEvent: {id:string,projectId:string,tabId:number,documentId:string,timestamp:number,kind:string,data:object}. kind examples request,response,console,exception,action,storage,coverage. No raw cookie/auth values.
CoverageGap: {channel:string,reason:string,startedAt:number,endedAt?:number}

App stores NotebookObservation {id,projectId,createdAt,title,markdown,draftRevision,editVersion,captures:[CaptureRecord],findings:[Finding],receipt?:FilingReceipt}. CaptureRecord {id,identity,events,gaps,context,screenshotPath?,annotations:[Annotation]}. Annotation {id,kind:"rectangle"|"arrow"|"pen"|"mask",points:[NormalizedPoint],color:string}; points x/y in [0,1]. Masks must be burned into export and AI derivatives.

Swift model initializer defaults supplied by root. JSONValue is recursive Codable with .object/.array/.string/.number/.bool/.null and conveniences objectValue/stringValue/intValue/doubleValue/boolValue plus subscript string -> JSONValue?.

## Core APIs (root implements)

LensPaths.defaultRoot URL (Application Support/Native Browser Lens), EvidenceStore(root:URL); projects() throws->[ProjectProfile]; saveProjects(_:); observations() throws->[NotebookObservation]; save(_:); artifactURL(observationId:filename:); saveArtifact(observationId:filename:data:) -> URL; export(observation:to:) -> URL. Store actor NOT required, main app serializes calls; SQLite busy timeout handles host-independent access.

BridgeMailbox(root:URL); send(kind:payload:) throws; pending(excluding:Set<String>) throws->[WireMessage]; acknowledge(Set<String>) throws; configuration saved via saveConfiguration(projects:). Host reads configuration on hello; commands carry destination clientId where necessary. App and host retain BridgeWatch instances. watchInbox/watchCommands use macOS vnode notifications or Linux inotify to read durable private queues immediately; no periodic transport polling. Native host adds its clientId to status tabs and capture identity. Commands targeting a tab carry clientId to distinguish browser profiles.

Investigator.investigate(observation:NotebookObservation, project:ProjectProfile, apiKey:String?, model:String) async throws->[Finding]; Investigator.makeDraft(observation:project:findings:apiKey:model:) async throws->String. Finding {id,kind:"observed"|"expected"|"documented"|"hypothesis"|"coverage",text,source?,confidence?}. Model IDs default gpt-5.6-terra and gpt-live-transcribe. KeychainStore.get/set(key:value:) for openai and vibeq tokens. VibeQClient(baseURL:URL,token:String); members() async throws->[VibeQMember]; file(observation:project:store:assigneeId:) async throws->FilingReceipt; amendments use observation draftRevision.

The macOS UI uses ScreenCaptureKit; Linux uses a user-approved, window-only XDG portal/PipeWire stream. Linux discards its bounded in-memory ring on tab, document, browser profile or title changes, project disable and pause. Portal window ownership cannot be independently matched to the Chrome tab; capture coverage records this limit. Native images use `coordinateSpace=native-window` and cannot bind browser viewport DOM coordinates. Browser PNGs take precedence over native fallback.

NotebookInbox.sync returns validated `captureStarts` before the final envelope arrives, allowing Linux to freeze a recent native frame without revealing the notebook. The Linux service accepts `nativeMedia` only for the saved capture's complete identity and private artifact filenames; `reviewVideo` controls `context.videoReviewed`. Video remains unreviewed when first saved.

The Linux service is a one-command JSON stdio helper. With `stream=true`, progress JSON lines (`{progress:{...}}`) precede the final result. Investigation progress and filing stages come from the shared clients. Cloud requests carry the explicitly reviewed `editVersion`; filing requests carry the observation ID, reviewed edit version and revision. The helper reloads and validates the stored review or frozen pending submission rather than accepting an oversized duplicate evidence payload. Report suggestions are returned separately from editable Markdown. `connectedClientIDs` excludes recorded dead host processes; the GTK app publishes a read-only `connection-status` action state for local diagnostics.

Native UI owns microphone transcription. Linux records 16 kHz mono PCM only after an explicit Dictate action, holds at most two minutes in memory, and sends an in-memory WAV to the bundled local Whisper helper after Finish. No microphone audio enters a network request or is saved. A missing engine/model cannot start the microphone. Late or duplicate completions cannot enter another session; text that cannot be inserted is retained for explicit recovery. Do not insert raw AI response over manual edits: compare editVersion captured before request; return suggested draft separately if changed. Filing always requires a reviewed explicit UI action.

Linux cloud investigation uses the managed Codex ChatGPT login, without reading or copying its tokens or consulting API-key environment variables. The CLI receives only reviewed text/local findings and copied reviewed PNG derivatives in a private temporary workspace. User rules/config and tools are disabled; a named filesystem profile denies the private notebook store. Sessions are ephemeral, time/output bounded, and return a separate suggested draft. Linux Settings provides managed ChatGPT login and status instead of an OpenAI API-key field.

## Reviewed cloud and filing selection

Cloud investigation includes only captures with context.includeInAI=true, plus the explicitly reviewed notebook text and local references derived from those captures. Prior findings are not implicitly transmitted. Raw screenshot and video paths are removed. Image masks must be rendered before cloud review; video never enters AI calls. Export includes video only when context.videoReviewed=true.

Filing snapshots and submission identities are persisted before network I/O. VibeQClient.pendingSubmission restores a frozen review after restart; retries reconcile that identity first. FilingProgress reports real prepare/reconcile/attachments/submit/receipt events and completed counts. The UI must not infer successful filing from an upload alone.

The VibeQ client binds each attempt to the server-verified /auth/me member ID before uploads; member changes cannot retry an uncertain outcome. Same-member token rotation preserves recovery.

Firefox uses the limited mode with webRequest metadata and explicit missing debugger/console/body/worker coverage. It does not intercept response streams. When native document IDs are unavailable, isolated-world random document tokens plus main-navigation epochs bind page probes and reject capture/navigation races. Exact origin grants remain required. Firefox screenshots require a browser action/shortcut activeTab grant, or the separately approved native fallback; Lens never requests broad all-site access for screenshots.

Linux service replies are incremental: `observationUpdates` contains complete records for changed or requested observation IDs, merged by ID and sorted by creation time in the UI. Status-only replies omit both observation fields. Only explicit `bootstrap` and `rebaseBackup` return the complete `observations` snapshot, replacing loaded state. The Refresh action and maintenance operations request `bootstrap` so restore and deletion remove stale loaded records. Capture replay checks and individual reads query the saved record without decoding unrelated observations.

## Linux debugging and diagnostic imports

`timeline` accepts observationId/captureId and returns only `timeline` rows and `timelineFindings`. Each row contains the original event, a failure marker and links with target/relationship/reason. Request links require the same document, target session and redirect hop; ties preserve recorded event order. Trace links require explicit identifiers. Nearby links are temporal context only.

Trace/request header identifiers are recognized in dictionary and name/value-array forms, including the trace portion of traceparent. The local log investigation uses the same extractor. Response-body omissions carry the same target scope as the recorded request. Portable import remaps matching capture IDs in spatial context/elements/annotationBindings, retains foreign IDs as invalid, and records that imported evidence was not recollected.

`cloudPreview` accepts observationId/reviewedVersion/captureIds, checks the current saved revision and returns the same bounded event selection used by Codex. JSON stays structurally valid. Failure/request/context priority, omitted counts/IDs, truncated ID lists and shortened fields are explicit. Raw data remains saved. Baked mask copies remove editable mask layers only after validation, so repeat sanitization cannot require a private original that was deliberately excluded.

`diagnosticArtifacts` is an optional capture context array. Each record has id/type/path/sha256/bytes/importedAt/reviewed/provenance and, for verification, a typed summary whitelist of the imported result. Import and export both normalize that summary, including older saved records. Unknown fields and free-form runner error details stay only in the original local file; summary failures use a fixed notice, tool names are enumerated, build IDs require commit syntax, and free-form query-policy text is omitted. Only har/trace/profile/verification types are accepted. Imports default reviewed=false. `reviewDiagnostic` requires the saved edit version and explicit reviewed flag. Cloud selections exclude this raw artifact array. Export copies only reviewed, unchanged artifacts within the observation; paths become portable. Import changes IDs/paths and resets review. Backup path rebasing includes diagnostics. VibeQ uploads reviewed files through the existing export manifest.

`importVerification` validates a result's observation/capture, contract hash and local artifact checksums before attaching it. Its condition must match the original captured HTTP failure's event, sanitized URL, exact method and integer failure status, with an explicit integer 200–399 success status. `verificationSummary` validates that original-failure binding for both runs and compares before/after condition, steps hash, script hash, completed execution, exactly one matching response per run and exact expected HTTP statuses. The runner chooses its observed status after browser shutdown, including responses received during profiler/trace cleanup. Imported assertions never become independently collected browser evidence. `handoff` writes a new folder only after a saved-version check; it never executes captured instructions. The local evidence CLI reads explicit portable exports, never the private database, and exposes no filing command.

Automatic source excerpts and mapped original sources use the shared source-file extension scope, checked before and after symlink resolution. Explicit configured documentation/log roots retain their separate read scope. PEM private-key blocks are redacted before slicing source excerpts, preserving line numbers. Credential matching within header containers includes session and anti-forgery names; public CDP session IDs outside those containers remain available for request correlation. Export/cloud sanitization also applies these rules to older saved normalized headers.

New CDP events use `data.targetSession` for the public debugger channel, with an explicit `main` value for the root session. Credential fields named sessionId remain redacted. Timeline and request views also read unredacted legacy sessionId metadata, but redaction markers never establish a shared target identity. AI selection deduplicates repeated rolling-event UUIDs across captures and reports `duplicateEventCopies`; originals stay unchanged. Notebook and findings byte budgets use the same formatted JSON representation sent to Codex.

Codex report generation loads a static trusted model-instructions file from its private ephemeral workspace. Reviewed reporter/page/source content remains in the separate untrusted prompt; it is never inserted into that trusted file. Existing disabled tools, ignored user config/rules, private-store denial, structured output and manual-note preservation remain enforced. HAR query sanitization distinguishes possible session/auth query secrets from public debugger session IDs used to correlate recorded requests.

## Local agents

`native-browser-lens mcp EXPORTS_DIRECTORY` serves MCP JSON-RPC over stdio. Its tools list and query only regular portable exports directly inside that explicit directory, using the shared evidence reader. Report names cannot traverse paths or follow directory symlinks. Images use the reader's validated reviewed PNG, returned as MCP image content with its checksum. Tools are read-only and expose no private notebook, arbitrary file, browser-control, shell or filing operation.

`Fix with Codex` is a separate explicit reviewed action. It freezes the saved observation version, selected capture/failure and expected success status, and exports only the selected evidence for the fix session. The user supplies a local development-server argument vector (with `{port}` substitution); captured text cannot choose commands. The workflow creates private sibling Git worktrees at the repository's saved HEAD, excluding current uncommitted edits. Codex plans reproduction steps read-only, then edits only the fix worktree using the existing ChatGPT login. No automatic commit, merge, push, deployment or filing occurs.

The controller freezes the handoff contract, steps and runner, runs the captured failure against a fresh loopback-only test server, then independently repeats it on an unchanged baseline and the edited worktree. The same captured HTTP condition is mapped to the local test origin; imported results retain that local-origin provenance. Passing means only the same configured HTTP condition passed, with checked artifact hashes and a retained patch. Errors/cancellation preserve the worktree and partial logs, stop owned child processes and cannot alter manual notebook text. Raw diagnostics are excluded from the Codex evidence input and remain unreviewed on import.

Codex's tools receive no read grant for the raw runs or controller/evidence directory, and get a private shell HOME with a minimal environment. The verified source server executes in a Bubblewrap filesystem/PID sandbox containing only its worktree, selected runtime and read-only Git metadata with credentials hidden. The trusted runner has separate immutable inputs/dependencies and writable result files inaccessible to the server. The two share an isolated loopback network, with no host services, session bus, home directory or external network. Local-origin URL mapping assigns pathname/search/hash without interpreting double-slash paths as an authority. The fixed, uncommitted source does not assert a build commit.
