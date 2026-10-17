import XCTest
@testable import LensCore

final class IncidentEvidenceTests: XCTestCase {
    func capture(_ events: [(String, Double, String, [String: JSONValue])]) -> CaptureRecord {
        CaptureRecord(identity: .init(projectId: "p", tabId: 1, documentId: "d"), events: events.map {
            EvidenceEvent(id: $0.0, projectId: "p", tabId: 1, documentId: "d", timestamp: $0.1, kind: $0.2, data: $0.3)
        })
    }
    func testTimelineSeparatesRequestLinksFromNearbyContextAndTargetCollisions() throws {
        let c = capture([
            ("click", 10, "action", ["type": .string("click")]),
            ("a", 20, "request", ["requestId": .string("1"), "targetSession": .string("a")]),
            ("b", 21, "request", ["requestId": .string("1"), "targetSession": .string("b")]),
            ("bad", 30, "response", ["requestId": .string("1"), "targetSession": .string("a"), "status": .number(503)]),
            ("unknown", 31, "response-body", ["requestId": .string("1")]),
            ("error", 40, "exception", ["text": .string("Save failed")])
        ])
        let rows = IncidentEvidence.timeline(capture: c)
        let bad = try XCTUnwrap(rows.first { $0.event.id == "bad" })
        XCTAssertTrue(bad.links.contains { $0.target == "a" && $0.relationship == "request" })
        XCTAssertFalse(bad.links.contains { $0.target == "b" && $0.relationship == "request" })
        XCTAssertTrue(bad.links.contains { $0.target == "click" && $0.relationship == "nearby" })
        XCTAssertTrue(bad.links.contains { $0.target == "error" && $0.relationship == "nearby" })
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.event.id == "unknown" }).links.contains { $0.relationship == "request" })
        var legacy = c
        for index in legacy.events.indices {
            legacy.events[index].data.removeValue(forKey: "targetSession")
            legacy.events[index].data["sessionId"] = .string("[REDACTED]")
        }
        XCTAssertFalse(IncidentEvidence.timeline(capture: legacy).flatMap(\.links).contains { $0.relationship == "request" })
    }
    func testSelectionRetainsLateFailureAndRelatedRequestAsValidJSONAndReportsOmissions() throws {
        var events = (0..<250).map { ("info-\($0)", Double($0), "console", ["text": JSONValue.string(String(repeating: "noise", count: 80))]) }
        events += [("request", 500, "request", ["requestId": .string("r"), "url": .string("https://example.test/save")]), ("failure", 510, "response", ["requestId": .string("r"), "status": .number(503)]), ("click", 499, "action", ["type": .string("click")])]
        let c = capture(events)
        let item = NotebookObservation(projectId: "p", captures: [c])
        let selection = try IncidentEvidence.select(observation: item, byteLimit: 10_000)
        let bytes = try JSONEncoder().encode(selection)
        XCTAssertLessThanOrEqual(bytes.count, 10_000)
        XCTAssertLessThanOrEqual(selection.pretty.utf8.count, 10_000)
        let json = try JSONDecoder().decode(JSONValue.self, from: bytes)
        let selected = json["captures"]?.arrayValue?.first?["events"]?.arrayValue ?? []
        XCTAssertTrue(selected.contains { $0["id"]?.stringValue == "failure" })
        XCTAssertTrue(selected.contains { $0["id"]?.stringValue == "request" })
        XCTAssertTrue(selected.contains { $0["id"]?.stringValue == "click" })
        XCTAssertGreaterThan(json["selection"]?["omittedEventCount"]?.intValue ?? 0, 0)
        let omitted = json["selection"]?["omittedEventIDs"]?.arrayValue ?? []
        XCTAssertFalse(omitted.isEmpty)
        XCTAssertFalse(selected.contains { event in omitted.contains(.string(event["id"]?.stringValue ?? "")) })
        XCTAssertEqual(json["selection"]?["omittedIDListTruncated"]?.boolValue, true)
        XCTAssertEqual(item.captures[0].events.count, 253)
        let findings = (0..<40).map { Finding(kind: "observed", text: String(repeating: "detail ", count: 30) + String($0)) }
        for limit in [4096, 6000, 10_000] { XCTAssertLessThanOrEqual(try IncidentEvidence.selectFindings(findings, byteLimit: limit).pretty.utf8.count, limit) }
    }
    func testRedirectHopsAndForeignDocumentsDoNotClaimRequestRelationships() throws {
        var c = capture([("first", 1, "request", ["requestId": .string("r")]), ("redirect", 2, "request", ["requestId": .string("r")]), ("response", 3, "response", ["requestId": .string("r"), "status": .number(500)])])
        var foreign = c.events[0]; foreign.id = "foreign"; foreign.documentId = "other"; c.events.append(foreign)
        let response = try XCTUnwrap(IncidentEvidence.timeline(capture: c).first { $0.event.id == "response" })
        XCTAssertTrue(response.links.contains { $0.target == "redirect" && $0.relationship == "request" })
        XCTAssertFalse(response.links.contains { ["first", "foreign"].contains($0.target) && $0.relationship == "request" })
    }
    func testRedirectHopsAtSameMillisecondKeepRecordedOrder() throws {
        let c = capture([("z-first", 1, "request", ["requestId": .string("r")]), ("a-redirect", 1, "request", ["requestId": .string("r")]), ("response", 1, "response", ["requestId": .string("r"), "status": .number(503)])])
        let row = try XCTUnwrap(IncidentEvidence.timeline(capture: c).last)
        XCTAssertEqual(row.event.id, "response")
        XCTAssertTrue(row.links.contains { $0.target == "a-redirect" && $0.relationship == "request" })
        XCTAssertFalse(row.links.contains { $0.target == "z-first" && $0.relationship == "request" })
    }
    func testRepeatedRollingEventCopiesDoNotCorruptOmissionsOrExceedSelectionBudget() throws {
        let first = capture([("shared-failure", 1, "response", ["status": .number(503), "text": .string(String(repeating: "detail ", count: 300))])])
        var second = first; second.id = UUID().uuidString
        let item = NotebookObservation(projectId: "p", captures: [first, second])
        for limit in [6000, 9000] {
            let selection = try IncidentEvidence.select(observation: item, byteLimit: limit)
            let included = (selection["captures"]?.arrayValue ?? []).flatMap { $0["events"]?.arrayValue ?? [] }.compactMap { $0["id"]?.stringValue }
            let omitted = (selection["selection"]?["omittedEventIDs"]?.arrayValue ?? []).compactMap(\.stringValue)
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(selection).count, limit)
            XCTAssertLessThanOrEqual(selection.pretty.utf8.count, limit)
            XCTAssertEqual(included, ["shared-failure"])
            XCTAssertTrue(Set(included).isDisjoint(with: omitted))
            XCTAssertEqual(selection["selection"]?["duplicateEventCopies"]?.intValue, 1)
        }
    }
}
