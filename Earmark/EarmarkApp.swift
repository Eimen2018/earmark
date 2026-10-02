import SwiftUI

@main
struct EarmarkApp: App {
    @State private var model = AppModel()
    @AppStorage("onboarded") private var onboarded = false

    var body: some Scene {
        Window("Earmark", id: "main") {
            ContentView()
                .environment(model)
                .onKeyPress("k") {
                    model.keepLastLine()
                    return .handled
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Captions") {
                Button(model.isListening ? "Pause Captions" : "Start Captions") { model.toggleListening() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isReady)
                Button("Keep Last Line") { model.keepLastLine() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("New Call") { model.newCall() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Welcome Guide") { onboarded = false }
                Link("Earmark on GitHub", destination: URL(string: "https://github.com/Eimen2018/earmark")!)
            }
        }
    }
}
