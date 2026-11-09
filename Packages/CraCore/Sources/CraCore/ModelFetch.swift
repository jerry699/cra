import CryptoKit
import Foundation

/// What a catalog model's bytes must add up to, without the source URLs: the downloader in the
/// app passes the URLs the catalog pinned.
public struct ModelFile: Sendable {
    public let id: String
    public let fileName: String
    public let bytes: Int64
    public let sha256: String

    public init(id: String, fileName: String, bytes: Int64, sha256: String) {
        self.id = id
        self.fileName = fileName
        self.bytes = bytes
        self.sha256 = sha256
    }
}

extension LocalModel {
    public var file: ModelFile {
        ModelFile(id: id, fileName: fileName, bytes: bytes, sha256: sha256)
    }
}

/// Fetches a model in resumable ranges and only puts the file where the app looks once its pinned
/// SHA256 and GGUF magic match. A failed or cancelled download keeps its parts for the next try;
/// parts that cannot resume (wrong size, wrong digest, not a GGUF) are removed.
public enum ModelFetch {
    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private static let sessions: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 1800
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 8 ranges at once: ModelScope throttles a single connection to about 225 KB/s.
    private static let parts = 8

    /// Tries `urls` in order for each part, so one blocked source hands that range to the next.
    public static func download(_ file: ModelFile, from urls: [URL], to directory: URL,
                                report: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = stagingDirectory(for: file, in: directory)
        // A staging folder for another pinned file can't be trusted against this one. Compare
        // paths: directory URLs from the file system may lack the trailing slash ours has.
        for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix(".download-\(file.id)-")
            && old.standardizedFileURL.path != staging.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: old)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let chunk = (file.bytes + Int64(parts) - 1) / Int64(parts)
        let ticker = Task.detached {
            while !Task.isCancelled {
                report(downloadedBytes(in: staging))
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<parts {
                    group.addTask {
                        try await fetchPart(file, index: index, chunk: chunk, staging: staging, urls: urls)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            ticker.cancel()
            throw error
        }
        ticker.cancel()
        report(file.bytes)
        return try assemble(file, staging: staging)
    }

    static func stagingDirectory(for file: ModelFile, in directory: URL) -> URL {
        directory.appendingPathComponent(".download-\(file.id)-\(file.sha256.prefix(8))", isDirectory: true)
    }

    private static func fetchPart(_ file: ModelFile, index: Int, chunk: Int64, staging: URL,
                                  urls: [URL]) async throws {
        let part = staging.appendingPathComponent(String(format: "part-%02d", index))
        let start = Int64(index) * chunk
        let end = min(file.bytes, start + chunk) - 1
        let wanted = end - start + 1
        var have = size(of: part)
        if have > wanted {
            try? FileManager.default.removeItem(at: part)
            have = 0
        }
        guard have < wanted else { return }

        var lastError: Error = Failure("No source had \(file.fileName).")
        for url in urls {
            do {
                try await append(url, from: start + have, to: end, to: part)
            } catch where Self.cancelled(error) {
                throw CancellationError()
            } catch {
                lastError = error
            }
            have = size(of: part)
            if have == wanted { return }
            if have > wanted {
                try? FileManager.default.removeItem(at: part)
                have = 0
            }
        }
        throw lastError
    }

    /// Appends one HTTPS range to the part file. A server that answers 200 (ignoring Range)
    /// would append the whole file, so only 206 is accepted; the next source is tried instead.
    private static func append(_ url: URL, from: Int64, to: Int64, to part: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        let (temp, response) = try await sessions.download(for: request)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse else {
            throw Failure("No HTTP answer.")
        }
        guard http.statusCode == 206 else {
            throw Failure("The server answered \(http.statusCode) instead of the requested range.")
        }
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let source = try FileHandle(forReadingFrom: temp)
        let destination = try FileHandle(forWritingTo: part)
        defer {
            try? source.close()
            try? destination.close()
        }
        try destination.seekToEnd()
        while let data = try source.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            try destination.write(contentsOf: data)
        }
    }

    /// Joins the parts in order while hashing, so a file only gets its name after its digest and
    /// GGUF magic match the catalog.
    private static func assemble(_ file: ModelFile, staging: URL) throws -> URL {
        let assembled = staging.appendingPathComponent("assembled.gguf")
        try? FileManager.default.removeItem(at: assembled)
        FileManager.default.createFile(atPath: assembled.path, contents: nil)
        let out = try FileHandle(forWritingTo: assembled)
        var hasher = SHA256()
        do {
            for index in 0..<parts {
                let part = staging.appendingPathComponent(String(format: "part-%02d", index))
                let input = try FileHandle(forReadingFrom: part)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 4 << 20), !data.isEmpty {
                    hasher.update(data: data)
                    try out.write(contentsOf: data)
                }
            }
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: assembled)
            throw error
        }
        try out.close()

        let actual = size(of: assembled)
        guard actual == file.bytes else {
            try? FileManager.default.removeItem(at: assembled)
            // Parts that added up wrong can't be resumed from.
            removeParts(staging)
            throw Failure("The download was \(actual) bytes, not \(file.bytes).")
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: assembled)
            removeParts(staging)
            throw Failure("The downloaded file does not match the pinned SHA256.")
        }
        let magic: Data
        do {
            let handle = try FileHandle(forReadingFrom: assembled)
            defer { try? handle.close() }
            magic = try handle.read(upToCount: 4) ?? Data()
        } catch {
            try? FileManager.default.removeItem(at: assembled)
            removeParts(staging)
            throw error
        }
        guard magic == Data("GGUF".utf8) else {
            try? FileManager.default.removeItem(at: assembled)
            removeParts(staging)
            throw Failure("The downloaded file is not a GGUF.")
        }

        let final = staging.deletingLastPathComponent().appendingPathComponent(file.fileName)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: assembled, to: final)
        try? FileManager.default.removeItem(at: staging)
        return final
    }

    private static func removeParts(_ staging: URL) {
        let parts = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        for part in parts where part.lastPathComponent.hasPrefix("part-") {
            try? FileManager.default.removeItem(at: part)
        }
    }

    private static func downloadedBytes(in staging: URL) -> Int64 {
        let parts = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        return parts
            .filter { $0.lastPathComponent.hasPrefix("part-") }
            .map(size(of:))
            .reduce(0, +)
    }

    /// Not `URL.resourceValues`: it caches a part's size at first read, so the check after a write
    /// would still see the old one.
    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
