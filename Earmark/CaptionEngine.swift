import FluidAudio
import Foundation

/// What the engine reports back to the UI.
enum EngineEvent: Sendable {
    case status(String)
    /// One-time model download/compile progress, 0...1 (nil when the step has no measurable progress).
    case loading(step: String, fraction: Double?)
    case ready
    case failed(String)
    /// Words of the utterance still being spoken. Empty clears it.
    case partial(String)
    /// A finished utterance. `speaker` is a Sortformer slot (0-3) or nil if unsure.
    case line(id: UUID, text: String, speaker: Int?)
    /// A later, better guess at who said an earlier line.
    case speaker(lineID: UUID, speaker: Int?)
    /// Which slot her enrolled voice landed in (nil if enrollment found no speech).
    case enrolled(slot: Int?)
}

/// Runs everything on-device: Silero VAD cuts speech into utterances, Parakeet turns each one
/// into text, and Sortformer says which of up to four voices was talking.
actor CaptionEngine {
    private static let rate = 16_000
    private static let frameSeconds = 0.08            // Sortformer output frame
    private static let maxUtterance = 14 * rate       // Parakeet's window is ~15 s
    private static let partialEvery = rate            // refresh the live line every second
    private static let refineAfter = 2 * rate         // diarization firms up ~1 s behind live audio
    private static let historyLimit = 45 * rate

    private let emit: @Sendable (EngineEvent) -> Void

    private var asr: AsrManager?
    private var decoderLayers = 2
    private var vad: VadManager?
    private var diarizer: SortformerDiarizer?
    private let vadConfig = VadSegmentationConfig(
        minSpeechDuration: 0.25, minSilenceDuration: 0.6, maxSpeechDuration: 14, speechPadding: 0.2)

    private var vadState = VadStreamState.initial()
    private var pending: [Float] = []            // waiting to fill a VAD chunk
    private var history: [Float] = []            // recent audio, for cutting out utterances
    private var historyStart = 0                 // absolute sample index of history[0]
    private var total = 0                        // absolute samples since the session started
    private var utteranceStart: Int?
    private var lastPartialAt = 0
    private var refinements: [(id: UUID, from: Int, to: Int, due: Int, speaker: Int?)] = []
    private var myVoice: [Float]?
    private var debugPeakProb: Float = 0
    private var debugChunks = 0

    init(emit: @escaping @Sendable (EngineEvent) -> Void) {
        self.emit = emit
    }

    // MARK: - Setup

    func load() async {
        do {
            let emit = self.emit
            emit(.loading(step: "Speech recognition", fraction: nil))
            // English-only v2: best English accuracy.
            let models = try await AsrModels.downloadAndLoad(version: .v2) { emit(.loading(step: "Speech recognition", fraction: $0.fractionCompleted)) }
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            decoderLayers = models.version.decoderLayers

            emit(.loading(step: "Voice detection", fraction: nil))
            // FluidAudio defaults to 0.85; earpiece audio through a lav is quiet, so use Silero's usual 0.5.
            let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5)) { emit(.loading(step: "Voice detection", fraction: $0.fractionCompleted)) }

            emit(.loading(step: "Speaker separation", fraction: nil))
            var timeline = DiarizerTimelineConfig.sortformerDefault
            timeline.maxStoredFrames = 1_500   // ~2 min of history is plenty, and keeps 8-hour days flat on memory
            timeline.storeSegments = false     // we read frame probabilities directly
            let diarizer = SortformerDiarizer(config: .balancedV2_1, timelineConfig: timeline)
            diarizer.initialize(models: try await SortformerModels.loadFromHuggingFace(config: .balancedV2_1) {
                emit(.loading(step: "Speaker separation", fraction: $0.fractionCompleted))
            })

            self.asr = asr
            self.vad = vad
            self.diarizer = diarizer
            emit(.ready)
        } catch {
            emit(.failed("Couldn't load the speech models: \(error.localizedDescription)"))
        }
    }

    /// Start a fresh call: forget all audio and speaker slots, then re-enroll her voice if we have it.
    func newSession() {
        vadState = VadStreamState.initial()
        pending.removeAll()
        history.removeAll()
        historyStart = 0
        total = 0
        utteranceStart = nil
        lastPartialAt = 0
        refinements.removeAll()
        diarizer?.reset()
        enrollMyVoiceIfAny()
        emit(.partial(""))
    }

    /// Her voice, recorded once, so Sortformer can name her slot "Me". Kept in memory only.
    func setMyVoice(_ samples: [Float]?) {
        myVoice = samples
        newSession()
    }

    private func enrollMyVoiceIfAny() {
        guard let myVoice, let diarizer else { return }
        do {
            let speaker = try diarizer.enrollSpeaker(withAudio: myVoice, named: "Me")
            emit(.enrolled(slot: speaker?.index))
        } catch {
            emit(.enrolled(slot: nil))
        }
    }

    // MARK: - Streaming

    /// Feed 16 kHz mono samples in capture order.
    func feed(_ samples: [Float]) async {
        guard let vad, asr != nil else { log.error("feed before models are ready"); return }
        if total == 0 { log.info("engine receiving audio") }

        if let diarizer {
            diarizer.addAudio(samples)
            _ = try? diarizer.process()
        }

        history.append(contentsOf: samples)
        total += samples.count
        if history.count > Self.historyLimit {
            let drop = history.count - Self.historyLimit
            history.removeFirst(drop)
            historyStart += drop
        }

        pending.append(contentsOf: samples)
        while pending.count >= VadManager.chunkSize {
            let chunk = Array(pending.prefix(VadManager.chunkSize))
            pending.removeFirst(VadManager.chunkSize)
            let result: VadStreamResult
            do { result = try await vad.processStreamingChunk(chunk, state: vadState, config: vadConfig) }
            catch { log.error("vad failed: \(String(describing: error), privacy: .public)"); continue }
            vadState = result.state
            debugPeakProb = max(debugPeakProb, result.probability)
            debugChunks += 1
            if debugChunks % 12 == 0 {
                let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
                log.debug("vad peak prob \(self.debugPeakProb) last rms \(rms)")
                debugPeakProb = 0
            }
            guard let event = result.event else { continue }
            if event.isStart {
                log.debug("vad start at \(event.sampleIndex)")
                utteranceStart = event.sampleIndex
                lastPartialAt = total
            } else if event.isEnd, let start = utteranceStart {
                log.debug("vad end at \(event.sampleIndex)")
                utteranceStart = nil
                await finish(from: start, to: event.sampleIndex)
            }
        }

        // Long monologue with no pause: cut it so Parakeet stays inside its window.
        if let start = utteranceStart, total - start > Self.maxUtterance {
            utteranceStart = total
            lastPartialAt = total
            await finish(from: start, to: total)
        }

        if let start = utteranceStart, total - lastPartialAt >= Self.partialEvery, total - start >= Self.rate / 2 {
            lastPartialAt = total
            emit(.partial(await transcribe(from: start, to: total)))
        }

        refineSpeakers()
    }

    private func finish(from start: Int, to end: Int) async {
        let text = await transcribe(from: start, to: end)
        emit(.partial(""))
        guard !text.isEmpty else { return }
        let id = UUID()
        let speaker = dominantSpeaker(from: start, to: end)
        emit(.line(id: id, text: text, speaker: speaker))
        refinements.append((id, start, end, end + Self.refineAfter, speaker))
    }

    private func refineSpeakers() {
        guard !refinements.isEmpty else { return }
        refinements.removeAll { item in
            guard total >= item.due else { return false }
            let better = dominantSpeaker(from: item.from, to: item.to)
            if better != item.speaker { emit(.speaker(lineID: item.id, speaker: better)) }
            return true
        }
    }

    private func transcribe(from start: Int, to end: Int) async -> String {
        guard let asr else { return "" }
        let a = max(0, start - historyStart), b = min(history.count, end - historyStart)
        guard b - a >= Self.rate * 3 / 10 else { return "" }
        var samples = Array(history[a..<b])
        if samples.count < Self.rate { samples += [Float](repeating: 0, count: Self.rate - samples.count) }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result: ASRResult?
        do { result = try await asr.transcribe(samples, decoderState: &state) }
        catch { log.error("transcribe failed: \(String(describing: error), privacy: .public)"); result = nil }
        log.debug("transcribed \(samples.count) samples -> \(result?.text.count ?? -1) chars")
        return result?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The Sortformer slot with the most speech probability across this stretch of audio.
    private func dominantSpeaker(from start: Int, to end: Int) -> Int? {
        guard let diarizer else { return nil }
        let timeline = diarizer.timeline
        let slots = diarizer.numSpeakers ?? 4
        let f0 = Int(Double(start) / Double(Self.rate) / Self.frameSeconds)
        let f1 = max(f0 + 1, Int(Double(end) / Double(Self.rate) / Self.frameSeconds))
        var sums = [Float](repeating: 0, count: slots)
        var frames = 0
        for frame in f0..<f1 {
            var seen = false
            for slot in 0..<slots {
                var p = timeline.probability(speaker: slot, frame: frame)
                if p.isNaN { p = timeline.tentativeProbability(speaker: slot, frame: frame) }
                if !p.isNaN { sums[slot] += p; seen = true }
            }
            if seen { frames += 1 }
        }
        guard frames > 0, let best = sums.indices.max(by: { sums[$0] < sums[$1] }),
              sums[best] / Float(frames) > 0.2 else { return nil }
        return best
    }
}
