import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

struct ModalOption: Identifiable {
    var label: String
    var desc: String? = nil
    var value: String
    var danger = false
    var id: String { value }
}

/// A dialog in NEO's own dark style. The continuation is resumed exactly once.
enum Modal: Identifiable {
    case input(title: String, placeholder: String, value: String, done: (String?) -> Void)
    case options(title: String, message: String?, options: [ModalOption], done: (String?) -> Void)
    case firstRun
    case stats
    case help
    case about

    var id: String {
        switch self {
        case .input(let t, _, _, _): return "input:" + t
        case .options(let t, _, _, _): return "options:" + t
        case .firstRun: return "firstRun"
        case .stats: return "stats"
        case .help: return "help"
        case .about: return "about"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var library: Library
    var session: BookSession?
    var metas: [String: BookMeta] = [:]
    var modal: Modal?
    var toast: String?
    @ObservationIgnored private var toastTimer: DispatchWorkItem?
    @ObservationIgnored private var flushTimer: Timer?

    private init() {
        var lib = LibraryStore.readLibrary()
        lib.ensureAuthors()
        library = lib
        reloadMetas()
        if !lib.firstRunDone { modal = .firstRun }
        LibraryStore.dailyBackup()
        // flush the open book every 20 seconds
        flushTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.session?.flushAll() }
        }
    }

    // MARK: - Library

    func saveLibrary() {
        LibraryStore.writeLibrary(library)
    }

    func reloadMetas() {
        var m: [String: BookMeta] = [:]
        for s in library.shelves {
            for id in s.bookIds where m[id] == nil {
                if let meta = LibraryStore.readMeta(id) { m[id] = meta }
            }
        }
        metas = m
    }

    var theme: PageTheme {
        PageTheme(night: library.pageTheme != "paper",
                  bodyFont: NEOFonts.bodyNames.contains(library.bodyFont ?? "") ? library.bodyFont! : "Georgia",
                  dropCap: library.dropCapStyle ?? "literary",
                  fontSize: CGFloat(min(22, max(14, library.editorFontSize ?? 17))),
                  zoom: CGFloat(min(1.6, max(0.75, library.pageZoom ?? 1))))
    }

    /// Something about the page's look changed: restyle every open surface.
    func themeChanged() {
        saveLibrary()
        guard let s = session else { return }
        for ch in s.chapters { ProseStyler.styleAll(ch.storage, theme: theme, mode: .chapter) }
        s.manuscript?.applyTheme()
    }

    func setPageTheme(_ v: String) { library.pageTheme = v; themeChanged() }
    func setBodyFont(_ f: String) { library.bodyFont = f; themeChanged() }
    func setDropCap(_ d: String) { library.dropCapStyle = d; themeChanged() }
    func toggleBright() { library.uiBright.toggle(); saveLibrary() }

    func changeFontSize(_ delta: Int) {
        if delta == 0 {
            library.editorFontSize = 17
            library.pageZoom = 1 // ⌘0 resets the zoom too
        } else {
            library.editorFontSize = min(22, max(14, (library.editorFontSize ?? 17) + Double(delta)))
        }
        themeChanged()
    }

    func setZoom(_ z: CGFloat) {
        let next = Double(min(1.6, max(0.75, z)))
        if abs(next - (library.pageZoom ?? 1)) < 0.001 { return }
        library.pageZoom = next
        guard let s = session else { saveLibrary(); return }
        for ch in s.chapters { ProseStyler.styleAll(ch.storage, theme: theme, mode: .chapter) }
        s.manuscript?.applyTheme()
        s.debounce("zoom-save", 0.6) { self.saveLibrary() }
    }

    func zoom(by k: CGFloat) { setZoom(theme.zoom * k) }

    func toggleTypewriter() {
        library.typewriter.toggle()
        saveLibrary()
        session?.manuscript?.layoutSheets()
        showToast(library.typewriter ? "Typewriter scrolling ON — your line stays centred" : "Typewriter scrolling off")
    }

    // MARK: - Dialogs

    func askInput(_ title: String, placeholder: String, value: String = "") async -> String? {
        await withCheckedContinuation { c in
            modal = .input(title: title, placeholder: placeholder, value: value) { v in
                self.modal = nil
                c.resume(returning: v)
            }
        }
    }

    func choose(_ title: String, message: String? = nil, _ options: [ModalOption]) async -> String? {
        await withCheckedContinuation { c in
            modal = .options(title: title, message: message, options: options) { v in
                self.modal = nil
                c.resume(returning: v)
            }
        }
    }

    func dismissModal() {
        switch modal {
        case .input(_, _, _, let done): done(nil)
        case .options(_, _, _, let done): done(nil)
        case .firstRun: break // the welcome must be answered
        default: modal = nil
        }
    }

    func showToast(_ msg: String, seconds: Double = 4) {
        toast = msg
        toastTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: - Authors and shelves

    var currentAuthor: Author { library.currentAuthor }
    var displayAuthor: String { currentAuthor.name.isEmpty ? "Anonymous" : currentAuthor.name }
    var visibleShelves: [Shelf] { library.shelves(for: currentAuthor.id) }

    func finishFirstRun(name: String, pen: String, style: String, body: String, dropCap: String) {
        library.authorName = name
        library.penNames = pen.isEmpty ? [] : [pen]
        library.writingStyle = style
        library.bodyFont = body
        library.dropCapStyle = dropCap
        library.firstRunDone = true
        // the shelf was drawn (and the author seeded as Anonymous) before the name was typed
        if let i = library.authors.firstIndex(where: { $0.id == currentAuthor.id }) {
            library.authors[i].name = !name.isEmpty ? name : (!pen.isEmpty ? pen : "Anonymous")
        }
        modal = nil
        saveLibrary()
    }

    func addShelf() {
        library.shelves.append(Shelf(id: "shelf-" + NEOID.stamp(), name: "New Shelf", authorId: currentAuthor.id))
        saveLibrary()
    }

    func renameShelf(_ id: String, _ name: String) {
        guard let i = library.shelfIndex(id) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { library.shelves[i].name = n }
        saveLibrary()
    }

    func shelfMenu(_ shelf: Shelf) {
        Task {
            let n = shelf.bookIds.count
            let choice = await choose("Shelf “\(shelf.name)”", message: nil, [
                ModalOption(label: "Export shelf as anthology…",
                            desc: "Collect \(n > 0 ? "its \(n)" : "the") work\(n == 1 ? "" : "s"), in shelf order, into a single book with a table of contents.",
                            value: "anthology"),
                ModalOption(label: "Delete shelf", desc: "Books move to another shelf. Nothing is deleted from disk.", value: "del", danger: true)
            ])
            if choice == "anthology" { await exportAnthology(shelf) }
            if choice == "del" { deleteShelf(shelf.id) }
        }
    }

    func deleteShelf(_ id: String) {
        let mine = visibleShelves
        guard mine.count > 1 else {
            showToast("This is your only shelf — add another before deleting this one")
            return
        }
        guard let shelf = mine.first(where: { $0.id == id }),
              let other = mine.first(where: { $0.id != id }),
              let oi = library.shelfIndex(other.id) else { return }
        for b in shelf.bookIds where !library.shelves[oi].bookIds.contains(b) { library.shelves[oi].bookIds.append(b) }
        library.shelves.removeAll { $0.id == id }
        saveLibrary()
    }

    /// Shelves reorder among the whole list, keeping other authors' in place.
    func moveShelf(_ id: String, before targetId: String?) {
        guard let from = library.shelfIndex(id), id != targetId else { return }
        let moving = library.shelves.remove(at: from)
        if let targetId, let to = library.shelfIndex(targetId) {
            library.shelves.insert(moving, at: to)
        } else {
            library.shelves.append(moving)
        }
        saveLibrary()
    }

    /// A book dropped on a shelf, before `beforeId` (or at the end).
    func moveBook(_ bookId: String, to shelfId: String, before beforeId: String?) {
        guard bookId != beforeId else { return }
        for i in library.shelves.indices { library.shelves[i].bookIds.removeAll { $0 == bookId } }
        guard let si = library.shelfIndex(shelfId) else { return }
        if let beforeId, let k = library.shelves[si].bookIds.firstIndex(of: beforeId) {
            library.shelves[si].bookIds.insert(bookId, at: k)
        } else {
            library.shelves[si].bookIds.append(bookId)
        }
        saveLibrary()
    }

    func authorMenu() {
        Task {
            let cur = currentAuthor
            var opts: [ModalOption] = library.authors.filter { $0.id != cur.id }.map {
                ModalOption(label: "Write as " + $0.name, desc: "Switch to this name’s shelves", value: "sw:" + $0.id)
            }
            opts.append(ModalOption(label: "Rename " + cur.name, value: "rename"))
            opts.append(ModalOption(label: "Add a pen name…", desc: "A separate set of shelves under another name", value: "add"))
            if library.authors.count > 1 {
                opts.append(ModalOption(label: "Remove " + cur.name,
                                        desc: "These shelves and books move to your other name. Nothing is deleted from disk.",
                                        value: "del", danger: true))
            }
            guard let pick = await choose("Writing as " + cur.name, message: nil, opts) else { return }
            if pick.hasPrefix("sw:") {
                library.currentAuthorId = String(pick.dropFirst(3))
            } else if pick == "rename" {
                guard let name = await askInput("Author name", placeholder: "Shown on your title pages", value: cur.name) else { return }
                if let i = library.authors.firstIndex(where: { $0.id == cur.id }), !name.isEmpty { library.authors[i].name = name }
                library.authorName = library.authors[0].name // the legacy field follows the first name
            } else if pick == "add" {
                guard let name = await askInput("New pen name", placeholder: "Shown on that name’s title pages"), !name.isEmpty else { return }
                let a = Author(id: "a-" + NEOID.stamp(), name: name)
                library.authors.append(a)
                library.currentAuthorId = a.id
                library.shelves.append(Shelf(id: "shelf-" + NEOID.stamp(), name: "Works in Progress", authorId: a.id))
            } else if pick == "del" {
                let home = library.authors[0].id
                let rest = library.authors.filter { $0.id != cur.id }
                guard let target = rest.first else { return }
                for i in library.shelves.indices where (library.shelves[i].authorId ?? home) == cur.id {
                    library.shelves[i].authorId = target.id
                }
                library.authors = rest
                library.currentAuthorId = target.id
                library.authorName = library.authors[0].name
            }
            saveLibrary()
        }
    }

    // MARK: - Books

    func tabDefaults() -> [String: String] {
        ["notes": library.tabDefaults["notes"] ?? "Notes", "outline": library.tabDefaults["outline"] ?? "Outline"]
    }

    func createBook(on shelfId: String) {
        var meta = LibraryStore.createBook(title: nil, author: displayAuthor)
        meta.tabNames = tabDefaults()
        LibraryStore.writeMeta(meta)
        if let i = library.shelfIndex(shelfId) { library.shelves[i].bookIds.append(meta.id) }
        saveLibrary()
        metas[meta.id] = meta
        open(meta.id)
    }

    func open(_ bookId: String) {
        guard let meta = LibraryStore.readMeta(bookId) else {
            showToast("That book’s folder is missing from your NEO Library")
            return
        }
        session?.close()
        session = BookSession(app: self, meta: meta)
    }

    func backToShelf() {
        guard let s = session else { return }
        s.close()
        session = nil
        reloadMetas()
    }

    func updateMeta(_ meta: BookMeta) {
        LibraryStore.writeMeta(meta)
        metas[meta.id] = meta
        if session?.meta.id == meta.id {
            session?.meta.coverImage = meta.coverImage
            session?.meta.wordGoal = meta.wordGoal
        }
    }

    func pickCover(_ meta: BookMeta) {
        let panel = NSOpenPanel()
        panel.title = "Choose cover art"
        panel.message = "A 2:3 image works best."
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCover(meta.id, url)
    }

    func removeCover(_ meta: BookMeta) {
        var m = metas[meta.id] ?? meta
        LibraryStore.removeCover(meta.id)
        m.coverImage = nil
        m.raw["coverMode"] = nil
        updateMeta(m)
    }

    func setWordGoal(_ meta: BookMeta) {
        Task {
            guard let goal = await askInput("Word count goal for “\(meta.title)”", placeholder: "e.g. 80000 — blank removes the goal",
                                            value: meta.wordGoal > 0 ? String(meta.wordGoal) : "") else { return }
            var m = metas[meta.id] ?? meta
            m.wordGoal = Int(goal.filter(\.isNumber)) ?? 0
            updateMeta(m)
        }
    }

    func removeFromShelves(_ meta: BookMeta) {
        for i in library.shelves.indices { library.shelves[i].bookIds.removeAll { $0 == meta.id } }
        saveLibrary()
        showToast("“\(meta.title)” removed from the shelves — its files are still in your NEO Library")
    }

    func trashBook(_ meta: BookMeta) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(meta.title)” to the Trash?"
        alert.informativeText = "The book folder goes to your system trash, so you can recover it."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if LibraryStore.trashBook(meta.id) {
            for i in library.shelves.indices { library.shelves[i].bookIds.removeAll { $0 == meta.id } }
            saveLibrary()
            metas[meta.id] = nil
        } else {
            showToast("NEO couldn’t move that folder to the Trash — it’s untouched, and shown in Finder")
        }
    }

    /// Something dropped from Finder onto a book: an image becomes its cover,
    /// a manuscript imports onto the book's shelf.
    func dropOnBook(_ meta: BookMeta, _ urls: [URL]) {
        guard let url = urls.first else { return }
        if LibraryStore.coverExtensions.contains(url.pathExtension.lowercased()) {
            setCover(meta.id, url)
        } else if Importer.canImport(url) {
            let home = library.shelves.first { $0.bookIds.contains(meta.id) }?.id
            importFiles(urls, shelfId: home)
        }
    }

    func setCover(_ bookId: String, _ url: URL) {
        guard var m = metas[bookId] ?? LibraryStore.readMeta(bookId) else { return }
        guard let fname = LibraryStore.setCover(bookId, from: url) else {
            showToast("That image couldn’t be used as a cover")
            return
        }
        m.coverImage = fname
        m.raw["coverMode"] = "image" // the Electron build reads this
        updateMeta(m)
        CoverImageCache.forget(bookId)
    }

    // MARK: - Import

    func pickImport() {
        let panel = NSOpenPanel()
        panel.title = "Bring your manuscripts home"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Importer.extensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, shelfId: visibleShelves.first?.id ?? library.shelves.first?.id)
    }

    /// Parsed manuscripts become books on a shelf.
    func importFiles(_ urls: [URL], shelfId: String?) {
        let files = urls.filter(Importer.canImport)
        guard !files.isEmpty else { showToast("No .docx, .txt, or .md files in that drop"); return }
        guard let sid = shelfId ?? visibleShelves.first?.id, let si = library.shelfIndex(sid) else { return }
        var ok = 0
        for url in files {
            do {
                let r = try Importer.importFile(url)
                let title = r.title ?? r.name
                var meta = LibraryStore.createBook(title: title, author: r.author ?? displayAuthor)
                meta.title = title
                meta.tabNames = tabDefaults()
                var words = 0
                for ch in r.chapters {
                    let chId = NEOID.chapter()
                    LibraryStore.writeChapter(meta.id, chId, Importer.html(ch))
                    meta.chapterOrder.append(chId)
                    words += Importer.words(ch)
                }
                meta.wordCount = words
                LibraryStore.writeMeta(meta, catalog: false)
                library.shelves[si].bookIds.append(meta.id)
                metas[meta.id] = meta
                ok += 1
            } catch {
                LibraryStore.logError("import", "\(url.lastPathComponent): \(error)")
                showToast("Couldn't import \(url.lastPathComponent): \(error.localizedDescription)", seconds: 6)
            }
        }
        saveLibrary()
        if ok > 0 {
            showToast("\(ok) book\(ok == 1 ? "" : "s") imported onto “\(library.shelves[si].name)” — chapters and scene breaks detected", seconds: 6)
        }
    }

    // MARK: - Export

    func exportData(_ s: BookSession) -> Exporter.Book {
        let order = s.meta.chapterOrder
        let sections = order.enumerated().compactMap { (i, chId) -> Exporter.Section? in
            guard let ch = s.chapter(chId) else { return nil }
            return Exporter.Section(num: i + 1, heading: Exporter.heading(index: i, of: order.count, title: s.meta.chapterTitles[chId]),
                                    paras: Exporter.paras(from: ch.storage))
        }
        return Exporter.Book(id: s.meta.id, title: s.meta.title, subtitle: s.meta.subtitle, author: s.meta.author, sections: sections)
    }

    private func savePanel(_ name: String, _ ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + "." + ext
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func export(_ format: String) {
        guard let s = session else { showToast("Open a book first"); return }
        s.flushAll()
        let d = exportData(s)
        Task { await write(d, format: format, coverFor: (s.meta.id, s.meta.coverImage)) }
    }

    func write(_ d: Exporter.Book, format: String, coverFor: (String?, String?), to target: URL? = nil) async {
        guard let url = target ?? savePanel(Exporter.safeName(d.title), format) else { return }
        do {
            let data: Data
            switch format {
            case "txt": data = Data(Exporter.txt(d).utf8)
            case "md": data = Data(Exporter.md(d).utf8)
            case "docx": data = Exporter.docx(d)
            case "epub": data = Exporter.epub(d, cover: ExportCover.make(bookId: coverFor.0, coverImage: coverFor.1, title: d.title, author: d.author))
            case "pdf":
                showToast("Setting type…")
                let cover = ExportCover.make(bookId: coverFor.0, coverImage: coverFor.1, title: d.title, author: d.author)
                data = try await PDFRenderer.render(html: Exporter.html(d, cover: cover))
            default:
                let cover = ExportCover.make(bookId: coverFor.0, coverImage: coverFor.1, title: d.title, author: d.author)
                data = Data(Exporter.html(d, cover: cover).utf8)
            }
            try data.write(to: url, options: .atomic)
            showToast("Exported: " + url.lastPathComponent)
        } catch {
            LibraryStore.logError("export", "\(error)")
            showToast("Export failed: \(error.localizedDescription)", seconds: 6)
        }
    }

    func exportAnthology(_ shelf: Shelf) async {
        guard !shelf.bookIds.isEmpty else { showToast("This shelf has no books on it yet"); return }
        guard let title = await askInput("Anthology title", placeholder: "Shown on the title page, cover, and metadata", value: shelf.name) else { return }
        guard let format = await choose("Export the anthology as…", message: nil, [
            ModalOption(label: "EPUB", desc: "For ebook stores — the TOC lists every story.", value: "epub"),
            ModalOption(label: "Word (.docx)", desc: "For editors — each story starts on a new page.", value: "docx"),
            ModalOption(label: "PDF", desc: "For reading, sharing, and print.", value: "pdf")
        ]) else { return }
        session?.flushAll()
        let d = Exporter.anthology(shelf: shelf, title: title.isEmpty ? shelf.name : title, author: displayAuthor)
        guard !d.sections.isEmpty else { showToast("No words found on this shelf yet"); return }
        await write(d, format: format, coverFor: (d.id, nil))
    }

    // MARK: - Email a snapshot to yourself

    func emailSettings() async -> Bool {
        guard let addr = await askInput("Email drafts to", placeholder: "you@example.com", value: library.emailAddress ?? "") else { return false }
        if !addr.isEmpty { library.emailAddress = addr }
        guard let method = await choose("How should NEO email your drafts?", message: nil, [
            ModalOption(label: "Apple Mail", desc: "Fully automatic — the PDF is attached and addressed. Just hit send.", value: "mail"),
            ModalOption(label: "Gmail", desc: "Opens a pre-filled compose window in your browser. NEO shows you the PDF to drag into it.", value: "gmail")
        ]) else { return false }
        library.emailMethod = method
        saveLibrary()
        showToast("Email settings saved")
        return true
    }

    /// A timestamped PDF in the library's Exports folder, handed to your email
    /// with a SHA-256 fingerprint of the text: an outside-the-machine paper trail.
    func emailDraft() {
        guard let s = session else { showToast("Open a book first"); return }
        Task {
            s.flushAll()
            if library.emailAddress == nil || library.emailMethod == nil {
                guard await emailSettings() else { return }
            }
            let total = s.bookWords
            let text = s.meta.title + "\n" + s.chapters.map { Prose.plainText($0.storage) }.joined(separator: "\n")
            let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            let day = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            let when = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)
            let subject = "NEO draft — \(s.meta.title) — \(total.formatted()) words — \(day)"
            let gmail = library.emailMethod == "gmail"
            let body = "Draft snapshot of \"\(s.meta.title)\" — \(total.formatted()) words.\nSent from NEO on \(when).\n\n"
                + "SHA-256 fingerprint of the manuscript text:\n\(hash)\n\n"
                + (gmail ? "The PDF snapshot is in the Finder window NEO just opened — drag it into this email before sending." : "PDF snapshot attached.")
            showToast("Preparing your draft…")
            do {
                let pdf = try await PDFRenderer.render(html: Exporter.html(exportData(s), stamp: true))
                try FileManager.default.createDirectory(at: LibraryStore.exportsDir, withIntermediateDirectories: true)
                let stamp = String(ISO8601DateFormatter().string(from: Date()).prefix(19)).replacingOccurrences(of: ":", with: "-")
                let file = LibraryStore.exportsDir.appendingPathComponent("\(Exporter.safeName(s.meta.title))-\(stamp).pdf")
                try pdf.write(to: file)
                let to = library.emailAddress ?? ""
                if gmail {
                    var c = URLComponents(string: "https://mail.google.com/mail/")!
                    c.queryItems = [.init(name: "view", value: "cm"), .init(name: "fs", value: "1"),
                                    .init(name: "to", value: to), .init(name: "su", value: subject), .init(name: "body", value: body)]
                    if let u = c.url { NSWorkspace.shared.open(u) }
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                    showToast("Gmail compose opened — drag in the PDF NEO revealed, then send", seconds: 8)
                } else if mailDraft(to: to, subject: subject, body: body, file: file) {
                    showToast("Draft handed to Mail — hit send for your timestamp")
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                    showToast("Mail unavailable — snapshot saved to your Exports folder instead")
                }
            } catch {
                LibraryStore.logError("email", "\(error)")
                showToast("Couldn’t prepare the snapshot: \(error.localizedDescription)", seconds: 6)
            }
        }
    }

    private func mailDraft(to: String, subject: String, body: String, file: URL) -> Bool {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = """
        tell application "Mail"
          set msg to make new outgoing message with properties {subject:"\(esc(subject))", content:"\(esc(body))" & return & return, visible:true}
          tell msg to make new to recipient at end of to recipients with properties {address:"\(esc(to))"}
          tell msg to make new attachment with properties {file name:(POSIX file "\(esc(file.path))")} at after the last paragraph of content
          activate
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err { LibraryStore.logError("mail", "\(err)") }
        return err == nil
    }

    // MARK: - Keys that work everywhere

    /// Esc closes whatever's open; otherwise leaves full screen; otherwise
    /// walks back to the shelf.
    func handleEscape() -> Bool {
        if modal != nil { dismissModal(); return true }
        if let s = session, s.searchVisible { s.closeSearch(); return true }
        if let w = NSApp.keyWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil); return true }
        if session != nil { backToShelf(); return true }
        return false
    }

    func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
    }

    func undo() {
        if let s = session, s.undo() { return }
        if !NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) {
            session?.manuscript?.window?.undoManager?.undo()
        }
    }

    func redo() {
        if !NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) {
            session?.manuscript?.window?.undoManager?.redo()
        }
    }
}
