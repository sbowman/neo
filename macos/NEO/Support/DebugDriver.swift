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
    private static var clickLog = ""
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
            // as a physical keyboard sends it: real key code, characters without
            // Shift, characters-ignoring-modifiers with it
            let codes: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
                                           "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
                                           "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ";": 41, "/": 44]
            if let c = bits.last?.lowercased(), let w = window,
               let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: c,
                                        charactersIgnoringModifiers: mods.contains(.shift) ? c.uppercased() : c,
                                        isARepeat: false, keyCode: codes[c] ?? 0) {
                // through the event queue, so it meets the app's key monitor and
                // then the menus, exactly as a keystroke does
                NSApp.postEvent(e, atStart: false)
            }
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
        case "hitscroller":
            // hitscroller <file>: what the window finds under the visible page scroller
            func scrollers(_ v: NSView) -> [PageScrollView] {
                (v as? PageScrollView).map { [$0] } ?? v.subviews.flatMap(scrollers)
            }
            var out = ""
            if let root = window?.contentView {
                for sv in scrollers(root) where !sv.isHiddenOrHasHiddenAncestor && sv.window != nil {
                    guard let bar = sv.verticalScroller else { continue }
                    sv.flashScrollers()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let edge = sv.convert(NSPoint(x: sv.bounds.maxX - 6, y: sv.bounds.midY), to: nil)
                    let edgeHit = root.hitTest(root.superview?.convert(edge, from: nil) ?? edge)
                    out += "window edge hit=\(edgeHit.map { String(describing: type(of: $0)) } ?? "nil")\n"
                    let p = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil)
                    let hit = root.hitTest(root.superview?.convert(p, from: nil) ?? p)
                    out += "scroller x=\(Int(bar.frame.minX)) of width \(Int(sv.bounds.width)); hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") isScroller=\(hit === bar)\n"
                    // drag the knob down by driving the scroller the way a drag does
                    let before = sv.contentView.bounds.minY
                    bar.doubleValue = 0.5
                    bar.sendAction(bar.action, to: bar.target)
                    out += "scroll before=\(Int(before)) after=\(Int(sv.contentView.bounds.minY))\n"
                }
            }
            try? out.write(toFile: arg, atomically: true, encoding: .utf8)
        case "wclick":
            // wclick <x> <y>: a click routed through the window, as the system delivers it
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if let w = window, let content = w.contentView, n.count == 2 {
                w.makeKey()
                let p = NSPoint(x: n[0], y: content.bounds.height - n[1])
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: Int.random(in: 1...100000), clickCount: 1, pressure: 1) {
                        w.sendEvent(e)
                        try? await Task.sleep(nanoseconds: 60_000_000)
                    }
                }
                clickLog = "window click key=\(w.isKeyWindow)"
            }
        case "clickflag":
            // clickflag <ch>: click the chapter's first flag
            if let s, let i = Int(arg), let tv = s.manuscript?.textView(s.meta.chapterOrder[i]), let ts = tv.textStorage,
               let lm = tv.layoutManager, let tc = tv.textContainer, let w = window {
                var at: Int? = nil
                ts.enumerateAttribute(.neoMark, in: NSRange(location: 0, length: ts.length)) { v, r, stop in
                    if v != nil { at = r.location; stop.pointee = true }
                }
                guard let at else { return }
                let r = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: at, length: 1), actualCharacterRange: nil), in: tc)
                let p = tv.convert(NSPoint(x: r.midX + tv.textContainerOrigin.x, y: r.midY + tv.textContainerOrigin.y), to: nil)
                if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: w.windowNumber, context: nil, eventNumber: Int.random(in: 1...99999), clickCount: 1, pressure: 1),
                   let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: w.windowNumber, context: nil, eventNumber: Int.random(in: 1...99999), clickCount: 1, pressure: 1) {
                    NSApp.postEvent(up, atStart: false)
                    tv.mouseDown(with: down)
                }
                clickLog = "flag at \(at); selection now \(tv.selectedRange()); first responder is page: \(w.firstResponder === tv)"
            }
        case "click":
            // click <x> <y>: a mouse click, in points from the window content's top-left
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if let w = window, let content = w.contentView, n.count == 2 {
                // straight to the view under the pointer: a background window would
                // otherwise spend the click on becoming key
                let p = NSPoint(x: n[0], y: content.bounds.height - n[1])
                func ev(_ t: NSEvent.EventType) -> NSEvent? {
                    NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                guard let down = ev(.leftMouseDown), let up = ev(.leftMouseUp),
                      let hit = content.hitTest(content.superview?.convert(p, from: nil) ?? p) else { return }
                NSApp.postEvent(up, atStart: false)   // for views that track the mouse until it's released
                hit.mouseDown(with: down)
                if !(hit is NSTextView) { hit.mouseUp(with: up) }
                let local = hit.convert(down.locationInWindow, from: nil)
                clickLog = "hit \(type(of: hit)) window=\(w.frame.size) content=\(content.bounds.size) local=\(local) mid=\((hit as? MarginView)?.pageMidX() ?? -1)"
            }
        case "menus":
            // menus <file>: every menu item with a key equivalent
            var out = ""
            func walk(_ m: NSMenu, _ path: String) {
                for it in m.items {
                    if !it.keyEquivalent.isEmpty || path.hasPrefix("File") {
                        out += "\(it.isEnabled ? "on " : "OFF")  \(path)\(it.title)  [\(it.keyEquivalentModifierMask.contains(.command) ? "⌘" : "")\(it.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")\(it.keyEquivalent)]\n"
                    }
                    if let sub = it.submenu { walk(sub, path + it.title + " > ") }
                }
            }
            NSApp.setWindowsNeedUpdate(true)
            NSApp.updateWindows()
            NotificationCenter.default.post(name: NSApplication.willUpdateNotification, object: NSApp)
            NotificationCenter.default.post(name: NSApplication.didUpdateNotification, object: NSApp)
            try? await Task.sleep(nanoseconds: 300_000_000)
            func update(_ m: NSMenu) { m.update(); for it in m.items { if let sub = it.submenu { update(sub) } } }
            if let m = NSApp.mainMenu { update(m); walk(m, "") }
            try? out.write(toFile: arg, atomically: true, encoding: .utf8)
        case "keqprobe":
            // keqprobe <file>: which spelling of ⌘⇧X does the menu accept?
            var out = ""
            if let w = window, let m = NSApp.mainMenu {
                func find(_ menu: NSMenu) -> NSMenuItem? {
                    for it in menu.items {
                        if it.title == "Placeholder Note" { return it }
                        if let sub = it.submenu, let f = find(sub) { return f }
                    }
                    return nil
                }
                if let it = find(m) {
                    it.menu?.update()
                    out += "item keyEquivalent=[\(it.keyEquivalent)] mask=\(it.keyEquivalentModifierMask.rawValue) enabled=\(it.isEnabled) target=\(String(describing: it.target)) action=\(String(describing: it.action))\n"
                }
                if let it = find(m), let a = it.action {
                    let before = app.session?.stickies.count ?? -1
                    let sent = NSApp.sendAction(a, to: it.target, from: it)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    out += "menu action sent=\(sent) stickies \(before)->\(app.session?.stickies.count ?? -1) toast=\(app.toast ?? "-") firstResponder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "-")\n"
                }
                for (chars, ign) in [("x", "X"), ("X", "X"), ("x", "x"), ("X", "x")] {
                    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, characters: chars,
                                             charactersIgnoringModifiers: ign, isARepeat: false, keyCode: 7)!
                    let before = app.session?.stickies.count ?? -1
                    let handled = m.performKeyEquivalent(with: e)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    out += "chars=\(chars) ignoring=\(ign): handled=\(handled) stickies \(before)->\(app.session?.stickies.count ?? -1)\n"
                }
            }
            try? out.write(toFile: arg, atomically: true, encoding: .utf8)
        case "probepanel":
            // probepanel <file>: open the real export panel, describe it, cancel it
            let file = arg
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                var out = ""
                for w in NSApp.windows {
                    out += "\(type(of: w)) frame=\(w.frame.size) resizable=\(w.styleMask.contains(.resizable)) min=\(w.minSize) max=\(w.maxSize) contentMin=\(w.contentMinSize) contentMax=\(w.contentMaxSize) sheet=\(w.isSheet) parent=\(w.sheetParent != nil)\n"
                    if let p = w as? NSSavePanel { out += "  savepanel expanded=\(p.value(forKey: "isExpanded") ?? "?") showsResize=\(p.showsResizeIndicator)\n" }
                }
                out += "modal window: \(NSApp.modalWindow.map { String(describing: type(of: $0)) } ?? "none")\n"
                for w in NSApp.windows { if let sh = w.attachedSheet {
                    out += "sheet on main window: \(type(of: sh)) resizable=\(sh.styleMask.contains(.resizable)) size=\(sh.frame.size) min=\(sh.minSize)\n"
                    w.endSheet(sh, returnCode: .cancel)
                } }
                try? out.write(toFile: file, atomically: true, encoding: .utf8)
                NSApp.abortModal()
                NSApp.modalWindow?.close()
            }
            app.export("txt")
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
                out += "last click: \(clickLog)\n"
                out += "search visible: \(s.searchVisible)\n"
                if let tv = window?.firstResponder as? ChapterTextView {
                    let str = (tv.textStorage?.string ?? "") as NSString
                    let loc = tv.selectedRange().location
                    let around = str.substring(with: NSRange(location: max(0, loc - 12), length: min(24, str.length - max(0, loc - 12))))
                    out += "caret: \(tv.chapterId) at \(loc) …\(around.replacingOccurrences(of: "\n", with: "¶"))…\n"
                } else {
                    out += "caret: none\n"
                }
                out += "first responder: \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-") editingSticky=\(s.editingStickyId ?? "-")\n"
                out += "panes: nav=\(s.navOpen) side=\(s.sideOpen) current=\(s.currentChapterId ?? "-") scroll=\(Int(s.manuscript?.scrollOffset ?? -1))\n"
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
