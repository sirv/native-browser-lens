import Foundation

public enum SourceMapResolver {
    public struct Position {
        public let source: Int
        public let line: Int
        public let column: Int
        public let map: JSONValue
    }
    public static func originalPosition(map: JSONValue, line: Int, column: Int, depth: Int = 0) throws -> Position? {
        guard depth < 8, map["version"]?.intValue == 3, line >= 0, column >= 0, line < 1_000_000, column < 100_000_000 else { throw LensError.invalid("Invalid source map version or generated position") }
        if let sections = map["sections"]?.arrayValue {
            guard sections.count <= 1024 else { throw LensError.invalid("Too many source map sections") }
            var previous = (-1, -1), selected: (JSONValue, Int, Int)?
            for section in sections {
                guard let sectionLine = section["offset"]?["line"]?.intValue, let sectionColumn = section["offset"]?["column"]?.intValue, sectionLine >= 0, sectionColumn >= 0,
                      sectionLine > previous.0 || (sectionLine == previous.0 && sectionColumn > previous.1), let child = section["map"], section["url"] == nil else { throw LensError.invalid("Indexed source map requires ordered inline sections") }
                previous = (sectionLine, sectionColumn)
                if sectionLine < line || (sectionLine == line && sectionColumn <= column) { selected = (child, sectionLine, sectionColumn) }
            }
            guard let (child, startLine, startColumn) = selected else { return nil }
            return try originalPosition(map: child, line: line - startLine, column: line == startLine ? column - startColumn : column, depth: depth + 1)
        }
        guard let text = map["mappings"]?.stringValue, text.utf8.count <= 8_000_000, let sources = map["sources"]?.arrayValue else { throw LensError.invalid("Invalid source map mappings") }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        let digits = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })
        var source = 0, originalLine = 0, originalColumn = 0, name = 0
        var answer: Position?
        for (generatedLine, rawLine) in text.split(separator: ";", omittingEmptySubsequences: false).enumerated() {
            if generatedLine > line { break }
            var generatedColumn = 0
            for segment in rawLine.split(separator: ",", omittingEmptySubsequences: false) where !segment.isEmpty {
                var fields: [Int] = [], value = 0, shift = 0
                for byte in segment.utf8 {
                    guard let digit = digits[byte], shift <= 30 else { throw LensError.invalid("Malformed source map VLQ") }
                    value |= (digit & 31) << shift
                    if digit & 32 == 0 { fields.append(value & 1 == 0 ? value >> 1 : -(value >> 1)); value = 0; shift = 0 }
                    else { shift += 5 }
                }
                guard shift == 0, [1,4,5].contains(fields.count) else { throw LensError.invalid("Incomplete source map segment") }
                let previousColumn = generatedColumn; generatedColumn += fields[0]
                guard generatedColumn >= previousColumn, generatedColumn <= 100_000_000 else { throw LensError.invalid("Invalid generated source map column") }
                if fields.count > 1 {
                    source += fields[1]; originalLine += fields[2]; originalColumn += fields[3]
                    if fields.count == 5 { name += fields[4] }
                    guard sources.indices.contains(source), originalLine >= 0, originalColumn >= 0, name >= 0, fields.count != 5 || (map["names"]?.arrayValue?.indices.contains(name) == true) else { throw LensError.invalid("Source map position is outside its source/name table") }
                }
                if generatedLine == line, generatedColumn <= column { answer = fields.count == 1 ? nil : Position(source: source, line: originalLine, column: originalColumn, map: map) }
            }
        }
        return answer
    }
    public static func frames(_ event: EvidenceEvent) -> [JSONValue] {
        func collect(_ value: JSONValue, depth: Int = 0) -> [JSONValue] {
            guard depth < 8 else { return [] }
            var result = Array((value["callFrames"]?.arrayValue ?? []).prefix(16))
            if let parent = value["parent"] { result += collect(parent, depth: depth + 1) }
            return result
        }
        return Array(collect(event.data["stackTrace"] ?? event.data["details"]?["stackTrace"] ?? event.data["initiator"]?["stack"] ?? .null).prefix(16))
    }
    public static func resolve(frame: JSONValue, project: ProjectProfile, observedBuild: String?) throws -> SourceExcerpt {
        guard let build = observedBuild, build.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil,
              let scriptURL = frame["url"]?.stringValue.flatMap(URL.init(string:)), ["https", "http"].contains(scriptURL.scheme),
              let line = frame["lineNumber"]?.intValue, let column = frame["columnNumber"]?.intValue,
              !project.repositoryPath.isEmpty else { throw LensError.unavailable("Source map requires a captured commit and a generated script URL/position") }
        guard try LocalRead.command("/usr/bin/git", ["cat-file", "-t", build], directory: project.repositoryPath).trimmingCharacters(in: .whitespacesAndNewlines) == "commit" else { throw LensError.unavailable("Captured build commit is unavailable locally") }
        let files = try LocalRead.command("/usr/bin/git", ["ls-tree", "-r", "--name-only", "-z", build], directory: project.repositoryPath, limit: 2_000_000).split(separator: "\0").map(String.init)
        let deployed = scriptURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !deployed.isEmpty, !deployed.split(separator: "/").contains("..") else { throw LensError.invalid("Invalid generated script path") }
        let matches = files.filter { $0 == deployed || $0.hasSuffix("/" + deployed) || (deployed.hasPrefix("_next/") && $0.hasSuffix("/.next/" + deployed.dropFirst(6))) }
        guard matches.count == 1, let compiled = matches.first else { throw LensError.unavailable("Generated script is absent or ambiguous in the captured commit") }
        _ = try LocalRead.safeFile(compiled, root: project.repositoryPath)
        let code = try LocalRead.command("/usr/bin/git", ["show", build + ":" + compiled], directory: project.repositoryPath, limit: 8_000_000)
        let regex = try NSRegularExpression(pattern: "(?m)//[#@]\\s*sourceMappingURL=([^\\s]+)\\s*$")
        guard let match = regex.matches(in: code, range: NSRange(code.startIndex..., in: code)).last, let range = Range(match.range(at: 1), in: code) else { throw LensError.unavailable("Generated script has no local sourceMappingURL annotation") }
        let mapName = String(code[range])
        let map: JSONValue, mapPath: String
        if mapName.hasPrefix("data:application/json;base64,") {
            guard let data = Data(base64Encoded: String(mapName.dropFirst(29))), data.count <= 8_000_000 else { throw LensError.invalid("Invalid inline source map") }
            map = try JSONDecoder().decode(JSONValue.self, from: data); mapPath = compiled
        } else {
            guard !mapName.contains(":"), !mapName.hasPrefix("/"), !mapName.contains("?"), !mapName.contains("#") else { throw LensError.unavailable("Remote or absolute source maps are not fetched") }
            mapPath = try relative(mapName, beside: compiled, root: project.repositoryPath)
            guard files.contains(mapPath) else { throw LensError.unavailable("Source map is not stored in the captured commit") }
            let text = try LocalRead.command("/usr/bin/git", ["show", build + ":" + mapPath], directory: project.repositoryPath, limit: 8_000_000)
            map = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        }
        guard let position = try originalPosition(map: map, line: line, column: column), let source = position.map["sources"]?.arrayValue?[position.source].stringValue else { throw LensError.unavailable("No original mapping for this generated position") }
        let effectiveMap = position.map
        var sourceName = (effectiveMap["sourceRoot"]?.stringValue ?? "") + ((effectiveMap["sourceRoot"]?.stringValue?.isEmpty == false && effectiveMap["sourceRoot"]?.stringValue?.hasSuffix("/") == false) ? "/" : "") + source
        let webpack = sourceName.hasPrefix("webpack://")
        if webpack, let url = URL(string: sourceName) { sourceName = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let sourcePath = try relative(sourceName, beside: webpack ? "project-root" : mapPath, root: project.repositoryPath)
        _ = try LocalRead.safeSourceFile(sourcePath, root: project.repositoryPath)
        let content: String
        if let embedded = effectiveMap["sourcesContent"]?.arrayValue, embedded.indices.contains(position.source), let text = embedded[position.source].stringValue { content = text }
        else {
            guard files.contains(sourcePath) else { throw LensError.unavailable("Original source is unavailable in the captured commit/map") }
            content = try LocalRead.command("/usr/bin/git", ["show", build + ":" + sourcePath], directory: project.repositoryPath, limit: 256_000)
        }
        let lines = EvidenceSanitizer.text(content).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"), lower = max(0, position.line - 5), upper = min(lines.count, position.line + 8)
        guard lower < upper else { throw LensError.invalid("Mapped position is outside original source") }
        let excerpt = (lower..<upper).map { "\($0 + 1): \(lines[$0])" }.joined(separator: "\n")
        return SourceExcerpt(reference: project.repositoryPath + "/" + sourcePath + ":\(position.line + 1):\(position.column + 1)", content: EvidenceSanitizer.text(String(excerpt.prefix(8000))), matchedBuild: true, explanation: "Source map and generated script read from captured commit \(build). The captured build label matches; deployed script bytes were not independently verified.")
    }
    static func relative(_ name: String, beside file: String, root: String) throws -> String {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains(":"), !name.contains("\\"), !name.contains("\0") else { throw LensError.invalid("Unsafe source map reference") }
        let base = URL(fileURLWithPath: root).standardizedFileURL
        let target = base.appendingPathComponent(file).deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { throw LensError.invalid("Source map reference escapes the repository") }
        let relative = String(target.path.dropFirst(base.path.count + 1))
        _ = try LocalRead.safeFile(relative, root: root)
        return relative
    }
}
