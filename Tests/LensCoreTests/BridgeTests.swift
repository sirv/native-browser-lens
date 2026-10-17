import XCTest
@testable import LensCore

final class BridgeTests: XCTestCase {
    func testCoalescedStatusRetainsSelectionChangeAfterSwitchingAwayAndBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeMailbox(root: root), client = UUID().uuidString
        func status(_ selected: Bool) throws {
            try bridge.receive(WireMessage(kind: "status", payload: .object(["tabs": .array([.object(["tabId": .number(1), "documentId": .string("doc"), "selected": .bool(selected), "mode": .string("deep")])])])), clientId: client)
        }
        try status(true)
        let initial = try XCTUnwrap(bridge.drain().first?.payload["selectionEpoch"]?.stringValue)
        try status(true)
        XCTAssertEqual(try bridge.drain().first?.payload["selectionEpoch"]?.stringValue, initial)
        try status(false); try status(true)
        let coalesced = try bridge.drain()
        XCTAssertEqual(coalesced.count, 1)
        XCTAssertEqual(coalesced[0].payload["tabs"]?.arrayValue?.first?["selected"]?.boolValue, true)
        XCTAssertNotEqual(coalesced[0].payload["selectionEpoch"]?.stringValue, initial)
    }
    func testNewStatusCanBeClaimedWhileEarlierStatusRemainsUnacknowledged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeMailbox(root: root); let client = UUID().uuidString
        let old = WireMessage(kind: "status", payload: .object(["sequence": .number(1)]))
        try bridge.receive(old, clientId: client)
        XCTAssertEqual(try bridge.pending().map(\.id), [old.id])

        let start = WireMessage(kind: "capture-started")
        let part = WireMessage(kind: "artifact")
        let capture = WireMessage(kind: "capture")
        for message in [start, part, capture] { try bridge.receive(message, clientId: client) }
        let newest = WireMessage(kind: "status", payload: .object(["sequence": .number(2)]))
        try bridge.receive(newest, clientId: client)

        let next = try bridge.pending(excluding: [old.id])
        XCTAssertEqual(next.map(\.id), [start.id, part.id, capture.id, newest.id])
        let reopened = BridgeMailbox(root: root)
        let replayed = try reopened.pending()
        XCTAssertEqual(replayed.filter { $0.kind != "status" }.map(\.id), [start.id, part.id, capture.id])
        XCTAssertEqual(replayed.filter { $0.kind == "status" }.map(\.id), [old.id, newest.id], "Replaying status must finish with the latest version")
        try reopened.acknowledge([old.id])
        XCTAssertEqual(try reopened.pending().filter { $0.kind == "status" }.map(\.id), [newest.id], "Acknowledging the older claim must preserve the replacement")
        try reopened.acknowledge(Set(next.map(\.id)))
        XCTAssertTrue(try BridgeMailbox(root: root).pending().isEmpty)
    }

    func testUnacknowledgedCaptureReplaysAfterRestartInOriginalOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = BridgeMailbox(root: root)
        let start = WireMessage(kind: "capture-started"); let part = WireMessage(kind: "artifact"); let capture = WireMessage(kind: "capture")
        for message in [start, part, capture] { try writer.receive(message) }
        let first = try writer.pending()
        XCTAssertEqual(first.map(\.id), [start.id, part.id, capture.id])
        let reopened = BridgeMailbox(root: root)
        XCTAssertEqual(try reopened.pending().map(\.id), first.map(\.id))
        XCTAssertEqual(try reopened.pending(excluding: [start.id, part.id]).map(\.id), [capture.id])
        try reopened.acknowledge(Set(first.map(\.id)))
        XCTAssertTrue(try BridgeMailbox(root: root).pending().isEmpty)
    }
    func testClosedNotebookCoalescesStatusWithoutDroppingCapturedEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeMailbox(root: root); let client = UUID().uuidString
        for index in 0..<100 { try bridge.receive(WireMessage(kind: "status", payload: .object(["sequence": .number(Double(index))])), clientId: client) }
        try bridge.receive(WireMessage(kind: "capture", id: "frozen", payload: .object([:])), clientId: client)
        let messages = try bridge.drain()
        XCTAssertEqual(messages.filter { $0.kind == "status" }.count, 1)
        XCTAssertEqual(messages.first { $0.kind == "status" }?.payload["sequence"]?.intValue, 99)
        XCTAssertEqual(messages.filter { $0.kind == "capture" }.map(\.id), ["frozen"])
    }
    func testQueuedMessageWakesNativeConsumerAndKeepsBrowserProfilesSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeMailbox(root: root)
        let clientA = UUID().uuidString; let clientB = UUID().uuidString
        try bridge.register(clientId: clientA); try bridge.register(clientId: clientB)
        XCTAssertEqual(Set(try bridge.connectedClientIDs()), Set([clientA, clientB]))
        _ = try bridge.commands(clientId: clientA); _ = try bridge.commands(clientId: clientB)
        let arrival = expectation(description: "Filesystem event delivers the message")
        let watch = try bridge.watchInbox(queue: DispatchQueue(label: "test.bridge")) {
            if let messages = try? bridge.drain(), messages.contains(where: { $0.id == "capture-message" && $0.payload["clientId"]?.stringValue == clientB }) { arrival.fulfill() }
        }
        defer { watch.cancel() }
        try bridge.receive(WireMessage(kind: "capture", id: "capture-message"), clientId: clientB)
        wait(for: [arrival], timeout: 2)
        XCTAssertThrowsError(try bridge.send(kind: "capture", payload: .object(["tabId": .number(1)])))
        try bridge.send(kind: "capture", payload: .object(["tabId": .number(1), "clientId": .string(clientB)]))
        XCTAssertTrue(try bridge.commands(clientId: clientA).isEmpty)
        XCTAssertEqual(try bridge.commands(clientId: clientB).map(\.kind), ["capture"])
        bridge.unregister(clientId: clientA)
        let stale = root.appendingPathComponent("bridge/clients/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try "2147483647".write(to: stale.appendingPathComponent(".owner-pid"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try bridge.connectedClientIDs(), [clientB])
    }
}
