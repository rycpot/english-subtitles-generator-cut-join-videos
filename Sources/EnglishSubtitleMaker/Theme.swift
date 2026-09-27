import AppKit
import SwiftUI

/// A dark "cinema" palette that matches the app icon: deep navy surfaces,
/// amber for the main action and progress, mint for success, coral for errors.
enum Theme {
    static let background = Color(hex: 0x11131C)
    static let surface = Color(hex: 0x1A1D29)
    static let surfaceRaised = Color(hex: 0x23273A)
    static let logBackground = Color(hex: 0x0C0E15)
    static let border = Color(hex: 0x2C3145)

    static let text = Color(hex: 0xE8EAF2)
    static let textSecondary = Color(hex: 0x8C92A8)
    static let textFaint = Color(hex: 0x5C6279)

    static let accent = Color(hex: 0xF5B82E)
    static let onAccent = Color(hex: 0x1A1D29)
    static let success = Color(hex: 0x4ADE9B)
    static let warning = Color(hex: 0xFF9F43)
    static let error = Color(hex: 0xFF6B6B)

    static let corner: CGFloat = 12
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Rounded button that visibly dips when pressed.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var small = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 11 : 13, weight: prominent ? .semibold : .medium))
            .padding(.horizontal, small ? 9 : 14)
            .padding(.vertical, small ? 4 : 7)
            .foregroundColor(prominent ? Theme.onAccent : Theme.text)
            .background(
                RoundedRectangle(cornerRadius: small ? 7 : 9)
                    .fill(prominent ? Theme.accent : Theme.surfaceRaised)
                    .brightness(configuration.isPressed ? -0.12 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: small ? 7 : 9)
                    .stroke(prominent ? Color.clear : Theme.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillSmall: PillButtonStyle { PillButtonStyle(small: true) }
    static var pillProminent: PillButtonStyle { PillButtonStyle(prominent: true) }
}

/// Section container with the theme's surface colour and a hairline border.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.border, lineWidth: 1))
    }
}

/// Thin amber progress bar.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                    .animation(.easeOut(duration: 0.3), value: value)
            }
        }
        .frame(height: 6)
    }
}
