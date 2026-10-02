import SwiftUI

/// First-launch guide: what Earmark does, microphone, model download, her voice, and the few things worth knowing.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    var onDone: () -> Void
    @State private var step = 0
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: microphone
                case 2: models
                case 3: voice
                default: tips
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 44)
            .padding(.top, 40)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            Divider()
            HStack {
                HStack(spacing: 7) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == step ? 18 : 7, height: 7)
                    }
                }
                .animation(.spring(duration: 0.3), value: step)
                Spacer()
                if step > 0 {
                    Button("Back") { go(step - 1) }
                }
                Button(nextTitle) { step == steps - 1 ? onDone() : go(step + 1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 640, height: 540)
    }

    private var nextTitle: String {
        switch step {
        case 0: return "Get started"
        case 3: return model.hasMyVoice ? "Continue" : "Skip for now"
        case steps - 1: return "Start using Earmark"
        default: return "Continue"
        }
    }

    private var canContinue: Bool {
        switch step {
        case 1: return model.micAuthorized
        case 2: return model.isReady
        case 3: return !model.recordingVoice
        default: return true
        }
    }

    private func go(_ next: Int) {
        withAnimation(.spring(duration: 0.35)) { step = next }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Earmark").font(.system(size: 34, weight: .bold))
                    Text("Live captions for interpreters").font(.title3).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Feature(icon: "captions.bubble", title: "Captions as they talk",
                        text: "Every word on the call appears in large, easy-to-read text.")
                Feature(icon: "highlighter", title: "Catches what you have to say back",
                        text: "Phone numbers, addresses, dates and IDs are highlighted and kept in a list. One click copies them.")
                Feature(icon: "person.2.wave.2", title: "Knows who is speaking",
                        text: "Each voice gets its own label, so you can tell the caller from yourself.")
                Feature(icon: "lock.shield", title: "Private by design",
                        text: "Everything runs on this Mac. No audio or text ever leaves it, and nothing is saved.")
            }
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Your microphone",
                       text: "Clip the mic to your headset's ear pad. It hears the caller through the earpiece and you as you speak.")
            if !model.micAuthorized {
                if model.micDenied {
                    Label("Microphone access is turned off for Earmark.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Privacy Settings") { model.openMicrophoneSettings() }
                    Text("Turn on Earmark under Microphone, then quit and reopen Earmark.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Allow microphone") { Task { await model.requestMicrophone() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Microphone", selection: Binding(get: { model.deviceID ?? "" }, set: { model.pickDevice($0) })) {
                        ForEach(model.devices) { Text($0.name).tag($0.id) }
                    }
                    .frame(maxWidth: 360)
                    HStack(spacing: 12) {
                        LiveLevelMeter().frame(width: 200)
                        Text(model.noSound ? "No sound. Is the transmitter on and paired (solid blue light)?" : "Say something. The bar should move.")
                            .foregroundStyle(model.noSound ? .orange : .secondary)
                    }
                    if model.devices.contains(where: \.isBoya) {
                        Label("Wireless mic found and selected.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.6)))
            }
            Spacer()
            Text("Swapping transmitters for battery? Captions pause while there's no sound and carry on by themselves.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Speech models",
                       text: "Earmark downloads its speech models once (about 600 MB). After that it works without the internet, and nothing you hear is ever uploaded.")
            VStack(alignment: .leading, spacing: 10) {
                if model.isReady {
                    Label("All set. Models are on this Mac.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                } else {
                    Text(model.loadingStep).font(.headline)
                    if let fraction = model.loadingFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(model.isError ? model.status : "This usually takes a minute or two.")
                        .font(.callout)
                        .foregroundStyle(model.isError ? .red : .secondary)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.6)))
        }
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Teach Earmark your voice",
                       text: "Optional, but it helps: your own lines get labelled “Me” and dimmed, so the callers stand out. The sample is saved on this Mac only, and you can redo or delete it any time.")
            VoiceRecorder()
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Good to know", text: "A few things that make calls easier.")
            VStack(alignment: .leading, spacing: 14) {
                Tip(key: "Space", text: "Start or pause captions.")
                Tip(key: "Click", text: "Click a highlighted number or address to copy it. Everything highlighted also collects under Kept.")
                Tip(key: "K", text: "Keep the last line in the Kept list.")
                Tip(key: "N", text: "Write a note. Esc takes you back to the captions. Right-click a line to add it to your notes.")
                Tip(key: "Speakers", text: "Click a speaker's name to rename them, dim or hide their lines, or merge two labels that are really the same person.")
                Tip(key: "New call", text: "Clears captions, notes, kept details and speaker names. Nothing is stored after you close the app.")
            }
        }
    }
}

private struct StepHeader: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 26, weight: .bold))
            Text(text).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Feature: View {
    let icon: String
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Tip: View {
    let key: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(key)
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.5)))
                .frame(width: 90, alignment: .leading)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
