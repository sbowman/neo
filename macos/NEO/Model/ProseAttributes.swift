import AppKit

// A chapter lives in an NSTextStorage whose *meaning* is carried by NEO's own
// attributes; fonts, colours and paragraph styles are derived from them by
// ProseStyler and never saved. Paragraphs are separated by "\n"; a manual line
// break inside a paragraph is U+2028.

extension NSAttributedString.Key {
    /// Character-level
    static let neoBold = NSAttributedString.Key("neo.bold")
    static let neoItalic = NSAttributedString.Key("neo.italic")
    /// Placeholder flag: the sticky id, on a single "⚑" character
    static let neoMark = NSAttributedString.Key("neo.mark")

    /// Paragraph-level (applied across the whole paragraph, newline included)
    static let neoBlock = NSAttributedString.Key("neo.block")       // BlockKind raw value
    static let neoSecId = NSAttributedString.Key("neo.secId")       // outline section this paragraph belongs to
    static let neoSecBrk = NSAttributedString.Key("neo.secBrk")     // a *** planted ahead of a ghost
    static let neoAlign = NSAttributedString.Key("neo.align")       // center | right | justify

    static let paragraphKeys: [NSAttributedString.Key] = [.neoBlock, .neoSecId, .neoSecBrk, .neoAlign]
}

enum BlockKind: String {
    case sceneBreak = "scene-break"
    case ghost
}

enum Prose {
    static let mark = "\u{2691}"                 // ⚑
    static let markChar: unichar = 0x2691
    static let lineBreak = "\u{2028}"
    static let lineBreakChar: unichar = 0x2028
    static let newline: unichar = 0x0A
    static let sceneBreakText = "***"

    /// Content ranges of every paragraph (excluding the "\n" separators).
    /// "" has one empty paragraph; "a\n" has two.
    static func paragraphs(_ s: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = 0
        let n = s.length
        var i = 0
        while i < n {
            if s.character(at: i) == newline {
                out.append(NSRange(location: start, length: i - start))
                start = i + 1
            }
            i += 1
        }
        out.append(NSRange(location: start, length: n - start))
        return out
    }

    /// The content range of the paragraph holding `loc`.
    static func paragraph(_ s: NSString, at loc: Int) -> NSRange {
        let n = s.length
        var a = min(max(0, loc), n)
        var b = a
        while a > 0 && s.character(at: a - 1) != newline { a -= 1 }
        while b < n && s.character(at: b) != newline { b += 1 }
        return NSRange(location: a, length: b - a)
    }

    /// Index of the paragraph holding `loc` among `paragraphs(s)`.
    static func paragraphIndex(_ s: NSString, at loc: Int) -> Int {
        var idx = 0
        let end = min(loc, s.length)
        var i = 0
        while i < end {
            if s.character(at: i) == newline { idx += 1 }
            i += 1
        }
        return idx
    }

    /// The paragraph range including its trailing newline when it has one.
    static func withSeparator(_ r: NSRange, in s: NSString) -> NSRange {
        NSMaxRange(r) < s.length ? NSRange(location: r.location, length: r.length + 1) : r
    }

    static func blockKind(_ a: NSAttributedString, _ para: NSRange) -> BlockKind? {
        guard let v = paragraphValue(a, para, .neoBlock) as? String else { return nil }
        return BlockKind(rawValue: v)
    }

    /// Paragraph attributes are read from the paragraph's first character, or
    /// from its newline when it is empty.
    static func paragraphValue(_ a: NSAttributedString, _ para: NSRange, _ key: NSAttributedString.Key) -> Any? {
        let at = para.location
        guard at < a.length else { return nil }
        return a.attribute(key, at: at, effectiveRange: nil)
    }

    static func paragraphAttributes(_ a: NSAttributedString, _ para: NSRange) -> [NSAttributedString.Key: Any] {
        var out: [NSAttributedString.Key: Any] = [:]
        for k in NSAttributedString.Key.paragraphKeys {
            if let v = paragraphValue(a, para, k) { out[k] = v }
        }
        return out
    }

    static func isBlank(_ s: NSString, _ r: NSRange) -> Bool {
        s.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Words as the writer sees them: no flags, no unwritten outline ghosts.
    static func plainText(_ a: NSAttributedString, skipGhosts: Bool = true) -> String {
        let s = a.string as NSString
        var parts: [String] = []
        for p in paragraphs(s) {
            if skipGhosts, blockKind(a, p) == .ghost { continue }
            if blockKind(a, p) == .sceneBreak { parts.append(""); continue }
            parts.append(s.substring(with: p)
                .replacingOccurrences(of: mark, with: "")
                .replacingOccurrences(of: lineBreak, with: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    /// The chapter's text as a browser's `textContent` would give it: no
    /// paragraph separators, flags included. Darlings remember their home by
    /// 60 characters of this on either side, so positions are measured here.
    /// Returns the flat string and, for each flat index, its storage index.
    static func flatText(_ a: NSAttributedString) -> (text: NSString, map: [Int]) {
        let s = a.string as NSString
        var chars = [unichar](repeating: 0, count: s.length)
        s.getCharacters(&chars, range: NSRange(location: 0, length: s.length))
        var out: [unichar] = []
        var map: [Int] = []
        out.reserveCapacity(chars.count)
        map.reserveCapacity(chars.count)
        for (i, c) in chars.enumerated() where c != newline && c != lineBreakChar {
            out.append(c)
            map.append(i)
        }
        return (NSString(characters: out, length: out.count), map)
    }
}
