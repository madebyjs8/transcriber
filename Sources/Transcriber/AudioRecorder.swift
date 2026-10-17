import AVFoundation
import Accelerate
import ObjCSafety

/// Captures microphone audio as 16 kHz mono Float32, the format Whisper expects.
///
/// Uses an AVCaptureSession bound to an explicit device. (AVAudioEngine can't reliably record
/// from anything but the system default input: forcing it onto the built-in mic while AirPods
/// are the default stalls the stream or throws on a stale format.) The capture output delivers
/// 16 kHz mono floats directly, so no conversion is needed.
///
/// Start/stop run on a private serial queue so the UI never waits on the microphone and
/// requests are processed in order. A fresh session per recording picks up device changes
/// and leaves nothing running while idle.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum RecorderError: LocalizedError {
        case noInputDevice
        case audioSystem(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone available"
            case .audioSystem: return "Microphone couldn't start"
            }
        }
    }

    static let sampleRate: Double = 16_000

    /// Called on the main thread roughly 20× per second with the current RMS level.
    var onLevel: ((Float) -> Void)?

    /// Diagnostics for the last start (shown by `--test-mic`).
    private(set) var lastStartInfo = ""
    private(set) var firstBufferDelay: Double = -1

    private let queue = DispatchQueue(label: "Transcriber.audio", qos: .userInteractive)
    private let sampleQueue = DispatchQueue(label: "Transcriber.audio.samples", qos: .userInteractive)
    private var session: AVCaptureSession?

    // Written on `sampleQueue`, read on `queue`.
    private let bufferLock = NSLock()
    private var samples: [Float] = []
    private var lastLevelReport: CFAbsoluteTime = 0
    private var startedAt: CFAbsoluteTime = 0

    /// Starts capturing. `completion` runs on the main thread.
    func start(deviceUID: String?, completion: @escaping (Error?) -> Void) {
        queue.async {
            var failure: Error?
            do {
                try self.startSession(deviceUID: deviceUID)
            } catch where deviceUID != "system" {
                // The chosen mic misbehaved: fall back to the system default instead of failing.
                self.teardown()
                do {
                    try self.startSession(deviceUID: "system")
                } catch {
                    self.teardown()
                    failure = error
                }
            } catch {
                self.teardown()
                failure = error
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    /// Keeps recording for `tail` seconds (so the last syllable isn't clipped), then stops
    /// and hands back everything captured. `completion` runs on the main thread.
    func stop(tail: TimeInterval = 0, completion: @escaping ([Float]) -> Void) {
        queue.async {
            if tail > 0, self.session != nil { Thread.sleep(forTimeInterval: tail) }
            self.teardown()
            let captured = self.takeSamples()
            DispatchQueue.main.async { completion(captured) }
        }
    }

    /// Stops and throws the audio away.
    func discard() {
        queue.async {
            self.teardown()
            _ = self.takeSamples()
        }
    }

    /// A copy of the most recent audio, for the live text preview. Recording continues.
    func snapshot(lastSeconds: Double) -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let count = min(samples.count, Int(lastSeconds * Self.sampleRate))
        return Array(samples.suffix(count))
    }

    /// Drops what has been captured so far but keeps recording.
    func resetBuffer() {
        bufferLock.lock()
        samples.removeAll(keepingCapacity: true)
        bufferLock.unlock()
    }

    // MARK: - Session (runs on `queue`)

    private func startSession(deviceUID: String?) throws {
        teardown()
        _ = takeSamples()

        // "" = automatic (avoid Bluetooth mics), "system" = always the system default.
        let device: AVCaptureDevice?
        switch deviceUID ?? "" {
        case "":
            device = AudioDevices.automaticInputDeviceUID().flatMap(AVCaptureDevice.init(uniqueID:))
                ?? AVCaptureDevice.default(for: .audio)
        case "system":
            device = AVCaptureDevice.default(for: .audio)
        case let uid:
            device = AVCaptureDevice(uniqueID: uid) ?? AVCaptureDevice.default(for: .audio)
        }
        guard let device else { throw RecorderError.noInputDevice }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw RecorderError.audioSystem("Cannot record from \(device.localizedName)")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        bufferLock.lock()
        samples.reserveCapacity(Int(Self.sampleRate) * 30)
        bufferLock.unlock()
        firstBufferDelay = -1
        startedAt = CFAbsoluteTimeGetCurrent()
        lastStartInfo = "device=\(device.localizedName)"

        self.session = session // so teardown() cleans up even after a failure
        if let exception = TRCatchObjCException({ session.startRunning() }) {
            throw RecorderError.audioSystem(exception)
        }
    }

    private func teardown() {
        guard let session else { return }
        _ = TRCatchObjCException { session.stopRunning() }
        sampleQueue.sync {} // let buffers already in flight land before samples are taken
        self.session = nil
    }

    private func takeSamples() -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let captured = samples
        samples = []
        return captured
    }

    // MARK: - Sample delivery (on `sampleQueue`)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        guard count > 0 else { return }

        var chunk = [Float](repeating: 0, count: count)
        let status = chunk.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: $0.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }

        if firstBufferDelay < 0 {
            firstBufferDelay = CFAbsoluteTimeGetCurrent() - startedAt
            if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                lastStartInfo += " format=\(Int(asbd.mSampleRate))Hz/\(asbd.mChannelsPerFrame)ch/\(asbd.mBitsPerChannel)bit"
            }
        }

        bufferLock.lock()
        samples.append(contentsOf: chunk)
        bufferLock.unlock()

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelReport > 0.045, let onLevel {
            lastLevelReport = now
            var rms: Float = 0
            vDSP_rmsqv(chunk, 1, &rms, vDSP_Length(count))
            DispatchQueue.main.async { onLevel(rms) }
        }
    }
}
