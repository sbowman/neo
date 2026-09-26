#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `-NEODebugScript /path/to/script` runs a script of UI
/// actions against the live app, so editing behaviour can be exercised
/// end-to-end without driving the mouse and keyboard from outside.
///
///     open <bookId>            tab <manuscript|notes|outline|darlings>
///     end <chapterIndex>       start <chapterIndex>
///     select <ch> <loc> <len>  type <text>
///     key <return|shift-return|backspace|delete|tab|shift-tab|left|right|up|down|esc>
///     cmd [shift] <char>       wait <seconds>
///     shot <file.png>          dump <file.txt>
///     flush                    shelf
///     quit
@MainActor
enum DebugDriver {
    static func startIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "NEODebugScript"),
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = script.split(separator: "\n").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            for line in lines where !line.hasPrefix("#") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                await run(line)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private static var app: AppModel { AppModel.shared }
    private static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 } }

    private static func key(_ chars: String, code: UInt16, mods: NSEvent.ModifierFlags = []) {
        guard let w = window,
              let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: chars,
                                       charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        if mods.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return }
        w.sendEvent(e)
    }

    private static func run(_ line: String) async {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        let s = app.session
        switch cmd {
        case "open": app.open(arg); try? await Task.sleep(nanoseconds: 800_000_000)
        case "shelf": app.backToShelf()
        case "tab": s?.switchTab(EditorTab(rawValue: arg) ?? .manuscript)
        case "end":
            if let s, let i = Int(arg), s.meta.chapterOrder.indices.contains(i) { s.manuscript?.focusChapterEnd(s.meta.chapterOrder[i]) }
        case "start":
            if let s, let i = Int(arg), s.meta.chapterOrder.indices.contains(i) { s.manuscript?.focusChapterStart(s.meta.chapterOrder[i]) }
        case "select":
            let n = arg.split(separator: " ").compactMap { Int($0) }
            if let s, n.count == 3, s.meta.chapterOrder.indices.contains(n[0]), let tv = s.manuscript?.textView(s.meta.chapterOrder[n[0]]) {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: n[1], length: n[2]))
            }
        case "selecttext", "caret":
            // selecttext <ch> <text> selects it; caret <ch> <text> puts the caret before it
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if let s, bits.count == 2, let i = Int(bits[0]), s.meta.chapterOrder.indices.contains(i),
               let tv = s.manuscript?.textView(s.meta.chapterOrder[i]), let ts = tv.textStorage {
                let r = (ts.string as NSString).range(of: bits[1])
                guard r.location != NSNotFound else { return }
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(cmd == "caret" ? NSRange(location: r.location, length: 0) : r)
            }
        case "type":
            for ch in arg { key(String(ch), code: 0) }
        case "key":
            switch arg {
            case "return": key("\r", code: 36)
            case "shift-return": key("\r", code: 36, mods: .shift)
            case "backspace": key("\u{7F}", code: 51)
            case "delete": key("\u{F728}", code: 117)
            case "tab": key("\t", code: 48)
            case "shift-tab": key("\u{19}", code: 48, mods: .shift)
            case "left": key("\u{F702}", code: 123)
            case "right": key("\u{F703}", code: 124)
            case "up": key("\u{F700}", code: 126)
            case "down": key("\u{F701}", code: 125)
            case "esc": _ = app.handleEscape()
            default: break
            }
        case "cmd":
            let bits = arg.split(separator: " ").map(String.init)
            var mods: NSEvent.ModifierFlags = [.command]
            if bits.contains("shift") { mods.insert(.shift) }
            if let c = bits.last { key(mods.contains(.shift) ? c.uppercased() : c, code: 0, mods: mods) }
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64((Double(arg) ?? 0.5) * 1_000_000_000))
        case "scroll":
            s?.manuscript?.scrollOffset = CGFloat(Double(arg) ?? 0)
        case "resign":
            window?.makeFirstResponder(nil)
        case "restore":
            if let s, let i = Int(arg), s.darlings.indices.contains(i) { s.restoreDarling(s.darlings[i].id) }
        case "find":
            s?.searchQuery = arg
            s?.openSearch()
            s?.searchQuery = arg
            s?.runSearch()
        case "replaceall":
            s?.replaceText = arg
            s?.replaceAll()
        case "section":
            // section <chapterIndex> <text>: a new outline section, synced into the manuscript as a ghost
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if let s, let i = Int(bits[0]), s.meta.chapterOrder.indices.contains(i) {
                let chId = s.meta.chapterOrder[i]
                s.meta.sectionNotes[chId, default: []].append(SectionNote(id: NEOID.section(), text: bits.count > 1 ? bits[1] : ""))
                s.syncGhosts(chId)
            }
        case "export":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if let s, bits.count == 2 {
                s.flushAll()
                await app.write(app.exportData(s), format: bits[0], coverFor: (s.meta.id, s.meta.coverImage), to: URL(fileURLWithPath: bits[1]))
            }
        case "import":
            app.importFiles([URL(fileURLWithPath: arg)], shelfId: app.visibleShelves.first?.id)
        case "pastehtml":
            if let tv = window?.firstResponder as? ProseTextView {
                let pb = NSPasteboard(name: NSPasteboard.Name("neo-debug"))
                pb.clearContents()
                pb.setString(arg, forType: .html)
                _ = tv.readSelection(from: pb, type: .html)
            }
        case "action":
            switch arg {
            case "placeholder": s?.insertPlaceholder()
            case "darling": s?.darlingFromKeyboard()
            case "spell": s?.toggleSpellcheck()
            case "typewriter": app.toggleTypewriter()
            case "paper": app.setPageTheme("paper")
            case "night": app.setPageTheme("night")
            case "stats": app.modal = .stats
            case "help": app.modal = .help
            case "firstrun": app.modal = .firstRun
            case "nav": s?.navOpen = true
            case "side": s?.sideOpen = true
            default: break
            }
        case "glyphs":
            // glyphs <ch> <loc> <len> <file>: layout facts for a range
            let n = arg.split(separator: " ").map(String.init)
            if let s, n.count == 4, let i = Int(n[0]), let loc = Int(n[1]), let len = Int(n[2]),
               let tv = s.manuscript?.textView(s.meta.chapterOrder[i]), let lm = tv.layoutManager, let ts = tv.textStorage {
                var out = ""
                for c in loc..<min(loc + len, ts.length) {
                    let g = lm.glyphIndexForCharacter(at: c)
                    let r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tv.textContainer!)
                    let ch = (ts.string as NSString).substring(with: NSRange(location: c, length: 1))
                    let font = ts.attribute(.font, at: c, effectiveRange: nil) as? NSFont
                    out += "\(c) '\(ch)' g=\(g) prop=\(lm.propertyForGlyph(at: g).rawValue) rect=\(r) font=\(font?.fontName ?? "-") \(font?.pointSize ?? 0) attrs=\(ts.attributes(at: c, effectiveRange: nil).keys.map(\.rawValue).sorted())\n"
                }
                try? out.write(toFile: n[3], atomically: true, encoding: .utf8)
            }
        case "time":
            // time <label> <file>: append a timestamp
            let bits = arg.split(separator: " ").map(String.init)
            if bits.count == 2 {
                let line = "\(bits[0]) \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))\n"
                if let h = FileHandle(forWritingAtPath: bits[1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? line.write(toFile: bits[1], atomically: true, encoding: .utf8) }
            }
        case "flush":
            s?.flushAll()
        case "shot":
            guard let v = window?.contentView else { return }
            v.layoutSubtreeIfNeeded()
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            }
        case "dump":
            var out = ""
            if let s {
                out += "title: \(s.meta.title)\nchapters: \(s.meta.chapterOrder.count)\nwords: \(s.bookWords)\n"
                for (i, id) in s.meta.chapterOrder.enumerated() {
                    out += "--- chapter \(i + 1) [\(id)] title=\(s.meta.chapterTitles[id] ?? "")\n"
                    if let ch = s.chapter(id) { out += HTMLCodec.html(from: ch.storage) + "\n" }
                }
                out += "--- stickies\n" + s.stickies.map { "\($0.id) ch=\($0.chapterId ?? "-") resolved=\($0.resolved) \($0.text)" }.joined(separator: "\n")
                out += "\n--- darlings\n" + s.darlings.map { "\($0.id) \($0.chapterLabel) pre=[\($0.anchorPrefix ?? "")] suf=[\($0.anchorSuffix ?? "")] html=\($0.html ?? "")" }.joined(separator: "\n")
                out += "\n--- undo stack: \(s.undoStack.map(\.label))\n"
            } else {
                out += "shelves: " + app.visibleShelves.map { "\($0.name)=\($0.bookIds)" }.joined(separator: "; ") + "\n"
            }
            try? out.write(toFile: arg, atomically: true, encoding: .utf8)
        case "quit":
            s?.flushAll()
            NSApp.terminate(nil)
        default:
            break
        }
    }
}
#endif
