import SwiftUI
import Charts

/// NEO's dialogs: a dark card over a dimmed window.
struct ModalHost: View {
    let modal: Modal
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            Group {
                switch modal {
                case .input(let title, let placeholder, let value, let done):
                    InputModal(title: title, placeholder: placeholder, initial: value, done: done)
                case .options(let title, let message, let options, let done):
                    OptionsModal(title: title, message: message, options: options, done: done)
                case .firstRun:
                    FirstRunModal()
                case .stats:
                    StatsModal()
                case .help:
                    HelpModal()
                case .about:
                    AboutModal()
                }
            }
        }
        .transition(.opacity)
    }
}

struct ModalCard<Content: View>: View {
    var width: CGFloat = 480
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 38).padding(.vertical, 34)
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(NEOColor.bgSoft))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0x333333)))
            .foregroundStyle(Color(hex: 0xDDDDDD))
    }
}

struct ModalTitle: View {
    let text: String
    var size: CGFloat = 17
    var body: some View {
        Text(text).font(.system(size: size)).foregroundStyle(NEOColor.accent).padding(.bottom, 10)
    }
}

/// A dark, gold-focused text input.
struct DarkField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    var autofocus = false

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color(hex: 0x666666)))
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: 0xEEEEEE))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 6).fill(NEOColor.bg))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? NEOColor.accent : NEOColor.border))
            .focused($focused)
            .onSubmit(onSubmit)
            .onAppear { if autofocus { DispatchQueue.main.async { focused = true } } }
    }
}

struct InputModal: View {
    let title: String
    let placeholder: String
    let initial: String
    let done: (String?) -> Void
    @State private var text = ""

    var body: some View {
        ModalCard(width: 380) {
            ModalTitle(text: title, size: 16)
            DarkField(placeholder: placeholder, text: $text, onSubmit: { done(text.trimmingCharacters(in: .whitespaces)) }, autofocus: true)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(QuietButton())
                Button("OK") { done(text.trimmingCharacters(in: .whitespaces)) }.buttonStyle(GoldButton())
            }
            .padding(.top, 14)
        }
        .onAppear { text = initial }
    }
}

struct ChoiceButton: View {
    let option: ModalOption
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(option.label).fontWeight(.semibold)
                    .foregroundStyle(option.danger ? Color(hex: 0xD97B6C) : NEOColor.accent)
                if let d = option.desc {
                    Text(d).font(.system(size: 12)).foregroundStyle(Color(hex: 0x8A8A8A))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(NEOColor.bg))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(hover ? NEOColor.accent : (option.danger ? Color(hex: 0x6B3A34) : NEOColor.border)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct OptionsModal: View {
    let title: String
    let message: String?
    let options: [ModalOption]
    let done: (String?) -> Void

    var body: some View {
        ModalCard(width: 420) {
            ModalTitle(text: title, size: 16)
            if let message { Text(message).font(.system(size: 14)).padding(.bottom, 18) }
            VStack(spacing: 8) {
                ForEach(options) { o in ChoiceButton(option: o) { done(o.value) } }
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(QuietButton())
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - First run

struct FirstRunModal: View {
    @Environment(AppModel.self) private var app
    @State private var step = 1
    @State private var name = ""
    @State private var pen = ""
    @State private var style = "pantser"
    @State private var body_ = "Georgia"
    @State private var cap = "literary"
    @State private var previewBody: String? = nil
    @State private var previewCap: String? = nil

    var body: some View {
        ModalCard(width: 520) {
            if step == 1 { stepOne } else { stepTwo }
        }
    }

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle(text: "Welcome to NEO", size: 22)
            Text("NEO knows you're writing books. A few quick questions and it will never ask anything again.")
                .font(.system(size: 14)).padding(.bottom, 18)
            (Text("Your name ") + Text("(appears as the author on every document — leave blank for “Anonymous”)").foregroundColor(Color(hex: 0x8A8A8A)))
                .font(.system(size: 13)).padding(.bottom, 6)
            DarkField(placeholder: "", text: $name, autofocus: true).padding(.bottom, 16)
            (Text("Pen name ") + Text("(optional — used on title pages if set)").foregroundColor(Color(hex: 0x8A8A8A)))
                .font(.system(size: 13)).padding(.bottom, 6)
            DarkField(placeholder: "", text: $pen).padding(.bottom, 16)
            Text("Are you a pantser or a plotter?").font(.system(size: 14)).padding(.bottom, 10)
            HStack(spacing: 12) {
                ChoiceButton(option: ModalOption(label: "Pantser", desc: "I write by the seat of my pants. New books open on a blank page.", value: "pantser")) {
                    style = "pantser"; step = 2
                }
                ChoiceButton(option: ModalOption(label: "Plotter", desc: "I outline first. New books open in the Outline tab.", value: "plotter")) {
                    style = "plotter"; step = 2
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepTwo: some View {
        let showBody = previewBody ?? body_
        let showCap = previewCap ?? cap
        let sample = "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness, it was the epoch of belief…"
        return VStack(alignment: .leading, spacing: 0) {
            ModalTitle(text: "How should the page look?", size: 22)
            Text("Pick a typeface and a drop-cap style. The sample below shows exactly what you'll get. (Changeable anytime in the Format menu.)")
                .font(.system(size: 14)).padding(.bottom, 18)
            HStack(alignment: .top, spacing: 7) {
                Text(String(sample.prefix(1)))
                    .font(Font(NEOFonts.dropCapFont(showCap, size: 46)))
                    .padding(.top, -4)
                Text(String(sample.dropFirst()))
                    .font(.custom(showBody, size: 15))
                    .lineSpacing(7)
            }
            .foregroundStyle(Color(hex: 0x1C1C1C))
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xFBFAF7)))
            .padding(.bottom, 20)
            Text("Body typeface").font(.system(size: 14)).padding(.bottom, 6)
            FlowRow {
                ForEach(NEOFonts.bodyNames, id: \.self) { f in
                    FontChip(label: f, font: .custom(f, size: 14), selected: body_ == f) { body_ = f }
                        .onHover { previewBody = $0 ? f : nil }
                }
            }
            .padding(.bottom, 16)
            Text("Drop cap").font(.system(size: 14)).padding(.bottom, 6)
            HStack(spacing: 8) {
                ForEach(NEOFonts.dropCapStyles, id: \.key) { d in
                    FontChip(label: d.label, cap: Font(NEOFonts.dropCapFont(d.key, size: 20)), font: .system(size: 14), selected: cap == d.key) { cap = d.key }
                        .onHover { previewCap = $0 ? d.key : nil }
                }
            }
            HStack {
                Spacer()
                Button("Start writing") {
                    app.finishFirstRun(name: name.trimmingCharacters(in: .whitespaces), pen: pen.trimmingCharacters(in: .whitespaces),
                                       style: style, body: body_, dropCap: cap)
                }
                .buttonStyle(GoldButton())
            }
            .padding(.top, 20)
        }
    }
}

struct FontChip: View {
    let label: String
    var cap: Font? = nil
    let font: Font
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let cap { Text("A").font(cap) }
                Text(label).font(font)
            }
            .foregroundStyle(selected ? NEOColor.accent : Color(hex: 0xDDDDDD))
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(NEOColor.bg))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? NEOColor.accent : (hover ? Color(hex: 0x666666) : NEOColor.border)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Wraps its children onto as many rows as they need.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: w, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Goals, sprints, and the chart

struct StatsModal: View {
    @Environment(AppModel.self) private var app
    @State private var daily = ""
    @State private var bookGoal = ""
    @State private var dayEnds = 0
    @State private var style = "pantser"
    @State private var sprintTarget = "500"

    private struct Day: Identifiable {
        let id: Int
        let daily: Double
        let total: Double
    }

    var body: some View {
        let s = app.session
        ModalCard(width: 600) {
            ModalTitle(text: s.map { "\($0.meta.title) — progress" } ?? "Goals & settings")
            if let s {
                HStack(spacing: 26) {
                    stat(s.bookWords.formatted(), "total words")
                    stat(s.wordsToday.formatted(), "today")
                    stat(s.meta.wordGoal > 0 ? "\(min(100, Int((Double(s.bookWords) / Double(s.meta.wordGoal) * 100).rounded())))%" : "—", "of book goal")
                }
                .padding(.vertical, 14)
                chart(s)
            }
            HStack(spacing: 12) {
                labeled("Daily goal") { numberField($daily, "500") }
                if s != nil { labeled("Book goal") { numberField($bookGoal, "80000") } }
            }
            .padding(.top, 18)
            HStack(spacing: 8) {
                Text("My writing day ends at").font(.system(size: 13))
                Picker("", selection: $dayEnds) {
                    ForEach(0..<7) { h in Text(h == 0 ? "midnight" : "\(h) am").tag(h) }
                }
                .labelsHidden().frame(width: 120)
            }
            .padding(.top, 12)
            if let s {
                HStack(spacing: 10) {
                    Text("Sprint").font(.system(size: 13))
                    numberField($sprintTarget, "500")
                    Text("words").font(.system(size: 13))
                    Button(s.sprint.map { !$0.done } == true ? "End sprint" : "Start sprint") { sprint(s) }
                        .buttonStyle(GoldButton())
                    Text(s.sprint.map { !$0.done } == true ? "sprint running…" : "a small hill to charge up")
                        .font(.system(size: 12)).foregroundStyle(Color(hex: 0x8A8A8A))
                }
                .padding(.top, 12)
            }
            HStack(spacing: 8) {
                Text("New books open for a").font(.system(size: 13))
                Picker("", selection: $style) {
                    Text("Pantser — straight to the blank page").tag("pantser")
                    Text("Plotter — outline first").tag("plotter")
                }
                .labelsHidden().frame(width: 280)
            }
            .padding(.top, 12)
            HStack {
                Spacer()
                Button("Done") { close() }.buttonStyle(GoldButton())
            }
            .padding(.top, 14)
        }
        .onAppear {
            daily = app.library.dailyGoal > 0 ? String(app.library.dailyGoal) : ""
            bookGoal = (s?.meta.wordGoal ?? 0) > 0 ? String(s!.meta.wordGoal) : ""
            dayEnds = app.library.dayEndsAt
            style = app.library.writingStyle == "plotter" ? "plotter" : "pantser"
            sprintTarget = String(s?.sprint?.target ?? 500)
        }
        .onDisappear(perform: save)
    }

    private func stat(_ big: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(big).font(.custom("Georgia", size: 26)).foregroundStyle(NEOColor.accent)
            Text(label.uppercased()).font(.system(size: 11)).tracking(1).foregroundStyle(Color(hex: 0x8A8A8A))
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) { Text(label).font(.system(size: 13)); c() }
    }

    private func numberField(_ b: Binding<String>, _ ph: String) -> some View {
        TextField("", text: b, prompt: Text(ph).foregroundStyle(Color(hex: 0x666666)))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(width: 90)
            .background(RoundedRectangle(cornerRadius: 5).fill(NEOColor.bg))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(NEOColor.border))
    }

    @ViewBuilder private func chart(_ s: BookSession) -> some View {
        let days: [String] = (0..<30).reversed().map { i in
            s.writingDay(Calendar.current.date(byAdding: .day, value: -i, to: Date())!)
        }
        let counts = s.meta.dailyCounts
        let dailyVals = days.map { counts[$0].map { max(0, $0.end - $0.start) } ?? 0 }
        let totals: [Int] = {
            var last = days.first(where: { counts[$0] != nil }).map { counts[$0]!.start } ?? 0
            return days.map { d in if let c = counts[d] { last = c.end }; return last }
        }()
        let goal = s.meta.wordGoal
        let maxC = Double(max(totals.max() ?? 0, goal, 1))
        let maxD = Double(max(dailyVals.max() ?? 0, app.library.dailyGoal, 1))
        // bars and the running total share one plot, each on its own scale
        let data = (0..<30).map { Day(id: $0, daily: Double(dailyVals[$0]) / maxD * 0.45, total: Double(totals[$0]) / maxC * 0.9) }
        VStack(spacing: 2) {
            Chart {
                ForEach(data) { d in
                    BarMark(x: .value("Day", d.id), y: .value("Daily", d.daily), width: .ratio(0.8))
                        .foregroundStyle(Color(hex: 0x3D5A4F))
                        .cornerRadius(1.5)
                }
                ForEach(data) { d in
                    LineMark(x: .value("Day", d.id), y: .value("Total", d.total))
                        .foregroundStyle(NEOColor.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if goal > 0 {
                    RuleMark(y: .value("Goal", Double(goal) / maxC * 0.9))
                        .foregroundStyle(NEOColor.accent.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...1)
            .chartXScale(domain: -0.5...29.5)
            .frame(height: 180)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x1D1D1D)))
            HStack {
                Text("30 days ago")
                Spacer()
                Text("▮ daily words").foregroundStyle(Color(hex: 0x3D8A6A))
                Spacer()
                Text("— total" + (goal > 0 ? " · - - goal" : "")).foregroundStyle(NEOColor.accent)
                Spacer()
                Text("today")
            }
            .font(.system(size: 10)).foregroundStyle(Color(hex: 0x666666)).padding(.horizontal, 4)
        }
    }

    private func sprint(_ s: BookSession) {
        if let sp = s.sprint, !sp.done {
            let got = s.bookWords - sp.startCount
            let mins = Int(Date().timeIntervalSince(sp.startTime) / 60)
            app.showToast("Sprint ended — \(got.formatted()) words in \(mins) min")
            s.sprint = nil
        } else {
            let target = Int(sprintTarget.filter(\.isNumber)) ?? 500
            s.sprint = Sprint(target: max(50, target), startCount: s.bookWords, startTime: Date())
            app.showToast("Sprint started — \(max(50, target).formatted()) words. Go.")
        }
        close()
    }

    private func close() {
        app.modal = nil // saving happens as the dialog goes, however it goes
    }

    private func save() {
        app.library.dailyGoal = Int(daily.filter(\.isNumber)) ?? 0
        app.library.dayEndsAt = dayEnds
        app.library.writingStyle = style
        if let s = app.session {
            s.meta.wordGoal = Int(bookGoal.filter(\.isNumber)) ?? 0
            s.scheduleMetaSave()
            s.updateCounters()
        }
        app.saveLibrary()
    }
}

// MARK: - Help and About

struct HelpModal: View {
    @Environment(AppModel.self) private var app

    private let sections: [(String, [(String, String)])] = [
        ("Writing", [
            ("Enter ×2", "Section break (***)"),
            ("Enter ×3", "New chapter, auto-numbered"),
            ("⌘⇧X", "Placeholder note"),
            ("⌘⇧D", "Send the selected passage to Darlings"),
            ("⌘Z", "Undo — including big moves (chapter splits and deletes, replace-all, darlings)"),
            ("-- and ...", "Become an em dash — and a true ellipsis …"),
            ("⌘B · ⌘I", "Bold, italic. Quotes curl themselves.")
        ]),
        ("Getting around", [
            ("⌘F", "Find & replace across the whole book"),
            ("Hover edges", "Left: chapters & outline notes. Right: comments (☉ pins)."),
            ("Esc", "Closes whatever’s open; otherwise back to the shelf")
        ]),
        ("Modes", [
            ("⌘⇧F · ⌘↩", "Full screen (Esc leaves)"),
            ("⌘⇧T", "Typewriter scrolling"),
            ("⌘;", "Spellcheck pass (right-click squiggles for fixes)")
        ]),
        ("Files", [
            ("⌘E", "Email a timestamped draft to yourself"),
            ("⌘⇧I", "Import .docx / .txt / .md manuscripts"),
            ("File → Export", "txt · md · html · pdf · docx · epub")
        ]),
        ("Mouse", [
            ("Drag text", "Onto the Darlings tab"),
            ("Right-click", "Books, shelf names, chapter headings, outline lines"),
            ("Drag chapters", "In the left panel, to reorder — everything renumbers"),
            ("Drag images", "From Finder onto a book, to make it the cover"),
            ("Double-click", "A tab, to rename it"),
            ("Click counters", "Cycle word counts · open goals & sprints"),
            ("Pinch", "Zoom the page — text and column together (⌘0 resets)")
        ])
    ]

    var body: some View {
        ModalCard(width: 580) {
            ModalTitle(text: "NEO Shortcuts", size: 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections, id: \.0) { sec in
                        Text(sec.0.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(1.5)
                            .foregroundStyle(NEOColor.accent).padding(.top, 16).padding(.bottom, 8)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            ForEach(sec.1, id: \.0) { row in
                                GridRow {
                                    Text(row.0).fontWeight(.semibold).foregroundStyle(Color(hex: 0xEEEEEE))
                                        .frame(width: 110, alignment: .leading)
                                    Text(row.1).foregroundStyle(Color(hex: 0xBBBBBB))
                                }
                                .font(.system(size: 13.5))
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 520)
            HStack { Spacer(); Button("Got it") { app.modal = nil }.buttonStyle(GoldButton()) }.padding(.top, 18)
        }
    }
}

struct AboutModal: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ModalCard(width: 340) {
            VStack(spacing: 10) {
                Text("NEO").font(.system(size: 22)).tracking(6).foregroundStyle(NEOColor.accent)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .foregroundStyle(Color(hex: 0x999999))
                Text("A word processor for authors.").font(.system(size: 13)).foregroundStyle(Color(hex: 0x777777))
                Button("Back to writing") { app.modal = nil }.buttonStyle(GoldButton()).padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
