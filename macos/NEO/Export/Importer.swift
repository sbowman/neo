import Foundation

/// .docx / .txt / .md → chapters, with the title and byline harvested off the
/// top. A straight port of the Electron build's importer.
enum Importer {
    static let extensions = ["docx", "txt", "md"]

    enum Para: Equatable {
        case text(String)
        case scene
    }

    struct Book {
        var name: String
        var title: String?
        var author: String?
        var chapters: [[Para]]
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Raw { var text: String; var pageBreak: Bool }

    static func canImport(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func importFile(_ url: URL) throws -> Book {
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        var paras: [Raw] = []

        if ext == "docx" {
            guard let zip = ZipReader(try Data(contentsOf: url)),
                  let docData = zip.read("word/document.xml") else {
                throw Failure(message: "Not a valid .docx: \(url.lastPathComponent)")
            }
            let xml = String(decoding: docData, as: UTF8.self)
            paras = matches(#"<w:p[ >][\s\S]*?</w:p>"#, in: xml).map { p in
                // <w:t> or <w:t attr…> only — never <w:tab>/<w:tabs>
                let text = captures(#"<w:t(?:\s[^>]*)?>([\s\S]*?)</w:t>"#, in: p)
                    .map { HTMLCodec.decodeEntities($0) }.joined()
                let pageBreak = p.range(of: #"<w:br [^>]*w:type="page""#, options: .regularExpression) != nil
                    || p.contains("<w:pageBreakBefore")
                return Raw(text: text.trimmingCharacters(in: .whitespacesAndNewlines), pageBreak: pageBreak)
            }
        } else {
            let raw = try String(contentsOf: url, encoding: .utf8)
            paras = raw.components(separatedBy: try! NSRegularExpression(pattern: #"\r?\n\s*\r?\n"#))
                .map { Raw(text: $0.replacingOccurrences(of: #"\s*\r?\n\s*"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines), pageBreak: false) }
                .filter { !$0.text.isEmpty }
        }

        // Chapterize: page breaks and heading lines start new chapters. Bare
        // numerals ("7", "VII", "Seven") only count when there's a ladder of them.
        let spelled = #"^(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)\.?$"#
        func isNumeralish(_ t: String) -> Bool {
            t.range(of: #"^\d{1,3}\.?$"#, options: .regularExpression) != nil
                || t.range(of: #"^[IVXLC]{1,7}\.?$"#, options: .regularExpression) != nil
                || t.range(of: spelled, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let numeralMode = paras.filter { !$0.text.isEmpty && isNumeralish($0.text) }.count >= 2
        func isHeading(_ t: String) -> Bool {
            guard !t.isEmpty else { return false }
            if t.count < 60, t.range(of: #"^(chapter|prologue|epilogue|part)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
            return numeralMode && isNumeralish(t)
        }
        func isBreak(_ t: String) -> Bool {
            t.range(of: #"^\s*([*#•~⁂—–-]\s*){1,7}$"#, options: .regularExpression) != nil
        }

        func chapterize(_ usePageBreaks: Bool) -> [[Para]] {
            var chapters: [[Para]] = []
            var cur: [Para] = []
            for p in paras {
                let brk = usePageBreaks && p.pageBreak
                if p.text.isEmpty && !brk { continue }
                if (brk || isHeading(p.text)) && !cur.isEmpty {
                    chapters.append(cur)
                    cur = []
                }
                if isHeading(p.text) { continue } // NEO numbers chapters itself
                if isBreak(p.text) { cur.append(.scene); continue }
                if !p.text.isEmpty { cur.append(.text(p.text)) }
            }
            if !cur.isEmpty { chapters.append(cur) }
            return chapters
        }

        func countAll(_ list: [[Para]]) -> Int {
            list.reduce(0) { n, ch in
                n + ch.reduce(0) { m, p in if case .text(let t) = p { return m + countWords(t) } else { return m } }
            }
        }

        // Some word processors sprinkle page breaks on every paragraph; if the
        // result is confetti, trust headings only.
        var chapters = chapterize(true)
        if chapters.count > 6 && countAll(chapters) / chapters.count < 250 {
            chapters = chapterize(false)
        }
        if chapters.isEmpty { chapters = [[.text("")]] }

        // Front matter: a short title line and a "by Author" line belong on the
        // title page, not in the body.
        var title: String? = nil
        var author: String? = nil
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression) }
        func textOf(_ p: Para?) -> String { if case .text(let t)? = p { return t.trimmingCharacters(in: .whitespaces) } else { return "" } }

        if var first = chapters.first, !first.isEmpty {
            let t0 = textOf(first.first)
            let t1 = first.count > 1 ? textOf(first[1]) : ""
            let endsSentence = t0.range(of: #"[.!?]$"#, options: .regularExpression) != nil
            let titleish = !t0.isEmpty && t0.count < 90 && !endsSentence && (
                (norm(t0).count > 3 && norm(name).contains(norm(t0)))
                    || t1.range(of: #"^by\s+\S"#, options: [.regularExpression, .caseInsensitive]) != nil
                    || (t0 == t0.uppercased() && t0.range(of: "[A-Z].*[A-Z]", options: .regularExpression) != nil && t0.count < 60)
            )
            if titleish {
                title = t0
                first.removeFirst()
            }
            if let lead = first.first.map(textOf),
               let m = lead.range(of: #"^by\s+(.{2,60})$"#, options: [.regularExpression, .caseInsensitive]) {
                author = String(lead[m].dropFirst(2)).trimmingCharacters(in: .whitespaces)
                first.removeFirst()
            }
            chapters[0] = first
            if first.isEmpty { chapters.removeFirst() }
            if chapters.isEmpty { chapters = [[.text("")]] }
        }
        return Book(name: name, title: title, author: author, chapters: chapters)
    }

    /// A chapter's worth of imported paragraphs, as chapter HTML.
    static func html(_ chapter: [Para]) -> String {
        let out = chapter.map { p -> String in
            switch p {
            case .scene: return "<p class=\"scene-break\">***</p>"
            case .text(let t): return "<p>\(HTMLCodec.escText(t))</p>"
            }
        }.joined()
        return out.isEmpty ? "<p><br></p>" : out
    }

    static func words(_ chapter: [Para]) -> Int {
        chapter.reduce(0) { n, p in if case .text(let t) = p { return n + countWords(t) } else { return n } }
    }

    // MARK: regex helpers

    private static func matches(_ pattern: String, in s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func captures(_ pattern: String, in s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
}

private extension String {
    func components(separatedBy re: NSRegularExpression) -> [String] {
        let ns = self as NSString
        var out: [String] = []
        var last = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = NSMaxRange(m.range)
        }
        out.append(ns.substring(from: last))
        return out
    }
}
