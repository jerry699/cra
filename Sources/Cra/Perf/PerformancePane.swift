import AppKit
import SwiftUI

/// Settings ▸ Performance (GitHub #91): what the recorder measured this session, read every two
/// seconds while the pane is on screen and never while it isn't. Card style like Privacy. Not in
/// Dia or Arc: Cra's own, for reports of freezes that are gone by the time they are written up.
struct PerformancePane: View {
    let nav: SettingsNavigation
    let actions: SettingsActions
    @Environment(SidebarStore.self) private var store
    @State private var section = Section.overview
    @State private var report: PerfReport?
    @State private var copied = false

    enum Section: String, CaseIterable { case overview = "Overview", events = "Events", export = "Export" }

    var body: some View {
        @Bindable var store = store
        SettingsCardPane {
            Picker("", selection: $section) { ForEach(Section.allCases, id: \.self) { Text(L10n.tr($0.rawValue)).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
            switch section {
            case .overview: overview($store.settings.perfRecording)
            case .events: events
            case .export: export($store.settings.perfHidesSiteNames)
            }
        }
        .task(id: RefreshKey(open: nav.isOpen && nav.tab == .advanced, recording: store.settings.perfRecording)) {
            report = nil
            guard nav.isOpen, store.settings.perfRecording else { return }
            while !Task.isCancelled {
                if let r = PerfRecorder.shared { r.snapshot { report = $0 } }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private struct RefreshKey: Equatable { var open: Bool; var recording: Bool }

    // MARK: Overview

    @ViewBuilder private func overview(_ recording: Binding<Bool>) -> some View {
        SettingsFeatureCard {
            SettingsToggleRow(L10n.tr("Record performance"),
                              detail: L10n.tr("Cra measures itself on this Mac: freezes, CPU and memory per process, tab timings."),
                              isOn: recording)
        }
        SettingsFootnote(L10n.tr("Nothing leaves the Mac unless you export it with Help ▸ Export Diagnostics."))

        if let r = report {
            if !r.insights.isEmpty {
                SettingsHeader(L10n.tr("Findings")).padding(.top, 20)
                SettingsCard {
                    ForEach(Array(r.insights.enumerated()), id: \.element.id) { i, insight in
                        if i > 0 { SettingsCardDivider() }
                        SettingsCardRow {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: insight.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                    .foregroundStyle(insight.severity == .warning ? Color(nsColor: .systemOrange) : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(insight.title).font(.system(size: 13))
                                    Text(insight.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } trailing: { EmptyView() }
                    }
                }
            }
            let m = r.mainThread
            card(L10n.tr("Main thread"), [
                (L10n.tr("Stalls of ¼ s or more"), "\(m.freezes)"),
                (L10n.tr("Freezes of 1 s or more"), "\(m.longFreezes)"),
                (L10n.tr("Longest freeze"), m.longestFreezeMs > 0 ? PerfInsights.duration(m.longestFreezeMs) : "–"),
                (L10n.tr("In menus, drags, alerts, start-up"), "\(m.outsideFreezes)"),
                (L10n.tr("Longest pass"), m.longestPassMs > 0 ? PerfInsights.duration(m.longestPassMs) + (m.longestPassMode.map { " (\($0))" } ?? "") : "–"),
                (L10n.tr("Typical pass (99 %)"), PerfInsights.duration(m.passes.percentile(0.99))),
            ])
            card(L10n.tr("Processes"), r.processes.filter { $0.count > 0 }.map { g in
                (L10n.tr(g.kind.label) + (g.count > 1 ? " ×\(g.count)" : ""),
                 g.available ? L10n.tr("%@ %% CPU · %@", String(format: "%.1f", g.cpuPct), PerfInsights.bytes(g.footprintBytes)) : L10n.tr("not available"))
            })
            if let s = r.system {
                card(L10n.tr("Mac"), [
                    (L10n.tr("CPU, all cores"), s.cpuPct.map { "\(Int($0.rounded())) %" } ?? "–"),
                    (L10n.tr("Memory pressure"), L10n.tr(s.memoryPressure.rawValue.capitalized)),
                    (L10n.tr("Temperature"), L10n.tr(s.thermalState.capitalized)),
                    (L10n.tr("Low Power Mode"), s.lowPowerMode ? L10n.tr("On") : L10n.tr("Off")),
                    (L10n.tr("Free disk"), s.freeDiskBytes.map(PerfInsights.bytes) ?? "–"),
                ])
            }
            card(L10n.tr("Tabs"), tabRows(r))
            Text(L10n.tr("Session %@, launch %d, up %d min · recording costs %@ %% of a core",
                         r.session.id, r.session.launch, Int(r.session.uptimeSeconds / 60), String(format: "%.3f", r.selfCost.cpuPct)))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.leading, 8).padding(.top, 12)
        } else if !recording.wrappedValue {
            SettingsFootnote(L10n.tr("Recording is off: no samples, no timers, nothing written. Files already recorded stay until you clear them."))
                .padding(.top, 12)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 24)
        }
    }

    private func tabRows(_ r: PerfReport) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let t = r.tabs.latest { rows.append((L10n.tr("Tabs"), L10n.tr("%d · %d loaded · %d asleep", t.tabs, t.live, t.slept))) }
        for (title, metric) in [(L10n.tr("Tab switch"), PerfMetric.tabSwitch), (L10n.tr("New page"), .pageCreate), (L10n.tr("Page load"), .pageLoad), (L10n.tr("Waking a slept tab"), .tabWake)] {
            guard let h = r.timings[metric.rawValue], h.count > 0 else { continue }
            rows.append((title, L10n.tr("%@ typical · %@ slow", PerfInsights.duration(h.percentile(0.5)), PerfInsights.duration(h.percentile(0.95)))))
        }
        if r.tabs.longTasks > 0 { rows.append((L10n.tr("Busy page (long tasks)"), L10n.tr("%d · %@", r.tabs.longTasks, PerfInsights.duration(r.tabs.longTaskMs)))) }
        if r.tabs.longFrames > 0 { rows.append((L10n.tr("Late frames"), L10n.tr("%d · longest %@", r.tabs.longFrames, PerfInsights.duration(r.tabs.longestFrameMs)))) }
        if r.tabs.videoFrames > 0 { rows.append((L10n.tr("Video frames dropped"), L10n.tr("%d of %d", r.tabs.droppedVideoFrames, r.tabs.videoFrames))) }
        return rows
    }

    @ViewBuilder private func card(_ title: String, _ rows: [(String, String)]) -> some View {
        if !rows.isEmpty {
            SettingsHeader(title).padding(.top, 20)
            SettingsCard {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { SettingsCardDivider() }
                    SettingsCardRow {
                        Text(row.0).font(.system(size: 13))
                    } trailing: {
                        Text(row.1).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Events

    @ViewBuilder private var events: some View {
        let list = report.map(Self.timeline) ?? []
        if list.isEmpty {
            SettingsFootnote(report == nil ? L10n.tr("Recording is off.") : L10n.tr("Nothing has happened this session: no stalls, crashed pages or failed loads."))
        } else {
            SettingsCard {
                ForEach(Array(list.prefix(100).enumerated()), id: \.offset) { i, e in
                    if i > 0 { SettingsCardDivider() }
                    SettingsCardRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.system(size: 13))
                            if !e.detail.isEmpty {
                                Text(e.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    } trailing: {
                        Text(e.time).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private struct Row { var at: Double; var time: String; var title: String; var detail: String }

    /// Stalls and events, newest first.
    private static func timeline(_ r: PerfReport) -> [Row] {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        func time(_ at: Double) -> String { f.string(from: r.session.startedAt.addingTimeInterval(at)) }
        var rows = r.mainThread.recent.map { s in
            Row(at: s.at, time: time(s.at),
                title: "\(s.freeze ? L10n.tr(s.kind == .stall ? "Stall" : "Freeze") : L10n.tr("Busy %@ loop", s.mode)) \(PerfInsights.duration(s.ms))",
                detail: ([s.site].compactMap { $0 } + (s.marks.isEmpty ? [] : [L10n.tr("after %@", s.marks.joined(separator: " → "))])).joined(separator: " · "))
        }
        rows += r.events.filter { $0.kind != "freeze" && $0.kind != "hang" }.map { e in
            Row(at: e.at, time: time(e.at), title: e.kind == "renderer" ? L10n.tr("Page process %@", e.detail) : L10n.tr("Load failed (%@)", e.detail),
                detail: e.site ?? "")
        }
        return rows.sorted { $0.at > $1.at }
    }

    // MARK: Export

    @ViewBuilder private func export(_ hideSites: Binding<Bool>) -> some View {
        SettingsCard {
            SettingsCardRow {
                Text(L10n.tr("Hide site names")).font(.system(size: 13))
            } trailing: {
                Toggle(L10n.tr("Hide site names"), isOn: hideSites).toggleStyle(.arcSwitch).labelsHidden()
            }
        }
        SettingsFootnote(L10n.tr("Sites in the exported files become site-1, site-2… in every file, logs included. Without it they keep their host name (never the full address), as Cra's logs always have."))
        HStack(spacing: 8) {
            Button(L10n.tr("Export Diagnostics…")) { actions.exportDiagnostics() }
            Button(copied ? L10n.tr("Copied") : L10n.tr("Copy Summary")) {
                guard let r = report else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(PerfSummary.text(r), forType: .string)
                copied = true
            }
            .disabled(report == nil)
            Spacer(minLength: 0)
            Button(L10n.tr("Clear…")) { confirmClear() }
        }
        .padding(.top, 16)
        SettingsFootnote(L10n.tr("Copy Summary never names a site. The recording lives in %@ and stays under 2 MB.",
                                 AppPaths.file("Perf").path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
            .padding(.top, 4)
    }

    private func confirmClear() {
        let alert = AppDialog(title: L10n.tr("Clear the performance recording?"),
                              message: L10n.tr("This session's numbers, the last 24 hours and saved freezes are deleted."),
                              actions: [DialogAction(L10n.tr("Clear"), role: .destructive), .cancel])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        PerfRecorder.clear()
        report = nil
    }
}

private extension PerfProcessKind {
    var label: String {
        switch self {
        case .browser: return "Cra"
        case .renderer: return "Pages"
        case .gpu: return "GPU"
        case .utility: return "Network, storage, audio"
        case .other: return "Other"
        }
    }
}
