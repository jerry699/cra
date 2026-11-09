import CraCore
import Foundation
import Testing

/// When the local model may load, and when Tidy Tabs must wait for the Mac to cool down.
struct LocalInferenceLimitsTests {
    @Test func loadBudgetAddsHeadroom() {
        let model: Int64 = 1_900 * 1024 * 1024
        #expect(LocalInferenceLimits.loadBudget(modelBytes: model) == model + 800 * 1024 * 1024)
    }

    @Test func canLoadNeedsModelPlusHeadroom() {
        let model: Int64 = 532_000_000
        let budget = LocalInferenceLimits.loadBudget(modelBytes: model)
        #expect(LocalInferenceLimits.canLoad(modelBytes: model, availableBytes: budget))
        #expect(!LocalInferenceLimits.canLoad(modelBytes: model, availableBytes: budget - 1))
    }

    @Test func seriousHeatPausesTabs() {
        #expect(!LocalInferenceLimits.pausesTabs(thermal: .nominal))
        #expect(!LocalInferenceLimits.pausesTabs(thermal: .fair))
        #expect(LocalInferenceLimits.pausesTabs(thermal: .serious))
        #expect(LocalInferenceLimits.pausesTabs(thermal: .critical))
    }

    @Test func hotChassisDropsToTwoThreads() {
        #expect(LocalInferenceLimits.threads(thermal: .nominal) == 4)
        #expect(LocalInferenceLimits.threads(thermal: .fair) == 4)
        #expect(LocalInferenceLimits.threads(thermal: .serious) == 2)
        #expect(LocalInferenceLimits.threads(thermal: .critical) == 2)
    }
}
