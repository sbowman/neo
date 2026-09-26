import AppKit

/// All disk access. The layout is identical to the Electron build's:
///
///     ~/Documents/NEO Library/
///       library.json
///       _catalog.txt
///       book-<slug>-<id>/
///         book.json  chapters/<chId>.html  notes.html  outline.html
///         darlings.json  stickies.json  cover-<ms>.<ext>
///       Backups/  Exports/  neo-errors.log
enum LibraryStore {
    /// `defaults write com.hughhowey.neo.native NEOLibraryPath /some/dir` (or the
    /// `-NEOLibraryPath` launch argument) points NEO at another library.
    static let root: URL = {
        if let p = UserDefaults.standard.string(forKey: "NEOLibraryPath"), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("NEO Library", isDirectory: true)
    }()

    static var libraryFile: URL { root.appendingPathComponent("library.json") }
    static var exportsDir: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    static var backupsDir: URL { root.appendingPathComponent("Backups", isDirectory: true) }

    static func bookDir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private static var fm: FileManager { .default }

    // MARK: JSON helpers

    static func readJSONObject(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func writeJSONObject(_ obj: Any, to url: URL) {
        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
            // written to a temp file and renamed: never a half-written file
            try data.write(to: url, options: .atomic)
        } catch {
            logError("json", "\(url.lastPathComponent): \(error)")
        }
    }

    static func readText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func writeText(_ s: String, to url: URL) {
        do {
            try s.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logError("write", "\(url.path): \(error)")
        }
    }

    // MARK: Library

    static func ensureLibrary() {
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: libraryFile.path) {
            writeJSONObject(Library.seed().json, to: libraryFile)
        }
    }

    static func readLibrary() -> Library {
        ensureLibrary()
        if let d = readJSONObject(libraryFile) as? JSONDict { return Library(d) }
        return Library.seed()
    }

    static func writeLibrary(_ lib: Library) {
        ensureLibrary()
        writeJSONObject(lib.json, to: libraryFile)
        writeCatalog(lib)
    }

    /// A human-readable map of the library: which folder is which book.
    static func writeCatalog(_ lib: Library? = nil) {
        let lib = lib ?? readLibrary()
        var onShelf: [String: String] = [:]
        for s in lib.shelves { for id in s.bookIds { onShelf[id] = s.name } }
        var lines: [String] = []
        let dirs = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for d in dirs where d.hasPrefix("book-") {
            guard let m = readJSONObject(root.appendingPathComponent(d).appendingPathComponent("book.json")) as? JSONDict
            else { continue }
            let id = m.string("id") ?? d
            lines.append("\(m.string("title") ?? "Untitled")  —  \(d)  —  shelf: \(onShelf[id] ?? "(none — removed from shelves)")")
        }
        lines.sort { $0.localizedCompare($1) == .orderedAscending }
        writeText("NEO LIBRARY CATALOG — which folder is which book\n(regenerated automatically; edits here do nothing)\n\n"
                  + lines.joined(separator: "\n") + "\n",
                  to: root.appendingPathComponent("_catalog.txt"))
    }

    // MARK: Books

    static func createBook(title: String?, author: String) -> BookMeta {
        ensureLibrary()
        // folders carry a slug of the title when it's known (imports), so the
        // library reads like a bookshelf in Finder too
        let slug = String((title ?? "").lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(30))
        let slugPart = slug.isEmpty ? "" : "\(slug)-"
        let id = "book-\(slugPart)\(NEOID.stamp())-\(NEOID.random(5))"
        let dir = bookDir(id)
        try? fm.createDirectory(at: dir.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        let now = NEOID.isoNow()
        let meta = BookMeta([
            "id": id,
            "title": (title?.isEmpty == false ? title! : "Untitled"),
            "subtitle": "",
            "series": "",
            "author": author.isEmpty ? "Anonymous" : author,
            "wordGoal": 0,
            "created": now,
            "modified": now,
            "chapterOrder": [String](),
            "tabNames": ["notes": "Notes", "outline": "Outline"]
        ])
        writeJSONObject(meta.json, to: dir.appendingPathComponent("book.json"))
        writeText("", to: dir.appendingPathComponent("notes.html"))
        writeText("", to: dir.appendingPathComponent("outline.html"))
        writeJSONObject([Any](), to: dir.appendingPathComponent("darlings.json"))
        writeJSONObject([Any](), to: dir.appendingPathComponent("stickies.json"))
        return meta
    }

    static func readMeta(_ id: String) -> BookMeta? {
        guard let d = readJSONObject(bookDir(id).appendingPathComponent("book.json")) as? JSONDict else { return nil }
        return BookMeta(d)
    }

    static func writeMeta(_ meta: BookMeta, catalog: Bool = true) {
        var m = meta
        m.raw["modified"] = NEOID.isoNow()
        let dir = bookDir(meta.id)
        guard fm.fileExists(atPath: dir.path) else { return }
        writeJSONObject(m.json, to: dir.appendingPathComponent("book.json"))
        if catalog { writeCatalog() }
    }

    static func chapterURL(_ bookId: String, _ chId: String) -> URL {
        bookDir(bookId).appendingPathComponent("chapters").appendingPathComponent(chId + ".html")
    }

    static func readChapter(_ bookId: String, _ chId: String) -> String {
        readText(chapterURL(bookId, chId))
    }

    static func writeChapter(_ bookId: String, _ chId: String, _ html: String) {
        let dir = bookDir(bookId).appendingPathComponent("chapters")
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        writeText(html, to: chapterURL(bookId, chId))
    }

    static func deleteChapter(_ bookId: String, _ chId: String) {
        try? fm.removeItem(at: chapterURL(bookId, chId))
    }

    static func readAux(_ bookId: String, _ name: String) -> String {
        readText(bookDir(bookId).appendingPathComponent(name + ".html"))
    }

    static func writeAux(_ bookId: String, _ name: String, _ html: String) {
        writeText(html, to: bookDir(bookId).appendingPathComponent(name + ".html"))
    }

    static func readList(_ bookId: String, _ name: String) -> [JSONDict] {
        (readJSONObject(bookDir(bookId).appendingPathComponent(name + ".json")) as? [Any] ?? [])
            .compactMap { $0 as? JSONDict }
    }

    static func writeList(_ bookId: String, _ name: String, _ list: [JSONDict]) {
        writeJSONObject(list, to: bookDir(bookId).appendingPathComponent(name + ".json"))
    }

    /// Sends a book folder to the Trash. Words are never lost: if the volume
    /// has no Trash, the folder is left alone and shown in Finder instead.
    static func trashBook(_ id: String) -> Bool {
        do {
            try fm.trashItem(at: bookDir(id), resultingItemURL: nil)
            writeCatalog()
            return true
        } catch {
            logError("trash", "\(error)")
            NSWorkspace.shared.activateFileViewerSelecting([bookDir(id)])
            return false
        }
    }

    // MARK: Covers

    static let coverExtensions = ["png", "jpg", "jpeg", "webp", "heic", "tiff"]

    /// Copies the writer's image into the book folder. Timestamped names
    /// sidestep every caching gremlin.
    static func setCover(_ bookId: String, from src: URL) -> String? {
        var ext = src.pathExtension.lowercased()
        guard coverExtensions.contains(ext) else { return nil }
        if ext == "jpeg" { ext = "jpg" }
        let dir = bookDir(bookId)
        guard fm.fileExists(atPath: dir.path) else { return nil }
        clearCovers(dir)
        let fname = "cover-\(Int64(Date().timeIntervalSince1970 * 1000)).\(ext)"
        do {
            try fm.copyItem(at: src, to: dir.appendingPathComponent(fname))
            return fname
        } catch {
            logError("cover", "\(error)")
            return nil
        }
    }

    static func removeCover(_ bookId: String) {
        clearCovers(bookDir(bookId))
    }

    private static func clearCovers(_ dir: URL) {
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where f.range(of: #"^cover-\d+\."#, options: .regularExpression) != nil {
            try? fm.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    static func coverURL(_ bookId: String, _ fname: String) -> URL? {
        guard fname.range(of: #"^cover-\d+\.[a-z]+$"#, options: .regularExpression) != nil else { return nil }
        let u = bookDir(bookId).appendingPathComponent(fname)
        return fm.fileExists(atPath: u.path) ? u : nil
    }

    // MARK: Errors and backups

    static func logError(_ source: String, _ message: String) {
        let line = "[\(NEOID.isoNow())] [\(source)] \(message)\n"
        let url = root.appendingPathComponent("neo-errors.log")
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// One zip of the whole library per day, keeping the last 14.
    static func dailyBackup() {
        let root = self.root
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
                let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
                let target = backupsDir.appendingPathComponent("neo-backup-\(day).zip")
                if FileManager.default.fileExists(atPath: target.path) { return }
                let zip = ZipWriter()
                let skip: Set<String> = ["Backups", "Exports"]
                func walk(_ dir: URL, _ rel: String) throws {
                    for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
                        if rel.isEmpty && skip.contains(name) { continue }
                        let full = dir.appendingPathComponent(name)
                        let relPath = rel.isEmpty ? name : rel + "/" + name
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir)
                        if isDir.boolValue { try walk(full, relPath) }
                        else { zip.add(relPath, data: try Data(contentsOf: full)) }
                    }
                }
                try walk(root, "")
                try zip.finish().write(to: target, options: .atomic)
                var backups = (try FileManager.default.contentsOfDirectory(atPath: backupsDir.path))
                    .filter { $0.hasPrefix("neo-backup-") }.sorted()
                while backups.count > 14 {
                    try? FileManager.default.removeItem(at: backupsDir.appendingPathComponent(backups.removeFirst()))
                }
            } catch {
                DispatchQueue.main.async { logError("backup", "\(error)") }
            }
        }
    }
}
