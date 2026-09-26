import AppKit

/// The builders behind File → Export, the anthology export, and the emailed
/// snapshot. Every paragraph is rebuilt from its runs, so exports carry only
/// author-meaningful markup: text, bold, italic, alignment, scene breaks.
enum Exporter {
    struct RunPiece { var text: String; var b: Bool; var i: Bool }

    struct Para {
        var sceneBreak: Bool
        var text: String
        var runs: [RunPiece]
        var align: String?
    }

    struct Section {
        var num: Int
        var heading: String
        var paras: [Para]
    }

    struct Book {
        var id: String
        var title: String
        var subtitle: String
        var author: String
        var sections: [Section]
    }

    struct Cover {
        var data: Data
        var mime: String
        var ext: String
    }

    // MARK: - Collecting

    /// A chapter's paragraphs, minus everything that isn't the book: unwritten
    /// outline ghosts (and the breaks planted for them), flags, blank lines.
    static func paras(from a: NSAttributedString) -> [Para] {
        let s = a.string as NSString
        let paragraphs = Prose.paragraphs(s)
        var ghostSections = Set<String>()
        for p in paragraphs where Prose.blockKind(a, p) == .ghost {
            if let id = Prose.paragraphValue(a, p, .neoSecId) as? String { ghostSections.insert(id) }
        }
        var out: [Para] = []
        for p in paragraphs {
            let kind = Prose.blockKind(a, p)
            if kind == .ghost { continue }
            if kind == .sceneBreak, let brk = Prose.paragraphValue(a, p, .neoSecBrk) as? String,
               ghostSections.contains(brk) { continue }
            var runs: [RunPiece] = []
            if p.length > 0 {
                a.enumerateAttributes(in: p, options: []) { attrs, r, _ in
                    guard attrs[.neoMark] == nil else { return }
                    let t = s.substring(with: r)
                        .replacingOccurrences(of: Prose.mark, with: "")
                        .replacingOccurrences(of: Prose.lineBreak, with: " ")
                    if !t.isEmpty { runs.append(RunPiece(text: t, b: attrs[.neoBold] != nil, i: attrs[.neoItalic] != nil)) }
                }
            }
            let text = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == .sceneBreak || !text.isEmpty {
                out.append(Para(sceneBreak: kind == .sceneBreak, text: text, runs: runs,
                                align: Prose.paragraphValue(a, p, .neoAlign) as? String))
            }
        }
        return out
    }

    static func heading(index: Int, of count: Int, title: String?) -> String {
        // chapterless stories export as continuous text
        guard count > 1 else { return "" }
        let t = title?.trimmingCharacters(in: .whitespaces) ?? ""
        return "Chapter \(index + 1)" + (t.isEmpty ? "" : " — " + t)
    }

    /// Every book on a shelf, merged into one: each story's title becomes its
    /// TOC entry; multi-chapter works keep their chapters as continuations.
    static func anthology(shelf: Shelf, title: String, author: String) -> Book {
        var sections: [Section] = []
        var num = 0
        for bookId in shelf.bookIds {
            guard let meta = LibraryStore.readMeta(bookId) else { continue }
            let multi = meta.chapterOrder.count > 1
            for (i, chId) in meta.chapterOrder.enumerated() {
                let (a, _) = HTMLCodec.attributedString(fromHTML: LibraryStore.readChapter(bookId, chId))
                let ps = paras(from: a)
                if ps.isEmpty { continue }
                num += 1
                let t = meta.chapterTitles[chId] ?? ""
                let heading = !multi ? meta.title
                    : (i == 0 ? meta.title : "\(meta.title) — Chapter \(i + 1)" + (t.isEmpty ? "" : ": " + t))
                sections.append(Section(num: num, heading: heading, paras: ps))
            }
        }
        return Book(id: "shelf-" + shelf.id, title: title, subtitle: "", author: author, sections: sections)
    }

    static func safeName(_ s: String) -> String {
        let t = s.replacingOccurrences(of: #"[^\w\s-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        return t.isEmpty ? "Untitled" : t
    }

    static func wordTotal(_ d: Book) -> Int {
        d.sections.reduce(0) { $0 + $1.paras.reduce(0) { $0 + countWords($1.text) } }
    }

    // MARK: - Plain text and markdown

    static func txt(_ d: Book) -> String {
        var out = d.title.uppercased() + "\n"
        if !d.subtitle.isEmpty { out += d.subtitle + "\n" }
        out += "by \(d.author)\n\n\n"
        for ch in d.sections {
            if !ch.heading.isEmpty { out += ch.heading.uppercased() + "\n\n" }
            for p in ch.paras { out += p.sceneBreak ? "\n***\n\n" : p.text + "\n\n" }
            out += "\n"
        }
        return out
    }

    static func md(_ d: Book) -> String {
        // emphasis markers hug the words; boundary spaces stay outside them
        func mdRun(_ r: RunPiece) -> String {
            let t = r.text.replacingOccurrences(of: #"([\\*_`])"#, with: #"\\$1"#, options: .regularExpression)
            let mark = r.b && r.i ? "***" : r.b ? "**" : r.i ? "*" : ""
            if mark.isEmpty { return t }
            let lead = String(t.prefix { $0 == " " })
            let trail = String(t.reversed().prefix { $0 == " " })
            let core = t.trimmingCharacters(in: .whitespaces)
            return core.isEmpty ? t : lead + mark + core + mark + trail
        }
        var out = "# \(d.title)\n\n"
        if !d.subtitle.isEmpty { out += "*\(d.subtitle)*\n\n" }
        out += "**by \(d.author)**\n\n"
        for ch in d.sections {
            if !ch.heading.isEmpty { out += "\n## \(ch.heading)\n\n" }
            for p in ch.paras {
                out += p.sceneBreak ? "\n***\n\n" : p.runs.map(mdRun).joined() + "\n\n"
            }
        }
        return out
    }

    // MARK: - HTML (also the source of PDFs)

    private static func esc(_ s: String) -> String { HTMLCodec.escAttr(s) }

    private static func inlineHTML(_ runs: [RunPiece], em: Bool = false) -> String {
        runs.map { r in
            var t = esc(r.text)
            if r.i { t = em ? "<em>\(t)</em>" : "<i>\(t)</i>" }
            if r.b { t = em ? "<strong>\(t)</strong>" : "<b>\(t)</b>" }
            return t
        }.joined()
    }

    static func html(_ d: Book, cover: Cover? = nil, stamp: Bool = false) -> String {
        let chapters = d.sections.map { ch -> String in
            // only the chapter's opening paragraph gets the enlarged initial
            var first = true
            let paras = ch.paras.map { p -> String in
                if p.sceneBreak { return "<p class=\"brk\">***</p>" }
                var attrs = ""
                if first { attrs += " class=\"first\"" }
                if let a = p.align { attrs += " style=\"text-align:\(a)\"" }
                first = false
                return "<p\(attrs)>\(inlineHTML(p.runs))</p>"
            }.joined(separator: "\n")
            return """

                <section class="chapter">
                  \(ch.heading.isEmpty ? "" : "<h2>\(esc(ch.heading))</h2>")
                  \(paras)
                </section>
            """
        }.joined(separator: "\n")
        let when = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        let coverHTML = cover.map {
            "<div class=\"coverpage\"><img src=\"data:\($0.mime);base64,\($0.data.base64EncodedString())\" alt=\"Cover\"/></div>"
        } ?? ""
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(esc(d.title))</title>
        <style>
          body { font-family: Georgia, serif; color: #1c1c1c; max-width: 620px; margin: 40px auto; line-height: 1.7; font-size: 13pt; }
          .coverpage { text-align: center; margin: 0 0 40px; page-break-after: always; }
          .coverpage img { display: block; margin: 0 auto; width: 100%; max-width: 620px; max-height: 95vh; object-fit: contain; }
          .titlepage { text-align: center; margin: 30vh 0 20vh; } /* each chapter breaks before itself */
          .titlepage h1 { font-size: 30pt; margin: 0; }
          .titlepage .sub { font-style: italic; color: #555; }
          .titlepage .auth { margin-top: 40px; letter-spacing: 3px; text-transform: uppercase; font-size: 11pt; }
          .chapter { page-break-before: always; }
          .chapter h2 { text-align: center; letter-spacing: 4px; text-transform: uppercase; font-size: 12pt; font-weight: normal; color: #555; margin: 60px 0 40px; }
          .chapter p { text-indent: 2em; margin: 0; }
          .chapter h2 + p, .brk + p, .chapter p.first { text-indent: 0; }
          .chapter h2 + p::first-letter, .chapter p.first::first-letter { font-size: 1.8em; line-height: 1; }
          .brk { text-align: center; text-indent: 0 !important; letter-spacing: 8px; color: #888; margin: 2.5em 0; }
          .prov { margin-top: 80px; text-align: center; color: #999; font-size: 9pt; }
        </style></head><body>
        \(coverHTML)
        <div class="titlepage"><h1>\(esc(d.title))</h1>
        \(d.subtitle.isEmpty ? "" : "<p class=\"sub\">\(esc(d.subtitle))</p>")
        <p class="auth">\(esc(d.author))</p></div>
        \(chapters)
        \(stamp ? "<p class=\"prov\">\(wordTotal(d).formatted()) words · exported from NEO on \(when)</p>" : "")
        </body></html>
        """
    }

    // MARK: - DOCX

    private static func docxP(_ runs: [RunPiece], align: String? = nil, pageBreak: Bool = false,
                              indent: Bool = false, spaceBefore: Int? = nil, size: Int? = nil) -> String {
        var pPr = ""
        if pageBreak { pPr += "<w:pageBreakBefore/>" }
        if let align { pPr += "<w:jc w:val=\"\(align == "justify" ? "both" : align)\"/>" }
        if indent { pPr += "<w:ind w:firstLine=\"480\"/>" }
        if let spaceBefore { pPr += "<w:spacing w:before=\"\(spaceBefore)\" w:line=\"360\" w:lineRule=\"auto\"/>" }
        let r = runs.map { r -> String in
            let rPr = (r.b ? "<w:b/>" : "") + (r.i ? "<w:i/>" : "") + (size.map { "<w:sz w:val=\"\($0)\"/>" } ?? "")
            return "<w:r>\(rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>")<w:t xml:space=\"preserve\">\(esc(r.text))</w:t></w:r>"
        }.joined()
        return "<w:p><w:pPr>\(pPr)</w:pPr>\(r)</w:p>"
    }

    static func docx(_ d: Book) -> Data {
        var body: [String] = []
        body.append(docxP([RunPiece(text: d.title, b: true, i: false)], align: "center", spaceBefore: 3000, size: 56))
        if !d.subtitle.isEmpty { body.append(docxP([RunPiece(text: d.subtitle, b: false, i: true)], align: "center", size: 32)) }
        body.append(docxP([RunPiece(text: d.author, b: false, i: false)], align: "center", spaceBefore: 800))
        for ch in d.sections {
            if !ch.heading.isEmpty {
                body.append(docxP([RunPiece(text: ch.heading.uppercased(), b: false, i: false)], align: "center", pageBreak: true, spaceBefore: 1200, size: 28))
                body.append(docxP([]))
            } else {
                body.append(docxP([], pageBreak: true)) // a headingless story still starts fresh
            }
            for p in ch.paras {
                if p.sceneBreak { body.append(docxP([RunPiece(text: "***", b: false, i: false)], align: "center", spaceBefore: 240)) }
                else if p.align == "center" || p.align == "right" { body.append(docxP(p.runs, align: p.align)) }
                else { body.append(docxP(p.runs, align: p.align == "justify" ? "justify" : nil, indent: true)) }
            }
        }
        let documentXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body.joined())
        <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
        </w:body></w:document>
        """
        let stylesXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia"/><w:sz w:val="24"/></w:rPr></w:rPrDefault>
        <w:pPrDefault><w:pPr><w:spacing w:line="360" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        </w:styles>
        """
        let z = ZipWriter()
        z.add("[Content_Types].xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """)
        z.add("_rels/.rels", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """)
        z.add("word/_rels/document.xml.rels", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """)
        z.add("word/document.xml", text: documentXml)
        z.add("word/styles.xml", text: stylesXml)
        return z.finish()
    }

    // MARK: - EPUB (EPUB 3, nav + NCX TOC, cover image — KDP friendly)

    private static func chapterXhtml(_ ch: Section, _ d: Book) -> String {
        var first = true
        let paras = ch.paras.map { p -> String in
            if p.sceneBreak { first = true; return "<p class=\"brk\">* * *</p>" }
            var classes: [String] = []
            if first { classes.append("first") }
            if p.align == "center" || p.align == "right" { classes.append(p.align!) }
            first = false
            let cls = classes.isEmpty ? "" : " class=\"\(classes.joined(separator: " "))\""
            return "<p\(cls)>\(inlineHTML(p.runs, em: true))</p>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(esc(ch.heading.isEmpty ? d.title : ch.heading))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body><section epub:type="chapter">\(ch.heading.isEmpty ? "" : "<h1>\(esc(ch.heading))</h1>")
        \(paras)
        </section></body></html>
        """
    }

    static func epub(_ d: Book, cover: Cover) -> Data {
        let chapters = d.sections
        let uuid = "urn:uuid:neo-" + d.id
        let modified = ISO8601DateFormatter().string(from: Date())
        let coverName = "cover." + cover.ext
        let label = { (ch: Section) in esc(ch.heading.isEmpty ? d.title : ch.heading) }
        let items = chapters.map { "<item id=\"ch\($0.num)\" href=\"ch\($0.num).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined(separator: "\n")
        let spine = chapters.map { "<itemref idref=\"ch\($0.num)\"/>" }.joined(separator: "\n")
        let nav = chapters.map { "<li><a href=\"ch\($0.num).xhtml\">\(label($0))</a></li>" }.joined(separator: "\n")
        let ncx = chapters.map {
            "\n<navPoint id=\"ch\($0.num)\" playOrder=\"\($0.num + 1)\"><navLabel><text>\(label($0))</text></navLabel><content src=\"ch\($0.num).xhtml\"/></navPoint>"
        }.joined()
        let firstHref = chapters.first.map { "ch\($0.num).xhtml" } ?? "title.xhtml"

        let z = ZipWriter()
        z.add("mimetype", text: "application/epub+zip", store: true)
        z.add("META-INF/container.xml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
        z.add("OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">\(esc(uuid))</dc:identifier>
        <dc:title>\(esc(d.title))</dc:title>
        <dc:creator>\(esc(d.author))</dc:creator>
        <dc:language>en</dc:language>
        <meta property="dcterms:modified">\(modified)</meta>
        <meta name="cover" content="cover-image"/>
        </metadata>
        <manifest>
        <item id="cover-image" href="\(coverName)" media-type="\(cover.mime)" properties="cover-image"/>
        <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
        <item id="titlepage" href="title.xhtml" media-type="application/xhtml+xml"/>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="css" href="style.css" media-type="text/css"/>
        \(items)
        </manifest>
        <spine toc="ncx">
        <itemref idref="cover" linear="no"/>
        <itemref idref="titlepage"/>
        <itemref idref="nav"\(chapters.count == 1 ? " linear=\"no\"" : "")/>
        \(spine)
        </spine>
        <guide>
        <reference type="cover" title="Cover" href="cover.xhtml"/>
        <reference type="toc" title="Table of Contents" href="nav.xhtml"/>
        <reference type="text" title="Beginning" href="\(firstHref)"/>
        </guide>
        </package>
        """)
        z.add("OEBPS/nav.xhtml", text: """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Table of Contents</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body><nav epub:type="toc" id="toc"><h1>Contents</h1>
        <ol>
        <li><a href="title.xhtml">Title Page</a></li>
        \(nav)
        </ol></nav>
        <nav epub:type="landmarks" hidden=""><ol>
        <li><a epub:type="cover" href="cover.xhtml">Cover</a></li>
        <li><a epub:type="toc" href="nav.xhtml">Table of Contents</a></li>
        <li><a epub:type="bodymatter" href="\(firstHref)">Beginning</a></li>
        </ol></nav>
        </body></html>
        """)
        z.add("OEBPS/toc.ncx", text: """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head><meta name="dtb:uid" content="\(esc(uuid))"/></head>
        <docTitle><text>\(esc(d.title))</text></docTitle>
        <navMap>
        <navPoint id="titlepage" playOrder="1"><navLabel><text>Title Page</text></navLabel><content src="title.xhtml"/></navPoint>\(ncx)
        </navMap></ncx>
        """)
        z.add("OEBPS/style.css", text: """
        body { font-family: serif; line-height: 1.5; margin: 1em; }
        h1 { text-align: center; font-weight: normal; letter-spacing: 0.2em; text-transform: uppercase; font-size: 1.2em; margin: 3em 0 2em; }
        p { text-indent: 1.2em; margin: 0; }
        p.first, p.brk + p { text-indent: 0; }
        p.center { text-align: center; text-indent: 0; }
        p.right { text-align: right; text-indent: 0; }
        p.brk { text-align: center; text-indent: 0; margin: 2.5em 0; letter-spacing: 0.5em; }
        .titlepage { text-align: center; margin-top: 30%; }
        .titlepage h2 { font-size: 2em; margin: 0; }
        .titlepage .sub { font-style: italic; }
        .titlepage .auth { margin-top: 4em; letter-spacing: 0.3em; text-transform: uppercase; }
        .coverimg { text-align: center; margin: 0; padding: 0; }
        .coverimg img { max-width: 100%; max-height: 100%; }
        """)
        z.add("OEBPS/cover.xhtml", text: """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Cover</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body><div class="coverimg"><img src="\(coverName)" alt="\(esc(d.title))"/></div></body></html>
        """)
        z.add("OEBPS/title.xhtml", text: """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(esc(d.title))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body><div class="titlepage"><h2>\(esc(d.title))</h2>
        \(d.subtitle.isEmpty ? "" : "<p class=\"sub\">\(esc(d.subtitle))</p>")
        <p class="auth">\(esc(d.author))</p></div></body></html>
        """)
        z.add("OEBPS/" + coverName, data: cover.data, store: true)
        for ch in chapters {
            z.add("OEBPS/ch\(ch.num).xhtml", text: chapterXhtml(ch, d))
        }
        return z.finish()
    }
}
