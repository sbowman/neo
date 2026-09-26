import AppKit
import SwiftUI

enum EditorTab: String { case manuscript, notes, outline, darlings }

/// One chapter's words. The storage *is* the model; the text view on the
/// manuscript page only displays it.
final class Chapter: Identifiable {
    let id: String
    let storage: NSTextStorage
    var dirty = false

    init(id: String, storage: NSTextStorage) {
        self.id = id
        self.storage = storage
    }
}

struct Caret {
    var chId: String
    var pIdx: Int
    var off: Int
    var scroll: CGFloat?
}

struct Sprint {
    var target: Int
    var startCount: Int
    var startTime: Date
    var done = false
}

struct OutlineFocus: Equatable {
    var chId: String?
    var secId: String?
}

/// Everything about the open book: its chapters, notes, darlings, counters,
/// saving, and the structural undo that covers the big moves.
@MainActor
@Observable
final class BookSession {
    let app: AppModel
    var meta: BookMeta
    private(set) var chapters: [Chapter] = []
    var stickies: [Sticky] = []
    var darlings: [Darling] = []

    var tab: EditorTab = .manuscript
    var currentChapterId: String?
    var wordModeChapter = false
    var selectedWords: Int?
    var bookWords = 0
    var chapterWords: [String: Int] = [:]
    var flaggedChapters: Set<String> = []
    var sprint: Sprint?

    var navOpen = false
    var sideOpen = false
    var sidePinned = false
    var draggingText = false
    var focusStickyId: String?
    var outlineFocus: OutlineFocus?
    var spellOn = false

    var searchVisible = false
    var searchQuery = ""
    var replaceText = ""
    var searchMatches: [(chId: String, range: NSRange)] = []
    var searchIndex = -1
    var searchFocusToken = 0

    /// bumps whenever the chapter list changes shape, for views that list chapters
    var structureVersion = 0

    @ObservationIgnored weak var manuscript: ManuscriptView?
    @ObservationIgnored var undoStack: [Snapshot] = []
    @ObservationIgnored var breakRun = 0
    @ObservationIgnored var enterRun = 0
    @ObservationIgnored var dragOrigin: (chId: String, range: NSRange)?
    @ObservationIgnored private var timers: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var normalizers: [ObjectIdentifier: StorageNormalizer] = [:]
    @ObservationIgnored private var tabScroll: [EditorTab: CGFloat] = [:]
    @ObservationIgnored private var tabCaret: Caret?
    @ObservationIgnored var notesDirtyHTML: String?
    @ObservationIgnored private var legacyAnchors: [(chId: String, id: String, offset: Int)] = []

    struct Snapshot {
        var label: String
        var rejoin = false
        var caret: Caret?
        var chapterOrder: [String]
        var contents: [String: NSAttributedString]
        var chapterTitles: [String: String]
        var chapterNotes: [String: String]
        var sectionNotes: [String: [SectionNote]]
        var darlings: [Darling]
        var stickies: [Sticky]
    }

    var theme: PageTheme { app.theme }

    var legacyAnchorsAreEmpty: Bool { legacyAnchors.isEmpty }

    func takeLegacyAnchors() -> [(chId: String, id: String, offset: Int)] {
        defer { legacyAnchors = [] }
        return legacyAnchors
    }

    init(app: AppModel, meta: BookMeta) {
        self.app = app
        self.meta = meta
        for chId in meta.chapterOrder {
            let (attr, anchors) = HTMLCodec.attributedString(fromHTML: LibraryStore.readChapter(meta.id, chId))
            let ch = makeChapter(chId, attr)
            chapters.append(ch)
            for a in anchors { legacyAnchors.append((chId, a.id, a.offset)) }
            chapterWords[chId] = countWords(Prose.plainText(ch.storage))
            if hasFlag(ch.storage) { flaggedChapters.insert(chId) }
        }
        stickies = LibraryStore.readList(meta.id, "stickies").compactMap(Sticky.init)
        darlings = LibraryStore.readList(meta.id, "darlings").compactMap(Darling.init)
        bookWords = chapterWords.values.reduce(0, +)
        migrateDarlingAnchors()
    }

    private func makeChapter(_ id: String, _ content: NSAttributedString) -> Chapter {
        let ts = NSTextStorage(attributedString: content)
        let ch = Chapter(id: id, storage: ts)
        let n = StorageNormalizer(session: self)
        normalizers[ObjectIdentifier(ts)] = n
        ts.delegate = n
        ProseStyler.styleAll(ts, theme: theme, mode: .chapter)
        return ch
    }

    func chapter(_ id: String?) -> Chapter? {
        guard let id else { return nil }
        return chapters.first { $0.id == id }
    }

    func index(of chId: String?) -> Int? {
        guard let chId else { return nil }
        return meta.chapterOrder.firstIndex(of: chId)
    }

    func chapterId(for storage: NSTextStorage) -> String? {
        chapters.first { $0.storage === storage }?.id
    }

    var isSolo: Bool { meta.chapterOrder.count == 1 }

    // MARK: - Opening

    /// Called once the manuscript page exists.
    func didAttachManuscript() {
        reconcileMarks()
        updateCounters()
        let isNew = meta.chapterOrder.isEmpty
        if isNew && app.library.writingStyle == "plotter" {
            switchTab(.outline)
        } else if isNew {
            DispatchQueue.main.async { self.manuscript?.focusTitle() }
        } else if let last = meta.lastChapterId, meta.chapterOrder.contains(last) {
            // pick up right where you left off
            currentChapterId = last
            let scroll = CGFloat(meta.lastScroll)
            DispatchQueue.main.async {
                self.manuscript?.scrollOffset = scroll
                self.manuscript?.focusChapterNear(last)
            }
        }
        if !app.library.hintShown {
            app.library.hintShown = true
            app.saveLibrary()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.app.showToast("Enter twice = section break · three times = new chapter · ⌘/ shows everything else", seconds: 7)
            }
        }
    }

    // MARK: - Timers

    func debounce(_ key: String, _ seconds: Double, _ work: @escaping () -> Void) {
        timers[key]?.cancel()
        let item = DispatchWorkItem(block: work)
        timers[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: - Saving

    func scheduleChapterSave(_ chId: String) {
        chapter(chId)?.dirty = true
        debounce("save-" + chId, 0.8) { [weak self] in self?.saveChapter(chId) }
    }

    func saveChapter(_ chId: String) {
        guard let ch = chapter(chId) else { return }
        LibraryStore.writeChapter(meta.id, chId, HTMLCodec.html(from: ch.storage))
        ch.dirty = false
    }

    func scheduleMetaSave() {
        debounce("meta", 0.8) { [weak self] in self?.saveMeta() }
    }

    func saveMeta() {
        LibraryStore.writeMeta(meta)
    }

    func saveStickies() {
        LibraryStore.writeList(meta.id, "stickies", stickies.map(\.json))
    }

    func scheduleStickiesSave() {
        debounce("stickies", 0.6) { [weak self] in self?.saveStickies() }
    }

    func saveDarlings() {
        LibraryStore.writeList(meta.id, "darlings", darlings.map(\.json))
    }

    func saveNotes(_ html: String) {
        notesDirtyHTML = html
        debounce("notes", 0.8) { [weak self] in self?.flushNotes() }
    }

    func flushNotes() {
        guard let html = notesDirtyHTML else { return }
        LibraryStore.writeAux(meta.id, "notes", html)
        notesDirtyHTML = nil
    }

    /// Remember where you were, write everything. Runs on a timer, when NEO
    /// loses focus, on the way back to the shelf, and at quit.
    func flushAll() {
        if let m = manuscript {
            meta.lastChapterId = currentChapterId
            meta.lastScroll = Double(tab == .manuscript ? m.scrollOffset : (tabScroll[.manuscript] ?? m.scrollOffset))
        }
        for ch in chapters where ch.dirty { saveChapter(ch.id) }
        flushNotes()
        saveMeta()
    }

    func close() {
        flushAll()
        for t in timers.values { t.cancel() }
        timers.removeAll()
        for ch in chapters { ch.storage.delegate = nil }
    }

    // MARK: - Counters

    /// Every edit to a chapter's words, typed or programmatic, lands here.
    func chapterEdited(_ chId: String) {
        breakRun = 0
        scheduleChapterSave(chId)
        debounce("count-" + chId, 0.25) { [weak self] in
            guard let self, let ch = self.chapter(chId) else { return }
            self.chapterWords[chId] = countWords(Prose.plainText(ch.storage))
            let flagged = self.hasFlag(ch.storage)
            // flags come and go with undo, cut and paste: keep their notes paired
            if flagged || self.flaggedChapters.contains(chId) { self.reconcileMarks() }
            if flagged { self.flaggedChapters.insert(chId) } else { self.flaggedChapters.remove(chId) }
            self.updateCounters()
        }
        if spellOn { manuscript?.refreshSpelling(chId) }
    }

    func hasFlag(_ a: NSAttributedString) -> Bool {
        var found = false
        a.enumerateAttribute(.neoMark, in: NSRange(location: 0, length: a.length)) { v, _, stop in
            if v != nil { found = true; stop.pointee = true }
        }
        return found
    }

    func recountAll() {
        for ch in chapters {
            chapterWords[ch.id] = countWords(Prose.plainText(ch.storage))
            if hasFlag(ch.storage) { flaggedChapters.insert(ch.id) } else { flaggedChapters.remove(ch.id) }
        }
        updateCounters()
    }

    func updateCounters() {
        let total = meta.chapterOrder.reduce(0) { $0 + (chapterWords[$1] ?? 0) }
        bookWords = total
        if meta.wordCount != total {
            meta.wordCount = total
            scheduleMetaSave()
        }
        trackDailyWords(total)
    }

    func writingDay(_ date: Date = Date()) -> String {
        var d = date
        if Calendar.current.component(.hour, from: d) < app.library.dayEndsAt {
            d = Calendar.current.date(byAdding: .day, value: -1, to: d) ?? d
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func trackDailyWords(_ total: Int) {
        let today = writingDay()
        if meta.dailyCounts[today] == nil {
            meta.dailyCounts[today] = DailyCount(start: total, end: total)
            scheduleMetaSave()
        } else if meta.dailyCounts[today]!.end != total {
            meta.dailyCounts[today]!.end = total
        }
        if var s = sprint, !s.done, total - s.startCount >= s.target {
            s.done = true
            sprint = s
            app.showToast("Sprint complete — \((total - s.startCount).formatted()) words. Well earned.", seconds: 6)
        }
    }

    var wordsToday: Int {
        guard let d = meta.dailyCounts[writingDay()] else { return 0 }
        return d.end - d.start
    }

    var goalText: String {
        if let s = sprint, !s.done {
            return "⚡ \((bookWords - s.startCount).formatted()) / \(s.target.formatted())"
        }
        let goal = app.library.dailyGoal
        return goal > 0 ? "\(wordsToday.formatted()) / \(goal.formatted()) today" : "\(wordsToday.formatted()) today"
    }

    var goalMet: Bool { app.library.dailyGoal > 0 && wordsToday >= app.library.dailyGoal && !(sprint.map { !$0.done } ?? false) }

    var wordCounterText: String {
        if let n = selectedWords, n > 0 { return "\(n.formatted()) selected" }
        if wordModeChapter {
            let n = currentChapterId.flatMap { chapterWords[$0] } ?? 0
            let i = (index(of: currentChapterId) ?? -1) + 1
            return "ch. \(i): \(n.formatted()) words"
        }
        return "\(bookWords.formatted()) words"
    }

    var positionText: String {
        let n = meta.chapterOrder.count
        guard n > 1 else { return "" } // a chapterless story needs no locator
        if let i = index(of: currentChapterId) { return "chapter \(i + 1) of \(n)" }
        return "\(n) chapters"
    }

    func chapterLabel(_ chId: String) -> String {
        let i = index(of: chId) ?? 0
        if isSolo { return meta.title == "Untitled" || meta.title.isEmpty ? "The story" : meta.title }
        if let t = meta.chapterTitles[chId], !t.isEmpty { return "\(i + 1) · \(t)" }
        return "Chapter \(i + 1)"
    }

    // MARK: - Title page

    func setTitle(_ t: String) {
        let v = t.trimmingCharacters(in: .whitespaces)
        meta.title = v.isEmpty ? "Untitled" : v
        scheduleMetaSave()
    }

    func setSubtitle(_ t: String) {
        meta.subtitle = t.trimmingCharacters(in: .whitespaces)
        scheduleMetaSave()
    }

    func setAuthor(_ t: String) {
        meta.author = t.trimmingCharacters(in: .whitespaces)
        scheduleMetaSave()
    }

    func setChapterTitle(_ chId: String, _ t: String) {
        meta.chapterTitles[chId] = t.trimmingCharacters(in: .whitespaces)
        scheduleMetaSave()
    }

    func setChapterNote(_ chId: String, _ t: String) {
        meta.chapterNotes[chId] = t.trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleMetaSave()
    }

    /// Enter on the title page drops you into chapter one.
    func titleEnter() {
        if meta.chapterOrder.isEmpty { newChapter() }
        else { manuscript?.focusChapterEnd(meta.chapterOrder[0]) }
    }

    // MARK: - Tabs

    func switchTab(_ t: EditorTab) {
        guard let m = manuscript else { tab = t; return }
        if tab == t { return }
        // every tab keeps its place while the book is open
        if tab == .manuscript {
            tabCaret = m.captureCaret()
            tabScroll[.manuscript] = m.scrollOffset
        }
        flushNotes()
        if t == .outline && meta.chapterOrder.isEmpty { _ = createChapter(at: 0) }
        tab = t
        if t == .manuscript {
            DispatchQueue.main.async {
                if let c = self.tabCaret { m.restoreCaret(c) }
                if let s = self.tabScroll[.manuscript] { m.scrollOffset = s }
            }
        }
    }

    func renameTab(_ kind: String) {
        Task {
            let current = kind == "notes" ? meta.notesTabName : meta.outlineTabName
            guard let name = await app.askInput("Rename tab", placeholder: "New tab name", value: current),
                  !name.isEmpty else { return }
            meta.tabNames[kind] = name
            saveMeta()
            // renamed tabs become the default for future books
            app.library.tabDefaults[kind] = name
            app.saveLibrary()
        }
    }

    // MARK: - Chapter structure

    @discardableResult
    func createChapter(at idx: Int, content: NSAttributedString = NSAttributedString()) -> String {
        let chId = NEOID.chapter()
        let ch = makeChapter(chId, content)
        let i = max(0, min(idx, meta.chapterOrder.count))
        meta.chapterOrder.insert(chId, at: i)
        chapters.insert(ch, at: min(i, chapters.count))
        chapterWords[chId] = countWords(Prose.plainText(ch.storage))
        saveChapter(chId)
        saveMeta()
        structureChanged()
        return chId
    }

    func newChapter() {
        // after the chapter you're in; at the end if you're not in one
        let idx = index(of: currentChapterId).map { $0 + 1 } ?? meta.chapterOrder.count
        let chId = createChapter(at: idx)
        manuscript?.focusChapterEnd(chId, scroll: true)
    }

    func addChapterAtEnd() {
        switchTab(.manuscript)
        currentChapterId = meta.chapterOrder.last
        newChapter()
    }

    func structureChanged() {
        chapters.sort { (meta.chapterOrder.firstIndex(of: $0.id) ?? 0) < (meta.chapterOrder.firstIndex(of: $1.id) ?? 0) }
        structureVersion += 1
        manuscript?.rebuild()
        updateCounters()
    }

    func deleteChapterQuiet(_ chId: String) {
        meta.chapterOrder.removeAll { $0 == chId }
        chapters.removeAll { $0.id == chId }
        chapterWords[chId] = nil
        flaggedChapters.remove(chId)
        meta.sectionNotes[chId] = nil
        meta.chapterNotes[chId] = nil
        stickies.removeAll { $0.chapterId == chId }
        if currentChapterId == chId { currentChapterId = nil }
        saveStickies()
        LibraryStore.deleteChapter(meta.id, chId)
        saveMeta()
        structureChanged()
    }

    func deleteChapterToDarlings(_ chId: String) {
        guard let ch = chapter(chId) else { return }
        snapshot("chapter delete")
        let idx = index(of: chId) ?? 0
        let text = Prose.plainText(ch.storage).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            darlings.append(Darling(id: NEOID.darling(), html: HTMLCodec.html(from: ch.storage),
                                    text: String(text.prefix(2000)), chapterId: nil,
                                    chapterLabel: "deleted Chapter \(idx + 1)"))
            saveDarlings()
        }
        deleteChapterQuiet(chId)
        resetNativeUndo()
        breakRun += 1
        if !text.isEmpty { app.showToast("Chapter removed — its words are in Darlings, or ⌘Z to undo") }
    }

    func chapterMenu(_ chId: String) {
        guard let ch = chapter(chId) else { return }
        let i = (index(of: chId) ?? 0) + 1
        let words = countWords(Prose.plainText(ch.storage))
        Task {
            let choice = await app.choose("Chapter \(i)", message: words > 0 ? "\(words.formatted()) words." : "This chapter is empty.", [
                ModalOption(label: "Delete chapter",
                            desc: words > 0 ? "Its words move to Darlings, recoverable anytime." : "Nothing to save — it just goes.",
                            value: "delete", danger: true)
            ])
            if choice == "delete" { deleteChapterToDarlings(chId) }
        }
    }

    func moveChapter(_ chId: String, to target: Int) {
        guard let from = index(of: chId) else { return }
        var order = meta.chapterOrder
        order.remove(at: from)
        let to = max(0, min(target > from ? target - 1 : target, order.count))
        if to == from { return }
        snapshot("chapter reorder")
        order.insert(chId, at: to)
        meta.chapterOrder = order
        saveMeta()
        structureChanged()
        reconcileMarks()
        resetNativeUndo()
        breakRun += 1
    }

    /// Everything from `loc` on becomes a new chapter right after this one.
    func splitChapter(_ chId: String, at loc: Int) {
        guard let ch = chapter(chId), let idx = index(of: chId) else { return }
        let ts = ch.storage
        let tail = ts.attributedSubstring(from: NSRange(location: loc, length: ts.length - loc))
        // the separator before the split point goes too
        let cut = loc > 0 ? loc - 1 : loc
        ts.replaceCharacters(in: NSRange(location: cut, length: ts.length - cut), with: "")
        chapterEdited(chId)
        let keep = manuscript?.scrollOffset
        let newId = createChapter(at: idx + 1, content: tail)
        // flags and section ghosts that moved belong to the new chapter now
        reconcileMarks()
        manuscript?.focusChapterStart(newId)
        if let keep { manuscript?.scrollOffset = keep }
        resetNativeUndo()
        breakRun += 1
    }

    /// Backspace at the very start of a chapter: swallow an empty chapter
    /// above, or merge this one up into the one before (the inverse of a split).
    func backspaceAtChapterStart(_ chId: String) -> Bool {
        guard let idx = index(of: chId), idx > 0, let cur = chapter(chId) else { return false }
        let prevId = meta.chapterOrder[idx - 1]
        guard let prev = chapter(prevId) else { return false }
        if Prose.plainText(prev.storage, skipGhosts: false).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshot("empty chapter removed")
            deleteChapterQuiet(prevId)
            manuscript?.focusChapterStart(chId)
            resetNativeUndo()
            breakRun += 1
            return true
        }
        snapshot("chapters merged")
        let keep = manuscript?.scrollOffset
        let prevParas = Prose.paragraphs(prev.storage.string as NSString).count
        let body = NSAttributedString(attributedString: cur.storage)
        prev.storage.append(NSAttributedString(string: "\n"))
        prev.storage.append(body)
        chapterEdited(prevId)
        for i in stickies.indices where stickies[i].chapterId == chId { stickies[i].chapterId = prevId }
        saveStickies()
        for i in darlings.indices where darlings[i].chapterId == chId { darlings[i].chapterId = prevId }
        saveDarlings()
        if let notes = meta.sectionNotes[chId] {
            meta.sectionNotes[prevId, default: []].append(contentsOf: notes)
            meta.sectionNotes[chId] = nil
        }
        meta.chapterTitles[chId] = nil
        meta.chapterNotes[chId] = nil
        meta.chapterOrder.removeAll { $0 == chId }
        chapters.removeAll { $0.id == chId }
        chapterWords[chId] = nil
        LibraryStore.deleteChapter(meta.id, chId)
        saveChapter(prevId)
        saveMeta()
        structureChanged()
        manuscript?.restoreCaret(Caret(chId: prevId, pIdx: prevParas, off: 0, scroll: keep))
        resetNativeUndo()
        breakRun += 1
        return true
    }

    /// Backspace in an empty chapter deletes it.
    func backspaceInEmptyChapter(_ chId: String) -> Bool {
        guard let ch = chapter(chId), let idx = index(of: chId), meta.chapterOrder.count > 1 else { return false }
        guard Prose.plainText(ch.storage, skipGhosts: false).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        snapshot("empty chapter removed")
        if idx > 0 {
            let prev = meta.chapterOrder[idx - 1]
            deleteChapterQuiet(chId)
            manuscript?.focusChapterEnd(prev)
        } else {
            // an empty chapter 1 dissolves too; the caret lands at the top of the new chapter 1
            let next = meta.chapterOrder[1]
            deleteChapterQuiet(chId)
            manuscript?.focusChapterStart(next)
        }
        resetNativeUndo()
        breakRun += 1
        return true
    }

    // MARK: - Structural undo

    /// Typing has the native ⌘Z. This covers the big moves — chapter splits,
    /// merges and deletes, reorders, replace-all, darlings — with snapshots.
    func snapshot(_ label: String, rejoin: Bool = false) {
        var contents: [String: NSAttributedString] = [:]
        for ch in chapters { contents[ch.id] = NSAttributedString(attributedString: ch.storage) }
        undoStack.append(Snapshot(label: label, rejoin: rejoin, caret: manuscript?.captureCaret(),
                                  chapterOrder: meta.chapterOrder, contents: contents,
                                  chapterTitles: meta.chapterTitles, chapterNotes: meta.chapterNotes,
                                  sectionNotes: meta.sectionNotes, darlings: darlings, stickies: stickies))
        if undoStack.count > 10 { undoStack.removeFirst() }
    }

    func structuralUndo() {
        guard let snap = undoStack.popLast() else { return }
        meta.chapterOrder = snap.chapterOrder
        meta.chapterTitles = snap.chapterTitles
        meta.chapterNotes = snap.chapterNotes
        meta.sectionNotes = snap.sectionNotes
        darlings = snap.darlings
        stickies = snap.stickies
        var rebuilt: [Chapter] = []
        for chId in snap.chapterOrder {
            let content = snap.contents[chId] ?? NSAttributedString()
            if let existing = chapter(chId) {
                existing.storage.setAttributedString(content)
                rebuilt.append(existing)
            } else {
                rebuilt.append(makeChapter(chId, content))
            }
        }
        chapters = rebuilt
        // resurrect any chapter files the action deleted
        for ch in chapters { saveChapter(ch.id) }
        saveDarlings()
        saveStickies()
        saveMeta()
        if let c = currentChapterId, !meta.chapterOrder.contains(c) { currentChapterId = nil }
        recountAll()
        structureChanged()
        if let c = snap.caret { manuscript?.restoreCaret(c) }
        if snap.rejoin { rejoinAtCaret() }
        resetNativeUndo()
    }

    /// After undoing a double-Enter break, close the split the gesture's first
    /// Enter made: the caret's paragraph flows back into the one above it.
    private func rejoinAtCaret() {
        guard let tv = manuscript?.activeTextView(), let ch = chapter(tv.chapterId) else { return }
        let ts = ch.storage
        let s = ts.string as NSString
        let blk = Prose.paragraph(s, at: tv.selectedRange().location)
        guard blk.location > 0 else { return }
        let prev = Prose.paragraph(s, at: blk.location - 1)
        guard Prose.blockKind(ts, prev) != .sceneBreak, Prose.blockKind(ts, blk) != .sceneBreak else { return }
        let seam = NSMaxRange(prev)
        if Prose.isBlank(s, blk) {
            ts.replaceCharacters(in: NSRange(location: seam, length: NSMaxRange(blk) - seam), with: "")
        } else {
            ts.replaceCharacters(in: NSRange(location: seam, length: 1), with: "")
        }
        chapterEdited(ch.id)
        tv.setSelectedRange(NSRange(location: seam, length: 0))
    }

    /// The text views' own undo history must never replay against text NEO
    /// has rearranged by hand.
    func resetNativeUndo() {
        manuscript?.window?.undoManager?.removeAllActions()
    }

    /// ⌘Z: right after a break operation (or when there's no typing to undo),
    /// the structural stack; otherwise the text's own history.
    func undo() -> Bool {
        let um = manuscript?.window?.undoManager
        let inText = manuscript?.window?.firstResponder is NSTextView
        if !undoStack.isEmpty && (breakRun > 0 || !inText || !(um?.canUndo ?? false)) {
            breakRun = max(0, breakRun - 1)
            structuralUndo()
            return true
        }
        return false
    }
}

/// Keeps a chapter's paragraphs coherent after every change to its characters
/// and restyles what changed. Lives outside the session because text storage
/// delegates must be NSObjects.
final class StorageNormalizer: NSObject, NSTextStorageDelegate {
    weak var session: BookSession?
    var mode: ProseMode = .chapter
    var theme: () -> PageTheme

    @MainActor init(session: BookSession) {
        self.session = session
        self.theme = { [weak session] in session?.theme ?? .default }
    }

    init(mode: ProseMode, theme: @escaping () -> PageTheme) {
        self.mode = mode
        self.theme = theme
    }

    func textStorage(_ ts: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            StorageNormalizer.normalize(ts, editedRange, mode: mode)
            ProseStyler.style(ts, around: editedRange, theme: theme(), mode: mode)
        }
    }

    /// 1. A flag is exactly one "⚑"; nothing typed beside it inherits it.
    /// 2. A paragraph means one thing throughout — its identity is read from
    ///    its end (the newline), which typing inside the paragraph never moves.
    /// 3. A *** holding prose is a stained paragraph, not a break.
    static func normalize(_ ts: NSTextStorage, _ edited: NSRange, mode: ProseMode) {
        let s = ts.string as NSString
        guard s.length > 0 else { return }
        let first = Prose.paragraph(s, at: min(edited.location, s.length))
        let last = Prose.paragraph(s, at: min(NSMaxRange(edited), s.length))
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)

        if span.length > 0 {
            var stray: [NSRange] = []
            ts.enumerateAttribute(.neoMark, in: span) { v, r, _ in
                guard v != nil else { return }
                for i in r.location..<NSMaxRange(r) where s.character(at: i) != Prose.markChar {
                    stray.append(NSRange(location: i, length: 1))
                }
            }
            for r in stray { ts.removeAttribute(.neoMark, range: r) }
        }
        guard mode == .chapter else { return }

        var para = first
        while true {
            let full = Prose.withSeparator(para, in: s)
            if full.length > 0 {
                let at = NSMaxRange(full) - 1
                var attrs: [NSAttributedString.Key: Any] = [:]
                for k in NSAttributedString.Key.paragraphKeys {
                    if let v = ts.attribute(k, at: at, effectiveRange: nil) { attrs[k] = v }
                }
                if (attrs[.neoBlock] as? String) == BlockKind.sceneBreak.rawValue,
                   s.substring(with: para).trimmingCharacters(in: .whitespaces) != Prose.sceneBreakText {
                    attrs[.neoBlock] = nil
                    attrs[.neoSecBrk] = nil
                }
                for k in NSAttributedString.Key.paragraphKeys {
                    if let v = attrs[k] { ts.addAttribute(k, value: v, range: full) }
                    else { ts.removeAttribute(k, range: full) }
                }
            }
            if para.location >= last.location || NSMaxRange(para) >= s.length { break }
            para = Prose.paragraph(s, at: NSMaxRange(para) + 1)
        }
    }
}
