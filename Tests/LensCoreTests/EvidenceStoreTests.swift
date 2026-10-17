import XCTest
import CSQLite
@testable import LensCore

final class EvidenceStoreTests: XCTestCase {
    func testTargetedLookupAndCaptureReplayDoNotDecodeTheWholeNotebook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        var item = NotebookObservation(projectId: "p", markdown: "My exact words")
        let capture = CaptureRecord(identity: CaptureIdentity(projectId: "p"))
        item.captures = [capture]
        let other = NotebookObservation(projectId: "other")
        try store.save(item); try store.save(other)
        XCTAssertEqual(try store.observation(id: item.id)?.markdown, "My exact words")
        XCTAssertNil(try store.observation(id: UUID().uuidString))
        XCTAssertTrue(try store.containsCapture(id: capture.id))
        XCTAssertFalse(try store.containsCapture(id: UUID().uuidString))
        XCTAssertThrowsError(try store.observation(id: "' OR 1=1 --"))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("notebook.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "UPDATE observations SET value=X'7b' WHERE id='\(other.id)'", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.observations())
        XCTAssertEqual(try store.observation(id: item.id)?.markdown, "My exact words")
    }
    func testProjectOriginsMatchBrowserCanonicalOrigins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        try store.saveProjects([ProjectProfile(origins: [" HTTPS://EXAMPLE.COM:443/ ", "http://localhost:80/", "http://[::1]:3000/"])])
        XCTAssertEqual(try store.projects()[0].origins, ["https://example.com", "http://localhost", "http://[::1]:3000"])
        XCTAssertThrowsError(try store.saveProjects([ProjectProfile(origins: ["https://example.com/path"])]))
    }
    func testExportContainsOnlyExplicitlyReviewedVideoAndKeepsPathsPortable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        var observation = NotebookObservation(projectId: "p")
        let video = try store.saveArtifact(observationId: observation.id, filename: "recording.mp4", data: Data("video fixture".utf8))
        observation.captures = [CaptureRecord(identity: CaptureIdentity(projectId: "p"), context: ["videoPath": .string(video.path), "videoReviewed": .bool(false)])]
        let privateExport = try store.export(observation: observation, to: root.appendingPathComponent("private-export"))
        let privateJSON = try JSONDecoder().decode(NotebookObservation.self, from: Data(contentsOf: privateExport.appendingPathComponent("evidence.json")))
        XCTAssertNil(privateJSON.captures[0].context["videoPath"])
        XCTAssertTrue(privateJSON.captures[0].gaps.contains { $0.channel == "video" })
        observation.captures[0].context["videoReviewed"] = .bool(true)
        let reviewedExport = try store.export(observation: observation, to: root.appendingPathComponent("reviewed-export"))
        let reviewedJSON = try JSONDecoder().decode(NotebookObservation.self, from: Data(contentsOf: reviewedExport.appendingPathComponent("evidence.json")))
        let path = try XCTUnwrap(reviewedJSON.captures[0].context["videoPath"]?.stringValue)
        XCTAssertFalse(path.hasPrefix("/"))
        XCTAssertEqual(try Data(contentsOf: reviewedExport.appendingPathComponent(path)), Data("video fixture".utf8))
    }
    func testSavedObservationSurvivesStoreReopenAndOtherProjectWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = EvidenceStore(root: root)
        let a = NotebookObservation(projectId: "project-a", title: "Stale image", markdown: "My exact words")
        try first.save(a)
        try first.save(NotebookObservation(projectId: "project-b", title: "Other tab"))
        let second = EvidenceStore(root: root)
        XCTAssertEqual(try second.observations().first(where: { $0.id == a.id })?.markdown, "My exact words")
    }
}
