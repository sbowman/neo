import AppKit

/// A paragraph lifted out of a storage: its content and what it means.
struct ParaPiece {
    var content: NSAttributedString
    var attrs: [NSAttributedString.Key: Any]

    var kind: BlockKind? { (attrs[.neoBlock] as? String).flatMap(BlockKind.init) }
    var secId: String? { attrs[.neoSecId] as? String }
    var secBrk: String? { attrs[.neoSecBrk] as? String }
    var isBlank: Bool { content.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func split(_ a: NSAttributedString) -> [ParaPiece] {
        let s = a.string as NSString
        return Prose.paragraphs(s).map { p in
            let full = Prose.withSeparator(p, in: s)
            var attrs: [NSAttributedString.Key: Any] = [:]
            if full.length > 0 {
                let at = NSMaxRange(full) - 1
                for k in NSAttributedString.Key.paragraphKeys {
                    if let v = a.attribute(k, at: at, effectiveRange: nil) { attrs[k] = v }
                }
            }
            return ParaPiece(content: a.attributedSubstring(from: p), attrs: attrs)
        }
    }

    static func join(_ pieces: [ParaPiece]) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (i, p) in pieces.enumerated() {
            let start = out.length
            out.append(p.content)
            if i < pieces.count - 1 { out.append(NSAttributedString(string: "\n")) }
            let r = NSRange(location: start, length: out.length - start)
            if r.length > 0 {
                for k in NSAttributedString.Key.paragraphKeys { out.removeAttribute(k, range: r) }
                out.addAttributes(p.attrs, range: r)
            }
        }
        return out
    }

    static func sceneBreak(secBrk: String? = nil) -> ParaPiece {
        var attrs: [NSAttributedString.Key: Any] = [.neoBlock: BlockKind.sceneBreak.rawValue]
        if let secBrk { attrs[.neoSecBrk] = secBrk }
        return ParaPiece(content: NSAttributedString(string: Prose.sceneBreakText), attrs: attrs)
    }
}

extension BookSession {

    // MARK: - Edits that the text's own undo can replay

    /// Replace text in a chapter through its text view, so ⌘Z undoes it.
    func edit(_ chId: String, _ range: NSRange, _ replacement: NSAttributedString, actionName: String? = nil) {
        guard let ch = chapter(chId) else { return }
        if let tv = manuscript?.textView(chId) {
            tv.breakUndoCoalescing()
            if tv.shouldChangeText(in: range, replacementString: replacement.string) {
                ch.storage.replaceCharacters(in: range, with: replacement)
                tv.didChangeText()
            }
            tv.breakUndoCoalescing()
            if let actionName { tv.undoManager?.setActionName(actionName) }
        } else {
            ch.storage.replaceCharacters(in: range, with: replacement)
            chapterEdited(chId)
        }
    }

    private func sceneBreakText(_ secBrk: String? = nil) -> NSAttributedString {
        ParaPiece.join([ParaPiece.sceneBreak(secBrk: secBrk)])
    }

    // MARK: - Enter

    /// Enter once: new paragraph. Twice: a *** section break, wherever the
    /// caret is, even mid-sentence. Three times: the chapter splits here.
    func handleNewline(_ tv: ChapterTextView) -> Bool {
        let chId = tv.chapterId
        guard let ch = chapter(chId) else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let ts = ch.storage
        let s = ts.string as NSString
        let block = Prose.paragraph(s, at: sel.location)
        if Prose.blockKind(ts, block) == .sceneBreak { return true } // Enter on a *** line: nothing
        let prev: NSRange? = block.location > 0 ? Prose.paragraph(s, at: block.location - 1) : nil
        let prevIsBreak = prev.map { Prose.blockKind(ts, $0) == .sceneBreak } ?? false

        if !Prose.isBlank(s, block) {
            let atStart = sel.location == block.location
            guard atStart && enterRun >= 2, let prev else { return false } // an ordinary Enter
            if prevIsBreak {
                // third Enter mid-flow: everything from here becomes the next chapter
                snapshot("chapter split")
                ts.replaceCharacters(in: NSRange(location: prev.location, length: block.location - prev.location), with: "")
                splitChapter(chId, at: prev.location)
                return true
            }
            // second Enter mid-flow: a *** goes in above the text the first press
            // pushed down; ⌘Z undoes the whole gesture and rejoins the sentence
            snapshot("section break", rejoin: enterRun >= 2)
            let brk = NSMutableAttributedString(attributedString: sceneBreakText())
            brk.append(NSAttributedString(string: "\n", attributes: [.neoBlock: BlockKind.sceneBreak.rawValue]))
            let at: NSRange
            if Prose.isBlank(s, prev) {
                // the blank line above becomes the break (its newline too — a
                // paragraph's identity lives on its newline)
                at = NSRange(location: prev.location, length: prev.length + 1)
            } else {
                at = NSRange(location: block.location, length: 0)
            }
            ts.replaceCharacters(in: at, with: brk)
            finishBreak(tv, chId, caret: at.location + brk.length)
            return true
        }

        if let prev, prevIsBreak {
            // third Enter at the end of the flow: the chapter splits here
            snapshot("chapter split")
            ts.replaceCharacters(in: NSRange(location: prev.location, length: block.location - prev.location), with: "")
            splitChapter(chId, at: prev.location)
            return true
        }
        if prev != nil {
            // second Enter at the end of the flow: this empty line becomes *** and a fresh one opens
            snapshot("section break", rejoin: enterRun >= 2)
            let brk = NSMutableAttributedString(attributedString: sceneBreakText())
            brk.append(NSAttributedString(string: "\n", attributes: [.neoBlock: BlockKind.sceneBreak.rawValue]))
            ts.replaceCharacters(in: NSRange(location: block.location, length: block.length), with: brk)
            finishBreak(tv, chId, caret: block.location + brk.length)
            return true
        }
        return false
    }

    /// Breaks live outside the text's own undo: while the latest edits are
    /// breaks, ⌘Z walks NEO's structural stack instead.
    private func finishBreak(_ tv: ChapterTextView, _ chId: String, caret: Int) {
        chapterEdited(chId)
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        tv.resetTypingAttributes()
        resetNativeUndo()
        breakRun += 1
    }

    // MARK: - Backspace / Delete

    func handleDelete(_ tv: ChapterTextView, backward: Bool) -> Bool {
        let chId = tv.chapterId
        guard let ch = chapter(chId) else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let ts = ch.storage
        let s = ts.string as NSString
        let loc = sel.location
        let block = Prose.paragraph(s, at: loc)

        // a *** is removed whole — prose never merges into the break
        if backward && loc == block.location && block.location > 0 {
            let prev = Prose.paragraph(s, at: block.location - 1)
            if Prose.blockKind(ts, prev) == .sceneBreak {
                edit(chId, NSRange(location: prev.location, length: block.location - prev.location), NSAttributedString(),
                     actionName: "Remove Section Break")
                tv.setSelectedRange(NSRange(location: prev.location, length: 0))
                return true
            }
        }
        if !backward && loc == NSMaxRange(block) && NSMaxRange(block) < s.length {
            let next = Prose.paragraph(s, at: NSMaxRange(block) + 1)
            if Prose.blockKind(ts, next) == .sceneBreak {
                edit(chId, NSRange(location: NSMaxRange(block), length: NSMaxRange(next) - NSMaxRange(block)), NSAttributedString(),
                     actionName: "Remove Section Break")
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                return true
            }
        }
        if backward {
            if backspaceInEmptyChapter(chId) { return true }
            if loc == 0 && backspaceAtChapterStart(chId) { return true }
        }
        // a flag is deleted as a unit, and takes its note with it
        let at = backward ? loc - 1 : loc
        if at >= 0 && at < s.length, s.character(at: at) == Prose.markChar,
           let sid = ts.attribute(.neoMark, at: at, effectiveRange: nil) as? String {
            resolveSticky(sid)
            return true
        }
        return false
    }

    /// Anything typed into an outline ghost turns it into prose (it keeps its
    /// section id, so the outline knows that section has been written).
    func willChange(_ chId: String, _ range: NSRange) {
        guard let ch = chapter(chId) else { return }
        let ts = ch.storage
        let s = ts.string as NSString
        let lo = Prose.paragraph(s, at: range.location)
        let hi = Prose.paragraph(s, at: min(NSMaxRange(range), s.length))
        var para = lo
        while true {
            if Prose.blockKind(ts, para) == .ghost {
                let full = Prose.withSeparator(para, in: s)
                ts.removeAttribute(.neoBlock, range: full)
                ProseStyler.style(ts, around: full, theme: theme, mode: .chapter)
            }
            if para.location >= hi.location || NSMaxRange(para) >= s.length { break }
            para = Prose.paragraph(s, at: NSMaxRange(para) + 1)
        }
    }

    // MARK: - Selection

    func selectionChanged(_ tv: ChapterTextView) {
        if currentChapterId != tv.chapterId { currentChapterId = tv.chapterId }
        let r = tv.selectedRange()
        if r.length > 0, let ch = chapter(tv.chapterId) {
            let n = countWords(ch.storage.attributedSubstring(from: r).string.replacingOccurrences(of: Prose.mark, with: ""))
            selectedWords = n > 0 ? n : nil
        } else if selectedWords != nil {
            selectedWords = nil
        }
    }

    func scrolledTo(_ chId: String) {
        if currentChapterId != chId { currentChapterId = chId }
    }

    // MARK: - Placeholders and stickies

    /// ⌘⇧X: drop a flag and a note, and keep writing.
    func insertPlaceholder() {
        guard tab == .manuscript, let tv = manuscript?.activeTextView() else {
            app.showToast("Click into a chapter first, then ⌘⇧X drops a placeholder")
            return
        }
        let chId = tv.chapterId
        currentChapterId = chId
        let sid = NEOID.sticky()
        let at = NSMaxRange(tv.selectedRange())
        let flag = NSMutableAttributedString(string: Prose.mark, attributes: [.neoMark: sid])
        flag.append(NSAttributedString(string: " "))
        edit(chId, NSRange(location: at, length: 0), flag, actionName: "Placeholder")
        tv.setSelectedRange(NSRange(location: at + 2, length: 0))
        tv.resetTypingAttributes()
        stickies.append(Sticky(id: sid, chapterId: chId))
        saveStickies()
        flaggedChapters.insert(chId)
    }

    var openStickies: [Sticky] { stickies.filter { !$0.resolved } }

    func updateSticky(_ sid: String, text: String) {
        guard let i = stickies.firstIndex(where: { $0.id == sid }) else { return }
        stickies[i].text = text
        scheduleStickiesSave()
    }

    func markLocation(_ sid: String) -> (chId: String, loc: Int)? {
        for ch in chapters {
            var found: Int? = nil
            ch.storage.enumerateAttribute(.neoMark, in: NSRange(location: 0, length: ch.storage.length)) { v, r, stop in
                if (v as? String) == sid { found = r.location; stop.pointee = true }
            }
            if let found { return (ch.id, found) }
        }
        return nil
    }

    /// Removes the flag (tidying the seam) and resolves its note.
    func resolveSticky(_ sid: String) {
        if let (chId, loc) = markLocation(sid), let ch = chapter(chId) {
            let s = ch.storage.string as NSString
            var r = NSRange(location: loc, length: 1)
            // removing a flag between two spaces shouldn't leave both
            let before = loc > 0 ? s.character(at: loc - 1) : 0
            let after = loc + 1 < s.length ? s.character(at: loc + 1) : 0
            if (before == 0x20 || before == 0xA0 || loc == 0 || before == Prose.newline) && (after == 0x20 || after == 0xA0) {
                r.length = 2
            }
            edit(chId, r, NSAttributedString(), actionName: "Resolve Placeholder")
            manuscript?.textView(chId)?.setSelectedRange(NSRange(location: loc, length: 0))
        }
        if let i = stickies.firstIndex(where: { $0.id == sid }) {
            stickies[i].resolved = true
        }
        saveStickies()
    }

    func goToSticky(_ sid: String) {
        switchTab(.manuscript)
        guard let (chId, loc) = markLocation(sid) else { return }
        DispatchQueue.main.async {
            self.manuscript?.reveal(chId, NSRange(location: loc + 1, length: 0), select: true)
        }
    }

    func focusSticky(_ sid: String) {
        sideOpen = true
        focusStickyId = sid
    }

    /// Pair every flag in the manuscript with a note: pasted duplicates get
    /// their own copy, flags that moved chapters update their red dot, flags
    /// brought back by an undo get their note back.
    func reconcileMarks() {
        var seen = Set<String>()
        var changed = false
        for ch in chapters {
            let ts = ch.storage
            var fixes: [(NSRange, String)] = []
            ts.enumerateAttribute(.neoMark, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
                guard let sid = v as? String else { return }
                for i in r.location..<NSMaxRange(r) {
                    if seen.contains(sid) {
                        let nid = NEOID.sticky()
                        let text = stickies.first { $0.id == sid }?.text ?? ""
                        fixes.append((NSRange(location: i, length: 1), nid))
                        stickies.append(Sticky(id: nid, chapterId: ch.id, text: text))
                        seen.insert(nid)
                        changed = true
                        continue
                    }
                    if let k = stickies.firstIndex(where: { $0.id == sid }) {
                        if stickies[k].chapterId != ch.id || stickies[k].resolved {
                            stickies[k].chapterId = ch.id
                            stickies[k].resolved = false
                            changed = true
                        }
                    } else {
                        stickies.append(Sticky(id: sid, chapterId: ch.id))
                        changed = true
                    }
                    seen.insert(sid)
                }
            }
            for (r, nid) in fixes { ts.addAttribute(.neoMark, value: nid, range: r) }
            if !fixes.isEmpty { scheduleChapterSave(ch.id) }
            if hasFlag(ts) { flaggedChapters.insert(ch.id) } else { flaggedChapters.remove(ch.id) }
        }
        if changed { saveStickies() }
    }

    // MARK: - Darlings

    private func flatOffset(_ s: NSString, _ loc: Int) -> Int {
        var n = 0
        var i = 0
        while i < min(loc, s.length) {
            let c = s.character(at: i)
            if c != Prose.newline && c != Prose.lineBreakChar { n += 1 }
            i += 1
        }
        return n
    }

    /// ⌘⇧D, or a drag onto the Darlings tab: the passage leaves the manuscript
    /// and is kept. Its home is remembered by the text around the cut — no
    /// markers are left in the manuscript.
    func moveToDarlings(_ chId: String, _ range: NSRange) {
        guard let ch = chapter(chId), range.length > 0, NSMaxRange(range) <= ch.storage.length else { return }
        let ts = ch.storage
        let piece = ts.attributedSubstring(from: range)
        let text = piece.string.replacingOccurrences(of: Prose.mark, with: "")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        snapshot("darling")
        var html = HTMLCodec.fragmentHTML(from: piece)
        ts.replaceCharacters(in: range, with: "")
        // a whole paragraph dragged away leaves its empty shell: remove it
        var caret = range.location
        let s = ts.string as NSString
        let host = Prose.paragraph(s, at: caret)
        if Prose.isBlank(s, host) && Prose.paragraphs(s).count > 1 {
            // a whole paragraph: it goes back as a paragraph of its own
            if html.range(of: "<p[\\s>]", options: .regularExpression) == nil { html = "<p>\(html)</p>" }
            if host.location > 0 {
                ts.replaceCharacters(in: NSRange(location: host.location - 1, length: host.length + 1), with: "")
                caret = host.location - 1
            } else {
                ts.replaceCharacters(in: NSRange(location: 0, length: host.length + 1), with: "")
                caret = 0
            }
        }
        let flat = Prose.flatText(ts).text
        let pos = flatOffset(ts.string as NSString, caret)
        let prefix = flat.substring(with: NSRange(location: max(0, pos - 60), length: pos - max(0, pos - 60)))
        let suffix = flat.substring(with: NSRange(location: pos, length: min(60, flat.length - pos)))
        let idx = index(of: chId)
        darlings.insert(Darling(id: NEOID.darling(), html: html, text: text, chapterId: chId,
                                chapterLabel: idx.map { "Chapter \($0 + 1)" } ?? "Manuscript",
                                anchorPrefix: prefix, anchorSuffix: suffix), at: 0)
        saveDarlings()
        chapterEdited(chId)
        manuscript?.textView(chId)?.setSelectedRange(NSRange(location: min(caret, ts.length), length: 0))
        resetNativeUndo()
        breakRun += 1
        reconcileMarks()
        app.showToast("Saved to Darlings — kill without remorse (⌘Z to undo)")
    }

    func darlingFromKeyboard() {
        guard tab == .manuscript, let tv = manuscript?.activeTextView(), tv.selectedRange().length > 0 else {
            app.showToast("Select the passage first, then ⌘⇧D sends it to Darlings")
            return
        }
        moveToDarlings(tv.chapterId, tv.selectedRange())
    }

    /// A drag that began in the manuscript landed on the Darlings tab.
    func dropOnDarlings() {
        draggingText = false
        guard let (chId, range) = dragOrigin else { return }
        dragOrigin = nil
        moveToDarlings(chId, range)
    }

    private func findDarlingPosition(_ flat: NSString, _ d: Darling) -> Int? {
        guard d.anchorPrefix != nil || d.anchorSuffix != nil else { return nil }
        let pre = d.anchorPrefix ?? "", suf = d.anchorSuffix ?? ""
        if !(pre + suf).isEmpty {
            let r = flat.range(of: pre + suf)
            if r.location != NSNotFound { return r.location + (pre as NSString).length }
        }
        if !pre.isEmpty {
            let r = flat.range(of: pre)
            if r.location != NSNotFound { return NSMaxRange(r) }
        }
        if !suf.isEmpty {
            let r = flat.range(of: suf)
            if r.location != NSNotFound { return r.location }
        }
        return nil
    }

    private func darlingContent(_ d: Darling) -> NSAttributedString {
        if let html = d.html, !html.isEmpty { return HTMLCodec.attributedString(fromHTML: html).0 }
        let paras = d.text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return NSAttributedString(string: paras.joined(separator: "\n"))
    }

    func restoreDarling(_ id: String) {
        guard let d = darlings.first(where: { $0.id == id }) else { return }
        snapshot("darling restore")
        switchTab(.manuscript)
        let content = darlingContent(d)
        let isBlock = d.html.map { $0.range(of: "<p[\\s>]", options: [.regularExpression, .caseInsensitive]) != nil } ?? d.text.contains("\n")

        // preferred: the exact spot it was cut from, found by its surroundings
        if let chId = d.chapterId, let ch = chapter(chId) {
            let ts = ch.storage
            let (flat, map) = Prose.flatText(ts)
            if let pos = findDarlingPosition(flat, d) {
                let loc = pos > 0 ? min(map[pos - 1] + 1, ts.length) : (map.first ?? 0)
                var revealAt = loc
                if isBlock {
                    // paragraphs go back in after the paragraph that held the cut
                    let host = Prose.paragraph(ts.string as NSString, at: loc)
                    let insert = NSMutableAttributedString(string: "\n")
                    insert.append(content)
                    ts.replaceCharacters(in: NSRange(location: NSMaxRange(host), length: 0), with: insert)
                    revealAt = NSMaxRange(host) + 1
                } else {
                    ts.replaceCharacters(in: NSRange(location: loc, length: 0), with: content)
                }
                finishRestore(id, chId, NSRange(location: revealAt, length: content.length))
                app.showToast("Darling restored to its original spot")
                return
            }
        }
        // fallback: the spot no longer exists — the end of its chapter, or the last one
        var chId = d.chapterId.flatMap { meta.chapterOrder.contains($0) ? $0 : nil } ?? meta.chapterOrder.last
        if chId == nil { chId = createChapter(at: 0) }
        guard let chId, let ch = chapter(chId) else { return }
        let ts = ch.storage
        let start: Int
        if Prose.plainText(ts, skipGhosts: false).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ts.setAttributedString(content)
            start = 0
        } else {
            ts.append(NSAttributedString(string: "\n"))
            start = ts.length
            ts.append(content)
        }
        finishRestore(id, chId, NSRange(location: start, length: content.length))
        app.showToast("Original spot is gone — restored to the end of " + (d.chapterLabel.isEmpty ? "the manuscript" : d.chapterLabel))
    }

    private func finishRestore(_ id: String, _ chId: String, _ range: NSRange) {
        darlings.removeAll { $0.id == id }
        saveDarlings()
        chapterEdited(chId)
        reconcileMarks()
        resetNativeUndo()
        breakRun += 1
        DispatchQueue.main.async {
            self.manuscript?.reveal(chId, NSRange(location: range.location, length: 0), select: true)
        }
    }

    func deleteDarling(_ id: String) {
        snapshot("darling delete")
        darlings.removeAll { $0.id == id }
        saveDarlings()
    }

    /// Older versions planted invisible anchor spans at cut points; on open
    /// each becomes a remembered-context position and the span is dropped.
    func migrateDarlingAnchors() {
        guard !legacyAnchorsAreEmpty else { return }
        var changed = false
        for a in takeLegacyAnchors() {
            guard let ch = chapter(a.chId) else { continue }
            scheduleChapterSave(a.chId)
            guard let k = darlings.firstIndex(where: { $0.id == a.id }), darlings[k].anchorPrefix == nil else { continue }
            let flat = Prose.flatText(ch.storage).text
            let off = min(a.offset, flat.length)
            darlings[k].anchorPrefix = flat.substring(with: NSRange(location: max(0, off - 60), length: off - max(0, off - 60)))
            darlings[k].anchorSuffix = flat.substring(with: NSRange(location: off, length: min(60, flat.length - off)))
            changed = true
        }
        if changed { saveDarlings() }
    }

    // MARK: - Outline ghosts

    /// Section notes appear in the manuscript as grey ghost paragraphs, with
    /// real *** breaks between sections. A ghost that has been written over
    /// is prose now and is left alone.
    func syncGhosts(_ chId: String) {
        guard let ch = chapter(chId) else { return }
        let list = meta.sectionNotes[chId] ?? []
        var pieces = ParaPiece.split(ch.storage)
        let ghostIds = Set(pieces.filter { $0.kind == .ghost }.compactMap(\.secId))
        // pull every unwritten ghost (and the break planted for it) out…
        pieces.removeAll { p in
            (p.kind == .ghost && p.secId != nil) || (p.kind == .sceneBreak && p.secBrk.map { ghostIds.contains($0) } == true)
        }
        if pieces.allSatisfy(\.isBlank) { pieces = [] }
        // …and put them back in outline order
        for sec in list {
            if pieces.contains(where: { $0.secId == sec.id && $0.kind != .ghost }) { continue } // written already
            if sec.text.isEmpty { continue }
            let hasContent = pieces.contains { !$0.isBlank }
            if hasContent && pieces.last?.kind != .sceneBreak {
                pieces.append(ParaPiece.sceneBreak(secBrk: sec.id))
            }
            pieces.append(ParaPiece(content: NSAttributedString(string: sec.text),
                                    attrs: [.neoBlock: BlockKind.ghost.rawValue, .neoSecId: sec.id]))
        }
        let rebuilt = ParaPiece.join(pieces)
        if rebuilt.isEqual(to: NSAttributedString(attributedString: ch.storage)) { return }
        ch.storage.setAttributedString(rebuilt)
        ProseStyler.styleAll(ch.storage, theme: theme, mode: .chapter)
        chapterEdited(chId)
        resetNativeUndo()
    }

    func outlineChapterEnter(_ chId: String) {
        let at = (index(of: chId) ?? meta.chapterOrder.count - 1) + 1
        let newId = createChapter(at: at)
        outlineFocus = OutlineFocus(chId: newId, secId: nil)
    }

    func outlineSectionEnter(_ chId: String, after secId: String) {
        var list = meta.sectionNotes[chId] ?? []
        let i = list.firstIndex { $0.id == secId }.map { $0 + 1 } ?? list.count
        let sec = SectionNote(id: NEOID.section(), text: "")
        list.insert(sec, at: i)
        meta.sectionNotes[chId] = list
        scheduleMetaSave()
        syncGhosts(chId)
        outlineFocus = OutlineFocus(chId: chId, secId: sec.id)
    }

    /// Tab on a fresh chapter line turns it into a section of the chapter above.
    func outlineIndent(_ chId: String) {
        guard let pos = index(of: chId) else { return }
        if pos == 0 { app.showToast("The first line has to be a chapter"); return }
        if (chapterWords[chId] ?? 0) > 0 {
            app.showToast("This chapter already has words in it — only empty chapter lines can become sections")
            return
        }
        let prevCh = meta.chapterOrder[pos - 1]
        let sec = SectionNote(id: NEOID.section(), text: meta.chapterNotes[chId] ?? "")
        meta.sectionNotes[prevCh, default: []].append(sec)
        deleteChapterQuiet(chId)
        syncGhosts(prevCh)
        outlineFocus = OutlineFocus(chId: prevCh, secId: sec.id)
    }

    /// Shift+Tab turns a section into a chapter of its own.
    func outlineOutdent(_ chId: String, _ secId: String) {
        var list = meta.sectionNotes[chId] ?? []
        guard let k = list.firstIndex(where: { $0.id == secId }) else { return }
        let sec = list.remove(at: k)
        meta.sectionNotes[chId] = list
        let at = (index(of: chId) ?? 0) + 1
        let newId = createChapter(at: at)
        meta.chapterNotes[newId] = sec.text
        scheduleMetaSave()
        syncGhosts(chId)
        outlineFocus = OutlineFocus(chId: newId, secId: nil)
    }

    func outlineRemoveEmpty(_ chId: String, secId: String?) {
        if let secId {
            meta.sectionNotes[chId] = (meta.sectionNotes[chId] ?? []).filter { $0.id != secId }
            scheduleMetaSave()
            syncGhosts(chId)
            outlineFocus = OutlineFocus(chId: chId, secId: nil)
        } else if meta.chapterOrder.count > 1 && (chapterWords[chId] ?? 0) == 0 {
            let pos = index(of: chId) ?? 0
            let prev = meta.chapterOrder[max(0, pos - 1)]
            deleteChapterQuiet(chId)
            outlineFocus = OutlineFocus(chId: prev == chId ? meta.chapterOrder.first : prev, secId: nil)
        }
    }

    func setSectionText(_ chId: String, _ secId: String, _ text: String) {
        guard var list = meta.sectionNotes[chId], let k = list.firstIndex(where: { $0.id == secId }) else { return }
        list[k].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.sectionNotes[chId] = list
        scheduleMetaSave()
    }

    func outlineDelete(_ chId: String, secId: String?) {
        Task {
            if let secId {
                let c = await app.choose("Delete this section?", message: nil, [
                    ModalOption(label: "Delete section",
                                desc: "Removes the outline line and its grey ghost from the manuscript. Written prose is never touched.",
                                value: "delete", danger: true)
                ])
                guard c == "delete" else { return }
                meta.sectionNotes[chId] = (meta.sectionNotes[chId] ?? []).filter { $0.id != secId }
                scheduleMetaSave()
                syncGhosts(chId)
            } else {
                chapterMenu(chId)
            }
        }
    }

    // MARK: - Format

    /// Format → Align Paragraph: every paragraph the selection touches.
    func applyAlign(_ value: String) {
        guard tab == .manuscript, let tv = manuscript?.activeTextView(), let ch = chapter(tv.chapterId) else {
            app.showToast("Click into a paragraph first")
            return
        }
        let ts = ch.storage
        let s = ts.string as NSString
        let sel = tv.selectedRange()
        let first = Prose.paragraph(s, at: sel.location)
        let last = Prose.paragraph(s, at: NSMaxRange(sel))
        let span = Prose.withSeparator(NSRange(location: first.location, length: NSMaxRange(last) - first.location), in: s)
        guard tv.shouldChangeText(in: span, replacementString: nil) else { return }
        var para = first
        while true {
            if Prose.blockKind(ts, para) != .sceneBreak {
                let full = Prose.withSeparator(para, in: s)
                if full.length > 0 {
                    if value == "left" { ts.removeAttribute(.neoAlign, range: full) }
                    else { ts.addAttribute(.neoAlign, value: value, range: full) }
                }
            }
            if para.location >= last.location || NSMaxRange(para) >= s.length { break }
            para = Prose.paragraph(s, at: NSMaxRange(para) + 1)
        }
        ProseStyler.style(ts, around: span, theme: theme, mode: .chapter)
        tv.didChangeText()
        tv.undoManager?.setActionName("Align")
    }

    func toggleSpellcheck() {
        spellOn.toggle()
        manuscript?.setSpellcheck(spellOn)
        app.showToast(spellOn ? "Spellcheck on" : "Spellcheck off")
    }
}
