import XCTest
import Foundation
import LensCore
@testable import NativeLens

final class NotebookStateTests: XCTestCase {
    @MainActor func testQueuedExtensionCaptureSurvivesAppRestartAndRejectsOtherProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectProfile(name: "Fixture project", origins: ["https://fixture.test"], enabled: true)
        let store = EvidenceStore(root: root); try store.saveProjects([project])
        let bridge = BridgeMailbox(root: root)
        let client = UUID().uuidString, wrongClient = UUID().uuidString
        let observationID = UUID().uuidString, captureID = UUID().uuidString
        let tab = TabStatus(tabId: 7, windowId: 10, projectId: project.id, url: "https://fixture.test/page", title: "Fixture", mode: "deep", documentId: "document-a", active: true)
        let identity = CaptureIdentity(projectId: project.id, tabId: 7, windowId: 10, documentId: "document-a", url: tab.url, title: tab.title)
        // Messages are durable before there is a running app or a current tab list.
        try bridge.receive(WireMessage(kind: "capture-started", payload: .object([
            "observationId": .string(observationID), "captureId": .string(captureID), "initiatedBy": .string("extension"),
            "identity": try .from(identity), "tab": try .from(tab)
        ])), clientId: client)
        let foreign = EvidenceEvent(projectId: UUID().uuidString, tabId: 7, documentId: "document-a", kind: "console", data: ["message": .string("Other project must never appear")])
        let final = WireMessage(kind: "capture", payload: .object([
            "observationId": .string(observationID), "captureId": .string(captureID), "identity": try .from(identity),
            "events": try .from([foreign]), "gaps": .array([]), "context": .object([:]), "screenshotOmission": .string("Fixture diagnostics-only capture")
        ]))
        try bridge.receive(final, clientId: wrongClient)
        let app = LensAppModel(root: root, revealWindows: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(app.observations.count, 1)
        XCTAssertTrue(app.observations[0].captures.isEmpty, "A foreign profile cannot satisfy a pending capture")
        try bridge.receive(final, clientId: client)
        try await eventually { app.observations.first?.captures.count == 1 }
        let saved = try XCTUnwrap(try store.observations().first)
        XCTAssertEqual(saved.id, observationID)
        XCTAssertEqual(saved.captures.first?.identity.clientId, client)
        XCTAssertEqual(saved.captures.first?.identity.windowId, 10)
        XCTAssertTrue(saved.captures.first?.events.isEmpty == true)
        XCTAssertTrue(saved.captures.first?.gaps.contains { $0.channel == "screenshot" } == true)
        XCTAssertTrue(try bridge.pending().isEmpty, "Only a committed complete capture acknowledges its input messages")
    }

    @MainActor func testDatabaseFailureRetainsCaptureUntilExplicitSaveRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectProfile(origins: ["https://fixture.test"], enabled: true)
        try EvidenceStore(root: root).saveProjects([project])
        let bridge = BridgeMailbox(root: root), client = UUID().uuidString
        let observationID = UUID().uuidString, captureID = UUID().uuidString
        let identity = CaptureIdentity(projectId: project.id, tabId: 1, documentId: "doc", url: "https://fixture.test", title: "Storage failure fixture")
        let tab = TabStatus(tabId: 1, projectId: project.id, url: identity.url, documentId: "doc")
        let app = LensAppModel(root: root, revealWindows: false)
        try bridge.receive(WireMessage(kind: "capture-started", payload: .object([
            "observationId": .string(observationID), "captureId": .string(captureID), "initiatedBy": .string("native"), "identity": try .from(identity), "tab": try .from(tab)
        ])), clientId: client)
        try await eventually { app.observations.count == 1 }
        let database = root.appendingPathComponent("notebook.sqlite"), backup = root.appendingPathComponent("notebook-backup.sqlite")
        try FileManager.default.moveItem(at: database, to: backup)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: false)
        try bridge.receive(WireMessage(kind: "capture", payload: .object([
            "observationId": .string(observationID), "captureId": .string(captureID), "identity": try .from(identity), "events": .array([]), "gaps": .array([]), "context": .object([:]), "screenshotOmission": .string("Fixture has no image")
        ])), clientId: client)
        try await eventually { app.unsavedCaptureCount == 1 }
        XCTAssertTrue(app.observations[0].captures.isEmpty)
        XCTAssertEqual(try bridge.pending().filter { ["capture-started", "capture"].contains($0.kind) }.count, 2)
        try FileManager.default.removeItem(at: database)
        try FileManager.default.moveItem(at: backup, to: database)
        app.retryCaptureSaves()
        XCTAssertEqual(app.unsavedCaptureCount, 0)
        XCTAssertEqual(try EvidenceStore(root: root).observations()[0].captures.count, 1)
        XCTAssertTrue(try bridge.pending().isEmpty)
    }

    @MainActor func testCaptureStartedOnUnconfiguredOriginDoesNotCreateNotebook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectProfile(origins: ["https://fixture.test"], enabled: true)
        try EvidenceStore(root: root).saveProjects([project])
        let identity = CaptureIdentity(projectId: project.id, tabId: 1, documentId: "one", url: "https://other.test")
        let tab = TabStatus(tabId: 1, projectId: project.id, url: identity.url, documentId: "one")
        let bridge = BridgeMailbox(root: root)
        try bridge.receive(WireMessage(kind: "capture-started", payload: .object([
            "observationId": .string(UUID().uuidString), "captureId": .string(UUID().uuidString), "initiatedBy": .string("extension"), "identity": try .from(identity), "tab": try .from(tab)
        ])), clientId: UUID().uuidString)
        let app = LensAppModel(root: root, revealWindows: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(app.observations.isEmpty)
    }

    @MainActor func testLateInvestigationDoesNotReplaceManualMarkdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectProfile(name: "Fixture", repositoryPath: root.path)
        try EvidenceStore(root: root).saveProjects([project])
        let app = LensAppModel(root: root, watchBridge: false, revealWindows: false)
        _ = app.newObservation(projectID: project.id)
        app.investigate(useCloud: false)
        app.edit(markdown: "Keep this manually written observation.")
        try await eventually { !app.investigating }
        XCTAssertEqual(app.current?.markdown, "Keep this manually written observation.")
        XCTAssertNotNil(app.suggestedDraft)
        XCTAssertEqual(app.suggestedDraftObservationID, app.current?.id)
    }

    func testVideoIdentitySeparatesChromeProfilesWithTheSameTabNumber() {
        var a = TabStatus(tabId: 7, projectId: "project", url: "https://fixture.test", documentId: "same")
        var b = a; a.clientId = "profile-a"; b.clientId = "profile-b"
        XCTAssertNotEqual(RollingVideo.identityKey(a), RollingVideo.identityKey(b))
    }

    @MainActor private func eventually(_ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), "Expected state was not reached before the deadline")
    }
}
