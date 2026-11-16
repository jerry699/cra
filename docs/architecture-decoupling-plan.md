# 架构解耦方案：让上游同步回到"低成本例行公事"（2026-11-16）

> 问题：本次上游同步（346 提交）暴露的痛点——我们的功能与上游文件**交织在同一个
> Swift 文件里**，每次同步都要人肉分辨"哪行是谁的"。根源不是上游变了，是我们的
> 代码没有"自己的地盘"。

## 一、数据驱动的冲突画像

我们的 40 个本地提交涉及的文件，按"上游改动频率 × 我们改动次数"排出的热区：

| 热度 | 文件 | 我们改了 N 次 | 上游趋势 | 根因 |
|---|---|---|---|---|
| 🔴 | MaxPane.swift | 8 | 上游整个面板重设计（Enable Max） | 我们的 provider 卡/本地模型卡/记忆行**内嵌**在上游面板 |
| 🔴 | AppDelegate.swift | 9 | 上游加 iOS/引擎轮询 | 我们的 3s 轮询（dwell/语义/自动整理）**混入**上游主轮询 |
| 🔴 | MainWindowController.swift | 5 | +1530 行 Arc 对齐 | 翻译/蒸馏 handler **散在**上游大类里 |
| 🟡 | MaxLocal.swift | 9 | 上游零改动 | 我们自己的文件，但被上游类型系统影响 |
| 🟡 | TidyTabsService.swift | 8 | 少量 | 单阶段分组+前置分配混入 |
| 🟡 | SuggestionEngine.swift | 5 | 少量 | RRF 融合混入上游排序 |
| 🟢 | Localizable.strings | 11 | 上游不动 | 零冲突 |
| 🟢 | CraInferenceHelper/main.cpp | 4 | 上游不动 | 零冲突 |
| 🟢 | MediaDistill/WhisperService/TranslationHUD | 独立新文件 | 上游不存在 | **零冲突——这就是方向** |

**规律一目了然**：凡是我们**新开的文件**（蒸馏、翻译 HUD、语义索引、评测脚本）零冲突；
凡是**嵌进上游文件**的功能（MaxPane 行、AppDelegate 轮询、MainWindowController handler）
全是热区。

## 二、解耦原则：三个隔离层

### 原则 1：新功能 = 新文件（最大化"我们自己的地盘"）
- 每个功能一个独立 Swift 文件，上游永远不碰
- 现状反例：Tidy 的单阶段分组逻辑塞在 MaxLocal.swift（9 次改动）；RRF 融合塞在
  SuggestionEngine.swift——应各自成文件

### 原则 2：上游文件的接触面收敛为"一行钩子"
上游文件里只留一行（或一小段稳定锚点）调用我们的代码：
```swift
// AppDelegate.swift 里只留：
ChinaFeatureHub.tick(store: self.store, browsers: ...)   // 一行
// MainWindowController.swift 里只留：
ChinaFeatures.handleMenu(id, browser: browser, point: point)  // 一行
```
上游重构这行周围时，我们只需"把这一行挪到新位置"，而不是在 300 行冲突里逐段辨认。

### 原则 3：数据结构自立（CraCore 或独立模块）
HistoryEntry 扩展字段、TidyPreferences、SemanticIndex 已经在 CraCore 且上游零改动——
**保持并强化**：所有 Codable 结构的新字段都进 CraCore，不进上游的 SidebarModel.swift
（它在上游有 +161 行的新增，会冲突）。

## 三、具体重构清单（按 ROI 排序）

| # | 动作 | 消除的热区 | 工作量 |
|---|---|---|---|
| 1 | **ChinaFeatures 单例**：集中 3s 轮询（dwell/语义/自动整理触发）为静态方法，AppDelegate 留一行钩子 | AppDelegate 🔴 | 0.5h |
| 2 | **TidyGroupedMode.swift 独立文件**：单阶段分组的指令/语法/解析从 MaxLocal.swift 抽出 | MaxLocal 🟡 | 1h |
| 3 | **RetrievalFusion.swift 独立文件**：RRF 融合/时间槽/弱锚点从 SuggestionEngine.swift 抽出 | SuggestionEngine 🟡 | 1h |
| 4 | **MaxPaneChina.swift 独立文件**：provider 卡/本地模型卡/蒸馏笔记行/用户记忆行做成 View 扩展文件，MaxPane.swift 只留 4 行调用 | MaxPane 🔴 | 1.5h |
| 5 | **MenuHandlers.swift 独立文件**：翻译/蒸馏的 delegate handler 从 MainWindowController 抽出 | MainWindowController 🔴 | 1h |
| 6 | CraCEF.h/mm 的改动（菜单项/CDP/fetchBinaryURL）无法抽文件——**接受为"深钩子"**，同步时手工合成（有 0.1.78 诊断日志护航） | CraCEF.mm 🟡 | 接受 |

**总工作量 ≈ 半天到 1 个时段**。做完后，上游文件的接触面从"数百行散布"收敛为
"每文件 1-4 行钩子"，下次 346 提交级的同步预计从 2-3 时段降到 **0.5-1 时段**。

## 四、长期机制

1. **同步节奏**：≤2-3 周一次（本次教训：346 提交的积压是冲突膨胀的直接原因）
2. **每次上游同步后**：跑 recall-eval.py（31 条基线）确认检索无回退
3. **新功能纪律**：评审问题固定为"这个功能有自己的文件吗？上游文件的接触面是几行？"
4. **深钩子登记表**：CraCEF.mm 内无法抽离的锚点（菜单 ID、CDP 方法名）维护在本文档，
   同步时逐一核对
