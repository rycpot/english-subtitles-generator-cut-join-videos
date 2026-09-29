import AppKit
import CoreText
import Foundation
import SubtitleCore

/// A text box on the Merge canvas. Sizes and positions are in canvas pixels.
struct MergeText: Identifiable, Equatable {
    enum Alignment: String, CaseIterable, Identifiable {
        case left, center, right
        var id: String { rawValue }
        var nsAlignment: NSTextAlignment {
            switch self {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }
    }

    let id = UUID()
    var text = "Your text"
    var fontFamily = "Helvetica Neue"
    var size: CGFloat = 96
    var bold = true
    var italic = false
    var color = NSColor.white
    var alignment = Alignment.center
    var outline = false
    var outlineColor = NSColor.black
    var shadow = true
    var box = false
    var boxColor = NSColor.black
    var boxOpacity: CGFloat = 0.5
    /// Top-left of the rendered text (including its box) on the canvas.
    var origin = CGPoint(x: 560, y: 820)
    /// The picture this text is shown on; nil = every picture.
    var slide: UUID?

    func shows(on slideID: UUID) -> Bool { slide == nil || slide == slideID }
}

/// Draws text boxes; the canvas preview and the video frames use the same images.
enum TextRenderer {
    /// The font for `t`, with bold / italic from the family when it has them;
    /// otherwise they are drawn synthetically (see `attributes`).
    static func font(_ t: MergeText) -> (font: NSFont, fakeBold: Bool, fakeItalic: Bool) {
        let fm = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if t.bold { traits.insert(.boldFontMask) }
        if t.italic { traits.insert(.italicFontMask) }
        let base = fm.font(withFamily: t.fontFamily, traits: traits, weight: t.bold ? 9 : 5, size: t.size)
            ?? fm.font(withFamily: t.fontFamily, traits: [], weight: 5, size: t.size)
            ?? NSFont(name: t.fontFamily, size: t.size)
            ?? NSFont.systemFont(ofSize: t.size, weight: t.bold ? .bold : .regular)
        let have = fm.traits(of: base)
        return (base, t.bold && !have.contains(.boldFontMask), t.italic && !have.contains(.italicFontMask))
    }

    static func attributed(_ t: MergeText) -> NSAttributedString {
        let (font, fakeBold, fakeItalic) = font(t)
        let para = NSMutableParagraphStyle()
        para.alignment = t.alignment.nsAlignment
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: t.color, .paragraphStyle: para]
        if fakeItalic { attrs[.obliqueness] = 0.2 }
        if t.outline {
            // Negative width: fill and stroke. The outline is ~6% of the size.
            attrs[.strokeColor] = t.outlineColor
            attrs[.strokeWidth] = -12
        } else if fakeBold {
            attrs[.strokeColor] = t.color
            attrs[.strokeWidth] = -4
        }
        if t.shadow {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.6)
            s.shadowOffset = NSSize(width: t.size * 0.03, height: -t.size * 0.03)
            s.shadowBlurRadius = t.size * 0.06
            attrs[.shadow] = s
        }
        return NSAttributedString(string: t.text.isEmpty ? " " : t.text, attributes: attrs)
    }

    /// Room around the glyphs for the box, outline, shadow and italic overhang.
    static func padding(_ t: MergeText) -> CGFloat { t.box ? t.size * 0.35 : t.size * 0.15 }

    /// The rendered text box: its image (at canvas scale) and size in canvas pixels.
    static func render(_ t: MergeText) -> (image: CGImage, size: CGSize)? {
        let string = attributed(t)
        let bounds = string.boundingRect(with: CGSize(width: 10_000, height: 10_000),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let pad = padding(t)
        let size = CGSize(width: ceil(bounds.width + 2 * pad), height: ceil(bounds.height + 2 * pad))
        guard size.width >= 1, size.height >= 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.current = previous }
        if t.box {
            let box = NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: t.size * 0.2, yRadius: t.size * 0.2)
            t.boxColor.withAlphaComponent(t.boxOpacity).setFill()
            box.fill()
        }
        string.draw(with: CGRect(x: pad, y: pad, width: bounds.width, height: bounds.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        guard let image = ctx.makeImage() else { return nil }
        return (image, size)
    }

    /// Where `t` sits on the canvas.
    static func frame(_ t: MergeText) -> CGRect {
        CGRect(origin: t.origin, size: render(t)?.size ?? .zero)
    }
}

/// Fonts the user added: copied to Application Support/…/Fonts and registered
/// for this app whenever it starts, so they stay available.
enum CustomFonts {
    static var folder: URL { AppPaths.support.appendingPathComponent("Fonts", isDirectory: true) }

    static let extensions: Set<String> = ["ttf", "otf", "ttc"]

    /// Registers every saved font; returns their family names.
    @discardableResult
    static func registerSaved() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { extensions.contains($0.pathExtension.lowercased()) }.flatMap { register($0) }
    }

    /// Family names in a font file.
    static func families(in url: URL) -> [String] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        return Array(Set(descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String })).sorted()
    }

    @discardableResult
    static func register(_ url: URL) -> [String] {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return families(in: url)
    }

    /// Copies `url` into the fonts folder and registers it; returns its families.
    static func add(_ url: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: url, to: dest)
        }
        let names = register(dest)
        if names.isEmpty { throw SubtitleError(.unexpected, "\(url.lastPathComponent) is not a font macOS can read") }
        return names
    }

    /// The saved font files and their families.
    static func saved() -> [(file: URL, families: [String])] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0, families(in: $0)) }
    }

    static func remove(_ file: URL) {
        CTFontManagerUnregisterFontsForURL(file as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: file)
    }
}
