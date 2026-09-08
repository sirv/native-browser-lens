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

Extension -> app:
- `hello`: {clientId:string}
- `status`: {tabs:TabStatus[]}
- `event`: EvidenceEvent
- `capture-started`: {observationId,captureId,initiatedBy:"extension"|"native",identity:CaptureIdentity,tab:TabStatus}; sent before acquisition. App prepares pending state without showing UI. Starts, chunks, and final capture stay unacknowledged until the complete notebook transaction succeeds.
- `capture`: {observationId,captureId,identity:CaptureIdentity,events:EvidenceEvent[],gaps:CoverageGap[],context:object,screenshotBase64?:string,screenshotOmission?:string}; screenshot is PNG. If payload large, send `artifact` parts first instead: {observationId,captureId,index,total,mimeType:"image/png",data:base64}, then capture with screenshotOmission absent. App joins parts.
- `error`: {message:string,observationId?:string}

ProjectProfile: {id,name,origins:string[],repositoryPath:string,documentationPaths:string[],recording:"diagnostics"|"video",enabled:bool,adapter:"generic"|"sirv-studio" (legacy "sirv" accepted),ownership:OwnerRule[],logPaths:string[]}. OwnerRule: {pattern:string,memberId:string,label:string}. Exact origin grants requested in extension settings on user gesture. App config alone cannot grant browser permissions.

TabStatus: {tabId:number,windowId:number,projectId:string,url:string,title:string,mode:"deep"|"devtools"|"handover"|"paused"|"unavailable",documentId:string,armedAt:number,capabilities:string[],reason?:string,active:bool}

CaptureIdentity: {projectId:string,tabId:number,windowId:number,documentId:string,url:string,title:string,capturedAt:number,buildId?:string}
EvidenceEvent: {id:string,projectId:string,tabId:number,documentId:string,timestamp:number,kind:string,data:object}. kind examples request,response,console,exception,action,storage,coverage. No raw cookie/auth values.
CoverageGap: {channel:string,reason:string,startedAt:number,endedAt?:number}

App stores NotebookObservation {id,projectId,createdAt,title,markdown,draftRevision,editVersion,captures:[CaptureRecord],findings:[Finding],receipt?:FilingReceipt}. CaptureRecord {id,identity,events,gaps,context,screenshotPath?,annotations:[Annotation]}. Annotation {id,kind:"rectangle"|"arrow"|"pen"|"mask",points:[NormalizedPoint],color:string}; points x/y in [0,1]. Masks must be burned into export and AI derivatives.

Swift model initializer defaults supplied by root. JSONValue is recursive Codable with .object/.array/.string/.number/.bool/.null and conveniences objectValue/stringValue/intValue/doubleValue/boolValue plus subscript string -> JSONValue?.

## Core APIs (root implements)

LensPaths.defaultRoot URL (Application Support/Native Browser Lens), EvidenceStore(root:URL); projects() throws->[ProjectProfile]; saveProjects(_:); observations() throws->[NotebookObservation]; save(_:); artifactURL(observationId:filename:); saveArtifact(observationId:filename:data:) -> URL; export(observation:to:) -> URL. Store actor NOT required, main app serializes calls; SQLite busy timeout handles host-independent access.

BridgeMailbox(root:URL); send(kind:payload:) throws; pending(excluding:Set<String>) throws->[WireMessage]; acknowledge(Set<String>) throws; configuration saved via saveConfiguration(projects:). Host reads configuration on hello; commands carry destination clientId where necessary. App and host retain BridgeWatch instances. watchInbox/watchCommands use macOS vnode notifications to read durable private queues immediately; no periodic transport polling. Native host adds its clientId to status tabs and capture identity. Commands targeting a tab carry clientId to distinguish browser profiles.

Investigator.investigate(observation:NotebookObservation, project:ProjectProfile, apiKey:String?, model:String) async throws->[Finding]; Investigator.makeDraft(observation:project:findings:apiKey:model:) async throws->String. Finding {id,kind:"observed"|"expected"|"documented"|"hypothesis"|"coverage",text,source?,confidence?}. Model IDs default gpt-5.6-terra and gpt-live-transcribe. KeychainStore.get/set(key:value:) for openai and vibeq tokens. VibeQClient(baseURL:URL,token:String); members() async throws->[VibeQMember]; file(observation:project:store:assigneeId:) async throws->FilingReceipt; amendments use observation draftRevision.

Native UI performs ScreenCaptureKit, video, mic transcription. Root provides OpenAITranscriptionSession on callbacks if requested; UI agent owns native speech session initially. Do not insert raw AI response over manual edits: compare editVersion captured before request; return suggested draft separately if changed. In notebook plain dictation append only to location/session captured at microphone start. Filing always reviewed explicit UI action.

## Reviewed cloud and filing selection

Cloud investigation includes only captures with context.includeInAI=true, plus the explicitly reviewed notebook text and local references derived from those captures. Prior findings are not implicitly transmitted. Raw screenshot and video paths are removed. Image masks must be rendered before cloud review; video never enters AI calls. Export includes video only when context.videoReviewed=true.

Filing snapshots and submission identities are persisted before network I/O. VibeQClient.pendingSubmission restores a frozen review after restart; retries reconcile that identity first. FilingProgress reports real prepare/reconcile/attachments/submit/receipt events and completed counts. The UI must not infer successful filing from an upload alone.

The VibeQ client binds each attempt to the server-verified /auth/me member ID before uploads; member changes cannot retry an uncertain outcome. Same-member token rotation preserves recovery.
