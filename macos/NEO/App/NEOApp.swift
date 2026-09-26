import SwiftUI
import AppKit

@main
struct NEOApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

    var body: some Scene {
        Window("NEO", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 800, minHeight: 600)
                .preferredColorScheme(.dark)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands { NEOCommands(app: app) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Esc and ⌘Enter work everywhere, the way they did in the Electron build
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.hasMarkedText() { return e }
            if e.keyCode == 53 && mods.isEmpty {
                return MainActor.assumeIsolated { AppModel.shared.handleEscape() } ? nil : e
            }
            if (e.keyCode == 36 || e.keyCode == 76) && mods == .command {
                MainActor.assumeIsolated { AppModel.shared.toggleFullScreen() }
                return nil
            }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.session?.flushAll() }
        }
        #if DEBUG
        MainActor.assumeIsolated { DebugDriver.startIfRequested() }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.session?.flushAll()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The window is the dark surround.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.backgroundColor = NEOColor.nsBg
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = false
            w.tabbingMode = .disallowed
            w.collectionBehavior.insert(.fullScreenPrimary)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct NEOCommands: Commands {
    let app: AppModel

    private func send(_ sel: Selector) { NSApp.sendAction(sel, to: nil, from: nil) }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About NEO") { app.modal = .about }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Goals & Settings…") { app.modal = .stats }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {
            Menu("Export") {
                Button("Plain Text (.txt)") { app.export("txt") }
                Button("Markdown (.md)") { app.export("md") }
                Button("Web Page (.html)") { app.export("html") }
                Button("PDF (.pdf)") { app.export("pdf") }
                Button("Word (.docx)") { app.export("docx") }
                Button("EPUB (.epub)") { app.export("epub") }
            }
            .disabled(app.session == nil)
            Divider()
            Button("Email Draft to Myself") { app.emailDraft() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(app.session == nil)
            Button("Email Settings…") { Task { _ = await app.emailSettings() } }
            Divider()
            Button("Import Manuscripts…") { app.pickImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Back to Shelf") { app.backToShelf() }
                .disabled(app.session == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { app.undo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { app.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find & Replace") { app.session?.openSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(app.session == nil)
            Button("Spellcheck Pass") { app.session?.toggleSpellcheck() }
                .keyboardShortcut(";", modifiers: .command)
                .disabled(app.session == nil)
            Divider()
            Button("Placeholder Note") { app.session?.insertPlaceholder() }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(app.session == nil)
            Button("Send Selection to Darlings") { app.session?.darlingFromKeyboard() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(app.session == nil)
        }
        CommandMenu("Format") {
            Button("Bold") { send(#selector(ProseTextView.neoToggleBold(_:))) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { send(#selector(ProseTextView.neoToggleItalic(_:))) }
                .keyboardShortcut("i", modifiers: .command)
            Divider()
            Menu("Body Font") {
                ForEach(NEOFonts.bodyNames, id: \.self) { f in
                    Toggle(f, isOn: Binding(get: { app.theme.bodyFont == f }, set: { _ in app.setBodyFont(f) }))
                }
            }
            Menu("Drop Cap Style") {
                ForEach(NEOFonts.dropCapStyles, id: \.key) { d in
                    Toggle(d.label, isOn: Binding(get: { app.theme.dropCap == d.key }, set: { _ in app.setDropCap(d.key) }))
                }
            }
            Menu("Align Paragraph") {
                ForEach(["Left", "Center", "Right", "Justify"], id: \.self) { a in
                    Button(a) { app.session?.applyAlign(a.lowercased()) }
                }
            }
            .disabled(app.session == nil)
            Divider()
            Button("Larger Text") { app.changeFontSize(1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Smaller Text") { app.changeFontSize(-1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Text Size") { app.changeFontSize(0) }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Toggle("Typewriter Scrolling", isOn: Binding(get: { app.library.typewriter }, set: { _ in app.toggleTypewriter() }))
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("Full Screen") { app.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Menu("Page") {
                Toggle("Night", isOn: Binding(get: { app.theme.night }, set: { _ in app.setPageTheme("night") }))
                Toggle("Paper", isOn: Binding(get: { !app.theme.night }, set: { _ in app.setPageTheme("paper") }))
            }
            Toggle("Brighter Interface", isOn: Binding(get: { app.library.uiBright }, set: { _ in app.toggleBright() }))
        }
        CommandGroup(replacing: .help) {
            Button("NEO Shortcuts") { app.modal = .help }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            NEOColor.bg.ignoresSafeArea()
            if let s = app.session {
                EditorView(session: s)
                    .id(s.meta.id)
                    .transition(.opacity)
            } else {
                ShelfView()
                    .transition(.opacity)
            }
            if let t = app.toast {
                VStack {
                    Spacer()
                    Text(t)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0xBBBBBB))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Capsule().fill(Color(hex: 0x2B2B2B)))
                        .shadow(color: .black.opacity(0.4), radius: 7, y: 3)
                        .padding(.bottom, 54)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            if let m = app.modal {
                ModalHost(modal: m)
            }
        }
        .animation(.easeOut(duration: 0.25), value: app.session?.meta.id)
        .animation(.easeOut(duration: 0.2), value: app.toast)
    }
}
