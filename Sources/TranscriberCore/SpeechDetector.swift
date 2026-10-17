import Foundation

/// Cheap energy-based voice activity check on 16 kHz mono audio.
///
/// Whisper hallucinates on silence ("Thank you.", subtitle credits, …). Rather than
/// sending silent clips to the model at all, we measure how much of the recording has
/// voice-level energy and skip transcription when there is essentially none.
public enum SpeechDetector {
    public static let sampleRate = 16_000
    static let frameLength = 480 // 30 ms

    public struct Analysis: Equatable {
        public var duration: Double
        /// Seconds of audio whose loudness is clearly above the background.
        public var speechSeconds: Double
        public var peakRMS: Float

        public var containsSpeech: Bool { speechSeconds >= 0.12 }
    }

    public static func analyze(_ samples: [Float]) -> Analysis {
        let duration = Double(samples.count) / Double(sampleRate)
        guard samples.count >= frameLength else {
            return Analysis(duration: duration, speechSeconds: 0, peakRMS: 0)
        }

        var frameRMS: [Float] = []
        frameRMS.reserveCapacity(samples.count / frameLength)
        samples.withUnsafeBufferPointer { buffer in
            var start = 0
            while start + frameLength <= buffer.count {
                var sum: Float = 0
                for i in start..<(start + frameLength) {
                    sum += buffer[i] * buffer[i]
                }
                frameRMS.append((sum / Float(frameLength)).squareRoot())
                start += frameLength
            }
        }

        // Noise floor = quiet end of the recording; speech must stand clearly above it
        // and above an absolute minimum (~ -48 dBFS) so hiss never counts as speech.
        let sorted = frameRMS.sorted()
        let noiseFloor = sorted[sorted.count / 10]
        let threshold = max(0.004, noiseFloor * 2)
        let speechFrames = frameRMS.filter { $0 > threshold }.count

        return Analysis(
            duration: duration,
            speechSeconds: Double(speechFrames * frameLength) / Double(sampleRate),
            peakRMS: sorted.last ?? 0
        )
    }
}
