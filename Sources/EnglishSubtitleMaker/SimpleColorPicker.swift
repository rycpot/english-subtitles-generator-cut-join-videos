import AppKit
import SubtitleCore
import SwiftUI

/// A compact colour picker like the browser's (and the design editor's): a
/// swatch that opens a popover with a saturation/brightness square, a hue bar,
/// an eyedropper and a hex field.
struct SimpleColorPicker: View {
    @Binding var color: NSColor
    var help = "Colour"
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(color))
                .frame(width: 30, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ColorPopover(color: $color)
        }
    }
}

/// The same picker for SwiftUI `Color` values.
struct SimpleColorPickerSwiftUI: View {
    @Binding var color: Color
    var help = "Colour"

    var body: some View {
        SimpleColorPicker(color: Binding(get: { NSColor(color) }, set: { color = Color($0) }), help: help)
    }
}

private struct ColorPopover: View {
    @Binding var color: NSColor
    @State private var hue: CGFloat = 0
    @State private var saturation: CGFloat = 0
    @State private var brightness: CGFloat = 1
    @State private var hex = ""
    @State private var loaded = false

    private let squareSize = CGSize(width: 220, height: 150)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            square
            hueBar
            HStack(spacing: 8) {
                Button { sample() } label: { Image(systemName: "eyedropper") }
                    .buttonStyle(.pillSmall)
                    .help("Pick a colour from anywhere on the screen")
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(current))
                    .frame(width: 26, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                TextField("#RRGGBB", text: $hex, onCommit: applyHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 100)
                    .help("Type a hex colour such as #FF6A00 and press Return")
                Text("HEX").font(.system(size: 10, weight: .medium)).foregroundColor(Theme.textFaint)
            }
        }
        .padding(12)
        .onAppear(perform: load)
    }

    private var current: NSColor {
        NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1).usingColorSpace(.sRGB) ?? .white
    }

    // Saturation left→right, brightness top→bottom, for the current hue.
    private var square: some View {
        ZStack(alignment: .topLeading) {
            Color(NSColor(calibratedHue: hue, saturation: 1, brightness: 1, alpha: 1))
            LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .background(Circle().stroke(Color.black.opacity(0.4), lineWidth: 3.5))
                .frame(width: 12, height: 12)
                .offset(x: saturation * squareSize.width - 6, y: (1 - brightness) * squareSize.height - 6)
        }
        .frame(width: squareSize.width, height: squareSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            saturation = min(1, max(0, v.location.x / squareSize.width))
            brightness = 1 - min(1, max(0, v.location.y / squareSize.height))
            commit()
        })
    }

    private var hueBar: some View {
        let stops = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
            Color(NSColor(calibratedHue: $0, saturation: 1, brightness: 1, alpha: 1))
        }
        return ZStack(alignment: .leading) {
            LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
                .clipShape(Capsule())
            Circle()
                .fill(Color(NSColor(calibratedHue: hue, saturation: 1, brightness: 1, alpha: 1)))
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(radius: 1)
                .frame(width: 14, height: 14)
                .offset(x: hue * (squareSize.width - 14))
        }
        .frame(width: squareSize.width, height: 14)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            hue = min(1, max(0, v.location.x / squareSize.width))
            commit()
        })
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let c = color.usingColorSpace(.sRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = h
        saturation = s
        brightness = b
        hex = HexColor.format(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }

    private func commit() {
        let c = current
        hex = HexColor.format(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        color = c
    }

    private func set(_ c: NSColor) {
        guard let rgb = c.usingColorSpace(.sRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Greys have no hue; keep the bar where it was.
        if s > 0.001 { hue = h }
        saturation = s
        brightness = b
        hex = HexColor.format(r: Double(rgb.redComponent), g: Double(rgb.greenComponent), b: Double(rgb.blueComponent))
        color = rgb
    }

    private func applyHex() {
        guard let c = HexColor.parse(hex) else {
            hex = HexColor.format(r: Double(color.usingColorSpace(.sRGB)?.redComponent ?? 1),
                                  g: Double(color.usingColorSpace(.sRGB)?.greenComponent ?? 1),
                                  b: Double(color.usingColorSpace(.sRGB)?.blueComponent ?? 1))
            return
        }
        set(NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1))
    }

    private func sample() {
        NSColorSampler().show { picked in
            if let picked { set(picked) }
        }
    }
}
