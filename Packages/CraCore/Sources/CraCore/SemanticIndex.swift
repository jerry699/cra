import Foundation

/// A history entry's embedding: the vector for "title + host", keyed by the history URL.
/// Built by CraInferenceHelper (op 4) with a pinned embedding GGUF — bge-small-zh-v1.5
/// (512-dim) is the default, Qwen3-Embedding-0.6B (1024-dim) the quality option.
public struct SemanticDocument: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var vector: [Float]

    public init(url: String, title: String, vector: [Float]) {
        self.url = url
        self.title = title
        self.vector = vector
    }
}

/// The per-profile semantic index over browsing history: documents plus the model id that
/// produced the vectors — vectors from different models don't mix, so a model change rebuilds.
public struct SemanticIndex: Codable, Equatable, Sendable {
    public var modelID: String
    public var documents: [SemanticDocument]

    public init(modelID: String, documents: [SemanticDocument] = []) {
        self.modelID = modelID
        self.documents = documents
    }

    public var urls: Set<String> { Set(documents.map(\.url)) }

    public mutating func upsert(_ document: SemanticDocument) {
        documents.removeAll { $0.url == document.url }
        documents.append(document)
    }

    public mutating func remove(urls: Set<String>) {
        documents.removeAll { urls.contains($0.url) }
    }

    /// Cosine similarity of the query with each document, best first. Brute force on purpose:
    /// at a browser's history scale (thousands) a linear scan is sub-millisecond against a
    /// 512-dim vector, and an ANN index would outsource memory the fork keeps local.
    public func search(query: [Float], limit: Int) -> [(document: SemanticDocument, score: Float)] {
        guard !query.isEmpty, query.count == documents.first?.vector.count else { return [] }
        let scored = documents.compactMap { doc -> (SemanticDocument, Float)? in
            guard doc.vector.count == query.count else { return nil }
            var dot: Float = 0
            var na: Float = 0
            var nb: Float = 0
            for (q, d) in zip(query, doc.vector) {
                dot += q * d
                na += q * q
                nb += d * d
            }
            let denom = na.squareRoot() * nb.squareRoot()
            guard denom > 0 else { return nil }
            return (doc, dot / denom)
        }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(limit))
            .map { (document: $0.0, score: $0.1) }
    }
}
