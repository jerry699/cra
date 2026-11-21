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
<<<<<<< HEAD
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
            case .available: return "Max features run on Apple Intelligence on this Mac, so the model sends nothing anywhere."
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
=======
    static let shared: TidyTabsService = {
        let service = TidyTabsService()
        service.activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak service] _ in
            MainActor.assumeIsolated { service?.refresh() }
>>>>>>> origin/main
        }
        return service
    }()

    /// Where Apple Intelligence stands on this Mac, as Settings explains it (CraCore decides).
    typealias Status = AppleIntelligenceStatus

    /// Read again when Cra comes to the front and while Settings shows it, so turning Apple
    /// Intelligence on in System Settings shows the button without a relaunch.
<<<<<<< HEAD
    private(set) var status: Status = .needsNewerMacOS
    var modelAvailable: Bool { status == .available || status == .remote }

    /// Whether Tidy Tabs can run here: Apple Intelligence, the user's provider, or the local 2B.
    var tabsAvailable: Bool {
        modelAvailable || (status == .local && MaxLocal.canTidyTabs)
    }
=======
    private(set) var status: Status = .needsNewerMacOS {
        didSet {
            if status != .available {
                NotificationCenter.default.post(name: AskOnPage.unavailableNotification, object: self)
            }
        }
    }
    var modelAvailable: Bool { status == .available }
    /// Re-read where it matters (a download's rename, an Ask request and its answer), even before the
    /// cached status refreshes.
    var currentModelAvailable: Bool { Self.currentStatus() == .available }
    @ObservationIgnored var downloadsUnavailable: () -> Void = {}
    @ObservationIgnored var previewsUnavailable: () -> Void = {}
    @ObservationIgnored var titlesUnavailable: () -> Void = {}
>>>>>>> origin/main

    typealias Generate = @MainActor (TidyTabs.Request) async throws -> TidyTabsModel.Answer
    private struct Key: Hashable { let store: ObjectIdentifier; let space: UUID }
    private struct Run {
        let token = UUID()
        weak var store: SidebarStore?
        let today: UUID
        let started: Date
        var task: Task<Void, Never>?
        var delay: ScheduledWork?
    }
    /// A failure keeps the request it sent: Arc hides Tidy after any run, even one that grouped nothing.
    private enum Outcome { case success(TidyTabsModel.Answer), failure(TidyTabs.Request) }
    @ObservationIgnored private let generate: Generate
    @ObservationIgnored private let availability: (@MainActor () -> Bool)?
    @ObservationIgnored private var runs: [Key: Run] = [:]
    @ObservationIgnored private var activation: NSObjectProtocol?
    /// Tidy's work per space, so a second press on the broom cancels it; the store comes along so
    /// a memory warning can cancel every run without one.
    private struct Run {
        let task: Task<Void, Never>
        let store: SidebarStore
    }
    @ObservationIgnored private var tidyRuns: [UUID: Run] = [:]

    init(generate: Generate? = nil, modelAvailable: (@MainActor () -> Bool)? = nil) {
        self.generate = generate ?? Self.ask
        self.availability = modelAvailable
        refresh()
    }

    deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
        let pending = Array(runs)
        pending.forEach { $0.value.task?.cancel() }
        Task { @MainActor in
            for (key, run) in pending {
                run.delay?.cancel()
                run.store?.setTidying(key.space, false)
            }
        }
    }

    func refresh() {
        let now = Self.currentStatus()
        // Invalidate synchronously even if the unavailable status was already cached.
        if now != .available { cancelAll(); downloadsUnavailable(); previewsUnavailable(); titlesUnavailable() }
        if now != status { status = now }
        else if now != .available {
            // A repeated unavailable refresh must invalidate work even when the UI cache did not change.
            NotificationCenter.default.post(name: AskOnPage.unavailableNotification, object: self)
        }
    }

    func cancelAll(store: SidebarStore? = nil) {
        let owner = store.map(ObjectIdentifier.init)
        let keys = runs.keys.filter { owner == nil || $0.store == owner }
        for key in keys { if let token = runs[key]?.token { finish(key, token: token) } }
    }

    func cancel(_ sid: UUID, store: SidebarStore) {
        let key = Key(store: ObjectIdentifier(store), space: sid)
        if let token = runs[key]?.token { finish(key, token: token) }
    }

    private var eligibleModel: Bool { availability?() ?? currentModelAvailable }

    private static func currentStatus() -> Status {
        // A test copy can stand in a fixed model (CRA_TIDY_FAKE_MODEL=1) where Apple Intelligence is off,
        // or show Settings as a Mac without it would (=off, =preparing, =ineligible for Intel, =not-offered for
        // Apple silicon whose Apple Intelligence keeps the model from apps, as in China on macOS 27.3).
        switch ProcessInfo.processInfo.environment["CRA_TIDY_FAKE_MODEL"] {
        case "1": return .available
        case "off": return .off
        case "preparing": return .preparing
        case "ineligible": return Status(reason: .deviceNotEligible, hardware: .intel)
        case "not-offered": return Status(reason: .deviceNotEligible, hardware: .appleSilicon)
        default: break
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let reason: Status.Reason?
            switch SystemLanguageModel.default.availability {
            case .available: reason = nil
            case .unavailable(.appleIntelligenceNotEnabled): reason = .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady): reason = .modelNotReady
            case .unavailable(.deviceNotEligible): reason = .deviceNotEligible
            case .unavailable: reason = .other
            }
            return Status(reason: reason, hardware: hardware)
        }
        #endif
        // Apple Intelligence can't run here: the local model (if the user turned it on and the
        // file is in place) runs Tidy Titles, then the user's own provider stands in.
        if MaxLocal.isReady { return .local }
        if MaxRemote.isConfigured { return .remote }
        return .needsNewerMacOS
    }

    /// Apple silicon, the Intel copy under Rosetta, or an Intel Mac: FoundationModels says only that
    /// the device isn't eligible, which on Apple silicon means Apple doesn't offer apps the model (#538).
    private static let hardware: Status.Hardware = {
        func flag(_ name: String) -> Bool {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 && value == 1
        }
        #if arch(arm64)
        return .appleSilicon
        #else
        return flag("sysctl.proc_translated") ? .rosetta : .intel
        #endif
    }()

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

<<<<<<< HEAD
    /// The Tidy button: ask the model about the space's loose Today tabs and apply its answer.
    /// Pressed again while it works, it cancels: the local 2B takes a minute or more per stage.
    /// `auto` marks the poller's own runs — they announce themselves in the divider, or the
    /// user only ever sees the broom and never learns the tidying was automatic.
    func tidy(_ sid: UUID, store: SidebarStore, auto: Bool = false) {
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
        let allLoose = store.looseTodayTabs(sid)
        guard !allLoose.isEmpty else {
            CraLog.note("Tidy Tabs: declined (no loose Today tabs)")
            return
        }
        let groups = store.tabGroups(in: sid).map { $0.title ?? "" }

        // P5-L2 域级规则 pre-assign: tabs whose host has a learned rule go to their group
        // DETERMINISTICALLY, right here — the model never sees them, so the user's domain
        // patterns execute at 100 % and the model only handles the unknown rest.
        let preAssignPrefs = store.preferences[sid]
        var preAssigned: [(item: SidebarItem, group: String)] = []
        var unknown: [SidebarItem] = []
        for item in allLoose {
            let host = item.tab.flatMap { URL(string: $0.url)?.host() } ?? ""
            let title = item.title ?? ""
            // L2 domain rule first, then the L1 exact-title lesson (a page the user moved
            // by hand once is pre-assigned forever).
            let group = preAssignPrefs?.rule(forHost: host)
                ?? preAssignPrefs?.entries.first(where: { $0.title == title })?.group
            if let group, groups.contains(group) {
                preAssigned.append((item, group))
            } else {
                unknown.append(item)
            }
        }
        if !preAssigned.isEmpty {
            store.applyPreAssignment(preAssigned, in: sid)
            CraLog.note(String(format: "Tidy Tabs: %d tabs pre-assigned by domain rules", preAssigned.count))
        }
        let loose = Array(unknown.prefix(TidyTabs.maximumTabs))
        guard !loose.isEmpty else {
            // Every loose tab was pre-assigned by rules: no model call at all.
            CraLog.note(String(format: "Tidy Tabs: all %d tabs pre-assigned by domain rules — done without the model", preAssigned.count))
            store.markTidied(sid)
            store.setTidyNotice(sid, L10n.tr(String(format: "Auto-tidied %d tabs", preAssigned.count)), seconds: 8)
            return
        }
        if allLoose.count > loose.count {
            CraLog.note(String(format: "Tidy Tabs: %d loose tabs, handling the first %d — the rest wait for the next round",
                               allLoose.count, loose.count))
        }
=======
    /// The retained provider task completes after its outcome has scheduled/applied the minimum
    /// animation. The service also owns any remaining delay; settings and lifecycle cancellation
    /// invalidate both without waiting for an uncooperative provider.
    @discardableResult
    func tidy(_ sid: UUID, store: SidebarStore) -> Task<Void, Never>? {
        let key = Key(store: ObjectIdentifier(store), space: sid)
        if let old = runs[key], old.store !== store { finish(key, token: old.token) }
        guard store.settings.tidyTabs, eligibleModel, store.canTidy(sid),
              runs[key] == nil, !store.tidyingSpaces.contains(sid), let space = store.space(sid) else { return nil }
        let loose = store.tidyCandidates(sid).prefix(TidyTabs.maximumTabs)
>>>>>>> origin/main
        let tabs = loose.map { item in
            TidyTabs.Tab(id: item.id, title: item.displayTitle, host: item.tab.flatMap { URL(string: $0.url)?.host() } ?? "")
        }
<<<<<<< HEAD
        // Bootstrap the preference memory from the groups that exist: the ⌘Z wipe bug once
        // emptied it, and without those Chinese group names the model drifted to English
        // topic names (the user's report). Two to three tab titles per group as anchors.
        if store.preferences[sid]?.entries.isEmpty != false {
            var seeded: [(item: SidebarItem, group: String)] = []
            for g in store.tabGroups(in: sid) {
                let name = g.title ?? ""
                guard !name.isEmpty else { continue }
                for t in store.tabs(under: g.id).prefix(3) {
                    seeded.append((item: t, group: name))
                }
            }
            if !seeded.isEmpty { store.seedPreferences(spaceID: sid, entries: seeded) }
        }
        let ids = loose.map(\.id)
        let prefs = store.preferences[sid]?.entries.map { (title: $0.title, group: $0.group) } ?? []
        let prompt = TidyTabs.prompt(tabs: tabs, existingGroups: groups, preferences: prefs)
        let local = status == .local
        store.setTidying(sid, true, stage: local ? .namingGroups : nil)
        let started = Date()
        let task = Task { @MainActor in
            // A cancelled run was already removed by cancelTidy; clearing here could wipe the
            // handle of a run started since.
            defer { if !Task.isCancelled { tidyRuns[sid] = nil } }
            // Two stages over the local 2B (topic names, then assignments); one call elsewhere.
            // Local first; when the local run can't produce a plan (memory, heat, a model that
            // won't load), the user's own provider stands in — the user asked for that order.
            let proposals: [TidyTabs.Proposal]?
            if local {
                store.setTidyStage(sid, .namingGroups)
                let localPlan = await MaxLocal.tidyTabs(tabs: tabs, existingGroups: groups, preferences: prefs) { stage in
                    store.setTidyStage(sid, stage)
                }
                if let localPlan {
                    proposals = localPlan
                } else {
                    // The local run produced nothing (memory, heat, an unloadable model):
                    // the user's own provider stands in, as they asked.
                    store.setTidying(sid, true, stage: nil)
                    proposals = await Self.ask(prompt)
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
            let plan = TidyTabs.plan(proposals, tabCount: tabs.count, existingGroups: groups)
            CraLog.note(String(format: "Tidy Tabs: plan %d new groups, %d joins", plan.newGroups.count, plan.joins.count))
            store.applyTidy(plan, tabIDs: ids, in: sid)
            if plan.newGroups.isEmpty && plan.joins.isEmpty {
                // The model saw no shared topics (or answered one group per tab): leaving the
                // tabs as they were is honest — but the broom must not read as broken.
                store.setTidyNotice(sid, L10n.tr("These tabs don't share a topic — left as they are."), seconds: 8)
            } else if auto {
                // An automatic run says so in the divider — otherwise the tidying is invisible
                // and the broom reads like the only thing that ever triggers it.
                store.setTidyNotice(sid, L10n.tr(String(format: "Auto-tidied %d tabs", tabs.count)), seconds: 8)
            }
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

    // MARK: Auto-tidy (the fork's addition): Today fills up, Tidy runs on its own.

    static var autoTidyEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoTidyEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "autoTidyEnabled")
    }

    static func setAutoTidyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "autoTidyEnabled")
        CraLog.note(String(format: "Auto Tidy: %@", enabled ? "on" : "off"))
    }

    private var lastAutoTidy: [UUID: Date] = [:]

    /// Polled every few seconds by the app. Fires Tidy when a space's loose Today tabs cross
    /// the threshold (6): the local model is free and private, so running on its own is cheap.
    /// With auto-tidy off, a crossing points at the broom instead (the divider's notice).
    @MainActor func autoTick(store: SidebarStore) {
        let auto = Self.autoTidyEnabled
        for space in store.orderedSpaces {
            // Level-triggered, not edge-triggered: a crossing that lands in the cooldown or on a
            // busy model must not be lost — it fires as soon as the cooldown expires (the user saw
            // tidy "sometimes manual" when this was edge-based).
            let loose = store.looseTodayTabs(space.id).count
            guard loose >= TidyTabs.minimumTabs else { continue }
            guard !store.tidyingSpaces.contains(space.id) else {
                skipLog("a tidy is in flight", space.id, loose)
                continue
            }
            let cooled = Date().timeIntervalSince(lastAutoTidy[space.id] ?? .distantPast) > 600
            guard cooled else {
                skipLog(String(format: "cooling down (%.0f s left)", 600 - Date().timeIntervalSince(lastAutoTidy[space.id] ?? .distantPast)), space.id, loose)
                continue
            }
            if auto, offers(space.id, store: store) {
                CraLog.note(String(format: "Auto Tidy: %d loose tabs in %@ — running", loose, space.id.uuidString))
                lastAutoTidy[space.id] = Date()
                tidy(space.id, store: store, auto: true)
            } else if !auto, offers(space.id, store: store) {
                store.setTidyNotice(space.id, String(format: "%d tabs — the broom can tidy", loose))
            } else if auto {
                // Auto on, cooled, but the model declined (thermals, memory): say why, or
                // the broom sits there and the auto-tidy looks dead (the user's report).
                skipLog(pauseReason ?? "model declined (thermal/memory)", space.id, loose)
            }
        }
    }

    /// Why the auto-tidy didn't fire while the broom was up: at most every 30 s per reason,
    /// so the 3 s poll doesn't flood the log but a stuck state is always visible in it.
    private static var lastSkipLog: (reason: String, date: Date)?
    private func skipLog(_ reason: String, _ sid: UUID, _ loose: Int) {
        if let last = Self.lastSkipLog, last.reason == reason, Date().timeIntervalSince(last.date) < 30 { return }
        Self.lastSkipLog = (reason, Date())
        CraLog.note(String(format: "Auto Tidy: %d loose tabs — holding: %@", loose, reason))
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
=======
        let groups = store.tabGroups(in: sid).map { TidyTabs.ExistingGroup(id: $0.id, name: $0.title ?? "") }
        guard let request = TidyTabs.request(tabs: tabs, existingGroups: groups,
                                             maximumBytes: TidyTabsModel.promptByteLimit) else { return nil }
        let run = Run(store: store, today: space.todayContainerID, started: store.clock.now)
        runs[key] = run
        store.setTidying(sid, true)
        let generate = self.generate, token = run.token
        let task = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                do {
                    try Task.checkCancellation()
                    let answer = try await generate(request)
                    try Task.checkCancellation()
                    self?.generated(.success(answer), key: key, token: token)
                } catch is CancellationError {
                    self?.finish(key, token: token)
                } catch {
                    CraLog.note(error is TidyTabsModel.Failure ? "Tidy Tabs: model unavailable or context limit" : "Tidy Tabs: generation failed")
                    if Task.isCancelled { self?.finish(key, token: token) }
                    else { self?.generated(.failure(request), key: key, token: token) }
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in self?.finish(key, token: token) }
            }
        }
        runs[key]?.task = task
        return task
    }

    private func generated(_ outcome: Outcome, key: Key, token: UUID) {
        guard let run = runs[key], run.token == token else { return }
        runs[key]?.task = nil
        guard let store = run.store, eligible(key, run: run, store: store) else { finish(key, token: token); return }
        let rest = TidyTabs.minimumRun - store.clock.now.timeIntervalSince(run.started)
        if rest > 0 {
            runs[key]?.delay = store.clock.after(rest) { [weak self] in self?.apply(outcome, key: key, token: token) }
        } else { apply(outcome, key: key, token: token) }
    }

    private func eligible(_ key: Key, run: Run, store: SidebarStore) -> Bool {
        store.settings.tidyTabs && eligibleModel && !store.isIncognito(space: key.space)
            && store.space(key.space)?.todayContainerID == run.today && store.item(run.today) != nil
    }

    private func apply(_ outcome: Outcome, key: Key, token: UUID) {
        guard let run = runs[key], run.token == token else { return }
        guard let store = run.store, eligible(key, run: run, store: store) else { finish(key, token: token); return }
        switch outcome {
        case .success(let answer):
            // The adapter may have reduced this request: consume its actual fitted mapping only.
            let plan = answer.request.plan(answer.proposals)
            store.applyTidy(plan, tabIDs: answer.request.tabIDs, in: key.space)
            // What the run did: proposals are one per tab since the per-tab answer, so their count said nothing (#594).
            let names = TidyTabs.distinctNames(answer.proposals)
            CraLog.note("Tidy Tabs: completed \(answer.request.tabs.count) tabs, \(names) proposed groups, "
                + "\(plan.newGroups.count) new, \(plan.joins.values.reduce(0) { $0 + $1.count }) joined")
        case .failure(let request):
            store.markTidied(key.space, tabIDs: request.tabIDs)
        }
        finish(key, token: token)
    }

    private func finish(_ key: Key, token: UUID) {
        guard let run = runs[key], run.token == token else { return }
        runs[key] = nil
        run.store?.setTidying(key.space, false)
        run.delay?.cancel()
        run.task?.cancel()
    }

    private static func ask(_ request: TidyTabs.Request) async throws -> TidyTabsModel.Answer {
        if fakeModel { return try await fakeAnswer(request) }
        return try await TidyTabsModel.group(request)
>>>>>>> origin/main
    }

    // MARK: Test model

    static let fakeModel = ProcessInfo.processInfo.environment["CRA_TIDY_FAKE_MODEL"] == "1"

    /// Groups tabs by site, named after it, after a model-like pause: enough to drive the UI in a
    /// test copy on a Mac without Apple Intelligence.
    private static func fakeAnswer(_ request: TidyTabs.Request) async throws -> TidyTabsModel.Answer {
        try await Task.sleep(for: .seconds(1.6))
        var bySite: [String: [Int]] = [:]
        var order: [String] = []
        for (id, tab) in request.tabs.enumerated() {
            let site = tab.host.isEmpty ? "Tabs" : tab.host
            if bySite[site] == nil { order.append(site) }
            bySite[site, default: []].append(id)
        }
        return TidyTabsModel.Answer(request: request, proposals: order.map {
            TidyTabs.Proposal(name: $0.replacingOccurrences(of: "www.", with: ""), tabs: bySite[$0] ?? [])
        })
    }
}
