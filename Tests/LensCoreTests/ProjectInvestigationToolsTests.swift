import XCTest
@testable import LensCore

final class ProjectInvestigationToolsTests: XCTestCase {
    func testSearchFollowsSourceTestsAndDocsWithoutSecretsOrSymlinkEscapes() async throws {
        let fixture = try ProjectToolsFixture()
        defer { fixture.close() }
        try fixture.write("src/Image.ts", "export const refreshImage = true")
        try fixture.write("tests/Image.test.ts", "test('refreshImage', () => {})")
        try fixture.write("docs/images.md", "refreshImage updates the saved image")
        try fixture.write("secrets/private.ts", "refreshImage PRIVATE_SECRET")
        try fixture.write(".env", "refreshImage=PRIVATE_ENV")
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".ts")
        try Data("refreshImage OUTSIDE_SECRET".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("src/external.ts"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("src/alias.ts"), withDestinationURL: fixture.root.appendingPathComponent("secrets/private.ts"))
        let tools = fixture.tools()
        let result = await tools.execute(name: "search_project", arguments: .object(["query": .string("refreshImage")]))
        let sources = try XCTUnwrap(result["findings"]).decode([Finding].self).compactMap(\.source)
        XCTAssertTrue(sources.contains { $0.contains("src/Image.ts") }, result.pretty)
        XCTAssertTrue(sources.contains { $0.contains("tests/Image.test.ts") }, result.pretty)
        XCTAssertTrue(sources.contains { $0.contains("docs/images.md") }, result.pretty)
        XCTAssertFalse(result.pretty.contains("PRIVATE_"))
        XCTAssertFalse(result.pretty.contains("OUTSIDE_SECRET"))
        let denied = await tools.execute(name: "read_project_file", arguments: .object(["path": .string("src/external.ts"), "line": .number(1)]))
        XCTAssertFalse(denied.pretty.contains("OUTSIDE_SECRET"))
        let secretAlias = await tools.execute(name: "read_project_file", arguments: .object(["path": .string("src/alias.ts"), "line": .number(1)]))
        XCTAssertFalse(secretAlias.pretty.contains("PRIVATE_SECRET"))
    }

    func testWorkingTreeAndConflictingBuildsNeverAssertMatchedSource() async throws {
        let fixture = try ProjectToolsFixture()
        defer { fixture.close() }
        try fixture.write("src/Image.ts", "export const version = 'OBSERVED_BUILD'")
        let build = try fixture.commit()
        try fixture.write("src/Image.ts", "export const version = 'SECOND_BUILD'")
        let secondBuild = try fixture.commit()
        try fixture.write("src/Image.ts", "export const version = 'CURRENT_CHECKOUT'")
        let verified = CaptureRecord(identity: CaptureIdentity(projectId: fixture.project.id, buildId: build))
        let exactTools = fixture.tools(captures: [verified])
        let exact = await exactTools.execute(name: "read_project_file", arguments: .object(["path": .string("src/Image.ts"), "line": .number(1)]))
        XCTAssertTrue(exact.pretty.contains("OBSERVED_BUILD"))
        XCTAssertFalse(exact.pretty.contains("CURRENT_CHECKOUT"))
        let exactFindings = await exactTools.evidence()
        XCTAssertEqual(exactFindings.first?.kind, "observed")
        let capture = CaptureRecord(identity: CaptureIdentity(projectId: fixture.project.id, buildId: build), context: ["sourceBuildVerified": .bool(false)])
        let tools = fixture.tools(captures: [capture])
        let result = await tools.execute(name: "read_project_file", arguments: .object(["path": .string("src/Image.ts"), "line": .number(1)]))
        XCTAssertTrue(result.pretty.contains("CURRENT_CHECKOUT"))
        let findings = await tools.evidence()
        XCTAssertTrue(findings.allSatisfy { $0.kind == "coverage" })
        XCTAssertTrue(result.pretty.lowercased().contains("unmatched"))
        let conflictTools = fixture.tools(captures: [verified, CaptureRecord(identity: CaptureIdentity(projectId: fixture.project.id, buildId: secondBuild))])
        let conflict = await conflictTools.execute(name: "read_project_file", arguments: .object(["path": .string("src/Image.ts"), "line": .number(1)]))
        XCTAssertTrue(conflict.pretty.contains("CURRENT_CHECKOUT"))
        let conflictFindings = await conflictTools.evidence()
        XCTAssertTrue(conflictFindings.allSatisfy { $0.kind == "coverage" })
    }

    func testRequestsAndCorrelatedLogsUseOnlySelectedProjectEvidence() async throws {
        let fixture = try ProjectToolsFixture()
        defer { fixture.close() }
        try fixture.write("logs/server.log", "trace-selected-123 image saved token=SECRET_TOKEN\ntrace-private-456 PRIVATE_OTHER_REQUEST")
        try fixture.write("secrets/server.log", "trace-selected-123 PRIVATE_LOG_SECRET")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("logs/alias.log"), withDestinationURL: fixture.root.appendingPathComponent("secrets/server.log"))
        var project = fixture.project; project.logPaths = ["logs/server.log", "logs/alias.log"]
        let selected = CaptureRecord(identity: CaptureIdentity(projectId: project.id, tabId: 7), events: [
            EvidenceEvent(id: "selected", projectId: project.id, tabId: 7, documentId: "doc", kind: "network", data: ["requestId": .string("trace-selected-123"), "authorization": .string("PRIVATE_TOKEN")]),
            EvidenceEvent(id: "other-project", projectId: "foreign", tabId: 7, documentId: "doc", kind: "network", data: ["requestId": .string("trace-private-456")]),
        ])
        let tools = ProjectInvestigationTools(project: project, observation: NotebookObservation(projectId: project.id, captures: [selected]))
        let request = await tools.execute(name: "lookup_request", arguments: .object(["id": .string("selected")]))
        XCTAssertTrue(request.pretty.contains("trace-selected-123"))
        XCTAssertFalse(request.pretty.contains("PRIVATE_TOKEN"))
        let unrelated = await tools.execute(name: "lookup_request", arguments: .object(["id": .string("other-project")]))
        XCTAssertFalse(unrelated.pretty.contains("trace-private-456"))
        let denied = await tools.execute(name: "lookup_correlated_logs", arguments: .object(["traceId": .string("trace-private-456")]))
        XCTAssertFalse(denied.pretty.contains("PRIVATE_OTHER_REQUEST"))
        let logs = await tools.execute(name: "lookup_correlated_logs", arguments: .object(["traceId": .string("trace-selected-123")]))
        XCTAssertTrue(logs.pretty.contains("image saved"))
        XCTAssertFalse(logs.pretty.contains("SECRET_TOKEN"))
        XCTAssertFalse(logs.pretty.contains("PRIVATE_OTHER_REQUEST"))
        XCTAssertFalse(logs.pretty.contains("PRIVATE_LOG_SECRET"))
    }

    func testCallsAndReturnedEvidenceStayWithinBudget() async throws {
        let fixture = try ProjectToolsFixture()
        defer { fixture.close() }
        try fixture.write("src/Image.ts", String(repeating: "x", count: 200_000))
        let tools = fixture.tools()
        for _ in 0..<12 { _ = await tools.execute(name: "read_project_file", arguments: .object(["path": .string("src/Image.ts"), "line": .number(1)])) }
        let before = await tools.evidence()
        let exhausted = await tools.execute(name: "read_project_file", arguments: .object(["path": .string("src/Image.ts"), "line": .number(1)]))
        let after = await tools.evidence()
        XCTAssertLessThanOrEqual(before.reduce(0) { $0 + $1.text.utf8.count }, 64_000)
        XCTAssertEqual(before, after)
        XCTAssertEqual(exhausted["remainingCalls"]?.intValue, 0)
        XCTAssertTrue(exhausted["truncated"]?.boolValue == true)
    }
}

private struct ProjectToolsFixture {
    let root: URL
    var project: ProjectProfile { ProjectProfile(id: "selected-project", repositoryPath: root.path) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func commit() throws -> String {
        // Commits exist only inside this disposable fixture, never the application repository.
        _ = try LocalRead.command("/usr/bin/git", ["init", "--quiet"], directory: root.path)
        _ = try LocalRead.command("/usr/bin/git", ["add", "src/Image.ts"], directory: root.path)
        _ = try LocalRead.command("/usr/bin/git", ["-c", "user.name=Lens Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Fixture source version"], directory: root.path)
        return try LocalRead.command("/usr/bin/git", ["rev-parse", "HEAD"], directory: root.path).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func tools(captures: [CaptureRecord] = []) -> ProjectInvestigationTools {
        ProjectInvestigationTools(project: project, observation: NotebookObservation(projectId: project.id, captures: captures))
    }
}
