# 上游同步分析报告（2026-11-16）

> 结论先行：**可以合并，但不是今天**。上游 346 提交包含三大结构变化，其中两个影响
> 我们的构建与产品定位；47 个重叠文件中 10 个是重冲突区。建议按本报告的策略执行。

## 一、上游 346 提交的三大结构变化

### 1. iPhone/iOS 平台（59 提交，56 个新文件，+5700 行）
上游把 cra 扩展到了 iPhone。**与 Intel Mac 版无冲突**（独立 iOS/ 目录 + iOS 测试），
但 Package.swift 的 manifest 因多平台变得庞大复杂——**Swift 6.2 在 Intel 上类型检查
超时**（已实测：products 三元拼接 + targets 数组都超时；上游在 arm64 上没遇到）。
同步时必须携带"manifest 拆分补丁"（已写好，在 /tmp/package-manifest-surgery.patch）。

### 2. Chromium 双引擎（57 提交）
上游把 **Chromium 完整引擎做成了默认**（CRA_ENGINE=cef 切回旧 CEF 路线），引入
engine/chromium/cra/bridge.mm（3507 行）和全新的 Package.swift targets 条件结构。
**对我们的影响**：Intel 上的构建依赖 CEF 路线——需要验证 CEF 路线在新 manifest 下
仍可用（targets 数组的 if chromiumEngine 分支就是给我们的）。风险中等，需实测。

### 3. MCP 组件（Agent 协议层，~2000 行新文件）
MCPAgentAids/Setup/Agents/Input/Protocol/References + MCPServer/MCPInput/MCPPage——
上游在做 AI Agent 接入层。**与我们的隐私纲领相反方向**（外部 agent 访问浏览器），
但代码独立、不启用即无影响。提醒：这印证了我们"悄悄帮忙"路线的差异化价值。

## 二、冲突面评估（47 个重叠文件）

### 高冲突（我们深度改过 + 上游大改）——10 个，预计手工解决
| 文件 | 上游改动 | 我们改动 |
|---|---|---|
| MainWindowController.swift | +1530（Arc 对齐/多窗口） | 翻译 HUD、蒸馏 handler |
| AppDelegate.swift | +808（iOS/引擎轮询） | dwell 埋点、3s 轮询 |
| CraCEF.mm | +769（引擎桥接） | 蒸馏菜单、fetchBinaryURL、CDP |
| SpaceColumnView.swift | +456（侧栏重构） | 分组重命名 UI |
| BrowserManager.swift | +322 | PageHistory 守卫、蒸馏转发 |
| ShortcutsPane.swift | +310（已在上次 rebase 取上游版） | 中文化 |
| SettingsWindowController.swift | +298 | — |
| SidebarRowViews.swift | +290 | 分组重命名内联编辑 |
| ProfilesPane.swift | +281 | 中文化 |
| MaxPane.swift | +271 | 我们整个 Max 面板改造 |

### 零冲突（最重要的好消息）
**TidyPreferences / SemanticIndex / TidyTabsTwoStage 上游零改动**——P5 记忆机制、
语义索引、GBNF 分组语法的全部载体文件上游没碰。我们的核心资产与上游演进**完全正交**。

SidebarModel.swift +161 行是上游给 AppSettings 加的新开关字段（iconImage、
autoPictureInPictureSites 等）——与我们的 HistoryEntry.description/contentSnippet/
dwellTime **不同结构体**，无冲突。

## 三、合并策略建议

**方案：一次性 merge 到 daily（不做逐提交 rebase）**
理由：346 提交逐个 rebase 会把同一冲突解决 346 次上下文碎片化；上次 6 提交 rebase
已经消耗大量精力。一次性 merge 把全部冲突集中在一次解决。

**执行步骤**（预计 2-3 个时段）：
1. `git checkout daily && git merge origin/main`（merge commit 保留我们的 6 提交历史）
2. 冲突解决顺序：Package.swift（manifest 拆分补丁）→ CraCEF.mm（最大）→
   MainWindowController → AppDelegate → 其余 UI 文件（策略=上游结构+我们的功能行/L10n）
3. **特别验证**：CraCEF.mm 的蒸馏菜单/fetchBinaryURL/CDP 管道在引擎桥接后是否完好
4. 构建通过 → 装 daily → 用户烟测 → 再 merge 到 local-model-merged（带上我们的
   40 个本地提交：本地模型、蒸馏、检索、记忆）
5. 全量验收：检索三件套、蒸馏、Tidy 记忆、分组重命名

**时机建议**：不必今天。当前 0.1.85 功能完整可用；建议（a）先把手头 LongCat 2 标签
处理完、再日常用 2-3 天确认 P5 稳定；（b）然后选一个完整时段做合并（失败可随时
`git merge --abort` 回到 0.1.85 基线，零风险）。

## 四、附带发现

- 上游发布节奏也在加速（v0.1.41-43 三个 tag 同天），说明它在活跃开发期——
  我们的同步间隔不宜超过 2-3 周，否则冲突面会像这次一样膨胀
- 上游 arc-reverse-engineering.md +1071 行、arc-search-reference.md +749 行——
  上游在系统整理 Arc 行为参考文档，对我们后续对齐是好事
