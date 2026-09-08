import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit
import LensCore

enum NativeCaptureError: LocalizedError {
    case windowUnavailable, noFrames, invalidImage, recording(String)
    var errorDescription: String? {
        switch self {
        case .windowUnavailable: return "Could not uniquely match the captured tab to an on-screen Chrome window. Keep that tab visible, or use a browser viewport capture."
        case .noFrames: return "No video frames are available for this tab yet."
        case .invalidImage: return "The captured image could not be decoded."
        case .recording(let message): return message
        }
    }
}

struct NativeWindowImage {
    var data: Data
    var width: Int
    var height: Int
    var windowID: UInt32
}

/// The Chrome window ID and CGWindowID belong to different namespaces. Match only a
/// unique visible Chrome window title, never an arbitrary window or desktop.
enum NativeScreenshot {
    static func matchingWindow(title: String) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.google.Chrome" &&
            ($0.title == title || $0.title == "\(title) - Google Chrome") &&
            $0.frame.width > 100 && $0.frame.height > 100
        }
        guard windows.count == 1, let window = windows.first else { throw NativeCaptureError.windowUnavailable }
        return window
    }

    static func capture(title: String) async throws -> NativeWindowImage {
        let window = try await matchingWindow(title: title)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NativeCaptureError.invalidImage }
        return NativeWindowImage(data: data, width: image.width, height: image.height, windowID: window.windowID)
    }
}

/// Compressed frames are retained in a bounded local-only ring. They are never
/// included in AI requests. Changing tab or project clears the entire ring.
final class RollingVideo: NSObject, SCStreamOutput, SCStreamDelegate {
    private struct Frame { let timestamp: Double; let jpeg: Data }
    private let queue = DispatchQueue(label: "studio.sirv.lens.video", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var bytes = 0
    private var stream: SCStream?
    private(set) var tabKey: String?
    private var expectedWindowID: UInt32 = 0
    private var expectedTitle = ""
    var onFailure: ((String) -> Void)?

    static func identityKey(_ tab: TabStatus) -> String { "\(tab.clientId ?? "default"):\(tab.projectId):\(tab.windowId):\(tab.tabId):\(tab.documentId)" }

    @MainActor func start(tab: TabStatus) async throws {
        let key = Self.identityKey(tab)
        guard tabKey != key else { return }
        await stop()
        let window = try await NativeScreenshot.matchingWindow(title: tab.title)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let ratio = min(1, 1440 / window.frame.width)
        config.width = max(2, Int(window.frame.width * ratio) / 2 * 2)
        config.height = max(2, Int(window.frame.height * ratio) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = false
        config.showsCursor = true
        config.ignoreShadowsSingleWindow = true
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        setExpectedWindow(id: window.windowID, title: tab.title)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await capture.startCapture()
        stream = capture
        tabKey = key
    }

    @MainActor func stop() async {
        let old = stream
        stream = nil
        tabKey = nil
        setExpectedWindow(id: 0, title: "")
        try? await old?.stopCapture()
        clearFrames()
    }

    private func clearFrames() { lock.lock(); frames.removeAll(); bytes = 0; lock.unlock() }
    private func setExpectedWindow(id: UInt32, title: String) { lock.lock(); expectedWindowID = id; expectedTitle = title; lock.unlock() }
    private func expectedWindow() -> (UInt32, String) { lock.lock(); defer { lock.unlock() }; return (expectedWindowID, expectedTitle) }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        clearFrames()
        DispatchQueue.main.async { self.tabKey = nil; self.onFailure?(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Check window identity on every native frame. A Chrome tab switch can
        // precede its extension status event; discard the ring at that boundary.
        let (windowID, title) = expectedWindow()
        guard windowID != 0,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let current = windows.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID })?[kCGWindowName as String] as? String,
              current == title || current == "\(title) - Google Chrome" else {
            clearFrames(); return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixel = sampleBuffer.imageBuffer,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(of: CIImage(cvPixelBuffer: pixel), colorSpace: colorSpace,
                  options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.55]) else { return }
        let now = Date().timeIntervalSince1970
        lock.lock()
        frames.append(Frame(timestamp: now, jpeg: data)); bytes += data.count
        while let first = frames.first, now - first.timestamp > 30 || bytes > 48 * 1024 * 1024 || frames.count > 150 {
            bytes -= frames.removeFirst().jpeg.count
        }
        lock.unlock()
    }

    func save(to url: URL, expectedKey: String) async throws -> Double {
        guard tabKey == expectedKey else { throw NativeCaptureError.noFrames }
        let snapshot: [Frame] = copyFrames()
        guard let first = snapshot.first, let image = NSImage(data: first.jpeg),
              let initial = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw NativeCaptureError.noFrames }
        return try await Task.detached(priority: .utility) {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: initial.width, AVVideoHeightKey: initial.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000]
            ])
            input.expectsMediaDataInRealTime = false
            let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: initial.width,
                kCVPixelBufferHeightKey as String: initial.height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ])
            guard writer.canAdd(input) else { throw NativeCaptureError.recording("Video encoder cannot accept these frames.") }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? NativeCaptureError.invalidImage }
            writer.startSession(atSourceTime: .zero)
            for frame in snapshot {
                try Task.checkCancellation()
                let deadline = Date().addingTimeInterval(10)
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing, Date() < deadline else { throw writer.error ?? NativeCaptureError.recording("Video encoder timed out.") }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let pool = adapter.pixelBufferPool else { throw NativeCaptureError.invalidImage }
                var pixel: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw NativeCaptureError.invalidImage }
                CVPixelBufferLockBaseAddress(pixel, [])
                let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: initial.width, height: initial.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
                ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: initial.width, height: initial.height))
                CVPixelBufferUnlockBaseAddress(pixel, [])
                guard adapter.append(pixel, withPresentationTime: CMTime(seconds: frame.timestamp - first.timestamp, preferredTimescale: 600)) else { throw writer.error ?? NativeCaptureError.invalidImage }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? NativeCaptureError.invalidImage }
            return (snapshot.last?.timestamp ?? first.timestamp) - first.timestamp
        }.value
    }

    private func copyFrames() -> [Frame] { lock.lock(); defer { lock.unlock() }; return frames }
}

enum ScreenshotDerivative {
    static func render(original: URL, annotations: [Annotation]) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NativeCaptureError.invalidImage }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // UI annotations have a top-left origin; bitmap drawing has a bottom-left origin.
        context.translateBy(x: 0, y: CGFloat(image.height)); context.scaleBy(x: 1, y: -1)
        for annotation in annotations {
            guard let first = annotation.points.first, let last = annotation.points.last else { continue }
            let a = CGPoint(x: first.x * Double(image.width), y: first.y * Double(image.height))
            let b = CGPoint(x: last.x * Double(image.width), y: last.y * Double(image.height))
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            context.setStrokeColor(LensTheme.oklch(0.67, 0.145, 286.8).cgColor)
            context.setLineWidth(max(3, Double(image.width) / 450))
            context.setLineCap(.round); context.setLineJoin(.round)
            switch annotation.kind {
            case "mask": context.setFillColor(NSColor.black.cgColor); context.fill(rect.integral)
            case "rectangle": context.stroke(rect)
            default:
                context.beginPath(); context.move(to: a)
                for point in annotation.points.dropFirst() { context.addLine(to: CGPoint(x: point.x * Double(image.width), y: point.y * Double(image.height))) }
                context.strokePath()
                if annotation.kind == "arrow" {
                    let angle = atan2(b.y - a.y, b.x - a.x), size = max(12, Double(image.width) / 65)
                    context.beginPath(); context.move(to: CGPoint(x: b.x - size * cos(angle - .pi / 6), y: b.y - size * sin(angle - .pi / 6)))
                    context.addLine(to: b)
                    context.addLine(to: CGPoint(x: b.x - size * cos(angle + .pi / 6), y: b.y - size * sin(angle + .pi / 6)))
                    context.strokePath()
                }
            }
        }
        guard let rendered = context.makeImage(), let data = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else { throw NativeCaptureError.invalidImage }
        return data
    }
}
