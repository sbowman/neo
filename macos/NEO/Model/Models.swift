import Foundation

// NEO's files are shared with the Electron build, so every model keeps the
// dictionary it was read from and only overwrites the keys it understands.
// Anything else in library.json / book.json survives a round trip untouched.

typealias JSONDict = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func string(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s) }
        return nil
    }
    func double(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func bool(_ k: String) -> Bool? { (self[k] as? NSNumber)?.boolValue }
    func dict(_ k: String) -> JSONDict? { self[k] as? JSONDict }
    func array(_ k: String) -> [Any]? { self[k] as? [Any] }
    func strings(_ k: String) -> [String] { (self[k] as? [Any])?.compactMap { $0 as? String } ?? [] }

    mutating func set(_ k: String, _ v: Any?) {
        if let v { self[k] = v } else { removeValue(forKey: k) }
    }
}

// MARK: - Library

struct Author: Identifiable, Equatable {
    var id: String
    var name: String
}

struct Shelf: Identifiable {
    var id: String
    var name: String
    var bookIds: [String]
    var authorId: String?
    var raw: JSONDict = [:]

    init(id: String, name: String, bookIds: [String] = [], authorId: String? = nil) {
        self.id = id; self.name = name; self.bookIds = bookIds; self.authorId = authorId
    }

    init(_ d: JSONDict) {
        raw = d
        id = d.string("id") ?? "shelf-" + NEOID.stamp()
        name = d.string("name") ?? "Shelf"
        bookIds = d.strings("bookIds")
        authorId = d.string("authorId")
    }

    var json: JSONDict {
        var d = raw
        d["id"] = id
        d["name"] = name
        d["bookIds"] = bookIds
        d.set("authorId", authorId)
        return d
    }
}

struct Library {
    var raw: JSONDict

    var authorName: String
    var penNames: [String]
    var firstRunDone: Bool
    var pageTheme: String          // "night" | "paper"
    var shelves: [Shelf]
    var authors: [Author]
    var currentAuthorId: String?
    var writingStyle: String?      // "pantser" | "plotter"
    var bodyFont: String?
    var dropCapStyle: String?      // "literary" | "fantasy" | "scifi"
    var tabDefaults: [String: String]
    var hintShown: Bool
    var dailyGoal: Int
    var dayEndsAt: Int
    var customWords: [String]
    var typewriter: Bool
    var editorFontSize: Double?
    var pageZoom: Double?
    var uiBright: Bool
    var emailAddress: String?
    var emailMethod: String?       // "mail" | "gmail"
    var lastOpenBookId: String?    // the book that was open at quit, reopened at launch
    var wordstarKeys: Bool         // WordStar's Control-key commands in the manuscript

    static func seed() -> Library {
        Library([
            "authorName": "",
            "penNames": [String](),
            "firstRunDone": false,
            "pageTheme": "night",
            "shelves": [["id": "shelf-1", "name": "Works in Progress", "bookIds": [String]()]]
        ])
    }

    init(_ d: JSONDict) {
        raw = d
        authorName = d.string("authorName") ?? ""
        penNames = d.strings("penNames")
        firstRunDone = d.bool("firstRunDone") ?? false
        pageTheme = d.string("pageTheme") ?? "night"
        shelves = (d.array("shelves") ?? []).compactMap { ($0 as? JSONDict).map(Shelf.init) }
        authors = (d.array("authors") ?? []).compactMap { a in
            guard let a = a as? JSONDict, let id = a.string("id") else { return nil }
            return Author(id: id, name: a.string("name") ?? "")
        }
        currentAuthorId = d.string("currentAuthorId")
        writingStyle = d.string("writingStyle")
        let fonts = d.dict("fonts") ?? [:]
        bodyFont = fonts.string("body")
        dropCapStyle = fonts.string("dropcap")
        tabDefaults = (d.dict("tabDefaults") ?? [:]).compactMapValues { $0 as? String }
        hintShown = d.bool("hintShown") ?? false
        dailyGoal = d.int("dailyGoal") ?? 0
        dayEndsAt = d.int("dayEndsAt") ?? 0
        customWords = d.strings("customWords")
        typewriter = d.bool("typewriter") ?? false
        editorFontSize = d.double("editorFontSize")
        pageZoom = d.double("pageZoom")
        uiBright = d.bool("uiBright") ?? false
        emailAddress = d.string("emailAddress")
        emailMethod = d.string("emailMethod")
        lastOpenBookId = d.string("lastOpenBookId")
        wordstarKeys = d.bool("wordstarKeys") ?? true
    }

    var json: JSONDict {
        var d = raw
        d["authorName"] = authorName
        d["penNames"] = penNames
        d["firstRunDone"] = firstRunDone
        d["pageTheme"] = pageTheme
        d["shelves"] = shelves.map(\.json)
        if !authors.isEmpty { d["authors"] = authors.map { ["id": $0.id, "name": $0.name] } }
        d.set("currentAuthorId", currentAuthorId)
        d.set("writingStyle", writingStyle)
        if bodyFont != nil || dropCapStyle != nil {
            var f = raw.dict("fonts") ?? [:]
            f.set("body", bodyFont)
            f.set("dropcap", dropCapStyle)
            d["fonts"] = f
        }
        if !tabDefaults.isEmpty { d["tabDefaults"] = tabDefaults }
        d["hintShown"] = hintShown
        d["dailyGoal"] = dailyGoal
        d["dayEndsAt"] = dayEndsAt
        d["customWords"] = customWords
        d["typewriter"] = typewriter
        d.set("editorFontSize", editorFontSize)
        d.set("pageZoom", pageZoom)
        d["uiBright"] = uiBright
        d.set("emailAddress", emailAddress)
        d.set("emailMethod", emailMethod)
        d.set("lastOpenBookId", lastOpenBookId)
        d["wordstarKeys"] = wordstarKeys
        return d
    }

    // Pen names: each author owns a set of shelves. Books all live in the one
    // library folder regardless — switching or removing a name never touches files.
    mutating func ensureAuthors() {
        if authors.isEmpty {
            let name = !authorName.isEmpty ? authorName : (penNames.first ?? "Anonymous")
            authors = [Author(id: "a1", name: name.isEmpty ? "Anonymous" : name)]
        }
    }

    var currentAuthor: Author {
        authors.first { $0.id == currentAuthorId } ?? authors.first ?? Author(id: "a1", name: "Anonymous")
    }

    func shelves(for authorId: String) -> [Shelf] {
        let home = authors.first?.id ?? "a1"
        return shelves.filter { ($0.authorId ?? home) == authorId }
    }

    func shelfIndex(_ id: String) -> Int? { shelves.firstIndex { $0.id == id } }
}

// MARK: - Book

struct SectionNote: Equatable {
    var id: String
    var text: String
}

struct DailyCount: Equatable {
    var start: Int
    var end: Int
}

struct BookMeta {
    var raw: JSONDict

    var id: String
    var title: String
    var subtitle: String
    var author: String
    var wordGoal: Int
    var chapterOrder: [String]
    var tabNames: [String: String]
    var chapterTitles: [String: String]
    var chapterNotes: [String: String]
    var sectionNotes: [String: [SectionNote]]
    var dailyCounts: [String: DailyCount]
    var lastChapterId: String?
    var lastScroll: Double
    /// where the caret was: its chapter, paragraph, and offset in that paragraph
    var lastCaret: (chapterId: String, paragraph: Int, offset: Int)?
    var wordCount: Int?
    var coverImage: String?

    init(_ d: JSONDict) {
        raw = d
        id = d.string("id") ?? ""
        title = d.string("title") ?? "Untitled"
        subtitle = d.string("subtitle") ?? ""
        author = d.string("author") ?? "Anonymous"
        wordGoal = d.int("wordGoal") ?? 0
        chapterOrder = d.strings("chapterOrder")
        tabNames = (d.dict("tabNames") ?? [:]).compactMapValues { $0 as? String }
        chapterTitles = (d.dict("chapterTitles") ?? [:]).compactMapValues { $0 as? String }
        chapterNotes = (d.dict("chapterNotes") ?? [:]).compactMapValues { $0 as? String }
        var sn: [String: [SectionNote]] = [:]
        for (k, v) in d.dict("sectionNotes") ?? [:] {
            sn[k] = (v as? [Any] ?? []).compactMap { s in
                guard let s = s as? JSONDict, let id = s.string("id") else { return nil }
                return SectionNote(id: id, text: s.string("text") ?? "")
            }
        }
        sectionNotes = sn
        var dc: [String: DailyCount] = [:]
        for (k, v) in d.dict("dailyCounts") ?? [:] {
            if let v = v as? JSONDict { dc[k] = DailyCount(start: v.int("start") ?? 0, end: v.int("end") ?? 0) }
        }
        dailyCounts = dc
        let lp = d.dict("lastPosition") ?? [:]
        lastChapterId = lp.string("chapterId")
        lastScroll = lp.double("scroll") ?? 0
        if let c = lp.string("caretChapterId"), let p = lp.int("caretParagraph"), let o = lp.int("caretOffset") {
            lastCaret = (c, p, o)
        }
        wordCount = d.int("wordCount")
        coverImage = d.string("coverImage")
    }

    var json: JSONDict {
        var d = raw
        d["id"] = id
        d["title"] = title
        d["subtitle"] = subtitle
        d["author"] = author
        d["wordGoal"] = wordGoal
        d["chapterOrder"] = chapterOrder
        d["tabNames"] = tabNames
        d["chapterTitles"] = chapterTitles
        d["chapterNotes"] = chapterNotes
        d["sectionNotes"] = sectionNotes.mapValues { $0.map { ["id": $0.id, "text": $0.text] } }
        d["dailyCounts"] = dailyCounts.mapValues { ["start": $0.start, "end": $0.end] }
        var lp: JSONDict = ["scroll": lastScroll]
        lp.set("chapterId", lastChapterId)
        if let c = lastCaret {
            lp["caretChapterId"] = c.chapterId
            lp["caretParagraph"] = c.paragraph
            lp["caretOffset"] = c.offset
        }
        d["lastPosition"] = lp
        d.set("wordCount", wordCount)
        d.set("coverImage", coverImage)
        return d
    }

    var notesTabName: String { tabNames["notes"] ?? "Notes" }
    var outlineTabName: String { tabNames["outline"] ?? "Outline" }
}

// MARK: - Stickies and darlings

struct Sticky: Identifiable, Equatable {
    var id: String
    var chapterId: String?
    var text: String
    var resolved: Bool

    init(id: String, chapterId: String?, text: String = "", resolved: Bool = false) {
        self.id = id; self.chapterId = chapterId; self.text = text; self.resolved = resolved
    }

    init?(_ d: JSONDict) {
        guard let id = d.string("id") else { return nil }
        self.id = id
        chapterId = d.string("chapterId")
        text = d.string("text") ?? ""
        resolved = d.bool("resolved") ?? false
    }

    var json: JSONDict {
        var d: JSONDict = ["id": id, "text": text, "resolved": resolved]
        d["chapterId"] = chapterId ?? NSNull()
        return d
    }
}

struct Darling: Identifiable {
    var id: String
    var html: String?
    var text: String
    var chapterId: String?
    var chapterLabel: String
    var anchorPrefix: String?
    var anchorSuffix: String?
    var date: String
    var raw: JSONDict = [:]

    init(id: String, html: String?, text: String, chapterId: String?, chapterLabel: String,
         anchorPrefix: String? = nil, anchorSuffix: String? = nil, date: String = NEOID.isoNow()) {
        self.id = id; self.html = html; self.text = text; self.chapterId = chapterId
        self.chapterLabel = chapterLabel; self.anchorPrefix = anchorPrefix
        self.anchorSuffix = anchorSuffix; self.date = date
    }

    init?(_ d: JSONDict) {
        guard let id = d.string("id") else { return nil }
        raw = d
        self.id = id
        html = d.string("html")
        text = d.string("text") ?? ""
        chapterId = d.string("chapterId")
        chapterLabel = d.string("chapterLabel") ?? "Manuscript"
        anchorPrefix = d.string("anchorPrefix")
        anchorSuffix = d.string("anchorSuffix")
        date = d.string("date") ?? NEOID.isoNow()
    }

    var json: JSONDict {
        var d = raw
        d["id"] = id
        d["html"] = html ?? NSNull()
        d["text"] = text
        d["chapterId"] = chapterId ?? NSNull()
        d["chapterLabel"] = chapterLabel
        d["anchorPrefix"] = anchorPrefix ?? NSNull()
        d["anchorSuffix"] = anchorSuffix ?? NSNull()
        d["date"] = date
        return d
    }
}

// MARK: - IDs and dates

enum NEOID {
    /// Base-36 millisecond clock, the same shape the Electron build uses.
    static func stamp() -> String {
        String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36)
    }

    static func random(_ n: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    static func chapter() -> String { "ch-\(stamp())-\(random(4))" }
    static func sticky() -> String { "s-\(stamp())-\(random(3))" }
    static func darling() -> String { "d-\(stamp())-\(random(3))" }
    static func section() -> String { "sec-\(stamp())-\(random(3))" }

    static func isoNow() -> String { iso.string(from: Date()) }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseISO(_ s: String) -> Date? {
        iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// Word counting shared by the counters, the shelf, and exports.
func countWords(_ text: String) -> Int {
    var n = 0
    var inWord = false
    for u in text.unicodeScalars {
        if CharacterSet.whitespacesAndNewlines.contains(u) {
            inWord = false
        } else if !inWord {
            inWord = true
            n += 1
        }
    }
    return n
}
