import Foundation

public enum DiagnosticArtifacts {
    public static func records(_ capture: CaptureRecord) -> [JSONValue] { capture.context["diagnosticArtifacts"]?.arrayValue ?? [] }
    static func summaryResult(_ value: JSONValue) -> JSONValue {
        var condition: [String: JSONValue] = [:]
        for key in ["type", "method"] {
            if let text = value["condition"]?[key]?.stringValue { condition[key] = .string(EvidenceSanitizer.text(String(text.prefix(250)))) }
        }
        if let url = value["condition"]?["url"]?.stringValue { condition["url"] = .string(safeURL(url)) }
        for key in ["failureStatus", "successStatus"] { if let number = value["condition"]?[key]?.doubleValue { condition[key] = .number(number) } }
        var summary: [String: JSONValue] = ["condition": .object(condition)]
        for key in ["observationId", "captureId", "failureEventId", "phase", "contractSHA256", "stepsSHA256", "scriptSHA256"] {
            if let text = value[key]?.stringValue { summary[key] = .string(EvidenceSanitizer.text(String(text.prefix(2000)))) }
        }
        for key in ["formatVersion", "startedAt", "finishedAt", "observedStatus", "matchingResponseCount"] {
            if let number = value[key]?.doubleValue { summary[key] = .number(number) }
        }
        if let complete = value["executionComplete"]?.boolValue { summary["executionComplete"] = .bool(complete) }
        if let build = value["buildId"]?.stringValue, build.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil { summary["buildId"] = .string(build) }
        if value["tool"]?.stringValue == "playwright" { summary["tool"] = .string("playwright") }
        if let origin = value["testOrigin"]?.stringValue, let url = URLComponents(string: origin), url.scheme == "http", url.host == "127.0.0.1", url.port != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty { summary["testOrigin"] = .string(origin) }
        if let failure = value["failure"], failure != .null { summary["failure"] = .string("Runner reported an error. Review the original diagnostic for details.") }
        return .object(summary)
    }
    public static func safeURL(_ text: String) -> String {
        guard var url = URLComponents(string: text), ["http", "https"].contains(url.scheme), url.host != nil else { return "[invalid URL]" }
        url.user = nil; url.password = nil; url.fragment = nil
        url.queryItems = url.queryItems?.map { item in
            return URLQueryItem(name: item.name, value: EvidenceSanitizer.isSensitiveField(item.name) ? "[redacted]" : item.value.map(EvidenceSanitizer.text))
        }
        return url.string ?? "[invalid URL]"
    }
    public static func harEvents(_ har: JSONValue, capture: CaptureRecord, importID: String) throws -> [EvidenceEvent] {
        guard let entries = har["log"]?["entries"]?.arrayValue, entries.count <= 10_000 else { throw LensError.invalid("HAR must contain at most 10000 entries") }
        let origin = URLComponents(string: capture.identity.url)
        let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainDate = ISO8601DateFormatter()
        func headers(_ value: JSONValue?) -> JSONValue {
            var result: [String: JSONValue] = [:]
            for entry in (value?.arrayValue ?? []).prefix(128) {
                guard let name = entry["name"]?.stringValue, let value = entry["value"]?.stringValue else { continue }
                result[String(name.prefix(128))] = .string(String(value.prefix(2000)))
            }
            return EvidenceSanitizer.json(.object(result))
        }
        return entries.prefix(1000).enumerated().compactMap { index, entry in
            guard let text = entry["request"]?["url"]?.stringValue, let url = URLComponents(string: text), url.scheme == origin?.scheme, url.host == origin?.host, (url.port ?? (url.scheme == "https" ? 443 : 80)) == (origin?.port ?? (origin?.scheme == "https" ? 443 : 80)) else { return nil }
            let stamp = entry["startedDateTime"]?.stringValue.flatMap { date.date(from: $0) ?? plainDate.date(from: $0) }?.timeIntervalSince1970
            var data: [String: JSONValue] = ["url": .string(safeURL(text)), "method": entry["request"]?["method"] ?? .string("UNKNOWN"), "status": entry["response"]?["status"] ?? .null, "durationMs": entry["time"] ?? .null, "requestHeaders": headers(entry["request"]?["headers"]), "responseHeaders": headers(entry["response"]?["headers"]), "requestId": .string("import-\(importID)-\(index)"), "sessionId": .string("import-" + importID), "provenance": .string("imported HAR; original document/target identity is not independently verified"), "bodyOmission": .string("Request/response bodies and cookies omitted from normalized evidence; original HAR stays local until separate attachment review")]
            if stamp != nil { data["startedDateTime"] = entry["startedDateTime"] }
            else { data["timingOmission"] = .string("Original timestamp missing; event timestamp is import time") }
            return EvidenceEvent(projectId: capture.identity.projectId, tabId: capture.identity.tabId, documentId: capture.identity.documentId, timestamp: stamp.map { $0 * 1000 } ?? nowMilliseconds(), kind: "devtools-network", data: EvidenceSanitizer.json(.object(data)).objectValue ?? [:])
        }
    }
    public static func attach(source: URL, type: String, to capture: inout CaptureRecord, observationId: String, store: EvidenceStore) throws {
        guard ["har", "trace", "profile", "verification"].contains(type), records(capture).count < 32 else { throw LensError.invalid("Choose HAR, trace ZIP, profile JSON or verification JSON; at most 32 diagnostic attachments per capture") }
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= (type == "trace" ? 64 : 16) * 1_048_576 else { throw LensError.invalid("Diagnostic must be a regular JSON file under 16 MiB or trace ZIP under 64 MiB") }
        let bytes = try Data(contentsOf: source), id = UUID().uuidString
        let value: JSONValue?
        if type == "trace" {
            guard bytes.starts(with: [80,75,3,4]) || bytes.starts(with: [80,75,5,6]) else { throw LensError.invalid("Trace is not a ZIP archive") }
            value = nil
        } else { value = try JSONDecoder().decode(JSONValue.self, from: bytes) }
        if type == "har", let value { capture.events += try harEvents(value, capture: capture, importID: id) }
        if type == "profile" { guard value?["nodes"]?.arrayValue != nil || value?["traceEvents"]?.arrayValue != nil else { throw LensError.invalid("Profile needs Chrome nodes or traceEvents") } }
        if type == "verification", let value { try validateResult(value, observationId: observationId, capture: capture) }
        let file = try store.saveArtifact(observationId: observationId, filename: "diagnostic-" + id + (type == "trace" ? ".zip" : ".json"), data: bytes)
        var record: [String: JSONValue] = ["id": .string(id), "type": .string(type), "path": .string(file.path), "sha256": .string(sha256(bytes)), "bytes": .number(Double(bytes.count)), "reviewed": .bool(false), "importedAt": .number(nowMilliseconds()), "provenance": .string("User-selected external diagnostic; contents are untrusted and not independently verified")]
        if type == "verification", let value { record["result"] = summaryResult(value) }
        capture.context["diagnosticArtifacts"] = .array(records(capture) + [.object(record)])
        capture.gaps.append(CoverageGap(channel: "imported-diagnostics", reason: "Imported \(type). Its browser session/document identity and tool assertions are not independently verified. Raw attachment remains local until separately reviewed. HAR normalization includes at most 1000 same-origin entries, with bodies/cookies omitted; trace archives are stored without extraction or execution."))
    }
    public static func validateResult(_ value: JSONValue, observationId: String, capture: CaptureRecord) throws {
        if let origin = value["testOrigin"], origin != .null, summaryResult(value)["testOrigin"] != origin { throw LensError.invalid("Local verification origin must be an HTTP loopback origin with a port") }
        let allowedConditionFields = Set(["type", "url", "method", "failureStatus", "successStatus", "queryPolicy"])
        guard let condition = value["condition"]?.objectValue, Set(condition.keys).isSubset(of: allowedConditionFields),
              let address = condition["url"]?.stringValue, address.count <= 4096, let url = URLComponents(string: address), ["http", "https"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(condition["method"]?.stringValue ?? ""),
              let failure = condition["failureStatus"]?.intValue, condition["failureStatus"]?.doubleValue == Double(failure), let success = condition["successStatus"]?.intValue, condition["successStatus"]?.doubleValue == Double(success),
              condition["queryPolicy"] == nil || (condition["queryPolicy"]?.stringValue.map { $0.count <= 250 } == true) else { throw LensError.invalid("Verification condition must contain only the declared HTTP fields") }
        let recorded = try Reproduction.condition(capture: capture, eventId: value["failureEventId"]?.stringValue ?? "", successStatus: success)
        guard ["type", "url", "method", "failureStatus", "successStatus"].allSatisfy({ recorded[$0] == value["condition"]?[$0] }) else { throw LensError.invalid("Verification condition does not match the original captured failure") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let contract = JSONValue.object(Dictionary(uniqueKeysWithValues: ["observationId", "captureId", "failureEventId", "condition"].map { ($0, value[$0] ?? .null) }))
        guard value["formatVersion"] == .number(1), value["observationId"]?.stringValue == observationId, value["captureId"]?.stringValue == capture.id,
              ["before", "after"].contains(value["phase"]?.stringValue ?? ""), value["condition"]?["type"]?.stringValue == "http-status",
              (400...599).contains(value["condition"]?["failureStatus"]?.intValue ?? 0), (200...399).contains(value["condition"]?["successStatus"]?.intValue ?? 0),
              ["contractSHA256", "stepsSHA256", "scriptSHA256"].allSatisfy({ value[$0]?.stringValue?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }),
              sha256(try encoder.encode(contract)) == value["contractSHA256"]?.stringValue else { throw LensError.invalid("Verification has a mismatched observation/capture, invalid condition or changed contract") }
    }
    public static func importRun(source: URL, to capture: inout CaptureRecord, observationId: String, store: EvidenceStore) throws {
        let size = try source.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard size.isRegularFile == true, size.isSymbolicLink != true, size.fileSize ?? Int.max <= 1_048_576 else { throw LensError.invalid("Select a regular runner result.json under 1 MiB") }
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: source))
        try validateResult(result, observationId: observationId, capture: capture)
        let folder = source.deletingLastPathComponent().resolvingSymlinksInPath()
        let artifacts = result["artifacts"]?.arrayValue ?? []
        guard artifacts.count <= 8, records(capture).count + artifacts.count + 1 <= 32 else { throw LensError.invalid("Too many diagnostic artifacts") }
        var files: [(URL, String)] = []
        for artifact in artifacts {
            guard let name = artifact["file"]?.stringValue, let type = artifact["type"]?.stringValue, ["har", "trace", "profile"].contains(type), name == URL(fileURLWithPath: name).lastPathComponent, !name.contains(".."), !name.contains("\\") else { throw LensError.invalid("Runner artifact leaves its result folder") }
            let file = folder.appendingPathComponent(name), values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard file.resolvingSymlinksInPath().deletingLastPathComponent() == folder, values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize ?? Int.max <= 67_108_864, sha256(try Data(contentsOf: file)) == artifact["sha256"]?.stringValue else { throw LensError.invalid("Runner artifact checksum or location mismatch") }
            files.append((file, type))
        }
        var updated = capture
        do {
            for (file, type) in files { try attach(source: file, type: type, to: &updated, observationId: observationId, store: store) }
            try attach(source: source, type: "verification", to: &updated, observationId: observationId, store: store)
            capture = updated
        } catch {
            let old = Set(records(capture).compactMap { $0["id"]?.stringValue })
            for record in records(updated) where !old.contains(record["id"]?.stringValue ?? "") { if let path = record["path"]?.stringValue { try? FileManager.default.removeItem(atPath: path) } }
            throw error
        }
    }
    public static func export(capture: inout CaptureRecord, observationId: String, store: EvidenceStore, folder: URL) throws {
        var shared: [JSONValue] = []
        for record in records(capture) {
            guard var fields = record.objectValue else { continue }
            fields.removeValue(forKey: "path")
            // Older notebooks may contain the entire external result in this metadata.
            if let result = fields["result"] { fields["result"] = summaryResult(result) }
            if record["reviewed"]?.boolValue == true, let path = record["path"]?.stringValue {
                let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let allowed = store.root.appendingPathComponent("observations/" + observationId).resolvingSymlinksInPath().path + "/"
                guard source.path.hasPrefix(allowed), ["json", "zip"].contains(source.pathExtension), (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 67_108_864 else { throw LensError.invalid("Reviewed diagnostic is outside this observation or exceeds its limit") }
                let bytes = try Data(contentsOf: source)
                guard record["sha256"]?.stringValue == sha256(bytes) else { throw LensError.invalid("Diagnostic changed after import/review") }
                let name = "diagnostic-" + sha256(bytes).prefix(24) + "." + source.pathExtension
                try bytes.write(to: folder.appendingPathComponent(name), options: .atomic)
                fields["path"] = .string(name)
            } else { fields["reviewed"] = .bool(false) }
            shared.append(.object(fields))
        }
        if !shared.isEmpty { capture.context["diagnosticArtifacts"] = .array(shared) }
    }
}
