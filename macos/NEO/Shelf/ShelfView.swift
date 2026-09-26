import SwiftUI
import UniformTypeIdentifiers

private let bookPrefix = "neo-book:"
private let shelfPrefix = "neo-shelf:"

/// Reads what was dropped: NEO's own drags arrive as tagged strings, Finder's as file URLs.
private func loadDrop(_ providers: [NSItemProvider], _ done: @escaping (_ tag: String?, _ urls: [URL]) -> Void) {
    let group = DispatchGroup()
    var tag: String? = nil
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { lock.lock(); urls.append(u); lock.unlock() }
                group.leave()
            }
        } else if p.canLoadObject(ofClass: NSString.self) {
            group.enter()
            _ = p.loadObject(ofClass: NSString.self) { s, _ in
                if let s = s as? String { lock.lock(); tag = s; lock.unlock() }
                group.leave()
            }
        }
    }
    group.notify(queue: .main) { done(tag, urls) }
}

struct ShelfView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let bright = app.library.uiBright
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("NEO").font(.system(size: 22, weight: .light)).tracking(10).foregroundStyle(NEOColor.accent)
                    Spacer()
                    Hoverable { h in
                        Text(app.displayAuthor).font(.system(size: 13))
                            .foregroundStyle(h ? Color(hex: 0xDDDDDD) : NEOColor.muted(bright))
                    }
                    .onTapGesture { app.authorMenu() }
                    .help("Click to change your author name")
                    .padding(.trailing, 8)
                    Button("⇩ Import") { app.pickImport() }.buttonStyle(GhostButton(bright: bright))
                        .help("Import .docx, .txt, or .md manuscripts")
                    Button("+ Shelf") { app.addShelf() }.buttonStyle(GhostButton(bright: bright))
                        .help("Add a shelf")
                }
                .padding(.bottom, 36)

                ForEach(app.visibleShelves) { shelf in
                    ShelfRow(shelf: shelf)
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 80)
        }
        .scrollIndicators(.automatic)
    }
}

private struct ShelfRow: View {
    let shelf: Shelf
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var targeted = false
    @State private var headTargeted = false
    @State private var hover = false
    @FocusState private var editing: Bool
    @State private var renaming = false

    private func finishRename() {
        guard renaming else { return }
        renaming = false
        app.renameShelf(shelf.id, name)
    }

    var body: some View {
        let bright = app.library.uiBright
        VStack(alignment: .leading, spacing: 0) {
            if headTargeted {
                RoundedRectangle(cornerRadius: 2).fill(NEOColor.accent).frame(height: 3)
                    .shadow(color: NEOColor.accent.opacity(0.8), radius: 5)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            HStack(spacing: 10) {
                Text("⠿").font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0x3A3A3A))
                    .opacity(hover ? 1 : (bright ? 0.55 : 0))
                    .onDrag { NSItemProvider(object: (shelfPrefix + shelf.id) as NSString) }
                    .help("Drag to reorder shelves")
                Group {
                    if renaming {
                        TextField("", text: $name)
                            .textFieldStyle(.plain)
                            .focused($editing)
                            .fixedSize()
                            .onSubmit { finishRename() }
                            .onChange(of: editing) { _, now in if !now { finishRename() } }
                            .onAppear { DispatchQueue.main.async { editing = true } }
                    } else {
                        Text(shelf.name.uppercased())
                            .onTapGesture { renaming = true }
                    }
                }
                .font(.system(size: 12))
                .tracking(2)
                .foregroundStyle(renaming ? Color(hex: 0xDDDDDD) : NEOColor.muted(bright))
                .padding(.bottom, 1)
                .overlay(alignment: .bottom) { if renaming { Rectangle().fill(NEOColor.accent).frame(height: 1) } }
                .help("Click to rename · right-click to export or delete")
                    .contextMenu {
                        Button("Export shelf as anthology…") { Task { await app.exportAnthology(shelf) } }
                        Divider()
                        Button("Delete shelf", role: .destructive) { app.deleteShelf(shelf.id) }
                    }
            }
            .padding(.bottom, 14)
            .onDrop(of: [.plainText], isTargeted: $headTargeted) { providers in
                loadDrop(providers) { tag, _ in
                    if let tag, tag.hasPrefix(shelfPrefix) { app.moveShelf(String(tag.dropFirst(shelfPrefix.count)), before: shelf.id) }
                    else if let tag, tag.hasPrefix(bookPrefix) { app.moveBook(String(tag.dropFirst(bookPrefix.count)), to: shelf.id, before: shelf.bookIds.first) }
                }
                return true
            }

            FlowRow(spacing: 22) {
                ForEach(shelf.bookIds, id: \.self) { id in
                    if let meta = app.metas[id] {
                        BookTile(meta: meta, shelfId: shelf.id)
                    }
                }
                NewBookTile { app.createBook(on: shelf.id) }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .bottomLeading)
            .padding(.bottom, 10)
            .background(targeted ? NEOColor.accent.opacity(0.05) : .clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(hex: 0x2E2A24)).frame(height: 4)
                    .shadow(color: .black.opacity(0.9), radius: 7, y: 8)
            }
            .onDrop(of: [.plainText, .fileURL], isTargeted: $targeted) { providers in
                loadDrop(providers) { tag, urls in
                    if !urls.isEmpty {
                        app.showToast("Importing…")
                        app.importFiles(urls, shelfId: shelf.id)
                    } else if let tag, tag.hasPrefix(bookPrefix) {
                        app.moveBook(String(tag.dropFirst(bookPrefix.count)), to: shelf.id, before: nil)
                    }
                }
                return true
            }
        }
        .padding(.bottom, 44)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onAppear { name = shelf.name }
        .onChange(of: shelf.name) { _, n in if !renaming { name = n } }
    }
}

private struct BookTile: View {
    let meta: BookMeta
    let shelfId: String
    @Environment(AppModel.self) private var app
    @State private var hover = false
    @State private var targeted = false

    var body: some View {
        ZStack(alignment: .bottom) {
            BookCover(meta: meta)
            if meta.wordGoal > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.12))
                        Rectangle().fill(NEOColor.accent)
                            .frame(width: g.size.width * min(1, CGFloat(meta.wordCount ?? 0) / CGFloat(meta.wordGoal)))
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(width: 104, height: 150)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 6, topTrailingRadius: 6))
        .overlay(alignment: .leading) {
            // the spine's inner shadow
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 6)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            if targeted {
                RoundedRectangle(cornerRadius: 2).fill(NEOColor.accent).frame(width: 3)
                    .shadow(color: NEOColor.accent.opacity(0.8), radius: 5).offset(x: -12)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 4, x: 2, y: 3)
        .offset(y: hover ? -5 : 0)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .help(meta.wordGoal > 0
              ? "\(meta.title) — \((meta.wordCount ?? 0).formatted()) / \(meta.wordGoal.formatted()) words"
              : meta.title)
        .onTapGesture { app.open(meta.id) }
        .onDrag { NSItemProvider(object: (bookPrefix + meta.id) as NSString) }
        .onDrop(of: [.plainText, .fileURL], isTargeted: $targeted) { providers in
            loadDrop(providers) { tag, urls in
                if !urls.isEmpty { app.dropOnBook(meta, urls) }
                else if let tag, tag.hasPrefix(bookPrefix) {
                    app.moveBook(String(tag.dropFirst(bookPrefix.count)), to: shelfId, before: meta.id)
                }
            }
            return true
        }
        .contextMenu {
            Button(meta.coverImage == nil ? "Set Cover Image…" : "Replace Cover Image…") { app.pickCover(meta) }
            if meta.coverImage != nil {
                Button("Remove Cover Image") { app.removeCover(meta) }
            }
            Divider()
            Button("Set Word Goal…") { app.setWordGoal(meta) }
            Divider()
            Button("Remove from Bookshelf") { app.removeFromShelves(meta) }
            Button("Move to Trash…", role: .destructive) { app.trashBook(meta) }
        }
    }
}

private struct NewBookTile: View {
    let action: () -> Void
    @Environment(AppModel.self) private var app
    @State private var hover = false

    var body: some View {
        let c = hover ? NEOColor.accent : Color(hex: app.library.uiBright ? 0x6A6A6A : 0x4A4A4A)
        Text("+")
            .font(.system(size: 34, weight: .ultraLight))
            .foregroundStyle(c)
            .frame(width: 104, height: 150)
            .background(Color.white.opacity(0.02))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 6, topTrailingRadius: 6)
                .stroke(c, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .offset(y: hover ? -5 : 0)
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
            .help("Start a new book")
    }
}
