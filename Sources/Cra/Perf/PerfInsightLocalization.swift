import CraCore

/// CraCore's PerfInsights composes English sentences (CraCore has no L10n access); the pane
/// renders the same findings keyed by their stable `id`, re-reading the numbers from the
/// report itself — so a new insight CraCore gains falls back to its English text until a key
/// lands here, and perf.json keeps the original English for issue reports.
enum PerfFindingLocalization {
    static func title(_ insight: PerfInsight, _ r: PerfReport) -> String {
        L10n.tr(detailOrTitle(insight, r).0)
    }

    static func detail(_ insight: PerfInsight, _ r: PerfReport) -> String {
        L10n.tr(detailOrTitle(insight, r).1)
    }

    /// Returns (titleKey, detailKey) with the format arguments already substituted into the
    /// key strings — L10n.tr passes text it has no entry for through unchanged, so an unknown
    /// id or a missed key shows the composed English instead.
    private static func detailOrTitle(_ insight: PerfInsight, _ r: PerfReport) -> (String, String) {
        let m = r.mainThread
        func dur(_ ms: Double) -> String { PerfInsights.duration(ms) }
        switch insight.id {
        case "previous-abnormal":
            let ver = r.session.previous?.craVersion ?? ""
            return ("The last session ended without quitting",
                    String(format: "司南 %@ crashed, was forced to quit or the Mac lost power. Its last minute is in the export.", ver))
        case "freezes":
            return (String(format: "司南 froze %d time%@ for a second or more", m.longFreezes, m.longFreezes == 1 ? "" : "s"),
                    String(format: "The longest lasted %@%@.", dur(m.longestFreezeMs),
                           m.hangs > 0 ? String(format: "; %d went past 2 s", m.hangs) : ""))
        case "stalls":
            return ("Frequent short stalls",
                    String(format: "%d pauses of a quarter second or more since launch.", m.freezes))
        case "outside-freezes":
            let longest = m.longestPassMs > m.longestFreezeMs
                ? String(format: " The longest lasted %@%@.", dur(m.longestPassMs),
                         m.longestPassMode.map { " (\($0))" } ?? "")
                : ""
            return (String(format: "%d long pass%@ in menus, drags, alerts or start-up", m.outsideFreezes, m.outsideFreezes == 1 ? "" : "es"),
                    String(format: "Not counted as freezes: 司南 was in a loop of its own on purpose.%@", longest))
        case "profiler-overhead":
            return (String(format: "Recording costs %.3f %% of a core", r.selfCost.cpuPct),
                    String(format: "Over its %d %% budget. The numbers still hold; selfCost in perf.json says which part costs it.", PerfInsights.selfCostBudgetPct))
        case "idle-cpu":
            return ("司南 kept working while the Mac was idle",
                    String(format: "%d %% of a core on average over %d min without keyboard or mouse input. A playing video counts too.",
                           Int(r.idle.cpuPct.rounded()), r.idle.samples * 5 / 60))
        case "renderer-crashes":
            let crashes = count(of: insight.title, pages: false)
            return (String(format: "%d page%@ stopped (“Aw, Snap!”)", crashes, crashes == 1 ? "" : "s"),
                    "A page's process crashed, ran out of memory or was ended.")
        case "unresponsive":
            let unresponsive = count(of: insight.title, pages: false)
            return (String(format: "%d page%@ stopped responding", unresponsive, unresponsive == 1 ? "" : "s"),
                    "Chromium asked whether to wait or close the page.")
        case "memory-pressure":
            let level = r.system?.memoryPressure.rawValue ?? ""
            return ("The Mac is short of memory",
                    String(format: "macOS reports %@ memory pressure; pages may reload and everything slows down.", zhMemoryPressure(level)))
        case "thermal":
            return ("The Mac is running hot", "macOS slows the processor down until it cools.")
        case "low-power":
            return ("Low Power Mode is on", "Video and scrolling may be less smooth.")
        case "low-disk":
            let free = r.storage.freeDiskBytes ?? r.system?.freeDiskBytes ?? 0
            return ("The disk is almost full", String(format: "%@ free. Chromium's caches and swap need room.", PerfInsights.bytes(free)))
        case "footprint":
            let footprint = r.processes.reduce(Int64(0)) { $0 + $1.footprintBytes }
            let slept = r.tabs.latest?.slept ?? 0
            return (String(format: "司南 uses %@ of memory", PerfInsights.bytes(footprint)),
                    slept > 0 ? String(format: "Tab sleeping has %d tab%@ asleep.", slept, slept == 1 ? "" : "s")
                              : "Pages you haven't looked at in a while (4 hours unless you change it) close, and reload when you open them. Settings ▸ Tabs ▸ Tab Cleanup can close them sooner, or when the Mac is short of memory.")
        default:
            return (insight.title, insight.detail)
        }
    }

    /// "2 pages stopped responding" — the count leads the CraCore title.
    private static func count(of title: String, pages: Bool) -> Int {
        Int(title.split(separator: " ").first ?? "") ?? 0
    }

    private static func zhMemoryPressure(_ raw: String) -> String {
        L10n.tr(raw.capitalized) // Nominal / Warning / Critical keys exist from the pane pass
    }
}
