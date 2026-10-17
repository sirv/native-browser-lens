import XCTest
import AppKit
import LensCore
@testable import NativeLens

final class AnnotationTests: XCTestCase {
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
