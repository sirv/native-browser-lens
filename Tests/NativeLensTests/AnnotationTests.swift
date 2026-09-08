import XCTest
import AppKit
import LensCore
@testable import NativeLens

final class AnnotationTests: XCTestCase {
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

    func testLetterboxingExcludesMarginsAndNormalizesRetinaIndependently() {
        let rect = AnnotationGeometry.fittedRect(image: CGSize(width: 2400, height: 1200), bounds: CGSize(width: 600, height: 500))
        XCTAssertEqual(rect, CGRect(x: 0, y: 100, width: 600, height: 300))
        XCTAssertNil(AnnotationGeometry.point(CGPoint(x: 100, y: 20), in: rect))
        XCTAssertEqual(AnnotationGeometry.point(CGPoint(x: 300, y: 250), in: rect), NormalizedPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(AnnotationGeometry.clampedPoint(CGPoint(x: 900, y: 0), in: rect), NormalizedPoint(x: 1, y: 0))
    }

    func testMaskBurnsIntoCorrectTopLeftPixelsAndLeavesOriginalUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let originalData = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        let original = directory.appendingPathComponent("original.png"); try originalData.write(to: original)
        let mask = Annotation(kind: "mask", points: [NormalizedPoint(x: 0.1, y: 0.1), NormalizedPoint(x: 0.3, y: 0.3)])
        let derivative = try ScreenshotDerivative.render(original: original, annotations: [mask])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: derivative))
        let masked = try XCTUnwrap(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
        let untouched = try XCTUnwrap(bitmap.colorAt(x: 20, y: 80)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(masked.redComponent, 0.01)
        XCTAssertLessThan(masked.greenComponent, 0.01)
        XCTAssertGreaterThan(untouched.redComponent, 0.99)
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        XCTAssertEqual(try ScreenshotDerivative.render(original: original, annotations: []), originalData)
    }
}
