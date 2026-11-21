# 司南浏览器 · 路线图（Roadmap）

> 产品基调（不变）：AI 悄悄帮忙，不抢戏、不加戏；数据不出 Mac；AI 选装。
> 每个阶段的出口条件写在该阶段末尾——达不到就不发版。

## 0. 上游跟踪策略（持续执行）

上游 [VictorKildahl/cra](https://github.com/VictorKildahl/cra) 仍在活跃开发。我们的同步原则：

1. **节奏**：每 2–3 周同步一次（v0.3.00 基线 = 上游 2026-11-17 快照）。拖过 6 周冲突面会翻倍（11-17 的 346-commit 合并花了两个会话）。
2. **机制**：上游新提交进 `origin/main` → rebase 到本地 `daily` 分支 → `daily` 构建验证（CRA_ENGINE=cef）→ 合并进 `main`（= local-model-merged）→ 跑回归。
3. **回归必跑**：`scripts/recall-eval.py`（检索 hit@1 基线 15/31，hit@4 20/31，RRF k=60）+ `swift test`（CraCore）+ 双架构构建。
4. **冲突面控制**：中国化代码已按「新功能新文件 + 上游文件只留一行钩子」原则解耦（ChinaFeatures/MenuHandlers/PaymentRecovery/PerfFindingLocalization 等）。新功能评审必问：**自己的文件吗？上游文件里加了几行？**
5. **每周日自动化**（已有）：拉上游 → rebase daily → 构建验证 → 简报。若构建失败：中止并报告，绝不自动发布。
6. **上游重叠警戒**：上游的 MCP/Agent 层与我们「不做 Agent」哲学相逆——保持默认关闭；上游若做本地模型，评估吸收而不是分叉。

## 1. 近期（0.3.x — 发布后第一个月）

- [ ] **真实用户反馈闭环**：Issues 分诊（bug/体验/功能），每条必复现后分类
- [ ] **从零模型下载**：监控 ModelScope/hf-mirror 链路；下载失败时给出线路切换提示（设置 ▸ Max）
- [ ] **支付自愈观测**：PaymentRecovery 弹窗的出现率（cra.log `PaymentRecovery` 行）——如果高频，把 havana Cookie 的预防性清理做成周期任务
- [ ] **Gitee 镜像**：仓库导入 + 发布同步 + 下载渠道写进 README（国内用户 GitHub 不稳）
- [ ] **主页完善**：sinanbrowser.cn（GitHub Pages 已上线，等 DNS）——加截图、更新日志页
- [ ] 品牌收尾：图标选择器预设名翻译、英 key 的 Cra→Sinan 渐进轮换

## 2. 中期（0.4.x — 两个月内）

- [ ] **专用小模型 v1**（见 [TRAINING-PLAN.md](TRAINING-PLAN.md)）：0.5–0.6B 多任务模型替换默认 1.7B——更快、更准、更小
- [ ] **Tidy 质量升级**：两阶段→单遍切换可配置；域规则可视化编辑（设置页）
- [ ] **蒸馏扩展**：转写纠错质量提升（更大 ASR 或纠错通道微调）；字幕直读站点点位扩充
- [ ] **引擎切换 UX**：支付/DRM 站点首次访问主动提示双引擎选项
- [ ] 性能：语义索引增量更新提速；启动耗时基线对比

## 3. 长期

- [ ] **鸿蒙手机版**（见 [HARMONYOS-PLAN.md](HARMONYOS-PLAN.md)）
- [ ] **Windows 版**（CEF 官方支持，WinUI 3 壳；CraCore 逻辑复用）
- [ ] 开源框架抽出（CRQL 协议 + 模型目录 + 偏好记忆作为独立 Swift 包回馈社区）
- [ ] 官网国际化（英文站）

## 出口条件约定

- 0.3.x 收官：≥50 个真实用户 issue 处理完毕；Gitee 就绪；无 P0/P1 open bug
- 0.4.0 发布：专用模型在 6 项任务评测上 ≥ 1.7B 基线（评测脚本即现行 eval 体系）

## 新增需求（2026-11-20 记录）

- **macOS 12 支持**（降低门槛扩大用户面）：当前部署目标 macOS 14。降级研究项：SwiftUI 可用 API 差异、CEF 最低系统要求、Sparkle 2 系统要求、Swift 运行时回部署边界 → 列入 0.4.x 候选
- **8GB 内存机型**：训练/引入 ~0.3-0.5B 更小模型（Q4 约 350MB），跑「AI 基本功能」（标题整理+翻译+搜索），完整功能仍建议 16GB → 与 W3 训练计划协同（见 TRAINING-PLAN.md 第七节）

## 新增需求（2026-11-21 记录）

- **Intel Mac 兼容性持续提升**（用户重点）：0.3.00 已完整支持 Intel，但兼容性不止「能跑」——包含：Swift 版本升级不破坏 Intel 构建（持续守护）、系统版本下探（macOS 12 支持研究见上）、性能优化（Intel 上启动/渲染/内存基线与优化）、各类 Mac 机型的真实场景回归（老机型显卡、低内存、机械盘）。每次发布保留 Intel 构建为一等公民（已是），Intel 专项回归清单待建。

### 同步预警（2026-11-21 记录）

上游 3 天新增 **486 commits**（iPhone 冲刺：搜索联动 Mac Today/Pinned、Peek 侧栏地址栏、分屏改进、Command bar profile 隔离 #609）。基线 7ff42c77（11-17）→ origin/main c77e50d5。涉及我们修改过的热点文件（SuggestionEngine/Command bar/SidebarStore）。**明日同步窗口执行**：rebase daily → CRA_ENGINE=cef 构建验证 → recall-eval 回归 → 合并 main → 双架构打包测试。若冲突超预期则中止报告。

### 同步执行记录（2026-11-21）

513-commit 合并尝试揭示架构分叉：上游重构 Tidy 服务层（Request 结构体/@Observable），我们的 AI 栈（P3/P5/RRF/本地模型/远程供应商/训练数据格式）绑定旧 API。合并尝试保存在 merge-upstream-513 分支；local-model-merged 回退到 b7731a13（最后可编译）。**下次会话：正式迁移——以上游新架构为基座，把我们的特性移植上去（估 1 个会话），然后发布 0.3.01/0.4.0**。远端 main 当前为不可编译状态，需先强推 b7731a13。
