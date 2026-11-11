import Darwin
import Foundation
import Observation

/// The Mac's heat and memory, as the local model's guardrails see them. A memory warning ends the
/// model process and any Tidy Tabs run in flight (the 2B's pages can be dropped and the run would
/// crawl through swap); a hot chassis keeps Tidy Tabs from starting, since it is minutes of four
/// cores. Tidy Tab Titles stays: a rename is seconds.
@MainActor @Observable
final class LocalRuntime {
    static let shared = LocalRuntime()

    enum Pressure: String, Equatable, Sendable {
        case normal, warning, critical
    }

    private(set) var thermal: ProcessInfo.ThermalState
    private(set) var pressure: Pressure = .normal

    /// Why the divider may not offer Tidy Tabs now; nil when it may.
    var tabsPauseReason: String? {
        if LocalInferenceLimits.pausesTabs(thermal: thermal) { return L10n.tr("Mac is warm — Tidy paused") }
        if pressure != .normal { return L10n.tr("Low memory — Tidy paused") }
        return nil
    }

    /// What the helper is asked to use: four cores, two while the chassis is hot.
    var threads: Int32 { LocalInferenceLimits.threads(thermal: thermal) }

    /// A test copy holds a state the Mac isn't in (cra://debug?thermal=serious, ?pressure=warning),
    /// so the app-level test can drive the same handler the system's notifications reach.
    @ObservationIgnored private var pinnedThermal: ProcessInfo.ThermalState?
    @ObservationIgnored private var pinnedPressure: Pressure?
    @ObservationIgnored private var source: DispatchSourceMemoryPressure?
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?

    private init() {
        thermal = ProcessInfo.processInfo.thermalState
        pinnedThermal = Self.thermalState(ProcessInfo.processInfo.environment["CRA_LOCAL_THERMAL"])
        if let pinned = pinnedThermal { thermal = pinned }
        pinnedPressure = ProcessInfo.processInfo.environment["CRA_LOCAL_PRESSURE"].flatMap(Pressure.init(rawValue:))
        if let pinned = pinnedPressure { pressure = pinned }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemThermalChanged() }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.systemPressureChanged() }
        }
        source.resume()
        self.source = source
        CraLog.note(String(format: "Max Local: thermal %@, memory pressure %@",
                           Self.name(thermal), pressure.rawValue))
    }

    // MARK: What the model may do

    /// False when free memory can't hold the model and its 800 MB of headroom.
    func canLoadModel(at url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              let available = Self.availableMemoryBytes() else {
            // No reading (unlikely): let the system decide rather than block a working Mac.
            return true
        }
        return LocalInferenceLimits.canLoad(modelBytes: size.int64Value, availableBytes: available)
    }

    /// Everything free + inactive + speculative, the pages a new mapping can take without paging.
    static func availableMemoryBytes() -> Int64? {
        // A test copy can stand in a short Mac (CRA_LOCAL_MEMORY_BYTES), as the pause hooks do.
        if let raw = ProcessInfo.processInfo.environment["CRA_LOCAL_MEMORY_BYTES"], let bytes = Int64(raw) {
            return bytes
        }
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
            / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let pages = Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.speculative_count)
        return pages * Int64(pageSize)
    }

    // MARK: System state

    private func systemThermalChanged() {
        guard pinnedThermal == nil else { return }
        let now = ProcessInfo.processInfo.thermalState
        guard now != thermal else { return }
        thermal = now
        CraLog.note("Max Local: thermal \(Self.name(now))")
    }

    private func systemPressureChanged() {
        guard pinnedPressure == nil, let event = source?.data else { return }
        let next: Pressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
        setPressure(next)
    }

    private func setPressure(_ next: Pressure) {
        guard next != pressure else { return }
        pressure = next
        CraLog.note("Max Local: memory pressure \(next.rawValue)")
        guard next != .normal else { return }
        // The pages matter more than the run: end the helper and the Tidy that waits on it.
        LocalInference.shared.cancelCurrent()
        TidyTabsService.shared.cancelAll()
    }

    // MARK: Test hooks

    func simulate(thermal raw: String) {
        guard let state = Self.thermalState(raw) else {
            CraLog.note("Max Local: unknown thermal state \(raw)")
            return
        }
        pinnedThermal = state
        thermal = state
        CraLog.note("Max Local: thermal \(Self.name(state)) (pinned)")
    }

    func simulate(pressure raw: String) {
        guard let level = Pressure(rawValue: raw) else {
            CraLog.note("Max Local: unknown memory pressure \(raw)")
            return
        }
        pinnedPressure = level
        setPressure(level)
        CraLog.note("Max Local: memory pressure \(level.rawValue) (pinned)")
    }

    private static func thermalState(_ raw: String?) -> ProcessInfo.ThermalState? {
        switch raw {
        case "nominal": return .nominal
        case "fair": return .fair
        case "serious": return .serious
        case "critical": return .critical
        default: return nil
        }
    }

    private static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
