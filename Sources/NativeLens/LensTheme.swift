import SwiftUI
import AppKit

/// Canonical VibeQ ac-* palette from frontend/src/app.css, converted from OKLCH.
/// Keeping the source values here preserves both skins without ad hoc color ramps.
enum LensTheme {
    static let background = adaptive("background", light: (1, 0, 0), dark: (0.148, 0.004, 228.8))
    static let surface = adaptive("surface", light: (1, 0, 0), dark: (0.218, 0.008, 223.9))
    static let inset = adaptive("surface2", light: (0.963, 0.002, 197.1), dark: (0.275, 0.011, 216.9))
    static let ink = adaptive("ink", light: (0.148, 0.004, 228.8), dark: (0.987, 0.002, 197.1))
    static let soft = adaptive("soft", light: (0.45, 0.017, 213.2), dark: (0.723, 0.014, 214.4))
    static let faint = adaptive("faint", light: (0.56, 0.021, 213.5), dark: (0.62, 0.018, 214.4))
    static let dim = adaptive("dim", light: (0.775, 0.01, 217), dark: (0.378, 0.015, 216))
    static let accent = adaptive("accent", light: (0.51, 0.19, 287), dark: (0.67, 0.145, 286.8))
    static let ok = adaptive("ok", light: (0.52, 0.12, 158), dark: (0.78, 0.15, 160))
    static let warn = adaptive("warn", light: (0.6, 0.12, 70), dark: (0.76, 0.13, 78))
    static let fail = adaptive("fail", light: (0.577, 0.245, 27.325), dark: (0.704, 0.191, 22.216))
    static let line = Color(nsColor: NSColor(name: "lens.line") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white.withAlphaComponent(0.10) : oklch(0.925, 0.005, 214.3)
    })
    static let lineStrong = Color(nsColor: NSColor(name: "lens.lineStrong") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white.withAlphaComponent(0.18) : oklch(0.872, 0.007, 219.6)
    })
    static let radius: CGFloat = 10
    static let hero = font(34, weight: .semibold)
    static let head = font(15, weight: .semibold)
    static let body = font(13.5)
    static let detail = font(12.5)
    static let meta = font(12)
    static let caption = font(11)
    static let eyebrow = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "Inter", size: size) != nil { return .custom("Inter", size: size).weight(weight) }
        return .system(size: size, weight: weight)
    }
    private static func adaptive(_ name: String, light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: "lens." + name) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return oklch(value.0, value.1, value.2)
        })
    }
    static func oklch(_ lightness: Double, _ chroma: Double, _ hue: Double) -> NSColor {
        let angle = hue * .pi / 180, a = chroma * cos(angle), b = chroma * sin(angle)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gamma(_ value: Double) -> Double { min(1, max(0, value <= 0.0031308 ? 12.92 * value : 1.055 * pow(max(0, value), 1 / 2.4) - 0.055)) }
        return NSColor(srgbRed: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s), green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s), blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), alpha: 1)
    }
}

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(LensTheme.eyebrow).tracking(1.365).foregroundStyle(LensTheme.faint) }
}

struct LensButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(LensTheme.meta).fontWeight(.medium)
            .foregroundStyle(prominent ? LensTheme.background : LensTheme.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(prominent ? LensTheme.accent : (configuration.isPressed ? LensTheme.inset : LensTheme.surface), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(prominent ? Color.clear : LensTheme.line))
            .opacity(enabled ? 1 : 0.45)
    }
}

extension View {
    func lensTile() -> some View {
        background(LensTheme.surface, in: RoundedRectangle(cornerRadius: LensTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: LensTheme.radius).strokeBorder(LensTheme.line))
    }
}
