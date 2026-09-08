import XCTest
@testable import LensCore

final class InvestigationTests: XCTestCase {
    func testCollectorNestedLogErrorsAreObservedWhileInformationalLogsAreExcluded() async throws {
        // The collector preserves Log.entryAdded under data.entry; this differs
        // from Runtime.consoleAPICalled's top-level data.type.
        let events = ["error", "warning", "info"].map { level in
            EvidenceEvent(id: "log-" + level, projectId: "p", tabId: 7, documentId: "doc", kind: "console", data: [
                "entry": .object(["level": .string(level), "text": .string("Browser log " + level), "source": .string("network")]),
            ])
        }
        let capture = CaptureRecord(identity: CaptureIdentity(projectId: "p", tabId: 7, documentId: "doc"), events: events)
        let findings = try await Investigator.investigate(observation: NotebookObservation(projectId: "p", captures: [capture]), project: ProjectProfile(id: "p"), apiKey: nil)
        for level in ["error", "warning"] {
            let finding = findings.first { $0.source == "event:log-" + level }
            XCTAssertEqual(finding?.kind, "observed")
            XCTAssertTrue(finding?.text.contains("Browser log " + level) == true)
        }
        XCTAssertFalse(findings.contains { $0.source == "event:log-info" })
    }

    func testCollectorNetworkFailureBecomesObservedFindingWithEventReference() async throws {
        // Network.loadingFailed is emitted as network-failure and has no HTTP
        // status, so the failed-status branch cannot recover this evidence.
        let failure = EvidenceEvent(id: "captured-network-failure", projectId: "p", tabId: 7, documentId: "doc", kind: "network-failure", data: [
            "requestId": .string("request-42"), "errorText": .string("net::ERR_CONNECTION_REFUSED"), "canceled": .bool(false),
        ])
        let capture = CaptureRecord(identity: CaptureIdentity(projectId: "p", tabId: 7, documentId: "doc"), events: [failure])
        let findings = try await Investigator.investigate(observation: NotebookObservation(projectId: "p", captures: [capture]), project: ProjectProfile(id: "p"), apiKey: nil)
        let observed = findings.first { $0.source == "event:" + failure.id }
        XCTAssertEqual(observed?.kind, "observed")
        XCTAssertTrue(observed?.text.contains("net::ERR_CONNECTION_REFUSED") == true)
        XCTAssertTrue(observed?.text.contains("request-42") == true)
    }

    func testStableSourceStampResolvesAndAnUnresolvedAnnotationDoesNotFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("export const staleImageFixture = true;".utf8).write(to: root.appendingPathComponent("src/Button.tsx"))
        var capture = CaptureRecord(identity: CaptureIdentity(projectId: "p", tabId: 7, documentId: "doc"))
        capture.context["elements"] = .array([.object(["source": .string("src/Button.tsx:1:1"), "binding": .string("stable-across-capture"), "captureId": .string(capture.id), "documentId": .string("doc"), "tabId": .number(7)])])
        var observation = NotebookObservation(projectId: "p", captures: [capture])
        let project = ProjectProfile(id: "p", repositoryPath: root.path)
        let findings = try await Investigator.investigate(observation: observation, project: project, apiKey: nil)
        XCTAssertTrue(findings.contains { $0.text.contains("staleImageFixture") })
        observation.captures[0].context["selectedElementRefs"] = .array([])
        let unresolved = try await Investigator.investigate(observation: observation, project: project, apiKey: nil)
        XCTAssertFalse(unresolved.contains { $0.text.contains("staleImageFixture") })
    }
    func testCloudSelectionExcludesUnselectedCapturesAndPriorLocalFindings() throws {
        let a = CaptureRecord(identity: CaptureIdentity(projectId: "p"), context: ["includeInAI": .bool(true), "videoPath": .string("/private/raw.mp4")], screenshotPath: "/reviewed.png", originalScreenshotPath: "/private/raw.png")
        let b = CaptureRecord(identity: CaptureIdentity(projectId: "p"), context: ["unshared": .string("private evidence")])
        let observation = NotebookObservation(projectId: "p", captures: [a, b], findings: [Finding(kind: "observed", text: "Private finding from unselected capture")])
        let shared = try EvidenceSanitizer.cloudSelection(observation)
        XCTAssertEqual(shared.captures.map(\.id), [a.id])
        XCTAssertTrue(shared.findings.isEmpty)
        XCTAssertNil(shared.captures.first?.originalScreenshotPath)
        XCTAssertNil(shared.captures.first?.context["videoPath"])
        XCTAssertEqual(shared.captures.first?.screenshotPath, "/reviewed.png")
    }
    func testSourceFromDifferentBuildCannotBePresentedAsMatchedImplementation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("export const broken = false;".utf8).write(to: root.appendingPathComponent("src/Button.tsx"))
        let result = try SourceResolver.resolve(reference: "src/Button.tsx:1:1", project: ProjectProfile(repositoryPath: root.path), observedBuild: String(repeating: "a", count: 40))
        XCTAssertFalse(result.matchedBuild)
        XCTAssertTrue(result.explanation.contains("unmatched"))
    }
    func testSourceReferenceCannotReadASecretOrEscapeRepository() throws {
        let project = ProjectProfile(repositoryPath: "/tmp")
        XCTAssertThrowsError(try SourceResolver.resolve(reference: "../etc/passwd:1:1", project: project, observedBuild: nil))
        XCTAssertThrowsError(try SourceResolver.resolve(reference: ".env:1:1", project: project, observedBuild: nil))
    }
    func testCloudImageLimitsKeepTechnicalEvidenceAndReportEachOmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let small = root.appendingPathComponent("small.png"); try Data([1, 2, 3]).write(to: small)
        let large = root.appendingPathComponent("large.png"); try Data(count: 4_000_001).write(to: large)
        let paths = [small.path, large.path, root.appendingPathComponent("missing.png").path, small.path, small.path]
        let captures = paths.map { CaptureRecord(identity: CaptureIdentity(projectId: "p"), context: ["includeInAI": .bool(true), "technical": .string("preserved")], screenshotPath: $0) }
        let result = EvidenceSanitizer.cloudImages(NotebookObservation(projectId: "p", captures: captures))
        XCTAssertEqual(result.captures.compactMap(\.screenshotPath).count, 2)
        XCTAssertEqual(result.captures.count, 5)
        XCTAssertTrue(result.captures.allSatisfy { $0.context["technical"]?.stringValue == "preserved" })
        for index in [1, 2, 4] { XCTAssertTrue(result.captures[index].gaps.contains { $0.channel == "cloud-image" }) }
    }
    func testStampedSourceCannotReadSecretThroughAnInRepositoryAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("secrets"), withIntermediateDirectories: true)
        try Data("PRIVATE_SECRET".utf8).write(to: root.appendingPathComponent("secrets/value.ts"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: root.appendingPathComponent("secrets").path)
        XCTAssertThrowsError(try SourceResolver.resolve(reference: "alias/value.ts:1", project: ProjectProfile(repositoryPath: root.path), observedBuild: nil))
    }
}
