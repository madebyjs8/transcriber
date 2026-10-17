import CWhisper
import Foundation
import os

/// Thin wrapper around whisper.cpp. Every call runs on one serial queue because a
/// whisper context is not thread-safe; completions are delivered on the main thread.
final class WhisperEngine {
    struct Options {
        var language = "auto"
        /// With `language == "auto"`, detection only chooses among these (empty = any language).
        var autoLanguages: [String] = []
        var prompt = ""
        /// Beam search: a little slower, a little more accurate.
        var accurate = false
        /// Encoder context in 20 ms frames: 0 sizes it to the clip, -1 always uses the full 30 s.
        var audioContext = 0
        /// Silence (in 20 ms frames) the sized window leaves after the clip.
        var contextMargin = 32
        /// Live preview: single pass, no retries. A garbled preview is simply replaced by the
        /// next one, whereas a retry can take seconds.
        var preview = false
    }

    /// Whisper always encodes a 30 s window, even for a two-second dictation, and the encoder is
    /// ~85% of the latency. Shrinking the window to fit the clip makes short dictations 3–5×
    /// faster with the same output. Two limits, both found by testing:
    ///  - below ~256 frames (5 s) the model becomes unreliable, so that is the floor;
    ///  - Metal flash attention mis-computes shortened windows, so it is disabled (see load).
    /// Clips near or over 30 s use the full window and whisper's normal long-form decoding.
    static func audioContext(forSampleCount count: Int, margin: Int) -> Int32 {
        let fullWindow = 1500
        let frames = Int((Double(count) / AudioRecorder.sampleRate * 50).rounded(.up))
        let sized = (frames + margin + 31) / 32 * 32
        guard sized < fullWindow - 100 else { return 0 }
        return Int32(max(256, sized))
    }

    struct Transcript {
        var text: String
        /// The language Whisper decoded with (detected when "auto").
        var language = "auto"
        var audioSeconds: Double
        var elapsed: TimeInterval
    }

    enum EngineError: LocalizedError {
        case loadFailed(String)
        case transcriptionFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .loadFailed(let name): return "Could not load model \(name)"
            case .transcriptionFailed(let code): return "Transcription failed (\(code))"
            }
        }
    }

    private let queue = DispatchQueue(label: "Transcriber.whisper", qos: .userInitiated)
    private let log = Logger(subsystem: "Transcriber", category: "whisper")
    private var context: OpaquePointer?
    private var loadedPath: String?

    /// Performance cores only: efficiency cores slow whisper's CPU-side work down.
    private let threadCount: Int32 = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
            cores = Int32(ProcessInfo.processInfo.activeProcessorCount / 2)
        }
        return max(2, min(cores, 8))
    }()

    private let verbose: Bool

    init(verbose: Bool = false) {
        self.verbose = verbose
        if !verbose {
            whisper_log_set({ level, text, _ in
                guard let text, level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue else { return }
                fputs(text, stderr)
            }, nil)
        }
    }

    deinit {
        if let context { whisper_free(context) }
    }

    /// Loads (if needed) and warms up the model in the background.
    func preload(modelPath: String, completion: ((Result<TimeInterval, Error>) -> Void)? = nil) {
        queue.async {
            let start = CFAbsoluteTimeGetCurrent()
            let result = Result { try self.loadIfNeeded(modelPath) }.map { CFAbsoluteTimeGetCurrent() - start }
            if let completion { DispatchQueue.main.async { completion(result) } }
        }
    }

    func unload(completion: (() -> Void)? = nil) {
        queue.async {
            if let context = self.context {
                whisper_free(context)
                self.log.info("Model unloaded")
            }
            self.context = nil
            self.loadedPath = nil
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    func transcribe(_ samples: [Float], modelPath: String, options: Options,
                    completion: @escaping (Result<Transcript, Error>) -> Void) {
        queue.async {
            let result = Result { try self.transcribeSync(samples, modelPath: modelPath, options: options) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Loads and warms up the model synchronously (command-line mode).
    func loadSync(modelPath: String) throws {
        try loadIfNeeded(modelPath)
    }

    /// Blocking variant for the command-line mode. Must not be called on the main thread
    /// while the app UI is running.
    func transcribeSync(_ samples: [Float], modelPath: String, options: Options) throws -> Transcript {
        try loadIfNeeded(modelPath)
        guard let context else { throw EngineError.loadFailed(modelPath) }

        let start = CFAbsoluteTimeGetCurrent()
        let audioSeconds = Double(samples.count) / AudioRecorder.sampleRate

        // whisper.cpp ignores clips under 100 ms and is steadier with a little trailing silence.
        var audio = samples
        let minimum = Int(AudioRecorder.sampleRate)
        if audio.count < minimum { audio += [Float](repeating: 0, count: minimum - audio.count) }

        var params = whisper_full_default_params(options.accurate ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.n_threads = threadCount
        params.translate = false
        params.no_context = true          // never leak text from a previous dictation into this one
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.detect_language = false
        // Long dictations are decoded in 30 s windows; repeat the vocabulary for each one,
        // not just the first (otherwise "Claude Code" turns into "Cloud Code" after 30 s).
        params.carry_initial_prompt = true
        if options.accurate {
            params.beam_search.beam_size = 5
        }
        if options.preview {
            params.temperature_inc = 0
            params.no_timestamps = true
            params.single_segment = true
        }
        switch options.audioContext {
        case 0: params.audio_ctx = Self.audioContext(forSampleCount: audio.count, margin: options.contextMargin)
        case let frames where frames > 0: params.audio_ctx = Int32(frames)
        default: params.audio_ctx = 0
        }

        let language = resolveLanguage(options, context: context, audio: audio)

        let status: Int32 = language.withCString { language in
            options.prompt.withCString { prompt in
                params.language = language
                params.initial_prompt = options.prompt.isEmpty ? nil : prompt
                return audio.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        guard status == 0 else { throw EngineError.transcriptionFailed(status) }
        if verbose {
            whisper_print_timings(context)
            whisper_reset_timings(context)
        }

        var text = ""
        for index in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, index) {
                text += String(cString: segment)
            }
        }

        let detected = whisper_full_lang_id(context)
        let decodedLanguage = detected >= 0 ? String(cString: whisper_lang_str(detected)) : language
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        log.info("Transcribed \(audioSeconds, format: .fixed(precision: 1))s of audio in \(Int(elapsed * 1000))ms")
        return Transcript(text: text, language: decodedLanguage, audioSeconds: audioSeconds, elapsed: elapsed)
    }

    /// Picks the language to decode with. English-only models skip detection entirely (they
    /// have no language token). For "auto" with several candidate languages, detection is
    /// limited to those so a short German phrase isn't mistaken for Dutch.
    private func resolveLanguage(_ options: Options, context: OpaquePointer, audio: [Float]) -> String {
        guard whisper_is_multilingual(context) != 0 else { return "en" }
        guard options.language == "auto" else { return options.language }

        let candidates = options.autoLanguages.filter { whisper_lang_id($0) >= 0 }
        guard candidates.count > 1 else { return "auto" } // whisper's own detection, any language

        let melStatus = audio.withUnsafeBufferPointer {
            whisper_pcm_to_mel(context, $0.baseAddress, Int32($0.count), threadCount)
        }
        var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        guard melStatus == 0, whisper_lang_auto_detect(context, 0, threadCount, &probabilities) >= 0 else {
            return "auto"
        }
        let best = candidates.max { probabilities[Int(whisper_lang_id($0))] < probabilities[Int(whisper_lang_id($1))] }
        return best ?? "auto"
    }

    // MARK: - Loading (on `queue`)

    private func loadIfNeeded(_ path: String) throws {
        if context != nil, loadedPath == path { return }
        if let context {
            whisper_free(context)
            self.context = nil
            loadedPath = nil
        }

        let start = CFAbsoluteTimeGetCurrent()
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true      // Metal on Apple Silicon
        // Flash attention breaks shortened encoder windows on Metal (garbage or looping output),
        // and at full window it only saves ~7%. Clip-sized windows win by far more.
        contextParams.flash_attn = ProcessInfo.processInfo.environment["TRANSCRIBER_FLASH_ATTN"] != nil
        guard let loaded = whisper_init_from_file_with_params(path, contextParams) else {
            throw EngineError.loadFailed((path as NSString).lastPathComponent)
        }
        context = loaded
        loadedPath = path
        let loadTime = CFAbsoluteTimeGetCurrent() - start

        // One throwaway pass builds the Metal pipelines now instead of during the first dictation.
        // It uses the same small encoder window as a typical dictation, so it is quick.
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threadCount
        params.audio_ctx = Self.audioContext(forSampleCount: Int(AudioRecorder.sampleRate), margin: 32)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        let silence = [Float](repeating: 0, count: Int(AudioRecorder.sampleRate))
        "en".withCString { language in
            params.language = language
            _ = silence.withUnsafeBufferPointer { whisper_full(loaded, params, $0.baseAddress, Int32($0.count)) }
        }
        let warmTime = CFAbsoluteTimeGetCurrent() - start - loadTime
        log.info("Loaded \((path as NSString).lastPathComponent) in \(Int(loadTime * 1000))ms, warm-up \(Int(warmTime * 1000))ms")
    }
}
