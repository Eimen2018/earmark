import AppKit
import AVFoundation
import SwiftUI
import os

let log = Logger(subsystem: "com.aymen.Earmark", category: "app")

struct CaptionLine: Identifiable {
    let id: UUID
    let text: String
    var speaker: Int?
    let details: [Detail]
}

struct KeptItem: Identifiable {
    let id = UUID()
    let kind: String
    let value: String
}

enum SpeakerVisibility: String, CaseIterable {
    case show = "Show", dim = "Dim", hide = "Hide"
}

struct SpeakerInfo {
    var name: String
    var visibility: SpeakerVisibility = .show
}

/// Routes captured audio either to her voice recording or to the caption engine.
/// Touched from the audio thread, hence the lock.
private final class SampleRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var recording: [Float]?
    private var listening = false
    private let continuation: AsyncStream<[Float]>.Continuation

    init(_ continuation: AsyncStream<[Float]>.Continuation) { self.continuation = continuation }

    func route(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        if recording != nil { recording!.append(contentsOf: samples); return }
        if listening { continuation.yield(samples) }
    }

    func setListening(_ on: Bool) { lock.withLock { listening = on } }
    func startRecording() { lock.withLock { recording = [] } }
    func stopRecording() -> [Float] { lock.withLock { defer { recording = nil }; return recording ?? [] } }
}

/// Her voice sample, kept on this Mac only so she records it once.
private enum VoiceStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Earmark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("my-voice.f32")
    }

    static func load() -> [Float]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func save(_ samples: [Float]) {
        try? samples.withUnsafeBytes { Data($0) }.write(to: url, options: .atomic)
    }

    static func delete() { try? FileManager.default.removeItem(at: url) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Starting…"
    @Published var isError = false
    @Published var isReady = false
    @Published var loadingStep = "Preparing"
    @Published var loadingFraction: Double?
    @Published var isListening = false
    @Published var micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var micDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    @Published var level: Float = 0
    @Published var noSound = false
    @Published var devices: [InputDevice] = []
    @Published var deviceID: String?
    @Published var lines: [CaptionLine] = []
    @Published var partial = ""
    @Published var kept: [KeptItem] = []
    @Published var speakers: [Int: SpeakerInfo] = [:]
    /// Slots Sortformer split off the same person, folded into another slot. Per call.
    @Published var mergedInto: [Int: Int] = [:]
    @Published var mySlot: Int?
    @Published var hasMyVoice = false
    @Published var recordingVoice = false
    @Published var fontSize: CGFloat = 26

    private let engine: CaptionEngine
    private let capture = AudioCapture()
    private let router: SampleRouter
    private var userPickedDevice = false
    private var deviceObservers: [NSObjectProtocol] = []
    private var silentSince: Date?
    private var lastLevelPush = Date.distantPast

    init() {
        let (events, eventSink) = AsyncStream.makeStream(of: EngineEvent.self)
        let (audio, audioSink) = AsyncStream.makeStream(of: [Float].self)
        engine = CaptionEngine { eventSink.yield($0) }
        router = SampleRouter(audioSink)

        // Events and audio each flow through one ordered stream.
        Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        Task { [engine] in
            for await chunk in audio { await engine.feed(chunk) }
        }
        Task { [engine] in
            await engine.load()
            if let voice = VoiceStore.load() { await engine.setMyVoice(voice) }
        }
        hasMyVoice = FileManager.default.fileExists(atPath: VoiceStore.url.path)

        capture.onSamples = { [router] in router.route($0) }
        capture.onLevel = { [weak self] rms, silent in
            DispatchQueue.main.async { self?.updateLevel(rms, silent: silent) }
        }
        capture.onInterrupted = { [weak self] in self?.restartCapture() }
        deviceObservers = AudioDevices.observeChanges { [weak self] in self?.devicesChanged() }
        // Before onboarding has asked, don't pop the permission prompt at launch.
        if micAuthorized { startMicrophone() }
    }

    // MARK: - Microphone

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        micAuthorized = granted
        micDenied = !granted
        if granted { startMicrophone() }
        else { setError("Microphone access is off. Turn on Earmark in System Settings › Privacy & Security › Microphone.") }
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    private func startMicrophone() {
        devices = AudioDevices.inputs()
        startCapture(devices.first(where: \.isBoya)?.id ?? AudioDevices.defaultInput())
    }

    func pickDevice(_ id: String) {
        userPickedDevice = true
        startCapture(id)
    }

    private func startCapture(_ id: String?) {
        do {
            try capture.start(device: id)
            deviceID = capture.deviceID
            silentSince = nil
        } catch {
            log.error("capture start failed for device \(id ?? "default", privacy: .public): \(String(describing: error), privacy: .public)")
            setError(error.localizedDescription)
        }
    }

    private func restartCapture() {
        guard micAuthorized else { return }
        let current = deviceID
        devices = AudioDevices.inputs()
        startCapture(devices.contains(where: { $0.id == current }) ? current : AudioDevices.defaultInput())
    }

    private func devicesChanged() {
        devices = AudioDevices.inputs()
        guard micAuthorized else { return }
        if let id = deviceID, !devices.contains(where: { $0.id == id }) {
            // The receiver was unplugged: keep captioning on whatever is left.
            startCapture(devices.first(where: \.isBoya)?.id ?? AudioDevices.defaultInput())
        } else if !userPickedDevice, let boya = devices.first(where: \.isBoya), boya.id != deviceID {
            startCapture(boya.id)
        }
    }

    private func updateLevel(_ rms: Float, silent: Bool) {
        let now = Date()
        // Exact zeros mean the receiver has no transmitter: off, unpaired, or mid battery swap.
        if silent { silentSince = silentSince ?? now } else { silentSince = nil }
        let shouldWarn = silentSince.map { now.timeIntervalSince($0) > 4 } ?? false
        if shouldWarn != noSound { noSound = shouldWarn }
        if now.timeIntervalSince(lastLevelPush) > 0.06 {
            lastLevelPush = now
            level = rms
        }
    }

    var deviceName: String {
        devices.first(where: { $0.id == deviceID })?.name ?? "the microphone"
    }

    // MARK: - Captions

    func toggleListening() {
        guard isReady, micAuthorized else { return }
        isListening.toggle()
        router.setListening(isListening)
        setStatus(isListening ? "Listening" : "Paused")
    }

    func newCall() {
        lines.removeAll()
        kept.removeAll()
        partial = ""
        mergedInto.removeAll()
        speakers = speakers.filter { $0.key == mySlot }
        Task { await engine.newSession() }
    }

    // MARK: - Her voice

    func startVoiceRecording() {
        router.startRecording()
        recordingVoice = true
    }

    func finishVoiceRecording() {
        let samples = router.stopRecording()
        recordingVoice = false
        guard samples.count > 16_000 * 5 else { return }
        VoiceStore.save(samples)
        hasMyVoice = true
        Task { await engine.setMyVoice(samples) }
    }

    func cancelVoiceRecording() {
        _ = router.stopRecording()
        recordingVoice = false
    }

    func forgetMyVoice() {
        VoiceStore.delete()
        hasMyVoice = false
        if let mySlot { speakers[mySlot] = nil }
        mySlot = nil
        Task { await engine.setMyVoice(nil) }
    }

    // MARK: - Speakers

    /// Follows merges to the slot a line should be shown under.
    func canonical(_ slot: Int?) -> Int? {
        var current = slot
        var hops = 0
        while let s = current, let next = mergedInto[s], hops < 8 { current = next; hops += 1 }
        return current
    }

    func info(for slot: Int?) -> SpeakerInfo? {
        guard let slot = canonical(slot) else { return nil }
        return speakers[slot] ?? SpeakerInfo(name: "Speaker \(slot + 1)")
    }

    func rename(_ slot: Int, to name: String) {
        let slot = canonical(slot) ?? slot
        speakers[slot, default: SpeakerInfo(name: name)].name = name
    }

    func setVisibility(_ slot: Int, _ visibility: SpeakerVisibility) {
        let slot = canonical(slot) ?? slot
        speakers[slot, default: SpeakerInfo(name: "Speaker \(slot + 1)")].visibility = visibility
    }

    /// "These two are the same person": everything from `slot`, past and future, shows as `target`.
    func merge(_ slot: Int, into target: Int) {
        guard let target = canonical(target), slot != target else { return }
        mergedInto[slot] = target
        // Anything already merged into `slot` follows it.
        for (key, value) in mergedInto where value == slot { mergedInto[key] = target }
        if slot == mySlot { mySlot = target }
    }

    func separate(_ slot: Int) {
        mergedInto[slot] = nil
    }

    /// Slots that currently have their own chip (merged ones fold into their target).
    var seenSlots: [Int] {
        Set(lines.compactMap { canonical($0.speaker) }).union(speakers.keys.compactMap(canonical)).sorted()
    }

    /// Slots folded into `slot`, for the "Separate again" menu.
    func mergedSlots(into slot: Int) -> [Int] {
        mergedInto.keys.filter { canonical($0) == slot }.sorted()
    }

    // MARK: - Kept

    func keep(_ kind: String, _ value: String, announce: Bool) {
        let norm = value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !norm.isEmpty else { return }
        if let at = kept.firstIndex(where: { $0.value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") == norm }) {
            guard announce else { return }
            kept.remove(at: at)
        }
        kept.insert(KeptItem(kind: kind, value: value), at: 0)
    }

    func keepLastLine() {
        guard let last = lines.last(where: { info(for: $0.speaker)?.visibility != .hide }) else { return }
        keep("Line", last.text, announce: true)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Engine events

    private func handle(_ event: EngineEvent) {
        switch event {
        case .status(let text):
            setStatus(text)
        case .loading(let step, let fraction):
            loadingStep = step
            loadingFraction = fraction
            let percent = fraction.map { " \(Int($0 * 100))%" } ?? ""
            status = "Getting ready: \(step.lowercased())\(percent)…" // frequent: skip the log
            isError = false
        case .ready:
            isReady = true
            loadingFraction = 1
            setStatus("Ready. Press Start captions.")
        case .failed(let message):
            setError(message)
        case .partial(let text):
            partial = text
        case .line(let id, let text, let speaker):
            let details = DetailFinder.find(in: text)
            lines.append(CaptionLine(id: id, text: text, speaker: speaker, details: details))
            for detail in details { keep(detail.kind, String(text[detail.range]), announce: false) }
        case .speaker(let id, let speaker):
            if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].speaker = speaker }
        case .enrolled(let slot):
            if let old = mySlot, old != slot { speakers[old] = nil }
            mySlot = slot
            if let slot { speakers[slot] = SpeakerInfo(name: "Me", visibility: .dim) }
            else if hasMyVoice { setError("Couldn't hear speech in your voice sample. Record it again from Teach my voice.") }
        }
    }

    private func setStatus(_ text: String) { log.info("status: \(text, privacy: .public)"); status = text; isError = false }
    private func setError(_ text: String) { log.error("error: \(text, privacy: .public)"); status = text; isError = true }
}
