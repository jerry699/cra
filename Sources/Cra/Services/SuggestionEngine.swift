import Foundation

enum SuggestionKind: Equatable {
    case switchToTab(UUID)
    case archived(UUID)
    case history
    case navigate
    case search
    case topDomain
    case command(String)
    case switchSpace(UUID)
    case moveToSpace(UUID)
    case moveToFolder(UUID)
}

struct Suggestion: Identifiable, Equatable {
    let id: String
    let kind: SuggestionKind
    let title: String
    var subtitle: String
    let url: String?
    var faviconKey: String?
    let symbol: String?
    let trailing: String?
    var score: Double
    var spaceID: UUID? = nil
    /// Matched only as scattered letters ("pota" in "grænselandsPOrTAl"): listed after the
    /// search engine's suggestions, which Arc shows instead of such matches.
    var loose = false
    var tabID: UUID? {
        if case .switchToTab(let id) = kind { return id }
        return nil
    }
}

struct SuggestionResult {
    var items: [Suggestion] = []
    /// Host (or more) to complete the typed text to, e.g. "github.com".
    var inlineCompletion: String?
    /// What Tab scopes the bar to ("Search YouTube  Tab", "Search Tabs  Tab").
    var scope: CommandBarScope?
    var query: String = ""
}

/// What makes ⌘T feel like Arc: open tabs, archived tabs, history, the
/// typed URL or search, popular domains and commands, ranked with
/// recency/frequency/learned signals (Arc: CommandBarRanking*).
@MainActor
final class SuggestionEngine {
    unowned let store: SidebarStore
    unowned let bindings: KeyBindingRegistry
    private let remote = SearchSuggestions()
    /// Arc's command bar always lists five rows; search suggestions make up what the
    /// tabs, history and commands don't fill, so the bar keeps its height while you type.
    static let maxRows = 5

    init(store: SidebarStore, bindings: KeyBindingRegistry) {
        self.store = store
        self.bindings = bindings
    }

    // MARK: Entry

    /// `spaceShown` is the space the bar's window shows, which "Switch to" leaves out: a Little
    /// Window's own target (#316); nil, the focused space.
    func suggestions(for rawQuery: String, mode: CommandBarMode, currentTabID: UUID?, spaceShown: UUID? = nil) -> SuggestionResult {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        let q = query.lowercased()
        var result = SuggestionResult(query: query)
        barProfile = profile(spaceShown: spaceShown)
        if q.isEmpty {
            result.items = Array(recentSuggestions(excluding: currentTabID).prefix(Self.maxRows))
            // Tab on the empty field lists the actions (Arc's typeTravel), with no hint at the end of it.
            result.scope = .actions
            return result
        }

        var items: [Suggestion] = []
        let typed = typedRow(query: query)
        // One clock reading for the keystroke, not two per matching row (#617).
        now = Date()
        items.append(contentsOf: tabSuggestions(q, excluding: currentTabID))
        // Incognito: the window's own tabs, search and commands; nothing from the normal profile.
        if !incognito {
            items.append(contentsOf: archiveSuggestions(q))
            // P3-R2: keyword and semantic vote separately, then fuse by URL — a page found
            // by BOTH outranks either alone (RRF-flavored: two independent rankers agreeing
            // is the strongest signal we have).
            items.append(contentsOf: historyAndSemanticSuggestions(q, openURLs: searchIndex.openURLs))
            items.append(contentsOf: topDomainSuggestions(q))
        }
        items.append(contentsOf: commandSuggestions(q, currentTabID: currentTabID, spaceShown: spaceShown))

        // Learned: the user picked this URL for this query before.
        if let learned = store.ranking.queriesToSelected[q] {
            for i in items.indices where items[i].url == learned { items[i].score += 150 }
        }

        items = dedupe(items)
        // Stable: equal scores keep their order (tabs, archive, history, domains, then commands
        // in menu order), so "clear" lists Clear Cache before Clear Cookies, as Arc does.
        // Sorted as indices, then the rows taken in that order once: sorting thousands of Suggestion values moved
        // each many times (#617). The same stable order.
        let order = items.indices.sorted { a, b in items[a].score != items[b].score ? items[a].score > items[b].score : a < b }
        items = order.map { items[$0] }

        // Arc's order: the row that supplies the inline completion comes first,
        // then what you typed, then everything else.
        let completion = inlineCompletion(q, candidates: items)
        if let completion, let idx = items.firstIndex(where: { $0.id == completion.candidateID }) {
            let c = items.remove(at: idx)
            items.insert(c, at: 0)
            items.insert(typed, at: 1)
        } else if let top = items.first, case .command = top.kind, top.score >= 68 {
            // Arc 1.171 lists a command the text names above it too: "sett" → Settings,
            // "clear" → Clear Cache and Refresh, "clear cook" → Clear Cookies and Refresh.
            items.insert(typed, at: 1)
        } else {
            items.insert(typed, at: 0)
        }
        if store.settings.searchSuggestions {
            let at = items.firstIndex(where: \.loose) ?? items.count
            if at < Self.maxRows {
                items.insert(contentsOf: searchSuggestions(query, after: items).prefix(Self.maxRows - at), at: at)
            }
        }
        // Rows are scored without their subtitles; only the ones shown get them (#617).
        result.items = items.prefix(Self.maxRows).map(finished)
        result.inlineCompletion = completion?.text
        result.scope = TabSearchScope.isOffered(by: query) ? .tabs
            : SiteSearch.match(q, completion: completion?.text, keywords: engines.keywords).map(CommandBarScope.site)
        return result
    }

    /// The bar scoped to a site (after Tab): one row, the typed text searched there.
    func suggestions(for rawQuery: String, in site: SiteSearch) -> SuggestionResult {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        var result = SuggestionResult(query: query)
        guard !query.isEmpty else { return result }
        result.items = [Suggestion(id: "typed", kind: .search, title: query, subtitle: L10n.tr("Search %@", site.name), url: site.searchURL(query),
                                   faviconKey: nil, symbol: "magnifyingglass", trailing: nil, score: 1000)]
        return result
    }

    /// The bar scoped to a space's open tabs ("%" Tab): its favorites, pinned and today tabs but
    /// the one in front, and nothing from history, the archive or the network.
    func suggestions(for rawQuery: String, inTabsOf spaceID: UUID, currentTabID: UUID?) -> SuggestionResult {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        let q = query.lowercased()
        var result = SuggestionResult(query: query)
        let tabs = store.visibleTabs(in: spaceID).filter { $0.id != currentTabID && $0.tab != nil }
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ranked = TabSearchScope.rank(tabs.map { tab in
            TabSearchScope.Candidate(id: tab.id, score: q.isEmpty ? 0 : textScore(q, title: tab.displayTitle, url: tab.tab?.url ?? ""),
                                     lastActive: tab.tab?.timeLastActiveAt)
        }, typed: !q.isEmpty)
        result.items = ranked.prefix(Self.maxRows).compactMap { byID[$0] }.map { tab in
            Suggestion(id: "tab:\(tab.id)", kind: .switchToTab(tab.id), title: tab.displayTitle, subtitle: Self.humanURL(tab.tab?.url ?? ""),
                       url: tab.tab?.url, faviconKey: tab.tab?.faviconKey, symbol: nil, trailing: L10n.tr("Switch to Tab"), score: 0, spaceID: spaceID)
        }
        return result
    }

    /// The bar scoped to actions (Tab on the empty field, Arc's typeTravel): commands, space
    /// switches and moves, the most used first, narrowed by what is typed.
    func suggestions(forActionsMatching rawQuery: String, currentTabID: UUID?, spaceShown: UUID? = nil) -> SuggestionResult {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        let q = query.lowercased()
        var result = SuggestionResult(query: query)
        let rows = actionRows(q, currentTabID: currentTabID, spaceShown: spaceShown).filter { row in
            if case .command(let id) = row.suggestion.kind { return ActionSearchScope.lists(actionID: id) }
            return true
        }
        let ranked = ActionSearchScope.rank(rows.indices.map {
            ActionSearchScope.Candidate(id: $0, score: rows[$0].suggestion.score, uses: rows[$0].uses)
        }, typed: !q.isEmpty)
        result.items = ranked.prefix(Self.maxRows).map { rows[$0].suggestion }
        return result
    }

    // MARK: Search index

    /// What scoring needs from a title and a URL. Worked out per keystroke for every tab,
    /// archived tab and history entry (a URL parse each) it held up typing in the command bar.
<<<<<<< HEAD
    struct Searchable {
        let title: String
        let words: [Substring]
        let url: String
        let host: String
        let bareHost: String
        /// The page's body-text snapshot (P3 索引增肥), lowercased — content words like
        /// 董事长 live here, never in the title. Nil for tabs/archive entries.
        let snippet: String?

        init(title: String, url: String, snippet: String? = nil) {
            self.title = title.lowercased()
            words = self.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            self.url = SuggestionEngine.humanURL(url).lowercased()
            host = (URL(string: url)?.host ?? "").lowercased()
            bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            self.snippet = snippet?.lowercased()
        }
    }
=======
    /// A row's text for scoring, prepared once per bar opening (CraCore CommandBarScore, #617).
    typealias Searchable = CommandBarScore.Key
>>>>>>> origin/main

    private struct SearchIndex {
        var tabs: [(SidebarItem, Searchable)] = []
        var archive: [(ArchivedItem, Searchable)] = []
        var history: [(HistoryEntry, Searchable)] = []
        var openURLs: Set<String> = []
        /// The profile its archive and history rows are limited to (#609).
        var profile: UUID?
        /// Each row's CommandBarDedupe keys, by its row id: an address parsed once per opening, not per keystroke.
        var dedupeKeys: [String: [String]] = [:]
        /// Each row's Suggestion id ("tab:<uuid>"…), made once per opening, in the order of `tabs`, `archive`, `history`.
        var tabIDs: [String] = [], archiveIDs: [String] = [], historyIDs: [String] = []
    }

    private var index: SearchIndex?
    /// The profile of the space the bar is in: its archive and history rows are that profile's (#609).
    private var barProfile: UUID?

    private func profile(spaceShown: UUID?) -> UUID? { store.profileID(space: spaceShown ?? store.focusedSpaceID) }

    /// What the index is made of, read on the main thread: the rows and the text their keys come from.
    private struct IndexRows {
        let tabs: [SidebarItem], archive: [ArchivedItem], history: [HistoryEntry]
        let profile: UUID?
        let text: [(title: String, url: String)]
        /// Each row's id, address and title as its Suggestion has them, for its dedupe keys.
        let rowIDs: [(id: String, url: String, title: String)]
    }

    private func indexRows(profile: UUID?) -> IndexRows {
        let tabs = commandBarTabs().filter { $0.tab != nil }
        let archive = Array(store.archive.filter { $0.item.tab != nil && suggests($0, on: profile) })
        let history = store.history.values.filter { CommandBarProfileScope.suggests($0, on: profile) }
        return IndexRows(tabs: tabs, archive: archive, history: history, profile: profile,
                         text: tabs.map { ($0.displayTitle, $0.tab!.url) } + archive.map { ($0.item.displayTitle, $0.item.tab!.url) }
                               + history.map { ($0.title, $0.url) },
                         rowIDs: tabs.map { ("tab:\($0.id)", $0.tab!.url, $0.displayTitle) }
                               + archive.map { ("arch:\($0.id)", $0.item.tab!.url, $0.item.displayTitle) }
                               + history.map { ("hist:\($0.url)", $0.url, $0.title.isEmpty ? Self.humanURL($0.url) : $0.title) })
    }

    /// The index's per-row work, done off the main thread when the bar opens: search keys and dedupe keys.
    nonisolated private static func rowKeys(_ rows: (text: [(title: String, url: String)], ids: [(id: String, url: String, title: String)]))
        -> (keys: [Searchable], dedupe: [String: [String]]) {
        let keys = searchables(rows.text)
        var dedupe: [String: [String]] = [:]
        dedupe.reserveCapacity(rows.ids.count)
        for r in rows.ids { dedupe[r.id] = CommandBarDedupe.keys(id: r.id, url: r.url, title: r.title) }
        return (keys, dedupe)
    }

    private static func index(_ rows: IndexRows, keys: (keys: [Searchable], dedupe: [String: [String]])) -> SearchIndex {
        var i = SearchIndex()
<<<<<<< HEAD
        let tabs = commandBarTabs()
        i.tabs = tabs.compactMap { tab in tab.tab.map { (tab, Searchable(title: tab.displayTitle, url: $0.url)) } }
        i.openURLs = Set(tabs.compactMap { $0.tab?.url })
        i.archive = store.archive.prefix(400).compactMap { e in e.item.tab.map { (e, Searchable(title: e.item.displayTitle, url: $0.url)) } }
        i.history = store.history.values.map { ($0, Searchable(title: $0.title, url: $0.url, snippet: $0.contentSnippet)) }
=======
        i.dedupeKeys = keys.dedupe
        let keys = keys.keys
        let ids = rows.rowIDs.map(\.id), nt = rows.tabs.count, na = rows.archive.count
        i.tabIDs = Array(ids[0..<nt]); i.archiveIDs = Array(ids[nt..<(nt + na)]); i.historyIDs = Array(ids[(nt + na)...])
        let t = rows.tabs.count, a = rows.archive.count
        i.tabs = Array(zip(rows.tabs, keys[0..<t]))
        i.archive = Array(zip(rows.archive, keys[t..<(t + a)]))
        i.history = Array(zip(rows.history, keys[(t + a)...]))
        i.openURLs = Set(rows.tabs.compactMap { $0.tab?.url })
        i.profile = rows.profile
        return i
    }

    /// An archived tab is suggested on the profile of the space it was closed in (#609).
    private func suggests(_ entry: ArchivedItem, on profile: UUID?) -> Bool {
        CommandBarProfileScope.suggests(archivedFrom: entry.sourceSpaceID.map { store.profileID(space: $0) }, on: profile)
    }

    /// Which opening of the bar an index is for: one built for an earlier opening is dropped.
    private var indexGeneration = 0

    /// The bar opened: its rows are read now and their keys built off the main thread (on every core), so the
    /// first keystroke finds the index ready (#617). A keystroke before it is ready builds it then, as before.
    func prepareIndex() {
        guard index == nil else { return }
        let rows = indexRows(profile: profile(spaceShown: nil)), generation = indexGeneration, work = (text: rows.text, ids: rows.rowIDs)
        DispatchQueue.global(qos: .userInitiated).async {
            let keys = Self.rowKeys(work)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.indexGeneration == generation, self.index == nil else { return }
                    self.index = Self.index(rows, keys: keys)
                }
            }
        }
    }

    /// Built when the bar opens (prepareIndex) or on its first keystroke, kept until it closes.
    private var searchIndex: SearchIndex {
        if let index, index.profile == barProfile { return index }
        let rows = indexRows(profile: barProfile)
        // The keys (lowercasing, words, bytes, the host) are built on every core at once (#617).
        let i = Self.index(rows, keys: Self.rowKeys((text: rows.text, ids: rows.rowIDs)))
>>>>>>> origin/main
        index = i
        return i
    }

    /// The command bar opened or closed: what it searches may have changed since.
    func resetIndex() {
        index = nil
        indexGeneration &+= 1
        enginesRead = nil
        remote.reset()
    }

    // MARK: Search engines

    private var enginesRead: (default: ChromiumSearchEngine, keywords: [ChromiumSearchEngine])?

    func watchSearchEngines(onChange: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        SearchEngines.shared.watchKeywords(profilePath: store.profilePath(space: store.focusedSpaceID)) { [weak self] in
            guard let self, let previous = self.enginesRead else { return }
            self.enginesRead = nil
            if self.engines != previous { onChange() }
        }
    }

    /// Chromium's, in the window's space's profile (an incognito window's are its Default's),
    /// cached while the bar is open. The default is the space's own engine where it has one (#306).
    private var engines: (default: ChromiumSearchEngine, keywords: [ChromiumSearchEngine]) {
        if let enginesRead { return enginesRead }
        let space = store.focusedSpaceID
        let profile = store.profilePath(space: space)
        let keywords = SearchEngines.shared.keywords(profilePath: profile)
        let fallback = SearchEngines.shared.defaultEngine(profilePath: profile, legacy: store.settings.searchEngine)
        let read = (ChromiumSearchEngine.forSpace(keyword: store.space(space)?.searchEngine, default: fallback, among: keywords), keywords)
        enginesRead = read
        return read
    }

    /// Where typed text that isn't an address is searched.
    var searchEngine: ChromiumSearchEngine { engines.default }

    func searchURL(_ text: String) -> String { engines.default.searchURL(text) }

    // Semantic history matches (the fork's addition): the query embedded locally, scored
    // against the history index. Fetched like the remote suggestions — `done` re-lists.
    private var semantic: (query: String, rows: [Suggestion])?

    /// Asks the local embedding model about `rawQuery`; `done` runs when the matches are in.
    func fetchSemanticSuggestions(for rawQuery: String, done: @escaping @MainActor () -> Void) {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        CraLog.note(String(format: "Semantic: fetch '%@' (incognito=%d, docs=%d)",
                           query, incognito ? 1 : 0, EmbeddingService.shared.documentURLs().count))
        guard !incognito, query.count >= 2, !query.contains("://") else {
            CraLog.note("Semantic: skipped (incognito or short query)")
            return
        }
        guard semantic?.query != query.lowercased() else {
            CraLog.note("Semantic: cache hit, no refetch")
            return
        }
        Task { @MainActor in
            let matches = await EmbeddingService.shared.search(query, limit: 4)
            CraLog.note(String(format: "Semantic: %d matches for '%@'", matches.count, query))
            guard !matches.isEmpty else { return }
            let rows = matches.compactMap { m -> Suggestion? in
                guard let entry = store.history[m.url] else { return nil }
                return Suggestion(id: "sem:\(m.url)", kind: .history, title: entry.title,
                                  subtitle: String(format: "%.2f · 语义匹配", m.score), url: m.url,
                                  faviconKey: entry.title.isEmpty ? nil : entry.title,
                                  symbol: nil, trailing: L10n.tr("Semantic match"), score: 40)
            }
            semantic = (query: query.lowercased(), rows: rows)
            done()
        }
    }

    /// The stored semantic rows for this query, exact match on the lowercased query.
    func semanticSuggestions(_ query: String) -> [Suggestion] {
        guard let semantic, semantic.query == query.lowercased() else { return [] }
        return semantic.rows
    }

    /// Asks the search engine about `rawQuery`; `done` runs when its answer is in, to list again.
    func fetchSearchSuggestions(for rawQuery: String, done: @escaping @MainActor () -> Void) {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard store.settings.searchSuggestions, !query.isEmpty, !query.contains("://") else { return }
        remote.fetch(query, engine: searchEngine, done: done)
    }

    /// The engine's suggestions not already listed, as search rows (or site rows).
    private func searchSuggestions(_ query: String, after items: [Suggestion]) -> [Suggestion] {
        let engine = searchEngine
        let titles = Set(items.map { $0.title.lowercased() })
        let urls = Set(items.compactMap(\.url))
        return remote.items(for: query, engine: engine).compactMap { r in
            let t = r.text.lowercased()
            guard t != query.lowercased(), !titles.contains(t) else { return nil }
            guard let url = r.url else {
                return Suggestion(id: "sugg:\(t)", kind: .search, title: r.text, subtitle: "", url: engine.searchURL(r.text),
                                  faviconKey: nil, symbol: "magnifyingglass", trailing: nil, score: 0)
            }
            guard !urls.contains(url) else { return nil }
            return Suggestion(id: "sugg:\(url)", kind: .history, title: r.text, subtitle: "", url: url,
                              faviconKey: FaviconKey.key(for: url), symbol: "globe", trailing: nil, score: 0)
        }
    }

    // MARK: Typed text

    static func looksLikeURL(_ s: String) -> Bool { TypedURL.looksLikeURL(s) }

    static func urlFromInput(_ s: String) -> String { TypedURL.fromInput(s) }

    private func typedRow(query: String) -> Suggestion {
        if Self.looksLikeURL(query) {
            let url = Self.urlFromInput(query)
            return Suggestion(id: "typed", kind: .navigate, title: query, subtitle: L10n.tr("Open URL"), url: url,
                              faviconKey: FaviconKey.key(for: url), symbol: "globe", trailing: nil, score: 1000)
        }
        let engine = searchEngine
        return Suggestion(id: "typed", kind: .search, title: query, subtitle: L10n.tr("Search %@", engine.name),
                          url: engine.searchURL(query), faviconKey: nil, symbol: "magnifyingglass", trailing: nil, score: 1000)
    }

    // MARK: Sources

    /// The command bar is open in an incognito window (it acts on the window in use).
    private var incognito: Bool { store.window().isIncognito }

    /// The "New …" command the bar offers: the focused space's profile's choice (#375).
    var newDocumentApp: NewDocumentApp? {
        store.settings.newDocumentCommand(profileID: store.profileID(space: store.focusedSpaceID), incognito: incognito)
    }

    private func tabSuggestions(_ q: String, excluding current: UUID?) -> [Suggestion] {
        var out: [Suggestion] = []
        let index = searchIndex
        for (n, (tab, key)) in index.tabs.enumerated() where tab.id != current {
            guard let t = tab.tab else { continue }
            var score = Self.score(q, key)
            let loose = score < Self.looseBelow && !(tab.title?.lowercased().hasPrefix(q) ?? false)
            if let custom = tab.title?.lowercased(), custom.hasPrefix(q) { score += 40 }
            if score < 30 { continue }
            score += recencyBoost(t.timeLastActiveAt)
<<<<<<< HEAD
            let switches = store.ranking.recentlySwitchedToTabs[tab.id]?.filter { $0 > Date().addingTimeInterval(-7 * 86400) }.count ?? 0
            score += Double(min(switches, 10)) * 3
            let sid = store.spaceID(ofItem: tab.id)
            let spaceName = sid.flatMap { store.space($0)?.title } ?? ""
            let pinned = store.isPinned(tab.id)
            out.append(Suggestion(id: "tab:\(tab.id)", kind: .switchToTab(tab.id), title: tab.displayTitle,
                                  subtitle: [spaceName, pinned ? L10n.tr("Pinned") : "", Self.humanURL(t.url)].filter { !$0.isEmpty }.joined(separator: " · "),
                                  url: t.url, faviconKey: t.faviconKey, symbol: nil, trailing: L10n.tr("Switch to Tab"), score: score, spaceID: sid, loose: loose))
=======
            score += Double(CommandBarRanking.recentSwitches(store.ranking.recentlySwitchedToTabs[tab.id], now: now)) * 3
            // Its space, pin and subtitle come in `finished`, for the rows shown (#617).
            out.append(Suggestion(id: index.tabIDs[n], kind: .switchToTab(tab.id), title: tab.displayTitle, subtitle: "",
                                  url: t.url, faviconKey: t.faviconKey, symbol: nil, trailing: "Switch to Tab", score: score, loose: loose))
>>>>>>> origin/main
        }
        return out
    }

    /// Below this a text score means only scattered letters matched (`fuzzy`).
    private static let looseBelow = 50.0

    private func archiveSuggestions(_ q: String) -> [Suggestion] {
        var out: [Suggestion] = []
        let index = searchIndex
        for (n, (entry, key)) in index.archive.enumerated() {
            guard let t = entry.item.tab else { continue }
            let text = Self.score(q, key)
            var score = text * 0.85
            if score < 30 { continue }
            score += recencyBoost(entry.archivedAt) * 0.5
<<<<<<< HEAD
            let spaceName = entry.sourceSpaceID.flatMap { store.space($0)?.title } ?? ""
            out.append(Suggestion(id: "arch:\(entry.id)", kind: .archived(entry.id), title: entry.item.displayTitle,
                                  subtitle: [L10n.tr("Archived %@", Self.relative(entry.archivedAt)), spaceName, Self.humanURL(t.url)].filter { !$0.isEmpty }.joined(separator: " · "),
                                  url: t.url, faviconKey: t.faviconKey, symbol: nil, trailing: L10n.tr("Restore"), score: score,
=======
            out.append(Suggestion(id: index.archiveIDs[n], kind: .archived(entry.id), title: entry.item.displayTitle, subtitle: "",
                                  url: t.url, faviconKey: t.faviconKey, symbol: nil, trailing: "Restore", score: score,
>>>>>>> origin/main
                                  loose: text < Self.looseBelow))
        }
        return out
    }

    private func historySuggestions(_ q: String, openURLs: Set<String>) -> [Suggestion] {
        var out: [Suggestion] = []
        let index = searchIndex
        for (n, (h, key)) in index.history.enumerated() where !openURLs.contains(h.url) {
            let text = Self.score(q, key)
            var score = text * 0.8
            if score < 30 { continue }
<<<<<<< HEAD
            score += behaviorBoost(h)
            out.append(Suggestion(id: "hist:\(h.url)", kind: .history, title: h.title.isEmpty ? Self.humanURL(h.url) : h.title,
                                  subtitle: Self.humanURL(h.url), url: h.url, faviconKey: FaviconKey.key(for: h.url),
=======
            score += min(Double(h.visitCount), 20) * 1.5 + recencyBoost(h.lastVisit) * 0.6
            // Its favicon key (an address parse) comes in `finished`, for the rows shown (#617).
            out.append(Suggestion(id: index.historyIDs[n], kind: .history, title: h.title.isEmpty ? Self.humanURL(h.url) : h.title,
                                  subtitle: "", url: h.url, faviconKey: nil,
>>>>>>> origin/main
                                  symbol: "clock", trailing: nil, score: score, loose: text < Self.looseBelow))
        }
        return out
    }

    /// P3-R2 行为信号: dwell seconds and visits say "认真看完" vs "点进去秒退" — up to
    /// +20 combined, a ranking signal no embedding can fake.
    private func behaviorBoost(_ h: HistoryEntry) -> Double {
        min(Double(h.visitCount), 20) * 1.5 + recencyBoost(h.lastVisit) * 0.6
            + min(Double(h.dwellTime ?? 0) / 60.0, 4.0) * 5.0
    }

    /// P3-R2: keyword and semantic vote separately, then fuse by URL — a page found by BOTH
    /// (the query word is ON the page AND it's semantically close) outranks either alone.
    /// Semantic-only rows carry a recency/visit/dwell boost too, so a forgotten page the
    /// user actually read still surfaces. Time slots ("上周那款手表") filter by lastVisit.
    private func historyAndSemanticSuggestions(_ q: String, openURLs: Set<String>) -> [Suggestion] {
        // Time slot: leading 昨天/今天/上周/本周/最近 narrows lastVisit and drops from the query.
        var term = q
        var window: (from: Date, to: Date?)?
        let now = Date()
        let day = 86_400.0
        let slots: [(String, Double, Double?)] = [("昨天", 2*day, day), ("今天", day, nil),
                                                  ("上周", 14*day, 7*day), ("本周", 7*day, nil),
                                                  ("最近", 7*day, nil), ("最近几天", 4*day, nil)]
        for (token, fromDays, toDays) in slots where term.hasPrefix(token) {
            window = (now.addingTimeInterval(-fromDays), toDays.map { now.addingTimeInterval(-$0) })
            term = String(term.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        var keyword: [Suggestion] = []
        for (h, key) in searchIndex.history where !openURLs.contains(h.url) {
            if let window, h.lastVisit < window.from || (window.to != nil && h.lastVisit > window.to!) { continue }
            let text = Self.score(term.isEmpty ? q : term, key)
            // The content snippet carries words (董事长) that title/url can't — a snippet
            // hit alone is a solid vote (60-scale), gated to real-word queries.
            var snippetHit = false
            if text < 60, term.count >= 2, let snippet = key.snippet, snippet.contains(term) {
                snippetHit = true
            }
            var score = max(text * 0.8, snippetHit ? 48 : 0)
            if score < 30, !snippetHit { continue }
            score += behaviorBoost(h)
            keyword.append(Suggestion(id: "hist:\(h.url)", kind: .history, title: h.title.isEmpty ? Self.humanURL(h.url) : h.title,
                                      subtitle: Self.humanURL(h.url), url: h.url, faviconKey: FaviconKey.key(for: h.url),
                                      symbol: "clock", trailing: nil, score: score, loose: text < Self.looseBelow && !snippetHit))
        }
        keyword.sort { $0.score > $1.score }
        let semantic = semanticSuggestions(term.isEmpty ? q : term)

        // P3-R2 RRF fusion (eval-tuned, scripts/recall-eval.py grid): each ranker votes
        // 1/(60 + rank), the keyword vote weighted 1.2 — hit@1 15/31, hit@4 20/31 vs the
        // additive mix's 14/18 and semantic-only's 11/15. Rank-based votes don't care that
        // the two rankers' raw scores live on different scales. Behavior boost stays as a
        // small tie-breaker on top (×0.1: it must not outweigh a rank step).
        func rrf(_ rank: Int, _ weight: Double) -> Double { weight / Double(60 + rank) }
        var votes: [String: (score: Double, both: Bool, row: Suggestion)] = [:]
        for (i, row) in semantic.enumerated() {
            guard let u = row.url else { continue }
            votes[u] = (rrf(i + 1, 1.0), false, row)
        }
        for (i, row) in keyword.enumerated() {
            guard let u = row.url else { continue }
            let prev = votes[u]
            votes[u] = (prev.map { $0.score + rrf(i + 1, 1.2) } ?? rrf(i + 1, 1.2),
                        prev != nil, prev?.row ?? row)
        }
        let fused = votes.values
            .sorted { $0.score > $1.score }
            .map { entry -> Suggestion in
                var r = entry.row
                r.score = entry.score * 1000 + behaviorOf(entry.row) * 0.1
                if entry.both, r.trailing == nil {
                    r = Suggestion(id: r.id, kind: r.kind, title: r.title, subtitle: r.subtitle,
                                   url: r.url, faviconKey: r.faviconKey, symbol: r.symbol,
                                   trailing: L10n.tr("Semantic match"), score: r.score, loose: r.loose)
                }
                return r
            }
        return fused
    }

    /// The behavior boost a row's history entry earned (dwell/visits/recency), or 0.
    private func behaviorOf(_ row: Suggestion) -> Double {
        guard let url = row.url, let h = store.history[url] else { return 0 }
        return behaviorBoost(h)
    }

    private func topDomainSuggestions(_ q: String) -> [Suggestion] {
        guard !q.contains(" ") else { return [] }
        var out: [Suggestion] = []
        for (i, d) in PopularDomains.list.enumerated() {
            let bare = d.hasPrefix("www.") ? String(d.dropFirst(4)) : d
            guard bare.hasPrefix(q) || d.hasPrefix(q) else { continue }
            let url = "https://\(d)/"
            out.append(Suggestion(id: "top:\(d)", kind: .topDomain, title: bare, subtitle: L10n.tr("Open URL"), url: url,
                                  faviconKey: FaviconKey.key(for: url), symbol: "globe", trailing: nil,
                                  score: 72 - Double(i) * 0.1))
        }
        return out
    }

    private func commandSuggestions(_ q: String, currentTabID: UUID?, spaceShown: UUID?) -> [Suggestion] {
        guard q.count >= 2 else { return [] }
        return actionRows(q, currentTabID: currentTabID, spaceShown: spaceShown).map { row in
            var s = row.suggestion
            s.score += Double(min(row.uses, 10)) * 2
            return s
        }
    }

    /// Commands, space switches and moves the text names (all of them with nothing typed), each
    /// scored by its name alone, with how often it was run from the bar.
    private func actionRows(_ q: String, currentTabID: UUID?, spaceShown: UUID?) -> [(suggestion: Suggestion, uses: Int)] {
        var out: [(suggestion: Suggestion, uses: Int)] = []
        func nameScore(_ name: String, triggers: [String]) -> Double {
            let n = name.lowercased()
            if n.hasPrefix(q) { return 80 }
            if n.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 68 }
            if triggers.contains(where: { $0.hasPrefix(q) }) { return 70 }
            if n.contains(q) { return 50 }
            return 0
        }
        for a in bindings.actions where a.inCommandBar {
            let zhTriggers = L10n.triggers(for: a.id)
            let displayName = L10n.actionName(id: a.id, fallback: a.name)
            let s = max(nameScore(a.name, triggers: a.triggers),
                        nameScore(displayName, triggers: a.triggers + zhTriggers))
            guard s > 0 else { continue }
            out.append((Suggestion(id: "cmd:\(a.id)", kind: .command(a.id), title: displayName, subtitle: L10n.tr("Command"),
                                   url: nil, faviconKey: nil, symbol: a.symbol ?? "command", trailing: a.primary?.display, score: s),
                        store.ranking.commandUsage[a.id] ?? 0))
        }
        // The profile's "New documents" app as one command, "New Google Doc" (Arc, #375); none while it's "——".
        if let doc = newDocumentApp {
            let s = nameScore(doc.commandName, triggers: doc.triggers)
            if s > 0 {
                let id = NewDocumentApp.commandID
                out.append((Suggestion(id: "cmd:\(id)", kind: .command(id), title: doc.commandName, subtitle: "Command",
                                       url: nil, faviconKey: nil, symbol: "doc.badge.plus", trailing: nil, score: s),
                            store.ranking.commandUsage[id] ?? 0))
            }
        }
        for space in incognito ? [] : store.orderedSpaces {
            let switchTitle = L10n.tr("Switch to %@", space.title)
            let s = max(nameScore("Switch to \(space.title)", triggers: [space.title.lowercased()]),
                        nameScore(switchTitle, triggers: [space.title.lowercased(), space.title]))
            if s > 0 && space.id != (spaceShown ?? store.focusedSpaceID) {
                out.append((Suggestion(id: "space:\(space.id)", kind: .switchSpace(space.id), title: switchTitle,
                                       subtitle: L10n.tr("Space"), url: nil, faviconKey: nil, symbol: nil, trailing: space.emoji, score: s), 0))
            }
            if currentTabID != nil, space.id != store.focusedSpaceID {
                let moveTitle = L10n.tr("Move Tab to %@", space.title)
                let m = max(nameScore("Move Tab to \(space.title)", triggers: ["move"]),
                            nameScore(moveTitle, triggers: ["move", "移动"]))
                if m > 0 {
                    out.append((Suggestion(id: "move:\(space.id)", kind: .moveToSpace(space.id), title: moveTitle,
                                           subtitle: L10n.tr("Space"), url: nil, faviconKey: nil, symbol: "arrow.right.square", trailing: space.emoji, score: m - 5), 0))
                }
            }
        }
        if currentTabID != nil {
            for f in store.children(of: store.focusedSpace.pinnedContainerID) where f.isFolder && !f.isLiveFolder {
                let name = f.title ?? "Folder"
                let moveTitle = L10n.tr("Move Tab to %@", name)
                let m = max(nameScore("Move Tab to Folder \(name)", triggers: [name.lowercased()]), nameScore(moveTitle, triggers: ["移动"]))
                if m > 0 {
                    out.append((Suggestion(id: "folder:\(f.id)", kind: .moveToFolder(f.id), title: moveTitle,
                                           subtitle: L10n.tr("Folder"), url: nil, faviconKey: nil, symbol: "folder", trailing: nil, score: m - 5), 0))
                }
            }
        }
        return out
    }

    /// The open tabs ⌘T searches: the profile's, or the window's space's with Settings ▸ Advanced
    /// "Search only the current space’s tabs" (#307). A tab open in another space
    /// then doesn't hide its history row either.
    private func commandBarTabs() -> [SidebarItem] {
        TabSearchScope.commandBarTabs(store.profileTabs(window: nil), space: { self.store.spaceID(ofItem: $0.id) },
                                      windowSpace: store.focusedSpaceID, currentSpaceOnly: store.settings.commandBarCurrentSpaceOnly)
    }

    private func recentSuggestions(excluding current: UUID?) -> [Suggestion] {
        // The seven latest without sorting every tab (#617).
        let tabs = CommandBarRanking.mostRecent(commandBarTabs().lazy.filter { $0.id != current }, count: 7) {
            $0.tab?.timeLastActiveAt ?? .distantPast
        }
        var out: [Suggestion] = tabs.map { tab in
            let sid = store.spaceID(ofItem: tab.id)
            return Suggestion(id: "tab:\(tab.id)", kind: .switchToTab(tab.id), title: tab.displayTitle,
                              subtitle: [sid.flatMap { store.space($0)?.title } ?? "", Self.humanURL(tab.tab?.url ?? "")].filter { !$0.isEmpty }.joined(separator: " · "),
                              url: tab.tab?.url, faviconKey: tab.tab?.faviconKey, symbol: nil, trailing: L10n.tr("Switch to Tab"), score: 0, spaceID: sid)
        }
        for entry in store.archive.lazy.filter({ self.suggests($0, on: self.barProfile) }).prefix(incognito ? 0 : 2) {
            guard let t = entry.item.tab else { continue }
            out.append(Suggestion(id: "arch:\(entry.id)", kind: .archived(entry.id), title: entry.item.displayTitle,
                                  subtitle: "Archived \(Self.relative(entry.archivedAt))", url: t.url, faviconKey: t.faviconKey,
                                  symbol: nil, trailing: L10n.tr("Restore"), score: 0))
        }
        return out
    }

    // MARK: Scoring

    /// 0...100 from how well the query matches a title and a URL.
    func textScore(_ q: String, title: String, url: String) -> Double {
        Self.score(q, Self.searchable(title: title, url: url))
    }

<<<<<<< HEAD
    private static func score(_ q: String, _ key: Searchable) -> Double {
        let t = key.title, host = key.host, bareHost = key.bareHost
        var score = 0.0
        // Case-insensitive throughout: a query "yu7" must hit the history page titled
        // "YU7" — the user typed a Xiaomi model code and got zero history rows while
        // semantic noise filled the bar (the YU7 case). Titles and hosts compare
        // lowercased; the URL matches lowercased too (hosts are, queries often aren't).
        let lq = q.lowercased()
        let lt = t.lowercased(), lu = key.url.lowercased()
        let lHost = host.lowercased(), lBareHost = bareHost.lowercased()
        let tokens = q.split(separator: " ").map { $0.lowercased() }
        if tokens.count > 1 {
            let hay = lt + " " + lu + " " + (key.snippet ?? "")
            let hits = tokens.filter { hay.contains($0) }.count
            if hits == tokens.count { score = 75 } else if hits > 0 { score = 30 * Double(hits) / Double(tokens.count) }
            if lt.hasPrefix(lq) { score = 95 }
            return score
        }
        if lt.hasPrefix(lq) { score = 100 }
        else if key.words.contains(where: { $0.lowercased().hasPrefix(lq) }) { score = 85 }
        else if lt.contains(lq) { score = 65 }
        else if let snippet = key.snippet, snippet.contains(lq) { score = 60 }
        else if let f = fuzzy(lq, in: lt) { score = 25 + 25 * f }
        if lBareHost.hasPrefix(lq) || lHost.hasPrefix(lq) { score = max(score, 95) }
        else if lBareHost.contains(lq) { score = max(score, 70) }
        else if lu.contains(lq) { score = max(score, 55) }
        return score
    }

    /// Subsequence match quality (0...1) or nil when not a subsequence.
    private static func fuzzy(_ q: String, in text: String) -> Double? {
        guard q.count >= 3 else { return nil }
        var it = text.makeIterator()
        var matched = 0
        var gaps = 0
        var inGap = false
        for c in q {
            var found = false
            while let x = it.next() {
                if x == c { found = true; break }
                inGap = true
=======
    /// Keys for many rows, in order, built in parallel chunks.
    nonisolated static func searchables(_ rows: [(title: String, url: String)]) -> [Searchable] {
        guard rows.count > 512 else { return rows.map { searchable(title: $0.title, url: $0.url) } }
        let chunks = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        var parts = [[Searchable]](repeating: [], count: chunks)
        parts.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = rows.count * c / chunks, hi = rows.count * (c + 1) / chunks
                out[c] = rows[lo..<hi].map { searchable(title: $0.title, url: $0.url) }
>>>>>>> origin/main
            }
        }
        return parts.flatMap { $0 }
    }

    /// What the old Searchable kept: the title and human address lowercased, the host from the address.
    nonisolated static func searchable(title: String, url: String) -> Searchable {
        Searchable(title: title.lowercased(), url: SuggestionEngine.humanURL(url).lowercased(), host: (URL(string: url)?.host ?? "").lowercased())
    }

    /// The match score (CraCore CommandBarScore: on bytes for ASCII text, #617).
    private static func score(_ q: String, _ key: Searchable) -> Double { CommandBarScore.score(q, key) }

    /// The keystroke's clock reading (`suggestions(for:)` sets it once per query).
    private var now = Date()

    private func recencyBoost(_ date: Date?) -> Double {
        CommandBarRanking.recencyBoost(age: date.map { now.timeIntervalSince($0) })
    }

    /// A scored row as the bar shows it: a tab's space, pin and address, an archived tab's age, space and
    /// address, a visited page's address. Only the rows shown are finished: dedupe, ranking and the inline
    /// completion read none of this, and at 5,000 tabs a short query matched thousands of rows (#617).
    private func finished(_ s: Suggestion) -> Suggestion {
        guard s.subtitle.isEmpty else { return s }
        var s = s
        switch s.kind {
        case .switchToTab(let id) where s.id.hasPrefix("tab:"):
            let sid = store.spaceID(ofItem: id)
            let spaceName = sid.flatMap { store.space($0)?.title } ?? ""
            s.spaceID = sid
            s.subtitle = [spaceName, store.isPinned(id) ? "Pinned" : "", Self.humanURL(s.url ?? "")].filter { !$0.isEmpty }.joined(separator: " · ")
        case .archived(let id) where s.id.hasPrefix("arch:"):
            guard let entry = store.archive.first(where: { $0.id == id }) else { break }
            let spaceName = entry.sourceSpaceID.flatMap { store.space($0)?.title } ?? ""
            s.subtitle = ["Archived \(Self.relative(entry.archivedAt))", spaceName, Self.humanURL(s.url ?? "")].filter { !$0.isEmpty }.joined(separator: " · ")
        case .history where s.id.hasPrefix("hist:"):
            s.subtitle = Self.humanURL(s.url ?? "")
            s.faviconKey = s.url.flatMap { FaviconKey.key(for: $0) }
        default: break
        }
        return s
    }

    private func dedupe(_ items: [Suggestion]) -> [Suggestion] {
        let rows = items.map { s -> CommandBarDedupe.Row in
            let isCommand: Bool
            if case .command = s.kind { isCommand = true } else { isCommand = false }
            // A tab's, archived tab's or visited page's keys come from the index (#617).
            let keys = isCommand ? nil : searchIndex.dedupeKeys[s.id]
            return CommandBarDedupe.Row(keys: keys ?? CommandBarDedupe.keys(id: s.id, url: isCommand ? nil : s.url, title: s.title),
                                        score: s.score, isOpenTab: s.tabID != nil)
        }
        return CommandBarDedupe.kept(rows).map { kept in
            var s = items[kept.index]
            s.score = kept.score
            return s
        }
    }

    private func inlineCompletion(_ q: String, candidates: [Suggestion]) -> (text: String, candidateID: String)? {
        guard !q.contains(" "), q.count >= 2, !Self.looksLikeURL(q) || !q.contains("/") else { return nil }
        func completion(_ c: Suggestion) -> String? {
            guard let url = c.url, c.score >= 90 || c.kind == .topDomain, let host = URL(string: url)?.host?.lowercased() else { return nil }
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if bare.hasPrefix(q) && bare != q { return bare }
            if host.hasPrefix(q) && host != q { return host }
            return nil
        }
        guard let best = candidates.lazy.compactMap({ c in completion(c).map { (text: $0, candidateID: c.id) } }).first else { return nil }
        // An open tab on the completed host leads, so Return switches to it rather than opening the
        // site again from history, and completes to its whole address (Arc 1.171: "semrush" →
        // semrush.com/projects for a tab on www.semrush.com/projects/).
        if let tab = candidates.first(where: { $0.tabID != nil && completion($0) == best.text }), let url = tab.url {
            let address = CommandBarDedupe.completionAddress(url)
            return (address.lowercased().hasPrefix(q) && address.count > q.count ? address : best.text, tab.id)
        }
        return best
    }

    // MARK: Formatting

    nonisolated static func humanURL(_ url: String) -> String {
        var s = url
        for p in ["https://www.", "http://www.", "https://", "http://"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
        if s.hasSuffix("/") { s.removeLast() }
        if s.count > 70 { s = String(s.prefix(67)) + "…" }
        return s
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

/// What Tab scopes the bar to, a pill before the field until Backspace on the empty field or
/// Escape (Arc's ScopedSearchType).
enum CommandBarScope: Equatable {
    /// Arc's Site Search: "youtube" Tab searches YouTube.
    case site(SiteSearch)
    /// The open tabs of the window's space (#49).
    case tabs
    /// Arc's typeTravel: Tab on the empty field lists the browser's actions (#195).
    case actions

    var name: String {
        switch self {
        case .site(let site): return site.name
        case .tabs: return TabSearchScope.name
        case .actions: return ActionSearchScope.name
        }
    }
}

enum PopularDomains {
    static let list: [String] = [
        "google.com", "youtube.com", "github.com", "gmail.com", "mail.google.com", "docs.google.com", "drive.google.com",
        "calendar.google.com", "maps.google.com", "chatgpt.com", "claude.ai", "x.com", "twitter.com", "reddit.com",
        "wikipedia.org", "en.wikipedia.org", "amazon.com", "apple.com", "developer.apple.com", "netflix.com", "linkedin.com",
        "facebook.com", "instagram.com", "notion.so", "figma.com", "slack.com", "app.slack.com", "discord.com", "zoom.us",
        "vercel.com", "stackoverflow.com", "npmjs.com", "medium.com", "nytimes.com", "bbc.com", "spotify.com",
        "open.spotify.com", "dr.dk", "tv2.dk", "jysk.com", "jysk.dk", "stripe.com", "dashboard.stripe.com", "cloudflare.com",
        "aws.amazon.com", "console.cloud.google.com", "linear.app", "trello.com", "asana.com", "dropbox.com",
        "icloud.com", "twitch.tv", "pinterest.com", "ebay.com", "booking.com", "airbnb.com", "paypal.com",
        "convex.dev", "supabase.com", "openai.com", "platform.openai.com", "anthropic.com", "huggingface.co",
        "producthunt.com", "news.ycombinator.com", "arc.net", "tryspook.com", "kildahl.dk", "localhost:3000",
    ]
}

