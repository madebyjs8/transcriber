import CryptoKit
import Foundation
import Observation

struct WhisperModel: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let bytes: Int64
    /// SHA-256 published by Hugging Face; nil for user-provided models.
    let sha256: String?
    var isCustom = false

    var fileName: String { "ggml-\(id).bin" }
    var downloadURL: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Knows which Whisper models exist, which are on disk, and downloads new ones.
@Observable
final class ModelManager: NSObject {
    static let catalog: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo-q5_0", name: "Large v3 Turbo",
                     summary: "Recommended. Near large-v3 accuracy at a fraction of the cost. All languages.",
                     bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
        WhisperModel(id: "large-v3-turbo-q8_0", name: "Large v3 Turbo (high precision)",
                     summary: "Marginally more accurate than the recommended model, uses more memory.",
                     bytes: 874_188_075, sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"),
        WhisperModel(id: "small.en", name: "Small (English)",
                     summary: "Fast and light. English only.",
                     bytes: 487_614_201, sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"),
        WhisperModel(id: "base.en", name: "Base (English)",
                     summary: "Fastest and smallest, noticeably less accurate. English only.",
                     bytes: 147_964_211, sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"),
    ]

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Transcriber/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Catalog models plus any other ggml-*.bin the user dropped into the models folder.
    private(set) var models: [WhisperModel] = catalog
    private(set) var installed: Set<String> = []
    /// Download progress (0…1) keyed by model id; present while downloading or verifying.
    private(set) var progress: [String: Double] = [:]
    private(set) var verifying: Set<String> = []
    private(set) var errors: [String: String] = [:]

    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]

    /// Called on the main thread whenever a model finished installing.
    @ObservationIgnored var onInstalled: ((WhisperModel) -> Void)?

    override init() {
        super.init()
        refresh()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        var models = Self.catalog
        for file in files.sorted() where file.hasPrefix("ggml-") && file.hasSuffix(".bin") {
            let id = String(file.dropFirst(5).dropLast(4))
            if models.contains(where: { $0.id == id }) { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: path(forFile: file))[.size] as? Int64) ?? 0
            models.append(WhisperModel(id: id, name: id, summary: "Custom model from the models folder.",
                                       bytes: size, sha256: nil, isCustom: true))
        }
        self.models = models
        installed = Set(models.filter { FileManager.default.fileExists(atPath: path(for: $0)) }.map(\.id))
    }

    func model(id: String) -> WhisperModel? { models.first { $0.id == id } }

    func path(for model: WhisperModel) -> String { path(forFile: model.fileName) }
    private func path(forFile file: String) -> String { Self.directory.appendingPathComponent(file).path }

    /// The model to use: the selected one if installed, otherwise the best installed one.
    func activeModel(preferred id: String) -> WhisperModel? {
        if let model = model(id: id), installed.contains(id) { return model }
        return models.first { installed.contains($0.id) }
    }

    // MARK: - Downloads

    func download(_ model: WhisperModel) {
        guard tasks[model.id] == nil, !model.isCustom else { return }
        errors[model.id] = nil
        progress[model.id] = 0
        let task = session.downloadTask(with: model.downloadURL)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancelDownload(_ model: WhisperModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        progress[model.id] = nil
    }

    func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(atPath: path(for: model))
        refresh()
    }

    private func finishInstall(id: String, downloadedFile: URL) {
        guard let model = model(id: id) else { return }
        let destination = URL(fileURLWithPath: path(for: model))
        DispatchQueue.main.async { self.verifying.insert(id) }

        DispatchQueue.global(qos: .utility).async {
            var failure: String?
            if let expected = model.sha256, Self.sha256(of: downloadedFile) != expected {
                failure = "Download was corrupted. Please try again."
            } else {
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: downloadedFile, to: destination)
                } catch {
                    failure = error.localizedDescription
                }
            }
            if failure != nil { try? FileManager.default.removeItem(at: downloadedFile) }

            DispatchQueue.main.async {
                self.verifying.remove(id)
                self.progress[id] = nil
                self.tasks[id] = nil
                self.errors[id] = failure
                self.refresh()
                if failure == nil { self.onInstalled?(model) }
            }
        }
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (model(id: id)?.bytes ?? 1)
        let fraction = min(1, Double(totalBytesWritten) / Double(expected))
        DispatchQueue.main.async {
            // Throttle UI updates to whole-percent changes.
            if let current = self.progress[id], Int(current * 100) == Int(fraction * 100) { return }
            if self.tasks[id] != nil { self.progress[id] = fraction }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            DispatchQueue.main.async { self.errors[id] = "Download failed (HTTP \(http.statusCode))" }
            return
        }
        // The system deletes `location` when this method returns, so move it right away.
        let staged = ModelManager.directory.appendingPathComponent("\(id).download")
        try? FileManager.default.removeItem(at: staged)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            finishInstall(id: id, downloadedFile: staged)
        } catch {
            DispatchQueue.main.async { self.errors[id] = error.localizedDescription }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        DispatchQueue.main.async {
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.errors[id] = error.localizedDescription
            }
            if error != nil || self.errors[id] != nil {
                self.progress[id] = nil
                self.tasks[id] = nil
            }
        }
    }
}
