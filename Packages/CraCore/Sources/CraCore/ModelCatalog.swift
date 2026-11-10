import Foundation

/// The GGUFs Cra may run on this Mac: pinned files from unsloth's Qwen3.5 GGUF releases, the
/// same bytes at ModelScope and Hugging Face (checked 2026-11-09: both digests below). A file is
/// only ever fetched from these URLs, and only used after its SHA256 matches.
public struct LocalModel: Identifiable, Equatable, Sendable {
    public enum Capability: String, Sendable {
        case titles
        case tabs
    }

    public let id: String
    public let name: String
    public let fileName: String
    public let repository: String
    public let bytes: Int64
    public let sha256: String
    public let capabilities: Set<Capability>

    public var gibibytes: Double { Double(bytes) / Double(1 << 30) }

    public func url(from source: ModelSource) -> URL? {
        URL(string: source.baseURL + repository + "/resolve/" + source.revision + "/" + fileName)
    }

    /// The source this Mac's region should try first; the rest follow.
    public func sources(preferred: ModelSource) -> [ModelSource] {
        [preferred] + ModelSource.allCases.filter { $0 != preferred }
    }
}

/// Where a model file comes from. ModelScope and Hugging Face are peers: the system region picks
/// one to try first, and a failed range moves on to the next. The mirror serves the same files.
public enum ModelSource: String, CaseIterable, Identifiable, Sendable {
    case modelScope
    case huggingFace
    case huggingFaceMirror

    public var id: String { rawValue }

    /// The user's pick in Settings; unset means the region's default.
    public static let settingKey = "localModelSource"

    public var label: String {
        switch self {
        case .modelScope: return "ModelScope"
        case .huggingFace: return "Hugging Face"
        case .huggingFaceMirror: return "Hugging Face mirror"
        }
    }

    var baseURL: String {
        switch self {
        case .modelScope: return "https://www.modelscope.cn/models/"
        case .huggingFace: return "https://huggingface.co/"
        case .huggingFaceMirror: return "https://hf-mirror.com/"
        }
    }

    /// ModelScope's default branch is master; Hugging Face's is main.
    var revision: String {
        self == .modelScope ? "master" : "main"
    }

    /// Mainland China reaches ModelScope directly; elsewhere Hugging Face comes first.
    public static func preferred(region: String?) -> ModelSource {
        region?.uppercased() == "CN" ? .modelScope : .huggingFace
    }
}

public enum ModelCatalog {
    public static let pointEightB = LocalModel(
        id: "qwen3.5-0.8b-q4km",
        name: "Qwen3.5 0.8B",
        fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
        repository: "unsloth/Qwen3.5-0.8B-GGUF",
        bytes: 532_517_120,
        sha256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
        capabilities: [.titles])

    /// Measured on the 2018 Intel test Mac (2026-11-10, see docs/local-model-plan.md): Titles 6/6
    /// synthetic renames (0.59-0.94 s after load), Tidy Tabs 7 tabs → 3 groups in 31.0 s — faster
    /// and less fragmented than the Qwen3.5 2B (45.1 s, 6 fragmented groups), so it serves both
    /// features and the 0.8B stays as the low-memory fallback.
    public static let twoB = LocalModel(
        id: "qwen3-1.7b-q4km",
        name: "Qwen3 1.7B",
        fileName: "Qwen3-1.7B-Q4_K_M.gguf",
        repository: "unsloth/Qwen3-1.7B-GGUF",
        bytes: 1_107_409_472,
        sha256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897",
        capabilities: [.titles, .tabs])

    public static let all = [twoB, pointEightB]

    public static func model(id: String) -> LocalModel? {
        all.first { $0.id == id }
    }

    /// 8 GB Macs get the 0.8B (Titles only); more memory gets the 2B, which also groups Tabs.
    public static func recommended(forMemory memory: Int64) -> LocalModel {
        memory > 8 << 30 ? twoB : pointEightB
    }

    /// Whether free space on the models volume covers a download and its assembled copy.
    public static func fits(_ model: LocalModel, freeBytes: Int64) -> Bool {
        freeBytes >= model.bytes * 2
    }
}
