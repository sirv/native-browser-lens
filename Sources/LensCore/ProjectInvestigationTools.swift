import Foundation

/// Read-only investigation over one already-selected observation. Model input
/// selects bounded operations, never shell commands or arbitrary filesystem roots.
public actor ProjectInvestigationTools {
    public static let definitions: [JSONValue] = [
        definition("search_project", "Find literal text in this project's source, tests and documentation. Results describe the local checkout, not the observed build.", ["query": .object(["type": .string("string"), "minLength": .number(2), "maxLength": .number(200)])]),
        definition("read_project_file", "Read a bounded source, test or documentation excerpt. Follow imports and search results incrementally. Build matching is reported explicitly.", ["path": .object(["type": .string("string")]), "line": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(1_000_000)])]),
        definition("lookup_request", "Inspect events for a selected captured request or event ID. This cannot inspect other observations, projects or unselected captures.", ["id": .object(["type": .string("string")])]),
        definition("lookup_correlated_logs", "Read configured local log tails only for a trace or request ID present in selected evidence. No server calls are made.", ["traceId": .object(["type": .string("string")])]),
    ]

    private let project: ProjectProfile
    private let captures: [CaptureRecord]
    private let validProject: Bool
    private var calls = 0
    private var textBytes = 0
    private var collected: [Finding] = []
    private static let extensions = Set(["ts", "tsx", "js", "jsx", "mjs", "cjs", "swift", "rs", "py", "go", "java", "kt", "c", "cpp", "h", "css", "scss", "html", "md", "mdx", "json", "yaml", "yml", "toml", "sql"])
    private static let excludedDirectories = Set(["node_modules", "vendor", "dist", "build", "target", "coverage", "credentials", "secrets"])

    public init(project: ProjectProfile, observation: NotebookObservation) {
        self.project = project
        validProject = project.id == observation.projectId
        captures = observation.captures.filter { $0.identity.projectId == project.id && $0.context["includeInAI"]?.boolValue != false }
    }

    public func evidence() -> [Finding] { collected }

    public func execute(name: String, arguments: JSONValue) async -> JSONValue {
        guard calls < 12 else { return result([], truncated: true) }
        calls += 1
        guard textBytes < 64_000 else { return result([], truncated: true) }
        guard validProject else { return record([Finding(kind: "coverage", text: "Observation and project do not match.", source: "tool:" + name)]) }
        do {
            let findings: [Finding]
            var truncated = false
            switch name {
            case "search_project":
                let query = try string("query", arguments, keys: ["query"], maximum: 200)
                guard query.count >= 2 else { throw LensError.invalid("Search requires at least two literal characters") }
                (findings, truncated) = try search(query)
            case "read_project_file":
                let path = try string("path", arguments, keys: ["path", "line"], maximum: 512)
                guard let number = arguments["line"]?.doubleValue, number.rounded() == number, number >= 1, number <= 1_000_000 else { throw LensError.invalid("Line must be an integer between 1 and 1000000") }
                _ = try permittedFile(path)
                let excerpt = try SourceResolver.resolve(reference: path + ":" + String(Int(number)), project: project, observedBuild: observedBuild())
                findings = [Finding(kind: excerpt.matchedBuild ? "observed" : "coverage", text: excerpt.explanation + "\n" + excerpt.content, source: excerpt.reference)]
            case "lookup_request":
                let id = try string("id", arguments, keys: ["id"], maximum: 256)
                let matching = selectedEvents().filter { $0.event.id == id || $0.event.data["requestId"]?.stringValue == id }
                truncated = matching.count > 8
                findings = matching.prefix(8).map { item in
                    Finding(kind: "observed", text: EvidenceSanitizer.json(.object(item.event.data)).pretty, source: "capture:" + item.captureID + "/event:" + item.event.id)
                }
            case "lookup_correlated_logs":
                let traceID = try string("traceId", arguments, keys: ["traceId"], maximum: 128)
                guard traceID.count >= 8, selectedEvents().contains(where: { Self.traceIDs(.object($0.event.data)).contains(traceID) }) else { throw LensError.invalid("Trace ID is absent from the selected evidence") }
                (findings, truncated) = try logLines(traceID)
            default: throw LensError.invalid("Unknown read-only investigation tool")
            }
            return record(findings.isEmpty ? [Finding(kind: "coverage", text: "No matching evidence was available within the configured inspection scope.", source: "tool:" + name)] : findings, truncated: truncated)
        } catch {
            return record([Finding(kind: "coverage", text: EvidenceSanitizer.text(error.localizedDescription), source: "tool:" + name)])
        }
    }

    private static func definition(_ name: String, _ description: String, _ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("function"), "name": .string(name), "description": .string(description), "strict": .bool(true),
            "parameters": .object(["type": .string("object"), "properties": .object(properties), "required": .array(properties.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])])
    }

    private func string(_ key: String, _ value: JSONValue, keys: Set<String>, maximum: Int) throws -> String {
        guard let object = value.objectValue, Set(object.keys) == keys, let text = object[key]?.stringValue,
              !text.isEmpty, text.count <= maximum, !text.contains("\0") else { throw LensError.invalid("Invalid investigation tool arguments") }
        return text
    }

    private func record(_ findings: [Finding], truncated: Bool = false) -> JSONValue {
        var included: [Finding] = []; var clipped = truncated; var callBytes = 0
        for var finding in findings {
            let allowance = min(8_000 - callBytes, 64_000 - textBytes)
            guard allowance > 0 else { clipped = true; break }
            finding.text = EvidenceSanitizer.text(finding.text)
            if finding.text.utf8.count > allowance {
                finding.text = String(decoding: finding.text.utf8.prefix(allowance), as: UTF8.self)
                // A split multibyte character can grow when decoded; stay within the byte budget.
                while finding.text.utf8.count > allowance { finding.text.removeLast() }
                clipped = true
            }
            callBytes += finding.text.utf8.count; textBytes += finding.text.utf8.count
            included.append(finding)
        }
        collected.append(contentsOf: included)
        return result(included, truncated: clipped)
    }

    private func result(_ findings: [Finding], truncated: Bool) -> JSONValue {
        .object(["findings": (try? .from(findings)) ?? .array([]), "truncated": .bool(truncated),
            "remainingCalls": .number(Double(max(0, 12 - calls))), "remainingTextBytes": .number(Double(max(0, 64_000 - textBytes)))])
    }

    private func observedBuild() -> String? {
        guard !captures.isEmpty else { return nil }
        let builds = captures.compactMap { capture -> String? in
            let build = capture.identity.buildId
            let applicationBuild = capture.context["application"]?["build"]
            guard capture.context["sourceBuildVerified"]?.boolValue != false,
                  capture.context["sourceState"]?.stringValue != "working-tree",
                  applicationBuild?["sourceState"]?.stringValue != "working-tree",
                  let build, build.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil else { return nil }
            return build.lowercased()
        }
        guard builds.count == captures.count, Set(builds).count == 1 else { return nil }
        return builds.first
    }

    private func permittedFile(_ path: String) throws -> URL {
        guard !path.contains(":"), Self.permittedComponents(path), Self.extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { throw LensError.invalid("Only project source, test and documentation files are available") }
        let target = try LocalRead.safeFile(path, root: project.repositoryPath)
        let root = URL(fileURLWithPath: project.repositoryPath).resolvingSymlinksInPath().path
        let resolved = String(target.path.dropFirst(root.count + 1))
        guard Self.permittedComponents(resolved), Self.extensions.contains(target.pathExtension.lowercased()) else { throw LensError.invalid("Resolved file is outside the permitted source scope") }
        return target
    }

    private static func permittedComponents(_ path: String) -> Bool {
        !path.split(separator: "/").contains { part in
            let lower = part.lowercased()
            return lower.hasPrefix(".") || excludedDirectories.contains(lower) || lower.hasPrefix("credentials.") || lower.hasPrefix("secrets.") || lower.hasPrefix("service-account")
        }
    }

    private func search(_ query: String) throws -> ([Finding], Bool) {
        guard !project.repositoryPath.isEmpty else { throw LensError.invalid("No project repository is configured") }
        let root = URL(fileURLWithPath: project.repositoryPath).resolvingSymlinksInPath()
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw LensError.unavailable("Project source is unavailable") }
        var matches: [Finding] = []; var inspected = 0; var bytesRead = 0; var truncated = false
        for case let file as URL in files {
            inspected += 1
            if inspected > 5_000 || bytesRead >= 8_000_000 || matches.count >= 24 { return (matches, true) }
            let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isSymbolicLink != true else { continue }
            // Foundation's enumerator can spell /var as /private/var even when
            // its root URL was normalized. Compare the same canonical form.
            let canonical = file.resolvingSymlinksInPath().path
            guard canonical.hasPrefix(root.path + "/") else { if values?.isDirectory == true { files.skipDescendants() }; continue }
            let relative = String(canonical.dropFirst(root.path.count + 1))
            if !Self.permittedComponents(relative) { if values?.isDirectory == true { files.skipDescendants() }; continue }
            guard values?.isRegularFile == true else { continue }
            if let size = values?.fileSize, size > 256_000 || bytesRead + size > 8_000_000 { truncated = true; continue }
            guard
                  let safe = try? permittedFile(relative), let data = try? Data(contentsOf: safe),
                  let text = String(data: data, encoding: .utf8) else { continue }
            bytesRead += data.count
            var fileMatches = 0
            for (index, line) in text.components(separatedBy: "\n").enumerated() where line.localizedCaseInsensitiveContains(query) {
                matches.append(Finding(kind: "coverage", text: "Build unmatched: local checkout search result\n" + String(line.prefix(1_200)), source: safe.path + ":" + String(index + 1)))
                fileMatches += 1
                if fileMatches >= 2 { break }
            }
        }
        return (matches, truncated)
    }

    private func selectedEvents() -> [(captureID: String, event: EvidenceEvent)] {
        captures.flatMap { capture in capture.events.filter { $0.projectId == project.id && $0.tabId == capture.identity.tabId }.map { (capture.id, $0) } }
    }

    private static func traceIDs(_ value: JSONValue) -> [String] {
        switch value {
        case .object(let object):
            let names = Set(["requestid", "traceid", "trace-id", "x-trace-id", "x-request-id", "traceparent"])
            var result: [String] = []
            if let name = object["name"]?.stringValue, names.contains(name.lowercased()), let value = object["value"]?.stringValue { result.append(value) }
            for (key, value) in object {
                if names.contains(key.lowercased()), let text = value.stringValue { result.append(text) }
                result.append(contentsOf: traceIDs(value))
            }
            return result
        case .array(let values): return values.flatMap(traceIDs)
        default: return []
        }
    }

    private func logLines(_ traceID: String) throws -> ([Finding], Bool) {
        var findings: [Finding] = []; var truncated = project.logPaths.count > 4
        for path in project.logPaths.prefix(4) {
            guard Self.permittedComponents(path), let url = try? LocalRead.safeFile(path, root: project.repositoryPath) else { continue }
            let root = URL(fileURLWithPath: project.repositoryPath).resolvingSymlinksInPath().path
            guard Self.permittedComponents(String(url.path.dropFirst(root.count + 1))),
                  let file = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? file.close() }
            let size = try file.seekToEnd(); try file.seek(toOffset: size > 256_000 ? size - 256_000 : 0)
            if size > 256_000 { truncated = true }
            let bytes = try file.read(upToCount: 256_000) ?? Data()
            let matching = String(decoding: bytes, as: UTF8.self).split(separator: "\n").filter({ $0.contains(traceID) })
            if matching.count > 8 { truncated = true }
            for line in matching.suffix(8) {
                findings.append(Finding(kind: "observed", text: EvidenceSanitizer.text(String(line)), source: url.path + " (tail; trace " + traceID + ")"))
            }
        }
        return (findings, truncated)
    }
}
