import AppKit

/// 中国版功能的 3 秒轮询中枢（P3-R2/P5）。上游的 AppDelegate 不含这里的任何逻辑——
/// 这个文件是"我们自己的地盘"，上游文件里的接触面只有 AppDelegate 调度器里的一行钩子
/// （上游重构那一带时，只需把这行钩子挪到新位置）。
///
/// 每次 tick 做三件事：
/// 1. P3-R2 行为信号：key 窗口的可见页累积停留秒数（"认真看完" vs "点进去秒退"）
/// 2. 自动整理触发检查（TidyTabsService.autoTick 的 6 标签/10 分钟/热节流状态机）
/// 3. 语义索引增量（新历史条目嵌入 + 失效条目清理）
@MainActor
enum ChinaFeatures {
    private static var tickCount = 0

    static func tick(store: SidebarStore, mainWindows: [MainWindowController]) {
        guard NSApp.isActive else { return }
        accrueDwell(mainWindows: mainWindows, store: store)
        TidyTabsService.shared.autoTick(store: store)
        EmbeddingService.shared.rebuildIfNeeded(history: Array(store.history.values))
        EmbeddingService.shared.sync(with: Array(store.history.values))
        tickCount += 1
    }

    /// 停留时长：key 窗口的可见页每 tick +3 秒。每 10 个 tick 落盘一次（store 内部去抖）。
    private static func accrueDwell(mainWindows: [MainWindowController], store: SidebarStore) {
        for w in mainWindows where w.window?.isKeyWindow == true {
            if let url = w.browsers.visibleRuntime?.browser.currentURL as String?, !url.isEmpty {
                store.addDwell(url: url, seconds: 3)
            }
        }
    }
}
