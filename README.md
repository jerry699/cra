<div align="center">
  <img src="brand/sinan-icon.png" alt="司南 SINAN" width="128" height="128">
</div>

<h1 align="center">司南浏览器 · Sinan Browser</h1>

<p align="center">
  一款面向中国用户的本地 AI 浏览器 · 基于 Cra 浏览器的开源分支<br>
  让浏览器回归本源：AI 不抢戏、不加戏，数据不出你的 Mac。
</p>

<p align="center">
  <a href="#-下载">下载</a> ·
  <a href="#-我们的故事">我们的故事</a> ·
  <a href="#-特性">特性</a> ·
  <a href="#-设计哲学">设计哲学</a> ·
  <a href="#-路线图">路线图</a> ·
  <a href="README-upstream.md">上游项目说明（英文）</a>
</p>

---

## 📖 我们的故事

这是一个基于 [CRA 浏览器](https://github.com/VictorKildahl/cra)的开源项目。做这个浏览器的最初目的是希望能够找一款 Arc 浏览器的替代品。但市面上合适的产品大多只支持 M 系列芯片 arm 架构了。囊中羞涩的我实在换不起新电脑了。为了能够继续下去，我觉得自己开发。但残酷的现实摆在我面前，源码库 100 多 GB，编译一个应用的过程十几个小时。对于我的老 Mac 来说实在太难了。

这个时候，AI 帮我找到了 CRA 浏览器。一份奇妙的缘分就此开始。

事实上 CRA 也只支持 ARM 芯片。本着试一试的想法，我在用 AI 完成了一部分的代码开发后给 CRA 的原作者发了信息，问对方是否愿意给我的 Intel X64 版本提供帮助。很快得到肯定的答复，原作者给我提供了我需要的补丁程序。今天，这款司南浏览器的雏形就此诞生。在这里感谢 CRA 的原作者和所有代码贡献者。

本来我们的故事到此已经可以圆满结束了，因为我得到了我想要的浏览器。但如果只是这样，我们就辜负了原作者的工作。于是，我决定在 CRA 浏览器原作的基础上，针对国内场景、日常使用和 AI 功能部分做继续的开发。

CRA 浏览器中的 AI 功能，需要使用苹果智能。但在国内的环境下，这个功能显然并不会好。而 CRA 的作者又是一个强调数据安全的开发者，绝不做 Agent 是一个写到网页上的承诺。这其实正好戳中了当下浏览器市场的一个反直觉的锚点：从互联网时代延续到当下，浏览器被多数厂商都认为是一个流量的入口。当我们日常的浏览过程中，真的需要持续和 AI 交互吗？真的需要与 Agent 交互吗？我调研了一下，用户使用最多的 AI 功能其实是翻译。我想这也是今年为什么很多 AI 浏览器都不做了的原因之一——没有能够赢得足够多的流量。

于是，我给自己的开发定了一个基调：**让浏览器回归本源，AI 的能力不抢戏、不加戏。**同时，大家的浏览器内容本身也是个人隐私的一部分，不应该让这些内容流转出去。在 AI 方面我使用本地的小模型，所有与 AI 相关的处理工作都在本地完成。考虑到浏览才是本源，本地模型部分为**选装**——如果你不使用 AI 功能，完全不用安装。

最后，讲讲为什么叫司南吧。战国《鬼谷子》与东汉《论衡》记载，司南以天然磁石磨成勺，置于光滑地盘之上，勺柄恒指南方。它是中华文明对"导航"的最早回答。浏览器在信息世界里做的，正是同一件事——帮人找到方向。这个名字让产品从"工具"变成"传承"。这也是我的希望。

## ✨ 特性

**浏览本源**（上游 Cra 的全部能力 + Intel 支持）
- 侧栏驱动的浏览体验：空间、固定标签页、收藏、文件夹、自动归档
- 双引擎：页面默认 Chromium（Chrome 扩展 / DevTools），一键切换 Safari 引擎（DRM、支付等场景）
- 垂直标签页 + 速览（Peek）+ 小窗口 + 分屏

**本地 AI**（全部离线运行，模型应用内下载，选装）
- 🧹 **标签页自动整理**：Today 攒满 6 个标签自动分组，支持 ⌘Z 撤销、域名规则学习
- 🏷 **标签页标题整理**：固定时自动把标题改得简洁易认
- 📥 **下载整理**：智能重命名下载文件
- 🔍 **语义历史搜索**：⌘L 直接用中文描述找网页（向量 + 关键词 RRF 融合检索）
- 🌐 **划选翻译**：右键翻译选中文字，本地完成
- 🎬 **音视频蒸馏**：右键把 B 站等页面的音视频蒸馏成 Markdown 笔记（转写 + 摘要，落入你的笔记目录）
- 🧠 **用户记忆**：整理结果可学习、可管理、可清除

**中国场景适配**
- 全中文界面，跟随系统语言
- 支付链路保护：内置拦截器对主流支付集团的收银台链路自动豁免
- 支付异常一键修复：登录数据冲突导致的支付失败，一键清除冲突数据
- 内置广告拦截默认规则对国内站点友好，第三方扩展（uBlock 等）冲突场景有提示

**安全**
- 定期第三方安全审计，关键发现已修复并公开记录
- cra:// 调试协议在正式版中封闭
- 诊断导出默认脱敏（站点级、非完整地址）

## 🎯 设计哲学

1. **AI 悄悄帮忙，不改变浏览**——没有聊天面板，没有 Agent，没有页面问答
2. **数据不出 Mac**——所有 AI 处理本地完成；诊断导出脱敏；不做遥测（使用统计默认关闭）
3. **AI 选装**——浏览是本源；不装模型，司南就是一款干净的快速浏览器

## 🛣 路线图

- [ ] 针对浏览器 AI 功能训练专用小模型（0.5-0.6B 多任务，替换默认 1.7B）
- [ ] 鸿蒙（HarmonyOS）手机版
- [ ] Windows 版
- [ ] 官网 sinanbrowser.cn

## 📥 下载

从 [Releases](https://github.com/jerry699/cra/releases) 页面下载：

| 文件 | 适用 |
|---|---|
| `司南-Intel.dmg` / `司南-Intel.zip` | Intel (x86_64) Mac |
| `司南.dmg` / `司南.zip` | Apple Silicon (arm64) Mac |

安装后：应用内即可下载 AI 模型（设置 ▸ Max），不装模型不影响任何浏览功能。

> 首次打开如遇 Gatekeeper 提示：右键点击应用 → 打开，或在系统设置 ▸ 隐私与安全性中允许。

## 🙏 致谢

- [Cra 浏览器](https://github.com/VictorKildahl/cra)的原作者 [@VictorKildahl](https://github.com/VictorKildahl) —— 对 Intel 支持的快速响应和这份出色的作品
- Cra 的所有代码贡献者
- Qwen 团队（通义千问开源模型）、whisper.cpp 与 llama.cpp 项目、bge/Qwen3-Embedding

## ⚖️ 许可

与上游一致，MIT License。

---

<div align="center">
<sub>English below / 英文版在下方</sub>
</div>

---

# Sinan Browser (English)

A local-AI browser for Chinese users — an open-source fork of the [Cra browser](https://github.com/VictorKildahl/cra).

**The story:** I wanted an Arc replacement, but everything suitable is Apple-Silicon-only, and my old Intel Mac couldn't run any of them. Building from source meant a 100 GB checkout and hours of compiling — not realistic on my machine. Then AI led me to Cra, itself ARM-only at the time. I developed parts of the port with AI's help and asked the author for support with the Intel X64 build; he answered quickly and provided the patches I needed. Sinan grew from there: instead of stopping at "I got my browser back," I kept developing Cra for China-specific scenarios, daily use, and AI features — with the author's data-safety philosophy as my compass.

**The philosophy:** browsers were long treated as traffic entrances, and today's AI browsers bolt on agents and chat panels to capture it. But browsing is the point. Research shows the AI feature people actually use most in a browser is translation. So Sinan's baseline: **AI quietly helps; it never steals the show.** Everything AI runs **locally** on small models — nothing leaves your Mac — and the AI parts are **optional**: without a model, Sinan is simply a clean, fast browser.

**Features** (all local, models downloadable in-app):
- Sidebar-first browsing: spaces, pinned tabs, favorites, folders, auto-archive — everything Cra does, now on Intel too
- Dual engine: Chromium pages (Chrome extensions, DevTools) with a one-click Safari engine switch (DRM, payment flows)
- AI Tidy: auto-group Today tabs (undoable, learns your domain rules), tidy tab titles on pin, smart download renaming
- Semantic history search (vector + keyword RRF fusion) in the command bar
- Translate-on-selection, fully offline
- Media distillation: turn a video page's audio into an edited transcript + summary note (Markdown, your vault)
- User memory for tidying, viewable and clearable

**Roadmap:** a purpose-trained 0.5–0.6B model for the browser AI tasks; a HarmonyOS phone version; Windows.

**Why "Sinan" (司南):** the Warring-States *Guiguzi* and the Eastern-Han *Lunheng* describe the sinan — a ladle carved of lodestone resting on a smooth plate, its handle always pointing south. It is Chinese civilization's earliest answer to "navigation," and pointing people toward what they're looking for is exactly what a browser does. The name turns the product from a tool into a heritage.

**Download:** see [Releases](https://github.com/jerry699/cra/releases). Intel (x86_64) and Apple Silicon (arm64) builds; first launch may need a right-click → Open (unsigned builds).

**License:** MIT, same as upstream.
