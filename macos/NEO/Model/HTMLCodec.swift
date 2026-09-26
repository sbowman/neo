import AppKit

/// Reads and writes the chapter HTML the Electron build keeps on disk:
///
///     <p>Plain, <b>bold</b>, <i>italic</i><span class="ph-mark" data-sid="s-…" contenteditable="false">⚑</span></p>
///     <p class="scene-break">***</p>
///     <p class="ghost" data-sec-id="sec-…">an outline note waiting to be written</p>
///     <p style="text-align: center;">…</p>
///     <p><br></p>
///
/// The reader is forgiving — years of contenteditable leave junk spans, divs,
/// entities and old darling anchors behind — and the writer emits only the
/// shapes above.
enum HTMLCodec {
    enum Mode {
        /// NEO's own files: classes, section ids, alignment and whitespace are kept.
        case stored
        /// Clipboard HTML from anywhere: only paragraphs, bold, italic and flags survive.
        case foreign
    }

    struct Run {
        var text: String
        var bold = false
        var italic = false
        var mark: String? = nil
    }

    struct Paragraph {
        var block: BlockKind?
        var secId: String?
        var secBrk: String?
        var align: String?
        var runs: [Run] = []
        var explicit = false

        var isEmpty: Bool { runs.allSatisfy { $0.text.isEmpty } }
        var text: String { runs.map(\.text).joined() }
    }

    struct Parsed {
        var paragraphs: [Paragraph]
        /// Legacy darling anchors: darling id → offset in the flat text.
        var anchors: [(id: String, offset: Int)]
    }

    // MARK: - Public

    static func attributedString(fromHTML html: String, mode: Mode = .stored) -> (NSMutableAttributedString, [(id: String, offset: Int)]) {
        let parsed = parse(html, mode: mode)
        return (build(parsed.paragraphs), parsed.anchors)
    }

    static func build(_ paragraphs: [Paragraph]) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (i, p) in paragraphs.enumerated() {
            let start = out.length
            for r in p.runs where !r.text.isEmpty {
                var attrs: [NSAttributedString.Key: Any] = [:]
                if r.bold { attrs[.neoBold] = true }
                if r.italic { attrs[.neoItalic] = true }
                if let m = r.mark { attrs[.neoMark] = m }
                out.append(NSAttributedString(string: r.text, attributes: attrs))
            }
            if i < paragraphs.count - 1 { out.append(NSAttributedString(string: "\n")) }
            let range = NSRange(location: start, length: out.length - start)
            guard range.length > 0 else { continue }
            if let b = p.block { out.addAttribute(.neoBlock, value: b.rawValue, range: range) }
            if let s = p.secId { out.addAttribute(.neoSecId, value: s, range: range) }
            if let s = p.secBrk { out.addAttribute(.neoSecBrk, value: s, range: range) }
            if let a = p.align { out.addAttribute(.neoAlign, value: a, range: range) }
        }
        return out
    }

    /// The whole attributed string as chapter HTML.
    static func html(from a: NSAttributedString) -> String {
        let s = a.string as NSString
        return Prose.paragraphs(s).map { paragraphHTML(a, $0) }.joined()
    }

    /// A slice of a chapter: a single paragraph's worth comes back inline (no
    /// <p>), more than one as paragraphs — the shape darlings are stored in.
    static func fragmentHTML(from a: NSAttributedString) -> String {
        let s = a.string as NSString
        let paras = Prose.paragraphs(s)
        if paras.count == 1 { return runsHTML(a, paras[0]) }
        return paras.map { paragraphHTML(a, $0) }.joined()
    }

    static func paragraphHTML(_ a: NSAttributedString, _ p: NSRange) -> String {
        let attrs = Prose.paragraphAttributes(a, p)
        var open = "<p"
        if let b = attrs[.neoBlock] as? String { open += " class=\"\(b)\"" }
        if let v = attrs[.neoSecId] as? String { open += " data-sec-id=\"\(escAttr(v))\"" }
        if let v = attrs[.neoSecBrk] as? String { open += " data-sec-brk=\"\(escAttr(v))\"" }
        if let v = attrs[.neoAlign] as? String { open += " style=\"text-align: \(escAttr(v));\"" }
        open += ">"
        let inner = runsHTML(a, p)
        return open + (inner.isEmpty ? "<br>" : inner) + "</p>"
    }

    static func runsHTML(_ a: NSAttributedString, _ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var out = ""
        a.enumerateAttributes(in: range, options: []) { attrs, r, _ in
            let text = (a.string as NSString).substring(with: r)
            if let sid = attrs[.neoMark] as? String {
                // one span per flag character
                for ch in text where String(ch) == Prose.mark {
                    out += "<span class=\"ph-mark\" data-sid=\"\(escAttr(sid))\" contenteditable=\"false\">⚑</span>"
                }
                return
            }
            var t = escText(text.replacingOccurrences(of: Prose.mark, with: ""))
                .replacingOccurrences(of: Prose.lineBreak, with: "<br>")
            if attrs[.neoItalic] != nil { t = "<i>" + t + "</i>" }
            if attrs[.neoBold] != nil { t = "<b>" + t + "</b>" }
            out += t
        }
        return out
    }

    static func escText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escAttr(_ s: String) -> String {
        escText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Parsing

    private static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre",
        "section", "article", "header", "footer", "tr", "dd", "dt", "figcaption", "address"
    ]
    private static let skipTags: Set<String> = ["script", "style", "head", "title", "table", "svg", "noscript", "template"]
    private static let voidTags: Set<String> = ["img", "meta", "link", "hr", "input", "col", "wbr", "source"]

    private struct Inline { let tag: String; let bold: Bool?; let italic: Bool?; let skipText: Bool }

    static func parse(_ html: String, mode: Mode) -> Parsed {
        var paragraphs: [Paragraph] = []
        var anchors: [(String, Int)] = []
        var current: Paragraph? = nil
        var stack: [Inline] = []
        var skipDepth: [String] = []
        var flat = 0

        func bold() -> Bool {
            for f in stack.reversed() { if let b = f.bold { return b } }
            return false
        }
        func italic() -> Bool {
            for f in stack.reversed() { if let i = f.italic { return i } }
            return false
        }
        func skippingText() -> Bool { stack.contains { $0.skipText } }

        // `wrapper`: a block opening inside an unclosed one (<div><p>…) — an
        // empty outer block is scaffolding, not a paragraph
        func flush(wrapper: Bool = false) {
            guard var p = current else { return }
            current = nil
            // trailing line breaks are layout placeholders, not content
            while let last = p.runs.last, last.text == Prose.lineBreak { p.runs.removeLast() }
            if var last = p.runs.last, last.text.hasSuffix(Prose.lineBreak) {
                last.text = String(last.text.dropLast())
                p.runs[p.runs.count - 1] = last
            }
            if mode == .foreign {
                trimRuns(&p)
                if p.isEmpty { return }
            } else if p.isEmpty && (wrapper || !p.explicit) {
                return
            }
            // a *** paragraph that has prose in it is a stained paragraph, not a break
            if p.block == .sceneBreak && p.text.trimmingCharacters(in: .whitespaces) != Prose.sceneBreakText {
                p.block = nil
                p.align = nil
            }
            paragraphs.append(p)
        }

        func open(_ explicit: Bool, _ attrs: [String: String]) {
            flush(wrapper: true)
            var p = Paragraph()
            p.explicit = explicit
            if mode == .stored {
                let classes = Set((attrs["class"] ?? "").split(separator: " ").map(String.init))
                if classes.contains("scene-break") { p.block = .sceneBreak }
                else if classes.contains("ghost") { p.block = .ghost }
                p.secId = attrs["data-sec-id"]
                p.secBrk = attrs["data-sec-brk"]
                if let style = attrs["style"], let a = cssValue(style, "text-align"),
                   ["center", "right", "justify"].contains(a) { p.align = a }
            }
            current = p
        }

        func appendText(_ raw: String) {
            if skippingText() || !skipDepth.isEmpty { return }
            var t = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            if mode == .foreign {
                t = t.replacingOccurrences(of: "[\\s]+", with: " ", options: .regularExpression)
            } else {
                // pre-wrap: a newline inside a paragraph was a visible line break
                if current == nil && t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                t = t.replacingOccurrences(of: "\n", with: Prose.lineBreak)
            }
            if current == nil {
                if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                open(false, [:])
            }
            current!.runs.append(Run(text: t, bold: bold(), italic: italic()))
            flat += (t as NSString).length - (t.components(separatedBy: Prose.lineBreak).count - 1)
        }

        let scalars = Array(html.unicodeScalars)
        var i = 0
        var textStart = 0

        func pendingText(upTo end: Int) {
            if end > textStart {
                var s = String.UnicodeScalarView()
                s.append(contentsOf: scalars[textStart..<end])
                appendText(decodeEntities(String(s)))
            }
        }

        while i < scalars.count {
            guard scalars[i] == "<" else { i += 1; continue }
            // comment
            if i + 3 < scalars.count, scalars[i + 1] == "!", scalars[i + 2] == "-", scalars[i + 3] == "-" {
                pendingText(upTo: i)
                var j = i + 4
                while j + 2 < scalars.count && !(scalars[j] == "-" && scalars[j + 1] == "-" && scalars[j + 2] == ">") { j += 1 }
                i = min(scalars.count, j + 3)
                textStart = i
                continue
            }
            // find the end of the tag, respecting quoted attribute values
            var j = i + 1
            var quote: Unicode.Scalar? = nil
            while j < scalars.count {
                let c = scalars[j]
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if c == ">" { break }
                j += 1
            }
            guard j < scalars.count else { break }
            var inner = String.UnicodeScalarView()
            inner.append(contentsOf: scalars[(i + 1)..<j])
            let tagText = String(inner)
            // a lone "<" that isn't a tag is text
            guard let first = tagText.unicodeScalars.first,
                  first == "/" || first == "!" || first == "?" || CharacterSet.letters.contains(first) else {
                i += 1
                continue
            }
            pendingText(upTo: i)
            i = j + 1
            textStart = i
            if first == "!" || first == "?" { continue }

            let closing = first == "/"
            let body = closing ? String(tagText.dropFirst()) : tagText
            let (name, attrs) = parseTag(body)
            if name.isEmpty { continue }

            if !skipDepth.isEmpty {
                if closing && name == skipDepth.last { skipDepth.removeLast() }
                else if !closing && skipTags.contains(name) && !tagText.hasSuffix("/") { skipDepth.append(name) }
                continue
            }
            if closing {
                if blockTags.contains(name) {
                    flush()
                } else if let k = stack.lastIndex(where: { $0.tag == name }) {
                    stack.removeSubrange(k...)
                }
                continue
            }
            if skipTags.contains(name) {
                if !tagText.hasSuffix("/") { skipDepth.append(name) }
                continue
            }
            if voidTags.contains(name) { continue }
            if name == "br" {
                if current == nil { open(false, [:]) }
                current!.runs.append(Run(text: Prose.lineBreak, bold: bold(), italic: italic()))
                continue
            }
            if blockTags.contains(name) {
                open(true, attrs)
                continue
            }
            let classes = Set((attrs["class"] ?? "").split(separator: " ").map(String.init))
            let selfClosing = tagText.hasSuffix("/")
            switch name {
            case "b", "strong":
                // Google Docs wraps whole clipboards in <b style="font-weight:normal">
                let normal = (cssValue(attrs["style"] ?? "", "font-weight") ?? "").hasPrefix("normal")
                    || cssValue(attrs["style"] ?? "", "font-weight") == "400"
                if !selfClosing { stack.append(Inline(tag: name, bold: !normal, italic: nil, skipText: false)) }
            case "i", "em", "cite":
                if !selfClosing { stack.append(Inline(tag: name, bold: nil, italic: true, skipText: false)) }
            case "span":
                if classes.contains("ph-mark") {
                    let sid = attrs["data-sid"] ?? ""
                    if !sid.isEmpty {
                        if current == nil { open(false, [:]) }
                        current!.runs.append(Run(text: Prose.mark, mark: sid))
                    }
                    flat += 1
                    if !selfClosing { stack.append(Inline(tag: name, bold: nil, italic: nil, skipText: true)) }
                } else if classes.contains("darling-anchor") {
                    if let did = attrs["data-did"] { anchors.append((did, flat)) }
                    if !selfClosing { stack.append(Inline(tag: name, bold: nil, italic: nil, skipText: true)) }
                } else {
                    // style-carrying spans (Chromium's, Google Docs') mean only weight and slant
                    let style = attrs["style"] ?? ""
                    var b: Bool? = nil, it: Bool? = nil
                    if mode == .foreign {
                        if let w = cssValue(style, "font-weight") {
                            b = w == "bold" || w == "bolder" || (Int(w) ?? 400) >= 600
                        }
                        if let s = cssValue(style, "font-style") { it = s == "italic" || s == "oblique" }
                    }
                    if !selfClosing { stack.append(Inline(tag: name, bold: b, italic: it, skipText: false)) }
                }
            default:
                if !selfClosing { stack.append(Inline(tag: name, bold: nil, italic: nil, skipText: false)) }
            }
        }
        pendingText(upTo: scalars.count)
        flush()
        return Parsed(paragraphs: paragraphs, anchors: anchors)
    }

    private static func trimRuns(_ p: inout Paragraph) {
        while let f = p.runs.first, f.mark == nil,
              f.text.trimmingCharacters(in: .whitespaces).isEmpty { p.runs.removeFirst() }
        while let l = p.runs.last, l.mark == nil,
              l.text.trimmingCharacters(in: .whitespaces).isEmpty { p.runs.removeLast() }
        if var f = p.runs.first, f.mark == nil {
            f.text = String(f.text.drop { $0 == " " })
            p.runs[0] = f
        }
        if var l = p.runs.last, l.mark == nil {
            while l.text.hasSuffix(" ") { l.text.removeLast() }
            p.runs[p.runs.count - 1] = l
        }
    }

    private static func parseTag(_ body: String) -> (String, [String: String]) {
        let s = Array(body.unicodeScalars)
        var i = 0
        var name = String.UnicodeScalarView()
        while i < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[i]), s[i] != "/" {
            name.append(s[i]); i += 1
        }
        var attrs: [String: String] = [:]
        while i < s.count {
            while i < s.count, CharacterSet.whitespacesAndNewlines.contains(s[i]) || s[i] == "/" { i += 1 }
            var key = String.UnicodeScalarView()
            while i < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[i]), s[i] != "=", s[i] != "/" {
                key.append(s[i]); i += 1
            }
            if key.isEmpty { i += 1; continue }
            while i < s.count, CharacterSet.whitespacesAndNewlines.contains(s[i]) { i += 1 }
            var value = String.UnicodeScalarView()
            if i < s.count, s[i] == "=" {
                i += 1
                while i < s.count, CharacterSet.whitespacesAndNewlines.contains(s[i]) { i += 1 }
                if i < s.count, s[i] == "\"" || s[i] == "'" {
                    let q = s[i]; i += 1
                    while i < s.count, s[i] != q { value.append(s[i]); i += 1 }
                    i += 1
                } else {
                    while i < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[i]) { value.append(s[i]); i += 1 }
                }
            }
            attrs[String(key).lowercased()] = decodeEntities(String(value))
        }
        let n = String(name).lowercased()
        // namespaced tags (<o:p>, <w:t>) keep their prefix; only the bare name matters here
        return (n, attrs)
    }

    private static func cssValue(_ style: String, _ prop: String) -> String? {
        for decl in style.split(separator: ";") {
            let parts = decl.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == prop {
                return parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            }
        }
        return nil
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "copy": "©",
        "reg": "®", "trade": "™", "bull": "•", "middot": "·", "shy": "", "zwj": "\u{200D}",
        "zwnj": "\u{200C}", "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à",
        "iacute": "í", "oacute": "ó", "uacute": "ú", "ntilde": "ñ", "ccedil": "ç",
        "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß", "deg": "°", "prime": "′", "Prime": "″"
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var rep: String? = named[name]
                if rep == nil, name.hasPrefix("#") {
                    let num = name.dropFirst()
                    let code = num.hasPrefix("x") || num.hasPrefix("X")
                        ? UInt32(num.dropFirst(), radix: 16) : UInt32(num)
                    if let code, let u = Unicode.Scalar(code) { rep = String(Character(u)) }
                }
                if let rep {
                    out += rep
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
}
