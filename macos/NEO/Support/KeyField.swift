import SwiftUI
import AppKit

/// A plain text field that reports the keys NEO gives meaning to — Enter,
/// Tab, Shift+Tab, arrows, and Backspace on an empty line — and can wrap to
/// several lines. Focus is requested by bumping `focusToken`.
struct KeyField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = NSFont(name: "Georgia", size: 15) ?? .systemFont(ofSize: 15)
    var color: NSColor = .labelColor
    var placeholderColor: NSColor = .placeholderTextColor
    var multiline = true
    var focusToken: Int = 0
    var selectAllOnFocus = false
    var onCommit: (() -> Void)? = nil          // editing ended (blur)
    var onFocus: (() -> Void)? = nil           // the field took the keyboard
    var onEnter: (() -> Bool)? = nil
    var onShiftEnter: (() -> Bool)? = nil
    var onTab: (() -> Bool)? = nil
    var onBacktab: (() -> Bool)? = nil
    var onUp: (() -> Bool)? = nil
    var onDown: (() -> Bool)? = nil
    var onEmptyBackspace: (() -> Bool)? = nil

    final class Field: NSTextField {
        var lastFocusToken = 0
        var onFocus: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocus?() }
            return ok
        }

        override var intrinsicContentSize: NSSize {
            guard cell?.wraps == true, bounds.width > 0 else { return super.intrinsicContentSize }
            let h = cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: CGFloat.greatestFiniteMagnitude)).height ?? 20
            return NSSize(width: NSView.noIntrinsicMetric, height: ceil(h))
        }
        override func layout() {
            super.layout()
            invalidateIntrinsicContentSize()
        }
    }

    func makeNSView(context: Context) -> Field {
        let f = Field()
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.delegate = context.coordinator
        f.cell?.wraps = multiline
        f.cell?.isScrollable = !multiline
        f.lineBreakMode = multiline ? .byWordWrapping : .byTruncatingTail
        f.maximumNumberOfLines = multiline ? 0 : 1
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.lastFocusToken = focusToken
        return f
    }

    func updateNSView(_ f: Field, context: Context) {
        context.coordinator.parent = self
        f.onFocus = onFocus
        if f.currentEditor() == nil && f.stringValue != text { f.stringValue = text }
        f.font = font
        f.textColor = color
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), .foregroundColor: placeholderColor
        ])
        if focusToken != f.lastFocusToken {
            f.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let w = f.window else { return }
                w.makeFirstResponder(f)
                if let ed = f.currentEditor() {
                    if selectAllOnFocus { ed.selectAll(nil) }
                    else { ed.selectedRange = NSRange(location: (f.stringValue as NSString).length, length: 0) }
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView f: Field, context: Context) -> CGSize? {
        let w = proposal.width ?? 200
        guard multiline else { return CGSize(width: w, height: ceil(font.ascender - font.descender + font.leading) + 4) }
        let text = f.stringValue.isEmpty ? (placeholder.isEmpty ? " " : placeholder) : f.stringValue
        let r = (text as NSString).boundingRect(with: NSSize(width: max(10, w - 4), height: 10_000),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return CGSize(width: w, height: ceil(r.height) + 4)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyField
        init(_ p: KeyField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.text = f.stringValue
            f.invalidateIntrinsicContentSize()
        }

        func controlTextDidEndEditing(_ n: Notification) {
            parent.onCommit?()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                if NSEvent.modifierFlags.contains(.shift), let h = parent.onShiftEnter { return h() }
                return parent.onEnter?() ?? false
            case #selector(NSResponder.insertTab(_:)): return parent.onTab?() ?? false
            case #selector(NSResponder.insertBacktab(_:)): return parent.onBacktab?() ?? false
            case #selector(NSResponder.moveUp(_:)): return parent.onUp?() ?? false
            case #selector(NSResponder.moveDown(_:)): return parent.onDown?() ?? false
            case #selector(NSResponder.deleteBackward(_:)):
                if textView.string.trimmingCharacters(in: .whitespaces).isEmpty, let h = parent.onEmptyBackspace { return h() }
                return false
            default: return false
            }
        }
    }
}

// MARK: - The two button voices every dialog speaks in

struct GoldButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: 0x191919))
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(NEOColor.accent.opacity(configuration.isPressed ? 0.85 : 1)))
            .contentShape(Rectangle())
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: configuration.isPressed ? 0xBBBBBB : 0x888888))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
    }
}

/// Outline buttons: grey until hovered, then gold.
struct GhostButton: ButtonStyle {
    var bright = false
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(hover ? NEOColor.accent : NEOColor.muted(bright))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(hover ? NEOColor.accent : Color(hex: bright ? 0x555555 : 0x3A3A3A)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

struct Hoverable<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hover = false

    var body: some View {
        content(hover).onHover { hover = $0 }
    }
}
