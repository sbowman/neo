import AppKit

/// WordStar 7's cursor, marker and block keys, for writers whose fingers never
/// forgot them. Control-key commands only; everything else stays macOS.
///
///     ^E ^X ^S ^D   up / down a line, left / right a character
///     ^A ^F         left / right a word
///     ^R ^C         up / down a screen          ^W ^Z  scroll a line
///     ^QE ^QX       top / bottom of the screen  ^QS ^QD  start / end of the line
///     ^QR ^QC       start / end of the book     ^QB ^QK  start / end of the block
///     ^QG c ^QH c   next / previous character c ^QV    last find, or the block
///     ^QW ^QZ       scroll continuously up / down (any key stops)
///     ^QP           where the cursor was before the last command
///     ^QL           next misspelling after the cursor
///     ^Q0–^Q9       go to marker            ^K0–^K9  set marker (again: remove it)
///     ^KB ^KK       mark block start / end  ^KH      hide / show block and markers
///     ^KC ^KV ^KW   copy / move / write the block
///
/// Positions (block ends, markers, the previous position) ride along with
/// edits, so they stay on the same words as the writer types.
@MainActor
final class WordStar {
    struct Spot: Equatable {
        var chId: String
        var loc: Int
    }

    private enum Pending { case q, k, qg, qh }

    unowned let session: BookSession
    private var pending: Pending?
    private(set) var hidden = false
    private var scrollTimer: Timer?

    /// Every remembered position, by name: "B" and "K" (the block), "0"–"9"
    /// (markers), "P" (before the last command), "V" (the last find).
    private var slots: [String: Spot] = [:]

    private(set) var blockBegin: Spot? { get { slots["B"] } set { slots["B"] = newValue } }
    private(set) var blockEnd: Spot? { get { slots["K"] } set { slots["K"] = newValue } }
    private var previous: Spot? { get { slots["P"] } set { slots["P"] = newValue } }
    var lastFind: Spot? { get { slots["V"] } set { slots["V"] = newValue } }
    private func marker(_ n: Int) -> Spot? { slots["\(n)"] }
    private func setMarker(_ n: Int, _ s: Spot?) { slots["\(n)"] = s }

    init(session: BookSession) { self.session = session }

    var enabled: Bool { session.app.library.wordstarKeys }
    private var app: AppModel { session.app }
    private var manuscript: ManuscriptView? { session.manuscript }

    // MARK: - Keys

    /// Offered every key press in a chapter or the notes; true when it was a
    /// WordStar command (or the second half of one).
    func handle(_ e: NSEvent, in tv: ProseTextView) -> Bool {
        guard enabled else { return false }
        if scrollTimer != nil { stopScrolling(); return true }
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        let key = (e.charactersIgnoringModifiers ?? "").lowercased()

        if let p = pending {
            guard !mods.contains(.command), !mods.contains(.option) else { cancel(); return false }
            pending = nil
            clearPrompt()
            switch p {
            case .q: quick(key, tv)
            case .k: block(key, tv)
            case .qg, .qh:
                if let c = e.characters, !c.isEmpty { findChar(c == "\r" ? "\n" : c, forward: p == .qg, tv) }
            }
            return true
        }

        guard mods == .control, key.count == 1 else { return false }
        let chapter = tv as? ChapterTextView
        switch key {
        case "e": if let c = chapter { lineMove(up: true, c) } else { tv.moveUp(nil) }
        case "x": if let c = chapter { lineMove(up: false, c) } else { tv.moveDown(nil) }
        case "s": charMove(left: true, tv)
        case "d": charMove(left: false, tv)
        case "a": wordMove(left: true, tv)
        case "f": wordMove(left: false, tv)
        case "r": if let c = chapter { screenMove(up: true, c) } else { tv.pageUp(nil) }
        case "c": if let c = chapter { screenMove(up: false, c) } else { tv.pageDown(nil) }
        case "w": if let c = chapter { scrollLine(up: true, c) } else { tv.scrollLineUp(nil) }
        case "z": if let c = chapter { scrollLine(up: false, c) } else { tv.scrollLineDown(nil) }
        case "q": pending = .q; prompt("^Q")
        case "k": pending = .k; prompt("^K")
        default: return false
        }
        return true
    }

    /// Esc (or a click) abandons a half-typed ^Q or ^K.
    @discardableResult
    func cancel() -> Bool {
        let had = pending != nil || scrollTimer != nil
        pending = nil
        stopScrolling()
        clearPrompt()
        return had
    }

    private var promptText: String?

    private func prompt(_ s: String) {
        let text = s == "^Q"
            ? "^Q  —  E X S D R C B K P V G H W Z L, or 0–9 for a marker"
            : "^K  —  B K H C V W, or 0–9 to set a marker"
        promptText = text
        app.showToast(text, seconds: 30)
    }

    private func clearPrompt() {
        if let p = promptText, app.toast == p { app.toast = nil }
        promptText = nil
    }

    private func say(_ s: String) { app.showToast(s) }

    // MARK: - ^Q

    private func quick(_ key: String, _ tv: ProseTextView) {
        guard let c = tv as? ChapterTextView else {
            // the notes have no chapters, blocks or markers — just the simple moves
            switch key {
            case "s": tv.moveToBeginningOfLine(nil)
            case "d": tv.moveToEndOfLine(nil)
            case "r": tv.moveToBeginningOfDocument(nil)
            case "c": tv.moveToEndOfDocument(nil)
            default: say("That WordStar command works in the manuscript")
            }
            return
        }
        switch key {
        case "e": remember(); edgeOfScreen(top: true, c)
        case "x": remember(); edgeOfScreen(top: false, c)
        case "s": c.moveToBeginningOfLine(nil)
        case "d": c.moveToEndOfLine(nil)
        case "r":
            guard let first = session.meta.chapterOrder.first else { return }
            remember(); go(Spot(chId: first, loc: 0))
        case "c":
            guard let last = session.meta.chapterOrder.last, let ch = session.chapter(last) else { return }
            remember(); go(Spot(chId: last, loc: ch.storage.length))
        case "b":
            guard let b = blockBegin else { say("No block beginning — ^KB marks one"); return }
            remember(); go(b)
        case "k":
            guard let k = blockEnd else { say("No block end — ^KK marks one"); return }
            remember(); go(k)
        case "v":
            guard let v = lastFind ?? blockBegin else { say("Nothing found or marked yet"); return }
            remember(); go(v)
        case "p":
            guard let p = previous else { say("No previous position yet"); return }
            let here = caretSpot()
            go(p)
            previous = here
        case "g": pending = .qg; promptText = "^QG  —  type the character to find"; app.showToast(promptText!, seconds: 30)
        case "h": pending = .qh; promptText = "^QH  —  type the character to find"; app.showToast(promptText!, seconds: 30)
        case "w": startScrolling(up: true)
        case "z": startScrolling(up: false)
        case "l": findMisspelling(after: c)
        default:
            if let n = Int(key) {
                guard let m = marker(n) else { say("Marker \(n) isn’t set — ^K\(n) sets it"); return }
                remember(); go(m)
            }
        }
    }

    // MARK: - ^K

    private func block(_ key: String, _ tv: ProseTextView) {
        guard let c = tv as? ChapterTextView else {
            say("Blocks and markers work in the manuscript")
            return
        }
        let here = Spot(chId: c.chapterId, loc: c.selectedRange().location)
        switch key {
        case "b":
            blockBegin = here
            hidden = false
            changed()
        case "k":
            blockEnd = here
            hidden = false
            changed()
        case "h":
            hidden.toggle()
            changed()
            say(hidden ? "Block and markers hidden — ^KH shows them" : "Block and markers shown")
        case "c": copyBlock(to: here)
        case "v": moveBlock(to: here)
        case "w": writeBlock()
        default:
            if let n = Int(key) {
                if marker(n) == here {
                    setMarker(n, nil)
                    say("Marker \(n) removed")
                } else {
                    setMarker(n, here)
                    hidden = false
                    say("Marker \(n) set — ^Q\(n) comes back here")
                }
                changed()
            }
        }
    }

    /// The block, if one is marked, shown, and within a single chapter.
    private func markedBlock() -> (chId: String, range: NSRange)? {
        guard let b = blockBegin, let k = blockEnd else { say("No block — mark one with ^KB and ^KK"); return nil }
        guard !hidden else { say("The block is hidden — ^KH shows it"); return nil }
        guard b.chId == k.chId else { say("A block has to begin and end in the same chapter"); return nil }
        guard b.loc < k.loc, let ch = session.chapter(b.chId), k.loc <= ch.storage.length else {
            say("The block’s end comes before its beginning"); return nil
        }
        return (b.chId, NSRange(location: b.loc, length: k.loc - b.loc))
    }

    private func copyBlock(to here: Spot) {
        guard let (chId, r) = markedBlock(), let src = session.chapter(chId) else { return }
        if here.chId == chId && here.loc > r.location && here.loc < NSMaxRange(r) {
            say("The cursor is inside the block"); return
        }
        remember()
        let piece = src.storage.attributedSubstring(from: r)
        session.edit(here.chId, NSRange(location: here.loc, length: 0), piece, actionName: "Copy Block")
        // the copy becomes the block, and the cursor waits at its start
        blockBegin = Spot(chId: here.chId, loc: here.loc)
        blockEnd = Spot(chId: here.chId, loc: here.loc + piece.length)
        go(here, reveal: false)
        changed()
    }

    private func moveBlock(to here: Spot) {
        guard let (chId, r) = markedBlock(), let src = session.chapter(chId), let dst = session.chapter(here.chId) else { return }
        if here.chId == chId && here.loc >= r.location && here.loc <= NSMaxRange(r) {
            say("The cursor is inside the block"); return
        }
        remember()
        session.snapshot("block move")
        let piece = src.storage.attributedSubstring(from: r)
        src.storage.replaceCharacters(in: r, with: "")
        var at = here.loc
        if here.chId == chId && at > r.location { at -= r.length }
        at = min(at, dst.storage.length)
        dst.storage.replaceCharacters(in: NSRange(location: at, length: 0), with: piece)
        session.chapterEdited(chId)
        if here.chId != chId { session.chapterEdited(here.chId) }
        session.reconcileMarks()
        blockBegin = Spot(chId: here.chId, loc: at)
        blockEnd = Spot(chId: here.chId, loc: at + piece.length)
        go(Spot(chId: here.chId, loc: at), reveal: false)
        session.resetNativeUndo()
        session.breakRun += 1
        changed()
    }

    private func writeBlock() {
        guard let (chId, r) = markedBlock(), let ch = session.chapter(chId) else { return }
        let text = Prose.plainText(ch.storage.attributedSubstring(from: r))
        Task { await app.saveText(text, suggestedName: "Block") }
    }

    // MARK: - Moving the caret

    func caretSpot() -> Spot? {
        guard let tv = manuscript?.activeTextView() else { return nil }
        return Spot(chId: tv.chapterId, loc: tv.selectedRange().location)
    }

    /// Before a jump: remember where the cursor is, for ^QP.
    func remember() {
        if let s = caretSpot() { previous = s }
    }

    private func go(_ s: Spot, reveal: Bool = true) {
        guard let m = manuscript, let tv = m.textView(s.chId), let len = tv.textStorage?.length else { return }
        let loc = min(s.loc, len)
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        session.currentChapterId = s.chId
        if reveal { m.ensureVisible(s.chId, NSRange(location: loc, length: 0)) }
    }

    private func neighbour(_ chId: String, _ step: Int) -> String? {
        let order = session.meta.chapterOrder
        guard let i = order.firstIndex(of: chId), order.indices.contains(i + step) else { return nil }
        return order[i + step]
    }

    private func charMove(left: Bool, _ tv: ProseTextView) {
        let sel = tv.selectedRange()
        let len = tv.textStorage?.length ?? 0
        if let c = tv as? ChapterTextView, sel.length == 0 {
            if left && sel.location == 0, let p = neighbour(c.chapterId, -1), let pc = session.chapter(p) {
                go(Spot(chId: p, loc: pc.storage.length)); return
            }
            if !left && sel.location >= len, let n = neighbour(c.chapterId, 1) {
                go(Spot(chId: n, loc: 0)); return
            }
        }
        if left { tv.moveLeft(nil) } else { tv.moveRight(nil) }
    }

    /// WordStar words: ^F lands on the start of the next word, ^A on the start
    /// of this one (or the one before).
    private func wordMove(left: Bool, _ tv: ProseTextView) {
        guard let s = tv.textStorage?.string as NSString? else { return }
        let space = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{2028}\u{2003}"))
        func isSpace(_ i: Int) -> Bool {
            guard let u = Unicode.Scalar(s.character(at: i)) else { return false }
            return space.contains(u)
        }
        var i = tv.selectedRange().location
        let len = s.length
        if let c = tv as? ChapterTextView {
            if left && i == 0, let p = neighbour(c.chapterId, -1), let pc = session.chapter(p) {
                go(Spot(chId: p, loc: pc.storage.length)); return
            }
            if !left && i >= len, let n = neighbour(c.chapterId, 1) { go(Spot(chId: n, loc: 0)); return }
        }
        if left {
            while i > 0 && isSpace(i - 1) { i -= 1 }
            while i > 0 && !isSpace(i - 1) { i -= 1 }
        } else {
            while i < len && !isSpace(i) { i += 1 }
            while i < len && isSpace(i) { i += 1 }
        }
        tv.setSelectedRange(NSRange(location: i, length: 0))
        tv.scrollRangeToVisible(NSRange(location: i, length: 0))
    }

    /// Up and down a line; at a chapter's edge the cursor carries on into the
    /// next chapter, as if the book were one long document.
    private func lineMove(up: Bool, _ tv: ChapterTextView) {
        guard let m = manuscript, let lm = tv.layoutManager, let tc = tv.textContainer, let ts = tv.textStorage else { return }
        let loc = tv.selectedRange().location
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let line = m.localRect(tv, NSRange(location: loc, length: 0))
        let atTop = line.minY <= used.minY + 1
        let atBottom = line.maxY >= used.maxY - 1 || ts.length == 0
        if up && atTop, let p = neighbour(tv.chapterId, -1), let prev = m.textView(p) {
            if let s = m.spot(atLocal: NSPoint(x: line.midX, y: prev.bounds.maxY - 4), in: p) { go(s) }
            return
        }
        if !up && atBottom, let n = neighbour(tv.chapterId, 1) {
            if let s = m.spot(atLocal: NSPoint(x: line.midX, y: 4), in: n) { go(s) }
            return
        }
        if up { tv.moveUp(nil) } else { tv.moveDown(nil) }
    }

    /// A screen at a time, the page and the cursor moving together.
    private func screenMove(up: Bool, _ tv: ChapterTextView) {
        guard let m = manuscript else { return }
        remember()
        let caret = m.docRect(tv.chapterId, tv.selectedRange())
        let visible = m.visibleDocRect
        let step = max(80, visible.height - 3 * m.lineHeight)
        let dy = up ? -step : step
        let before = m.scrollOffset
        m.scrollOffset = before + dy
        let moved = m.scrollOffset - before
        let target = NSPoint(x: caret.midX, y: caret.midY + (abs(moved) > 1 ? moved : dy))
        if let s = m.spot(atDocPoint: target) { go(s, reveal: abs(moved) < 1) }
    }

    private func scrollLine(up: Bool, _ tv: ChapterTextView) {
        guard let m = manuscript else { return }
        m.scrollOffset += up ? -m.lineHeight : m.lineHeight
        keepCaretOnScreen(tv)
    }

    private func keepCaretOnScreen(_ tv: ChapterTextView) {
        guard let m = manuscript else { return }
        let caret = m.docRect(tv.chapterId, tv.selectedRange())
        let visible = m.visibleDocRect.insetBy(dx: 0, dy: m.lineHeight)
        if caret.minY < visible.minY, let s = m.spot(atDocPoint: NSPoint(x: caret.midX, y: visible.minY + 2)) { go(s, reveal: false) }
        if caret.maxY > visible.maxY, let s = m.spot(atDocPoint: NSPoint(x: caret.midX, y: visible.maxY - 2)) { go(s, reveal: false) }
    }

    private func edgeOfScreen(top: Bool, _ tv: ChapterTextView) {
        guard let m = manuscript else { return }
        let caret = m.docRect(tv.chapterId, tv.selectedRange())
        let visible = m.visibleDocRect
        let y = top ? visible.minY + m.lineHeight : visible.maxY - m.lineHeight
        if let s = m.spot(atDocPoint: NSPoint(x: caret.midX, y: y)) { go(s, reveal: false) }
    }

    private func startScrolling(up: Bool) {
        stopScrolling()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tv = self.manuscript?.activeTextView() else { self?.stopScrolling(); return }
                let before = self.manuscript?.scrollOffset ?? 0
                self.scrollLine(up: up, tv)
                if abs((self.manuscript?.scrollOffset ?? 0) - before) < 0.5 { self.stopScrolling() }
            }
        }
        say(up ? "Scrolling up — any key stops" : "Scrolling down — any key stops")
    }

    func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    /// ^QG / ^QH: the next (or previous) occurrence of a character, across chapters.
    private func findChar(_ c: String, forward: Bool, _ tv: ProseTextView) {
        let target = c as NSString
        guard let chapter = tv as? ChapterTextView else {
            guard let s = tv.textStorage?.string as NSString? else { return }
            let from = tv.selectedRange().location
            let r = forward
                ? s.range(of: c, options: [], range: NSRange(location: min(from + 1, s.length), length: s.length - min(from + 1, s.length)))
                : s.range(of: c, options: .backwards, range: NSRange(location: 0, length: from))
            if r.location != NSNotFound { tv.setSelectedRange(NSRange(location: r.location, length: 0)); tv.scrollRangeToVisible(r) }
            return
        }
        let order = session.meta.chapterOrder
        guard var i = order.firstIndex(of: chapter.chapterId) else { return }
        var from = chapter.selectedRange().location
        while order.indices.contains(i), let ch = session.chapter(order[i]) {
            let s = ch.storage.string as NSString
            let r: NSRange
            if forward {
                let start = min(from + (i == order.firstIndex(of: chapter.chapterId)! ? 1 : 0), s.length)
                r = s.range(of: target as String, options: [], range: NSRange(location: start, length: s.length - start))
            } else {
                let end = min(from, s.length)
                r = s.range(of: target as String, options: .backwards, range: NSRange(location: 0, length: end))
            }
            if r.location != NSNotFound {
                remember()
                go(Spot(chId: order[i], loc: r.location))
                return
            }
            i += forward ? 1 : -1
            from = forward ? 0 : (order.indices.contains(i) ? (session.chapter(order[i])?.storage.length ?? 0) : 0)
        }
        say("“\(c == "\n" ? "↵" : c)” not found \(forward ? "after" : "before") the cursor")
    }

    // MARK: - ^QL

    /// The next misspelled word after the cursor, anywhere in the rest of the book.
    private func findMisspelling(after tv: ChapterTextView) {
        guard let m = manuscript else { return }
        let checker = NSSpellChecker.shared
        let order = session.meta.chapterOrder
        guard let start = order.firstIndex(of: tv.chapterId) else { return }
        let custom = app.library.customWords
        for i in start..<order.count {
            let chId = order[i]
            guard let ch = session.chapter(chId), let view = m.textView(chId) else { continue }
            let tag = view.spellCheckerDocumentTag
            let ignored = Set(checker.ignoredWords(inSpellDocumentWithTag: tag) ?? []).union(custom)
            checker.setIgnoredWords(Array(ignored), inSpellDocumentWithTag: tag)
            let s = ch.storage.string
            let ns = s as NSString
            var from = i == start ? NSMaxRange(tv.selectedRange()) : 0
            while from < ns.length {
                let r = checker.checkSpelling(of: s, startingAt: from, language: nil, wrap: false,
                                              inSpellDocumentWithTag: tag, wordCount: nil)
                if r.location == NSNotFound || r.location < from { break }
                let para = Prose.paragraph(ns, at: r.location)
                if Prose.blockKind(ch.storage, para) != nil { from = NSMaxRange(r); continue } // ghosts and breaks aren't prose
                remember()
                m.reveal(chId, r, select: true)
                let word = ns.substring(with: r)
                let guesses = checker.guesses(forWordRange: r, in: s, language: nil, inSpellDocumentWithTag: tag) ?? []
                let hint = guesses.isEmpty ? "no suggestions" : "maybe " + guesses.prefix(4).joined(separator: ", ")
                app.showToast("“\(word)” — \(hint) · right-click to fix · ^QL for the next", seconds: 8)
                return
            }
        }
        say("No misspellings after the cursor")
    }

    // MARK: - Positions that ride along with edits

    /// Called for every change to a chapter's characters: positions after the
    /// change shift with it; positions inside replaced text land at its end.
    /// A chapter replaced whole (undo, outline ghosts) keeps its offsets.
    func adjust(_ storage: NSTextStorage, _ edited: NSRange, _ delta: Int) {
        guard let chId = session.chapterId(for: storage) else { return }
        let whole = edited.location == 0 && edited.length == storage.length
        let oldEnd = edited.location + edited.length - delta
        var moved = false
        for (key, var s) in slots where s.chId == chId {
            let was = s.loc
            if !whole {
                if s.loc >= oldEnd && s.loc > edited.location { s.loc += delta }
                else if s.loc > edited.location { s.loc = NSMaxRange(edited) }
            }
            s.loc = max(0, min(s.loc, storage.length))
            if s.loc != was { slots[key] = s; if key != "P" && key != "V" { moved = true } }
        }
        if moved { changed() }
    }

    /// A chapter split at `loc`: positions from there on belong to the new
    /// chapter. Call before the text is cut; hand the result to `adopt`.
    func detach(_ chId: String, from loc: Int) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, s) in slots where s.chId == chId && s.loc >= loc {
            out[key] = s.loc - loc
            slots[key] = nil
        }
        return out
    }

    func adopt(_ detached: [String: Int], into chId: String) {
        for (key, off) in detached { slots[key] = Spot(chId: chId, loc: off) }
        changed()
    }

    /// A chapter merged onto the end of another, starting at `offset`.
    func merge(_ chId: String, into target: String, offset: Int) {
        for (key, s) in slots where s.chId == chId { slots[key] = Spot(chId: target, loc: s.loc + offset) }
        changed()
    }

    /// For the structural undo: every remembered position, as it was.
    var savedSlots: [String: Spot] {
        get { slots }
        set { slots = newValue; changed() }
    }

    /// Chapters that are gone take their positions with them.
    func forget(_ chId: String) {
        slots = slots.filter { $0.value.chId != chId }
        changed()
    }

    private var refreshQueued = false

    private func changed() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.manuscript?.refreshWordStar()
        }
    }

    /// The highlighted block (shown, complete, in one chapter).
    var visibleBlock: (chId: String, range: NSRange)? {
        guard !hidden, let b = blockBegin, let k = blockEnd, b.chId == k.chId, b.loc < k.loc else { return nil }
        return (b.chId, NSRange(location: b.loc, length: k.loc - b.loc))
    }

    /// The little tags drawn in a chapter: markers 0–9, and <B>/<K> while a
    /// block is only half marked.
    func tags(in chId: String) -> [(label: String, loc: Int)] {
        guard !hidden else { return [] }
        var out = (0...9).compactMap { n in marker(n).flatMap { $0.chId == chId ? ("\(n)", $0.loc) : nil } }
        if visibleBlock == nil {
            if let b = blockBegin, b.chId == chId { out.append(("B", b.loc)) }
            if let k = blockEnd, k.chId == chId { out.append(("K", k.loc)) }
        }
        return out
    }
}
