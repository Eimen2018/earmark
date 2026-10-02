import AVFoundation

/// An audio input device as macOS sees it.
struct InputDevice: Identifiable, Hashable {
    let id: String      // AVCaptureDevice.uniqueID
    let name: String

    var isBoya: Bool { name.range(of: "boya|wireless|lav", options: [.regularExpression, .caseInsensitive]) != nil }
}

/// Lists microphones and reports when one is plugged in or removed.
enum AudioDevices {
    static func inputs() -> [InputDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices
            .map { InputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func defaultInput() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    /// Calls `onChange` on the main queue whenever a microphone is connected or disconnected.
    /// Keep the returned tokens alive for as long as you want updates.
    static func observeChanges(_ onChange: @escaping () -> Void) -> [NSObjectProtocol] {
        [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in onChange() }
        }
    }
}
