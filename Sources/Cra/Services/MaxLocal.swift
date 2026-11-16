import Foundation

/// Max features on a model that lives on this Mac: Tidy Tab Titles everywhere, Tidy Tabs too on a
/// Mac with memory for the 2B. Qwen3.5's GGUF is run by CraInferenceHelper, a separate process that
/// exits after a minute idle, so a Mac that stops tidying gets its memory back. The file arrives
/// from the catalog's pinned URLs (`ModelDownloader`) or, for a dev build, `CRA_LOCAL_MODEL`.
enum MaxLocal {
    static let settingKey = "maxLocalEnabled"
    static let titlesModelFileName = ModelCatalog.pointEightB.fileName
    static let tabsModelFileName = ModelCatalog.twoB.fileName

    static var isEnabled: Bool {
        // A test copy stands in the user's switch (scripts/scenario.sh, bench).
        ProcessInfo.processInfo.environment["CRA_LOCAL_ENABLED"] == "1"
            || UserDefaults.standard.bool(forKey: settingKey)
    }

    static func setEnabled(_ enabled: Bool) {
        CraLog.note(String(format: "Max Local: %@", enabled ? "on" : "off"))
        UserDefaults.standard.set(enabled, forKey: settingKey)
    }

    static var modelsDirectory: URL? {
        let directory = AppPaths.supportDir.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 8 GB Macs get the 0.8B (Titles); bigger ones the 2B, which also groups Tabs.
    static var recommendedModel: LocalModel {
        ModelCatalog.recommended(forMemory: Int64(ProcessInfo.processInfo.physicalMemory))
    }

    static var prefersTabsModel: Bool { recommendedModel == ModelCatalog.twoB }

    static func url(for model: LocalModel) -> URL? {
        modelsDirectory?.appendingPathComponent(model.fileName)
    }

    static func isInstalled(_ model: LocalModel) -> Bool {
        guard let url = url(for: model) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func delete(_ model: LocalModel) {
        guard let directory = modelsDirectory else { return }
        let file = directory.appendingPathComponent(model.fileName)
        try? FileManager.default.removeItem(at: file)
        // A cancelled download's parts go with it: the user asked for the model to be gone.
        for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix(".download-\(model.id)-") {
            try? FileManager.default.removeItem(at: old)
        }
        CraLog.note("Max Local: deleted \(model.id)")
    }

    /// CRA_LOCAL_MODEL points a dev build (or a test) at any GGUF; otherwise the recommended
    /// model when it is there, else the other one the user did download.
    static var modelURL: URL? {
        if let path = ProcessInfo.processInfo.environment["CRA_LOCAL_MODEL"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        if let url = url(for: recommendedModel), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        for model in ModelCatalog.all where isInstalled(model) {
            return url(for: model)
        }
        return url(for: recommendedModel)
    }

    static var isInstalled: Bool {
        guard let modelURL else { return false }
        return FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// Next to Cra in the app bundle; in a `swift build` directory, next to the debug binary.
    static var helperURL: URL? {
        if let path = ProcessInfo.processInfo.environment["CRA_INFERENCE_HELPER"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("CraInferenceHelper")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    static var isReady: Bool {
        isEnabled && isInstalled && helperURL != nil
    }

    /// Tidy Tabs needs the 2B: the 0.8B answers titles, not groupings. A dev model
    /// (CRA_LOCAL_MODEL) is taken as capable; pointing it at the 0.8B only weakens test results.
    static var canTidyTabs: Bool {
        guard isReady else { return false }
        if ProcessInfo.processInfo.environment["CRA_LOCAL_MODEL"] != nil { return true }
        return isInstalled(ModelCatalog.twoB)
    }

    /// 4096 holds the two-stage Tidy Tabs prompt and its answer; a rename needs 1024.
    static var context: Int {
        if let value = ProcessInfo.processInfo.environment["CRA_LOCAL_CONTEXT"], let n = Int(value), n >= 256 { return n }
        let name = modelURL?.lastPathComponent ?? ""
        return name.contains("2B") || name.contains("1.7B") ? 4096 : 1024
    }

    /// The same shape as MaxRemote.ask, so TidyTitlesService can fall through to it unchanged.
    @MainActor
    static func ask(instructions: String, prompt: String) async -> String? {
        await ask(instructions: instructions, prompt: prompt, grammar: nil, maxTokens: 32, timeout: 30)
    }

    /// One answer from the local model; `grammar` (GBNF) holds a JSON answer to its shape.
    @MainActor
    static func ask(instructions: String, prompt: String, grammar: String?, maxTokens: Int,
                    timeout: TimeInterval) async -> String? {
        guard isReady, let modelURL, let helperURL else { return nil }
        // The model maps clean file pages; on a Mac already short of memory they would come from
        // swap and the request would take minutes. Decline instead, and leave the pages alone.
        guard LocalRuntime.shared.canLoadModel(at: modelURL) else {
            CraLog.note("Max Local: declined (not enough free memory for the model)")
            return nil
        }
        return await LocalInference.shared.ask(system: instructions, user: prompt, grammar: grammar,
                                               maxTokens: maxTokens, context: context, timeout: timeout,
                                               threads: LocalRuntime.shared.threads,
                                               helper: helperURL, model: modelURL)
    }

    /// Tidy Tabs in two stages: topic names first, then a closed-book assignment of each tab.
    /// Nil at either stage when the model's answer isn't the JSON the grammar promises, and nil
    /// straight away once the task is cancelled (the divider's Cancel) between or within stages.
    @MainActor
    static func tidyTabs(tabs: [TidyTabs.Tab], existingGroups: [String],
                         preferences: [(title: String, group: String)] = [],
                         onStage: (@MainActor (TidyStage) -> Void)? = nil) async -> [TidyTabs.Proposal]? {
        guard canTidyTabs, !Task.isCancelled else { return nil }
        if let onStage { await onStage(.namingGroups) }
        CraLog.note("Max Local: Tidy Tabs grouped (single pass)")
        let prompt = TidyTabs.prompt(tabs: tabs, existingGroups: existingGroups, preferences: preferences)
        // CRA_TIDY_DEBUG=1: a fingerprint only, so two runs can be told apart without titles in the log.
        if ProcessInfo.processInfo.environment["CRA_TIDY_DEBUG"] != nil {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in prompt.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            CraLog.note(String(format: "Max Local: Tidy Tabs prompt %d bytes, fnv %016llx",
                               prompt.utf8.count, hash))
        }
        // P3-R2 single pass first: name groups AND assign ids in one decision — the
        // two-stage split let the naming and the assigning disagree (the user's accuracy
        // report). The two-stage flow stays as the fallback when the single pass fails.
        let groupedAnswer = await ask(instructions: TidyTabsTwoStage.groupedInstructions, prompt: prompt,
                                      grammar: TidyTabsTwoStage.groupedGrammar, maxTokens: 768,
                                      timeout: 240)
        guard !Task.isCancelled else { return nil }
        if let groupedAnswer, let proposals = TidyTabsTwoStage.grouped(from: groupedAnswer) {
            let sizes = proposals.map(\.tabs.count)
            CraLog.note(String(format: "Max Local: Tidy Tabs grouped: %d groups in one pass, sizes %@",
                               proposals.count, sizes.map(String.init).joined(separator: ",")))
            // A group of one per tab is the model squirming out of contradictory instructions
            // (seen with unrelated tabs): plan() would filter them all and apply nothing. The
            // two-stage flow, which names topics first, gets another chance.
            if proposals.count > 1, sizes.allSatisfy({ $0 < 2 }) {
                CraLog.note("Max Local: every tab alone in its own group — trying two stages")
            } else {
                return proposals
            }
        }
        // Why it failed matters: a broken grammar (the helper answers WITHOUT it, in its own
        // format) and a constrained-but-garbled answer look identical from the outside.
        CraLog.note("Max Local: Tidy Tabs grouped pass failed — falling back to two stages")
        if let groupedAnswer {
            CraLog.note("Max Local: grouped raw answer: " + String(groupedAnswer.prefix(200)))
        }
        if let errURL = LocalInference.stderrFile, let err = try? String(contentsOf: errURL, encoding: .utf8) {
            CraLog.note("Max Local: helper stderr tail: " + String(err.suffix(300)))
        }

        let topicsAnswer = await ask(instructions: TidyTabsTwoStage.topicsInstructions, prompt: prompt,
                                     grammar: TidyTabsTwoStage.topicsGrammar, maxTokens: 128,
                                     timeout: 240)
        // A cancelled request ends its helper early; that is not a model failure worth a log line.
        guard !Task.isCancelled else { return nil }
        guard let topicsAnswer, let topics = TidyTabsTwoStage.topics(from: topicsAnswer) else {
            CraLog.note("Max Local: Tidy Tabs found no topic names — raw answer: "
                        + String((topicsAnswer ?? "nil").prefix(200)))
            return nil
        }
        // A count only: the names, like the titles, stay out of the log.
        CraLog.note(String(format: "Max Local: Tidy Tabs topic names: %d", topics.count))
        if ProcessInfo.processInfo.environment["CRA_TIDY_DEBUG"] != nil {
            CraLog.note("Max Local: Tidy Tabs topics (debug): " + topics.joined(separator: " | "))
        }
        // A cancel between the stages must not start the second, longer one.
        guard !Task.isCancelled else { return nil }
        if let onStage { await onStage(.sortingTabs) }
        CraLog.note("Max Local: Tidy Tabs stage 2 (assignments)")
        let answer = await ask(instructions: TidyTabsTwoStage.assignmentsInstructions(topics: topics),
                               prompt: prompt, grammar: TidyTabsTwoStage.assignmentsGrammar,
                               maxTokens: 900, timeout: 300)
        guard !Task.isCancelled else { return nil }
        guard let answer, let assignments = TidyTabsTwoStage.assignments(from: answer, tabCount: tabs.count,
                                                                        topics: topics.count) else {
            CraLog.note("Max Local: Tidy Tabs got no usable assignment")
            return nil
        }
        if ProcessInfo.processInfo.environment["CRA_TIDY_DEBUG"] != nil {
            var counts = Array(repeating: 0, count: topics.count)
            for (_, topic) in assignments where topic >= 0 && topic < counts.count { counts[topic] += 1 }
            CraLog.note("Max Local: Tidy Tabs assignments (debug): \(counts)")
        }
        // The 2B sometimes answers every id with topic 0 after proposing several: one group of
        // everything is not a grouping, so the tabs stay as they were.
        if topics.count >= 3, tabs.count >= 10, Set(assignments.values).count == 1 {
            CraLog.note("Max Local: Tidy Tabs collapsed every tab into one topic")
            return nil
        }
        let proposals = TidyTabsTwoStage.proposals(topics: topics, assignments: assignments)
        // Two stages can degenerate the other way too (one topic per tab): with every proposal
        // a singleton, plan() applies nothing — say so and leave the tabs loose.
        if proposals.count > 1, proposals.allSatisfy({ $0.tabs.count < 2 }) {
            CraLog.note("Max Local: Tidy Tabs two stages also made one group per tab — leaving the tabs loose")
            return nil
        }
        return proposals
    }
}

/// One helper process, one request at a time. The actor serialises renames; a failed exchange
/// drops the process so the next rename starts a fresh one. The helper itself enforces the 60 s
/// idle exit, so no timer is needed here.
actor LocalInference {
    static let shared = LocalInference()

    /// Reachable without the actor. A cancel must not queue behind the request it cancels: the
    /// exchange below blocks on a pipe read inside the actor.
    final class HelperSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?

        func put(_ process: Process?) {
            lock.lock()
            let old = self.process
            self.process = process
            lock.unlock()
            if old !== process, old?.isRunning == true { old?.terminate() }
        }

        func terminate() {
            lock.lock()
            let process = self.process
            lock.unlock()
            if process?.isRunning == true { process?.terminate() }
        }
    }

    nonisolated let slot = HelperSlot()
    /// A second process for the embedding model: embeddings and generation use different GGUFs,
    /// and switching one helper between modes would thrash loads between Tidy bursts and index
    /// builds (bge is a BERT — it embeds and cannot generate at all).
    nonisolated static let embedding = LocalInference()

    private var process: Process?
    private var toHelper: FileHandle?
    private var fromHelper: FileHandle?
    /// The context is fixed when the helper loads its model, so a change restarts it.
    private var startedModel: URL?
    private var startedContext = 0
    private var startedThreads: Int32 = 0

    private enum Failure: Error {
        case ended
        case badReply
    }

    func ask(system: String, user: String, grammar: String?, maxTokens: Int, context: Int,
             timeout: TimeInterval, threads: Int32, helper: URL, model: URL) async -> String? {
        // Cancelled before it began (the divider's Cancel): don't spin a helper up for nothing.
        guard !Task.isCancelled else { return nil }
        do {
            if process?.isRunning != true || startedModel != model || startedContext != context
                || startedThreads != threads || startedPooling != -1 {
                try start(helper: helper, model: model, context: context, threads: threads, pooling: -1)
            }
            return try exchange(system: system, user: user, grammar: grammar,
                                maxTokens: maxTokens, timeout: timeout)
        } catch {
            CraLog.note("Max Local: the model process failed (\(error))")
            stop()
            return nil
        }
    }

    /// One embedding vector (helper op 4): the text in, `n_embd` little-endian floats out.
    /// The helper loads the model in embedding mode on first use (pooling per the GGUF
    /// metadata). Context 2048: the indexed text grew to title + description + a 500-char
    /// body snapshot (P3) — at 1024 a long page overflowed the context, llama_decode
    /// asserted and the helper crashed, and the 3 s poller restarted it forever.
    func embed(text: String, model: URL, helper: URL, threads: Int32, pooling: Int32) async -> [Float]? {
        if process?.isRunning != true || startedModel != model || startedPooling != pooling {
            do { try start(helper: helper, model: model, context: 2048, threads: threads, pooling: pooling) }
            catch {
                CraLog.note("Embeddings: cannot start the helper (\(error))")
                return nil
            }
        }
        var frame = Data()
        Self.append(UInt32(0x4C515243), to: &frame)
        frame.append(4)
        frame.append(contentsOf: [0, 0, 0])
        Self.append(UInt32(0), to: &frame)
        Self.appendString(text, to: &frame)
        do {
            try toHelper?.write(contentsOf: frame)
            let header = try read(12)
            guard header.count == 12, Self.uint32(header, at: 0) == 0x4C534352 else { throw Failure.badReply }
            let status = header[4]
            let length = Int(Self.uint32(header, at: 8))
            let body = length > 0 ? try read(length) : Data()
            guard status == 0, body.count >= 4 else {
                Thread.sleep(forTimeInterval: 0.3)  // let the helper finish its diagnostics
                CraLog.note(String(format: "Embeddings: helper replied status %d, %d bytes; stderr: %@",
                                   status, body.count, recentStderr().suffix(2000)))
                return nil
            }
            return body.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            }
        } catch {
            CraLog.note("Embeddings: the model process failed (\(error)); helper stderr: \(recentStderr().suffix(400))")
            stop()
            return nil
        }
    }

    /// Cancels the request in flight: the helper exits and the read waiting on it ends. Called
    /// without hopping onto the actor, which the read occupies. The pipes stay open here; `ask`
    /// closes them when the read fails.
    nonisolated func cancelCurrent() {
        slot.terminate()
    }


    private var startedPooling: Int32 = -1

    private func start(helper: URL, model: URL, context: Int, threads: Int32, pooling: Int32) throws {
        stop()
        let process = Process()
        process.executableURL = helper
        process.arguments = [model.path, "60", String(context), String(threads), String(pooling)]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // The helper's diagnostics go to a file: a crash's stderr must survive the process for
        // the failure log to quote it (pipe chunks raced the log).
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("cra-inference-helper.err")
        try? FileManager.default.removeItem(at: errURL)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: errURL)
        Self.stderrFile = errURL
        try process.run()
        self.process = process
        slot.put(process)
        toHelper = input.fileHandleForWriting
        fromHelper = output.fileHandleForReading
        startedModel = model
        startedContext = context
        startedThreads = threads
        startedPooling = pooling
        CraLog.note(String(format: "Max Local: started the model process (context %d, %d threads, pooling %d)",
                           context, threads, pooling))
    }

    static var stderrFile: URL?

    func recentStderr() -> String {
        guard let url = Self.stderrFile, let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data.suffix(2000), encoding: .utf8) ?? ""
    }

    private func stop() {
        try? toHelper?.close()
        if process?.isRunning == true { process?.terminate() }
        slot.put(nil)
        toHelper = nil
        fromHelper = nil
        process = nil
        startedModel = nil
        startedContext = 0
        startedThreads = 0
        startedPooling = -1
    }

    private func exchange(system: String, user: String, grammar: String?, maxTokens: Int,
                          timeout: TimeInterval) throws -> String? {
        var frame = Data()
        Self.append(UInt32(0x4C515243), to: &frame)  // "CRQL"
        frame.append(grammar == nil ? 0 : 3)  // generate
        frame.append(contentsOf: [0, 0, 0])
        Self.append(UInt32(maxTokens), to: &frame)
        Self.appendString(system, to: &frame)
        Self.appendString(user, to: &frame)
        if let grammar { Self.appendString(grammar, to: &frame) }
        guard let toHelper else { throw Failure.ended }
        try toHelper.write(contentsOf: frame)

        // A hung helper must not keep a pinned tab waiting forever; Tabs takes minutes.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
        defer { watchdog.cancel() }

        let header = try read(12)
        guard header.count == 12, Self.uint32(header, at: 0) == 0x4C534352 else { throw Failure.badReply }
        let status = header[4]
        let length = Int(Self.uint32(header, at: 8))
        let body = length > 0 ? try read(length) : Data()
        guard status == 0, let answer = String(data: body, encoding: .utf8), !answer.isEmpty else {
            // A status-1 reply is the helper declining (a failed load, an empty generation);
            // its diagnostics live in the stderr file. Silent nil here cost a day of debugging
            // (the distill summary): quote both.
            CraLog.note(String(format: "Max Local: the model replied status %d, %d bytes; stderr: %@",
                               status, body.count, recentStderr().suffix(600)))
            return nil
        }
        return answer
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try fromHelper?.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw Failure.ended
            }
            data.append(chunk)
        }
        return data
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        append(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) | (UInt32(data[start + 1]) << 8) |
               (UInt32(data[start + 2]) << 16) | (UInt32(data[start + 3]) << 24)
    }
}
