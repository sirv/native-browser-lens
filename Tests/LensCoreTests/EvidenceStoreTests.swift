import XCTest
@testable import LensCore

final class EvidenceStoreTests: XCTestCase {
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
