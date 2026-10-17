import Foundation

/// Relationships in recorded evidence. Temporal proximity never establishes causation.
public enum IncidentEvidence {
    public struct Link: Codable, Equatable {
        public let target: String
        public let relationship: String
        public let reason: String
    }
    public struct Row: Codable, Equatable {
        public let event: EvidenceEvent
        public let failure: Bool
        public let links: [Link]
    }
    public static func isFailure(_ event: EvidenceEvent) -> Bool {
        ["exception", "failure", "network-failure"].contains(event.kind) || (event.data["status"]?.intValue ?? 0) >= 400 ||
        (event.kind == "console" && ["error", "assert"].contains(event.data["type"]?.stringValue ?? event.data["level"]?.stringValue ?? event.data["entry"]?["level"]?.stringValue ?? ""))
    }
    static func traceIDs(_ value: JSONValue) -> Set<String> {
        switch value {
        case .object(let object):
            var fields = object
            if let name = object["name"]?.stringValue, ["traceid", "trace-id", "x-trace-id", "x-request-id", "traceparent"].contains(name.lowercased()), let value = object["value"]?.stringValue { fields[name] = .string(value) }
            return fields.reduce(into: Set<String>()) { ids, pair in
                let (key, item) = pair
                if ["traceid", "trace-id", "x-trace-id", "x-request-id", "traceparent"].contains(key.lowercased()), let text = item.stringValue, (8...128).contains(text.count) {
                    ids.insert(text)
                    if key.lowercased() == "traceparent" {
                        let parts = text.split(separator: "-")
                        if parts.count == 4, parts[1].count == 32 { ids.insert(String(parts[1])) }
                    }
                }
                ids.formUnion(traceIDs(item))
            }
        case .array(let array): return array.reduce(into: Set<String>()) { $0.formUnion(traceIDs($1)) }
        default: return []
        }
    }
    public static func timeline(capture: CaptureRecord, findings: [Finding] = []) -> [Row] {
        func session(_ event: EvidenceEvent) -> String? { event.data["targetSession"]?.stringValue ?? event.data["sessionId"]?.stringValue }
        let events = capture.events.enumerated().filter { $0.element.projectId == capture.identity.projectId && $0.element.tabId == capture.identity.tabId && $0.element.documentId == capture.identity.documentId }.sorted { $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp }.map(\.element)
        let network = Set(["request", "response", "response-body", "network-failure", "network-complete", "cache"])
        var requests: [String: [EvidenceEvent]] = [:]
        for event in events where network.contains(event.kind) {
            if let id = event.data["requestId"]?.stringValue { requests[id, default: []].append(event) }
        }
        let traces = events.map { traceIDs(.object($0.data)) }
        return events.enumerated().map { index, event in
            var links: [Link] = []
            if network.contains(event.kind), let id = event.data["requestId"]?.stringValue {
                let candidates = requests[id] ?? []
                let sessions = Set(candidates.compactMap(session))
                let target = session(event)
                if !sessions.contains(where: { $0.lowercased() == "[redacted]" }), target != nil || sessions.isEmpty {
                    let scoped = candidates.filter { session($0) == target }
                    let position = scoped.firstIndex { $0.id == event.id } ?? 0
                    let start = scoped.indices.last { $0 <= position && scoped[$0].kind == "request" }
                    let end = scoped.indices.first { $0 > (start ?? -1) && scoped[$0].kind == "request" } ?? scoped.endIndex
                    links += scoped[(start ?? 0)..<end].filter { $0.id != event.id }.prefix(16).map { Link(target: $0.id, relationship: "request", reason: "Same recorded request ID, target session, document and redirect hop") }
                }
            }
            if !traces[index].isEmpty {
                links += events.enumerated().filter { $0.offset != index && !traces[index].isDisjoint(with: traces[$0.offset]) }.prefix(12).map {
                    Link(target: $0.element.id, relationship: "trace", reason: "Shared explicit request or trace identifier; this does not prove causation")
                }
                links += findings.filter { finding in
                    traces[index].contains { id in
                        finding.text.range(of: "(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: id) + "(?![A-Za-z0-9_-])", options: .regularExpression) != nil
                    }
                }.prefix(8).map { Link(target: "finding:" + $0.id, relationship: "trace", reason: "Local finding contains the same explicit trace identifier; log origin and timing still need verification") }
            }
            if isFailure(event) {
                links += events.filter { other in other.id != event.id && abs(other.timestamp - event.timestamp) <= 3_000 && (other.kind == "action" || isFailure(other)) && !links.contains(where: { $0.target == other.id }) }.prefix(8).map {
                    Link(target: $0.id, relationship: "nearby", reason: "Within 3 seconds in this document; temporal context only, no causal link recorded")
                }
            }
            return Row(event: event, failure: isFailure(event), links: links)
        }
    }
    static func bounded(_ value: JSONValue, depth: Int = 0) -> JSONValue {
        if depth >= 8 { return .string("[nested detail omitted; query the original event]") }
        switch value {
        case .string(let text): return .string(text.count > 1800 ? String(text.prefix(1800)) + " [shortened; query original event]" : text)
        case .array(let array): return .array(array.prefix(48).map { bounded($0, depth: depth + 1) })
        case .object(let object): return .object(Dictionary(uniqueKeysWithValues: object.keys.sorted().prefix(64).map { ($0, bounded(object[$0]!, depth: depth + 1)) }))
        default: return value
        }
    }
    public static func select(observation: NotebookObservation, byteLimit: Int = 32_000) throws -> JSONValue {
        guard byteLimit >= 4096 else { throw LensError.invalid("Evidence selection budget is too small") }
        let clean = try EvidenceSanitizer.exportable(observation)
        let ranked = clean.captures.map { timeline(capture: $0) }
        var candidates: [(capture: Int, row: Row, score: Int)] = []
        var seen = Set<String>()
        var duplicateCopies = 0
        for (index, rows) in ranked.enumerated() {
            let linked = Set(rows.filter(\.failure).flatMap { $0.links.map(\.target) })
            for row in rows {
                guard seen.insert(row.event.id).inserted else { duplicateCopies += 1; continue }
                candidates.append((index, row, row.failure ? 1000 : linked.contains(row.event.id) ? 900 : row.event.kind == "action" ? 200 : 0))
            }
        }
        candidates.sort { $0.score == $1.score ? ($0.row.event.timestamp == $1.row.event.timestamp ? $0.row.event.id < $1.row.event.id : $0.row.event.timestamp > $1.row.event.timestamp) : $0.score > $1.score }
        var included: [Int: [JSONValue]] = [:]
        var includedIDs = Set<String>()
        let allIDs = candidates.map { $0.row.event.id }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func document() throws -> JSONValue {
            let omitted = allIDs.filter { !includedIDs.contains($0) }
            let captures: [JSONValue] = try clean.captures.enumerated().map { index, capture in
                .object(["id": .string(capture.id), "identity": try .from(capture.identity), "gaps": bounded(try .from(capture.gaps)), "context": bounded(.object(capture.context.filter { ["selectedElementRefs", "annotationBindings", "sourceBuildVerified", "sourceState", "buildId", "mode", "url", "title"].contains($0.key) })), "events": .array((included[index] ?? []).sorted { ($0["timestamp"]?.doubleValue ?? 0) < ($1["timestamp"]?.doubleValue ?? 0) })])
            }
            return .object(["id": .string(clean.id), "title": .string(String(clean.title.prefix(500))), "markdown": .string(String(clean.markdown.prefix(min(12_000, byteLimit / 5)))), "captures": .array(captures), "selection": .object([
                "policy": .string("Failures first, then recorded request links and nearby actions. Repeated event IDs appear once across selected captures. Nearby events are not proven causes. Raw evidence remains available through the reviewed export CLI."),
                "duplicateEventCopies": .number(Double(duplicateCopies)),
                "omittedEventCount": .number(Double(omitted.count)), "omittedEventIDs": .array(omitted.prefix(128).map(JSONValue.string)), "omittedIDListTruncated": .bool(omitted.count > 128),
                "fieldsMayBeShortened": .bool(true), "reporterTextShortened": .bool(clean.markdown.count > min(12_000, byteLimit / 5)),
                "fieldLimits": .string("1800 characters/string, 48 array items, 64 object keys, depth 8; capture context contains only source/binding fields. Query the original event for full detail.")
            ])])
        }
        guard try encoder.encode(document()).count <= byteLimit else { throw LensError.invalid("Capture identities and coverage exceed the AI budget. Select fewer captures.") }
        for candidate in candidates {
            guard includedIDs.count < 160 else { break }
            let value = bounded(try .from(candidate.row.event))
            included[candidate.capture, default: []].append(value); includedIDs.insert(candidate.row.event.id)
            if try encoder.encode(document()).count > byteLimit { included[candidate.capture]?.removeLast(); includedIDs.remove(candidate.row.event.id) }
        }
        let selected = try document()
        guard try encoder.encode(selected).count <= byteLimit else { throw LensError.invalid("Selected evidence exceeds the AI budget. Select fewer captures.") }
        return selected
    }
    public static func selectFindings(_ findings: [Finding], byteLimit: Int = 26_000) throws -> JSONValue {
        var selected: [JSONValue] = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func document() -> JSONValue { .object(["findings": .array(selected), "omittedFindingCount": .number(Double(findings.count - selected.count)), "fieldsMayBeShortened": .bool(true)]) }
        for finding in findings.sorted(by: { ($0.kind == "observed" ? 0 : 1) < ($1.kind == "observed" ? 0 : 1) }) {
            selected.append(bounded(try .from(finding)))
            if try encoder.encode(document()).count > byteLimit { selected.removeLast(); break }
        }
        return document()
    }
}
