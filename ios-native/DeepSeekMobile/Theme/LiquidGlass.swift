import SwiftUI
import UIKit

// MARK: - iOS Liquid Glass Design System (White Minimalist + Specular Rim + Haptics)

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

struct LiquidGlassCapsuleModifier: ViewModifier {
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.75))
            )
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                Color(white: 0.88).opacity(0.55),
                                Color.white.opacity(0.85),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.06), radius: 16, x: 0, y: 6)
            .shadow(color: Color.black.opacity(0.03), radius: 3, x: 0, y: 1)
    }
}

struct CleanWhiteCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(red: 0.91, green: 0.91, blue: 0.93), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.035), radius: 8, x: 0, y: 2)
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 24) -> some View {
        modifier(LiquidGlassCapsuleModifier(cornerRadius: cornerRadius))
    }

    func cleanWhiteCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(CleanWhiteCardModifier(cornerRadius: cornerRadius))
    }
}

extension Color {
    static let dsAccent = Color(red: 0.30, green: 0.42, blue: 1.0)
    static let dsSurface = Color(red: 0.968, green: 0.968, blue: 0.973)
    static let dsSurface2 = Color(red: 0.94, green: 0.94, blue: 0.95)
    static let dsBorder = Color(red: 0.91, green: 0.91, blue: 0.93)
    static let dsPrimary = Color(red: 0.067, green: 0.067, blue: 0.078)
}
