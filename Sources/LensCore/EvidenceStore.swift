import Foundation
import CSQLite
#if os(Linux)
import CLinux
#else
import CryptoKit
#endif

public final class EvidenceStore {
    public let root: URL
    private let lock = NSRecursiveLock()
    public init(root: URL = LensPaths.defaultRoot) { self.root = root }
    private func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("notebook.sqlite").path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = pointer else { if let pointer { sqlite3_close(pointer) }; throw LensError.storage("Could not open the local notebook") }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        let schema = "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS observations(id TEXT PRIMARY KEY, created_at REAL NOT NULL, value BLOB NOT NULL); CREATE TABLE IF NOT EXISTS settings(id TEXT PRIMARY KEY, value BLOB NOT NULL);"
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw LensError.storage("Could not initialize the local notebook") }
        return try body(db)
    }
    private func put<T: Encodable>(table: String, id: String, createdAt: Double?, value: T) throws {
        let bytes = try JSONEncoder().encode(value)
        try database { db in
            let sql = table == "observations" ? "INSERT INTO observations(id,created_at,value) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value" : "INSERT INTO settings(id,value) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let s = statement else { throw LensError.storage("Could not prepare notebook write") }
            defer { sqlite3_finalize(s) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(s, 1, id, -1, transient)
            let index: Int32
            if table == "observations" { sqlite3_bind_double(s, 2, createdAt ?? nowMilliseconds()); index = 3 } else { index = 2 }
            _ = bytes.withUnsafeBytes { sqlite3_bind_blob(s, index, $0.baseAddress, Int32(bytes.count), transient) }
            guard sqlite3_step(s) == SQLITE_DONE else { throw LensError.storage("Could not save the local notebook") }
        }
    }
    private func values<T: Decodable>(sql: String, type: T.Type, parameters: [String] = []) throws -> [T] {
        try database { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let s = statement else { throw LensError.storage("Could not read the local notebook") }
            defer { sqlite3_finalize(s) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in parameters.enumerated() {
                guard sqlite3_bind_text(s, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw LensError.storage("Could not bind notebook lookup") }
            }
            var result: [T] = []
            while true {
                let status = sqlite3_step(s)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw LensError.storage("Notebook read was interrupted") }
                let count = Int(sqlite3_column_bytes(s, 0))
                guard let pointer = sqlite3_column_blob(s, 0), count > 0 else { throw LensError.storage("A saved notebook record is empty") }
                result.append(try JSONDecoder().decode(type, from: Data(bytes: pointer, count: count)))
            }
            return result
        }
    }
    public func projects() throws -> [ProjectProfile] { try values(sql: "SELECT value FROM settings WHERE id='projects'", type: [ProjectProfile].self).first ?? [] }
    public func saveProjects(_ projects: [ProjectProfile]) throws {
        var projects = projects
        guard Set(projects.map(\.id)).count == projects.count else { throw LensError.invalid("Project identities must be unique") }
        for index in projects.indices {
            projects[index].origins = try projects[index].origins.map { origin in
                guard var c = URLComponents(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host?.isEmpty == false, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else { throw LensError.invalid("Project access requires an exact HTTP or HTTPS origin") }
                c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased(); c.path = ""
                if (c.scheme == "https" && c.port == 443) || (c.scheme == "http" && c.port == 80) { c.port = nil }
                guard let result = c.url?.absoluteString else { throw LensError.invalid("Project origin is invalid") }
                return result
            }
        }
        try put(table: "settings", id: "projects", createdAt: nil, value: projects)
    }
    public func observations() throws -> [NotebookObservation] { try values(sql: "SELECT value FROM observations ORDER BY created_at DESC", type: NotebookObservation.self) }
    public func observation(id: String) throws -> NotebookObservation? {
        guard UUID(uuidString: id) != nil else { throw LensError.invalid("Invalid observation identity") }
        return try values(sql: "SELECT value FROM observations WHERE id=?", type: NotebookObservation.self, parameters: [id]).first
    }
    public func containsCapture(id: String) throws -> Bool {
        guard UUID(uuidString: id) != nil else { throw LensError.invalid("Invalid capture identity") }
        return try !values(sql: "SELECT observations.value FROM observations, json_each(CAST(observations.value AS TEXT),'$.captures') AS capture WHERE json_extract(capture.value,'$.id')=? LIMIT 1", type: NotebookObservation.self, parameters: [id]).isEmpty
    }
    public func save(_ observation: NotebookObservation) throws {
        guard UUID(uuidString: observation.id) != nil else { throw LensError.invalid("Invalid observation identity") }
        for capture in observation.captures {
            guard capture.identity.projectId == observation.projectId, capture.events.allSatisfy({ $0.projectId == observation.projectId && $0.tabId == capture.identity.tabId }) else { throw LensError.invalid("Evidence belongs to a different project or tab") }
        }
        try put(table: "observations", id: observation.id, createdAt: observation.createdAt, value: observation)
    }
    public func artifactURL(observationId: String, filename: String) throws -> URL {
        guard UUID(uuidString: observationId) != nil, !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent, !filename.contains(".."), !filename.contains("/"), !filename.contains("\\") else { throw LensError.invalid("Invalid artifact path") }
        let directory = root.appendingPathComponent("observations", isDirectory: true).appendingPathComponent(observationId, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(filename)
        guard target.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { throw LensError.invalid("Artifact leaves the observation directory") }
        return target
    }
    @discardableResult public func saveArtifact(observationId: String, filename: String, data: Data) throws -> URL {
        let target = try artifactURL(observationId: observationId, filename: filename)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }
    public func export(observation: NotebookObservation, to destination: URL) throws -> URL {
        let stem = "lens-" + observation.id + "-r" + String(observation.draftRevision)
        var folder = destination.appendingPathComponent(stem, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { folder = destination.appendingPathComponent(stem + "-" + UUID().uuidString, isDirectory: true) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sanitized = try EvidenceSanitizer.exportable(observation)
        var portable = sanitized
        for index in portable.captures.indices {
            let capture = portable.captures[index]
            try DiagnosticArtifacts.export(capture: &portable.captures[index], observationId: observation.id, store: self, folder: folder)
            guard UUID(uuidString: capture.id) != nil else { throw LensError.invalid("Invalid capture identity in export") }
            portable.captures[index].originalScreenshotPath = nil
            if let path = capture.screenshotPath {
                let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let allowed = root.appendingPathComponent("observations/" + observation.id).resolvingSymlinksInPath().path + "/"
                guard source.path.hasPrefix(allowed) else { throw LensError.invalid("Screenshot is outside this observation") }
                let name = "capture-" + capture.id + ".png"
                try Data(contentsOf: source).write(to: folder.appendingPathComponent(name), options: .atomic)
                portable.captures[index].screenshotPath = name
            }
            if let path = capture.context["videoPath"]?.stringValue {
                if capture.context["videoReviewed"]?.boolValue == true {
                    let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                    let allowed = root.appendingPathComponent("observations/" + observation.id).resolvingSymlinksInPath().path + "/"
                    guard source.path.hasPrefix(allowed) else { throw LensError.invalid("Recording is outside this observation") }
                    let name = "capture-" + capture.id + ".mp4"
                    try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
                    portable.captures[index].context["videoPath"] = .string(name)
                } else {
                    portable.captures[index].context.removeValue(forKey: "videoPath")
                    portable.captures[index].gaps.append(CoverageGap(channel: "video", reason: "Recording remains local because it has not been reviewed for export"))
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(portable).write(to: folder.appendingPathComponent("evidence.json"), options: .atomic)
        var markdown = "# " + sanitized.title + "\n\n" + sanitized.markdown + "\n\n"
        for capture in portable.captures {
            if let path = capture.screenshotPath { markdown += "![Captured observation](" + path + ")\n\n" }
            if let path = capture.context["videoPath"]?.stringValue { markdown += "[Reviewed recording](" + path + ")\n\n" }
            for gap in capture.gaps { markdown += "- Capture gap (" + gap.channel + "): " + gap.reason + "\n" }
        }
        if !sanitized.findings.isEmpty { markdown += "\n## Investigation\n\n" + sanitized.findings.map { "- **" + $0.kind + "**: " + $0.text + ($0.source.map { " (" + $0 + ")" } ?? "") }.joined(separator: "\n") }
        try Data(markdown.utf8).write(to: folder.appendingPathComponent("report.md"), options: .atomic)
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        return folder
    }
}

public enum EvidenceSanitizer {
    public static func cloudImages(_ observation: NotebookObservation) -> NotebookObservation {
        var selected = observation
        var included = 0
        for index in selected.captures.indices {
            guard let path = selected.captures[index].screenshotPath else { continue }
            let url = URL(fileURLWithPath: path)
            let reason: String?
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 4_000_000 {
                reason = "Image exceeds the 4 MB cloud limit; its selected technical evidence remains available."
            } else if !FileManager.default.isReadableFile(atPath: path) {
                reason = "Selected image is unavailable; its technical evidence remains available."
            } else if included >= 2 {
                reason = "Image omitted from this investigation's two-image limit; its selected technical evidence remains available."
            } else { reason = nil; included += 1 }
            if let reason {
                selected.captures[index].screenshotPath = nil
                selected.captures[index].gaps.append(CoverageGap(channel: "cloud-image", reason: reason))
            }
        }
        return selected
    }
    public static func cloudSelection(_ observation: NotebookObservation) throws -> NotebookObservation {
        var selected = observation
        selected.captures = selected.captures.filter { $0.context["includeInAI"]?.boolValue == true }
        selected.findings = []; selected.receipt = nil
        selected = try exportable(selected)
        for index in selected.captures.indices {
            selected.captures[index].originalScreenshotPath = nil
            // This copy contains the baked derivative; editable masks belong to the private original.
            selected.captures[index].annotations.removeAll { $0.kind == "mask" }
            selected.captures[index].context.removeValue(forKey: "videoPath")
            selected.captures[index].context.removeValue(forKey: "diagnosticArtifacts")
        }
        return selected
    }
    static let sensitive = try! NSRegularExpression(pattern: "(?i)(authorization|cookie|password|secret|token|api[-_]?key|credential|set-cookie)")
    static func isSensitiveField(_ name: String) -> Bool {
        sensitive.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil || name.range(of: "(?i)(passwd|session|csrf|xsrf)", options: .regularExpression) != nil
    }
    private static let privateKey = try! NSRegularExpression(pattern: "(?s)-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY)-----.*?(?:-----END \\1-----|$)")
    public static func text(_ value: String) -> String {
        var output = value
        for match in privateKey.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            // Preserve source line numbers even when a later excerpt starts inside a key.
            let replacement = "[redacted private key]" + String(repeating: "\n", count: output[range].utf8.filter { $0 == 10 }.count)
            output.replaceSubrange(range, with: replacement)
        }
        let patterns = ["(?i)(Bearer\\s+)[A-Za-z0-9._~+/-]+=*", "(?i)((?:token|password|secret|api[-_]?key|session|authorization)[\\\"']?\\s*[:=]\\s*[\\\"']?)[^\\s&\\\"',}]+", "sk-[A-Za-z0-9_-]{12,}"]
        for pattern in patterns { if let re = try? NSRegularExpression(pattern: pattern) { output = re.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "[redacted]") } }
        return output
    }
    public static func json(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object): return .object(object.mapValues { json($0) }.mapKeysAndValues { key, value in
            let range = NSRange(key.startIndex..., in: key)
            var clean = value
            if ["headers", "requestHeaders", "responseHeaders"].contains(key) {
                if let headers = value.objectValue {
                    clean = .object(headers.mapKeysAndValues { name, item in (name, isSensitiveField(name) ? .string("[redacted]") : item) })
                } else if let headers = value.arrayValue {
                    clean = .array(headers.map { header in
                        guard let name = header["name"]?.stringValue, isSensitiveField(name) else { return header }
                        return .object(["name": .string(name), "value": .string("[redacted]")])
                    })
                }
            }
            return (key, sensitive.firstMatch(in: key, range: range) == nil ? clean : .string("[redacted]"))
        })
        case .array(let values): return .array(values.map(json))
        case .string(let value): return .string(text(value))
        default: return value
        }
    }
    public static func exportable(_ observation: NotebookObservation) throws -> NotebookObservation {
        for capture in observation.captures where capture.annotations.contains(where: { $0.kind == "mask" }) {
            guard let original = capture.originalScreenshotPath, let derivative = capture.screenshotPath, original != derivative else { throw LensError.invalid("Apply the visual masks before exporting or investigating this capture") }
        }
        let bytes = try JSONEncoder().encode(observation)
        let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
        return try json(value).decode(NotebookObservation.self)
    }
}
private extension Dictionary where Key == String, Value == JSONValue {
    func mapKeysAndValues(_ transform: (String, JSONValue) -> (String, JSONValue)) -> [String: JSONValue] { Dictionary(uniqueKeysWithValues: map { transform($0.key, $0.value) }) }
}
public func sha256(_ data: Data) -> String {
    #if os(Linux)
    var digest = [UInt8](repeating: 0, count: Int(SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = SHA256($0.bindMemory(to: UInt8.self).baseAddress, data.count, &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
    #else
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #endif
}
public func stableUUID(_ string: String) -> String {
    let h = Array(sha256(Data(string.utf8)).prefix(32)); let raw = String(h)
    return [String(raw.prefix(8)), String(raw.dropFirst(8).prefix(4)), "4"+String(raw.dropFirst(13).prefix(3)), "a"+String(raw.dropFirst(17).prefix(3)), String(raw.dropFirst(20))].joined(separator: "-")
}
