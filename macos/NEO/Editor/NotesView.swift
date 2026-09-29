import AppKit
import SwiftUI

/// The Notes tab's writing surface.
final class NotesTextView: ProseTextView {
    weak var session: BookSession?

    override func mouseDown(with event: NSEvent) {
        session?.pageClicked()
        session?.wordstar?.cancel()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), let ws = session?.wordstar, ws.handle(event, in: self) { return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if textStorage?.length == 0 {
            let t = theme
            ("Write freely…" as NSString).draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y + 2), withAttributes: [
                .font: t.font(italic: true, size: 16 * t.zoom, family: "Georgia"),
                .foregroundColor: t.placeholder
            ])
        }
    }
}

final class NotesPageView: NSView, NSTextViewDelegate {
    let session: BookSession
    private let scroll = PageScrollView()
    private let doc = MarginView()
    private let sheet = SheetView()
    private let heading = NSTextField(labelWithString: "")
    private let storage: NSTextStorage
    private let normalizer: StorageNormalizer
    let textView: NotesTextView

    init(session: BookSession) {
        self.session = session
        let (attr, _) = HTMLCodec.attributedString(fromHTML: LibraryStore.readAux(session.meta.id, "notes"), mode: .stored)
        storage = NSTextStorage(attributedString: attr)
        normalizer = StorageNormalizer(mode: .notes, theme: { [weak session] in session?.theme ?? .default })
        storage.delegate = normalizer
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        lm.addTextContainer(tc)
        textView = NotesTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), textContainer: tc)
        super.init(frame: .zero)

        textView.mode = .notes
        textView.session = session
        textView.themeProvider = { [weak session] in session?.theme ?? .default }
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 300)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.configureProse()
        textView.delegate = self
        textView.postsFrameChangedNotifications = true
        textView.isContinuousSpellCheckingEnabled = session.spellOn

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = doc
        scroll.onZoom = { [weak session] k in session?.app.zoom(by: k) }
        doc.onMarginClick = { [weak session] right in session?.marginClicked(right: right) }
        doc.pageMidX = { [weak self] in
            guard let self else { return 0 }
            return self.doc.bounds.midX - (self.session.sidePinned ? 125 : 0)
        }
        addSubview(scroll)
        doc.addSubview(sheet)
        sheet.addSubview(heading)
        sheet.addSubview(textView)
        NotificationCenter.default.addObserver(self, selector: #selector(relayout), name: NSView.frameDidChangeNotification, object: textView)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }

    func applyTheme() {
        let t = session.theme
        sheet.theme = t
        ProseStyler.styleAll(storage, theme: t, mode: .notes)
        textView.applyThemeColors()
        textView.isContinuousSpellCheckingEnabled = session.spellOn
        heading.attributedStringValue = NSAttributedString(string: session.meta.notesTabName.uppercased(), attributes: [
            .font: NSFont(name: "Georgia", size: 14) ?? .systemFont(ofSize: 14), .kern: 3,
            .foregroundColor: t.night ? NSColor(hex: 0x918B7D) : NSColor(hex: 0x777777),
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()
        ])
        heading.alignment = .center
        relayout()
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        relayout()
    }

    @objc func relayout() {
        let avail = scroll.contentSize.width
        guard avail > 0 else { return }
        let t = session.theme
        let w = floor(min(680 * t.zoom, avail * 0.92))
        let x = max(8, floor((avail - w) / 2) - (session.sidePinned ? 125 : 0))
        scroll.pageWidth = w
        scroll.pageShift = session.sidePinned ? 125 : 0
        heading.frame = NSRect(x: 72, y: 70, width: w - 144, height: 20)
        let tw = w - 144
        if abs(textView.frame.width - tw) > 0.5 { textView.setFrameSize(NSSize(width: tw, height: textView.frame.height)) }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = max(scroll.contentSize.height * 0.5, textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0)
        if abs(textView.frame.height - used) > 0.5 { textView.setFrameSize(NSSize(width: tw, height: used)) }
        textView.setFrameOrigin(NSPoint(x: 72, y: 130))
        let h = max(scroll.contentSize.height * 0.85, 130 + textView.frame.height + 90)
        sheet.frame = NSRect(x: x, y: 40, width: w, height: h)
        doc.frame = NSRect(x: 0, y: 0, width: avail, height: 40 + h + 120)
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) {
        session.saveNotes(HTMLCodec.html(from: storage))
    }

    func undoManager(for view: NSTextView) -> UndoManager? { window?.undoManager }
}


struct NotesHost: NSViewRepresentable {
    let session: BookSession
    let themeKey: PageTheme

    func makeNSView(context: Context) -> NotesPageView {
        let v = NotesPageView(session: session)
        DispatchQueue.main.async { v.focus() }
        return v
    }

    func updateNSView(_ v: NotesPageView, context: Context) {
        v.applyTheme()
    }
}
