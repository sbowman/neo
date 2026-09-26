import AppKit
import SwiftUI

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Scrolls the page; a pinch or Ctrl+scroll zooms it instead.
final class PageScrollView: NSScrollView {
    var onZoom: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onZoom?(exp(-event.scrollingDeltaY * 0.005))
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification)
    }
}

/// A sheet of paper.
class SheetView: NSView {
    var theme: PageTheme = .default { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.55
        layer?.shadowRadius = 15
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        theme.paper.setFill()
        bounds.fill()
        if let b = theme.sheetBorder {
            b.setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
        }
    }
}

/// A borderless, backgroundless text field for the title page and headings.
final class PageField: NSTextField {
    var onEnter: (() -> Void)?
    var onChange: ((String) -> Void)?
    var onEndEditing: ((String) -> Void)?

    convenience init(placeholder: String) {
        self.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        alignment = .center
        cell?.wraps = true
        cell?.isScrollable = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        placeholderString = placeholder
    }
}

// MARK: - Title page

final class TitleSheetView: SheetView, NSTextFieldDelegate {
    let title = PageField(placeholder: "Untitled")
    let subtitle = PageField(placeholder: "Subtitle (optional)")
    let author = PageField(placeholder: "Author")
    weak var session: BookSession?

    init(session: BookSession) {
        self.session = session
        super.init(frame: .zero)
        for f in [title, subtitle, author] {
            f.delegate = self
            addSubview(f)
        }
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    func load() {
        guard let m = session?.meta else { return }
        title.stringValue = m.title == "Untitled" ? "" : m.title
        subtitle.stringValue = m.subtitle
        author.stringValue = m.author
    }

    func applyTheme(_ t: PageTheme) {
        theme = t
        let ph = t.placeholder
        func style(_ f: PageField, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0, placeholder: String) {
            f.font = font
            f.textColor = color
            f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask),
                .foregroundColor: ph, .kern: kern,
                .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()
            ])
        }
        style(title, t.font(bold: true, size: 34 * t.zoom), t.ink, placeholder: "Untitled")
        style(subtitle, t.font(italic: true, size: 17), t.subtitle, placeholder: "Subtitle (optional)")
        style(author, NSFont(name: "Georgia", size: 14) ?? .systemFont(ofSize: 14), t.authorInk, kern: 3, placeholder: "Author")
        needsLayout = true
    }

    private func height(_ f: NSTextField, _ w: CGFloat) -> CGFloat {
        let text = f.stringValue.isEmpty ? (f.placeholderString ?? " ") : f.stringValue
        let r = (text as NSString).boundingRect(with: NSSize(width: w, height: 10_000),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: [.font: f.font ?? NSFont.systemFont(ofSize: 14)])
        return ceil(r.height) + 6
    }

    override func layout() {
        super.layout()
        let w = bounds.width - 144
        let hs = [height(title, w), height(subtitle, w), height(author, w)]
        let total = hs[0] + 14 + hs[1] + 46 + hs[2]
        var y = max(70, (bounds.height - total) / 2)
        title.frame = NSRect(x: 72, y: y, width: w, height: hs[0]); y += hs[0] + 14
        subtitle.frame = NSRect(x: 72, y: y, width: w, height: hs[1]); y += hs[1] + 46
        author.frame = NSRect(x: 72, y: y, width: w, height: hs[2])
    }

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField, let s = session else { return }
        if f === title { s.setTitle(f.stringValue) }
        else if f === subtitle { s.setSubtitle(f.stringValue) }
        else if f === author { s.setAuthor(f.stringValue) }
        needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if control === author { window?.makeFirstResponder(nil) } else { session?.titleEnter() }
            return true
        }
        return false
    }
}

// MARK: - Chapter heading

final class ChapterHeadingView: NSView, NSTextFieldDelegate {
    let number = NSTextField(labelWithString: "")
    let sep = NSTextField(labelWithString: "—")
    let titleField = PageField(placeholder: "add a title")
    let chId: String
    weak var session: BookSession?
    private var hovering = false { didSet { refreshVisibility() } }

    init(chId: String, session: BookSession) {
        self.chId = chId
        self.session = session
        super.init(frame: .zero)
        titleField.delegate = self
        number.lineBreakMode = .byClipping
        number.cell?.wraps = false
        titleField.alignment = .left
        titleField.cell?.wraps = false
        titleField.cell?.isScrollable = true
        titleField.maximumNumberOfLines = 1
        titleField.stringValue = session.meta.chapterTitles[chId] ?? ""
        toolTip = "Right-click for chapter options · click after the number to add a title"
        for v in [number, sep, titleField] { addSubview(v) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(index: Int, theme t: PageTheme) {
        let font = NSFont(name: "Georgia", size: 15 * t.zoom) ?? .systemFont(ofSize: 15)
        number.attributedStringValue = NSAttributedString(string: "CHAPTER \(index + 1)", attributes: [.font: font, .kern: 4, .foregroundColor: t.heading])
        sep.font = font
        sep.textColor = t.heading
        titleField.font = font
        titleField.textColor = t.heading
        titleField.placeholderAttributedString = NSAttributedString(string: "add a title", attributes: [
            .font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), .foregroundColor: t.placeholder, .kern: 1
        ])
        refreshVisibility()
        needsLayout = true
    }

    private func refreshVisibility() {
        let has = !titleField.stringValue.isEmpty || window?.firstResponder === titleField.currentEditor()
        sep.alphaValue = has || hovering ? 0.6 : 0
        titleField.alphaValue = has || hovering ? 1 : 0.02
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func layout() {
        super.layout()
        let h = bounds.height
        let nw = ceil(number.attributedStringValue.size().width) + 10
        let sw = ceil(sep.intrinsicContentSize.width)
        let text = titleField.stringValue.isEmpty ? "add a title" : titleField.stringValue
        let tw = min(bounds.width * 0.6, ceil((text as NSString).size(withAttributes: [.font: titleField.font!]).width) + 24)
        let total = nw + 10 + sw + 10 + tw
        var x = max(0, (bounds.width - total) / 2)
        number.frame = NSRect(x: x, y: 0, width: nw, height: h); x += nw + 10
        sep.frame = NSRect(x: x, y: 0, width: sw, height: h); x += sw + 10
        titleField.frame = NSRect(x: x, y: 0, width: tw, height: h)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        session?.chapterMenu(chId)
        return nil
    }

    func controlTextDidChange(_ n: Notification) {
        needsLayout = true
        refreshVisibility()
    }

    func controlTextDidEndEditing(_ n: Notification) {
        session?.setChapterTitle(chId, titleField.stringValue)
        refreshVisibility()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            session?.setChapterTitle(chId, titleField.stringValue)
            session?.manuscript?.focusChapterStart(chId)
            return true
        }
        return false
    }
}

// MARK: - Chapter sheet

final class ChapterSheetView: SheetView {
    let chId: String
    let heading: ChapterHeadingView
    let textView: ChapterTextView
    var solo = false

    init(chapter: Chapter, session: BookSession, width: CGFloat) {
        chId = chapter.id
        heading = ChapterHeadingView(chId: chapter.id, session: session)
        textView = ChapterTextView(chapterId: chapter.id, session: session, storage: chapter.storage, width: width)
        super.init(frame: .zero)
        addSubview(heading)
        addSubview(textView)
        textView.postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) { fatalError() }

    static let pad = (top: CGFloat(70), side: CGFloat(72), bottom: CGFloat(90))

    /// Lays the sheet out at a width and returns its height.
    func place(width: CGFloat, minHeight: CGFloat) -> CGFloat {
        let p = ChapterSheetView.pad
        var y = p.top
        heading.isHidden = solo
        if !solo {
            let hh = ceil(15 * theme.zoom * 1.6)
            heading.frame = NSRect(x: p.side, y: y, width: width - 2 * p.side, height: hh)
            y += hh + 44
        }
        let tw = max(100, width - 2 * p.side)
        if abs(textView.frame.width - tw) > 0.5 {
            textView.setFrameSize(NSSize(width: tw, height: textView.frame.height))
        }
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            var used = lm.usedRect(for: tc).height
            used = max(used, ProseStyler.lineHeight(theme, .chapter))
            if abs(textView.frame.height - used) > 0.5 { textView.setFrameSize(NSSize(width: tw, height: used)) }
        }
        textView.setFrameOrigin(NSPoint(x: p.side, y: y))
        y += textView.frame.height + p.bottom
        return max(minHeight, y)
    }

    /// A click on the paper around the words puts the caret in them.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(textView)
        let len = textView.textStorage?.length ?? 0
        textView.setSelectedRange(NSRange(location: p.y < textView.frame.minY ? 0 : len, length: 0))
    }
}

// MARK: - The manuscript

/// The title page and every chapter, each on its own sheet, on one scroll.
final class ManuscriptView: NSView, NSTextViewDelegate {
    let session: BookSession
    let scroll = PageScrollView()
    private let doc = FlippedView()
    let titleSheet: TitleSheetView
    private var sheets: [String: ChapterSheetView] = [:]
    private var order: [String] = []
    var lastSearchedQuery = ""
    private var highlighted: Set<String> = []
    private var scrollTimer: DispatchWorkItem?
    private var laidOutWidth: CGFloat = 0

    init(session: BookSession) {
        self.session = session
        titleSheet = TitleSheetView(session: session)
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = doc
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.onZoom = { [weak self] k in self?.session.app.zoom(by: k) }
        addSubview(scroll)
        doc.addSubview(titleSheet)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(textFrameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: nil)
        applyTheme()
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var theme: PageTheme { session.theme }

    // MARK: Structure

    /// Brings the sheets in line with the chapter order, reusing every sheet
    /// that still has a chapter.
    func rebuild() {
        let ids = session.meta.chapterOrder
        for (id, sheet) in sheets where !ids.contains(id) {
            sheet.textView.detach()
            sheet.removeFromSuperview()
            sheets[id] = nil
        }
        let w = max(100, pageWidth - 144)
        for ch in session.chapters where sheets[ch.id] == nil {
            let sheet = ChapterSheetView(chapter: ch, session: session, width: w)
            sheet.textView.delegate = self
            sheet.textView.isContinuousSpellCheckingEnabled = session.spellOn
            sheets[ch.id] = sheet
            doc.addSubview(sheet)
        }
        order = ids
        for (i, id) in ids.enumerated() {
            guard let s = sheets[id] else { continue }
            s.theme = theme
            s.solo = ids.count == 1
            s.heading.configure(index: i, theme: theme)
            s.textView.updateDropCap()
        }
        layoutSheets()
    }

    func applyTheme() {
        let t = theme
        titleSheet.applyTheme(t)
        for (i, id) in order.enumerated() {
            guard let s = sheets[id] else { continue }
            s.theme = t
            s.heading.configure(index: i, theme: t)
            s.textView.applyThemeColors()
            s.textView.updateDropCap()
            s.textView.needsDisplay = true
        }
        layoutSheets()
    }

    func reloadTitlePage() { titleSheet.load(); titleSheet.needsLayout = true }

    // MARK: Layout

    private var pageWidth: CGFloat {
        let avail = scroll.contentSize.width > 0 ? scroll.contentSize.width : 900
        return floor(min(680 * theme.zoom, avail * 0.92))
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        if abs(laidOutWidth - bounds.width) > 0.5 { layoutSheets() }
    }

    @objc private func textFrameChanged(_ n: Notification) {
        guard let tv = n.object as? ChapterTextView, sheets[tv.chapterId]?.textView === tv else { return }
        DispatchQueue.main.async { [weak self] in self?.layoutSheets() }
    }

    private var inLayout = false

    func layoutSheets() {
        guard !inLayout else { return }
        inLayout = true
        defer { inLayout = false }
        laidOutWidth = bounds.width
        let avail = scroll.contentSize.width
        guard avail > 0 else { return }
        let visH = scroll.contentSize.height
        let w = pageWidth
        let shift: CGFloat = session.sidePinned ? 125 : 0
        let x = max(8, floor((avail - w) / 2) - shift)
        let minH = floor(visH * 0.88)
        var y: CGFloat = 40
        titleSheet.frame = NSRect(x: x, y: y, width: w, height: minH)
        y += minH + 44
        for id in order {
            guard let s = sheets[id] else { continue }
            let h = s.place(width: w, minHeight: minH)
            s.frame = NSRect(x: x, y: y, width: w, height: h)
            y += h + 44
        }
        let bottom = session.app.library.typewriter ? visH * 0.6 : 76
        doc.frame = NSRect(x: 0, y: 0, width: avail, height: max(visH, y + bottom))
    }

    // MARK: Scrolling

    var scrollOffset: CGFloat {
        get { scroll.contentView.bounds.origin.y }
        set {
            layoutSheets()
            let maxY = max(0, doc.frame.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, newValue), maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @objc private func scrolled() {
        scrollTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.trackChapter() }
        scrollTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    /// Which chapter the writer is looking at: the last one whose top is
    /// above 40% of the view.
    private func trackChapter() {
        let mark = scroll.contentView.bounds.minY + scroll.contentSize.height * 0.4
        var best: String? = nil
        for id in order { if let s = sheets[id], s.frame.minY < mark { best = id } }
        if let best { session.scrolledTo(best) }
    }

    private func rect(of range: NSRange, in tv: ChapterTextView) -> NSRect {
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let ts = tv.textStorage else { return tv.bounds }
        var r: NSRect
        if ts.length == 0 {
            r = NSRect(x: 0, y: 0, width: 1, height: ProseStyler.lineHeight(theme, .chapter))
        } else if range.location >= ts.length && lm.extraLineFragmentTextContainer != nil {
            r = lm.extraLineFragmentRect
        } else {
            let loc = min(range.location, ts.length - 1)
            let gr = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: max(1, min(range.length, ts.length - loc))),
                                   actualCharacterRange: nil)
            r = lm.boundingRect(forGlyphRange: gr, in: tc)
        }
        r.origin.x += tv.textContainerOrigin.x
        r.origin.y += tv.textContainerOrigin.y
        return tv.convert(r, to: doc)
    }

    /// Scroll so a range sits a little above the middle of the view.
    func center(_ chId: String, _ range: NSRange, at fraction: CGFloat = 0.45, animated: Bool = false) {
        guard let tv = sheets[chId]?.textView else { return }
        let r = rect(of: range, in: tv)
        let target = r.midY - scroll.contentSize.height * fraction
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: min(max(0, target), max(0, doc.frame.height - scroll.contentSize.height))))
            } completionHandler: { [weak self] in
                guard let self else { return }
                self.scroll.reflectScrolledClipView(self.scroll.contentView)
            }
        } else {
            scrollOffset = target
        }
    }

    func reveal(_ chId: String, _ range: NSRange, select: Bool) {
        guard let tv = sheets[chId]?.textView, let len = tv.textStorage?.length else { return }
        let r = NSRange(location: min(range.location, len), length: min(range.length, len - min(range.location, len)))
        layoutSheets()
        if select {
            window?.makeFirstResponder(tv)
            tv.setSelectedRange(r)
        }
        center(chId, r, animated: true)
    }

    // MARK: Focus

    func textView(_ chId: String) -> ChapterTextView? { sheets[chId]?.textView }

    func activeTextView() -> ChapterTextView? {
        guard let tv = window?.firstResponder as? ChapterTextView, sheets[tv.chapterId]?.textView === tv else { return nil }
        return tv
    }

    func focusTitle() {
        window?.makeFirstResponder(titleSheet.title)
    }

    func focusCurrent() {
        if let id = session.currentChapterId, let tv = textView(id) { window?.makeFirstResponder(tv) }
    }

    func focusChapterEnd(_ chId: String, scroll toTop: Bool = true) {
        guard let s = sheets[chId] else { return }
        layoutSheets()
        window?.makeFirstResponder(s.textView)
        s.textView.setSelectedRange(NSRange(location: s.textView.textStorage?.length ?? 0, length: 0))
        session.currentChapterId = chId
        if toTop {
            let target = s.frame.minY - 20
            let visible = scroll.contentView.bounds
            if s.frame.minY < visible.minY || s.frame.minY > visible.maxY - 100 { scrollOffset = target }
            let caret = rect(of: s.textView.selectedRange(), in: s.textView)
            if !scroll.contentView.bounds.contains(NSPoint(x: caret.midX, y: caret.maxY)) {
                center(chId, s.textView.selectedRange())
            }
        }
    }

    func focusChapterStart(_ chId: String) {
        guard let s = sheets[chId] else { return }
        layoutSheets()
        window?.makeFirstResponder(s.textView)
        s.textView.setSelectedRange(NSRange(location: 0, length: 0))
        session.currentChapterId = chId
        let visible = scroll.contentView.bounds
        let caret = rect(of: NSRange(location: 0, length: 0), in: s.textView)
        if !visible.contains(NSPoint(x: caret.midX, y: caret.midY)) { center(chId, NSRange(location: 0, length: 0)) }
    }

    /// On open: the caret goes to the first line in view, without moving the page.
    func focusChapterNear(_ chId: String) {
        guard let s = sheets[chId] else { return }
        let topInView = scroll.contentView.bounds.minY + 80
        let pt = s.textView.convert(NSPoint(x: 10, y: topInView), from: doc)
        let idx = s.textView.characterIndexForInsertion(at: NSPoint(x: max(0, pt.x), y: max(0, pt.y)))
        let keep = scrollOffset
        window?.makeFirstResponder(s.textView)
        s.textView.setSelectedRange(NSRange(location: min(idx, s.textView.textStorage?.length ?? 0), length: 0))
        scrollOffset = keep
    }

    func captureCaret() -> Caret? {
        guard let tv = activeTextView(), let ts = tv.textStorage else { return nil }
        let s = ts.string as NSString
        let loc = tv.selectedRange().location
        let p = Prose.paragraph(s, at: loc)
        return Caret(chId: tv.chapterId, pIdx: Prose.paragraphIndex(s, at: loc), off: loc - p.location, scroll: scrollOffset)
    }

    func restoreCaret(_ c: Caret) {
        guard let tv = textView(c.chId), let ts = tv.textStorage else { return }
        layoutSheets()
        let paras = Prose.paragraphs(ts.string as NSString)
        let p = paras[min(c.pIdx, paras.count - 1)]
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: p.location + min(c.off, p.length), length: 0))
        session.currentChapterId = c.chId
        if let s = c.scroll { scrollOffset = s }
    }

    // MARK: Search and spelling

    func clearSearchHighlights() {
        for id in highlighted {
            guard let tv = textView(id), let lm = tv.layoutManager, let ts = tv.textStorage else { continue }
            let all = NSRange(location: 0, length: ts.length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        }
        highlighted = []
    }

    func highlightSearch(_ matches: [(chId: String, range: NSRange)], current: Int?) {
        clearSearchHighlights()
        for (i, m) in matches.enumerated() {
            guard let tv = textView(m.chId), let lm = tv.layoutManager, let len = tv.textStorage?.length,
                  NSMaxRange(m.range) <= len else { continue }
            if i == current {
                lm.addTemporaryAttributes([.backgroundColor: NEOColor.nsAccent, .foregroundColor: NSColor(hex: 0x1C1C1C)],
                                          forCharacterRange: m.range)
            } else {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor(hex: 0xC9A86A, alpha: 0.35), forCharacterRange: m.range)
            }
            highlighted.insert(m.chId)
        }
    }

    func setSpellcheck(_ on: Bool) {
        let words = session.app.library.customWords
        for s in sheets.values {
            let tv = s.textView
            if on { NSSpellChecker.shared.setIgnoredWords(words, inSpellDocumentWithTag: tv.spellCheckerDocumentTag) }
            tv.isContinuousSpellCheckingEnabled = on
            tv.needsDisplay = true
        }
    }

    func refreshSpelling(_ chId: String) {}

    // MARK: Typewriter scrolling

    private func typewriter(_ tv: ChapterTextView) {
        guard session.app.library.typewriter, session.tab == .manuscript, tv.selectedRange().length == 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let r = self.rect(of: tv.selectedRange(), in: tv)
            let diff = r.midY - (self.scroll.contentView.bounds.minY + self.scroll.contentSize.height * 0.45)
            if abs(diff) > 6 { self.scrollOffset = self.scrollOffset + diff }
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ n: Notification) {
        guard let tv = n.object as? ChapterTextView else { return }
        session.chapterEdited(tv.chapterId)
        tv.updateDropCap()
        typewriter(tv)
    }

    func textViewDidChangeSelection(_ n: Notification) {
        guard let tv = n.object as? ChapterTextView, window?.firstResponder === tv else { return }
        session.selectionChanged(tv)
        tv.updateDropCap()
        typewriter(tv)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if let tv = textView as? ChapterTextView, replacementString != nil {
            session.willChange(tv.chapterId, range)
        }
        return true
    }

    func undoManager(for view: NSTextView) -> UndoManager? { window?.undoManager }
}

/// SwiftUI host for the manuscript page. The view is made once per open book
/// and kept alive (hidden) while other tabs are showing.
struct ManuscriptHost: NSViewRepresentable {
    let session: BookSession

    func makeNSView(context: Context) -> ManuscriptView {
        let v = ManuscriptView(session: session)
        session.manuscript = v
        DispatchQueue.main.async { session.didAttachManuscript() }
        return v
    }

    func updateNSView(_ v: ManuscriptView, context: Context) {
        v.isHidden = session.tab != .manuscript
        _ = session.sidePinned   // the page steps left of a pinned notes pane
        v.layoutSheets()
    }
}
