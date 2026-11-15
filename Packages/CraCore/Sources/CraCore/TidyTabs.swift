import Foundation

/// Arc's Tidy Tabs (Arc Max, `createUnpinnedTabGroups()`), done with the Mac's own Apple Intelligence
/// model instead of Arc's server. The divider's Tidy button sorts a space's loose Today tabs under
/// named group headers (Arc's `SidebarItemData.tabGroup`): the model only proposes names and members;
/// everything here decides what the sidebar does with that answer. Arc 1.171, 4 Nov 2026.
public enum TidyTabs {
    /// Arc 1.171 (canAutoOrganizeTodayTabs, offline copy, 4 Nov 2026): Tidy shows once Today holds six
    /// tabs, grouped ones included (five loose tabs: only Clear; two loose and six grouped: Tidy).
    public static let minimumTabs = 6
    /// A model answer can't hold a sidebar's worth of tabs: the on-device model reads ~4K
    /// tokens, and 60 titles + preferences + the two-stage prompt overflowed it — the model
    /// returned empty and the tidy silently did nothing (the user's "多标签不分类" report).
    /// 30 titles leave room to spare; leftovers wait for the next round (manual press or
    /// the auto-tick after its cooldown).
    public static let maximumTabs = 30
    static let maximumTitleLength = 80
    static let maximumNameLength = 32

    /// One loose Today tab as the model sees it: its place in the prompt is its id.
    public struct Tab: Equatable, Sendable {
        public var title: String
        public var host: String
        public init(title: String, host: String) {
            self.title = title
            self.host = host
        }
    }

    /// One group of the model's answer: tab ids from the prompt.
    public struct Proposal: Equatable, Sendable {
        public var name: String
        public var tabs: [Int]
        public init(name: String, tabs: [Int]) {
            self.name = name
            self.tabs = tabs
        }
    }

    /// What the sidebar does: new groups, in order, and tabs added to groups Today already has.
    public struct Plan: Equatable, Sendable {
        public var newGroups: [Proposal]
        /// Existing group index (as passed in) → tab ids joining it.
        public var joins: [Int: [Int]]
        public init(newGroups: [Proposal], joins: [Int: [Int]]) {
            self.newGroups = newGroups
            self.joins = joins
        }
        public var isEmpty: Bool { newGroups.isEmpty && joins.isEmpty }
    }

    /// Whether the divider offers Tidy: Today holds enough tabs, one of them loose, and a loose tab
    /// came in since the last run (`tidied`: Today's tabs then). Arc hid the button after a run, even
    /// one that grouped nothing, and a second click on that spot did nothing.
    public static func offers<ID: Hashable>(todayTabs: Int, looseTabs: [ID], tidied: Set<ID>?) -> Bool {
        guard todayTabs >= minimumTabs, !looseTabs.isEmpty else { return false }
        guard let tidied else { return true }
        return looseTabs.contains { !tidied.contains($0) }
    }

    public static let instructions = """
    You sort a person's open browser tabs into groups, like tidying loose papers into labelled folders. \
    Put tabs about the same topic, task or project in one group, even when they come from different websites. \
    Make two to six groups and give each tab to exactly one group if it fits; a group needs at least two tabs. \
    Name each group with the topic, not the website.
    """

    /// The request: Arc's "Here are my tabs, in the format 'id: title':", plus the site, and the
    /// groups Today already has so new tabs can join them (Arc does that on a second Tidy).
    public static func prompt(tabs: [Tab], existingGroups: [String],
                              preferences: [(title: String, group: String)] = []) -> String {
        var lines = ["Here are my tabs, as 'id: title (site)':"]
        for (i, t) in tabs.prefix(maximumTabs).enumerated() {
            let title = clip(t.title.isEmpty ? t.host : t.title, maximumTitleLength)
            lines.append(t.host.isEmpty ? "\(i): \(title)" : "\(i): \(title) (\(t.host))")
        }
        if !existingGroups.isEmpty {
            lines.append("")
            lines.append("I already have these groups; reuse a name exactly to add tabs to it: "
                         + existingGroups.map { "\"\($0)\"" }.joined(separator: ", ") + ".")
        }
        if !preferences.isEmpty {
            lines.append("")
            lines.append("Where I moved similar pages before (follow the same pattern when a tab clearly matches):")
            for pref in preferences.prefix(20) {
                lines.append("\"\(clip(pref.title, 60))\" → \"\(pref.group)\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The model's answer made safe: ids in range and used once (first group wins), names trimmed
    /// and capped, a name that matches an existing group (any case) adds to it, two new groups with
    /// one name merge, and a new group needs two tabs. New groups keep the order of their first tab.
    public static func plan(_ proposals: [Proposal], tabCount: Int, existingGroups: [String]) -> Plan {
        var used = Set<Int>()
        var joins: [Int: [Int]] = [:]
        var newGroups: [Proposal] = []
        let existing = existingGroups.map(key)
        for p in proposals {
            let name = clip(p.name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)), maximumNameLength)
            guard !name.isEmpty else { continue }
            var ids: [Int] = []
            for id in p.tabs where id >= 0 && id < min(tabCount, maximumTabs) && !used.contains(id) {
                used.insert(id)
                ids.append(id)
            }
            guard !ids.isEmpty else { continue }
            if let e = existing.firstIndex(of: key(name)) {
                joins[e, default: []].append(contentsOf: ids)
            } else if let n = newGroups.firstIndex(where: { key($0.name) == key(name) }) {
                newGroups[n].tabs.append(contentsOf: ids)
            } else {
                newGroups.append(Proposal(name: name, tabs: ids))
            }
        }
        newGroups = newGroups.filter { $0.tabs.count >= 2 }.map { Proposal(name: $0.name, tabs: $0.tabs.sorted()) }
        newGroups.sort { ($0.tabs.first ?? 0) < ($1.tabs.first ?? 0) }
        return Plan(newGroups: newGroups, joins: joins.mapValues { $0.sorted() })
    }

    /// Today's top level after a tidy: loose tabs left over first, in their order (Arc keeps new
    /// tabs above the groups), then the groups Today had, then the new ones. `Item` is either a loose
    /// tab or a group; `isGroup` tells them apart.
    public static func order<ID: Hashable>(today: [ID], isGroup: (ID) -> Bool, grouped: Set<ID>, newGroups: [ID]) -> [ID] {
        let loose = today.filter { !isGroup($0) && !grouped.contains($0) }
        let groups = today.filter(isGroup)
        return loose + groups + newGroups
    }

    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let one = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return one.count <= n ? one : String(one.prefix(n - 1)) + "…"
    }
}


/// What past tidy runs taught the model, so the next one keeps the user's pattern: accepted
/// assignments (tab title → group name), newest first, capped. ⌘Z of a tidy clears that run's
/// lesson; the user retraining the model is the point (the fork's addition).
public struct TidyPreferences: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var title: String
        public var group: String
        public init(title: String, group: String) {
            self.title = title
            self.group = group
        }
    }

    public var entries: [Entry] = []
    /// P5-L2 域级规则: a host moved into the same group twice becomes a rule
    /// ("aliyun.com → 云计算") — the tidy pre-assigns matching tabs deterministically and
    /// the model only sees the unknown rest. Optional: older files lack the key.
    public var domains: [DomainRule]?

    public static let cap = 40
    public static let domainCap = 20

    public init(entries: [Entry] = []) { self.entries = entries }

    public var domainRules: [DomainRule] { domains ?? [] }

    /// The L1 exact-title lesson (existing behavior).
    public mutating func record(_ assignments: [(title: String, group: String)]) {
        for a in assignments where !a.title.isEmpty && !a.group.isEmpty {
            entries.removeAll { $0.title == a.title }
            entries.insert(Entry(title: String(a.title.prefix(80)), group: String(a.group.prefix(32))), at: 0)
        }
        if entries.count > Self.cap { entries = Array(entries.prefix(Self.cap)) }
    }

    /// The P5 learning step behind every move into a group: the L1 exact-title lesson
    /// (existing) plus the L2 domain induction — the second move of one host into the same
    /// group turns into a rule, and a later correction to another group rewrites it.
    public mutating func recordMove(url: String, title: String, group: String) {
        record([(title: title, group: group)])
        guard !group.isEmpty, let host = URL(string: url)?.host, !host.isEmpty else { return }
        var rules = domains ?? []
        if let i = rules.firstIndex(where: { $0.domain == host && $0.group == group }) {
            rules[i].count += 1
        } else if let i = rules.firstIndex(where: { $0.domain == host }) {
            rules[i].group = group  // the latest correction wins for this domain
            rules[i].count = 1
        } else {
            rules.append(DomainRule(domain: host, group: group, count: 1))
            if rules.count > Self.domainCap { rules.removeFirst(rules.count - Self.domainCap) }
        }
        domains = rules
    }

    /// The domain's group when the rule has been confirmed by at least two moves.
    public func rule(forHost host: String) -> String? {
        let confirmed = domainRules.filter { $0.count >= Self.domainThreshold }
        return confirmed.first(where: { host == $0.domain || host.hasSuffix("." + $0.domain) })?.group
    }

    public struct DomainRule: Codable, Equatable, Sendable {
        public var domain: String
        public var group: String
        public var count: Int
        public init(domain: String, group: String, count: Int) {
            self.domain = domain
            self.group = group
            self.count = count
        }
    }
    public static let domainThreshold = 2

    public mutating func clear(groups: Set<String>) {
        entries.removeAll { groups.contains($0.group) }
    }

    /// ⌘Z of a tidy retracts exactly the lessons that run recorded — everything else
    /// (the model's whole learned history) stays.
    public mutating func retract(titles: [String]) {
        entries.removeAll { titles.contains($0.title) }
    }

    /// The user renamed a tab group: every lesson pointing at the old name follows the
    /// new one (the rename re-teaches the model, it doesn't fight it).
    public mutating func remapGroup(old: String, new: String) {
        for i in entries.indices where entries[i].group == old { entries[i].group = new }
    }

    public static func load(directory: URL, spaceID: UUID) -> TidyPreferences {
        let url = directory.appendingPathComponent("tidy-prefs-\(spaceID.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(TidyPreferences.self, from: data) else { return TidyPreferences() }
        return prefs
    }

    public func save(to directory: URL, spaceID: UUID) {
        let url = directory.appendingPathComponent("tidy-prefs-\(spaceID.uuidString).json")
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }

    public func remove(directory: URL, spaceID: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("tidy-prefs-\(spaceID.uuidString).json"))
    }
}
