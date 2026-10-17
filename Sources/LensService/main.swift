import Foundation
import LensCore
import Glibc

let store = EvidenceStore(), bridge = BridgeMailbox()
let defaults = UserDefaults(suiteName: "studio.sirv.native-browser-lens")!
@MainActor func settings() -> [String: String] {
    ["codexModel": defaults.string(forKey: "codexModel") ?? "", "trashRetentionDays": defaults.string(forKey: "trashRetentionDays") ?? "0", "trashMaxMiB": defaults.string(forKey: "trashMaxMiB") ?? "0", "shortcutEnabled": defaults.string(forKey: "shortcutEnabled") ?? "false", "appearance": defaults.string(forKey: "appearance") ?? "dark", "capturePaused": defaults.string(forKey: "capturePaused") ?? "false", "transcriptionModel": defaults.string(forKey: "transcriptionModel") ?? "gpt-live-transcribe", "vibeqURL": defaults.string(forKey: "vibeqURL") ?? "http://localhost:3001"]
}
@MainActor func bridgeProjects() throws -> [ProjectProfile] {
    var projects = try store.projects()
    if settings()["capturePaused"] == "true" { for index in projects.indices { projects[index].enabled = false } }
    return projects
}
@MainActor func observation(_ request: JSONValue) throws -> NotebookObservation {
    guard let id = request["observationId"]?.stringValue, let item = try store.observation(id: id) else { throw LensError.invalid("Select a saved observation") }
    return item
}
@MainActor func project(_ id: String) throws -> ProjectProfile {
    guard let result = try store.projects().first(where: { $0.id == id }) else { throw LensError.invalid("Select a project in Settings first") }
    return result
}
func edited(_ item: inout NotebookObservation) {
    item.editVersion += 1
    if let receipt = item.receipt { item.draftRevision = max(item.draftRevision, receipt.revision + 1) }
}
@MainActor func handle(_ request: JSONValue) async throws -> JSONValue {
    var extra: [String: JSONValue] = [:]
    let streaming = request["stream"]?.boolValue == true
    let progress: @Sendable (JSONValue) -> Void = { value in
        guard streaming, var data = try? JSONEncoder().encode(JSONValue.object(["progress": value])) else { return }
        data.append(10); try? FileHandle.standardOutput.write(contentsOf: data)
    }
    switch request["action"]?.stringValue {
    case "handoff":
        let item = try observation(request)
        guard item.editVersion == request["reviewedVersion"]?.intValue, let event = request["eventId"]?.stringValue, let status = request["successStatus"]?.intValue, let path = request["destination"]?.stringValue, path.hasPrefix("/" ) else { throw LensError.invalid("Review the saved failure and expected success status") }
        let folder = try Reproduction.handoff(observation: item, eventId: event, successStatus: status, destination: URL(fileURLWithPath: path), runner: LensPaths.executableDirectory.appendingPathComponent("reproduce.mjs"))
        return .object(["handoffPath": .string(folder.path)])
    case "verificationSummary":
        let item = try observation(request)
        guard let capture = item.captures.first(where: { $0.id == request["captureId"]?.stringValue }) else { throw LensError.invalid("Select a capture") }
        return .object(["verification": Reproduction.summary(capture: capture)])
    case "importDiagnostic", "importVerification", "reviewDiagnostic":
        var item = try observation(request)
        guard let index = item.captures.firstIndex(where: { $0.id == request["captureId"]?.stringValue }) else { throw LensError.invalid("Select a saved capture") }
        if request["action"]?.stringValue == "importVerification" {
            guard let path = request["source"]?.stringValue, path.hasPrefix("/") else { throw LensError.invalid("Choose a runner result.json") }
            try DiagnosticArtifacts.importRun(source: URL(fileURLWithPath: path), to: &item.captures[index], observationId: item.id, store: store)
        } else if request["action"]?.stringValue == "importDiagnostic" {
            guard let path = request["source"]?.stringValue, path.hasPrefix("/"), let type = request["type"]?.stringValue else { throw LensError.invalid("Choose a diagnostic file and type") }
            try DiagnosticArtifacts.attach(source: URL(fileURLWithPath: path), type: type, to: &item.captures[index], observationId: item.id, store: store)
        } else {
            guard request["reviewedVersion"]?.intValue == item.editVersion, let id = request["artifactId"]?.stringValue, let reviewed = request["reviewed"]?.boolValue else { throw LensError.invalid("Review the current diagnostic attachment") }
            var records = DiagnosticArtifacts.records(item.captures[index])
            guard let artifact = records.firstIndex(where: { $0["id"]?.stringValue == id }), var fields = records[artifact].objectValue else { throw LensError.invalid("Unknown diagnostic attachment") }
            fields["reviewed"] = .bool(reviewed); records[artifact] = .object(fields)
            item.captures[index].context["diagnosticArtifacts"] = .array(records)
        }
        edited(&item); try store.save(item)
    case "timeline":
        let item = try observation(request)
        guard let capture = item.captures.first(where: { $0.id == request["captureId"]?.stringValue }) else { throw LensError.invalid("Select a saved capture") }
        return .object(["timeline": try .from(IncidentEvidence.timeline(capture: capture, findings: item.findings)), "timelineFindings": try .from(item.findings)])
    case "cloudPreview":
        var item = try observation(request)
        guard item.editVersion == request["reviewedVersion"]?.intValue else { throw LensError.invalid("The observation changed. Open its current review again.") }
        let ids = Set(request["captureIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        for index in item.captures.indices { item.captures[index].context["includeInAI"] = .bool(ids.contains(item.captures[index].id)) }
        item = try EvidenceSanitizer.cloudSelection(item)
        return .object(["selection": try IncidentEvidence.select(observation: item)])
    case "bootstrap":
        try bridge.saveConfiguration(projects: bridgeProjects())
        fallthrough
    case "sync": extra["update"] = try .from(NotebookInbox(store: store).sync())
    case "configure":
        guard let profiles = try request["projects"]?.decode([ProjectProfile].self) else { throw LensError.invalid("Missing projects") }
        guard profiles.allSatisfy({ ["diagnostics", "video"].contains($0.recording) }) else { throw LensError.invalid("Unknown recording mode") }
        try store.saveProjects(profiles); try bridge.saveConfiguration(projects: bridgeProjects())
    case "settings":
        for (key, limit) in [("trashRetentionDays", 3650), ("trashMaxMiB", 1_048_576)] {
            if let text = request["settings"]?[key]?.stringValue { guard let number = Int(text), (0...limit).contains(number) else { throw LensError.invalid("Invalid Trash retention limit") } }
        }
        if let appearance = request["settings"]?["appearance"]?.stringValue, !["dark", "light", "system"].contains(appearance) { throw LensError.invalid("Unknown appearance") }
        if let endpoint = request["settings"]?["vibeqURL"]?.stringValue {
            guard let url = URLComponents(string: endpoint), url.host != nil, ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { throw LensError.invalid("Enter a valid VibeQ endpoint") }
        }
        for (key, value) in request["settings"]?.objectValue ?? [:] where ["codexModel", "trashRetentionDays", "trashMaxMiB", "appearance", "capturePaused", "shortcutEnabled", "transcriptionModel", "vibeqURL"].contains(key) {
            if let text = value.stringValue { defaults.set(text, forKey: key) }
        }
        for key in ["openai", "vibeq"] { if let value = request[key]?.stringValue { try KeychainStore.set(key: key, value: value) } }
        guard defaults.synchronize() else { throw LensError.storage("Could not save notebook settings") }
        if request["settings"]?["capturePaused"] != nil { try bridge.saveConfiguration(projects: bridgeProjects()) }
    case "new":
        let profile = try project(request["projectId"]?.stringValue ?? "")
        let item = NotebookObservation(projectId: profile.id)
        try store.save(item); extra["selectedObservationId"] = .string(item.id)
    case "archive", "trash", "restoreObservation":
        var item = try observation(request)
        switch request["action"]?.stringValue {
        case "archive": item.archivedAt = item.archivedAt == nil ? nowMilliseconds() : nil
        case "trash": item.trashedAt = nowMilliseconds()
        default: item.trashedAt = nil
        }
        try store.save(item)
    case "rebaseBackup":
        guard let old = request["oldRoot"]?.stringValue, old.hasPrefix("/"), old != "/" else { throw LensError.invalid("Invalid backup origin") }
        try VibeQClient.rebaseBackup(store: store, oldRoot: old, newRoot: request["newRoot"]?.stringValue)
    case "edit":
        var item = try observation(request)
        if let title = request["title"]?.stringValue { item.title = title }
        if let markdown = request["markdown"]?.stringValue { item.markdown = markdown }
        edited(&item); try store.save(item)
    case "annotate":
        var item = try observation(request)
        guard let id = request["captureId"]?.stringValue, let index = item.captures.firstIndex(where: { $0.id == id }),
              let annotations = try request["annotations"]?.decode([Annotation].self), annotations.count <= 500,
              annotations.allSatisfy({ ["rectangle", "mask", "arrow", "pen"].contains($0.kind) && $0.points.count >= 2 && $0.points.count <= 10_000 && $0.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) }),
              let filename = request["filename"]?.stringValue, filename.hasPrefix(id + "-reviewed-"), filename.hasSuffix(".png") else { throw LensError.invalid("Invalid annotation or reviewed image") }
        let url = try store.artifactURL(observationId: item.id, filename: filename)
        guard try Data(contentsOf: url).starts(with: [137,80,78,71,13,10,26,10]) else { throw LensError.invalid("Reviewed image is not PNG") }
        item.captures[index].annotations = annotations
        item.captures[index].originalScreenshotPath = item.captures[index].originalScreenshotPath ?? item.captures[index].screenshotPath
        item.captures[index].screenshotPath = url.path
        let capture = item.captures[index]
        item.captures[index].context["annotationBindings"] = .array(SpatialAnnotationResolver.bindings(annotations: annotations, capture: capture))
        item.captures[index].context["selectedElementRefs"] = .array(SpatialAnnotationResolver.references(annotations: annotations, capture: capture).map(JSONValue.string))
        edited(&item); try store.save(item)
    case "nativeMedia", "reviewVideo":
        var item = try observation(request)
        guard let id = request["captureId"]?.stringValue, let index = item.captures.firstIndex(where: { $0.id == id }) else { throw LensError.invalid("Select a saved capture") }
        if request["action"]?.stringValue == "reviewVideo" {
            guard item.captures[index].context["videoPath"]?.stringValue != nil, let reviewed = request["reviewed"]?.boolValue else { throw LensError.invalid("Review the saved recording first") }
            item.captures[index].context["videoReviewed"] = .bool(reviewed)
        } else {
            guard let identity = try request["identity"]?.decode(CaptureIdentity.self), identity == item.captures[index].identity else { throw LensError.invalid("Native media belongs to a different browser capture") }
            func mediaFile(_ field: String, _ prefix: String, _ suffix: String) throws -> URL? {
                guard let name = request[field]?.stringValue else { return nil }
                guard name.hasPrefix(id + prefix), name.hasSuffix(suffix) else { throw LensError.invalid("Invalid native media filename") }
                let url = try store.artifactURL(observationId: item.id, filename: name)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 64 * 1024 * 1024 else { throw LensError.invalid("Native media exceeds its size limit") }
                return url
            }
            if let image = try mediaFile("screenshot", "-native-", ".png"), item.captures[index].screenshotPath == nil {
                guard let timestamp = request["nativeCapturedAt"]?.doubleValue, timestamp.isFinite,
                      timestamp <= identity.capturedAt + 100, identity.capturedAt - timestamp <= 2_000,
                      let width = request["pixelWidth"]?.intValue, let height = request["pixelHeight"]?.intValue,
                      width > 0, height > 0, width <= 1440, height <= 900,
                      try Data(contentsOf: image).starts(with: [137,80,78,71,13,10,26,10]) else { throw LensError.invalid("Native screenshot time or geometry does not match this capture") }
                item.captures[index].screenshotPath = image.path; item.captures[index].originalScreenshotPath = image.path
                item.captures[index].context["coordinateSpace"] = .string("native-window")
                item.captures[index].context["nativeCapturedAt"] = .number(timestamp)
                item.captures[index].context["pixelWidth"] = .number(Double(width)); item.captures[index].context["pixelHeight"] = .number(Double(height))
                item.captures[index].context["annotationBindings"] = .array([]); item.captures[index].context["selectedElementRefs"] = .array([])
                item.captures[index].gaps.append(CoverageGap(channel: "spatial-binding", reason: "Native image from the user-selected portal window; the OS window is not independently matched to the browser tab. It may include browser chrome. DOM coordinates are not bound to this image."))
            }
            if let video = try mediaFile("video", "-video-", ".mp4") {
                guard let seconds = request["videoSeconds"]?.doubleValue, seconds.isFinite, seconds > 0, seconds <= 30,
                      try Data(contentsOf: video).dropFirst(4).prefix(4) == Data("ftyp".utf8) else { throw LensError.invalid("Native recording is invalid") }
                item.captures[index].context["videoPath"] = .string(video.path)
                item.captures[index].context["videoSeconds"] = .number(seconds)
                item.captures[index].context["videoReviewed"] = .bool(false)
                item.captures[index].context["videoCoordinateSpace"] = .string("native-window")
                item.captures[index].gaps.append(CoverageGap(channel: "video-window", reason: "The recording comes from the user-selected portal window. Browser tab identity is checked against collector status; the OS window is not independently matched to the tab."))
            }
        }
        edited(&item); try store.save(item)
    case "capture", "resumeTab", "pause", "openOptions":
        let kind = request["action"]!.stringValue!
        guard var payload = request["payload"]?.objectValue else { throw LensError.invalid("Missing browser command") }
        if kind == "openOptions" {
            guard let client = payload["clientId"]?.stringValue, try bridge.connectedClientIDs().contains(client) else { throw LensError.invalid("Connect this browser profile before opening its permissions") }
        }
        if kind == "capture" {
            guard let projectID = payload.removeValue(forKey: "projectId")?.stringValue else { throw LensError.invalid("Select a browser tab") }
            _ = try project(projectID)
            if let id = payload["observationId"]?.stringValue {
                guard try store.observation(id: id)?.projectId == projectID else { throw LensError.invalid("Observation belongs to another project") }
            } else { payload["observationId"] = .string(UUID().uuidString) }
            payload["captureId"] = .string(UUID().uuidString)
        }
        try bridge.send(kind: kind, payload: .object(payload))
    case "export":
        let item = try observation(request)
        guard let path = request["destination"]?.stringValue, path.hasPrefix("/") else { throw LensError.invalid("Choose an export directory") }
        extra["exportPath"] = .string(try store.export(observation: item, to: URL(fileURLWithPath: path, isDirectory: true)).path)
    case "importExport":
        let profile = try project(request["projectId"]?.stringValue ?? "")
        guard let path = request["source"]?.stringValue, path.hasPrefix("/") else { throw LensError.invalid("Choose a portable report folder") }
        let item = try store.importObservation(from: URL(fileURLWithPath: path, isDirectory: true), projectId: profile.id)
        extra["selectedObservationId"] = .string(item.id)
    case "investigate", "cloud":
        let original = try observation(request), profile = try project(original.projectId)
        var selected = original
        let cloud = request["action"]?.stringValue == "cloud"
        if cloud {
            guard request["reviewed"]?.boolValue == true else { throw LensError.invalid("Review the notebook text and selected captures before cloud investigation") }
            guard request["reviewedVersion"]?.intValue == original.editVersion else { throw LensError.invalid("The observation changed after review. Review its current text and evidence before sending.") }
            let ids = Set(request["captureIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            for index in selected.captures.indices { selected.captures[index].context["includeInAI"] = .bool(ids.contains(selected.captures[index].id)) }
            selected = try EvidenceSanitizer.cloudImages(EvidenceSanitizer.cloudSelection(selected))
        }
        progress(.object(["kind": .string("investigation"), "detail": .string(cloud ? "Investigating reviewed evidence" : "Reading local evidence and source")]))
        var findings = try await Investigator.investigate(observation: selected, project: profile, apiKey: nil, onProgress: { findings in
            progress(.object(["kind": .string("investigation"), "detail": .string("\(findings.count) findings collected")]))
        })
        let draft: String
        if cloud {
            let result = try CodexClient().investigate(observation: selected, findings: findings, store: store, model: settings()["codexModel"]!, onProgress: { detail in
                progress(.object(["kind": .string("investigation"), "detail": .string(detail)]))
            })
            findings += result.findings; draft = result.markdown
        } else { draft = try await Investigator.makeDraft(observation: selected, project: profile, findings: findings, apiKey: nil) }
        var current = try observation(request)
        current.findings = findings; edited(&current); try store.save(current)
        extra["suggestedDraft"] = .string(draft)
        extra["investigationObservationId"] = .string(original.id)
    case "codexStatus": extra["codexStatus"] = .string(CodexClient().status())
    case "members":
        let item = try observation(request), profile = try project(item.projectId)
        guard let token = try KeychainStore.get(key: "vibeq"), !token.isEmpty, let url = URL(string: settings()["vibeqURL"]!) else { throw LensError.invalid("Save a VibeQ endpoint and token in Settings before loading members") }
        let members = try await VibeQClient(baseURL: url, token: token).members()
        extra["members"] = try .from(members)
        if let owner = profile.ownership.last(where: { rule in
            item.findings.contains { finding in
                guard let source = finding.source else { return false }
                var path = source.components(separatedBy: ":")[0]
                if path.hasPrefix(profile.repositoryPath + "/") { path.removeFirst(profile.repositoryPath.count + 1) }
                return Investigator.globMatches(rule.pattern, path: path)
            }
        }), members.contains(where: { $0.id == owner.memberId }) { extra["suggestedAssigneeId"] = .string(owner.memberId) }
    case "reviewFiling":
        let item = try observation(request)
        let pending = try VibeQClient.pendingSubmission(observationId: item.id, revision: item.draftRevision, store: store)
        extra["review"] = try .from(pending?.observation ?? EvidenceSanitizer.exportable(item))
        extra["assigneeId"] = .string(pending?.assigneeId ?? "")
        extra["frozen"] = .bool(pending != nil)
    case "file":
        guard request["reviewed"]?.boolValue == true, let revision = request["revision"]?.intValue else { throw LensError.invalid("Review the frozen report before filing") }
        let saved = try observation(request)
        let pending = try VibeQClient.pendingSubmission(observationId: saved.id, revision: revision, store: store)
        let snapshot = try pending?.observation ?? EvidenceSanitizer.exportable(saved)
        guard request["reviewedVersion"]?.intValue == snapshot.editVersion, revision == snapshot.draftRevision else { throw LensError.invalid("The observation changed after review. Review its current revision before filing.") }
        let profile = try project(snapshot.projectId)
        let client = VibeQClient(baseURL: URL(string: settings()["vibeqURL"]!) ?? URL(string: "http://localhost:3001")!, token: try KeychainStore.get(key: "vibeq") ?? "")
        let assignee = request["assigneeId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let receipt = try await client.file(observation: snapshot, project: profile, store: store, assigneeId: assignee, progress: { event in
            if let value = try? JSONValue.from(event) { progress(value) }
        })
        var current = try observation(.object(["observationId": .string(snapshot.id)]))
        current.receipt = receipt
        if current.editVersion != snapshot.editVersion { current.draftRevision = max(current.draftRevision, receipt.revision + 1) }
        try store.save(current); extra["receipt"] = try .from(receipt)
    default: throw LensError.invalid("Unknown notebook command")
    }
    extra["projects"] = try .from(store.projects())
    if ["bootstrap", "rebaseBackup"].contains(request["action"]?.stringValue ?? "") {
        extra["observations"] = try .from(store.observations())
    } else {
        var ids = Set((extra["update"]?["capturedObservationIDs"]?.arrayValue ?? []).compactMap(\.stringValue))
        if let id = request["observationId"]?.stringValue { ids.insert(id) }
        if let id = extra["selectedObservationId"]?.stringValue { ids.insert(id) }
        if !ids.isEmpty { extra["observationUpdates"] = try .from(ids.sorted().compactMap { try store.observation(id: $0) }) }
    }
    extra["root"] = .string(store.root.path)
    extra["connectedClientIDs"] = try .from(bridge.connectedClientIDs())
    extra["settings"] = try .from(settings())
    return .object(extra)
}

do {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 1_048_576 else { throw LensError.invalid("Notebook command exceeds 1 MiB") }
    let result = try await handle(JSONDecoder().decode(JSONValue.self, from: data))
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(result))
} catch {
    let response = JSONValue.object(["error": .string(error.localizedDescription)])
    try? FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response))
    exit(1)
}
