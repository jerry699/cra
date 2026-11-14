import AVFoundation

/// W2: transcription of downloaded audio/video via CraWhisper (whisper.cpp). Cra decodes the
/// media's audio track to a 16 kHz mono WAV with AVFoundation, and the one-shot CraWhisper
/// process transcribes it with the pinned whisper GGUF. The transcript lands next to the media
/// as .transcript.md. Nothing leaves the Mac.
enum WhisperService {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "whisperEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "whisperEnabled")
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "whisperEnabled")
    }

    /// Prefer small (better Chinese), fall back to base. Files staged in the shared Models dir.
    static var modelURL: URL? {
        let dir = MaxLocal.modelsDirectory
        for name in ["ggml-small.bin", "ggml-base.bin"] {
            if let url = dir?.appendingPathComponent(name),
               FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static var binaryURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("CraWhisper")
    }

    static let mediaExtensions: Set<String> = ["mp4", "mov", "m4a", "mp3", "wav", "flac", "m4b", "aac", "webm"]

    static func handles(_ path: String) -> Bool {
        mediaExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Transcribes the media file's audio track. Blocking; call from a detached task.
    static func transcribe(mediaURL: URL) -> String? {
        guard isEnabled, let modelURL = modelURL, let binaryURL else { return nil }
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cra-whisper-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        guard decodeToWav(mediaURL: mediaURL, wavURL: wavURL) else {
            CraLog.note("Whisper: cannot decode the audio track")
            return nil
        }
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [modelURL.path, wavURL.path, "zh"]
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        do { try process.run() } catch {
            CraLog.note("Whisper: cannot run (\(error))")
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            let tail = String(data: stderr.suffix(300), encoding: .utf8) ?? ""
            CraLog.note("Whisper: transcription failed (status \(process.terminationStatus)); stderr: \(tail)")
            return nil
        }
        return text
    }

    /// Decodes the media's audio track to a 16 kHz mono float32 WAV (whisper's input format)
    /// via AVFoundation — mp4/mov/m4a/mp3 all decode natively, no ffmpeg dependency.
    /// AVAssetReaderTrackOutput with int16, NOT AVAssetReaderAudioMixOutput with float32:
    /// the mix output decodes some B站 m4s streams to ALL-ZERO samples (a silent 100 %
    /// "successful" read that transcribes to nothing but "(音樂)" — the user's bug), while
    /// the plain track output reads the same file loud and clear.
    static func decodeToWav(mediaURL: URL, wavURL: URL) -> Bool {
        let asset = AVURLAsset(url: mediaURL)
        guard let track = asset.tracks(withMediaType: .audio).first else { return false }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let reader = try? AVAssetReader(asset: asset),
              let output = try? AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0
                var ptr: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                            totalLengthOut: &length, dataPointerOut: &ptr)
                if let ptr, length > 0 {
                    let frames = length / MemoryLayout<Int16>.size
                    ptr.withMemoryRebound(to: Int16.self, capacity: frames) {
                        for v in UnsafeBufferPointer(start: $0, count: frames) {
                            samples.append(Float(v) / 32768.0)
                        }
                    }
                }
            }
        }
        // A truncated download decodes to a few seconds of BGM and a transcript of nothing
        // but "(音樂)" — compare what decoded against what the container claims and refuse
        // a partial read (the distill flow then falls back to re-fetching).
        let expected = CMTimeGetSeconds(asset.duration)
        let decoded = Double(samples.count) / 16000.0
        CraLog.note(String(format: "Whisper: decoded %.1fs of %.1fs audio (%.0f%%)",
                           decoded, expected, expected > 0 ? decoded / expected * 100 : 0))
        if expected > 4, decoded < expected * 0.9 {
            CraLog.note("Whisper: the audio decoded only partially — the download is probably truncated")
            return false
        }
        guard !samples.isEmpty else { return false }
        return writeWav(samples: samples, sampleRate: 16000, to: wavURL)
    }

    /// 44-byte RIFF header + float32 mono samples.
    static func writeWav(samples: [Float], sampleRate: Int, to url: URL) -> Bool {
        var data = Data()
        let byteCount = UInt32(samples.count * 4)
        func append(_ s: String) { data.append(contentsOf: s.utf8) }
        func append(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append(byteCount + 36); append("WAVE")
        append("fmt "); append(UInt32(16)); append(UInt16(3)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 4))
        append(UInt16(4)); append(UInt16(32))
        append("data"); append(byteCount)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return FileManager.default.createFile(atPath: url.path, contents: data)
    }
}
