#if os(Linux)
import XCTest
@testable import LensCore

final class LinuxNotebookTests: XCTestCase {
    func testHashMatchesPortableSHA256() {
        XCTAssertEqual(sha256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testCaptureSurvivesRestartAndAcknowledgesOnlyAfterImageIsSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root), bridge = BridgeMailbox(root: root)
        let project = ProjectProfile(origins: ["https://example.test"], enabled: true)
        try store.saveProjects([project])
        let observationID = UUID().uuidString, captureID = UUID().uuidString, clientID = UUID().uuidString
        let identity = CaptureIdentity(projectId: project.id, tabId: 1, windowId: 0, documentId: "doc", url: "https://example.test/page", title: "Defect")
        let tab = TabStatus(tabId: 1, projectId: project.id, url: identity.url, documentId: "doc")
        try bridge.receive(WireMessage(kind: "capture-started", payload: .object(["observationId": .string(observationID), "captureId": .string(captureID), "initiatedBy": .string("extension"), "identity": try .from(identity), "tab": try .from(tab)])), clientId: clientID)
        XCTAssertEqual(try NotebookInbox(store: store).sync().captureStarts.count, 1)
        XCTAssertEqual(try bridge.pending().count, 1)
        let png = Data([137,80,78,71,13,10,26,10,1,2,3])
        try bridge.receive(WireMessage(kind: "artifact", payload: .object(["observationId": .string(observationID), "captureId": .string(captureID), "index": .number(0), "total": .number(2), "mimeType": .string("image/png"), "data": .string(png.prefix(8).base64EncodedString())])), clientId: clientID)
        let final = WireMessage(kind: "capture", payload: .object(["observationId": .string(observationID), "captureId": .string(captureID), "identity": try .from(identity), "events": .array([]), "gaps": .array([]), "context": .object([:])]))
        try bridge.receive(final, clientId: clientID)
        XCTAssertTrue(try NotebookInbox(store: store).sync().capturedObservationIDs.isEmpty)
        XCTAssertEqual(try bridge.pending().count, 3)
        try bridge.receive(WireMessage(kind: "artifact", payload: .object(["observationId": .string(observationID), "captureId": .string(captureID), "index": .number(1), "total": .number(2), "mimeType": .string("image/png"), "data": .string(png.dropFirst(8).base64EncodedString())])), clientId: clientID)
        let obstruction = root.appendingPathComponent("observations")
        try Data("storage temporarily unavailable".utf8).write(to: obstruction)
        XCTAssertThrowsError(try NotebookInbox(store: store).sync())
        XCTAssertEqual(try bridge.pending().count, 4)
        try FileManager.default.removeItem(at: obstruction)
        let result = try NotebookInbox(store: store).sync()
        XCTAssertEqual(result.capturedObservationIDs, [observationID])
        let saved = try XCTUnwrap(store.observations().first)
        XCTAssertEqual(saved.captures.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(saved.captures.first?.screenshotPath))), png)
        XCTAssertTrue(try bridge.pending().isEmpty)
        try bridge.receive(final, clientId: clientID)
        _ = try NotebookInbox(store: store).sync()
        XCTAssertTrue(try bridge.pending().isEmpty)
        XCTAssertEqual(try store.observations().first?.captures.count, 1)
    }
    func testCrossProfileCaptureIsQuarantinedWithoutSavingOrDeletingOtherEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root), bridge = BridgeMailbox(root: root)
        let project = ProjectProfile(origins: ["https://example.test"], enabled: true)
        try store.saveProjects([project])
        let observationID = UUID().uuidString, captureID = UUID().uuidString
        let identity = CaptureIdentity(projectId: project.id, tabId: 1, windowId: 0, documentId: "doc", url: "https://example.test/page")
        let tab = TabStatus(tabId: 1, projectId: project.id, url: identity.url, documentId: "doc")
        try bridge.receive(WireMessage(kind: "capture-started", payload: .object(["observationId": .string(observationID), "captureId": .string(captureID), "initiatedBy": .string("extension"), "identity": try .from(identity), "tab": try .from(tab)])), clientId: UUID().uuidString)
        try bridge.receive(WireMessage(kind: "capture", payload: .object(["observationId": .string(observationID), "captureId": .string(captureID), "identity": try .from(identity)])), clientId: UUID().uuidString)
        let result = try NotebookInbox(store: store).sync()
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertTrue(try store.observations().isEmpty)
        XCTAssertTrue(try bridge.pending().isEmpty)
    }
}
#endif
