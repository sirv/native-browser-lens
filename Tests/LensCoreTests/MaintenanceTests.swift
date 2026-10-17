import XCTest
@testable import LensCore

final class MaintenanceTests: XCTestCase {
    func testPortableImportRebindsOnlyMatchingSpatialCaptureReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("export const importedSourceFixture = true;".utf8).write(to: root.appendingPathComponent("src/Control.ts"))
        var capture = CaptureRecord(identity: .init(projectId: "p", tabId: 1, documentId: "doc"))
        let source = "src/Control.ts:1"
        func element(_ id: String) -> JSONValue { .object(["captureId": .string(id), "documentId": .string("doc"), "tabId": .number(1), "source": .string(source), "binding": .string("stable-across-capture"), "bounds": .object(["x": .number(0), "y": .number(0), "width": .number(100), "height": .number(100)])]) }
        capture.context = ["captureId": .string(capture.id), "documentId": .string("doc"), "coordinateSpace": .string("browser-viewport"), "viewport": .object(["width": .number(100), "height": .number(100)]), "elements": .array([element(capture.id), element("foreign-capture")]), "annotationBindings": .array([.object(["captureId": .string(capture.id), "sourceRef": .string(source)])])]
        let original = NotebookObservation(projectId: "p", captures: [capture])
        let folder = try store.export(observation: original, to: root.appendingPathComponent("export"))
        let imported = try store.importObservation(from: folder, projectId: "destination")
        let copy = try XCTUnwrap(imported.captures.first)
        XCTAssertNotEqual(copy.id, capture.id)
        XCTAssertEqual(copy.context["captureId"]?.stringValue, copy.id)
        XCTAssertEqual(copy.context["elements"]?.arrayValue?[0]["captureId"]?.stringValue, copy.id)
        XCTAssertEqual(copy.context["elements"]?.arrayValue?[1]["captureId"]?.stringValue, "foreign-capture")
        XCTAssertEqual(copy.context["annotationBindings"]?.arrayValue?[0]["captureId"]?.stringValue, copy.id)
        let mark = Annotation(kind: "rectangle", points: [.init(x: 0.25, y: 0.25), .init(x: 0.75, y: 0.75)])
        XCTAssertEqual(SpatialAnnotationResolver.references(annotations: [mark], capture: copy), [source])
        let findings = try await Investigator.investigate(observation: imported, project: .init(id: "destination", repositoryPath: root.path), apiKey: nil)
        XCTAssertTrue(findings.contains { $0.text.contains("importedSourceFixture") })
    }
    func testPortableImportPreservesExistingNotesAndRejectsEscapingMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        var item = NotebookObservation(projectId: "p", markdown: "Existing note")
        let image = try store.saveArtifact(observationId: item.id, filename: "masked.png", data: Data([137,80,78,71,13,10,26,10]))
        let original = try store.saveArtifact(observationId: item.id, filename: "private.png", data: Data("private".utf8))
        item.captures = [CaptureRecord(identity: CaptureIdentity(projectId: "p"), screenshotPath: image.path, originalScreenshotPath: original.path, annotations: [Annotation(kind: "mask", points: [.init(x: 0, y: 0), .init(x: 1, y: 1)])])]
        try store.save(item)
        let exported = try store.export(observation: item, to: root.appendingPathComponent("export"))
        let imported = try store.importObservation(from: exported, projectId: "new-project")
        XCTAssertNotEqual(imported.id, item.id)
        XCTAssertEqual(imported.projectId, "new-project")
        XCTAssertEqual(imported.markdown, item.markdown)
        XCTAssertNil(imported.receipt)
        XCTAssertTrue(imported.captures[0].annotations.isEmpty)
        XCTAssertNotNil(imported.captures[0].context["importedAnnotations"])
        XCTAssertNoThrow(try EvidenceSanitizer.exportable(imported))
        XCTAssertEqual(try store.observations().count, 2)
        var poison = try JSONDecoder().decode(NotebookObservation.self, from: Data(contentsOf: exported.appendingPathComponent("evidence.json")))
        poison.captures[0].screenshotPath = "../../private.png"
        try JSONEncoder().encode(poison).write(to: exported.appendingPathComponent("evidence.json"))
        XCTAssertThrowsError(try store.importObservation(from: exported, projectId: "p"))
        XCTAssertEqual(try store.observations().count, 2)
    }
    func testArchiveAndTrashAreBackwardCompatibleAndSurviveSaving() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        var item = NotebookObservation(projectId: "p")
        let old = try JSONEncoder().encode(item)
        XCTAssertNil(try JSONDecoder().decode(NotebookObservation.self, from: old).trashedAt)
        item.archivedAt = 100; item.trashedAt = 200
        try store.save(item)
        XCTAssertEqual(try store.observations().first?.trashedAt, 200)
        XCTAssertEqual(try store.observations().first?.archivedAt, 100)
    }

    func testRestoredFilingKeepsItsSubmissionIdentityAndRebindsOnlyLocalPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let oldRoot = "/old/private/notebook"
        var item = NotebookObservation(projectId: "p")
        item.captures = [CaptureRecord(identity: CaptureIdentity(projectId: "p"), screenshotPath: oldRoot + "/observations/" + item.id + "/a.png")]
        try store.save(item)
        let attempt: JSONValue = .object([
            "formatVersion": .number(2), "endpoint": .string("https://tracker.test"), "memberId": .string("m"), "snapshotHash": .string("old"),
            "exportPath": .string(oldRoot + "/observations/" + item.id + "/filing-r1"), "snapshot": try .from(item),
            "submission": .object(["submissionId": .string("original-submission"), "observationId": .string(item.id), "revision": .number(1), "projectId": .string("p"), "title": .string(item.title), "markdown": .string("Reviewed report"), "reviewed": .bool(true), "evidenceManifest": .array([])])
        ])
        let path = try store.saveArtifact(observationId: item.id, filename: "submission-r1.json", data: JSONEncoder().encode(attempt))
        try VibeQClient.rebaseBackup(store: store, oldRoot: oldRoot, newRoot: root.path)
        let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: path))
        XCTAssertEqual(saved["submission"]?["submissionId"]?.stringValue, "original-submission")
        XCTAssertEqual(saved["submission"]?["markdown"]?.stringValue, "Reviewed report")
        XCTAssertTrue(try XCTUnwrap(saved["exportPath"]?.stringValue).hasPrefix(root.path + "/"))
        let snapshot = try XCTUnwrap(VibeQClient.pendingSubmission(observationId: item.id, revision: 1, store: store)?.observation)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(saved["snapshotHash"]?.stringValue, sha256(try encoder.encode(snapshot)))
        XCTAssertTrue(try XCTUnwrap(store.observations().first?.captures.first?.screenshotPath).hasPrefix(root.path + "/"))
    }
}
