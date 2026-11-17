import SwiftUI
import UIKit

// MARK: - iOS Liquid Glass Design System
// Implements Apple's Liquid Glass optical material guidelines:
// 1. Multi-layer translucent refraction (.ultraThinMaterial + translucent lens tint)
// 2. Top-edge curved caustic inner highlight + dual-angle refractive specular rim
// 3. Ambient pastel light backdrop so glass layers genuinely refract underlying light & scroll content
// 4. All decorative glass & backdrop layers explicitly disable hit-testing (.allowsHitTesting(false))
//    so interactive controls inside glass containers always respond immediately.

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

// MARK: - Ambient Light Backdrop (White-Dominant with Soft Refractive Light Orbs)

struct LiquidGlassBackdropView: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Base luminous porcelain white canvas
                LinearGradient(
                    colors: [
                        Color(red: 0.965, green: 0.976, blue: 0.996),
                        Color(red: 0.988, green: 0.990, blue: 0.998),
                        Color(red: 0.955, green: 0.968, blue: 0.992),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Top-left icy sapphire refraction bloom
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.68, green: 0.80, blue: 1.0).opacity(0.42),
                                Color(red: 0.68, green: 0.80, blue: 1.0).opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 200
                        )
                    )
                    .frame(width: 360, height: 360)
                    .position(x: geo.size.width * 0.15, y: geo.size.height * 0.12)

                // Center-right soft periwinkle/lavender refraction bloom
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.80, green: 0.76, blue: 1.0).opacity(0.34),
                                Color(red: 0.80, green: 0.76, blue: 1.0).opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 190
                        )
                    )
                    .frame(width: 340, height: 340)
                    .position(x: geo.size.width * 0.88, y: geo.size.height * 0.46)

                // Bottom-left cool aqua refraction bloom (illuminates floating composer & tab bar)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.70, green: 0.88, blue: 0.99).opacity(0.38),
                                Color(red: 0.70, green: 0.88, blue: 0.99).opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 190
                        )
                    )
                    .frame(width: 350, height: 350)
                    .position(x: geo.size.width * 0.25, y: geo.size.height * 0.88)
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
    var tintOpacity: Double = 0.58
    var prominent: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                ZStack {
                    // Layer 1: System real-time backdrop blur material
                    shape.fill(prominent ? .thinMaterial : .ultraThinMaterial)

                    // Layer 2: Translucent optical glass body gradient (not opaque white)
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(tintOpacity + 0.14),
                                Color.white.opacity(tintOpacity - 0.12),
                                Color(red: 0.94, green: 0.97, blue: 1.0).opacity(tintOpacity),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                    // Layer 3: Top-edge curved lens caustic highlight
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
                // Layer 4: Dual-angle specular refractive rim border
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

// MARK: - Interactive Liquid Glass Press Button Style (Moderate Spring Animation)

struct LiquidGlassPressButtonStyle: ButtonStyle {
    var scaleAmount: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scaleAmount : 1.0)
            .brightness(configuration.isPressed ? 0.03 : 0.0)
            .animation(.spring(response: 0.26, dampingFraction: 0.76), value: configuration.isPressed)
    }
}

extension View {
    /// Primary floating Liquid Glass bar / capsule (navigation bar, composer, tab bar, modals)
    func liquidGlass(cornerRadius: CGFloat = 24, prominent: Bool = true) -> some View {
        modifier(LiquidGlassCapsuleModifier(cornerRadius: cornerRadius, tintOpacity: 0.52, prominent: prominent))
    }

    /// Translucent Liquid Glass card / pill (replaces old opaque white card with real glass refraction)
    func cleanWhiteCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(LiquidGlassCapsuleModifier(cornerRadius: cornerRadius, tintOpacity: 0.60, prominent: false))
    }

    /// Applies moderate spring scale & highlight feedback when tapped
    func glassPressable(scale: CGFloat = 0.96) -> some View {
        buttonStyle(LiquidGlassPressButtonStyle(scaleAmount: scale))
    }
}

extension Color {
    static let dsAccent = Color(red: 0.26, green: 0.40, blue: 0.98)
    static let dsSurface = Color.white.opacity(0.46)
    static let dsSurface2 = Color.white.opacity(0.62)
    static let dsBorder = Color.white.opacity(0.75)
    static let dsPrimary = Color(red: 0.07, green: 0.09, blue: 0.14)
}
