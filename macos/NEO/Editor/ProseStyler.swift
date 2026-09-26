import AppKit

enum ProseMode { case chapter, notes }

/// Derives how the page looks from what the text means. Runs over a whole
/// storage when the theme changes, and over the touched paragraphs (plus the
/// one after, whose indent depends on its neighbour) after every edit.
enum ProseStyler {
    static let markBackground = NSColor(hex: 0xF6E3B8)
    static let markInk = NSColor(hex: 0x1C1C1C)

    static func lineHeight(_ theme: PageTheme, _ mode: ProseMode) -> CGFloat {
        theme.size * (mode == .chapter ? 1.75 : 1.7)
    }

    /// The raise that centres a line's glyphs in its (taller) line box, the way
    /// CSS line-height does.
    static func baselineOffset(_ theme: PageTheme, _ mode: ProseMode, font: NSFont) -> CGFloat {
        let natural = ceil(font.ascender - font.descender + font.leading)
        return max(0, (lineHeight(theme, mode) - natural) / 2)
    }

    static func styleAll(_ ts: NSTextStorage, theme: PageTheme, mode: ProseMode) {
        style(ts, around: NSRange(location: 0, length: ts.length), theme: theme, mode: mode)
    }

    static func style(_ ts: NSTextStorage, around range: NSRange, theme: PageTheme, mode: ProseMode) {
        let s = ts.string as NSString
        let lo = min(range.location, s.length)
        let hi = min(NSMaxRange(range), s.length)
        var para = Prose.paragraph(s, at: lo)
        var prevKind: BlockKind? = para.location > 0
            ? Prose.blockKind(ts, Prose.paragraph(s, at: para.location - 1)) : nil
        var extra = 1   // the paragraph after the touched ones, whose indent may change
        ts.beginEditing()
        while true {
            let full = Prose.withSeparator(para, in: s)
            styleParagraph(ts, full: full, content: para, isFirst: para.location == 0,
                           prevKind: prevKind, theme: theme, mode: mode)
            prevKind = Prose.blockKind(ts, para)
            guard NSMaxRange(para) < s.length else { break }
            if NSMaxRange(para) >= hi {
                if extra == 0 { break }
                extra -= 1
            }
            para = Prose.paragraph(s, at: NSMaxRange(para) + 1)
        }
        ts.endEditing()
    }

    static func paragraphStyle(kind: BlockKind?, align: String?, isFirst: Bool, prevKind: BlockKind?,
                               theme: PageTheme, mode: ProseMode, font: NSFont) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        let lh = lineHeight(theme, mode)
        ps.minimumLineHeight = lh
        ps.maximumLineHeight = lh
        ps.lineBreakMode = .byWordWrapping
        switch align {
        case "center": ps.alignment = .center
        case "right": ps.alignment = .right
        case "justify": ps.alignment = .justified
        default: ps.alignment = .natural
        }
        if mode == .chapter {
            // 2em first-line indent, except where a book wouldn't: the opening
            // paragraph, after a break, ghosts, and centred/right lines
            let noIndent = isFirst || kind != nil || prevKind == .sceneBreak || align == "center" || align == "right"
            ps.firstLineHeadIndent = noIndent ? 0 : theme.size * 2
            if kind == .sceneBreak {
                ps.alignment = .center
                ps.paragraphSpacingBefore = theme.size * 1.6
                ps.paragraphSpacing = theme.size * 1.6
            }
        }
        return ps
    }

    private static func styleParagraph(_ ts: NSTextStorage, full: NSRange, content: NSRange, isFirst: Bool,
                                       prevKind: BlockKind?, theme: PageTheme, mode: ProseMode) {
        guard full.length > 0 else { return }
        let kind = mode == .chapter ? Prose.blockKind(ts, content) : nil
        let align = Prose.paragraphValue(ts, content, .neoAlign) as? String
        let base = theme.font()
        let ps = paragraphStyle(kind: kind, align: align, isFirst: isFirst, prevKind: prevKind,
                                theme: theme, mode: mode, font: base)
        let color: NSColor = kind == .ghost ? theme.ghost : kind == .sceneBreak ? theme.sceneBreak : theme.ink
        let rise = baselineOffset(theme, mode, font: base)

        ts.addAttribute(.paragraphStyle, value: ps, range: full)
        ts.addAttribute(.foregroundColor, value: color, range: full)
        ts.addAttribute(.baselineOffset, value: rise, range: full)
        ts.removeAttribute(.backgroundColor, range: full)
        ts.removeAttribute(.underlineStyle, range: full)
        ts.removeAttribute(.underlineColor, range: full)
        if kind == .sceneBreak {
            ts.addAttribute(.kern, value: 8 * theme.zoom, range: full)
        } else {
            ts.removeAttribute(.kern, range: full)
        }

        ts.enumerateAttributes(in: full, options: []) { attrs, r, _ in
            let bold = attrs[.neoBold] != nil
            let italic = attrs[.neoItalic] != nil || kind == .ghost
            ts.addAttribute(.font, value: theme.font(bold: bold, italic: italic), range: r)
            if attrs[.neoMark] != nil {
                ts.addAttributes([
                    .backgroundColor: markBackground,
                    .foregroundColor: markInk,
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: NEOColor.nsRed,
                    .cursor: NSCursor.pointingHand
                ], range: r)
            }
        }
        // characters the body face lacks (⚑, emoji, other scripts) borrow a
        // face that has them, as AppKit would have done before restyling
        ts.fixFontAttribute(in: full)
    }

    /// What new typing looks like: the neighbour's weight and slant, never its
    /// flag, never a break's or a ghost's paragraph identity.
    static func typingAttributes(_ theme: PageTheme, _ mode: ProseMode, bold: Bool, italic: Bool,
                                 paragraphStyle: NSParagraphStyle?, align: String?) -> [NSAttributedString.Key: Any] {
        let base = theme.font()
        var a: [NSAttributedString.Key: Any] = [
            .font: theme.font(bold: bold, italic: italic),
            .foregroundColor: theme.ink,
            .baselineOffset: baselineOffset(theme, mode, font: base)
        ]
        if bold { a[.neoBold] = true }
        if italic { a[.neoItalic] = true }
        if let align { a[.neoAlign] = align }
        a[.paragraphStyle] = paragraphStyle
            ?? ProseStyler.paragraphStyle(kind: nil, align: align, isFirst: false, prevKind: nil, theme: theme, mode: mode, font: base)
        return a
    }
}
