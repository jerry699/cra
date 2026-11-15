import Foundation

/// Semantic history search: embeds history titles with a pinned embedding GGUF
/// (Qwen3-Embedding-0.6B, 1024-dim — conceptual Chinese matching the 25MB bge couldn't do) in
/// its own CraInferenceHelper process, and answers queries for the command bar.
///
/// Separate process from the generation model on purpose: bge is a BERT — it embeds and cannot
/// generate, so sharing one helper would thrash modes between Tidy bursts and index builds.
/// The index lives in the data folder as semantic-index.json; vectors from a different model
/// id force a rebuild (vectors never mix).
@MainActor
final class EmbeddingService {
    static let shared = EmbeddingService()

    static let modelID = "qwen3-embedding-0.6b-q8_0"
    static let modelFileName = "Qwen3-Embedding-0.6B-Q8_0.gguf"
    /// bge (bert) pools MEAN; Qwen3-Embedding pools LAST. The GGUF metadata for the latter is
    /// absent, so the helper needs the value explicitly.
    static var poolingType: Int32 { modelID.contains("bge") ? 1 : 3 }

    private let inference = LocalInference()
    private let indexFile = JSONStore<SemanticIndex>("semantic-index.json")
    private var index = SemanticIndex(modelID: "qwen3-embedding-0.6b-q8_0")
    private var indexLoaded = false
    private var building = false

    static var modelURL: URL? {
        // Same Models folder the other catalog models live in (MaxLocal.modelsDirectory).
        MaxLocal.modelsDirectory?.appendingPathComponent(Self.modelFileName)
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

    /// Settings ▸ Max "clear": drops the whole semantic index. It is a CACHE — the next
    /// rebuildIfNeeded re-embeds everything from history.json (~20 s for 400 pages). The
    /// history itself and the tidy preferences are the user's data and are never touched.
    func clearIndex() {
        building = false
        index = SemanticIndex(modelID: Self.modelID)
        persist()
        CraLog.note("Embeddings: index cleared (rebuilds from history on the next tick)")
    }

    /// The index file's size for the settings row.
    var indexFileSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: Self.indexURL.path)[.size] as? Int) ?? 0
    }

    /// How many pages the index holds, for the settings row.
    var documentCount: Int { index.documents.count }

    /// Embeds history titles that are not in the index yet — plus entries whose text
    /// version has bumped (P3 索引增肥): the embed text grows from "title + host" to
    /// "+ meta description + body snippet", so recall works on what a page SAYS (content
    /// words like 董事长 never appear in a title). Called after launch and when the
    /// history grows; a run over a day's new entries takes seconds (0.01-0.05 s per title).
    func rebuildIfNeeded(history: [HistoryEntry]) {
        guard !building, let modelURL = Self.modelURL, let helperURL = Self.helperURL else { return }
        let pending = history.filter { entry in
            guard !entry.title.isEmpty else { return false }
            if !index.urls.contains(entry.url) { return true }
            let docVersion = index.documents.first(where: { $0.url == entry.url })?.textVersion ?? 0
            return (entry.textVersion ?? 0) > docVersion
        }
        guard !pending.isEmpty else { return }
        building = true
        Task { @MainActor in
            defer { building = false }
            CraLog.note(String(format: "Embeddings: indexing %d history entries", pending.count))
            let started = Date()
            var embedded = 0
            var nilStreak = 0
            for entry in pending.prefix(2000) {
                if Task.isCancelled { return }
                let host = URL(string: entry.url)?.host() ?? ""
                var text = "\(entry.title) \(host)"
                if let description = entry.description, !description.isEmpty { text += " " + description }
                if let snippet = entry.contentSnippet, !snippet.isEmpty { text += " " + snippet }
                // The embed context is 2048 tokens; a Chinese char is ~1 token. Overflows
                // crash llama_decode and the helper dies — cap the text with margin.
                if text.count > 1500 { text = String(text.prefix(1500)) }
                let version = entry.textVersion
                guard let vector = await inference.embed(text: text, model: modelURL,
                                                         helper: helperURL, threads: 4, pooling: Self.poolingType) else {
                    nilStreak += 1
                    if nilStreak >= 2 {
                        CraLog.note("Embeddings: two failures in a row — backing off until the next tick")
                        return
                    }
                    continue
                }
                nilStreak = 0
                index.upsert(SemanticDocument(url: entry.url, title: entry.title, vector: vector,
                                              textVersion: version))
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
    /// Two gates keep the "no true hit" noise out:
    /// - per-doc floor 0.35: a single weak match ("中年危机" vs a banking page ≈ 0.26).
    /// - weak-anchor gate 0.45: rare alphanumeric queries ("yu7") score EVERYTHING into a
    ///   flat 0.34-0.38 background band — measured, the TRUE page scored 0.380 while a
    ///   noise page scored 0.384, so no static floor can separate them. When even the best
    ///   match sits in that band, the query has no anchor in the index at all: withhold
    ///   every semantic row and let the keyword rows answer.
    static let minimumScore: Float = 0.35
    static let weakAnchorScore: Float = 0.45

    func search(_ query: String, limit: Int = 5) async -> [(url: String, title: String, score: Float)] {
        guard indexLoaded, !index.documents.isEmpty, query.count >= 2,
              let modelURL = Self.modelURL, let helperURL = Self.helperURL else { return [] }
        guard let vector = await inference.embed(text: query, model: modelURL, helper: helperURL, threads: 4, pooling: Self.poolingType) else {
            return []
        }
        let matches = index.search(query: vector, limit: limit)
            .filter { $0.score >= Self.minimumScore }
        guard let best = matches.first?.score, best >= Self.weakAnchorScore else {
            CraLog.note(String(format: "Semantic: weak anchor (best %.2f) — withheld", matches.first?.score ?? 0))
            return []
        }
        return matches.map { (url: $0.document.url, title: $0.document.title, score: $0.score) }
    }

    /// The entries the index knows, for the search integration to map back to history rows.
    func documentURLs() -> Set<String> { index.urls }
}
