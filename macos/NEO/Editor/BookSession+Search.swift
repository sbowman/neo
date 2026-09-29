import AppKit

/// Find & replace: always the whole book, first chapter to last. Matches are
/// highlighted, never selected, so nothing moves until the writer asks.
extension BookSession {
    func openSearch() {
        switchTab(.manuscript)
        if let tv = manuscript?.activeTextView(), tv.selectedRange().length > 0,
           let ch = chapter(tv.chapterId) {
            let preset = ch.storage.attributedSubstring(from: tv.selectedRange()).string
            searchQuery = String(preset.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        searchVisible = true
        searchFocusToken += 1
        runSearch()
    }

    func closeSearch() {
        searchVisible = false
        searchMatches = []
        searchIndex = -1
        manuscript?.clearSearchHighlights()
        manuscript?.focusCurrent()
    }

    func runSearch() {
        searchMatches = []
        searchIndex = -1
        let q = searchQuery
        if !q.isEmpty {
            for ch in chapters {
                let s = ch.storage.string as NSString
                var from = 0
                while from < s.length {
                    let r = s.range(of: q, options: [.caseInsensitive], range: NSRange(location: from, length: s.length - from))
                    if r.location == NSNotFound { break }
                    searchMatches.append((ch.id, r))
                    from = NSMaxRange(r)
                }
            }
        }
        lastSearchedQuery = q
        manuscript?.highlightSearch(searchMatches, current: nil)
    }

    var searchCountText: String {
        if searchQuery.isEmpty { return "" }
        if searchMatches.isEmpty { return "none" }
        if searchIndex >= 0 { return "\(searchIndex + 1) of \(searchMatches.count)" }
        return "\(searchMatches.count) found"
    }

    private var lastSearchedQuery: String {
        get { manuscript?.lastSearchedQuery ?? "" }
        set { manuscript?.lastSearchedQuery = newValue }
    }

    func freshSearchIfStale() {
        if lastSearchedQuery != searchQuery { runSearch() }
    }

    func gotoMatch(_ i: Int) {
        freshSearchIfStale()
        let n = searchMatches.count
        guard n > 0 else { return }
        searchIndex = ((i % n) + n) % n
        let m = searchMatches[searchIndex]
        wordstar?.remember()
        wordstar?.lastFind = WordStar.Spot(chId: m.chId, loc: m.range.location)
        manuscript?.highlightSearch(searchMatches, current: searchIndex)
        manuscript?.reveal(m.chId, m.range, select: false)
    }

    func nextMatch() { gotoMatch(searchIndex + 1) }
    func previousMatch() { gotoMatch(searchIndex - 1) }

    /// Tab from the find field: the caret goes to the end of the current match.
    func caretToMatch() {
        freshSearchIfStale()
        guard !searchMatches.isEmpty else { return }
        let m = searchMatches[max(0, searchIndex)]
        manuscript?.reveal(m.chId, NSRange(location: NSMaxRange(m.range), length: 0), select: true)
    }

    func replaceCurrent() {
        freshSearchIfStale()
        guard !searchMatches.isEmpty else { app.showToast("No matches"); return }
        if searchIndex < 0 { searchIndex = 0 }
        let m = searchMatches[searchIndex]
        guard let ch = chapter(m.chId), NSMaxRange(m.range) <= ch.storage.length else { runSearch(); return }
        let attrs = ch.storage.attributes(at: m.range.location, effectiveRange: nil)
            .filter { $0.key == .neoBold || $0.key == .neoItalic }
        edit(m.chId, m.range, NSAttributedString(string: replaceText, attributes: attrs), actionName: "Replace")
        let old = searchIndex
        runSearch()
        if !searchMatches.isEmpty { gotoMatch(min(old, searchMatches.count - 1)) }
    }

    func replaceAll() {
        let q = searchQuery
        guard !q.isEmpty else { return }
        snapshot("replace all")
        var n = 0
        for ch in chapters {
            let ts = ch.storage
            var ranges: [NSRange] = []
            let s = ts.string as NSString
            var from = 0
            while from < s.length {
                let r = s.range(of: q, options: [.caseInsensitive], range: NSRange(location: from, length: s.length - from))
                if r.location == NSNotFound { break }
                ranges.append(r)
                from = NSMaxRange(r)
            }
            guard !ranges.isEmpty else { continue }
            ts.beginEditing()
            for r in ranges.reversed() {
                let attrs = ts.attributes(at: r.location, effectiveRange: nil)
                    .filter { $0.key == .neoBold || $0.key == .neoItalic || NSAttributedString.Key.paragraphKeys.contains($0.key) }
                ts.replaceCharacters(in: r, with: NSAttributedString(string: replaceText, attributes: attrs))
            }
            ts.endEditing()
            n += ranges.count
            chapterEdited(ch.id)
        }
        if n == 0 {
            undoStack.removeLast() // nothing changed, nothing to undo
        } else {
            resetNativeUndo()
            breakRun += 1
        }
        app.showToast(n > 0 ? "\(n) replaced across the whole book — ⌘Z to undo" : "0 replaced")
        runSearch()
    }
}
