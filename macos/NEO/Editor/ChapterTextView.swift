import AppKit

/// One chapter's page of prose. Keys that carry NEO's grammar — Enter's
/// rhythm, Backspace beside breaks, flags and chapter edges — are routed to
/// the session; everything else is the system's own text editing.
///
/// The opening paragraph wears a drop cap: its first letter is hidden from
/// layout, the space it needs is excluded from the text container, and the
/// letter is drawn large in the corner. While the caret is in that paragraph
/// the cap steps aside, so editing it is ordinary editing.
final class ChapterTextView: ProseTextView, NSLayoutManagerDelegate {
    let chapterId: String
    weak var session: BookSession?

    private var capRange: NSRange? = nil     // characters hidden for the cap
    private var capText: String = ""

    init(chapterId: String, session: BookSession, storage: NSTextStorage, width: CGFloat) {
        self.chapterId = chapterId
        self.session = session
        let lm = NSLayoutManager()
        lm.allowsNonContiguousLayout = false
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(containerSize: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.heightTracksTextView = false
        lm.addTextContainer(tc)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40), textContainer: tc)
        lm.delegate = self
        mode = .chapter
        themeProvider = { [weak session] in session?.theme ?? .default }
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = []
        minSize = NSSize(width: 0, height: 20)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        configureProse()
        afterPaste = { [weak session] in session?.reconcileMarks() }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        fatalError("use init(chapterId:session:storage:width:)")
    }

    required init?(coder: NSCoder) { fatalError() }

    func detach() {
        if let lm = layoutManager { textStorage?.removeLayoutManager(lm) }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), let ws = session?.wordstar, ws.handle(event, in: self) {
            session?.enterRun = 0
            return
        }
        if !hasMarkedText(), let session {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if isReturn && mods.isEmpty {
                session.enterRun += 1
            } else {
                session.enterRun = 0
            }
            if isReturn && mods == .shift {
                insertLineBreak(nil)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if session?.handleNewline(self) == true { return }
        super.insertNewline(sender)
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        insertNewline(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if session?.handleDelete(self, backward: true) == true { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if session?.handleDelete(self, backward: false) == true { return }
        super.deleteForward(sender)
    }

    // MARK: Mouse

    private func characterIndex(atWindowPoint p: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let local = convert(p, from: nil)
        let pt = NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
        var frac: CGFloat = 0
        let gi = lm.glyphIndex(for: pt, in: tc, fractionOfDistanceThroughGlyph: &frac)
        guard gi < lm.numberOfGlyphs else { return nil }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tc)
        guard rect.contains(pt) else { return nil }
        return lm.characterIndexForGlyph(at: gi)
    }

    override func mouseDown(with event: NSEvent) {
        session?.enterRun = 0
        session?.wordstar?.cancel()
        // a flag shows its note — and leaves the text alone: no caret move, no
        // selection, focus stays on the page (so the drop cap doesn't jump)
        if let ci = characterIndex(atWindowPoint: event.locationInWindow),
           let sid = textStorage?.attribute(.neoMark, at: ci, effectiveRange: nil) as? String {
            session?.showSticky(sid)
            return
        }
        session?.pageClicked()
        super.mouseDown(with: event)
        // clicking an outline ghost selects it, ready to be written over
        guard let ts = textStorage, selectedRange().length == 0, event.clickCount == 1 else { return }
        let s = ts.string as NSString
        let p = Prose.paragraph(s, at: selectedRange().location)
        if p.length > 0, Prose.blockKind(ts, p) == .ghost {
            setSelectedRange(p)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = super.menu(for: event) ?? NSMenu()
        if selectedRange().length > 0 {
            m.insertItem(NSMenuItem.separator(), at: 0)
            let item = NSMenuItem(title: "Send to Darlings", action: #selector(sendToDarlings(_:)), keyEquivalent: "")
            item.target = self
            m.insertItem(item, at: 0)
        }
        return m
    }

    @objc private func sendToDarlings(_ sender: Any?) {
        session?.moveToDarlings(chapterId, selectedRange())
    }

    // MARK: Dragging to the Darlings tab

    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        session?.dragOrigin = (chapterId, selectedRange())
        session?.draggingText = true
        return super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
    }

    override func draggingSession(_ s: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        super.draggingSession(s, endedAt: screenPoint, operation: operation)
        session?.draggingText = false
        session?.dragOrigin = nil
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { session?.currentChapterId = chapterId; updateDropCap() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { DispatchQueue.main.async { self.updateDropCap() } }
        return ok
    }

    // MARK: Drop cap

    private var caretInFirstParagraph: Bool {
        guard window?.firstResponder === self, let ts = textStorage else { return false }
        let s = ts.string as NSString
        return Prose.paragraph(s, at: selectedRange().location).location == 0
    }

    /// The characters the cap is made of: the first letter, with an opening
    /// quote riding along the way ::first-letter takes it.
    private func capCandidate() -> NSRange? {
        guard let ts = textStorage, ts.length > 0 else { return nil }
        let s = ts.string as NSString
        let first = Prose.paragraph(s, at: 0)
        guard first.length > 1, Prose.blockKind(ts, first) == nil else { return nil }
        if let a = Prose.paragraphValue(ts, first, .neoAlign) as? String, a == "center" || a == "right" { return nil }
        var r = s.rangeOfComposedCharacterSequence(at: 0)
        let c = s.substring(with: r)
        if "“‘\"'(«".contains(c), NSMaxRange(r) < first.length {
            let next = s.rangeOfComposedCharacterSequence(at: NSMaxRange(r))
            r = NSUnionRange(r, next)
        }
        let text = s.substring(with: r)
        guard text.rangeOfCharacter(from: .alphanumerics) != nil,
              ts.attribute(.neoMark, at: r.location, effectiveRange: nil) == nil else { return nil }
        return r
    }

    func updateDropCap() {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return }
        let want: NSRange? = caretInFirstParagraph ? nil : capCandidate()
        let wantText = want.map { (ts.string as NSString).substring(with: $0) } ?? ""
        let theme = self.theme
        let capFont = NEOFonts.dropCapFont(theme.dropCap, size: theme.size * 3.4)
        var path: [NSBezierPath] = []
        if want != nil {
            let w = (wantText as NSString).size(withAttributes: [.font: capFont]).width
            let lh = ProseStyler.lineHeight(theme, .chapter)
            path = [NSBezierPath(rect: NSRect(x: 0, y: 0, width: ceil(w + 8 * theme.zoom), height: lh * 2 - 1))]
        }
        let pathChanged = tc.exclusionPaths.map(\.bounds) != path.map(\.bounds)
        guard want != capRange || wantText != capText || pathChanged else { return }
        let old = capRange
        capRange = want
        capText = wantText
        tc.exclusionPaths = path
        for r in [old, want].compactMap({ $0 }) where NSMaxRange(r) <= ts.length {
            lm.invalidateGlyphs(forCharacterRange: r, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        }
        needsDisplay = true
        sizeToFit()
    }

    func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let cap = capRange, glyphRange.length > 0,
              charIndexes[0] < NSMaxRange(cap) else { return 0 }
        var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        for i in 0..<glyphRange.length {
            newProps[i] = props[i]
            if NSLocationInRange(charIndexes[i], cap) { newProps[i].insert(.null) }
        }
        lm.setGlyphs(glyphs, properties: newProps, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawWordStarTags()
        guard let cap = capRange, let lm = layoutManager, let tc = textContainer, let ts = textStorage,
              NSMaxRange(cap) < ts.length else { return }
        let theme = self.theme
        let capFont = NEOFonts.dropCapFont(theme.dropCap, size: theme.size * 3.4)
        // the cap sits on the second line's baseline
        let gi = lm.glyphIndexForCharacter(at: NSMaxRange(cap))
        guard gi < lm.numberOfGlyphs else { return }
        let frag = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
        let baseline = frag.minY + lm.location(forGlyphAt: gi).y + ProseStyler.lineHeight(theme, .chapter)
        let origin = NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y + baseline - capFont.ascender)
        _ = tc
        (capText as NSString).draw(at: origin, withAttributes: [.font: capFont, .foregroundColor: theme.ink])
    }

    // MARK: WordStar tags

    /// Markers <0>–<9> (and <B>/<K> for a half-marked block), drawn in the
    /// space above the line so they never move the words.
    private func drawWordStarTags() {
        guard let session, let ws = session.wordstar, ws.enabled, let lm = layoutManager, let tc = textContainer,
              let ts = textStorage, let m = session.manuscript else { return }
        let tags = ws.tags(in: chapterId)
        guard !tags.isEmpty else { return }
        let t = theme
        let font = NSFont.systemFont(ofSize: max(9, 10 * t.zoom), weight: .bold)
        for tag in tags {
            let loc = min(tag.loc, ts.length)
            let caret = m.localRect(self, NSRange(location: loc, length: 0))
            var top = caret.minY
            if ts.length > 0 {
                let gi = lm.glyphIndexForCharacter(at: min(loc, ts.length - 1))
                top = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil).minY + textContainerOrigin.y
            }
            _ = tc
            let label = tag.label as NSString
            let size = label.size(withAttributes: [.font: font])
            let w = size.width + 8
            let x = min(max(0, caret.minX - w / 2), bounds.maxX - w)   // whole, never clipped at the margin
            let box = NSRect(x: x, y: top, width: w, height: size.height + 1)
            (tag.label == "B" || tag.label == "K" ? NSColor(srgbRed: 0.36, green: 0.55, blue: 0.86, alpha: 0.95) : NEOColor.nsAccent).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            label.draw(at: NSPoint(x: box.minX + 4, y: box.minY + 0.5), withAttributes: [.font: font, .foregroundColor: NSColor(hex: 0x1C1C1C)])
        }
    }
}
