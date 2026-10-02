import SwiftUI

/// One colour per Sortformer slot, readable in light and dark mode.
enum Palette {
    static let speakers: [Color] = [
        Color(nsColor: NSColor(name: nil) { $0.isDark ? #colorLiteral(red: 0.42, green: 0.66, blue: 1, alpha: 1) : #colorLiteral(red: 0.11, green: 0.37, blue: 0.85, alpha: 1) }),
        Color(nsColor: NSColor(name: nil) { $0.isDark ? #colorLiteral(red: 0.96, green: 0.6, blue: 0.3, alpha: 1) : #colorLiteral(red: 0.78, green: 0.36, blue: 0.04, alpha: 1) }),
        Color(nsColor: NSColor(name: nil) { $0.isDark ? #colorLiteral(red: 0.45, green: 0.82, blue: 0.55, alpha: 1) : #colorLiteral(red: 0.1, green: 0.52, blue: 0.27, alpha: 1) }),
        Color(nsColor: NSColor(name: nil) { $0.isDark ? #colorLiteral(red: 0.85, green: 0.55, blue: 0.95, alpha: 1) : #colorLiteral(red: 0.55, green: 0.2, blue: 0.7, alpha: 1) }),
    ]
    static let unknown = Color.secondary
    static let marker = Color(nsColor: NSColor(name: nil) { $0.isDark ? #colorLiteral(red: 0.58, green: 0.25, blue: 0.42, alpha: 1) : #colorLiteral(red: 1, green: 0.8, blue: 0.9, alpha: 1) })

    static func color(_ slot: Int?) -> Color {
        guard let slot, speakers.indices.contains(slot) else { return unknown }
        return speakers[slot]
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// Where the keyboard is: the captions (single-key shortcuts work) or her notes (keys are typing).
enum KeyFocus: Hashable { case captions, notes }

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmNewCall = false
    @State private var showVoiceSheet = false
    @AppStorage("onboarded") private var onboarded = false
    @FocusState private var focus: KeyFocus?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                VSplitView {
                    KeptPanel()
                        .frame(minHeight: 160)
                    NotesPanel(focus: $focus)
                        .frame(minHeight: 140, idealHeight: 220)
                }
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
                TranscriptView()
                    .frame(minWidth: 400)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        // The window itself takes focus so Space/K/N work without clicking anything first.
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .captions)
        .onAppear { focus = .captions }
        // Single-key shortcuts step aside while she's typing a note.
        .onKeyPress(.space) {
            guard focus != .notes else { return .ignored }
            model.toggleListening()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "kKnN")) { press in
            guard focus != .notes else { return .ignored }
            if press.characters.lowercased() == "k" { model.keepLastLine() } else { focus = .notes }
            return .handled
        }
        .onChange(of: model.focusNotesRequest) { focus = .notes }
        .sheet(isPresented: $showVoiceSheet) { VoiceSheet() }
        .sheet(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView { onboarded = true }
                .interactiveDismissDisabled()
        }
        .confirmationDialog("Clear the captions, notes and everything kept?", isPresented: $confirmNewCall) {
            Button("New call", role: .destructive) { model.newCall() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(action: model.toggleListening) {
                Label(model.isListening ? "Pause captions" : "Start captions",
                      systemImage: model.isListening ? "pause.fill" : "record.circle")
                    .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isListening ? .red : .accentColor)
            .controlSize(.large)
            .disabled(!model.isReady)
            .help("Start or pause captions (Space)")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.noSound && model.isListening
                     ? "No sound from \(model.deviceName). Is the transmitter on?"
                     : model.status)
                    .foregroundStyle(model.isError || (model.noSound && model.isListening) ? .red : .secondary)
                    .lineLimit(2)
                Text("On this Mac only. Nothing is saved.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()

            Picker("Mic", selection: Binding(get: { model.deviceID ?? "" }, set: { model.pickDevice($0) })) {
                ForEach(model.devices) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 220)
            LiveLevelMeter()

            ControlGroup {
                Button { model.fontSize = max(16, model.fontSize - 3) } label: { Image(systemName: "textformat.size.smaller") }
                Button { model.fontSize = min(48, model.fontSize + 3) } label: { Image(systemName: "textformat.size.larger") }
            }
            .frame(width: 80)

            Button(model.hasMyVoice ? "My voice ✓" : "Teach my voice") { showVoiceSheet = true }
            Button("New call") {
                if model.hasCallContent { confirmNewCall = true } else { model.newCall() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Reads the level itself, so the 16-per-second updates only redraw this little bar.
struct LiveLevelMeter: View {
    @Environment(AppModel.self) private var model
    var body: some View { LevelMeter(level: model.level) }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.primary)
                    .frame(width: geo.size.width * CGFloat(min(1, level * 4)))
                    .animation(.linear(duration: 0.06), value: level)
            }
        }
        .frame(width: 60, height: 8)
        .help("Mic level")
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    /// Keep the newest line in view. Only her own scrolling turns this off; new text never does.
    @State private var follow = true
    @State private var nearBottom = true
    @State private var userScrolling = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.seenSlots.isEmpty { SpeakerBar() }
            ZStack(alignment: .bottomTrailing) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: model.fontSize * 0.5) {
                            if model.lines.isEmpty && model.partial.isEmpty {
                                Text(model.isListening
                                     ? "Listening… words appear here as they're spoken."
                                     : "Press Start captions (or Space). Phone numbers, addresses, dates and IDs are highlighted and collected on the left. Click a highlight to copy it.")
                                    .font(.system(size: model.fontSize * 0.7))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.lines) { line in
                                if let info = model.info(for: line.speaker), info.visibility == .hide {
                                    EmptyView()
                                } else {
                                    LineRow(line: line)
                                }
                            }
                            if !model.partial.isEmpty {
                                Text(model.partial)
                                    .font(.system(size: model.fontSize))
                                    .foregroundStyle(.secondary)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geo in
                        geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
                    } action: { _, isNear in
                        nearBottom = isNear
                        if isNear && userScrolling { follow = true }
                    }
                    .onScrollPhaseChange { _, phase in
                        switch phase {
                        case .tracking, .interacting, .decelerating:
                            userScrolling = true
                        case .idle:
                            if userScrolling { follow = nearBottom }
                            userScrolling = false
                        default:
                            break
                        }
                    }
                    .onChange(of: model.lines.count) { keepLatest(proxy) }
                    .onChange(of: model.partial) { keepLatest(proxy) }
                    .onChange(of: model.fontSize) { keepLatest(proxy) }
                    .overlay(alignment: .bottomTrailing) {
                        if !follow {
                            Button("Jump to latest") {
                                follow = true
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(16)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.openURL, OpenURLAction { url in
            // Highlights are links with a copy: scheme carrying the detail text.
            if url.scheme == "copy", let text = url.absoluteString.dropFirst(5).removingPercentEncoding {
                model.copy(text)
                return .handled
            }
            return .systemAction
        })
    }
}

extension TranscriptView {
    /// Scroll after layout has settled, so the new line's height is known.
    func keepLatest(_ proxy: ScrollViewProxy) {
        guard follow, !userScrolling else { return }
        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

struct LineRow: View {
    @Environment(AppModel.self) private var model
    let line: CaptionLine

    var body: some View {
        let info = model.info(for: line.speaker)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(info?.name ?? "?")
                .font(.system(size: max(12, model.fontSize * 0.45), weight: .semibold))
                .foregroundStyle(Palette.color(model.canonical(line.speaker)))
                .frame(width: 96, alignment: .trailing)
                .lineLimit(1)
            Text(attributed)
                .font(.system(size: model.fontSize))
                .textSelection(.enabled)
                .frame(maxWidth: 900, alignment: .leading)
        }
        .opacity(info?.visibility == .dim ? 0.45 : 1)
        .contextMenu {
            Button("Keep this line") { model.keep("Line", line.text, announce: true) }
            Button("Add to notes") { model.addToNotes(line.text) }
            Button("Copy line") { model.copy(line.text) }
        }
    }

    private var attributed: AttributedString {
        var result = AttributedString(line.text)
        for detail in line.details {
            guard let lower = AttributedString.Index(detail.range.lowerBound, within: result),
                  let upper = AttributedString.Index(detail.range.upperBound, within: result) else { continue }
            let value = String(line.text[detail.range])
            result[lower..<upper].backgroundColor = Palette.marker
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            result[lower..<upper].foregroundColor = .primary
            result[lower..<upper].link = URL(string: "copy:" + (value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
        }
        return result
    }
}

/// Who's been heard on this call. Click a chip to name them, dim/hide their lines,
/// or merge them into someone else when the separation split one person in two.
struct SpeakerBar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: Int?
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 10) {
            Text("Speakers").font(.caption).foregroundStyle(.secondary)
            ForEach(model.seenSlots, id: \.self) { slot in
                let info = model.info(for: slot)!
                let merged = model.mergedSlots(into: slot)
                Menu {
                    Section("Name") {
                        ForEach(["Me", "English caller", "Amharic caller"], id: \.self) { name in
                            Button(name) { model.rename(slot, to: name) }
                        }
                        Button("Other…") { draft = info.name; renaming = slot }
                    }
                    Section("Their lines") {
                        Picker("Lines", selection: Binding(get: { info.visibility }, set: { model.setVisibility(slot, $0) })) {
                            ForEach(SpeakerVisibility.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                    }
                    let others = model.seenSlots.filter { $0 != slot }
                    if !others.isEmpty || !merged.isEmpty {
                        Section("Same person?") {
                            if !others.isEmpty {
                                Menu("Merge \(info.name) into") {
                                    ForEach(others, id: \.self) { other in
                                        Button(model.info(for: other)!.name) { model.merge(slot, into: other) }
                                    }
                                }
                            }
                            ForEach(merged, id: \.self) { m in
                                Button("Separate Speaker \(m + 1) again") { model.separate(m) }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Palette.color(slot)).frame(width: 9, height: 9)
                        Text(info.name)
                        if !merged.isEmpty { Text("+\(merged.count)").foregroundStyle(.secondary) }
                        if info.visibility != .show { Text("(\(info.visibility.rawValue.lowercased()))").foregroundStyle(.secondary) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Name, dim, hide or merge this speaker")
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(.bar)
        .alert("Name this speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Save") { if let slot = renaming, !draft.isEmpty { model.rename(slot, to: draft) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

// MARK: - Kept

struct KeptPanel: View {
    @Environment(AppModel.self) private var model
    @State private var copied: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kept").font(.headline)
            if model.kept.isEmpty {
                Text("Numbers, phone numbers, dates and addresses collect here as they're said. Click one to copy it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.kept) { item in
                        HStack(alignment: .center) {
                            Button {
                                model.copy(item.value)
                                copied = item.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if copied == item.id { copied = nil } }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(copied == item.id ? "Copied" : item.kind)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(item.value)
                                        .font(.system(size: 20, weight: .bold).monospacedDigit())
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { model.kept.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .help("Remove")
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(copied == item.id ? Palette.marker : Color(nsColor: .controlBackgroundColor)))
                    }
                }
            }
            Text("Press K to keep the last line.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

// MARK: - Notes

/// A scratch pad for the call. Press N to start typing, Esc to go back to the captions.
struct NotesPanel: View {
    @Environment(AppModel.self) private var model
    var focus: FocusState<KeyFocus?>.Binding
    @State private var copied = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes").font(.headline)
                Spacer()
                if !model.notes.isEmpty {
                    Button(copied ? "Copied" : "Copy all") {
                        model.copy(model.notes)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.notes)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .focused(focus, equals: .notes)
                    .onKeyPress(.escape) {
                        focus.wrappedValue = .captions
                        return .handled
                    }
                if model.notes.isEmpty && focus.wrappedValue != .notes {
                    Text("Press N to write a note. Esc goes back.")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus.wrappedValue == .notes ? Color.accentColor : .clear, lineWidth: 2))
        }
        .padding(16)
    }
}

// MARK: - Her voice

/// Records 15 s of her voice so her own lines get labelled "Me" and dimmed.
struct VoiceRecorder: View {
    @Environment(AppModel.self) private var model
    var onFinish: () -> Void = {}
    @State private var secondsLeft = 15
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.recordingVoice {
                Text("Read this aloud in your normal interpreting voice:").font(.headline)
                Text("“Hello, I will be your interpreter today. Please speak in short sentences and pause so I can interpret everything you say. If anything is unclear, I will ask you to repeat it. The appointment is on Tuesday at ten thirty in the morning.”")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
                HStack(spacing: 10) {
                    LiveLevelMeter()
                    Text("\(secondsLeft) s left").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { stop(save: false) }
                }
            } else {
                HStack {
                    if model.hasMyVoice {
                        Label("Your voice is saved on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Forget", role: .destructive) { model.forgetMyVoice() }
                        Button("Record again") { start() }
                    } else {
                        Button("Start recording (15 seconds)") { start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.micAuthorized)
                    }
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            if model.recordingVoice { model.cancelVoiceRecording() }
        }
    }

    private func start() {
        secondsLeft = 15
        model.startVoiceRecording()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                secondsLeft -= 1
                if secondsLeft <= 0 { stop(save: true) }
            }
        }
    }

    private func stop(save: Bool) {
        timer?.invalidate()
        timer = nil
        guard model.recordingVoice else { return }
        if save { model.finishVoiceRecording(); onFinish() } else { model.cancelVoiceRecording() }
    }
}

struct VoiceSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Teach Earmark your voice").font(.title2.bold())
            Text("With a short sample of your voice, your own lines get labelled “Me” and dimmed, so the callers stand out. The sample is saved on this Mac only.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VoiceRecorder()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 540)
    }
}
