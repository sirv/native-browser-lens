import XCTest
@testable import LensCore

final class SpatialAnnotationTests: XCTestCase {
    func testSpatialAnnotationResolvesSmallestStableElementAndRejectsDifferentCapture() {
        let identity = CaptureIdentity(projectId: "project", tabId: 4, documentId: "doc", url: "https://fixture.test")
        func element(_ source: String, _ width: Double, captureID: String = "capture") -> JSONValue {
            .object(["source": .string(source), "binding": .string("stable-across-capture"), "captureId": .string(captureID), "documentId": .string("doc"), "tabId": .number(4), "bounds": .object(["x": .number(100), "y": .number(100), "width": .number(width), "height": .number(width)])])
        }
        var capture = CaptureRecord(id: "capture", identity: identity, context: [
            "coordinateSpace": .string("browser-viewport"), "captureId": .string("capture"), "documentId": .string("doc"),
            "viewport": .object(["width": .number(1000), "height": .number(500)]),
            "elements": .array([element("src/Outer.tsx:1", 300), element("src/Button.tsx:20", 100), element("src/Wrong.tsx:1", 60, captureID: "other")])
        ])
        let annotation = Annotation(kind: "rectangle", points: [NormalizedPoint(x: 0.12, y: 0.24), NormalizedPoint(x: 0.18, y: 0.36)])
        XCTAssertEqual(SpatialAnnotationResolver.references(annotations: [annotation], capture: capture), ["src/Button.tsx:20"])
        capture.context["coordinateSpace"] = .string("native-window")
        XCTAssertEqual(SpatialAnnotationResolver.references(annotations: [annotation], capture: capture), [])
        capture.context["coordinateSpace"] = .string("browser-viewport")
        capture.context["documentId"] = .string("new-document")
        XCTAssertEqual(SpatialAnnotationResolver.references(annotations: [annotation], capture: capture), [])
    }

}
