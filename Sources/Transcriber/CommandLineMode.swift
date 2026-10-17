import AVFoundation
import Cocoa
import TranscriberCore

/// Headless mode for testing and benchmarking the transcription pipeline:
///
///     Transcriber --transcribe recording.wav [--model <id|path>] [--language en]
///                 [--prompt "…" | --no-prompt] [--repeat 3] [--accurate]
enum CommandLineMode {
    static func runIfRequested() -> Int32? {
        let args = CommandLine.arguments
        if args.contains("--test-mic") { return testMicrophone() }
        if args.contains("--test-paste-target") { return testPasteTarget() }
        guard let index = args.firstIndex(of: "--transcribe"), index + 1 < args.count else { return nil }

        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        let audioPath = args[index + 1]
        let models = ModelManager()
        let modelArgument = value("--model") ?? Prefs.modelID
        let modelPath: String
        if FileManager.default.fileExists(atPath: modelArgument) {
            modelPath = modelArgument
        } else if let model = models.activeModel(preferred: modelArgument) {
            modelPath = models.path(for: model)
        } else {
            fputs("No model found. Download one in the app or pass --model /path/to/ggml-model.bin\n", stderr)
            return 1
        }

        let samples: [Float]
        do {
            samples = try loadAudio(audioPath)
        } catch {
            fputs("Could not read \(audioPath): \(error.localizedDescription)\n", stderr)
            return 1
        }

        let prompt = args.contains("--no-prompt") ? "" : (value("--prompt") ?? Prefs.prompt)
        let options = WhisperEngine.Options(language: value("--language") ?? Prefs.language,
                                            autoLanguages: value("--auto-languages")?.components(separatedBy: ",") ?? Prefs.autoLanguages,
                                            prompt: prompt,
                                            accurate: args.contains("--accurate"),
                                            audioContext: Int(value("--audio-ctx") ?? "0") ?? 0,
                                            contextMargin: Int(value("--ctx-margin") ?? "32") ?? 32)
        let repeats = max(1, Int(value("--repeat") ?? "1") ?? 1)
        if let window = value("--simulate-live").flatMap(Double.init) {
            // Mimics the live preview: every 0.5 s of "speech", transcribe the last `window` seconds.
            let engine = WhisperEngine()
            try? engine.loadSync(modelPath: modelPath)
            var position = 1.0
            while position <= Double(samples.count) / AudioRecorder.sampleRate {
                let end = Int(position * AudioRecorder.sampleRate)
                let start = max(0, end - Int(window * AudioRecorder.sampleRate))
                if let t = try? engine.transcribeSync(Array(samples[start..<end]), modelPath: modelPath, options: options) {
                    print(String(format: "at %4.1fs: %4.0f ms | %@", position, t.elapsed * 1000,
                                 String(t.text.trimmingCharacters(in: .whitespaces).suffix(60))))
                }
                position += 3
            }
            return 0
        }
        let engine = WhisperEngine(verbose: args.contains("--verbose"))
        let analysis = SpeechDetector.analyze(samples)

        print("model:   \((modelPath as NSString).lastPathComponent)")
        print(String(format: "audio:   %.2f s (speech %.2f s)", analysis.duration, analysis.speechSeconds))
        do {
            let loadStart = CFAbsoluteTimeGetCurrent()
            let semaphore = DispatchSemaphore(value: 0)
            var loadResult: Result<TimeInterval, Error> = .success(0)
            DispatchQueue.global().async {
                loadResult = Result { try engine.loadSync(modelPath: modelPath) }
                    .map { CFAbsoluteTimeGetCurrent() - loadStart }
                semaphore.signal()
            }
            semaphore.wait()
            print(String(format: "load:    %.0f ms (incl. GPU warm-up)", try loadResult.get() * 1000))

            var transcript = WhisperEngine.Transcript(text: "", audioSeconds: 0, elapsed: 0)
            for run in 1...repeats {
                transcript = try engine.transcribeSync(samples, modelPath: modelPath, options: options)
                print(String(format: "run %d:   %.0f ms", run, transcript.elapsed * 1000))
            }
            let cleaned = TextProcessor(options: Prefs.textOptions)
                .process(transcript.text, speechSeconds: analysis.speechSeconds, prompt: prompt)
            print("raw:     \(transcript.text.trimmingCharacters(in: .whitespaces))")
            print("cleaned: \(cleaned)")
            return 0
        } catch {
            fputs("Transcription failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    /// Switches to Finder and checks that the dictation's original app is brought back.
    private static func testPasteTarget() -> Int32 {
        _ = NSApplication.shared
        let front = { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }
        guard let target = PasteTarget.current() else { print("no target"); return 1 }
        print("started in: \(target.app.localizedName ?? "?") (text field known: \(target.element != nil))")
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        print("switched to: \(front())")
        var done = false
        target.restore { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print("restored to: \(front())")
        return front() == target.app.localizedName ? 0 : 1
    }

    /// Starts the microphone the way a dictation does (same device choice) for 1.5 s.
    private static func testMicrophone() -> Int32 {
        let recorder = AudioRecorder()
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        DispatchQueue.global().async {
            recorder.start(deviceUID: Prefs.inputDeviceUID) { error in failure = error }
            Thread.sleep(forTimeInterval: 3)
            recorder.stop { samples in
                let analysis = SpeechDetector.analyze(samples)
                print(String(format: "captured %.2f s, first audio after %.0f ms | %@", analysis.duration,
                             recorder.firstBufferDelay * 1000, recorder.lastStartInfo))
                done.signal()
            }
        }
        // Completions are delivered on the main queue, so keep it running while we wait.
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let failure { print("microphone error: \(failure.localizedDescription)"); return 1 }
        return 0
    }

    /// Reads any audio file Core Audio understands and converts it to 16 kHz mono.
    private static func loadAudio(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                   channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioRecorder.RecorderError.audioSystem("Unsupported audio file")
        }
        try file.read(into: input)
        converter.downmix = true

        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioRecorder.RecorderError.audioSystem("Unsupported audio file")
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
