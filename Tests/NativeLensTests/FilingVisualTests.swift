import XCTest
import SwiftUI
import AppKit
import LensCore
@testable import NativeLens

final class FilingVisualTests: XCTestCase {
    @MainActor func testRenderFilingStateFixturesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["LENS_UI_ARTIFACTS"] else { throw XCTSkip("Set LENS_UI_ARTIFACTS to render native visual fixtures.") }
        let url = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let stages = ["prepare", "reconcile", "attachments", "submit", "receipt"]
        var active: [String: FilingProgress] = [:]
        active["prepare"] = FilingProgress(stage: "prepare", state: "completed", detail: "Revision 2 saved")
        active["reconcile"] = FilingProgress(stage: "reconcile", state: "completed", detail: "No earlier submission found")
        active["attachments"] = FilingProgress(stage: "attachments", state: "active", completed: 2, total: 5, detail: "reviewed-capture.png")
        var failed = active
        failed["attachments"] = FilingProgress(stage: "attachments", state: "failed", completed: 2, total: 5, detail: "Connection interrupted. The reviewed revision and submission identity are saved.")
        let done = Dictionary(uniqueKeysWithValues: stages.map { ($0, FilingProgress(stage: $0, state: "completed", detail: $0 == "receipt" ? "Task and attachments confirmed" : "Confirmed")) })
        for skin in [ColorScheme.dark, .light] {
            let view = VStack(alignment: .leading, spacing: 24) {
                Eyebrow("Native Lens / Visual fixtures / No live uploads")
                Text("A clear path from report to receipt.").font(LensTheme.hero).foregroundStyle(LensTheme.ink)
                HStack(alignment: .top, spacing: 22) {
                    fixture("Uploading evidence", progress: active, retry: false)
                    fixture("Recoverable failure", progress: failed, retry: true)
                    fixture("Receipt confirmed", progress: done, retry: false)
                }
            }.padding(32).frame(width: 1480).background(LensTheme.background).environment(\.colorScheme, skin).transaction { $0.animation = nil }
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: url.appendingPathComponent(skin == .dark ? "filing-states-dark.png" : "filing-states-light.png"))
            XCTAssertGreaterThan(image.width, 2000)
        }
    }
    @MainActor private func fixture(_ title: String, progress: [String: FilingProgress], retry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Eyebrow(title)
            FilingProgressView(progress: progress, retry: {}, retryEnabled: retry)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
