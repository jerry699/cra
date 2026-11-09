# Cra 本地模型：方案与实施计划

基线：jerry699/cra `daily` 分支（3e3b3bc6，2026-11-08，线上模型版）。
本项目 cra-local 与线上版并行开发，互不冲突。日期：2026-11-09（阶段 0 实测已完成）。

## 一、结论

1. 在现有两条模型路径（Apple 智能、线上 provider）之外，加第三条：**本地小模型**。不改现有两条的行为。
2. 默认模型 **Qwen3.5-2B Q4（约 1.2GB，常驻约 1.9GB）**；8GB 机器默认 **0.8B（约 0.5GB，常驻约 0.8GB）**，只开 Titles。档位只是推荐值，设置页可自由切换。
3. 本地档的能力边界由实测决定：
   - **Tidy Titles：0.8B 就能做好**（实测 3/3 正确），这是本地档的第一顺位功能。
   - **Tidy Tabs：只有 2B 能接住，且必须改成"两段式"**（先定主题名，再逐页归组），60 个标签约 2–3 分钟。一次性分组对 0.8B/2B 都不成立。用户已确认接受这个耗时。
   - **Tidy Downloads：暂不进本地档**（0.8B 原样返回，2B 日期解析出错）。
4. 模型不进安装包，首次用到才下载。**一份模型清单管现在和未来的所有 AI 功能**——这是扩展问题的答案，见第六节。
5. 本地路径数据不出机。三条路径里，只有它同时覆盖 Intel Mac 和中国用户，又守住 README "nothing goes to a server" 的承诺。
6. 小内存机器（8–16GB）靠"分档 + 空闲卸载 + 前缀快照"顶住，不靠砍上下文——砍到 4k 也只省 0.3GB。见第四节。
7. Intel 档不启用独立显卡：本机 Radeon Pro 555X 实测生成比 CPU 慢 7–13 倍，默认并发还会触发驱动崩溃。固定 CPU + Accelerate。见第四节。
8. 选型窗已关：Qwen2.5-1.5B 与 Gemma 3 1B 同标准实测均弱于 Qwen3.5-2B，CPU 这档没有更合适的替换。见第十节。

## 二、现状（已核实代码）

- `daily` 已是双路径：Apple FoundationModels 优先；不可用则走 `MaxRemote`（OpenAI 兼容端点，DeepSeek/Qwen/GLM/Custom 预设，key 存 Keychain）。
- 三个功能：Tidy Tabs（标签分组）、Tidy Titles（标签改名）、Tidy Downloads（下载文件名）。模型调用都收口在各 Service 的 `ask()`。
- CraCore 已有输出校验：`TidyTabs.plan()` 查 id 范围/去重/名称截断，`TidyTitleRules` 清理标题。**校验与模型无关，本地模型直接复用，一行不动。**
- 所以 Titles/Downloads 的本地化 = `ask()` 加一个分支 + Status 加本地状态 + 一个下载器；Tabs 另需两段式协议（见第五节）。

## 三、阶段 0 实测结果（2026-11-09，本机 i7-8750H / 16GB）

测试环境：llama.cpp b8210 **本机原生编译**（AVX2/FMA + Accelerate，Metal 关）。brew 预编译版是 SSE 基线，同一模型慢一倍，不作为依据。贪心解码（temperature 0）、关思考，经 llama-server 走与生产一致的聊天模板路径。测试机连续满载会降频到 46–48%，下表速度均在 `CPU_Speed_Limit=100` 状态下测。

速度与内存（8k 上下文）：

| 模型 | 预处理 pp512 | 生成 tg128 | 60 标签任务实测生成 | 进程内存 |
| --- | --- | --- | --- | --- |
| Qwen3.5-0.8B Q4_K_M | 72–102 t/s | 9.8 t/s | 8.3 t/s | 1.1GB |
| Qwen3.5-2B Q4_K_M | 50 t/s | 6.15 t/s | 5.5 t/s | 2.2GB |

质量结论（每项都用真实 Tidy prompt 格式）：

- **Tidy Titles**：0.8B 3/3 正确（`京都清水寺游玩攻略`、`哔哩哔哩`、`收件箱`）。2B 需在 system 后追加"只输出新名字"一句才 3/3——不加这句会把中文标题翻成英文长句。
- **Tidy Downloads**：0.8B 0/2（原样返回），2B 1/2（`Qwen3.5 技术报告.pdf` 对，飞书截图日期解析错）。
- **Tidy Tabs（60 个中文标签）**，逐条试过：
  - 一次性分组（原 prompt + GBNF）：两个模型都失败（全部塞进一组、id 重复）。
  - 加 JSON schema 提示 / 开思考 / 减到 30 个标签：仍失败；开思考后输出散文，不守 JSON。
  - 逐标签页打主题标签：失败，60 页给出 52 个互不相同的标签，不会聚合。
  - **两段式（先提 3–6 个主题名，再闭卷把每个 id 归到主题编号）+ 紧凑 GBNF：2B 成功**。两套标签集（60 个旅行/开发/购物…、48 个报税/健身/装修…）均验证：60/60 覆盖、各簇 7–8/8 命中；合并有语义合理性（开发+文档、新闻+视频）。0.8B 失败（只会提"日本…"系列主题，收不了尾）。
  - 耗时：2B 两段式约 2–3.5 分钟（含降频影响；满血约 2 分钟）。

由此确定的三条设计结论：

1. **默认 2B，0.8B 是低内存降级档**（只做 Titles）。
2. **分组必须两段式**：模型只做"起名"和"选择题"，id 不重不漏由代码保证（复用 `TidyTabs.plan()`）。这也意味着本地分组不是"换一个 ask() 分支"那么简单，要先加协议。
3. **2B 6.15 t/s 未达原定 8 t/s 验收线，但用户已确认接受**（分组 2–3 分钟）。小内存机器的应对见第四节。

## 四、小内存与老机器优化（8–16GB）

先给结论：模型本身不是小内存机器的瓶颈，**CEF 和系统才是**。2B 常驻约 1.85GB，0.8B 约 0.8GB；把上下文从 8k 压到 4k 只省 0.3GB。真正有效的是"不用就卸载"和"前缀只算一次"。

### 实测（同一台 16GB 机器，逐项变量对比）

- **内存地板**：2B 1853MB（1k 上下文）～1891MB（4k）～2170MB（8k）；0.8B 811MB（1k）～880MB（2k）～1.1GB（8k）。**4k 以下上下文对内存几乎没有影响，8k 才多 0.3GB。**
- **线程**：0.8B t2 8.42 / t4 10.13 t/s；2B t2 4.22 / t4 5.7–6.3 t/s。**两个线程也能跑**——小模型是内存带宽受限，不是核数受限。
- **两段式 60 标签的 prompt 实测 1153 token**，4096 上下文足够，不需要 8k。
- **Titles 单次 prompt 约 250 token**，1024 上下文就够；前缀状态快照约 20MB（SSM 状态占大头，与前缀长度关系不大）。

原始数据与测试程序：`bench/results-lowmem/summary.txt`、`bench/reuse_test.cpp`。

### 分档推荐（只是默认值，用户可改）

| 内存 | 默认模型 | 默认开放 | 依据 |
| --- | --- | --- | --- |
| 8GB 及以下 | 0.8B（0.8GB） | 仅 Titles | CEF 1–2GB + 系统 2–3GB，再塞 1.9GB 会挤压换页 |
| 12GB 及以上 | 2B（1.9GB） | Tabs + Titles | 本机 16GB 实测稳定 |

- 清单里每个模型带 `minRAM`，低于时二次确认并显示预计占用，**不禁止选择**——模型用户可以自由选。
- 8GB 机器上 Tabs 不隐藏，点下去先说明"需要 2B、预计 N 分钟、内存可能不足"。

### 运行期七条（helper 内实现，主 App 不改逻辑）

1. **懒加载 + 空闲卸载**：启动不加载，首次 Tidy 才加载；空闲 60 秒卸载，RSS 回到几十 MB。模型文件留在 page cache，未被回收时再次加载不读盘。
2. **只用 mmap，不 mlock**：权重是干净的文件页，内存紧张时系统可直接回收，不会把机器拖进 swap。
3. **上下文按功能给**：Titles 1024、Tabs 4096。不统统一把 8k。
4. **线程 4**（双核机器 2）：不抢 CEF 的核，也较少撞温度墙。
5. **串行单请求**：同一时刻只算一个；连续 pin 标签产生的改名请求排队，不并发抢内存和 CPU。
6. **前缀状态复用**（Titles 的关键）：`TidyTitles.prompt()` 每次的指令和 6 个示例完全相同，只有最后一行标题在变（稳定前缀约 230 token）。helper 在算完稳定前缀后存一份状态快照，之后每个改名只算新标题那十几个 token。**Qwen3.5 是混合 SSM 模型，不能把 KV 回退到前缀**（`llama_memory_seq_rm` 部分删除会失败，llama-server 的 `cache_prompt` 因此一直不生效），必须用 `llama_state_seq_get_data/set_data` 整段恢复。已实测（`bench/reuse_test.cpp`）：快照 19.6MB、恢复 3–7ms；真实约 250 token 的 prompt 原本每次全量预处理要 5–8s（阶段 0 server 实测），复用后只算后缀约 0.5–0.8s。单次改名合计约 2–3s（2B）/ 1–2s（0.8B）。
7. **内存压力兜底**：主进程订阅 `DispatchSource.makeMemoryPressureSource`，warning 就取消在跑的请求并卸载；加载前查 `vm_statistics64` 的 free+inactive，不足"模型体积 + 800MB"就不加载并提示。

### 热降频

老机器散热差，本机满载就掉到 46% 频率，速度差一倍。App 读 `ProcessInfo.thermalState`：serious/critical 时暂停 Tabs、线程降到 2。UI 只显示进度和"设备温度较高"，不承诺完成时间。

### AMD 独显能用吗：实测不用

本机是 MacBook Pro 15" 2018，Radeon Pro 555X 4GB（Metal 2）。llama.cpp 能枚举到这块卡，但：

- **默认并发编码直接崩**：0.8B/2B 都在 `llama_decode` 里 SIGSEGV，栈在 `amdMtlBronzeCmdBufUpdateRsrc`。
- 加 `GGML_METAL_CONCURRENCY_DISABLE=1` 能跑，但比 CPU 慢得多：

| 模型 | GPU pp512 / tg128 | CPU+Accelerate pp512 / tg128 |
| --- | --- | --- |
| 2B | 32.6 / 0.90 t/s | 50 / 6.15 t/s |
| 0.8B | 58.8 / 0.75 t/s | 72–102 / 9.8 t/s |

- 原因：ggml 检测到该卡不支持 simdgroup matrix/reduction；Qwen3.5 的 SSM 混合层在 Metal 上走低效路径；旧 AMD Metal 驱动还有崩溃 bug。
- 结论：**Intel 档固定 CPU + Accelerate，不提供 GPU 开关**。开了只会更慢、更热，还可能崩。Metal 只在 Apple 芯片上有意义（M 系列走默认 Metal，代码保留自动选择即可）。

原始数据：`bench/results-gpu/summary.txt`。

### 对 8GB 老机的实话

8GB 多是 2015–2017 年的双核 13"。按本机两线程实测推算，0.8B 改名约 2–4 秒一次；Tabs 默认不开，硬开约十分钟。本地档在这里只承诺三件事：数据不出机、免费、断网可用；速度不如新机，不掩饰。

## 五、架构

新增组件：

- **MaxLocal.swift**：本地后端，与 `MaxRemote` 平级。Titles/Downloads 接口同形 `ask(instructions:prompt:json:)`；Tabs 提供两段式方法 `topics(...)` + `assign(...)`。
- **CraInferenceHelper**（XPC 进程）：内嵌 llama.cpp 静态库（MIT）。无网络权限，模型目录只读，崩溃不拖垮主进程。内存策略（懒加载、空闲卸载、前缀状态快照、压力响应）都收在这一层，见第四节。
- **CraCore 侧的两段式协议**（新增，与模型无关可单测）：主题名列表 → 校验（3–6 个、去重、长度截断）→ 逐页归组 → 复用 `TidyTabs.plan()` 落盘。0.8B/2B 共用同一套校验。
- **GBNF grammar**：两段式各一个紧凑语法（无空白 JSON，省 token）；Titles/Downloads 不需要（输出是纯文本）。解析后仍过 CraCore 校验。
- **本地档专属 prompt**：Tabs 用两段式指令；Titles/Downloads 在系统提示后追加"只输出名字"。不改 Apple 路径的 prompt。
- **ModelCatalog.json**：模型清单，见第六节。每条带 `minRAM` 与预计耗时，供分档和 UI 提示。
- **ModelDownloader**：下载 / 断点续传 / SHA256 校验 / 删除。
- **MaxPane**：加本地模型状态、下载引导、模型管理入口；显示内存占用与预计耗时；分组时给进度和取消。

路径选择（建议默认）：Apple 可用 → Apple；否则本地模型已就绪 → 本地；否则用户配置了线上 → 线上。设置页可显式指定。本地优先于线上的理由：免费、离线、无需 key。最终由作者定。

x86_64 构建：llama.cpp 开 Accelerate、关 Metal（AMD 独显实测更慢且会崩，见第四节；Apple 芯片默认走 Metal）。helper 单独签名、公证。

## 六、模型分发设计（回答"以后扩展 AI 功能，用户下模型怎么考虑"）

核心原则：**按模型下载，不按功能下载。**

1. **功能声明能力，不声明模型。** 每个 AI 功能在代码里声明能力标签（如 `text`、`json`、`zh`）。清单把能力映射到模型。新功能上线先查现有模型能否覆盖。
2. **一份清单（ModelCatalog）。** 每个模型一条：id、版本、体积、SHA256、能力标签、最低内存、**双源下载 URL（魔搭 + HuggingFace，平级，不分主备）**。清单随 App 版本发布，模型版本钉死。选源规则：按系统地区给默认（中国大陆 → 魔搭，其它 → HF），一源失败自动换另一源，设置页可手动切换。两源必须是同一发布者的同一文件，下载后 SHA256 校验一致才用。已验证（2026-11-09）：魔搭与 HF 的 `unsloth/Qwen3.5-{0.8B,2B}-GGUF` Q4_K_M 文件字节数与 SHA256 完全一致——0.8B：532,517,120 字节，`bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517`；2B：1,280,835,840 字节（约 1.19GB），`aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223`。两个文件均已从魔搭实际下载并与 HF 公布值比对通过。
3. **首次启用才下载。** 下载前明示体积和用途；支持暂停、续传、删除。多个功能共享同一模型，只下一次。
4. **按内存分档。** 8GB 档推荐 0.8B（只开 Titles），其余推荐 2B（Tabs/Titles 全开）。用户可覆盖。依据：第四节实测。
5. **磁盘护栏。** 下载前检查剩余空间（建议 ≥ 模型体积 × 2）；设置页显示已下模型和占用，一键删除（Firefox 的 On-Device AI 页面同款模式）。
6. **未来扩展的三种情况：**
   - 新功能现有模型能覆盖 → 零下载，直接用。
   - 需要更强文本模型 → 清单加一条，按需下载，旧模型可删。
   - 需要多模态（看图）→ 清单加多模态条目（如 Gemma E2B 级），同样按需。
7. **更新不静默。** 新模型版本随 App 更新进清单，用户确认后下载，SHA256 通过才切换。
8. **永远不做：** 安装包内置权重；静默下载；开放任意 GGUF 导入。

## 七、安全（给作者的交代）

- 无监听端口、无模型导入入口、无 API key。攻击面比 Ollama 小（Ollama 今年有 CVSS 9.1 的恶意 GGUF 漏洞 CVE-2026-7482）。
- 模型只来自清单：HTTPS + 版本钉死 + SHA256 校验。
- helper 进程无网络权限；模型输出必须过 CraCore 校验才落地；网页内容视为不可信输入（防提示注入）。
- llama.cpp 钉版本、随 App 更新、订阅安全公告。今年已有多个 GGUF 解析 CVE，引擎要当浏览器组件维护，不能当普通依赖放任。

## 八、实施计划

### 阶段 1：最小闭环——Tidy Titles 走本地（1–2 天）
- cra-local 导入 daily 源码；llama.cpp 静态库嵌入 + helper 进程；模型手动放置，不做下载器。
- 只接 Tidy Titles（0.8B）：prompt 追加"只输出名字"，复用 `TidyTitleRules`。
- 内存四件事一起做：1024 上下文、4 线程、空闲 60 秒卸载、前缀状态快照复用（Qwen3.5 有 SSM 层，不能回退 KV）。快照要按 token 前缀严格校验，不匹配或换模型就全量重算。
- 验收：断网可用；三个测试用例全对；常驻 <0.9GB；空闲后回落到几十 MB；连续改名 10 次内存不增长。

**实现状态（2026-11-09）：阶段 1 验收通过。**

- `CraInferenceHelper`：C++ 常驻子进程，stdin/stdout 二进制协议，llama.cpp 静态链接，无网络；空闲 60 秒自行退出。前缀复用用状态快照（SSM 层不能回退 KV），快照按 token 前缀校验，不匹配就全量重算。
- Swift 侧：`MaxLocal`（开关、模型路径、helper 路径）+ `LocalInference` actor（一次一个请求、30 秒看门狗、失败即重启进程）；Tidy Titles 回退链变为 Apple Intelligence → 本地模型 → 用户自己的 provider。
- 设置页：Max 卡片新增 "Local model" 开关；状态新增 `.local`，阶段 1 只放开 Tidy Tab Titles（阶段 2 起 2B 在位时也放开 Tabs，见下）。
- 引擎实测（`bench/results-helper/summary.txt`）：3/3 标题正确且保持中文（用 App 实际下发的 system 提示词也复测 3/3）；首次 3.0–3.6 秒（加载 + 全量预填），之后 0.37–0.97 秒；常驻 875MB；连续 10 次不增长；空闲退出后归零。
- App 内实测（`bench/results-helper/app-summary.txt`，`bench/app_local_test.sh`）：断网（只连 127.0.0.1 fixture）pin 标签后改名为"收件箱"；helper 830MB、0 个网络套接字；空闲 60 秒退出；App 正常退出。
- 与计划的偏差：helper 由 App 以子进程 stdio 拉起，未用 XPC；XPC、沙箱与签名加固留在阶段 3。
- 构建注意：本机验证包用 Spotify 官方 CEF（`CRA_ALLOW_STOCK_CEF=1`，无 H.264/AAC、共享 Keychain 项），分发仍须换回 fork 的
  CEF；`scripts/build.sh` 在签名前清理 xattrs（vendor 目录在 ~/Documents 下会被文件提供商打上 FinderInfo）。
- llama.cpp 静态库已按 App 的 14.0 目标重编（`scripts/build-llama.sh`，原先按 SDK 默认 15.0 构建，链接时会报版本警告）。脚本会逐库核对 minos，重链后 helper 与 App 主程序也都是 14.0。

### 阶段 2：Tidy Tabs 两段式 + 下载器（3–4 天）
- 两段式协议（topics → assignments → 代码归组 → `TidyTabs.plan()` 校验）落 CraCore，单测覆盖非法 id/重复/空组；2B 档接入，4096 上下文，UI 给进度与取消。
- ModelCatalog + 下载 / 续传 / 校验 / 删除；MaxPane 状态与管理入口；按内存自动选档（8GB → 0.8B 仅 Titles），显示内存占用与预计耗时。
- 验收：两套测试标签集达到阶段 0 水平；首次启用有下载引导；删除模型后功能回到未启用态。

**实现状态（2026-11-09）：两段式 Tabs 与下载器均已接入，并在真实 App 内跑通。**

- CraCore：新增 `TidyTabsTwoStage`（topics → assignments → proposals，两段 GBNF）。解析容错、非法 id/重复/越界丢弃、主题名截断（24 字）、最多 6 组；最终仍由 `TidyTabs.plan()` 把关。`swift test --filter TidyTabs` 12 项全过。
- helper：新增 op 3（带 GBNF 约束采样），采样链为 grammar + greedy；上下文由 argv[3] 指定（Titles 1024，Tabs 4096）。修掉一处崩溃：`llama_sampler_sample` 内部已调用 accept，外面再 accept 会让语法栈空抛异常。
- Swift：`MaxLocal` 按内存选模（>8GB 用 2B，否则 0.8B），`canTidyTabs` 要求 2B 在位；`LocalInference` 支持 grammar / maxTokens / context / timeout；`.local` 状态下 Tidy Tabs 走 `MaxLocal.tidyTabs`；设置页 Tabs 行随 2B 放开，Local model 文案区分"只 Titles"与"Titles + Tabs"。
- App 内验收（`bench/results-helper/tabs-app-summary.txt`，`bench/app_tabs_test.sh`）：60 个本机标签页、断网、真实 2B；`modelAvailable=0, canTidy=1, loose=60` 确认走本地路径；6 组、覆盖 60/60、131.8 秒；helper 峰值 2011MB、0 个网络套接字、空闲 60 秒退出、App 正常退出。六个植入簇的主组命中 6–8/8（两簇 6/8，未全部达到 ≥7/8）。Titles 回归同时通过（834MB）。
- 提示词：保留阶段 0 原措辞。另试"禁止拆分同一主题/合并无关主题"（视频簇 5/8）与"4–8 个主题"（购物簇 5/8），均未改善，弃用；2B 对标签顺序敏感，这是当前档位的质量上限。
- 下载：`ModelCatalog`（钉死 id/文件名/字节数/SHA256/能力，魔搭与 HF 两个平级源，按地区默认）在 CraCore；抓取器 `ModelFetch` 也在 CraCore（8 段并发 Range、断点续传、只认 206、拼装时算 SHA256 + 查 GGUF 魔数、失败删不可续分片）。App 侧 `ModelDownloader` 只做状态与磁盘护栏（≥2× 体积），`MaxPane` 每个模型一行：预计体积与能力、下载前确认来源与"不上传"、进度与取消、删除。
- 下载验收（`bench/results-helper/download-app-summary.txt`，`bench/app_download_test.sh`）：本地 6 项 Range 测试全过；真实魔搭 0.8B 532MB / 36.4 秒 / SHA256 一致；App 内取消时保留 63MB 分片，续传后校验通过，文件落在数据目录的 `Models/`，删除后文件与暂存都清掉。Tabs 回归另跑一轮：覆盖 60/60，5 组，簇纯度 4–7/8（顺序不同所致，见上）。
- 测试抓到两个真 bug 并已修：`URL.resourceValues` 缓存文件大小导致续传判断永远为 0；暂存目录 URL 尾斜杠不等导致同一目录被当旧目录删除。模型目录改用 App 数据目录（`CRA_DATA_DIR` 测试实例不再动真实目录）。
- 分阶段进度与取消（`bench/results-helper/tidy-cancel-summary.txt`，`bench/app_tidy_cancel_test.sh`）：整理时分隔行用 Clear 的位置显示 "Step 1 of 2 · Naming groups…" / "Step 2 of 2 · Sorting tabs…"，扫帚变成 Cancel。点击即取消：取消 Task、立刻终止 helper 进程、分隔行复位，晚到的结果直接丢弃。helper 的取消入口做成 nonisolated（锁保护的 `HelperSlot`），否则会排在 actor 里那次阻塞的管道读后面，永远等不到。
- 取消验收（真实 App、60 标签、2B、断网）：开始 10.5 秒后取消，"Tidy Tabs: cancelled"、helper 立即退出、0 个分组被应用；紧接着重跑完整流程，6 组 / 覆盖 60/60 / 126.1 秒，helper 2018MB、0 套接字、空闲退出、App 正常退出。同一脚本再跑一轮：5 组 / 60/60 / 187.2 秒，其余一致。
- 顺带修一个质量退化：取消后的重跑曾把 60 个标签全塞进一个主题（stage 2 返回 `[60,0,0,0,0,0]`）。两次 prompt 指纹完全相同且 helper 是新进程，排除取消的影响；根因是 fixture 标题未加载完导致 prompt 变化（2575 / 2840 / 2867 字节），2B 对此很敏感。加一道护栏：≥3 个主题且 ≥10 个标签时，若全部落进同一主题则丢弃本次结果，不落盘。
- 调试开关 `CRA_TIDY_DEBUG=1`：记录 prompt 字节数与 FNV 指纹、主题名、每个主题的标签数，排查"同样的输入为什么分组不同"时先看指纹。

### 阶段 3：加固交付（1–2 天）
- XPC 沙箱、磁盘护栏、helper 签名公证、给作者的方案说明文档。
- 内存压力与热状态实测：制造内存紧张，确认取消请求并卸载；thermalState 到 serious 时暂停 Tabs。
- 用更多样例重测 Tidy Downloads，达标再决定是否开放本地档。
- 验收：第七节安全清单逐项通过；dmg 在 Intel 真机安装跑通。

**实现状态（2026-11-09）：运行期护栏与 macOS 14 构建基线完成；打包加固未做。**

- 策略在 CraCore（`LocalInferenceLimits`）：模型体积 + 800MB 才算放得下；thermal serious/critical 暂停 Tabs；线程 4，热时 2。
- App 侧 `LocalRuntime`：订阅 `thermalStateDidChangeNotification` 与内存压力 source；压力非 normal 时终止 helper 并取消所有在跑的 Tidy；加载前查 free+inactive+speculative；分隔行新增暂停态，悬停显示 "Low memory — Tidy paused" / "Mac is warm — Tidy paused"。
- helper 线程数改由 argv[4] 给（默认 4）；线程变化会重启 helper。
- 验收（`bench/results-helper/local-guards-summary.txt`，`bench/app_local_guards_test.sh`、`bench/app_local_budget_test.sh`）：60 标签分组中注入内存警告 → 同秒取消、helper 退出、0 组落盘；压力/过热时开始被拒并给出原因；恢复后 5 组 / 60:60 / 172.3 秒、helper 2014MB、0 套接字、空闲退出。加载预算把可用内存钉到 1MB → 拒绝开始、helper 未启动、0 组。CraCore 701 项测试通过。
- 真实系统级内存压力与真实 serious 热状态没有人为制造（`memory_pressure -l` 要 root，制造压力会让这台唯一机器进 swap）；钩子驱动的是与真实通知相同的处理函数。
- 给作者的英文说明已写：`docs/local-model-upstream.md`（本地路径是什么、安全约束、组件分工、实测、待作者定的五个问题）。
- 签名链路已就绪：`scripts/build.sh` 在设置 `CRA_SIGN_IDENTITY` 时对 helper 也用 hardened runtime + timestamp 签名，`scripts/release.sh` 走公证；缺的是 Developer ID 与凭证。
- 构建基线：`scripts/build-llama.sh` 按 App 的 macOS 14.0 目标构建 llama.cpp 静态库（原生 CPU、Accelerate、无 Metal/网络），自带 minos 核对；重编后 5 个库、helper、App 主程序全部 14.0，链接不再有版本警告。
- 自测包：`scripts/build.sh release` + `scripts/package.sh` 已产出 `build/dist/Cra.dmg`（0.1.0-local，ad-hoc 签名，官方 CEF），用于本机手动测试；`package.sh` 已改为从 /tmp 干净副本打包，避免 ~/Documents 的文件提供商扩展属性导致 codesign 校验失败（校验失败不修会导致分发/Keychain 异常）。
- 未做：XPC/沙箱（需作者定形态）、Developer ID 签名与公证、更多 Downloads 样例、分发用 Intel 真机 dmg（自测 ad-hoc dmg 已有）。

## 九、风险与对策

- **老 Intel 机器更慢**（本机 6 核满血 2B 6.15 t/s；限到 2 线程仍有 4.22，0.8B 有 8.42）→ 分组给进度条 + 可取消；设置页标明单次耗时；8GB 机器按第四节只开 Titles。
- **0.8B 只能 Titles** → 8GB 机器的分组继续走苹果/线上，功能不缺失。
- **热降频**：本机连续满载会降到 46%，速度能差一倍 → App 读 thermalState，serious 时暂停 Tabs；UI 不做速度承诺，只做进度反馈。
- **内存被 CEF 挤爆** → 懒加载 + 空闲卸载 + mmap + 内存压力取消；加载前检查可用内存。
- 单源下载慢/失败 → 自动切换另一源 + 断点续传 + 校验重试。
- llama.cpp 漏洞 → 钉版 + 跟公告 + helper 进程隔离。
- 与线上版漂移 → cra-local 定期 merge daily；本地路径是纯增量，冲突面小。

## 十、模型选型调研（2026-11-09 完成）

为什么重开选型：Qwen3.5 是 SSM 混合结构，Metal 上几乎不可用；2B 做分组也只是刚刚够。除 Qwen 外需要看一圈。

先写死评估标准，避免拍脑袋：

1. Tidy Titles 3/3 正确且保持中文；
2. Tidy Tabs 两段式 60/60 覆盖、主簇 ≥7/8；
3. CPU 生成 ≥4 t/s（4B 档放宽到 3 t/s），常驻内存 ≤2.5GB；
4. 许可证允许随开源 App 分发、允许商用；
5. GGUF 魔搭与 HF 双源可得、SHA256 可比对；
6. llama.cpp b8210 支持该架构。

候选（体积为 Q4_K_M 或官方 QAT q4_0）：

| 模型 | 体积 | 许可证 | 魔搭 | 状态 |
| --- | --- | --- | --- | --- |
| Qwen3.5-0.8B / 2B | 0.5 / 1.2GB | Apache 2.0 | 有 | 当前基线，已验证 |
| Qwen2.5-1.5B | 1.12GB | Apache 2.0 | 有 | **已测，淘汰**：CPU 49/4.9 t/s，Titles 2/3，Downloads 1/2，Tabs 第一段就崩 |
| Qwen2.5-3B | 2.10GB | Apache 2.0 | 有 | 不测：1.5B 已失败，按参数推算 tg 约 2.5–3 t/s，低于底线 |
| Gemma 3 1B QAT | 1.00GB | Gemma Terms（非 OSI） | 有 | **已测，淘汰**：CPU 102/8.8 t/s，但标题全英文/误译，Tabs 第一段乱码 |
| Gemma 3 4B QAT | 3.16GB | Gemma Terms（非 OSI） | 有 | 不测：4B 纯 CPU 约 2–3 t/s，只有 GPU 可用才值得看 |
| MiniCPM3-4B | 2.47GB | MiniCPM 许可（非 OSI） | 有 | 不测：同上，且许可证非 OSI |
| Phi-4-mini 3.8B | ~2.5GB | MIT | 无官方 GGUF | 双源不满足 |
| InternLM2.5-1.8B | — | Apache 2.0 | 无官方 GGUF | 双源不满足 |

判断顺序：

1. 先测 Qwen2.5-1.5B（纯 Transformer）：同一套 Tidy prompt 与 Qwen3.5 对比。AMD 那次先不跑——驱动崩溃过，等模型筛完再说。
2. 再测 Gemma 3 1B QAT：体积接近 0.8B，看质量与许可证的取舍。
3. 若 1–1.5B 分组都不行，再测 Gemma 3 4B；只有 AMD 能跑快才用，4B 纯 CPU 约 2–3 t/s，分组会超过 5 分钟。
4. 4B 及以上只能 CPU 的，直接放弃，不如留在 2B。

Qwen2.5-1.5B 实测（2026-11-09 晚，满速段）：

- 速度：pp512 49.1 t/s、tg128 4.9 t/s；短上下文生成 5–9 t/s。**比 2B 的 Qwen3.5 慢**，说明 SSM 在纯 CPU 上确实省算力。
- 内存：ctx8192 常驻 1.34GB，比 2B 的 2.17GB 低。
- 前缀缓存：可用（同一 system prompt 第二次只算 30 token），没有 SSM 的整段状态快照问题。
- 质量：Titles 2/3（"哔哩哔哩…" 给了 "Bilibili"，没保持中文），Downloads 1/2；Tabs 两段式第一段就失败——无视"3–6 个主题"，一口气列了十几个细碎主题并重复刷屏，JSON 也收不了尾。
- 结论：**淘汰**。速度和内存有优势，但分组能力和中文标题都不如 Qwen3.5-2B。

Gemma 3 1B 实测（2026-11-09 晚）：

- 速度：pp512 101.6 t/s、tg128 8.8 t/s，比 Qwen3.5-0.8B（72–102 / 9.8）接近；内存 1.15GB@8k。
- 质量：Titles 0/3——把"京都清水寺"译成 "Kyoto Imperial Palace - Kyoto Travel"（意思也错了），"哔哩哔哩"给 "Bilibili"，"收件箱"给 "Mail"，全部丢中文。Downloads 0/2，一条原样回显、一条保留站点名。
- Tabs 两段式：第一段 GBNF 内只吐出 `{"topics"` 加一串空格，直接失败。
- 模板已确认把 system 并入首轮，不是提示词没传进去。
- 结论：**淘汰**。体积接近 0.8B 但中文能力更差，且许可证不是 OSI，没有替换价值。

选型结论：**CPU 这一档没有比 Qwen3.5 更合适的模型**。1–1.5B 的非 Qwen 候选在标题和分组上都明显更弱；3B/4B 纯 CPU 低于 4 t/s 底线，不测。唯一可能翻盘的是"AMD 能跑快"，但 Metal 在本机崩过驱动，暂不验证，也不据此改默认档。

已知风险：Gemma/MiniCPM 许可证不是 OSI，随 App 分发要作者确认；Gemma QAT 只有 q4_0；MiniCPM3 的架构支持待验证；本轮的"AMD 不可用"只针对 Qwen3.5，不能推广到纯 Transformer。

下一步：选型收口，默认维持 Qwen3.5-2B；回到阶段 1 实现（本地 Titles）。Qwen2.5-3B / Gemma 3 4B 不测——纯 CPU 低于 4 t/s 底线，只有将来 GPU 路径被证明安全才值得回头看。

## 十一、待确认

1. 路径优先级：默认本地 > 线上，是否接受？

## 更新记录

- 2026-11-09：下载源定为魔搭 + HF 双源平级（用户确认，兼顾国内外用户），不再是"主源 + 镜像"。魔搭端模型文件已验证存在。
- 2026-11-09：阶段 0 实测完成。新增第三节；由此改写结论、架构（两段式）、分档与实施计划；Downloads 暂不开放本地档。
- 2026-11-09：用户确认 2B 为默认、接受分组 2–3 分钟、档位由用户自由选择。新增第四节小内存优化（8–16GB）：补测线程、上下文与内存（2B 1.85–2.17GB、0.8B 0.81–1.1GB；t2 仍可用）。发现 Qwen3.5 为 SSM 混合模型、前缀不能回退 KV，改用状态快照复用并在 `bench/reuse_test.cpp` 实测通过（19.6MB / 恢复 3–7ms）。实施计划与验收相应更新。
- 2026-11-09：实测 Radeon Pro 555X 独显：llama.cpp Metal 默认并发 SIGSEGV，规避后 2B 生成 0.90 t/s（CPU 6.15）、0.8B 0.75 t/s（CPU 9.8），不可用。Intel 档固定 CPU + Accelerate；数据在 `bench/results-gpu/summary.txt`。
- 2026-11-09：开模型选型调研（第十节）。候选与标准已定；Qwen2.5-1.5B 已下载并校验（SHA256 `6a1a2eb6…`，魔搭与 HF 公布值一致）。已核魔搭可得性：Qwen2.5-1.5B/3B、Gemma 3 1B/4B QAT、MiniCPM3-4B；Phi-4-mini 与 InternLM2.5-1.8B 无官方 GGUF，双源不满足。选型结果出来前，Qwen3.5 仍是默认基线。
- 2026-11-09 晚：Qwen2.5-1.5B 测完并淘汰（49/4.9 t/s、1.34GB、Titles 2/3、Downloads 1/2、Tabs 第一段失败）；顺带确认纯 Transformer 的前缀缓存可用。Gemma 3 1B 开始下载（SHA256 `95e5b8d8…`，1,003,541,152 字节）。
- 2026-11-09 晚：Gemma 3 1B 测完并淘汰（102/8.8 t/s、1.15GB，Titles 0/3、Downloads 0/2、Tabs 乱码）。**选型收口：Qwen3.5-2B 保持默认，0.8B 保持低内存档。**
- 2026-11-09 晚：阶段 1 落地并通过验收。`CraInferenceHelper`（llama.cpp 子进程 + stdio 协议 + 状态快照复用）与 Swift 侧 `MaxLocal`/设置接入完成；引擎 3/3 正确、875MB、10 次不增长、空闲退出；真实 App 内断网 pin 改名成功、helper 830MB 且无网络连接。下一步进入阶段 2（Tabs 两段式 + 下载器），分发前补 macOS 14.0 静态库重编与 fork CEF 回归。
- 2026-11-09 晚：阶段 2 的 Tidy Tabs 两段式落地并在真实 App 内跑通：60 标签 6 组、覆盖 60/60、131.8 秒、helper 2.0GB、断网、空闲退出；Titles 回归通过。提示词保留阶段 0 原措辞（两种改法实测都更差）。阶段 2 剩余：ModelCatalog/Downloader 与 MaxPane 下载引导、Tabs 分阶段进度与取消。
- 2026-11-09 晚：阶段 2 的下载器落地并通过验收。`ModelCatalog` + `ModelFetch` 进 CraCore（双源、8 段 Range、续传、SHA256 + GGUF 校验），设置页按模型给下载/进度/取消/删除与来源选择（下载与删除都要确认，不静默）；模型目录改走 App 数据目录。本地 6 项 Range 测试全过，697 项 CraCore 测试全过；真实魔搭 0.8B 36.4 秒、SHA256 一致；App 内取消→续传→校验→删除整条链路通过。修掉两个会破坏续传的真 bug（URL 资源值缓存大小、暂存目录 URL 尾斜杠比较）。阶段 2 只剩 Tabs 分阶段进度与取消。
- 2026-11-09 晚：阶段 2 全部完成。Tidy Tabs 分隔行显示两步进度，扫帚变 Cancel；取消同时终止 helper（nonisolated 入口，不排 actor 的阻塞读），晚到结果丢弃。真实 App 验收：10.5 秒取消→helper 退出→0 分组→重跑 6 组 / 60 标签 / 126.1 秒；再跑一轮 5 组 / 187.2 秒，helper 2.0GB、0 套接字、空闲退出、正常退出。另加护栏：≥3 主题且 ≥10 标签时禁止全部落进同一主题（取消后重跑曾触发一次，指纹证明与取消无关，是 fixture 标题未加载完导致 prompt 变化）。下一步阶段 3：加固与分发。
- 2026-11-09 晚：阶段 3 的运行期护栏落地。`LocalInferenceLimits`（预算 +800MB、热暂停、线程 2/4）进 CraCore 并有 4 项单测；`LocalRuntime` 订阅内存压力与热状态，压力时终止 helper 并取消在跑的 Tidy；加载前查可用内存；分隔行可显示暂停原因；helper 线程数改由 argv[4] 传入。真实 App：分组中注入内存警告 → 同秒取消、helper 退出、0 组落盘；压力/过热时拒绝开始；恢复后 5 组 / 60:60 / 172.3 秒；可用内存钉到 1MB → 拒绝且不起 helper。CraCore 701 项全过。真实系统级压力与 serious 热未制造（钩子走同一处理函数）。阶段 3 剩余：XPC/沙箱、签名公证、作者文档、更多 Downloads 样例、Intel 真机 dmg。
- 2026-11-09 晚：阶段 3 再补两项。英文说明给作者：`docs/local-model-upstream.md`（定位、安全约束、组件分工、实测、五个待定问题）；Titles 回归在护栏 build 上通过（0.8B，35→3 字，833MB、0 套接字、空闲退出）。核对 `scripts/build.sh`：设置 `CRA_SIGN_IDENTITY` 时 helper 已随 App 用 hardened runtime + timestamp 签名，公证走现有 `release.sh`，只缺 Developer ID 与凭证。下一步：XPC/沙箱形态与作者对齐，然后 Developer ID + Intel 真机 dmg。
- 2026-11-09 晚：补齐 macOS 14 构建基线。新增 `scripts/build-llama.sh`（钉死部署目标 14.0、原生 CPU、Accelerate、Metal/CURL 关闭、只出静态库，并逐库核对 minos；注意 `otool | awk` 在 pipefail 下会因 SIGPIPE 静默失败，已改为落临时文件）。重编后 5 个静态库、helper、App 主程序 minos 均为 14.0，链接无版本警告。回归：Titles 0.8B 35→3 字 / 833MB / 0 套接字 / 空闲退出通过；2B Tabs 跑两轮，进程与取消/空闲路径正常，但分组质量撞上已知波动——一轮整批退化被“单主题”护栏丢弃，另一轮 2 组（48 个挤进一组）/ 覆盖 59/60。同一编译器与 `-march=native` 下仅改 minos，不认为是重编回归；更像计划里记录的 fixture 标题加载差异导致 prompt 变化（2637→2699 字节）。证据：`bench/results-helper/local-titles-minos14.log`、`local-tabs-minos14.log`、`local-tabs-minos14-retry.log`。
- 2026-11-09 晚：产出可手动测试的本地包 `build/dist/Cra.dmg`（release、0.1.0-local、ad-hoc、官方 CEF，187.9MB）并校验通过；修复 `package.sh` 从 ~/Documents 直取 bundle 带入 FinderInfo、导致 codesign 报 detritus 的问题（改为 /tmp 干净副本打包）。给作者的英文说明扩写：新增“为什么不选 Ollama”（监听端口、生命周期、字节锁定、llama.cpp 直接控制、分发成本；未测 Ollama 速度，明确不作速度比较）、Qwen3.5 0.8B/2B 的 Titles/Tabs/Downloads 能力与上限、速度内存热状态、被淘汰模型、五条建议，以及本测试包的使用方法。等作者回复的五件事不变。
