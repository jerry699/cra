import AppKit
import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tidy Tabs on the Mac's own Apple Intelligence model (FoundationModels, macOS 26): free, and
/// nothing leaves the Mac. Arc sent the same "id: title" list to its server (Arc Max). Without
/// Apple Intelligence (an older macOS, a Mac that can't run it, or it is off) the Tidy button
/// doesn't show at all. What the answer does to the sidebar is TidyTabs (CraCore) and the store.
@MainActor @Observable
final class TidyTabsService {
    static let shared = TidyTabsService()

    /// Where Apple Intelligence stands on this Mac, as Settings explains it.
    enum Status: Equatable {
        case available
        /// Off in System Settings ▸ Apple Intelligence & Siri.
        case off
        /// On, with the model still downloading.
        case preparing
        /// An Intel Mac, or one Apple Intelligence doesn't support.
        case ineligible
        /// macOS 15 or earlier: no FoundationModels.
        case needsNewerMacOS
        case unavailable
        /// Apple Intelligence can't run here, but the user configured their own
        /// OpenAI-compatible provider (Settings ▸ Max): tab titles and site names
        /// go to that provider.
        case remote
        /// Apple Intelligence can't run here, so Max features use the local model
        /// (Settings ▸ Max ▸ Local model): Tidy Tab Titles always, Tidy Tabs with the 2B.
        case local

        /// What Settings ▸ Max says under its features.
        var explanation: String {
            switch self {
            case .available: return "Max features run on Apple Intelligence on this Mac. Nothing is sent anywhere."
            case .off: return "Max features run on Apple Intelligence, which is off on this Mac."
            case .preparing: return "Apple Intelligence is still downloading. Max features turn on once it’s ready."
            case .ineligible: return "Max features run on Apple Intelligence, which needs a Mac with Apple silicon."
            case .needsNewerMacOS: return "Max features run on Apple Intelligence, which needs macOS 26 or later."
            case .unavailable: return "Apple Intelligence isn’t available right now."
            case .remote: return "Max features run on your own provider (\(MaxRemote.provider.label)). Tab titles and site names are sent to it."
            case .local: return MaxLocal.canTidyTabs
                ? "Tidy Tab Titles and Tidy Tabs run on the local model on this Mac. Nothing is sent anywhere."
                : "Tidy Tab Titles runs on the local model on this Mac. Nothing is sent anywhere."
            }
        }

        /// Whether System Settings can fix it.
        var canOpenSettings: Bool { self == .off || self == .preparing || self == .unavailable }
    }

    /// Read again when Cra comes to the front and while Settings shows it, so turning Apple
    /// Intelligence on in System Settings shows the button without a relaunch.
    private(set) var status: Status = .needsNewerMacOS
    var modelAvailable: Bool { status == .available || status == .remote }

    /// Whether Tidy Tabs can run here: Apple Intelligence, the user's provider, or the local 2B.
    var tabsAvailable: Bool {
        modelAvailable || (status == .local && MaxLocal.canTidyTabs)
    }

    @ObservationIgnored private var activation: NSObjectProtocol?
    /// Tidy's work per space, so a second press on the broom cancels it; the store comes along so
    /// a memory warning can cancel every run without one.
    private struct Run {
        let task: Task<Void, Never>
        let store: SidebarStore
    }
    @ObservationIgnored private var tidyRuns: [UUID: Run] = [:]

    private init() {
        refresh()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TidyTabsService.shared.refresh() }
        }
    }

    func refresh() {
        let now = Self.currentStatus()
        if now != status { status = now }
    }

    private static func currentStatus() -> Status {
        // A test copy can stand in a fixed model (CRA_TIDY_FAKE_MODEL=1) where Apple Intelligence is off,
        // or show Settings as a Mac without it would (=off, =preparing, =ineligible).
        switch ProcessInfo.processInfo.environment["CRA_TIDY_FAKE_MODEL"] {
        case "1": return .available
        case "off": return .off
        case "preparing": return .preparing
        case "ineligible": return .ineligible
        default: break
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .off
            case .unavailable(.modelNotReady): return .preparing
            case .unavailable(.deviceNotEligible): return .ineligible
            case .unavailable: return .unavailable
            }
        }
        #endif
        // Apple Intelligence can't run here: the local model (if the user turned it on and the
        // file is in place) runs Tidy Titles, then the user's own provider stands in.
        if MaxLocal.isReady { return .local }
        if MaxRemote.isConfigured { return .remote }
        return .needsNewerMacOS
    }

    /// System Settings ▸ Apple Intelligence & Siri (the Siri-Settings extension's pane).
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.systemSettingsURL)
    }

    /// Whether the divider may show Tidy for this space now.
    func offers(_ sid: UUID, store: SidebarStore) -> Bool {
        pauseReason == nil && tabsAvailable && store.settings.tidyTabs && store.canTidy(sid)
    }

    /// Why Tidy Tabs is paused for now, in the divider's words. Only the local model can pause:
    /// Apple Intelligence and a provider run elsewhere and heat nothing here.
    var pauseReason: String? {
        guard status == .local, tabsAvailable else { return nil }
        return LocalRuntime.shared.tabsPauseReason
    }

    /// The Tidy button: ask the model about the space's loose Today tabs and apply its answer.
    /// Pressed again while it works, it cancels: the local 2B takes a minute or more per stage.
    func tidy(_ sid: UUID, store: SidebarStore) {
        if store.tidyingSpaces.contains(sid) {
            cancelTidy(sid, store: store)
            return
        }
        guard tabsAvailable else {
            CraLog.note("Tidy Tabs: declined (tabsAvailable=0)")
            return
        }
        // The local model is the only path that heats this Mac or maps 2 GB: hold Tabs while the
        // chassis is hot, memory is tight, or the model plus its headroom would not fit.
        if status == .local {
            let reason = LocalRuntime.shared.tabsPauseReason
                ?? (MaxLocal.modelURL.map { !LocalRuntime.shared.canLoadModel(at: $0) } == true
                    ? "Not enough free memory" : nil)
            if let reason {
                CraLog.note("Tidy Tabs: declined (\(reason))")
                store.setTidyNotice(sid, reason)
                return
            }
        }
        let loose = Array(store.looseTodayTabs(sid).prefix(TidyTabs.maximumTabs))
        guard !loose.isEmpty else {
            CraLog.note("Tidy Tabs: declined (no loose Today tabs)")
            return
        }
        let tabs = loose.map { item in
            TidyTabs.Tab(title: item.displayTitle, host: item.tab.flatMap { URL(string: $0.url)?.host() } ?? "")
        }
        let groups = store.tabGroups(in: sid).map { $0.title ?? "" }
        let ids = loose.map(\.id)
        let prompt = TidyTabs.prompt(tabs: tabs, existingGroups: groups)
        let local = status == .local
        store.setTidying(sid, true, stage: local ? .namingGroups : nil)
        let started = Date()
        let task = Task { @MainActor in
            // A cancelled run was already removed by cancelTidy; clearing here could wipe the
            // handle of a run started since.
            defer { if !Task.isCancelled { tidyRuns[sid] = nil } }
            // Two stages over the local 2B (topic names, then assignments); one call elsewhere.
            let proposals: [TidyTabs.Proposal]?
            if local {
                proposals = await MaxLocal.tidyTabs(tabs: tabs, existingGroups: groups) { stage in
                    store.setTidyStage(sid, stage)
                }
            } else {
                proposals = await Self.ask(prompt)
            }
            // Cancelled: cancelTidy has already put the divider back and nothing should land.
            guard !Task.isCancelled else { return }
            // Counts and time only: tab titles stay out of the log (it goes into diagnostics).
            CraLog.note(String(format: "Tidy Tabs: %d tabs, %d groups proposed in %.1f s", tabs.count, proposals?.count ?? -1,
                               Date().timeIntervalSince(started)))
            // The squiggle runs at least one full swing of the broom, so a quick answer doesn't flash.
            let rest = SidebarTidyMetrics.minimumRun - Date().timeIntervalSince(started)
            if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
            store.setTidying(sid, false)
            guard let proposals else {
                store.markTidied(sid)
                return
            }
            // The list slides the tabs under their new headers (SpaceListView.placeViews).
            store.applyTidy(TidyTabs.plan(proposals, tabCount: tabs.count, existingGroups: groups), tabIDs: ids, in: sid)
        }
        tidyRuns[sid] = Run(task: task, store: store)
    }

    /// The broom pressed while Tidy works: the wait ends, the helper exits, nothing is applied.
    func cancelTidy(_ sid: UUID, store: SidebarStore) {
        guard store.tidyingSpaces.contains(sid) else { return }
        CraLog.note("Tidy Tabs: cancelled")
        tidyRuns.removeValue(forKey: sid)?.task.cancel()
        store.setTidying(sid, false)
        // The helper answers one request at a time; ending it ends the read that waits on it.
        LocalInference.shared.cancelCurrent()
    }

    /// Every run ends: a memory warning takes the model process with it.
    func cancelAll() {
        for (sid, run) in Array(tidyRuns) { cancelTidy(sid, store: run.store) }
    }

    /// The model's groups, nil when it couldn't answer.
    private static func ask(_ prompt: String) async -> [TidyTabs.Proposal]? {
        if fakeModel { return await fakeAnswer(prompt) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.availability == .available {
            do {
                let session = LanguageModelSession(instructions: TidyTabs.instructions)
                let answer = try await session.respond(to: prompt, generating: TidyAnswer.self,
                                                       options: GenerationOptions(sampling: .greedy))
                return answer.content.groups.map { TidyTabs.Proposal(name: $0.name, tabs: $0.tabs) }
            } catch {
                CraLog.note("Tidy Tabs: the model failed: \(error)")
                return nil
            }
        }
        #endif
        // The user's own provider: same instructions, JSON reply parsed here
        // (the structured generation above is Apple's API alone).
        return await remoteAnswer(prompt)
    }

    /// Tidy Tabs over the user's OpenAI-compatible provider. The reply must be a JSON object
    /// {"groups": [{"name": "...", "tabs": [1, 2]}]}; anything else counts as no answer and
    /// CraCore's plan() never sees it.
    private static func remoteAnswer(_ prompt: String) async -> [TidyTabs.Proposal]? {
        guard MaxRemote.isConfigured else { return nil }
        let instructions = TidyTabs.instructions
            + "\n\nReply with a JSON object only: {\"groups\": [{\"name\": the group's name, \"tabs\": [the ids of its tabs]}]}."
        guard let content = await MaxRemote.ask(instructions: instructions, prompt: prompt, json: true) else { return nil }
        struct RemoteGroup: Decodable { let name: String; let tabs: [Int] }
        struct RemoteAnswer: Decodable { let groups: [RemoteGroup] }
        guard let data = content.data(using: .utf8), let answer = try? JSONDecoder().decode(RemoteAnswer.self, from: data) else {
            CraLog.note("Tidy Tabs: the provider's reply was not the expected JSON")
            return nil
        }
        return answer.groups.map { TidyTabs.Proposal(name: $0.name, tabs: $0.tabs) }
    }

    // MARK: Test model

    static let fakeModel = ProcessInfo.processInfo.environment["CRA_TIDY_FAKE_MODEL"] == "1"

    /// Groups tabs by site, named after it, after a model-like pause: enough to drive the UI in a
    /// test copy on a Mac without Apple Intelligence.
    private static func fakeAnswer(_ prompt: String) async -> [TidyTabs.Proposal] {
        try? await Task.sleep(for: .seconds(1.6))
        var bySite: [String: [Int]] = [:]
        var order: [String] = []
        for line in prompt.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":"), let id = Int(line[..<colon]),
                  let open = line.lastIndex(of: "("), line.hasSuffix(")") else { continue }
            let site = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
            if bySite[site] == nil { order.append(site) }
            bySite[site, default: []].append(id)
        }
        return order.map { TidyTabs.Proposal(name: $0.replacingOccurrences(of: "www.", with: ""), tabs: bySite[$0] ?? []) }
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct TidyAnswer {
    @Guide(description: "The groups, each with a name and the ids of its tabs")
    var groups: [TidyGroup]
}

@available(macOS 26.0, *)
@Generable
struct TidyGroup {
    @Guide(description: "What the tabs have in common, in one or two words, like a folder name: 'Planets', 'Trip to Lisbon', 'Cra Pull Requests'")
    var name: String
    @Guide(description: "Ids of every tab that belongs in this group")
    var tabs: [Int]
}
#endif
