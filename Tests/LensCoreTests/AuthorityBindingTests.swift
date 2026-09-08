import XCTest
@testable import LensCore

final class AuthorityBindingTests: XCTestCase {
    func testChangedMemberAfterCommittedTimeoutCannotCreateAnotherTask() async throws {
        let fixture = AuthorityFixture()
        defer { fixture.close() }
        try await fixture.commitWithLostResponse()

        do {
            _ = try await fixture.file(token: "member-b-token")
            XCTFail("A saved submission must remain bound to its original authenticated member")
        } catch {
            // The precise error wording is UI policy; the observable contract is
            // that another member cannot stage or create against this attempt.
        }

        XCTAssertEqual(fixture.taskCount, 1, "Actor-scoped server deduplication cannot prevent this client-side duplicate")
        XCTAssertEqual(fixture.memberBWriteCount, 0, "Reject an authority change before sending reviewed evidence")

        let recovered = try await fixture.file(token: "member-a-original-token")
        XCTAssertEqual(recovered.taskId, "task-member-a")
        XCTAssertEqual(fixture.taskCount, 1)
    }

    func testRotatedTokenForSameMemberRecoversCommittedReceiptAfterStoreReopen() async throws {
        let fixture = AuthorityFixture()
        defer { fixture.close() }
        try await fixture.commitWithLostResponse()

        let writesBeforeRotation = fixture.writeCount
        let recovered = try await fixture.file(token: "member-a-rotated-token")

        XCTAssertEqual(recovered.taskId, "task-member-a")
        XCTAssertEqual(fixture.taskCount, 1)
        XCTAssertEqual(fixture.writeCount, writesBeforeRotation, "A renewed credential for the same member must reconcile the committed task without reposting")
    }
}

/// Mirrors VibeQ's actual cookie-authenticated /auth/me contract and its
/// actor-scoped capture receipt lookup. Tokens are deliberately opaque: the
/// native client must use the server-verified member, not decode JWT claims.
private final class AuthorityFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let observation = NotebookObservation(projectId: "project", title: "Stale image", markdown: "The image should update after saving.")
    private let session: URLSession
    private var receipts: [String: FilingReceipt] = [:]
    private(set) var taskCount = 0
    private(set) var writeCount = 0
    private(set) var memberBWriteCount = 0

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FilingHTTP.self]
        session = URLSession(configuration: config)
        FilingHTTP.handler = { [self] request in try respond(to: request) }
    }

    func close() {
        session.invalidateAndCancel()
        FilingHTTP.handler = nil
        try? FileManager.default.removeItem(at: root)
    }

    func file(token: String) async throws -> FilingReceipt {
        // Recreate both client and store on every attempt, as after an app restart.
        try await VibeQClient(baseURL: URL(string: "https://tracker.test")!, token: token, session: session)
            .file(observation: observation, project: ProjectProfile(id: "project"), store: EvidenceStore(root: root), assigneeId: nil)
    }

    func commitWithLostResponse() async throws {
        do {
            _ = try await file(token: "member-a-original-token")
            XCTFail("The fixture must lose the first response after committing")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(taskCount, 1, "The initial request must actually reach the commit before testing recovery")
    }

    private func member(for token: String?) -> String? {
        switch token {
        case "member-a-original-token", "member-a-rotated-token": return "member-a"
        case "member-b-token": return "member-b"
        default: return nil
        }
    }

    private func respond(to request: URLRequest) throws -> (Int, Data) {
        let path = request.url!.path
        if path == "/auth/me" {
            let token = request.value(forHTTPHeaderField: "Cookie")?
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("session=") }
                .map { String($0.dropFirst("session=".count)) }
            guard let actor = member(for: token) else { return (401, Data()) }
            return (200, try JSONEncoder().encode(VibeQMember(id: actor, name: actor)))
        }
        let bearer = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        guard let actor = member(for: bearer) else { return (401, Data()) }
        if request.httpMethod == "GET", path.hasPrefix("/api/capture/v1/submissions/") {
            guard let receipt = receipts[actor], path.hasSuffix(receipt.submissionId) else { return (404, Data()) }
            return (200, try JSONEncoder().encode(receipt))
        }
        guard request.httpMethod == "POST" else { return (404, Data()) }
        writeCount += 1
        if actor == "member-b" { memberBWriteCount += 1 }
        if path == "/api/attachments/stage" {
            return (200, Data("{\"stagedKey\":\"staged/\(actor)/fixture\"}".utf8))
        }
        guard path == "/api/capture/v1/submissions" else { return (404, Data()) }
        let body = try JSONDecoder().decode(JSONValue.self, from: bodyData(request))
        let submissionID = try XCTUnwrap(body["submissionId"]?.stringValue)
        if let existing = receipts[actor], existing.submissionId == submissionID {
            return (200, try JSONEncoder().encode(existing))
        }
        taskCount += 1
        let receipt = FilingReceipt(submissionId: submissionID, observationId: observation.id.lowercased(), revision: 1,
            taskId: "task-" + actor, taskUrl: "https://tracker.test/?task=task-" + actor)
        receipts[actor] = receipt
        if taskCount == 1 { throw URLError(.timedOut) }
        return (201, try JSONEncoder().encode(receipt))
    }

    private func bodyData(_ request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open(); defer { stream.close() }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes
    }
}
