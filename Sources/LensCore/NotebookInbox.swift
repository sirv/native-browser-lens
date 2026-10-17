import Foundation

/// Replays the durable browser inbox without relying on a running notebook process.
public final class NotebookInbox {
    public struct Update: Codable {
        public var statuses: [JSONValue] = []
        public var captureStarts: [JSONValue] = []
        public var capturedObservationIDs: [String] = []
        public var errors: [String] = []
    }
    private let store: EvidenceStore
    private let bridge: BridgeMailbox
    public init(store: EvidenceStore) { self.store = store; bridge = BridgeMailbox(root: store.root) }

    public func sync() throws -> Update {
        var update = Update(), messages: [WireMessage] = [], seen = Set<String>()
        while true {
            let batch = try bridge.pending(excluding: seen)
            messages += batch; seen.formUnion(batch.map(\.id))
            if batch.count < 256 { break }
        }
        let captures = Set(["capture-started", "artifact", "capture"])
        for message in messages where !captures.contains(message.kind) {
            if message.kind == "status" { update.statuses.append(message.payload) }
            if message.kind == "error" {
                update.errors.append(message.payload["message"]?.stringValue ?? "Browser collector error")
                if message.payload["poison"]?.boolValue == true { try quarantine([message]) }
            }
            try bridge.acknowledge([message.id])
        }
        let groups = Dictionary(grouping: messages.filter { captures.contains($0.kind) }, by: { $0.payload["captureId"]?.stringValue ?? "invalid" })
        for (captureID, group) in groups.sorted(by: { ($0.value.first?.payload["identity"]?["capturedAt"]?.doubleValue ?? 0) < ($1.value.first?.payload["identity"]?["capturedAt"]?.doubleValue ?? 0) }) {
            do {
                if try commit(captureID: captureID, messages: group, update: &update) {
                    try bridge.acknowledge(Set(group.map(\.id)))
                    if let id = group.first?.payload["observationId"]?.stringValue { update.capturedObservationIDs.append(id) }
                }
            } catch let error as LensError {
                guard case .invalid = error else { throw error }
                try quarantine(group)
                try bridge.acknowledge(Set(group.map(\.id)))
                update.errors.append(error.localizedDescription + " Details retained locally.")
            } catch let error as DecodingError {
                try quarantine(group)
                try bridge.acknowledge(Set(group.map(\.id)))
                update.errors.append("Invalid browser capture retained locally: " + error.localizedDescription)
            }
        }
        return update
    }

    private func quarantine(_ messages: [WireMessage]) throws {
        _ = try store.saveArtifact(observationId: stableUUID("lens-transport-errors"), filename: UUID().uuidString + ".json", data: JSONEncoder().encode(messages))
    }

    private func commit(captureID: String, messages: [WireMessage], update: inout Update) throws -> Bool {
        guard UUID(uuidString: captureID) != nil else { throw LensError.invalid("Invalid capture identity") }
        if try store.containsCapture(id: captureID) { return true }
        guard let start = messages.first(where: { $0.kind == "capture-started" }) else { return false }
        let payload = start.payload
        guard let observationID = payload["observationId"]?.stringValue, UUID(uuidString: observationID) != nil,
              let clientID = payload["clientId"]?.stringValue, UUID(uuidString: clientID) != nil,
              ["extension", "native"].contains(payload["initiatedBy"]?.stringValue ?? ""),
              let identity = try payload["identity"]?.decode(CaptureIdentity.self),
              let tab = try payload["tab"]?.decode(TabStatus.self),
              identity.clientId == clientID, identity.projectId == tab.projectId, identity.tabId == tab.tabId,
              identity.windowId == tab.windowId, identity.documentId == tab.documentId, !identity.documentId.isEmpty,
              let project = try store.projects().first(where: { $0.id == identity.projectId }),
              let url = URLComponents(string: identity.url), let scheme = url.scheme, let host = url.host,
              project.origins.contains(scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")),
              messages.allSatisfy({ $0.payload["observationId"]?.stringValue == observationID && $0.payload["clientId"]?.stringValue == clientID }) else {
            throw LensError.invalid("Capture does not match its project, origin, document or browser profile")
        }
        update.captureStarts.append(payload)
        guard let final = messages.last(where: { $0.kind == "capture" }) else { return false }
        guard let finished = try final.payload["identity"]?.decode(CaptureIdentity.self),
              finished.clientId == clientID, finished.projectId == identity.projectId, finished.tabId == identity.tabId,
              finished.windowId == identity.windowId, finished.documentId == identity.documentId, finished.url == identity.url else {
            throw LensError.invalid("Capture identity changed during acquisition")
        }
        var screenshot = final.payload["screenshotBase64"]?.stringValue.flatMap { Data(base64Encoded: $0) }
        let parts = messages.filter { $0.kind == "artifact" }
        if screenshot == nil, !parts.isEmpty {
            guard let total = parts.first?.payload["total"]?.intValue, total > 0, total <= 512 else { throw LensError.invalid("Invalid screenshot part count") }
            var chunks: [Int: Data] = [:], size = 0
            for part in parts {
                guard part.payload["total"]?.doubleValue == Double(total), let index = part.payload["index"]?.intValue,
                      part.payload["index"]?.doubleValue == Double(index), index >= 0, index < total,
                      part.payload["mimeType"]?.stringValue == "image/png",
                      let text = part.payload["data"]?.stringValue, text.utf8.count <= 300_000,
                      let data = Data(base64Encoded: text) else { throw LensError.invalid("Invalid screenshot part") }
                size += data.count - (chunks[index]?.count ?? 0)
                guard size <= 64 * 1024 * 1024 else { throw LensError.invalid("Screenshot exceeds 64 MiB") }
                chunks[index] = data
            }
            guard chunks.count == total else { return false }
            screenshot = (0..<total).reduce(into: Data()) { $0.append(chunks[$1]!) }
        }
        if let screenshot, !screenshot.starts(with: [137,80,78,71,13,10,26,10]) { throw LensError.invalid("Browser screenshot is not PNG") }
        var observation = try store.observation(id: observationID) ?? NotebookObservation(id: observationID, projectId: project.id, title: identity.title.isEmpty ? "Untitled observation" : identity.title)
        guard observation.projectId == project.id else { throw LensError.invalid("Observation belongs to another project") }
        var record = CaptureRecord(id: captureID, identity: finished, events: try final.payload["events"]?.decode([EvidenceEvent].self) ?? [], gaps: try final.payload["gaps"]?.decode([CoverageGap].self) ?? [], context: final.payload["context"]?.objectValue ?? [:])
        if let screenshot {
            let url = try store.saveArtifact(observationId: observationID, filename: captureID + "-original.png", data: screenshot)
            record.screenshotPath = url.path; record.originalScreenshotPath = url.path
        } else {
            record.gaps.append(CoverageGap(channel: "screenshot", reason: final.payload["screenshotOmission"]?.stringValue ?? "No browser screenshot. Share the target window to enable native fallback, then capture again."))
        }
        observation.captures.append(record); observation.editVersion += 1
        if let receipt = observation.receipt { observation.draftRevision = max(observation.draftRevision, receipt.revision + 1) }
        try store.save(observation)
        return true
    }
}
