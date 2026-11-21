import Foundation

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

    public struct DomainRule: Codable, Equatable, Identifiable, Sendable {
        public var domain: String
        public var group: String
        public var count: Int
        public var id: String { domain }
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

    /// Settings ▸ Max "clear": drops every learned rule (P5 记忆治理 — viewable and
    /// clearable, never silently accumulating).
    public mutating func clearAll() {
        entries = []
        domains = nil
    }

    /// Deletes one domain rule (per-rule management in Settings ▸ Max).
    public mutating func deleteDomainRule(domain: String, group: String) {
        domains?.removeAll { $0.domain == domain && $0.group == group }
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
