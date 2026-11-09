import CryptoKit
import Foundation
import Network
import Testing
@testable import CraCore

/// A local HTTP server that answers Range requests the way ModelScope and Hugging Face do (206
/// with the requested slice), and can instead ignore Range (200), or send slowly for cancellation.
private final class RangeServer: @unchecked Sendable {
    struct StartFailure: Error {}

    private let listener: NWListener
    private let queue = DispatchQueue(label: "cra.test.range-server")
    private let body: Data
    private let replyWholeFile: Bool
    private let chunkDelay: TimeInterval
    private let lock = NSLock()
    private var recorded: [String] = []

    init(body: Data, replyWholeFile: Bool = false, chunkDelay: TimeInterval = 0) throws {
        self.body = body
        self.replyWholeFile = replyWholeFile
        self.chunkDelay = chunkDelay
        listener = try NWListener(using: .tcp, on: .any)
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var ranges: [String] { lock.withLock { recorded } }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw StartFailure() }
    }

    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let range = head.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("range:") }
            .flatMap { value -> (Int, Int)? in
                let spec = value.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces)
                guard let spec, spec.hasPrefix("bytes=") else { return nil }
                let ends = spec.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1)
                guard ends.count == 2, let from = Int(ends[0]), let to = Int(ends[1]) else { return nil }
                return (from, to)
            }
        if let range {
            lock.withLock { recorded.append("\(range.0)-\(range.1)") }
        }
        guard !replyWholeFile, let range else {
            send(Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body,
                 on: connection)
            return
        }
        let from = range.0
        let to = min(range.1, body.count - 1)
        let slice = body.subdata(in: from..<(to + 1))
        let header = "HTTP/1.1 206 Partial Content\r\nContent-Length: \(slice.count)\r\n"
            + "Content-Range: bytes \(from)-\(to)/\(body.count)\r\nConnection: close\r\n\r\n"
        if chunkDelay > 0 {
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
                self.sendSlice(slice, at: 0, on: connection)
            })
        } else {
            send(Data(header.utf8) + slice, on: connection)
        }
    }

    private func sendSlice(_ slice: Data, at offset: Int, on connection: NWConnection) {
        guard offset < slice.count else { connection.cancel(); return }
        let end = min(offset + (64 << 10), slice.count)
        let chunk = slice.subdata(in: offset..<end)
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + self.chunkDelay) {
                self.sendSlice(slice, at: end, on: connection)
            }
        })
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

struct ModelFetchTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelFetchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeBody(_ bytes: Int) -> Data {
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15
        var data = Data("GGUF".utf8)
        while data.count < bytes {
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            data.append(UInt8(truncatingIfNeeded: x >> 33))
        }
        return data
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ body: Data, sha256: String? = nil) -> ModelFile {
        ModelFile(id: "test-model", fileName: "Test-Q4_K_M.gguf", bytes: Int64(body.count),
                  sha256: sha256 ?? digest(body))
    }

    private func url(_ server: RangeServer) -> URL {
        URL(string: "http://127.0.0.1:\(server.port)/model.gguf")!
    }

    @Test func downloadsInRangesAndVerifies() async throws {
        let body = makeBody(200_000)
        let server = try RangeServer(body: body)
        try server.start()
        defer { server.stop() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = file(body)

        let out = try await ModelFetch.download(model, from: [url(server)], to: directory) { _ in }

        #expect(try Data(contentsOf: out) == body)
        #expect(out.lastPathComponent == model.fileName)
        #expect(!FileManager.default.fileExists(
            atPath: ModelFetch.stagingDirectory(for: model, in: directory).path))
        #expect(server.ranges.count == 8)
        #expect(Set(server.ranges) == Set((0..<8).map { "\($0 * 25_000)-\(($0 + 1) * 25_000 - 1)" }))
    }

    @Test func resumesFromPartsAlreadyOnDisk() async throws {
        let body = makeBody(200_000)
        let server = try RangeServer(body: body)
        try server.start()
        defer { server.stop() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = file(body)
        let staging = ModelFetch.stagingDirectory(for: model, in: directory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try body.subdata(in: 0..<1_000).write(to: staging.appendingPathComponent("part-00"))

        let out = try await ModelFetch.download(model, from: [url(server)], to: directory) { _ in }

        #expect(try Data(contentsOf: out) == body)
        #expect(server.ranges.count == 8)
        #expect(server.ranges.contains("1000-24999"))
        #expect(!server.ranges.contains("0-24999"))
    }

    @Test func serverIgnoringRangeIsRejected() async throws {
        let body = makeBody(200_000)
        let server = try RangeServer(body: body, replyWholeFile: true)
        try server.start()
        defer { server.stop() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await ModelFetch.download(file(body), from: [url(server)], to: directory) { _ in }
            Issue.record("a 200 answer must not be accepted")
        } catch {
            #expect(error.localizedDescription.contains("200"), "\(error)")
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Test-Q4_K_M.gguf").path))
    }

    @Test func sha256MismatchLeavesNothingToResume() async throws {
        let body = makeBody(200_000)
        let server = try RangeServer(body: body)
        try server.start()
        defer { server.stop() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = file(body, sha256: String(repeating: "0", count: 64))

        do {
            _ = try await ModelFetch.download(model, from: [url(server)], to: directory) { _ in }
            Issue.record("a wrong digest must not be accepted")
        } catch {
            #expect(error.localizedDescription.contains("SHA256"), "\(error)")
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(model.fileName).path))
        let staging = ModelFetch.stagingDirectory(for: model, in: directory)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        #expect(!left.contains { $0.hasPrefix("part-") })
    }

    @Test func cancelStopsTheDownloadAndNextTryFinishes() async throws {
        let body = makeBody(16_000_000)
        let server = try RangeServer(body: body, chunkDelay: 0.01)
        try server.start()
        defer { server.stop() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = file(body)

        let job = Task {
            try await ModelFetch.download(model, from: [url(server)], to: directory) { _ in }
        }
        try await Task.sleep(for: .milliseconds(100))
        job.cancel()
        do {
            _ = try await job.value
            Issue.record("the download should have been cancelled")
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            #expect(cancelled, "\(error)")
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(model.fileName).path))

        // Whatever reached the disk is resumed; the answer still has to match the digest.
        let out = try await ModelFetch.download(model, from: [url(server)], to: directory) { _ in }
        #expect(try Data(contentsOf: out) == body)
    }

    /// Real bytes from ModelScope; opt in with `CRA_NET_TEST=1` since it moves 532 MB.
    @Test func modelScopeRealDownload() async throws {
        guard ProcessInfo.processInfo.environment["CRA_NET_TEST"] == "1" else { return }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ModelCatalog.pointEightB
        let urls = model.sources(preferred: .modelScope).compactMap { model.url(from: $0) }

        let out = try await ModelFetch.download(model.file, from: urls, to: directory) { _ in }

        let handle = try FileHandle(forReadingFrom: out)
        defer { try? handle.close() }
        #expect(try handle.read(upToCount: 4) == Data("GGUF".utf8))
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value
        #expect(size == model.bytes)
    }
}
