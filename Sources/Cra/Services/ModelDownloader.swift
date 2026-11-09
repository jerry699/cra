import Foundation
import Observation

/// The Settings pane's view of a model download: which catalog file is in flight, how far it got,
/// and how it ended. The bytes themselves come from `ModelFetch` in CraCore, which verifies the
/// pinned SHA256 before the file gets its name.
@MainActor @Observable
final class ModelDownloader {
    static let shared = ModelDownloader()

    enum Phase: Equatable {
        case idle
        case downloading
        case verifying
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var modelID: String?
    private(set) var received: Int64 = 0
    private(set) var total: Int64 = 0

    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    var isBusy: Bool { phase == .downloading || phase == .verifying }

    @ObservationIgnored private var job: Task<Void, Never>?

    private init() {}

    /// The source the user picked, else the one this Mac's region starts with.
    static var preferredSource: ModelSource {
        get {
            guard let raw = UserDefaults.standard.string(forKey: ModelSource.settingKey),
                  let source = ModelSource(rawValue: raw) else {
                return ModelSource.preferred(region: Locale.current.region?.identifier)
            }
            return source
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ModelSource.settingKey) }
    }

    func start(_ model: LocalModel) {
        guard job == nil, !MaxLocal.isInstalled(model) else { return }
        guard let directory = MaxLocal.modelsDirectory else {
            phase = .failed("Cra has no Models folder.")
            return
        }
        if let free = Self.freeSpace(for: directory), !ModelCatalog.fits(model, freeBytes: free) {
            phase = .failed("Not enough disk space for \(model.name) (needs \(model.bytes * 2 / (1 << 30)) GB free).")
            return
        }
        modelID = model.id
        total = model.bytes
        received = 0
        phase = .downloading
        let source = Self.preferredSource
        let urls = model.sources(preferred: source).compactMap { model.url(from: $0) }
        CraLog.note(String(format: "Model download: %@ from %@", model.id, source.label))
        job = Task {
            do {
                _ = try await ModelFetch.download(model.file, from: urls, to: directory) { done in
                    Task { @MainActor in
                        guard self.modelID == model.id, self.phase == .downloading else { return }
                        self.received = done
                    }
                }
                await MainActor.run {
                    self.received = model.bytes
                    self.phase = .idle
                    self.job = nil
                    CraLog.note("Model download: \(model.id) verified and in place")
                }
            } catch where Self.isCancellation(error) {
                await MainActor.run {
                    self.phase = .idle
                    self.job = nil
                    CraLog.note("Model download: cancelled; partial file kept for resume")
                }
            } catch {
                await MainActor.run {
                    self.phase = .failed(error.localizedDescription)
                    self.job = nil
                    CraLog.note("Model download: failed (\(error.localizedDescription))")
                }
            }
        }
    }

    func cancel() {
        job?.cancel()
    }

    /// Removes the model and anything a download left behind, then the feature that needed it
    /// goes back to its uninstalled state.
    func delete(_ model: LocalModel) {
        guard !isBusy else { return }
        MaxLocal.delete(model)
        if modelID == model.id {
            modelID = nil
            received = 0
            total = 0
            phase = .idle
        }
    }

    private static func freeSpace(for directory: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: directory.path)
            ? directory : directory.deletingLastPathComponent()
        return try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
