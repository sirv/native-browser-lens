import XCTest
@testable import LensCore

final class FilingHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class FilingTests: XCTestCase {
    func testTimeoutAfterCommitRecoversSameTicketAfterStoreReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FilingHTTP.self]
        let client = VibeQClient(baseURL: URL(string: "https://tracker.test")!, token: "fixture", session: URLSession(configuration: config))
        let observation = NotebookObservation(projectId: "p", title: "Broken image", markdown: "Expected immediate update")
        var receipt: FilingReceipt?; var tickets = 0
        FilingHTTP.handler = { request in
            if request.url!.path == "/auth/me" { return (200, Data("{\"id\":\"fixture-member\"}".utf8)) }
            if request.httpMethod == "GET" { return (receipt == nil ? 404 : 200, try receipt.map { try JSONEncoder().encode($0) } ?? Data()) }
            if request.url!.path.hasSuffix("/stage") { return (200, Data("{\"stagedKey\":\"staged/member/fixture\"}".utf8)) }
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) } }
            let body = try JSONDecoder().decode(JSONValue.self, from: bytes)
            tickets += 1
            receipt = FilingReceipt(submissionId: body["submissionId"]!.stringValue!, observationId: observation.id.lowercased(), revision: 1, taskId: "only-ticket", taskUrl: "https://tracker.test/?task=only-ticket")
            throw URLError(.timedOut)
        }
        do { _ = try await client.file(observation: observation, project: ProjectProfile(id: "p"), store: EvidenceStore(root: root), assigneeId: nil) } catch {}
        let recovered = try await client.file(observation: observation, project: ProjectProfile(id: "p"), store: EvidenceStore(root: root), assigneeId: nil)
        XCTAssertEqual(tickets, 1)
        XCTAssertEqual(recovered.taskId, "only-ticket")
        XCTAssertEqual(recovered.submissionId, receipt?.submissionId)
    }
}
