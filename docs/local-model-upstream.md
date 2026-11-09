# Local Max: on-device Tidy for Intel Macs

This branch (`cra-local`) adds a local, offline backend for the Max features. It exists because
Apple Intelligence needs an Apple silicon Mac (and macOS 26), so on every Intel Mac — and in places
where Apple Intelligence is unavailable — Tidy has no model at all. The local backend is a GGUF
model run by a helper process on the CPU; nothing leaves the Mac.

It is an addition, not a replacement: Apple Intelligence stays first, and the local model is an
additional option the user turns on in Settings ▸ Max.

The detailed plan, measurements and per-phase acceptance records are in
`docs/local-model-plan.md` (Chinese). This page is the version for review, plus what we would like
your decision on.

## Where it stands

Ready to try on an Intel Mac today:

- Tidy Titles, offline, 0.8B or 2B.
- Tidy Tabs via a two-stage prompt on the 2B (2–3 minutes for 60 tabs).
- Model download with resume and SHA256 verification from two mirrors; delete; enable/switch in
  Settings ▸ Max.
- Memory-pressure cancel, a pre-load memory budget, heat-aware pause and thread reduction.
- No extra runtime to install: llama.cpp is compiled into `CraInferenceHelper` inside the bundle
  (its MIT license ships in `Resources/licenses`); only the pinned GGUF model is downloaded.
- Status: working on our Intel test machine; not yet packaged for distribution (no Developer
  ID, no notarization, and our test build used the stock Spotify CEF, so no H.264/AAC).

Not ready, and deliberately not shipped: local Tidy Downloads, XPC/sandbox packaging, Developer ID
and notarization, the patched CEF distribution for shipping..

## What the user gets

- Tidy Tab Titles on any Intel Mac with 8 GB and up (0.8B model, about 0.85 GB resident).
- Tidy Tabs on Macs with 12 GB and up (2B model, about 2 GB resident, 2–3 minutes for 60 tabs).
- Offline after the one-time model download; no key, no account, no telemetry.
- 8 GB Macs default to the 0.8B and titles only; the user can override, with the cost shown.

Tidy Downloads is **not** enabled on the local backend: the 2B got 1 of 2 test samples right, and
Apple Intelligence does that job better. Local Tidy Downloads stays off until a model clears a
larger sample.

## Why not Ollama

Ollama is the obvious shortcut, and we deliberately did not take it. This is an architectural
decision, not a speed comparison; we did not benchmark Ollama, and it also runs llama.cpp-derived
code, so the numbers would likely be close.

- **It is a daemon with a listening socket.** Ollama serves an HTTP API on `127.0.0.1:11434`. The
  local path has a hard rule: no listening port, no server, nothing that another local process can
  call. The helper has no network code, and the acceptance runs show zero sockets while it runs.
  A browser already has a large attack surface; a local model server is a new one.
- **We cannot own the model lifecycle.** The app must be able to unload on 60 s idle, cancel a
  generation by ending the worker, refuse to start when free memory is below the model plus 800 MB,
  and drop to two threads when the Mac is hot. A shared daemon that other apps may be using cannot
  give those guarantees; killing or unloading it is not ours to do.
- **We cannot pin the bytes.** `ModelCatalog` pins file name, byte count and SHA256, requires
  explicit user consent, and serves the same file from ModelScope and Hugging Face. Ollama manages
  its own store and registry and updates on its own schedule; the app could not promise which
  bytes were loaded.
- **The controls we depend on are direct llama.cpp calls.** Per-request context (1024 titles /
  4096 tabs), GBNF grammar + greedy sampling, thread count, and Qwen3.5's hybrid-SSM state snapshot
  reuse (`llama_state_seq_get_data/set_data`). Putting a daemon API in between means depending on
  its versioning for every one of these.
- **Distribution.** A browser cannot require the user to install and keep a second app running.
  The helper lives inside the signed bundle, starts on demand and exits with the feature; sandbox
  and notarization apply to one bundle, not to a separate service.
- **Cost.** The helper is a small C++ program plus a tiny binary protocol. Embedding pinned
  llama.cpp is less work than adopting and tracking a daemon contract.

## What the two Qwen3.5 models can actually do

Setup: Qwen3.5 0.8B and 2B, Q4_K_M GGUF (unsloth builds; identical bytes and SHA256 on ModelScope
and Hugging Face), llama.cpp b8210 built for this CPU (AVX2/FMA, Accelerate, Metal off), 4 threads,
greedy sampling, thinking off. Test machine: 2018 15″ MacBook Pro, i7-8750H, 16 GB, macOS 15.8.2.

### Tidy Titles — reliable at both sizes

- 0.8B: 3/3 test titles correct, Chinese kept (`京都清水寺游玩攻略`, `哔哩哔哩`, `收件箱`).
- 2B: 3/3 only after adding one instruction, "output only the new name". Without it the model
  turns a Chinese title into an English sentence.
- In the real app a pinned tab renamed 35 → 3 characters; subsequent renames take 0.37–0.97 s, the
  first 3.0–3.6 s (load + prefill).
- This is the feature the local path is good at: short output, fixed instruction prefix, and the
  SSM snapshot makes the prefix cost disappear.

### Tidy Tabs — usable on the 2B, not Arc-quality

What failed: one-shot grouping, JSON-schema prompts, thinking on, cutting the input to 30 tabs,
and per-tab labelling all failed on both models. The 2B would ignore the requested shape, repeat
topics or answer in prose.

What works: two stages on the 2B only.

1. Ask for 3–6 topic names under a compact GBNF grammar.
2. Ask, closed-book, for each tab id's topic number under a second grammar.
3. Code builds the groups and `TidyTabs.plan()` validates ids, duplicates and bounds before
   anything reaches the sidebar.

Measured on 60 real tabs, offline:

- Coverage 60/60 in every accepted run; 5–6 groups; 2–3 minutes (131.8 s, 126.1 s, 172.3 s, 187.2 s
  across runs); helper peak about 2.0 GB; zero sockets; idle exit after 60 s.
- Cluster purity 4–8 of 8, depending on the run and on tab order. The first acceptance run hit
  6–8/8 for all six planted clusters; later runs sat at 4–7/8.
- The 0.8B cannot do this. It proposes one "Japan…" family of topics and cannot finish the
  assignment, so Tabs is gated on the 2B being installed.

The ceiling, stated plainly:

- The 2B is order-sensitive. The same 60 tabs in a different arrival order can produce different
  groups, and a prompt that differs by a few dozen bytes can change the answer.
- It sometimes puts almost everything into one group. We reject the fully degenerate case
  (all tabs in one group) in code; a 48-of-60 merge still passes validation and produces coarse
  groups. This is the main quality gap against Arc's server-side clustering.
- 6.15 tokens/s is below the 8 t/s bar we originally set. The user accepted it because grouping
  runs in the background with progress and cancel, not while waiting for a page.
- A larger or better model is a drop-in later: `ModelCatalog` is the only place that changes.

### Tidy Downloads — not acceptable locally

- 0.8B: 0/2 samples (returns the input).
- 2B: 1/2 (one correct name; a date in another file name parsed wrong).
- Left off in the local backend. Where Apple Intelligence is available, Downloads continues to use it.

### Speed, memory, heat

- 0.8B: prefill 72–102 t/s, generation 9.8 t/s, 8.3 t/s during a 60-tab run; 811 MB at 1k context,
  about 1.1 GB at 8k.
- 2B: prefill ~50 t/s, generation 6.15 t/s, 5.5 t/s during a 60-tab run; 1.85 GB at 1k, about
  2.2 GB at 8k.
- Two threads still work (0.8B 8.42 t/s, 2B 4.22 t/s), which is what a hot or low-core Mac gets.
- Sustained full load throttles this chassis to about 46% of nominal speed, so the app pauses
  Tabs at `thermalState` serious and drops the helper to two threads otherwise.
- The Radeon Pro 555X is not usable: Metal concurrency crashes in `llama_decode`, and with
  concurrency disabled it is 7–13× slower than the CPU (2B 0.90 t/s). Intel builds are CPU-only.

### Models we rejected under the same tests

- Qwen2.5-1.5B (Apache 2.0): 4.9 t/s, 1.34 GB; Titles 2/3 (lost Chinese), Downloads 1/2, Tabs failed
  in stage 1.
- Gemma 3 1B (Gemma terms, not OSI): 8.8 t/s, 1.15 GB; Titles 0/3 (English paraphrase), Tabs
  produced garbage, Downloads 0/2.
- 3B/4B models are below 4 t/s on this CPU, so they were not candidates.

## Our recommendation

1. **Ship the local backend as an opt-in beta, not a default.** Titles are ready. Tabs are useful
   but visibly below Arc's quality; the UI should say 2–3 minutes for 60 tabs and keep progress and
   Cancel in front of the user.
2. **Keep the memory split.** 8 GB Macs: 0.8B, Titles only. 12 GB and up: 2B, Titles + Tabs. A user
   can override, with the cost shown; do not hide the feature on small Macs, explain it.
3. **Keep Tidy Downloads off the local backend.** One of two samples is not a feature.
4. **Market it as offline and private, not fast.** On a 2018 machine grouping takes minutes; the
   promise is that it works with no account, no key and no network.
5. **Revisit when a CPU-feasible model beats the 2B.** The pipeline is model-agnostic; a better
   model only changes the catalog entry and its prompt budget.

## Security posture

The constraints the local path is built around:

- No listening socket. The helper is a child process talking over stdin/stdout; it has no network
  code and the acceptance runs show zero sockets while it runs.
- No arbitrary GGUF import. The model list is pinned in `ModelCatalog` (file name, byte count,
  SHA256, capabilities). A file is used only after its size and SHA256 match and its header is a
  GGUF.
- No silent downloads. Every download is confirmed with its size and source; both sources
  (ModelScope and Hugging Face) serve the same pinned file, and either can be chosen.
- Weights never ship in the installer. The app downloads them on request into its data directory.
- Untrusted input is treated as untrusted: page titles only reach the model inside a prompt, and
  its answer must pass CraCore validation (`TidyTabs.plan`, id/duplicate/bounds checks) before it
  touches the sidebar.
- llama.cpp is pinned, built from source with Accelerate on x86_64 with the same macOS 14 floor as
  the app (`scripts/build-llama.sh`), and linked statically into the helper; Metal is off on Intel.

Not done yet: the helper is still a plain child process, not XPC, and is signed ad hoc in this
build. Sandboxing, hardened-runtime signing and notarization are the next step before any
distribution; see “Open questions”.

## How it is put together

- `Sources/CraInferenceHelper/main.cpp` — the helper. Loads the GGUF with llama.cpp, answers one
  request at a time over a small binary protocol (`CRQL`/`CRSL`), and exits after 60 s idle so the
  memory goes back to the system. Op 3 adds GBNF-constrained sampling for JSON answers.
- `Sources/Cra/Services/MaxLocal.swift` — the Swift side: which model, which path, the two-stage
  Tidy Tabs call, and `LocalInference`, an actor that owns the helper process and serialises
  requests. Cancellation goes through a lock-protected slot, because the actor is blocked on the
  pipe read; the memory-pressure handler uses the same path.
- `Sources/Cra/Services/LocalRuntime.swift` — thermal and memory pressure. A warning ends the
  helper and the run; serious heat pauses Tidy Tabs and drops the helper to two threads. A run
  only starts if free + inactive memory covers the model plus 800 MB.
- `Packages/CraCore` — code that needs no window and is unit-tested: `ModelCatalog`, `ModelFetch`
  (8-range resume, 206-only, SHA256 + GGUF check), `TidyTabsTwoStage` (topics → assignments →
  proposals), `LocalInferenceLimits` (memory budget, heat, thread count).
- `Sources/Cra/Services/ModelDownloader.swift`, `Sources/Cra/UI/Settings/MaxPane.swift` — download,
  resume, verify, delete; source picker; local-model switch and capability notes.
- `Sources/Cra/Services/TidyTabsService.swift`, `Sources/Cra/UI/Sidebar/…` — the divider shows the
  local stages (“Step 1 of 2 · Naming groups…”, then sorting), the broom becomes Cancel, and a
  paused Tidy says why on hover.

Qwen3.5 is a hybrid SSM model, so its state cannot be rewound to a prefix with
`llama_memory_seq_rm`. Prefix reuse keeps a state snapshot (`llama_state_seq_get_data/set_data`)
and restores it only when the token prefix matches; otherwise it recomputes. That is what makes
titles take a second instead of five.

## Trying it

The implementation lives on a branch we have not published yet; say the word and we will push
it, or split it into reviewable pieces (Open question 1). Testing notes from our own runs, for
whoever reproduces it:

- Same profile and data folder as the installed Cra; run a separate copy to keep both.
- Settings ▸ Max: turn on "Local model", pick a source and download the model (0.8B ~0.53 GB,
  2B ~1.28 GB). The download is confirmed, resumable and SHA256-checked.
- Titles: pin or open tabs with the Titles toggle on. Tabs: press the broom in a space's divider.
  The divider shows the two stages and Cancel.
- Worth checking: no network while the helper runs, `CraInferenceHelper` gone after 60 s idle,
  Cancel ends the run and the helper, low-memory or hot states show a pause reason on hover.
- Known limits: 2B grouping varies with tab order; local Downloads is off; first use loads
  the model (a few seconds).

## Open questions for the author

1. **Upstream or stay a fork?** The local path is additive and touches Max settings, Tidy services
   and the sidebar divider; if you want it upstream, we can split it into reviewable pieces.
2. **Helper packaging.** Child process + stdio now; XPC with a sandbox profile is the safer
   long-term shape. Do you have a preference (XPC service vs. embedded helper) before we invest?
3. **Model hosting and licensing.** The pinned models are Qwen3.5 0.8B/2B, Apache 2.0, mirrored on
   ModelScope and Hugging Face (`unsloth` GGUF builds, same SHA256 on both). Is a third-party
   download at first use acceptable, or should the project host the files?
4. **Release pipeline.** The Intel build currently uses the stock Spotify CEF for local testing and
   is signed ad hoc; distribution needs the patched CEF distribution, Developer ID signing for the helper, and
   notarization. We will follow whatever your release scripts expect.
5. **Minimum macOS.** CraCore targets macOS 14, and the local path's llama.cpp libraries are built
   with `CMAKE_OSX_DEPLOYMENT_TARGET=14.0` (`scripts/build-llama.sh`, which also checks the
   result), so the helper carries the same floor as the app and the bundle links without version
   warnings. Confirm the floor you want to commit to.

## What the reviewer may want to look at

- `Packages/CraCore/Sources/CraCore/TidyTabsTwoStage.swift` and `TidyTabs.swift` — the validation
  the model's answer must survive.
- `Sources/CraInferenceHelper/main.cpp` — the protocol and the sampling chain (grammar + greedy).
- `Sources/Cra/Services/MaxLocal.swift` — process lifetime, cancellation, state reuse.
- `Sources/Cra/Services/ModelFetch.swift` — resume and verification rules.
- `docs/local-model-plan.md` §7 (security) and §10 (model selection) for the reasoning and the
  rejected candidates.
