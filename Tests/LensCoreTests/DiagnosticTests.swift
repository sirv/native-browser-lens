import XCTest
@testable import LensCore

final class DiagnosticTests: XCTestCase {
    func testUnreviewedVerificationDoesNotCopyUnknownPayloadFieldsIntoPortableEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        var item = NotebookObservation(projectId: "p", captures: [CaptureRecord(identity: .init(projectId: "p"))])
        let identity = item.captures[0].identity
        let failure = EvidenceEvent(projectId: "p", tabId: identity.tabId, documentId: identity.documentId, kind: "response", data: ["url": .string("https://example.test/save"), "method": .string("POST"), "status": .number(503)])
        item.captures[0].events = [failure]
        let condition: JSONValue = .object(["type": .string("http-status"), "url": .string("https://example.test/save"), "method": .string("POST"), "failureStatus": .number(503), "successStatus": .number(200)])
        let contract: JSONValue = .object(["observationId": .string(item.id), "captureId": .string(item.captures[0].id), "failureEventId": .string(failure.id), "condition": condition])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var result = contract.objectValue!
        result.merge(["formatVersion": .number(1), "phase": .string("before"), "contractSHA256": .string(sha256(try encoder.encode(contract))), "stepsSHA256": .string(String(repeating: "a", count: 64)), "scriptSHA256": .string(String(repeating: "b", count: 64)), "executionComplete": .bool(true), "observedStatus": .number(503), "debugScreenshot": .string("private-unreviewed-image"), "failure": .string("private-unreviewed-error"), "buildId": .string("private-unreviewed-build"), "tool": .string("private-unreviewed-tool")], uniquingKeysWith: { _, value in value })
        let file = root.appendingPathComponent("result.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(JSONValue.object(result)).write(to: file)
        try DiagnosticArtifacts.attach(source: file, type: "verification", to: &item.captures[0], observationId: item.id, store: store)
        XCTAssertFalse(DiagnosticArtifacts.records(item.captures[0])[0]["result"]!.pretty.contains("private-unreviewed"))
        var legacy = DiagnosticArtifacts.records(item.captures[0])[0].objectValue!
        legacy["result"] = .object(result)
        item.captures[0].context["diagnosticArtifacts"] = .array([.object(legacy)])
        let exported = try store.export(observation: item, to: root.appendingPathComponent("exports"))
        let metadata = try String(contentsOf: exported.appendingPathComponent("evidence.json"))
        XCTAssertFalse(metadata.contains("private-unreviewed"))
        XCTAssertTrue(metadata.contains("observedStatus"))
        XCTAssertEqual(Reproduction.summary(capture: item.captures[0])["status"]?.stringValue, "needs-before-and-after")
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: URL(fileURLWithPath: DiagnosticArtifacts.records(item.captures[0])[0]["path"]!.stringValue!)))
        var unsafe = condition.objectValue!; unsafe["debugBody"] = .string("private-condition-body")
        result["condition"] = .object(unsafe)
        let unsafeContract = JSONValue.object(Dictionary(uniqueKeysWithValues: ["observationId", "captureId", "failureEventId", "condition"].map { ($0, result[$0]!) }))
        result["contractSHA256"] = .string(sha256(try encoder.encode(unsafeContract)))
        XCTAssertThrowsError(try DiagnosticArtifacts.validateResult(.object(result), observationId: item.id, capture: item.captures[0]))
        var differentEndpoint = condition.objectValue!; differentEndpoint["url"] = .string("https://other.test/save")
        result["condition"] = .object(differentEndpoint)
        let differentContract = JSONValue.object(Dictionary(uniqueKeysWithValues: ["observationId", "captureId", "failureEventId", "condition"].map { ($0, result[$0]!) }))
        result["contractSHA256"] = .string(sha256(try encoder.encode(differentContract)))
        XCTAssertThrowsError(try DiagnosticArtifacts.validateResult(.object(result), observationId: item.id, capture: item.captures[0]))
    }
    func testImportedURLRedactsSessionAndAntiForgeryParametersWithoutChangingEvidenceSessionIDs() throws {
        let url = DiagnosticArtifacts.safeURL("https://user:pass@example.test/save?sessionId=privateSession&session_id=privateSession&passwd=privatePassword&csrf=privateCSRF&xsrf=privateXSRF&view=one")
        XCTAssertFalse(url.contains("private")); XCTAssertFalse(url.contains("user:pass")); XCTAssertTrue(url.contains("view=one"))
        let evidence = EvidenceSanitizer.json(.object(["sessionId": .string("public-cdp-target-session")]))
        XCTAssertEqual(evidence["sessionId"]?.stringValue, "public-cdp-target-session")
    }
    func testVerificationRequiresMatchingStepsScriptConditionAndBothCompletedStatuses() throws {
        var capture = CaptureRecord(identity: .init(projectId: "p"))
        let identity = capture.identity
        let failure = EvidenceEvent(projectId: "p", tabId: identity.tabId, documentId: identity.documentId, kind: "response", data: ["url": .string("https://example.test/save"), "method": .string("POST"), "status": .number(503)])
        capture.events = [failure]
        func run(_ phase: String, _ status: Int, steps: String = "b", complete: Bool = true, endpoint: String = "https://example.test/save", count: Int = 1) -> JSONValue {
            .object(["captureId": .string(capture.id), "failureEventId": .string(failure.id), "phase": .string(phase), "observedStatus": .number(Double(status)), "matchingResponseCount": .number(Double(count)), "executionComplete": .bool(complete), "contractSHA256": .string(String(repeating: "a", count: 64)), "stepsSHA256": .string(String(repeating: steps, count: 64)), "scriptSHA256": .string(String(repeating: "c", count: 64)), "condition": .object(["type": .string("http-status"), "url": .string(endpoint), "method": .string("POST"), "failureStatus": .number(503), "successStatus": .number(200)])])
        }
        let before = run("before", 503)
        func results(_ values: [JSONValue]) { capture.context["diagnosticArtifacts"] = .array(values.map { .object(["result": $0]) }) }
        results([before]); XCTAssertEqual(Reproduction.summary(capture: capture)["status"]?.stringValue, "needs-before-and-after")
        results([before, run("after", 200)]); XCTAssertEqual(Reproduction.summary(capture: capture)["status"]?.stringValue, "same-condition-check-passed")
        results([before, run("after", 200, steps: "d")]); XCTAssertEqual(Reproduction.summary(capture: capture)["status"]?.stringValue, "incomplete-or-mismatched")
        results([before, run("after", 200, complete: false)]); XCTAssertEqual(Reproduction.summary(capture: capture)["status"]?.stringValue, "incomplete-or-mismatched")
        results([before, run("after", 500)]); XCTAssertEqual(Reproduction.summary(capture: capture)["status"]?.stringValue, "incomplete-or-mismatched")
        results([before, run("after", 200, count: 2)]); XCTAssertEqual(Reproduction.summary(capture: capture)["status"]?.stringValue, "incomplete-or-mismatched")
        results([run("before", 503, endpoint: "https://other.test/save"), run("after", 200, endpoint: "https://other.test/save")]); XCTAssertEqual(Reproduction.summary(capture: capture)["status"]?.stringValue, "incomplete-or-mismatched")
    }
    func testHARImportStripsCookiesAuthorizationAndBodiesAndKeepsOriginCoverage() throws {
        let har: JSONValue = .object(["log": .object(["entries": .array([.object([
            "startedDateTime": .string("2026-10-17T10:00:00Z"), "time": .number(42),
            "request": .object(["method": .string("POST"), "url": .string("https://example.test/save?token=secret&view=one"), "headers": .array([.object(["name": .string("Authorization"), "value": .string("Bearer private")]), .object(["name": .string("X-Session-ID"), "value": .string("privateSession")]), .object(["name": .string("X-CSRF"), "value": .string("privateCSRF")])]), "cookies": .array([.string("private")]), "postData": .object(["text": .string("private body")])]),
            "response": .object(["status": .number(503), "headers": .array([.object(["name": .string("X-Request-ID"), "value": .string("request-123")]), .object(["name": .string("X-Session-ID"), "value": .string("privateSession")]), .object(["name": .string("X-XSRF"), "value": .string("privateXSRF")])]), "content": .object(["text": .string("private body")])])
        ]), .object(["request": .object(["url": .string("https://other.test/ignored")])])])])])
        let capture = CaptureRecord(identity: .init(projectId: "p", tabId: 1, documentId: "d", url: "https://example.test/page"))
        let events = try DiagnosticArtifacts.harEvents(har, capture: capture, importID: "import")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data["status"]?.intValue, 503)
        let text = try JSONValue.from(events).pretty
        XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("token=secret"))
        XCTAssertTrue(text.contains("request-123")); XCTAssertTrue(text.contains("view=one"))
        XCTAssertTrue(text.contains("imported"))
        let legacy = EvidenceSanitizer.json(.object(["sessionId": .string("public-cdp-session"), "headers": .object(["X-Session-ID": .string("privateLegacy"), "X-Request-ID": .string("request-123")])]))
        XCTAssertFalse(legacy.pretty.contains("privateLegacy")); XCTAssertEqual(legacy["sessionId"]?.stringValue, "public-cdp-session")
        XCTAssertEqual(legacy["headers"]?["X-Request-ID"]?.stringValue, "request-123")
        let firefox = EvidenceSanitizer.json(.object(["sessionId": .string("public-cdp-session"), "responseHeaders": .array([
            .object(["name": .string("X-Session"), "value": .string("privateFirefoxSession")]),
            .object(["name": .string("X-Session-ID"), "binaryValue": .array([.number(65), .number(66)])]),
            .object(["name": .string("X-Request-ID"), "value": .string("request-123")])
        ])]))
        XCTAssertFalse(firefox.pretty.contains("privateFirefoxSession"))
        XCTAssertNil(firefox["responseHeaders"]?.arrayValue?[1]["binaryValue"])
        XCTAssertEqual(firefox["responseHeaders"]?.arrayValue?[2]["value"]?.stringValue, "request-123")
        XCTAssertEqual(firefox["sessionId"]?.stringValue, "public-cdp-session")
    }
    func testUnreviewedDiagnosticsStayLocalAndReviewedFilesSurvivePortableRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        var item = NotebookObservation(projectId: "p", captures: [CaptureRecord(identity: .init(projectId: "p"))])
        let file = try store.saveArtifact(observationId: item.id, filename: "diagnostic-profile.json", data: Data("{\"nodes\":[]}".utf8))
        item.captures[0].context["diagnosticArtifacts"] = .array([.object(["id": .string("artifact"), "type": .string("profile"), "path": .string(file.path), "reviewed": .bool(false), "sha256": .string(sha256(try Data(contentsOf: file)))])])
        let first = try store.export(observation: item, to: root.appendingPathComponent("exports-a"))
        let firstJSON = try String(contentsOf: first.appendingPathComponent("evidence.json"))
        XCTAssertFalse(firstJSON.contains(file.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("diagnostic-profile.json").path))
        var record = item.captures[0].context["diagnosticArtifacts"]!.arrayValue![0].objectValue!
        record["reviewed"] = .bool(true)
        item.captures[0].context["diagnosticArtifacts"] = .array([.object(record)])
        let second = try store.export(observation: item, to: root.appendingPathComponent("exports-b"))
        let shared = try ReviewedEvidence(folder: second)
        let artifact = try XCTUnwrap(shared.observation.captures[0].context["diagnosticArtifacts"]?.arrayValue?.first?["path"]?.stringValue)
        XCTAssertEqual(try Data(contentsOf: shared.file(artifact)), try Data(contentsOf: file))
        let imported = try store.importObservation(from: second, projectId: "p")
        let importedArtifact = try XCTUnwrap(imported.captures[0].context["diagnosticArtifacts"]?.arrayValue?.first)
        XCTAssertEqual(importedArtifact["reviewed"]?.boolValue, false)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: importedArtifact["path"]!.stringValue!)), try Data(contentsOf: file))
    }
}
