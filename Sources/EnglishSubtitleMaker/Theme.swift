import AppKit
import SwiftUI

/// Dark charcoal surfaces with green accents: deep green for primary
/// buttons, mint for labels and progress, coral for errors.
enum Theme {
    static let background = Color(hex: 0x0B0F12)
    static let surface = Color(hex: 0x12181C)
    static let surfaceRaised = Color(hex: 0x1A2227)
    static let logBackground = Color(hex: 0x080B0D)
    static let border = Color(hex: 0x222C32)

    static let text = Color(hex: 0xECF1EF)
    static let textSecondary = Color(hex: 0x9AA7A2)
    static let textFaint = Color(hex: 0x5E6B66)

    /// Primary buttons.
    static let accent = Color(hex: 0x14805C)
    static let onAccent = Color.white
    /// Labels, highlights and the progress bar.
    static let mint = Color(hex: 0x4FD6A0)
    static let success = Color(hex: 0x4FD6A0)
    static let warning = Color(hex: 0xF0B45A)
    static let error = Color(hex: 0xFF6B6B)

    static let corner: CGFloat = 14
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
            .padding(.horizontal, small ? 11 : 18)
            .padding(.vertical, small ? 4 : 8)
            .foregroundColor(prominent ? Theme.onAccent : Theme.text)
            .background(
                Capsule()
                    .fill(prominent ? Theme.accent : Theme.surfaceRaised)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .overlay(
                Capsule()
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

/// Thin mint progress bar.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.mint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                    .animation(.easeOut(duration: 0.3), value: value)
            }
        }
        .frame(height: 6)
    }
}
