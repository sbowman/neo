import SwiftUI
import UniformTypeIdentifiers

private let chapterPrefix = "neo-chapter:"

struct EditorView: View {
    @Bindable var session: BookSession
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ManuscriptHost(session: session)
                switch session.tab {
                case .manuscript: EmptyView()
                case .notes: NotesHost(session: session, themeKey: app.theme)
                case .outline: OutlinePage(session: session)
                case .darlings: DarlingsPage(session: session)
                }
                panes
                if session.searchVisible {
                    VStack { SearchBar(session: session).padding(.top, 34); Spacer() }
                }
            }
            BottomBar(session: session)
        }
        .onChange(of: session.tab) { _, _ in session.navOpen = false }
    }

    private var panes: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Color.clear.frame(width: 18).contentShape(Rectangle())
                    .onHover { if $0 && NSEvent.pressedMouseButtons == 0 { session.navOpen = true } }
                NavPane(session: session)
                    .frame(width: 248)
                    .offset(x: session.navOpen ? 0 : -250)
                    .onHover { if !$0 { session.navOpen = false } }
            }
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                Color.clear.frame(width: 18).contentShape(Rectangle())
                    .onHover { if $0 && NSEvent.pressedMouseButtons == 0 { session.sideOpen = true } }
                SidePane(session: session)
                    .frame(width: 250)
                    .offset(x: session.sideOpen || session.sidePinned ? 0 : 252)
                    .onHover { if !$0 && !session.sidePinned { session.sideOpen = false } }
            }
        }
        .animation(.easeOut(duration: 0.18), value: session.navOpen)
        .animation(.easeOut(duration: 0.18), value: session.sideOpen)
        .animation(.easeOut(duration: 0.18), value: session.sidePinned)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            // leaving the window closes unpinned panes
            session.navOpen = false
            if !session.sidePinned { session.sideOpen = false }
        }
    }
}

// MARK: - Left pane: chapters and their outline notes

private struct NavPane: View {
    @Bindable var session: BookSession
    @Environment(AppModel.self) private var app
    @State private var dropBefore: String? = nil
    @State private var dropAtEnd = false

    var body: some View {
        let bright = app.library.uiBright
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(session.meta.chapterOrder, id: \.self) { chId in
                    NavItem(session: session, chId: chId, bright: bright, dropIndicator: dropBefore == chId)
                        .onDrop(of: [.plainText], delegate: ChapterDrop(session: session, before: chId, target: $dropBefore))
                }
                if dropAtEnd {
                    RoundedRectangle(cornerRadius: 1).fill(NEOColor.accent).frame(height: 2).padding(.horizontal, 14)
                }
                Hoverable { h in
                    Text("+ Chapter").font(.system(size: 12))
                        .foregroundStyle(h ? NEOColor.accent : Color(hex: 0x666666))
                        .frame(maxWidth: .infinity).padding(8)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(h ? NEOColor.accent : NEOColor.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                }
                .onTapGesture { session.addChapterAtEnd() }
                .help("Add a chapter at the end")
                .padding(.horizontal, 18).padding(.top, 14)
                .onDrop(of: [.plainText], delegate: ChapterDrop(session: session, before: nil, target: .constant(nil), atEnd: $dropAtEnd))
            }
            .padding(.top, 40).padding(.bottom, 20)
        }
        .scrollIndicators(.never)
        .background(NEOColor.pane)
        .overlay(alignment: .trailing) { Rectangle().fill(Color(hex: 0x2C2C2C)).frame(width: 1) }
    }
}

private struct ChapterDrop: DropDelegate {
    let session: BookSession
    let before: String?
    @Binding var target: String?
    var atEnd: Binding<Bool>? = nil

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }
    func dropEntered(info: DropInfo) { if let before { target = before } else { atEnd?.wrappedValue = true } }
    func dropExited(info: DropInfo) { if target == before { target = nil }; atEnd?.wrappedValue = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        target = nil
        atEnd?.wrappedValue = false
        guard let p = info.itemProviders(for: [.plainText]).first else { return false }
        _ = p.loadObject(ofClass: NSString.self) { s, _ in
            guard let s = s as? String, s.hasPrefix(chapterPrefix) else { return }
            let chId = String(s.dropFirst(chapterPrefix.count))
            DispatchQueue.main.async {
                let to = before.flatMap { session.meta.chapterOrder.firstIndex(of: $0) } ?? session.meta.chapterOrder.count
                session.moveChapter(chId, to: to)
            }
        }
        return true
    }
}

private struct NavItem: View {
    @Bindable var session: BookSession
    let chId: String
    let bright: Bool
    let dropIndicator: Bool
    @State private var note = ""
    @State private var hover = false

    var body: some View {
        let current = session.currentChapterId == chId
        VStack(alignment: .leading, spacing: 4) {
            if dropIndicator {
                RoundedRectangle(cornerRadius: 1).fill(NEOColor.accent).frame(height: 2)
                    .shadow(color: NEOColor.accent.opacity(0.8), radius: 4)
            }
            HStack {
                Text(session.chapterLabel(chId)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 155, alignment: .leading)
                Spacer()
                Text((session.chapterWords[chId] ?? 0).formatted())
                    .font(.system(size: 11)).foregroundStyle(Color(hex: bright ? 0x8F8F8F : 0x5D5D5D))
                if session.flaggedChapters.contains(chId) {
                    Circle().fill(NEOColor.red).frame(width: 8, height: 8).padding(.leading, 8)
                        .help("Unresolved placeholder")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(hover || current ? Color(hex: 0xEEEEEE) : Color(hex: bright ? 0xCCCCCC : 0xAAAAAA))
            .contentShape(Rectangle())
            .onTapGesture {
                session.switchTab(.manuscript)
                DispatchQueue.main.async { session.manuscript?.focusChapterEnd(chId) }
            }
            .onDrag { NSItemProvider(object: (chapterPrefix + chId) as NSString) }
            .help("Drag to reorder chapters")
            KeyField(text: $note, placeholder: "What happens here…",
                     font: .systemFont(ofSize: 12), color: NSColor(hex: bright ? 0x999999 : 0x777777),
                     placeholderColor: NSColor(hex: 0x4A4A4A),
                     onCommit: { session.setChapterNote(chId, note) },
                     onEnter: { session.setChapterNote(chId, note); NSApp.keyWindow?.makeFirstResponder(nil); return true })
        }
        .padding(.horizontal, 18).padding(.top, 9).padding(.bottom, 10)
        .background(hover ? Color(hex: 0x282828) : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(current ? NEOColor.accent : .clear).frame(width: 3)
        }
        .onHover { hover = $0 }
        .onAppear { note = session.meta.chapterNotes[chId] ?? "" }
        .onChange(of: session.meta.chapterNotes[chId]) { _, v in note = v ?? "" }
    }
}

// MARK: - Right pane: notes and comments

private struct SidePane: View {
    @Bindable var session: BookSession
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("NOTES & COMMENTS").font(.system(size: 12)).tracking(2).foregroundStyle(NEOColor.muted(app.library.uiBright))
                Spacer()
                Button {
                    session.sidePinned.toggle()
                    if session.sidePinned { session.sideOpen = true }
                } label: {
                    Text("☉").font(.system(size: 15)).foregroundStyle(session.sidePinned ? NEOColor.accent : Color(hex: 0x555555))
                }
                .buttonStyle(.plain)
                .help("Keep this pane open")
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 12) {
                    if session.openStickies.isEmpty {
                        Text("No notes yet.\n\nHit ⌘⇧X while writing to drop a placeholder — a “come back to this” mark that never breaks your flow.")
                            .font(.system(size: 12)).foregroundStyle(Color(hex: 0x555555))
                            .multilineTextAlignment(.center).lineSpacing(4)
                            .padding(.horizontal, 14).padding(.vertical, 30)
                    }
                    ForEach(session.openStickies) { s in
                        StickyCard(session: session, sticky: s)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 36).padding(.bottom, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NEOColor.pane)
        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: 0x2C2C2C)).frame(width: 1) }
    }
}

private struct StickyCard: View {
    @Bindable var session: BookSession
    let sticky: Sticky
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.index(of: sticky.chapterId).map { "CHAPTER \($0 + 1)" } ?? "UNPLACED")
                .font(.system(size: 10)).tracking(1).foregroundStyle(Color(hex: 0x777777))
            TextField("What needs doing here?", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0xDDDDDD))
                .lineLimit(2...12)
                .focused($focused)
                .onChange(of: text) { _, v in session.updateSticky(sticky.id, text: v) }
            HStack {
                Spacer()
                Hoverable { h in Text("Go to").foregroundStyle(h ? NEOColor.accent : Color(hex: 0x666666)) }
                    .onTapGesture { session.goToSticky(sticky.id) }
                Hoverable { h in Text("Resolve").foregroundStyle(h ? NEOColor.accent : Color(hex: 0x666666)) }
                    .onTapGesture { session.resolveSticky(sticky.id) }
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x2A2A26)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6).fill(NEOColor.red).frame(width: 3)
        }
        .onAppear {
            text = sticky.text
            if session.focusStickyId == sticky.id { focused = true; session.focusStickyId = nil }
        }
        .onChange(of: session.focusStickyId) { _, v in
            if v == sticky.id { focused = true; session.focusStickyId = nil }
        }
    }
}

// MARK: - Bottom bar: tabs and counters

private struct BottomBar: View {
    @Bindable var session: BookSession
    @Environment(AppModel.self) private var app
    @State private var hover = false
    @State private var darlingTarget = false

    var body: some View {
        let bright = app.library.uiBright
        let muted = NEOColor.muted(bright)
        HStack(spacing: 18) {
            Hoverable { h in Text("⇤ Shelf").foregroundStyle(h ? NEOColor.accent : muted) }
                .onTapGesture { app.backToShelf() }
                .help("Back to your bookshelf")
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                tab(.manuscript, "Manuscript")
                tab(.notes, session.meta.notesTabName, renamable: "notes")
                tab(.outline, session.meta.outlineTabName, renamable: "outline")
                tab(.darlings, "Darlings")
                    .background(RoundedRectangle(cornerRadius: 6).fill(darlingTarget ? NEOColor.accent : .clear))
                    .foregroundStyle(darlingTarget ? NEOColor.bg : muted)
                    .padding(.leading, 18)
                    .help("Drag any selection here. It's saved, not gone.")
                    .onDrop(of: [.plainText, .utf8PlainText, .rtf], delegate: DarlingDrop(session: session, targeted: $darlingTarget))
            }
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                Hoverable { h in
                    Text(session.goalText).foregroundStyle(session.goalMet ? NEOColor.accent : (h ? Color(hex: 0xDDDDDD) : muted))
                }
                .onTapGesture { app.modal = .stats }
                .help("Today's words — click for goals, sprints, and your progress chart")
                if !session.positionText.isEmpty {
                    Text(session.positionText).foregroundStyle(muted)
                }
                Hoverable { h in Text(session.wordCounterText).foregroundStyle(h ? Color(hex: 0xDDDDDD) : muted) }
                    .onTapGesture { session.wordModeChapter.toggle() }
                    .help("Click to cycle book / chapter word count")
                HStack(spacing: 6) {
                    Hoverable { h in Text("−").foregroundStyle(h ? Color(hex: 0xDDDDDD) : muted) }
                        .onTapGesture { app.setZoom(app.theme.zoom - 0.1) }
                    Hoverable { h in Text("\(Int((app.theme.zoom * 100).rounded()))%").foregroundStyle(h ? Color(hex: 0xDDDDDD) : muted) }
                        .onTapGesture { app.setZoom(1) }
                        .help("Click to reset to 100%")
                    Hoverable { h in Text("+").foregroundStyle(h ? Color(hex: 0xDDDDDD) : muted) }
                        .onTapGesture { app.setZoom(app.theme.zoom + 0.1) }
                }
                .help("Pinch or Ctrl+Scroll anywhere on the page to zoom")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(NEOColor.bg)
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0x262626)).frame(height: 1) }
        .opacity(hover || session.draggingText || darlingTarget ? 1 : (bright ? 0.92 : 0.35))
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
    }

    private func tab(_ t: EditorTab, _ label: String, renamable: String? = nil) -> some View {
        let active = session.tab == t
        return Hoverable { h in
            Text(label)
                .foregroundStyle(active ? NEOColor.accent : (h ? Color(hex: 0xDDDDDD) : NEOColor.muted(app.library.uiBright)))
                .padding(.horizontal, 16).padding(.vertical, 5)
                .background(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6).fill(active ? Color(hex: 0x232323) : .clear))
                .contentShape(Rectangle())
        }
        .onTapGesture {
            if let kind = renamable, (NSApp.currentEvent?.clickCount ?? 1) >= 2 { session.renameTab(kind) }
            else { session.switchTab(t) }
        }
    }
}

private struct DarlingDrop: DropDelegate {
    let session: BookSession
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool { session.dragOrigin != nil }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    /// A copy, so the text view leaves the source alone; NEO makes the cut itself.
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        session.dropOnDarlings()
        return true
    }
}

// MARK: - Find & replace

private struct SearchBar: View {
    @Bindable var session: BookSession
    @State private var query = ""
    @State private var replace = ""
    @State private var searchTask: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 8) {
            field { KeyField(text: $query, placeholder: "Find", font: .systemFont(ofSize: 13), color: NSColor(hex: 0xEEEEEE),
                             placeholderColor: NSColor(hex: 0x666666), multiline: false, focusToken: session.searchFocusToken,
                             selectAllOnFocus: true,
                             onEnter: { session.searchQuery = query; session.nextMatch(); return true },
                             onShiftEnter: { session.searchQuery = query; session.previousMatch(); return true },
                             onTab: { session.searchQuery = query; session.caretToMatch(); return true }) }
            Text(session.searchCountText).font(.system(size: 11)).foregroundStyle(Color(hex: 0x8A8A8A)).frame(minWidth: 52)
            small("↑") { session.previousMatch() }.help("Previous (⇧Enter)")
            small("↓") { session.nextMatch() }.help("Next (Enter)")
            field { KeyField(text: $replace, placeholder: "Replace with", font: .systemFont(ofSize: 13), color: NSColor(hex: 0xEEEEEE),
                             placeholderColor: NSColor(hex: 0x666666), multiline: false,
                             onEnter: { session.replaceText = replace; session.replaceCurrent(); return true }) }
            small("Replace") { session.replaceText = replace; session.replaceCurrent() }
            small("All") { session.replaceText = replace; session.replaceAll() }
            small("✕") { session.closeSearch() }.help("Close (Esc)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x262626)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NEOColor.border))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        .onAppear { query = session.searchQuery; replace = session.replaceText }
        .onChange(of: session.searchFocusToken) { _, _ in query = session.searchQuery }
        .onChange(of: query) { _, q in
            searchTask?.cancel()
            let item = DispatchWorkItem { session.searchQuery = q; session.runSearch() }
            searchTask = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        }
    }

    private func field<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(width: 170)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(NEOColor.bg))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(NEOColor.border))
    }

    private func small(_ label: String, _ action: @escaping () -> Void) -> some View {
        Hoverable { h in
            Text(label).font(.system(size: 12))
                .foregroundStyle(h ? NEOColor.accent : Color(hex: 0xAAAAAA))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(h ? NEOColor.accent : NEOColor.border))
                .contentShape(Rectangle())
        }
        .onTapGesture(perform: action)
    }
}

// MARK: - Paper for the Outline and Darlings tabs

struct PaperPage<Content: View>: View {
    let title: String
    let theme: PageTheme
    var sidePinned = false
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { g in
            ScrollView {
                VStack(spacing: 0) {
                    Text(title.uppercased())
                        .font(.custom("Georgia", size: 14)).tracking(3)
                        .foregroundStyle(Color(nsColor: theme.night ? NSColor(hex: 0x918B7D) : NSColor(hex: 0x777777)))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 40)
                    content
                }
                .padding(.horizontal, 72).padding(.top, 70).padding(.bottom, 90)
                .frame(width: min(680 * theme.zoom, g.size.width * 0.92), alignment: .top)
                .frame(minHeight: g.size.height * 0.85, alignment: .top)
                .background(theme.paperColor)
                .overlay { if let b = theme.sheetBorder { Rectangle().stroke(Color(nsColor: b)) } }
                .shadow(color: .black.opacity(0.5), radius: 15, y: 4)
                .padding(.top, 40).padding(.bottom, 120)
                .frame(maxWidth: .infinity)
                .offset(x: sidePinned ? -125 : 0)
            }
            .scrollIndicators(.automatic)
        }
    }
}

private struct OutlinePage: View {
    @Bindable var session: BookSession
    @Environment(AppModel.self) private var app

    var body: some View {
        let theme = app.theme
        PaperPage(title: session.meta.outlineTabName, theme: theme, sidePinned: session.sidePinned) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(session.meta.chapterOrder.enumerated()), id: \.element) { i, chId in
                    OutlineLine(session: session, chId: chId, secId: nil, label: "\(i + 1)", theme: theme)
                        .padding(.top, 18)
                    ForEach(Array((session.meta.sectionNotes[chId] ?? []).enumerated()), id: \.element.id) { j, sec in
                        OutlineLine(session: session, chId: chId, secId: sec.id, label: String(UnicodeScalar(65 + j % 26)!), theme: theme)
                            .padding(.leading, 40)
                    }
                }
                Text("Enter — new chapter (or section, from a section line) · Tab — turn a fresh chapter line into a section · Shift+Tab — turn a section into a chapter · Backspace on an empty line removes it")
                    .font(.custom("Georgia", size: 12.5)).italic()
                    .foregroundStyle(Color(nsColor: theme.placeholder))
                    .multilineTextAlignment(.center).lineSpacing(5)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
    }
}

private struct OutlineLine: View {
    @Bindable var session: BookSession
    let chId: String
    let secId: String?
    let label: String
    let theme: PageTheme
    @State private var text = ""
    @State private var token = 0

    private var isChapter: Bool { secId == nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.custom("Georgia", size: 15)).fontWeight(isChapter ? .bold : .regular)
                .foregroundStyle(Color(nsColor: isChapter ? (theme.night ? NSColor(hex: 0x918B7D) : NSColor(hex: 0x6B6455))
                                                         : (theme.night ? NSColor(hex: 0x7D7768) : NSColor(hex: 0x8D8778))))
                .frame(minWidth: 24, alignment: .trailing)
            KeyField(text: $text,
                     placeholder: isChapter ? "What happens in this chapter…" : "What happens in this section…",
                     font: NSFont(name: "Georgia", size: 15) ?? .systemFont(ofSize: 15),
                     color: theme.ink, placeholderColor: theme.placeholder, focusToken: token,
                     onCommit: commit,
                     onEnter: {
                         commit()
                         if let secId { session.outlineSectionEnter(chId, after: secId) } else { session.outlineChapterEnter(chId) }
                         return true
                     },
                     onTab: { commit(); if isChapter { session.outlineIndent(chId) }; return true },
                     onBacktab: { commit(); if let secId { session.outlineOutdent(chId, secId) }; return true },
                     onUp: { move(-1); return true },
                     onDown: { move(1); return true },
                     onEmptyBackspace: { session.outlineRemoveEmpty(chId, secId: secId); return true })
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(isChapter ? "Delete Chapter…" : "Delete Section…", role: .destructive) { session.outlineDelete(chId, secId: secId) }
        }
        .onAppear {
            text = secId.flatMap { id in session.meta.sectionNotes[chId]?.first { $0.id == id }?.text } ?? (isChapter ? session.meta.chapterNotes[chId] ?? "" : "")
            checkFocus()
        }
        .onChange(of: session.outlineFocus) { _, _ in checkFocus() }
    }

    private func checkFocus() {
        guard let f = session.outlineFocus else { return }
        if f.secId == secId && (f.chId == chId || f.chId == nil) {
            token += 1
            session.outlineFocus = nil
        }
    }

    private func commit() {
        if let secId {
            session.setSectionText(chId, secId, text)
            session.syncGhosts(chId)
        } else {
            session.setChapterNote(chId, text)
        }
    }

    /// Up and down walk the outline's lines.
    private func move(_ dir: Int) {
        commit()
        var lines: [OutlineFocus] = []
        for c in session.meta.chapterOrder {
            lines.append(OutlineFocus(chId: c, secId: nil))
            for s in session.meta.sectionNotes[c] ?? [] { lines.append(OutlineFocus(chId: c, secId: s.id)) }
        }
        guard let i = lines.firstIndex(of: OutlineFocus(chId: chId, secId: secId)) else { return }
        let j = i + dir
        guard lines.indices.contains(j) else { return }
        session.outlineFocus = lines[j]
    }
}

private struct DarlingsPage: View {
    @Bindable var session: BookSession
    @Environment(AppModel.self) private var app

    var body: some View {
        let theme = app.theme
        PaperPage(title: "Darlings", theme: theme, sidePinned: session.sidePinned) {
            if session.darlings.isEmpty {
                Text("When a beautiful paragraph is gumming up the works, select it and drag it onto the Darlings tab below.\nIt leaves your manuscript but it is never lost.")
                    .font(.custom("Georgia", size: 15)).italic()
                    .foregroundStyle(Color(nsColor: theme.placeholder))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 60)
            }
            VStack(spacing: 18) {
                ForEach(session.darlings) { d in
                    DarlingCard(session: session, darling: d, theme: theme)
                }
            }
        }
    }
}

private struct DarlingCard: View {
    @Bindable var session: BookSession
    let darling: Darling
    let theme: PageTheme

    private var content: AttributedString {
        let a: NSMutableAttributedString
        if let h = darling.html, !h.isEmpty {
            a = HTMLCodec.attributedString(fromHTML: h).0
        } else {
            a = NSMutableAttributedString(string: darling.text)
        }
        let ts = NSTextStorage(attributedString: a)
        ts.mutableString.replaceOccurrences(of: "\n", with: "\n\n", range: NSRange(location: 0, length: ts.length))
        ts.enumerateAttributes(in: NSRange(location: 0, length: ts.length)) { attrs, r, _ in
            ts.addAttribute(.font, value: theme.font(bold: attrs[.neoBold] != nil, italic: attrs[.neoItalic] != nil, size: 15, family: "Georgia"), range: r)
        }
        ts.addAttribute(.foregroundColor, value: theme.ink, range: NSRange(location: 0, length: ts.length))
        return (try? AttributedString(ts, including: \.appKit)) ?? AttributedString(ts.string)
    }

    var body: some View {
        let date = NEOID.parseISO(darling.date).map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) } ?? ""
        VStack(alignment: .leading, spacing: 12) {
            Text(content).lineSpacing(5).textSelection(.enabled)
            HStack {
                Text("from \(darling.chapterLabel) · \(date) · \(countWords(darling.text).formatted()) words")
                Spacer()
                cardButton("Restore") { session.restoreDarling(darling.id) }
                cardButton("Delete forever") { session.deleteDarling(darling.id) }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(hex: 0x999999))
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: theme.night ? NSColor(hex: 0x3A3835) : NSColor(hex: 0xE3DDCF))))
        .overlay(alignment: .leading) { Rectangle().fill(NEOColor.accent).frame(width: 3) }
    }

    private func cardButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Hoverable { h in
            Text(label)
                .foregroundStyle(h ? Color(nsColor: theme.ink) : Color(hex: 0x777777))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(h ? NEOColor.accent : Color(hex: 0xCCCCCC)))
                .contentShape(Rectangle())
        }
        .onTapGesture(perform: action)
    }
}
