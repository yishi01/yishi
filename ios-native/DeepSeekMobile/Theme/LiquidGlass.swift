import SwiftUI
import UIKit

// MARK: - iOS Liquid Glass Design System
// - Adopts Apple's native iOS 26+ `.glassEffect(.regular.tint(...), in:)` optical refraction when available.
// - Falls back cleanly on iOS 16-25 to a 4-layer optical glass simulation (.ultraThinMaterial + caustic highlight + dual specular rim).
// - All decorative backdrop and highlight layers disable hit-testing so buttons and inputs inside glass cards never block taps.

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
                LinearGradient(
                    colors: [
                        Color(red: 0.962, green: 0.975, blue: 0.996),
                        Color(red: 0.988, green: 0.991, blue: 0.999),
                        Color(red: 0.950, green: 0.966, blue: 0.994),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Top-left icy sapphire refraction bloom
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.62, green: 0.78, blue: 1.0).opacity(0.46),
                                Color(red: 0.62, green: 0.78, blue: 1.0).opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 210
                        )
                    )
                    .frame(width: 380, height: 380)
                    .position(x: geo.size.width * 0.14, y: geo.size.height * 0.12)

                // Center-right soft periwinkle/lavender refraction bloom
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.78, green: 0.74, blue: 1.0).opacity(0.36),
                                Color(red: 0.78, green: 0.74, blue: 1.0).opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 195
                        )
                    )
                    .frame(width: 350, height: 350)
                    .position(x: geo.size.width * 0.88, y: geo.size.height * 0.45)

                // Bottom-left cool aqua refraction bloom
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.66, green: 0.87, blue: 0.99).opacity(0.42),
                                Color(red: 0.66, green: 0.87, blue: 0.99).opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 200
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

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
            fallbackGlassBody(content: content, shape: shape)
        }
        #else
        fallbackGlassBody(content: content, shape: shape)
        #endif
    }

    private func fallbackGlassBody(content: Content, shape: RoundedRectangle) -> some View {
        content
            .background(
                ZStack {
                    shape.fill(prominent ? .thinMaterial : .ultraThinMaterial)

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
    static let dsAccent = Color(red: 0.26, green: 0.40, blue: 0.98)
    static let dsSurface = Color.white.opacity(0.46)
    static let dsSurface2 = Color.white.opacity(0.62)
    static let dsBorder = Color.white.opacity(0.75)
    static let dsPrimary = Color(red: 0.07, green: 0.09, blue: 0.14)
}
