import SwiftUI
import AppKit
import LensCore

enum AnnotationGeometry {
    static func fittedRect(image: CGSize, bounds: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    static func point(_ point: CGPoint, in rect: CGRect) -> NormalizedPoint? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return NormalizedPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }
    static func clampedPoint(_ point: CGPoint, in rect: CGRect) -> NormalizedPoint {
        NormalizedPoint(x: (point.x - rect.minX) / max(1, rect.width), y: (point.y - rect.minY) / max(1, rect.height))
    }
}

struct AnnotationCanvas: View {
    let capture: CaptureRecord
    let tool: String
    let add: (Annotation) -> Void
    @State private var drawing: [NormalizedPoint] = []
    @State private var image: NSImage?
    @State private var imagePath = ""

    var body: some View {
        GeometryReader { proxy in
            let rect = AnnotationGeometry.fittedRect(image: image?.size ?? .zero, bounds: proxy.size)
            ZStack(alignment: .topLeading) {
                LensTheme.background
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                        .accessibilityLabel("Captured page: \(capture.identity.title)")
                    // Saved annotations have already been burned into this derivative.
                    // Only the current stroke is drawn as an interactive overlay.
                    if !drawing.isEmpty { annotationPath(points: drawing, rect: rect) }
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                            if drawing.isEmpty {
                                guard let first = AnnotationGeometry.point(value.startLocation, in: rect) else { return }
                                drawing = [first]
                            }
                            let point = AnnotationGeometry.clampedPoint(value.location, in: rect)
                            if tool == "pen" { if drawing.count < 4_096 { drawing.append(point) } }
                            else { drawing = [drawing[0], point] }
                        }.onEnded { _ in
                            if drawing.count > 1 { add(Annotation(kind: tool, points: drawing, color: "ac-accent")) }
                            drawing = []
                        })
                        .accessibilityLabel("Screenshot annotation canvas")
                        .help("Drag on the frozen image to add a \(tool). Annotations use image coordinates.")
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark").font(.system(size: 28, weight: .light)).foregroundStyle(LensTheme.faint)
                        Text("Screenshot unavailable").font(LensTheme.head)
                        Text(capture.gaps.first { $0.channel == "screenshot" }?.reason ?? "This capture contains diagnostics only.")
                            .font(LensTheme.detail).foregroundStyle(LensTheme.soft).multilineTextAlignment(.center).frame(maxWidth: 320)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipped()
        }
        .onAppear { loadImage() }
        .onChange(of: capture.screenshotPath) { _, _ in loadImage() }
        .onChange(of: capture.id) { _, _ in drawing = []; loadImage() }
    }
    private func loadImage() {
        let path = capture.screenshotPath ?? ""
        guard path != imagePath else { return }; imagePath = path
        image = path.isEmpty ? nil : NSImage(contentsOfFile: path)
    }
    @ViewBuilder private func annotationPath(points: [NormalizedPoint], rect: CGRect) -> some View {
        let mapped = points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        if let first = mapped.first, let last = mapped.last {
            let bounds = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            if tool == "mask" {
                Rectangle().fill(.black).frame(width: bounds.width, height: bounds.height).position(x: bounds.midX, y: bounds.midY)
            } else {
                Path { path in
                    if tool == "rectangle" { path.addRect(bounds) }
                    else {
                        path.addLines(mapped)
                        if tool == "arrow" {
                            let angle = atan2(last.y - first.y, last.x - first.x), size: CGFloat = 12
                            path.move(to: CGPoint(x: last.x - size * cos(angle - .pi / 6), y: last.y - size * sin(angle - .pi / 6)))
                            path.addLine(to: last)
                            path.addLine(to: CGPoint(x: last.x - size * cos(angle + .pi / 6), y: last.y - size * sin(angle + .pi / 6)))
                        }
                    }
                }.stroke(LensTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct CaptureEmptyCanvas: View {
    let connected: Bool
    let capture: () -> Void
    let settings: () -> Void
    var body: some View {
        ZStack {
            LensTheme.background
            Canvas { context, size in
                let length: CGFloat = 26, inset: CGFloat = 28
                let corners = [CGPoint(x: inset, y: inset), CGPoint(x: size.width - inset, y: inset), CGPoint(x: inset, y: size.height - inset), CGPoint(x: size.width - inset, y: size.height - inset)]
                for (index, point) in corners.enumerated() {
                    let dx: CGFloat = index % 2 == 0 ? 1 : -1, dy: CGFloat = index < 2 ? 1 : -1
                    var path = Path(); path.move(to: CGPoint(x: point.x + dx * length, y: point.y)); path.addLine(to: point); path.addLine(to: CGPoint(x: point.x, y: point.y + dy * length))
                    context.stroke(path, with: .color(LensTheme.lineStrong), style: StrokeStyle(lineWidth: 1))
                }
            }.accessibilityHidden(true)
            VStack(spacing: 22) {
                Image(systemName: "viewfinder").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(LensTheme.accent)
                VStack(spacing: 9) {
                    Text("Keep the moment.").font(LensTheme.hero).tracking(-0.34).foregroundStyle(LensTheme.ink)
                    Text(connected ? "Capture the page. Point to the detail.\nTell the story while the evidence follows." : "Connect a project in Chrome, then capture\nwhat you see without losing what happened.")
                        .font(LensTheme.body).foregroundStyle(LensTheme.soft).multilineTextAlignment(.center).lineSpacing(3)
                }
                Button(action: connected ? capture : settings) { Label(connected ? "Capture page" : "Connect a project", systemImage: connected ? "viewfinder" : "plus") }
                    .buttonStyle(LensButtonStyle(prominent: true))
                Text("⌘ ⌥ ⇧ L").font(.system(size: 11, design: .monospaced)).foregroundStyle(LensTheme.faint)
            }
        }
    }
}
