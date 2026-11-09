import Foundation

/// What the Mac's memory and heat allow the local model to do. A 2B maps 1.9 GB of clean file
/// pages and builds about 0.3 GB of context on top; on an 8 GB Mac with CEF running, both only
/// fit if the system is not already paging. Serious heat is the 2018 Intel's other limit: a Tabs
/// run holds four cores for minutes and clocks fall to about half.
public enum LocalInferenceLimits {
    /// Room beyond the model's own pages for the context, the graph and the sampler.
    public static let memoryHeadroom: Int64 = 800 * 1024 * 1024

    public static func loadBudget(modelBytes: Int64) -> Int64 {
        modelBytes + memoryHeadroom
    }

    /// Free + inactive + speculative pages, against the model plus headroom.
    public static func canLoad(modelBytes: Int64, availableBytes: Int64) -> Bool {
        availableBytes >= loadBudget(modelBytes: modelBytes)
    }

    /// Tidy Tab Titles is a few seconds and stays; Tidy Tabs is minutes under load.
    public static func pausesTabs(thermal: ProcessInfo.ThermalState) -> Bool {
        thermal == .serious || thermal == .critical
    }

    /// Four threads normally; two while the chassis is hot, for the renames that still run.
    public static func threads(thermal: ProcessInfo.ThermalState) -> Int32 {
        pausesTabs(thermal: thermal) ? 2 : 4
    }
}
