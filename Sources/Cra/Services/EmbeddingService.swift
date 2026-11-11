import Foundation

/// Semantic history search: embeds history titles with a pinned embedding GGUF
/// (bge-small-zh-v1.5, 512-dim, 25 MB — the lightest model that covers Chinese) in its own
/// CraInferenceHelper process, and answers queries for the command bar.
///
/// Separate process from the generation model on purpose: bge is a BERT — it embeds and cannot
/// generate, so sharing one helper would thrash modes between Tidy bursts and index builds.
/// The index lives in the data folder as semantic-index.json; vectors from a different model
/// id force a rebuild (vectors never mix).
@MainActor
final class EmbeddingService {
    static let shared = EmbeddingService()

    static let modelID = "bge-small-zh-v1.5-q8_0"
    static let modelFileName = "bge-small-zh-v1.5-q8_0.gguf"

    private let inference = LocalInference()
    private let indexFile = JSONStore<SemanticIndex>("semantic-index.json")
    private var index = SemanticIndex(modelID: "bge-small-zh-v1.5-q8_0")
    private var indexLoaded = false
    private var building = false

    static var modelURL: URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cra", isDirectory: true).appendingPathComponent("Models", isDirectory: true)
        let url = dir.appendingPathComponent(Self.modelFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var helperURL: URL? { MaxLocal.helperURL }

    private static var indexURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cra", isDirectory: true)
        return dir.appendingPathComponent("semantic-index.json")
    }

    private init() {
        if let data = try? Data(contentsOf: EmbeddingService.indexURL),
           let stored = try? JSONDecoder().decode(SemanticIndex.self, from: data),
           stored.modelID == Self.modelID {
            index = stored
            indexLoaded = true
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    /// Embeds history titles that are not in the index yet. Called after launch and when the
    /// history grows; a run over a day's new entries takes seconds (0.01-0.05 s per title).
    func rebuildIfNeeded(history: [HistoryEntry]) {
        guard !building, let modelURL = Self.modelURL, let helperURL = Self.helperURL else { return }
        let known = index.urls
        let pending = history.filter { !known.contains($0.url) && !$0.title.isEmpty }
        guard !pending.isEmpty else { return }
        building = true
        Task { @MainActor in
            defer { building = false }
            CraLog.note(String(format: "Embeddings: indexing %d history entries", pending.count))
            let started = Date()
            var embedded = 0
            for entry in pending.prefix(2000) {
                if Task.isCancelled { return }
                let host = URL(string: entry.url)?.host() ?? ""
                let text = "\(entry.title) \(host)"
                guard let vector = await inference.embed(text: text, model: modelURL,
                                                         helper: helperURL, threads: 4) else { return }
                index.upsert(SemanticDocument(url: entry.url, title: entry.title, vector: vector))
                embedded += 1
            }
            persist()
            CraLog.note(String(format: "Embeddings: indexed %d of %d in %.1f s (total %d)",
                               embedded, pending.count, Date().timeIntervalSince(started), index.documents.count))
        }
    }

    /// Drops documents whose URLs left the history (archive pruning, cleared browsing data).
    func sync(with history: [HistoryEntry]) {
        let live = Set(history.map(\.url))
        let stale = Set(index.documents.map(\.url)).subtracting(live)
        guard !stale.isEmpty else { return }
        index.remove(urls: stale)
        persist()
    }

    /// Top semantic matches for a query; the command bar merges them with its keyword rows.
    func search(_ query: String, limit: Int = 5) async -> [(url: String, title: String, score: Float)] {
        guard indexLoaded, !index.documents.isEmpty, query.count >= 2,
              let modelURL = Self.modelURL, let helperURL = Self.helperURL else { return [] }
        guard let vector = await inference.embed(text: query, model: modelURL, helper: helperURL, threads: 4) else {
            return []
        }
        return index.search(query: vector, limit: limit)
            .map { (url: $0.document.url, title: $0.document.title, score: $0.score) }
    }

    /// The entries the index knows, for the search integration to map back to history rows.
    func documentURLs() -> Set<String> { index.urls }
}
