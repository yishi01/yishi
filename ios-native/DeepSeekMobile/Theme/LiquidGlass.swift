import SwiftUI
import UIKit

// MARK: - Appearance & Interaction Customization Store

enum AccentThemeOption: String, CaseIterable, Identifiable {
    case blue = "blue"
    case indigo = "indigo"
    case teal = "teal"
    case violet = "violet"
    case emerald = "emerald"
    case rose = "rose"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue: return "晴空蓝"
        case .indigo: return "深海靛"
        case .teal: return "冰川青"
        case .violet: return "星云紫"
        case .emerald: return "翡翠绿"
        case .rose: return "绯樱粉"
        }
    }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.24, green: 0.42, blue: 0.98)
        case .indigo: return Color(red: 0.34, green: 0.32, blue: 0.94)
        case .teal: return Color(red: 0.06, green: 0.62, blue: 0.78)
        case .violet: return Color(red: 0.56, green: 0.30, blue: 0.96)
        case .emerald: return Color(red: 0.12, green: 0.68, blue: 0.48)
        case .rose: return Color(red: 0.90, green: 0.28, blue: 0.46)
        }
    }
}

@MainActor
final class ThemePreferences: ObservableObject {
    static let shared = ThemePreferences()

    @AppStorage("ds_theme_accent") var accentId: String = "blue" {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ds_theme_glass_intensity") var glassIntensity: Double = 0.85 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ds_theme_font_scale") var fontScale: Double = 1.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ds_theme_bubble_radius") var bubbleRadius: Double = 20.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ds_theme_compact_mode") var compactMode: Bool = false {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ds_theme_auto_hide_composer") var autoHideComposer: Bool = true {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ds_theme_auto_hide_delay") var autoHideDelaySec: Double = 4.0 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ds_theme_dynamic_island") var enableDynamicIsland: Bool = true {
        didSet { objectWillChange.send() }
    }
    @AppStorage("ds_theme_haptics") var enableHaptics: Bool = true {
        didSet { objectWillChange.send() }
    }

    var accentOption: AccentThemeOption {
        AccentThemeOption(rawValue: accentId) ?? .blue
    }

    var accentColor: Color {
        accentOption.color
    }

    func scaledFont(_ base: CGFloat) -> CGFloat {
        max(10.0, min(28.0, base * CGFloat(fontScale)))
    }

    func resetDefaults() {
        accentId = "blue"
        glassIntensity = 0.85
        fontScale = 1.0
        bubbleRadius = 20.0
        compactMode = false
        autoHideComposer = true
        autoHideDelaySec = 4.0
        enableDynamicIsland = true
        enableHaptics = true
    }

    private init() {}
}

enum Haptics {
    private static var enabled: Bool {
        if let v = UserDefaults.standard.object(forKey: "ds_theme_haptics") as? Bool {
            return v
        }
        return true
    }

    static func light() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

// MARK: - Ambient Light Backdrop (Reactive to Theme Accent & Glass Intensity)

struct LiquidGlassBackdropView: View {
    @ObservedObject private var theme = ThemePreferences.shared

    var body: some View {
        let accent = theme.accentColor
        let orbScale = max(0.35, min(1.3, theme.glassIntensity))

        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.962, green: 0.975, blue: 0.996),
                        Color(red: 0.988, green: 0.991, blue: 0.999),
                        Color(red: 0.950, green: 0.966, blue: 0.994),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                accent.opacity(0.24 * orbScale),
                                accent.opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 215
                        )
                    )
                    .frame(width: 380, height: 380)
                    .position(x: geo.size.width * 0.14, y: geo.size.height * 0.12)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.78, green: 0.74, blue: 1.0).opacity(0.36 * orbScale),
                                Color(red: 0.78, green: 0.74, blue: 1.0).opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 195
                        )
                    )
                    .frame(width: 350, height: 350)
                    .position(x: geo.size.width * 0.88, y: geo.size.height * 0.45)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                accent.opacity(0.18 * orbScale),
                                accent.opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 205
                        )
                    )
                    .frame(width: 360, height: 360)
                    .position(x: geo.size.width * 0.24, y: geo.size.height * 0.88)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Optical Liquid Glass Surface Modifier

struct LiquidGlassCapsuleModifier: ViewModifier {
    var cornerRadius: CGFloat = 24
    var tintOpacity: Double = 0.54
    var prominent: Bool = false
    @ObservedObject private var theme = ThemePreferences.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let alphaAdjust = max(0.32, min(0.88, tintOpacity * (1.28 - 0.34 * theme.glassIntensity)))
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(Color.white.opacity(prominent ? 0.32 : 0.44)),
                    in: shape
                )
                .shadow(
                    color: Color(red: 0.15, green: 0.28, blue: 0.58).opacity(prominent ? 0.10 : 0.06),
                    radius: prominent ? 18 : 12,
                    x: 0,
                    y: prominent ? 7 : 4
                )
        } else {
            fallbackGlassBody(content: content, shape: shape, effOpacity: alphaAdjust)
        }
        #else
        fallbackGlassBody(content: content, shape: shape, effOpacity: alphaAdjust)
        #endif
    }

    private func fallbackGlassBody(content: Content, shape: RoundedRectangle, effOpacity: Double) -> some View {
        content
            .background(
                ZStack {
                    shape.fill(prominent ? .thinMaterial : .ultraThinMaterial)

                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(min(0.95, effOpacity + 0.14)),
                                Color.white.opacity(max(0.18, effOpacity - 0.12)),
                                Color(red: 0.94, green: 0.97, blue: 1.0).opacity(effOpacity),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.78), location: 0.0),
                                .init(color: Color.white.opacity(0.18), location: 0.28),
                                .init(color: Color.clear, location: 0.55),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .allowsHitTesting(false)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.98), location: 0.0),
                            .init(color: Color(red: 0.76, green: 0.85, blue: 1.0).opacity(0.55), location: 0.45),
                            .init(color: Color.white.opacity(0.45), location: 0.72),
                            .init(color: Color.white.opacity(0.92), location: 1.0),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: prominent ? 1.35 : 1.15
                )
                .allowsHitTesting(false)
            )
            .shadow(
                color: Color(red: 0.15, green: 0.28, blue: 0.58).opacity(prominent ? 0.11 : 0.075),
                radius: prominent ? 20 : 14,
                x: 0,
                y: prominent ? 8 : 5
            )
            .shadow(
                color: Color.black.opacity(0.03),
                radius: 2.5,
                x: 0,
                y: 1
            )
    }
}

// MARK: - Button Styles

struct LiquidGlassPressButtonStyle: ButtonStyle {
    var scaleAmount: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scaleAmount : 1.0)
            .brightness(configuration.isPressed ? 0.03 : 0.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

/// Immediate single-tap row style for ScrollView/List items (zero scale animation lag or gesture theft).
struct SingleTapRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1.0)
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 24, prominent: Bool = true) -> some View {
        modifier(LiquidGlassCapsuleModifier(cornerRadius: cornerRadius, tintOpacity: 0.52, prominent: prominent))
    }

    func cleanWhiteCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(LiquidGlassCapsuleModifier(cornerRadius: cornerRadius, tintOpacity: 0.60, prominent: false))
    }

    func glassPressable(scale: CGFloat = 0.96) -> some View {
        buttonStyle(LiquidGlassPressButtonStyle(scaleAmount: scale))
    }
}

extension Color {
    static var dsAccent: Color {
        let raw = UserDefaults.standard.string(forKey: "ds_theme_accent") ?? "blue"
        return (AccentThemeOption(rawValue: raw) ?? .blue).color
    }
    static let dsSurface = Color.white.opacity(0.46)
    static let dsSurface2 = Color.white.opacity(0.62)
    static let dsBorder = Color.white.opacity(0.75)
    static let dsPrimary = Color(red: 0.07, green: 0.09, blue: 0.14)
}
