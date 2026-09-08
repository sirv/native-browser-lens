import AppKit
import SwiftUI
import LensCore

@MainActor
final class LensAppModel: ObservableObject {
    @Published var projects: [ProjectProfile] = []
    @Published var observations: [NotebookObservation] = []
    @Published var selectedObservationID: String?
    @Published var selectedProjectID: String?
    @Published var selectedTabKey: String?
    @Published var tabs: [TabStatus] = []
    @Published var selectedCaptureID: String?
    @Published var errorMessage: String?
    @Published var notice = "Your observations stay on this Mac."
    @Published var paused = UserDefaults.standard.bool(forKey: "lens.capturePaused")
    @Published var capturing = false
    @Published var investigating = false
    @Published var filing = false
    @Published var recordingVideo = false
    @Published var videoStatus = "Video is off"
    @Published var showSettings = false
    @Published var showReview = false
    @Published var suggestedDraft: String?
    @Published var suggestedDraftObservationID: String?
    @Published var members: [VibeQMember] = []
    @Published var assigneeID = ""
    @Published var filingProgress: [String: FilingProgress] = [:]
    @Published var filingSnapshot: NotebookObservation?
    @Published var unsavedCaptureCount = 0
    @Published var speech = SpeechCapture()
    @Published var lastBridgeAt: Date?
    @Published var latestEvent: EvidenceEvent?
    @Published var appearance: String = UserDefaults.standard.string(forKey: "lens.appearance") ?? "dark" {
        didSet { UserDefaults.standard.set(appearance, forKey: "lens.appearance") }
    }
    var investigationModel: String { UserDefaults.standard.string(forKey: "lens.investigationModel") ?? "gpt-5.6-terra" }
    var transcriptionModel: String { UserDefaults.standard.string(forKey: "lens.transcriptionModel") ?? "gpt-live-transcribe" }
    var vibeqURL: String { UserDefaults.standard.string(forKey: "lens.vibeqURL") ?? "http://localhost:3001" }
    let store: EvidenceStore
    let bridge: BridgeMailbox
    private let revealWindows: Bool
    private let video = RollingVideo()
    private var inboxWatch: BridgeWatch?
    private var filingAssigneeID = ""
    private var videoChanging = false
    private var lastVideoAttemptKey: String?
    private var dictationObservationID: String?
    private var dictationAnchorVersion = 0
    private var pending: [String: PendingCapture] = [:]
    private var chunks: [String: [Int: Data]] = [:]
    private var chunkCounts: [String: Int] = [:]
    private var clients: [String: [TabStatus]] = [:]
    private var seenMessageIDs = Set<String>()
    private var captureWireIDs: [String: Set<String>] = [:]
    private var failedCaptures: [String: FailedCapture] = [:]
    private var blockedMessageIDs = Set<String>()
    private var timedOutCaptures = Set<String>()
    private var investigationRunID: UUID?

    private struct FailedCapture {
        let observationID: String
        var record: CaptureRecord
        let image: Data?
    }

    private struct PendingCapture {
        let observationID: String
        let tab: TabStatus
        let started: Date
        let capturedAt: Double
        let fallback: Task<NativeWindowImage, Error>?
    }

    init(root: URL = LensPaths.defaultRoot, watchBridge: Bool = true, revealWindows: Bool = true) {
        self.revealWindows = revealWindows
        store = EvidenceStore(root: root); bridge = BridgeMailbox(root: root)
        do {
            projects = try store.projects()
            observations = try store.observations().sorted { $0.createdAt > $1.createdAt }
            selectedObservationID = observations.first?.id
            selectedProjectID = observations.first?.projectId ?? projects.first?.id
            try bridge.saveConfiguration(projects: effectiveProjects(projects))
            try bridge.send(kind: "pause", payload: .object(["paused": .bool(paused)]))
        } catch { errorMessage = error.localizedDescription }
        speech.onCompleted = { [weak self] text in self?.appendTranscript(text) }
        speech.onFailure = { [weak self] text in self?.errorMessage = text }
        video.onFailure = { [weak self] text in
            self?.recordingVideo = false; self?.videoStatus = text
        }
        if watchBridge {
            do { inboxWatch = try bridge.watchInbox(queue: .main) { [weak self] in Task { @MainActor in self?.poll() } }; poll() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    var current: NotebookObservation? { observations.first { $0.id == selectedObservationID } }
    var currentProject: ProjectProfile? { projects.first { $0.id == (current?.projectId ?? selectedProjectID) } }
    var currentCapture: CaptureRecord? { current?.captures.first { $0.id == selectedCaptureID } ?? current?.captures.last }
    var selectedTab: TabStatus? { tabs.first { tabKey($0) == selectedTabKey } }
    var armedCount: Int { tabs.filter { ["deep", "devtools"].contains($0.mode) }.count }
    var statusText: String {
        if paused { return "Capture paused" }
        if recordingVideo { return "\(armedCount) tabs · video armed" }
        if armedCount > 0 { return "\(armedCount) \(armedCount == 1 ? "tab" : "tabs") connected" }
        return lastBridgeAt == nil ? "Connect Chrome" : "No project tabs"
    }

    func tabKey(_ tab: TabStatus) -> String { "\(tab.clientId ?? "default"):\(tab.tabId)" }
    func selectObservation(_ id: String) {
        selectedObservationID = id; selectedCaptureID = nil
        selectedProjectID = current?.projectId
    }

    func saveProjects(_ incoming: [ProjectProfile]) {
        let updated = incoming.map { item -> ProjectProfile in
            var item = item
            item.origins = item.origins.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
            item.documentationPaths = item.documentationPaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            item.logPaths = item.logPaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return item
        }
        do {
            for project in updated {
                for origin in project.origins {
                    guard let url = URLComponents(string: origin), ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
                          (url.path.isEmpty || url.path == "/"), url.query == nil, url.fragment == nil, url.user == nil else {
                        throw LensError.invalid("Use exact origins such as https://dev.sirv.studio, without paths or credentials.")
                    }
                }
            }
            try store.saveProjects(updated); try bridge.saveConfiguration(projects: effectiveProjects(updated))
            projects = updated
            if selectedProjectID == nil { selectedProjectID = updated.first?.id }
            lastVideoAttemptKey = nil
            updateVideo()
            notice = "Projects saved. Grant their origins in the Chrome extension to connect."
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult func newObservation(projectID: String? = nil) -> String? {
        guard let id = projectID ?? selectedProjectID ?? selectedTab?.projectId ?? projects.first?.id else { showSettings = true; return nil }
        let observation = NotebookObservation(projectId: id)
        observations.insert(observation, at: 0)
        selectedObservationID = observation.id; selectedProjectID = id; selectedCaptureID = nil
        persist(observation); return observation.id
    }

    func edit(title: String? = nil, markdown: String? = nil) {
        guard let id = selectedObservationID else { return }
        mutate(id, edited: true) { item in
            if let title { item.title = title }
            if let markdown { item.markdown = markdown }
        }
    }

    func togglePause() {
        let next = !paused
        paused = next; UserDefaults.standard.set(next, forKey: "lens.capturePaused")
        if next { Task { await video.stop(); recordingVideo = false; videoStatus = "Video paused" } }
        else { lastVideoAttemptKey = nil }
        do {
            try bridge.saveConfiguration(projects: effectiveProjects(projects))
            try bridge.send(kind: "pause", payload: .object(["paused": .bool(next)]))
            updateVideo()
        } catch { errorMessage = error.localizedDescription }
    }
    private func effectiveProjects(_ profiles: [ProjectProfile]) -> [ProjectProfile] {
        guard paused else { return profiles }
        return profiles.map { profile in var copy = profile; copy.enabled = false; return copy }
    }

    func capture(preferForeground: Bool = false) {
        guard !paused else { errorMessage = "Resume capture before adding a screenshot."; return }
        var chosen = selectedTab
        if preferForeground {
            // Never guess between active tabs in separate windows.
            let active = tabs.filter { $0.active && ["deep", "devtools", "handover"].contains($0.mode) }
            let foreground = frontmostChromeTitle()
            let matching = active.filter { $0.title == foreground || "\($0.title) - Google Chrome" == foreground }
            if matching.count == 1 { chosen = matching.first }
            else if active.count == 1 { chosen = active.first }
            else { chosen = nil }
        }
        guard let tab = chosen, ["deep", "devtools", "handover"].contains(tab.mode) else {
            errorMessage = "Choose a connected project tab. With multiple Chrome windows, select the target tab in Lens first."
            reveal(); return
        }
        let observationID: String
        if let observation = current, observation.projectId == tab.projectId { observationID = observation.id }
        else { guard let id = newObservation(projectID: tab.projectId) else { return }; observationID = id }
        let captureID = UUID().uuidString
        let fallback: Task<NativeWindowImage, Error>? = (tab.mode == "devtools" || CGPreflightScreenCaptureAccess()) ? Task { try await NativeScreenshot.capture(title: tab.title) } : nil
        pending[captureID] = PendingCapture(observationID: observationID, tab: tab, started: Date(), capturedAt: nowMilliseconds(), fallback: fallback)
        capturing = true; notice = "Capturing the page before opening your notebook…"
        do {
            var payload: [String: JSONValue] = ["tabId": .number(Double(tab.tabId)), "observationId": .string(observationID), "captureId": .string(captureID)]
            if let client = tab.clientId { payload["clientId"] = .string(client) }
            try bridge.send(kind: "capture", payload: .object(payload))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.expireCapture(captureID)
            }
        } catch { pending.removeValue(forKey: captureID); fallback?.cancel(); capturing = !pending.isEmpty; errorMessage = error.localizedDescription }
    }

    private func frontmostChromeTitle() -> String? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome",
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.first { ($0[kCGWindowOwnerName as String] as? String) == "Google Chrome" && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowName as String] as? String
    }

    private func poll() {
        do {
            var count = 0
            repeat {
                let messages = try bridge.pending(excluding: seenMessageIDs); count = messages.count
                for message in messages {
                    seenMessageIDs.insert(message.id)
                    do {
                        try receive(message)
                        if !captureWireIDs.values.contains(where: { $0.contains(message.id) }) {
                            try bridge.acknowledge([message.id]); seenMessageIDs.remove(message.id)
                        }
                    } catch {
                        let malformed: Bool
                        if error is DecodingError { malformed = true }
                        else if case LensError.invalid = error { malformed = true }
                        else { malformed = false }
                        guard malformed else {
                            blockedMessageIDs.insert(message.id)
                            unsavedCaptureCount = failedCaptures.count + blockedMessageIDs.count
                            errorMessage = "Browser evidence is retained while storage is unavailable: " + error.localizedDescription
                            continue
                        }
                        // Preserve malformed messages privately before acknowledging them.
                        // A storage failure leaves the original durable inbox item in place.
                        let details = JSONValue.object(["error": .string(error.localizedDescription), "message": try .from(message)])
                        _ = try store.saveArtifact(observationId: stableUUID("lens-transport-errors"), filename: message.id + ".json", data: JSONEncoder().encode(details))
                        try bridge.acknowledge([message.id]); seenMessageIDs.remove(message.id)
                        errorMessage = "A browser message could not be read. Its details were saved locally: " + error.localizedDescription
                    }
                }
            } while count >= 256
        }
        catch { errorMessage = error.localizedDescription }
        capturing = pending.keys.contains { !timedOutCaptures.contains($0) }
        updateVideo()
    }
    private func expireCapture(_ id: String) {
        guard pending[id] != nil, timedOutCaptures.insert(id).inserted else { return }
        // Slow or disconnected collectors may still deliver a final message.
        // Keep the start and parts so a late reply or app restart can recover them.
        errorMessage = "Chrome has not returned this capture after 20 seconds. Received evidence is retained; check the extension connection."
        capturing = pending.keys.contains { !timedOutCaptures.contains($0) }
    }

    private func receive(_ message: WireMessage) throws {
        guard message.version == 1 else { return }
        let payload = message.payload
        switch message.kind {
        case "hello": lastBridgeAt = Date()
        case "capture-started":
            guard ["extension", "native"].contains(payload["initiatedBy"]?.stringValue ?? ""),
                  let observationID = payload["observationId"]?.stringValue, UUID(uuidString: observationID) != nil,
                  let captureID = payload["captureId"]?.stringValue, UUID(uuidString: captureID) != nil,
                  let identity = try payload["identity"]?.decode(CaptureIdentity.self),
                  var tab = try payload["tab"]?.decode(TabStatus.self),
                  let clientID = payload["clientId"]?.stringValue, identity.clientId == clientID,
                  identity.projectId == tab.projectId, identity.tabId == tab.tabId, identity.documentId == tab.documentId,
                  !identity.documentId.isEmpty,
                  let project = projects.first(where: { $0.id == identity.projectId && $0.enabled }),
                  let components = URLComponents(string: identity.url), let scheme = components.scheme, let host = components.host,
                  project.origins.contains("\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")),
                  !observations.contains(where: { $0.captures.contains(where: { $0.id == captureID }) }) else { return }
            tab.clientId = clientID
            if let existing = pending[captureID] {
                guard existing.observationID == observationID, existing.tab.clientId == clientID,
                      existing.tab.tabId == tab.tabId, existing.tab.projectId == tab.projectId else { return }
                captureWireIDs[captureID, default: []].insert(message.id)
                return
            }
            if let existing = observations.first(where: { $0.id == observationID }) {
                guard existing.projectId == project.id else { return }
            } else {
                let observation = NotebookObservation(id: observationID, projectId: project.id, title: identity.title.isEmpty ? "Untitled observation" : identity.title)
                // The retained start envelope is the durable pending record.
                // Do not let an initial database error prevent later parts from
                // joining this capture; commit the notebook with its full record.
                observations.insert(observation, at: 0)
            }
            let fresh = abs(nowMilliseconds() - identity.capturedAt) < 2_000
            let fallback: Task<NativeWindowImage, Error>? = revealWindows && fresh && (tab.mode == "devtools" || CGPreflightScreenCaptureAccess()) ? Task { try await NativeScreenshot.capture(title: tab.title) } : nil
            pending[captureID] = PendingCapture(observationID: observationID, tab: tab, started: Date(), capturedAt: identity.capturedAt, fallback: fallback)
            captureWireIDs[captureID, default: []].insert(message.id)
            capturing = true
            Task { [weak self] in try? await Task.sleep(nanoseconds: 20_000_000_000); self?.expireCapture(captureID) }
        case "status":
            let incoming = try payload["tabs"]?.decode([TabStatus].self) ?? []
            clients[payload["clientId"]?.stringValue ?? "default"] = incoming
            tabs = clients.values.flatMap { $0 }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            lastBridgeAt = Date()
            if !tabs.contains(where: { tabKey($0) == selectedTabKey }) {
                let active = tabs.filter { $0.active }
                selectedTabKey = active.count == 1 ? active.first.map(tabKey) : nil
            }
        case "event": latestEvent = try? payload.decode(EvidenceEvent.self)
        case "artifact":
            guard let id = payload["captureId"]?.stringValue, let request = pending[id],
                  request.observationID == payload["observationId"]?.stringValue,
                  request.tab.clientId == payload["clientId"]?.stringValue,
                  let index = payload["index"]?.intValue, let total = payload["total"]?.intValue,
                  total > 0, total <= 512, index >= 0, index < total,
                  let text = payload["data"]?.stringValue, text.count <= 300_000,
                  let part = Data(base64Encoded: text) else { return }
            if let previous = chunkCounts[id], previous != total { throw LensError.invalid("Screenshot parts disagree on their total.") }
            let existingBytes = chunks[id]?.values.reduce(0) { $0 + $1.count } ?? 0
            guard existingBytes + part.count <= 64 * 1024 * 1024 else { throw LensError.invalid("Screenshot exceeds the 64 MiB capture limit.") }
            chunkCounts[id] = total; chunks[id, default: [:]][index] = part
            captureWireIDs[id, default: []].insert(message.id)
        case "capture":
            guard let id = payload["captureId"]?.stringValue, let request = pending[id],
                  request.observationID == payload["observationId"]?.stringValue,
                  let identity = try payload["identity"]?.decode(CaptureIdentity.self),
                  identity.projectId == request.tab.projectId, identity.tabId == request.tab.tabId,
                  identity.clientId == request.tab.clientId else { return }
            captureWireIDs[id, default: []].insert(message.id)
            var screenshot = payload["screenshotBase64"]?.stringValue.flatMap { Data(base64Encoded: $0) }
            if screenshot == nil, let parts = chunks[id], let count = chunkCounts[id], parts.count == count {
                screenshot = (0..<count).reduce(into: Data()) { $0.append(parts[$1] ?? Data()) }
            }
            let events = try payload["events"]?.decode([EvidenceEvent].self) ?? []
            let gaps = try payload["gaps"]?.decode([CoverageGap].self) ?? []
            let context = payload["context"]?.objectValue ?? [:]
            let omission = payload["screenshotOmission"]?.stringValue
            pending.removeValue(forKey: id); chunks.removeValue(forKey: id); chunkCounts.removeValue(forKey: id)
            timedOutCaptures.remove(id)
            Task { await finishCapture(id: id, request: request, identity: identity, screenshot: screenshot, events: events, gaps: gaps, context: context, omission: omission) }
        case "error":
            let error = payload["message"]?.stringValue ?? "The browser collector reported an error."
            if payload["poison"]?.boolValue == true {
                _ = try store.saveArtifact(observationId: stableUUID("lens-transport-errors"), filename: message.id + ".json", data: JSONEncoder().encode(message))
            }
            if let id = payload["captureId"]?.stringValue, let request = pending[id], request.observationID == payload["observationId"]?.stringValue,
               request.tab.clientId == payload["clientId"]?.stringValue {
                captureWireIDs[id, default: []].insert(message.id)
                pending.removeValue(forKey: id); timedOutCaptures.remove(id)
                var identity = CaptureIdentity(projectId: request.tab.projectId, tabId: request.tab.tabId, windowId: request.tab.windowId, documentId: request.tab.documentId, url: request.tab.url, title: request.tab.title, capturedAt: request.capturedAt)
                identity.clientId = request.tab.clientId
                Task { await finishCapture(id: id, request: request, identity: identity, screenshot: nil, events: [], gaps: [CoverageGap(channel: "capture", reason: error)], context: [:], omission: error) }
            }
            errorMessage = error
        default: break
        }
    }

    private func finishCapture(id: String, request: PendingCapture, identity: CaptureIdentity, screenshot: Data?, events: [EvidenceEvent], gaps: [CoverageGap], context: [String: JSONValue], omission: String?) async {
        var record = CaptureRecord(id: id, identity: identity, events: events.filter { $0.projectId == identity.projectId && $0.tabId == identity.tabId }, gaps: gaps, context: context)
        var image = screenshot
        do {
            if image == nil, let fallback = request.fallback, identity.documentId == request.tab.documentId, identity.windowId == request.tab.windowId {
                do {
                    let native = try await fallback.value; image = native.data
                    record.context["coordinateSpace"] = .string("native-window")
                    record.context["nativeWindowId"] = .number(Double(native.windowID))
                    record.context["pixelWidth"] = .number(Double(native.width)); record.context["pixelHeight"] = .number(Double(native.height))
                    record.gaps.append(CoverageGap(channel: "spatial-binding", reason: "Native window image includes browser chrome. DOM coordinates are not bound to this image."))
                } catch { record.gaps.append(CoverageGap(channel: "screenshot", reason: error.localizedDescription)) }
            } else { request.fallback?.cancel() }
            if image == nil { record.gaps.append(CoverageGap(channel: "screenshot", reason: omission ?? "No screenshot was supplied by the browser or native capture.")) }
            if identity.documentId != request.tab.documentId {
                record.gaps.append(CoverageGap(channel: "spatial-binding", reason: "The document changed during capture. Annotations cannot be assigned to elements from the earlier document."))
            }
            try persistCompletedCapture(observationID: request.observationID, record: &record, image: image)
            selectedObservationID = request.observationID; selectedProjectID = identity.projectId; selectedCaptureID = id
            notice = "Capture saved · \(record.events.count) events · \(record.gaps.count) coverage notes"
            capturing = pending.keys.contains { !timedOutCaptures.contains($0) }
            reveal()
            let key = RollingVideo.identityKey(request.tab)
            if video.tabKey == key {
                do {
                    let url = try store.artifactURL(observationId: request.observationID, filename: id + "-video.mp4")
                    let seconds = try await video.save(to: url, expectedKey: key)
                    mutate(request.observationID, edited: true) { item in
                        if let index = item.captures.firstIndex(where: { $0.id == id }) {
                            item.captures[index].context["videoPath"] = .string(url.path)
                            item.captures[index].context["videoSeconds"] = .number(seconds)
                            item.captures[index].context["videoReviewed"] = .bool(false)
                            item.captures[index].context["videoCoordinateSpace"] = .string("native-window")
                        }
                    }
                } catch { mutate(request.observationID, edited: true) { item in
                    if let index = item.captures.firstIndex(where: { $0.id == id }) { item.captures[index].gaps.append(CoverageGap(channel: "video", reason: error.localizedDescription)) }
                } }
            }
        } catch {
            failedCaptures[id] = FailedCapture(observationID: request.observationID, record: record, image: image)
            unsavedCaptureCount = failedCaptures.count + blockedMessageIDs.count
            errorMessage = "Capture is retained but could not be saved: " + error.localizedDescription
            notice = "Capture retained. Retry saving when storage is available."
            reveal()
        }
    }

    private func persistCompletedCapture(observationID: String, record: inout CaptureRecord, image: Data?) throws {
        guard let index = observations.firstIndex(where: { $0.id == observationID }) else { throw LensError.storage("The target observation is unavailable.") }
        if record.screenshotPath == nil, let image {
            let url = try store.saveArtifact(observationId: observationID, filename: record.id + "-original.png", data: image)
            record.screenshotPath = url.path; record.originalScreenshotPath = url.path
        }
        var observation = observations[index]
        if !observation.captures.contains(where: { $0.id == record.id }) {
            observation.captures.append(record); observation.editVersion += 1
            if let receipt = observation.receipt { observation.draftRevision = max(observation.draftRevision, receipt.revision + 1) }
            if observation.title == "Untitled observation", !record.identity.title.isEmpty { observation.title = record.identity.title }
        }
        // The complete observation must commit before any capture transport item is removed.
        try store.save(observation)
        observations[index] = observation
        let ids = captureWireIDs[record.id] ?? []
        try bridge.acknowledge(ids)
        seenMessageIDs.subtract(ids); captureWireIDs.removeValue(forKey: record.id)
    }

    func retryCaptureSaves() {
        errorMessage = nil
        seenMessageIDs.subtract(blockedMessageIDs); blockedMessageIDs.removeAll()
        poll()
        for (id, var failed) in failedCaptures {
            do {
                try persistCompletedCapture(observationID: failed.observationID, record: &failed.record, image: failed.image)
                failedCaptures.removeValue(forKey: id)
                selectedObservationID = failed.observationID; selectedCaptureID = id; selectedProjectID = failed.record.identity.projectId
            } catch { errorMessage = error.localizedDescription; break }
        }
        unsavedCaptureCount = failedCaptures.count + blockedMessageIDs.count
        if unsavedCaptureCount == 0 { notice = "Retained captures saved successfully." }
    }

    func annotate(_ annotation: Annotation) {
        guard let observation = current, let capture = currentCapture else { return }
        var annotations = capture.annotations; annotations.append(annotation)
        updateAnnotations(observationID: observation.id, capture: capture, annotations: annotations)
    }
    func undoAnnotation() {
        guard let observation = current, let capture = currentCapture, !capture.annotations.isEmpty else { return }
        updateAnnotations(observationID: observation.id, capture: capture, annotations: Array(capture.annotations.dropLast()))
    }
    private func updateAnnotations(observationID: String, capture: CaptureRecord, annotations: [Annotation]) {
        do {
            guard let path = capture.originalScreenshotPath ?? capture.screenshotPath else { return }
            let data = try ScreenshotDerivative.render(original: URL(fileURLWithPath: path), annotations: annotations)
            let derivative = try store.saveArtifact(observationId: observationID, filename: capture.id + "-reviewed-" + UUID().uuidString + ".png", data: data)
            mutate(observationID, edited: true) { item in
                guard let index = item.captures.firstIndex(where: { $0.id == capture.id }) else { return }
                item.captures[index].annotations = annotations; item.captures[index].screenshotPath = derivative.path
                item.captures[index].originalScreenshotPath = path
                let bindings = SpatialAnnotationResolver.bindings(annotations: annotations, capture: capture)
                item.captures[index].context["annotationBindings"] = .array(bindings)
                item.captures[index].context["selectedElementRefs"] = .array(SpatialAnnotationResolver.references(annotations: annotations, capture: capture).map { .string($0) })
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func dictate() {
        if speech.isRecording { speech.finish(); return }
        guard !speech.isConnecting && !speech.isFinishing else { return }
        if current == nil { _ = newObservation() }
        guard let observation = current else { return }
        dictationObservationID = observation.id; dictationAnchorVersion = observation.editVersion
        Task {
            do { try await speech.start(apiKey: try KeychainStore.get(key: "openai") ?? "", model: transcriptionModel) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    private func appendTranscript(_ text: String) {
        guard let id = dictationObservationID else { return }
        mutate(id, edited: true) { item in item.markdown += (item.markdown.isEmpty ? "" : "\n\n") + text }
        notice = "Dictation added to its original observation."
    }
    func insertPartialTranscript() {
        guard !speech.partial.isEmpty else { return }; appendTranscript(speech.partial); speech.cancel()
    }

    func investigate(useCloud: Bool) {
        guard let observation = current, let project = currentProject, !investigating else { return }
        let runID = UUID(); investigationRunID = runID
        investigating = true; notice = useCloud ? "Investigating selected, sanitized evidence…" : "Reading local source and documentation…"
        Task {
            defer { investigating = false; investigationRunID = nil }
            do {
                let key = useCloud ? try KeychainStore.get(key: "openai") : nil
                if useCloud && (key ?? "").isEmpty { throw LensError.invalid("Add an OpenAI API key in Settings, or choose local investigation.") }
                let findings = try await Investigator.investigate(observation: observation, project: project, apiKey: key, model: investigationModel, onProgress: { [weak self] findings in
                    Task { @MainActor in
                        guard let self, self.investigationRunID == runID else { return }
                        self.mutate(observation.id) { $0.findings = findings }
                    }
                })
                investigationRunID = nil
                mutate(observation.id) { $0.findings = findings }
                let draft = try await Investigator.makeDraft(observation: observation, project: project, findings: findings, apiKey: key, model: investigationModel)
                if let live = observations.first(where: { $0.id == observation.id }), live.editVersion == observation.editVersion && live.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    mutate(observation.id) { $0.markdown = draft }
                } else { suggestedDraft = draft; suggestedDraftObservationID = observation.id }
                notice = "Investigation ready. Facts and hypotheses are separated."
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func selectCloudCaptures(_ ids: Set<String>) {
        guard let id = selectedObservationID else { return }
        mutate(id) { item in
            for index in item.captures.indices { item.captures[index].context["includeInAI"] = .bool(ids.contains(item.captures[index].id)) }
        }
    }
    func applySuggestedDraft() {
        guard let draft = suggestedDraft, let id = suggestedDraftObservationID else { return }
        mutate(id, edited: true) { $0.markdown = draft }; suggestedDraft = nil; suggestedDraftObservationID = nil
    }

    func prepareReview() {
        members = []; assigneeID = ""; filingProgress = [:]
        if let observation = current, let receipt = observation.receipt,
           receipt.revision == observation.draftRevision, receipt.missingAttachments.isEmpty {
            filingSnapshot = nil
            for stage in ["prepare", "reconcile", "attachments", "submit", "receipt"] {
                filingProgress[stage] = FilingProgress(stage: stage, state: "completed", detail: stage == "receipt" ? "Task and attachments previously confirmed" : "Confirmed in saved receipt")
            }
            showReview = true
            return
        }
        if filingSnapshot?.id != current?.id || filingSnapshot?.draftRevision != current?.draftRevision { filingSnapshot = nil }
        if let observation = current {
            do {
                if let saved = try VibeQClient.pendingSubmission(observationId: observation.id, revision: observation.draftRevision, store: store) {
                    filingSnapshot = saved.observation; filingAssigneeID = saved.assigneeId ?? ""; assigneeID = filingAssigneeID
                    filingProgress["prepare"] = FilingProgress(stage: "prepare", state: "completed", detail: "Reviewed revision restored from local storage")
                    filingProgress["reconcile"] = FilingProgress(stage: "reconcile", state: "failed", detail: "Retry to recover the saved tracker outcome")
                }
            } catch { errorMessage = error.localizedDescription }
        }
        showReview = true
        Task {
            do {
                guard let url = URL(string: vibeqURL), let token = try KeychainStore.get(key: "vibeq"), !token.isEmpty else { return }
                members = try await VibeQClient(baseURL: url, token: token).members()
                let proposed = currentProject?.ownership.last { rule in
                    current?.findings.contains { finding in
                        guard let source = finding.source else { return false }
                        var path = source.components(separatedBy: ":")[0]
                        if let root = currentProject?.repositoryPath, path.hasPrefix(root + "/") { path.removeFirst(root.count + 1) }
                        return Investigator.globMatches(rule.pattern, path: path)
                    } == true
                }
                if filingSnapshot == nil, let proposed, members.contains(where: { $0.id == proposed.memberId }) { assigneeID = proposed.memberId }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func fileReviewed(observation: NotebookObservation, assigneeID: String) {
        guard let project = projects.first(where: { $0.id == observation.projectId }), !filing else { return }
        if filingSnapshot == nil {
            guard current?.id == observation.id && current?.editVersion == observation.editVersion && current?.draftRevision == observation.draftRevision else { errorMessage = "The observation changed during review. Review the current revision before filing."; return }
            filingSnapshot = observation; filingAssigneeID = assigneeID
        }
        filing = true
        errorMessage = nil
        Task { [self] in
            defer { filing = false }
            do {
                guard let url = URL(string: vibeqURL), let token = try KeychainStore.get(key: "vibeq"), !token.isEmpty else { throw LensError.invalid("Add the VibeQ endpoint and API token in Settings.") }
                let receipt = try await VibeQClient(baseURL: url, token: token).file(observation: observation, project: project, store: store, assigneeId: assigneeID.isEmpty ? nil : assigneeID, progress: { [weak self] event in
                    Task { @MainActor in self?.filingProgress[event.stage] = event }
                })
                mutate(observation.id) { item in
                    item.receipt = receipt
                    if item.editVersion != observation.editVersion || item.title != observation.title || item.markdown != observation.markdown || item.captures != observation.captures || item.findings != observation.findings {
                        item.draftRevision = max(item.draftRevision, receipt.revision + 1)
                    }
                }
                notice = receipt.missingAttachments.isEmpty ? "Filed to VibeQ. Receipt saved." : "Task filed. Some attachments still need recovery."
                if receipt.missingAttachments.isEmpty { filingSnapshot = nil }
            } catch {
                if !filingProgress.values.contains(where: { $0.state == "failed" }) {
                    filingProgress["prepare"] = FilingProgress(stage: "prepare", state: "failed", detail: error.localizedDescription)
                }
                errorMessage = error.localizedDescription
            }
        }
    }
    func retryFiling() {
        guard let observation = filingSnapshot else { return }
        fileReviewed(observation: observation, assigneeID: filingAssigneeID)
    }
    func export() {
        guard let observation = current else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Export notebook"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { let url = try store.export(observation: observation, to: folder); NSWorkspace.shared.activateFileViewerSelecting([url]); notice = "Markdown and reviewed evidence exported." }
        catch { errorMessage = error.localizedDescription }
    }

    func setVideoReviewed(_ value: Bool) {
        guard let observation = current, let capture = currentCapture else { return }
        mutate(observation.id, edited: true) { item in
            if let index = item.captures.firstIndex(where: { $0.id == capture.id }) { item.captures[index].context["videoReviewed"] = .bool(value) }
        }
    }
    func toggleVideo() {
        guard let tab = selectedTab, let index = projects.firstIndex(where: { $0.id == tab.projectId }) else { return }
        var updated = projects; updated[index].recording = updated[index].recording == "video" ? "diagnostics" : "video"; saveProjects(updated)
    }
    private func updateVideo() {
        guard !videoChanging else { return }
        let active = tabs.filter { $0.active && ["deep", "devtools"].contains($0.mode) }
        let tab = active.count == 1 ? active.first : selectedTab.flatMap { selected in active.first { tabKey($0) == tabKey(selected) } }
        guard !paused, let tab, projects.first(where: { $0.id == tab.projectId })?.recording == "video" else {
            if video.tabKey != nil { videoChanging = true; Task { await video.stop(); recordingVideo = false; videoStatus = "Video is off"; videoChanging = false } }
            lastVideoAttemptKey = nil; return
        }
        let key = RollingVideo.identityKey(tab)
        guard lastVideoAttemptKey != key else { return }
        lastVideoAttemptKey = key; videoChanging = true
        Task {
            defer { videoChanging = false; updateVideo() }
            do {
                try await video.start(tab: tab)
                guard !paused, projects.first(where: { $0.id == tab.projectId })?.recording == "video",
                      tabs.contains(where: { RollingVideo.identityKey($0) == key && $0.active }) else {
                    await video.stop(); recordingVideo = false; videoStatus = "Video is off"; return
                }
                recordingVideo = true; videoStatus = "Last 30 seconds · local only"
            }
            catch { recordingVideo = false; videoStatus = error.localizedDescription }
        }
    }

    private func mutate(_ id: String, edited: Bool = false, _ body: (inout NotebookObservation) -> Void) {
        guard let index = observations.firstIndex(where: { $0.id == id }) else { return }
        var item = observations[index]; body(&item)
        if edited { item.editVersion += 1; if let receipt = item.receipt { item.draftRevision = max(item.draftRevision, receipt.revision + 1) } }
        if let receipt = item.receipt {
            let prior = observations[index]
            if prior.title != item.title || prior.markdown != item.markdown || prior.captures != item.captures || prior.findings != item.findings {
                item.draftRevision = max(item.draftRevision, receipt.revision + 1)
            }
        }
        observations[index] = item; persist(item)
    }
    private func persist(_ observation: NotebookObservation) {
        do { try store.save(observation) } catch { errorMessage = error.localizedDescription }
    }
    func reveal() {
        guard revealWindows else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
