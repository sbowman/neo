import SwiftUI
import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: opacity))
    }
}

/// The dark surround, the gold accent, and the two pages.
enum NEOColor {
    static let bg = Color(hex: 0x191919)
    static let bgSoft = Color(hex: 0x222222)
    static let pane = Color(hex: 0x202020)
    static let accent = Color(hex: 0xC9A86A)
    static let red = Color(hex: 0xC0392B)
    static let border = Color(hex: 0x3A3A3A)

    static let nsBg = NSColor(hex: 0x191919)
    static let nsAccent = NSColor(hex: 0xC9A86A)
    static let nsRed = NSColor(hex: 0xC0392B)

    static func muted(_ bright: Bool) -> Color { bright ? Color(hex: 0xB4B4B4) : Color(hex: 0x8A8A8A) }
}

enum NEOFonts {
    static let bodyNames = ["Georgia", "Palatino", "Baskerville", "Hoefler Text", "Iowan Old Style"]
    static let dropCapStyles: [(key: String, label: String)] = [("literary", "Literary"), ("fantasy", "Fantasy"), ("scifi", "Sci-Fi")]

    static func dropCapFamilies(_ style: String) -> [String] {
        switch style {
        case "fantasy": return ["Apple Chancery", "Snell Roundhand", "Zapfino"]
        case "scifi": return ["Futura", "Avenir Next", "Helvetica Neue"]
        default: return ["Didot", "Bodoni 72", "Georgia"]
        }
    }

    static func dropCapFont(_ style: String, size: CGFloat) -> NSFont {
        for fam in dropCapFamilies(style) {
            if let f = NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: size) { return f }
        }
        return NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
    }
}

/// Everything the page's look depends on. Built from the library settings.
struct PageTheme: Equatable {
    var night: Bool
    var bodyFont: String
    var dropCap: String
    var fontSize: CGFloat     // editorFontSize (14…22)
    var zoom: CGFloat         // pageZoom (0.75…1.6)

    var size: CGFloat { fontSize * zoom }

    var paper: NSColor { night ? NSColor(hex: 0x232221) : NSColor(hex: 0xFBFAF7) }
    var ink: NSColor { night ? NSColor(hex: 0xD6D2C6) : NSColor(hex: 0x1C1C1C) }
    var heading: NSColor { night ? NSColor(hex: 0x918B7D) : NSColor(hex: 0x555555) }
    var subtitle: NSColor { night ? NSColor(hex: 0xA09A8C) : NSColor(hex: 0x555555) }
    var authorInk: NSColor { night ? NSColor(hex: 0x918B7D) : NSColor(hex: 0x444444) }
    var sceneBreak: NSColor { night ? NSColor(hex: 0x7D7768) : NSColor(hex: 0x888888) }
    var ghost: NSColor { night ? NSColor(hex: 0x6F6A5E) : NSColor(hex: 0xA9A294) }
    var placeholder: NSColor { night ? NSColor(hex: 0x5F5B52) : NSColor(hex: 0xB9B4A8) }
    var sheetBorder: NSColor? { night ? NSColor(hex: 0x2E2D2B) : nil }

    var paperColor: Color { Color(nsColor: paper) }
    var inkColor: Color { Color(nsColor: ink) }

    static let `default` = PageTheme(night: true, bodyFont: "Georgia", dropCap: "literary", fontSize: 17, zoom: 1)

    // font cache: bold/italic variants of the body face at the current size
    private static var cache: [String: NSFont] = [:]

    func font(bold: Bool = false, italic: Bool = false, size: CGFloat? = nil, family: String? = nil) -> NSFont {
        let fam = family ?? bodyFont
        let sz = size ?? self.size
        let key = "\(fam)|\(sz)|\(bold)|\(italic)"
        if let f = PageTheme.cache[key] { return f }
        let fm = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        var f = fm.font(withFamily: fam, traits: traits, weight: bold ? 9 : 5, size: sz)
            ?? NSFont(name: "Georgia", size: sz)!
        // some faces lack a true italic or bold; ask for the trait by conversion
        if italic && !fm.traits(of: f).contains(.italicFontMask) { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        if bold && !fm.traits(of: f).contains(.boldFontMask) { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        PageTheme.cache[key] = f
        return f
    }
}
