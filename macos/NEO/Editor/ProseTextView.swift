import AppKit

/// What every NEO writing surface shares: smart punctuation, Tab spacing,
/// bold and italic kept as meaning (not fonts), and paste that arrives clean.
class ProseTextView: NSTextView {
    static let neoPasteType = NSPasteboard.PasteboardType("com.hughhowey.neo.html")

    var mode: ProseMode = .chapter
    var themeProvider: () -> PageTheme = { .default }
    var afterPaste: (() -> Void)?
    var theme: PageTheme { themeProvider() }

    func configureProse() {
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = false
        usesFontPanel = false
        usesRuler = false
        usesFindBar = false
        usesFindPanel = false
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        selectedTextAttributes = [.backgroundColor: NSColor(hex: 0xC9A86A, alpha: 0.35)]
        applyThemeColors()
    }

    func applyThemeColors() {
        insertionPointColor = theme.ink
        resetTypingAttributes()
    }

    // MARK: Typing attributes

    /// New typing takes its neighbour's weight and slant — never its flag,
    /// never a break's or a ghost's look.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set { super.typingAttributes = cleanTyping(newValue) }
    }

    private func cleanTyping(_ a: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let inherited = a[.neoBlock] == nil ? a[.paragraphStyle] as? NSParagraphStyle : nil
        var out = ProseStyler.typingAttributes(theme, mode, bold: a[.neoBold] != nil, italic: a[.neoItalic] != nil,
                                               paragraphStyle: inherited, align: a[.neoAlign] as? String)
        if mode == .chapter, let sec = a[.neoSecId] { out[.neoSecId] = sec }
        return out
    }

    func resetTypingAttributes() {
        guard let ts = textStorage else { return }
        let loc = selectedRange().location
        if ts.length == 0 {
            typingAttributes = [:]
        } else {
            let at = max(0, min(loc - 1, ts.length - 1))
            // at the start of a paragraph, the paragraph's own first character speaks
            let s = ts.string as NSString
            let useAt = (loc < ts.length && (loc == 0 || s.character(at: loc - 1) == Prose.newline)) ? loc : at
            typingAttributes = ts.attributes(at: useAt, effectiveRange: nil)
        }
    }

    // MARK: Smart keys

    private func char(before loc: Int, _ n: Int = 1) -> String {
        guard let s = textStorage?.string as NSString?, loc - n >= 0 else { return "" }
        return s.substring(with: NSRange(location: loc - n, length: n))
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if !hasMarkedText(), replacementRange.location == NSNotFound, let s = string as? String {
            let sel = selectedRange()
            let collapsed = sel.length == 0
            if s == "-" && collapsed && char(before: sel.location) == "-" {
                super.insertText("—", replacementRange: NSRange(location: sel.location - 1, length: 1))
                return
            }
            if s == "." && collapsed && char(before: sel.location, 2) == ".." {
                super.insertText("…", replacementRange: NSRange(location: sel.location - 2, length: 2))
                return
            }
            if s == "\"" || s == "'" {
                let before = collapsed ? char(before: sel.location) : ""
                let opening = before.isEmpty || " \t\n\u{2028}\u{2003}([{—‘“>".contains(before)
                let curly = s == "\"" ? (opening ? "“" : "”") : (opening ? "‘" : "’")
                super.insertText(curly, replacementRange: replacementRange)
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Tab indents by two em spaces; Shift+Tab takes up to two back.
    override func insertTab(_ sender: Any?) {
        insertText("\u{2003}\u{2003}", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func insertBacktab(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, let s = textStorage?.string as NSString? else { return }
        var n = 0
        while n < 2 && sel.location - n > 0 && s.character(at: sel.location - n - 1) == 0x2003 { n += 1 }
        guard n > 0 else { return }
        let r = NSRange(location: sel.location - n, length: n)
        if shouldChangeText(in: r, replacementString: "") {
            textStorage?.replaceCharacters(in: r, with: "")
            didChangeText()
        }
    }

    // MARK: Bold / italic

    @objc func neoToggleBold(_ sender: Any?) { toggle(.neoBold, name: "Bold") }
    @objc func neoToggleItalic(_ sender: Any?) { toggle(.neoItalic, name: "Italic") }

    private func toggle(_ key: NSAttributedString.Key, name: String) {
        guard let ts = textStorage else { return }
        let r = selectedRange()
        if r.length == 0 {
            var a = typingAttributes
            if a[key] != nil { a[key] = nil } else { a[key] = true }
            typingAttributes = a
            return
        }
        var all = true
        ts.enumerateAttribute(key, in: r) { v, _, stop in if v == nil { all = false; stop.pointee = true } }
        guard shouldChangeText(in: r, replacementString: nil) else { return }
        ts.beginEditing()
        if all { ts.removeAttribute(key, range: r) } else { ts.addAttribute(key, value: true, range: r) }
        ts.endEditing()
        ProseStyler.style(ts, around: r, theme: theme, mode: mode)
        didChangeText()
        undoManager?.setActionName(name)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(neoToggleBold(_:)) || item.action == #selector(neoToggleItalic(_:)) { return isEditable }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Copy and paste

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [ProseTextView.neoPasteType] + super.writablePasteboardTypes
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let ts = textStorage else { return false }
        let r = selectedRange()
        guard r.length > 0 else { return super.writeSelection(to: pboard, type: type) }
        let piece = ts.attributedSubstring(from: r)
        if type == ProseTextView.neoPasteType {
            return pboard.setString(HTMLCodec.fragmentHTML(from: piece), forType: type)
        }
        if type == .string {
            let plain = piece.string.replacingOccurrences(of: Prose.mark, with: "")
                .replacingOccurrences(of: Prose.lineBreak, with: "\n")
            return pboard.setString(plain, forType: .string)
        }
        return super.writeSelection(to: pboard, type: type)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [ProseTextView.neoPasteType, .html, .rtf, .rtfd, .string]
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        var content: NSAttributedString? = nil
        switch type {
        case ProseTextView.neoPasteType:
            if let h = pboard.string(forType: type) { content = HTMLCodec.attributedString(fromHTML: h, mode: .stored).0 }
        case .html:
            if let h = pboard.string(forType: .html) { content = HTMLCodec.attributedString(fromHTML: h, mode: .foreign).0 }
        case .rtf, .rtfd:
            if let d = pboard.data(forType: type),
               let a = NSAttributedString(rtf: d, documentAttributes: nil) ?? NSAttributedString(rtfd: d, documentAttributes: nil) {
                content = ProseTextView.fromRich(a)
            }
        case .string:
            if let t = pboard.string(forType: .string) { content = ProseTextView.fromPlain(t) }
        default:
            break
        }
        guard let content, content.length > 0 else { return false }
        insertClean(content)
        return true
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        for t in readablePasteboardTypes where pb.availableType(from: [t]) != nil {
            if readSelection(from: pb, type: t) { return }
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if let t = NSPasteboard.general.string(forType: .string) { insertClean(ProseTextView.fromPlain(t)) }
    }

    func insertClean(_ incoming: NSAttributedString) {
        guard let ts = textStorage else { return }
        let a = NSMutableAttributedString(attributedString: incoming)
        if mode == .notes {
            // notes have no flags, breaks, or ghosts
            let full = NSRange(location: 0, length: a.length)
            for k in [NSAttributedString.Key.neoBlock, .neoSecId, .neoSecBrk, .neoMark] { a.removeAttribute(k, range: full) }
            a.mutableString.replaceOccurrences(of: Prose.mark, with: "", range: NSRange(location: 0, length: a.length))
        }
        let r = rangeForUserTextChange
        guard r.location != NSNotFound, shouldChangeText(in: r, replacementString: a.string) else { return }
        // the first pasted paragraph joins the one it lands in, and keeps that
        // paragraph's identity (its alignment, its outline section)
        let nl = (a.string as NSString).range(of: "\n")
        if mode == .chapter, nl.location != NSNotFound {
            var host = Prose.paragraphAttributes(ts, Prose.paragraph(ts.string as NSString, at: r.location))
            if (host[.neoBlock] as? String) == BlockKind.sceneBreak.rawValue { host = [:] }
            let head = NSRange(location: 0, length: nl.location + 1)
            for k in NSAttributedString.Key.paragraphKeys { a.removeAttribute(k, range: head) }
            a.addAttributes(host, range: head)
        }
        ts.replaceCharacters(in: r, with: a)
        didChangeText()
        setSelectedRange(NSRange(location: r.location + a.length, length: 0))
        scrollRangeToVisible(selectedRange())
        afterPaste?()
    }

    /// Plain text: every run of line breaks is a paragraph break.
    static func fromPlain(_ t: String) -> NSAttributedString {
        let paras = t.replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "\n\u{2029}"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return NSAttributedString(string: paras.joined(separator: "\n"))
    }

    /// Rich text from other apps: paragraphs, bold and italic survive.
    static func fromRich(_ a: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString()
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            let text = (a.string as NSString).substring(with: r)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{2029}", with: "\n")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            var attrs: [NSAttributedString.Key: Any] = [:]
            if let f = v as? NSFont {
                let traits = NSFontManager.shared.traits(of: f)
                if traits.contains(.boldFontMask) { attrs[.neoBold] = true }
                if traits.contains(.italicFontMask) { attrs[.neoItalic] = true }
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        let pieces = ParaPiece.split(out).filter { !$0.isBlank }.map { p -> ParaPiece in
            ParaPiece(content: p.content, attrs: [:])
        }
        return ParaPiece.join(pieces)
    }
}
