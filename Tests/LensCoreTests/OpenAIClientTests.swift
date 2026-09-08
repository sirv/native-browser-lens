import XCTest
@testable import LensCore

final class OpenAIHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let data = try Self.handler(request); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> JSONValue {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) } }
        return try JSONDecoder().decode(JSONValue.self, from: bytes)
    }
}
final class OpenAIClientTests: XCTestCase {
    func testInvestigationFollowsReadOnlyToolAndReturnsItsEvidenceWithoutServerStorage() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OpenAIHTTP.self]
        let client = OpenAIClient(apiKey: "fixture", session: URLSession(configuration: config))
        var requests = 0
        OpenAIHTTP.handler = { request in
            let body = try OpenAIHTTP.body(request); requests += 1
            XCTAssertEqual(body["store"]?.boolValue, false)
            XCTAssertEqual(body["include"]?.arrayValue, [.string("reasoning.encrypted_content")])
            if requests == 1 { return Data("{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\",\"summary\":[]},{\"type\":\"function_call\",\"name\":\"read_project_file\",\"call_id\":\"call-one\",\"arguments\":\"{\\\"path\\\":\\\"src/Button.tsx\\\",\\\"line\\\":1}\"}]}".utf8) }
            let input = body["input"]!.arrayValue!
            XCTAssertTrue(input.contains { $0["type"]?.stringValue == "reasoning" && $0["encrypted_content"]?.stringValue == "opaque" })
            XCTAssertTrue(input.contains { $0["type"]?.stringValue == "function_call_output" && $0["call_id"]?.stringValue == "call-one" && ($0["output"]?.stringValue?.contains("verified source result") ?? false) })
            return Data("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Evidence-linked draft\"}]}]}".utf8)
        }
        let result = try await client.respond(model: "configured-model", instruction: "Investigate", tools: [.object(["type": .string("function"), "name": .string("read_project_file")])], onToolCall: { name, arguments in
            XCTAssertEqual(name, "read_project_file"); XCTAssertEqual(arguments["path"]?.stringValue, "src/Button.tsx")
            return .object(["result": .string("verified source result")])
        })
        XCTAssertEqual(result, "Evidence-linked draft"); XCTAssertEqual(requests, 2)
    }
}
