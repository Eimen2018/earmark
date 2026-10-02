import AVFoundation
import CoreMedia

enum CaptureError: LocalizedError {
    case noDevice
    case cannotUse(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "No microphone found."
        case .cannotUse(let name): return "\(name) can't be opened. Pick another microphone."
        }
    }
}

/// Captures one microphone and hands out 16 kHz mono Float32 samples, the format FluidAudio expects.
/// AVCaptureSession picks devices by ID and resamples for us; AVAudioEngine fights both on macOS.
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// 16 kHz mono samples. Called on the capture queue.
    var onSamples: (([Float]) -> Void)?
    /// RMS level and whether the buffer was exact digital silence. Called on the capture queue.
    var onLevel: ((Float, Bool) -> Void)?
    /// The device stopped (unplugged, or the session hit an error). Called on the main queue.
    var onInterrupted: (() -> Void)?

    private(set) var deviceID: String?
    private var session: AVCaptureSession?
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "capture.audio", qos: .userInteractive)

    func start(device id: String?) throws {
        stop()
        guard let device = id.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.noDevice
        }
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw CaptureError.cannotUse(device.localizedName)
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Both Boya channels get mixed down, and macOS resamples to what the models want.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotUse(device.localizedName) }
        session.addOutput(output)

        observers = [
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
                self?.onInterrupted?()
            },
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in
                self?.onInterrupted?()
            },
        ]
        log.info("capture starting on \(device.localizedName, privacy: .public)")
        session.startRunning()
        self.session = session
        deviceID = device.uniqueID
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        session?.stopRunning()
        session = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let bytes = CMBlockBufferGetDataLength(block)
        let count = bytes / MemoryLayout<Float>.size
        guard count > 0 else { return }
        var samples = [Float](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }

        var peak: Float = 0, sumSquares: Float = 0
        for s in samples {
            peak = max(peak, abs(s))
            sumSquares += s * s
        }
        onLevel?((sumSquares / Float(count)).squareRoot(), peak == 0)
        onSamples?(samples)
    }
}
