#!/usr/bin/env python3
"""T1 数据管线（scripts/gen-training-data.py，用 anaconda python 跑：需要 pyarrow）

从公开分类语料合成司南六任务的 SFT 样本（chat 格式 JSONL）。
数据策略见 docs/TRAINING-PLAN.md：公开语料为主体（自带类目标签），
真实 tidy-prefs 只做评测集；6:3:1 相关配比红线（OBS-1）。

语料源（2026-11-19 实测可达）：
  - hf-mirror seamew/THUCNewsTitle（thuc_news_title-train.arrow，标题+类目）
  - hf-mirror Helsinki-NLP/opus-100 en-zh（翻译对，parquet）
任务样本格式对齐 CraCore 真实 prompt（TidyTabs.prompt / TidyTabsTwoStage
instructions / TidyDownloads 双语 few-shot / TidyTranslate），输出严格符合
各任务 GBNF 语法，微调后才不漂移。

用法：
  python3 scripts/gen-training-data.py [--out datasets/sinan-sft] [--n 3000]
输出：
  <out>/train.jsonl  dev.jsonl  eval-singleton.jsonl（tidy-eval 用）
"""
import argparse, json, random, re, sys, pathlib, urllib.request

MIRROR = "https://hf-mirror.com/"
CACHE = pathlib.Path.home() / "Projects/cra/.corpus-cache"
random.seed(20261120)

CATEGORIES = ["财经", "彩票", "房产", "股票", "家居", "教育", "科技", "社会",
              "时尚", "时政", "体育", "星座", "游戏", "娱乐"]
CAT_EN = {"财经": "finance", "彩票": "lottery", "房产": "estate", "股票": "stock",
          "家居": "home", "教育": "education", "科技": "technology", "社会": "society",
          "时尚": "fashion", "时政": "politics", "体育": "sports", "星座": "constellation",
          "游戏": "game", "娱乐": "entertainment"}

def fetch(url, dest, tries=4):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    import time
    for attempt in range(1, tries + 1):
        print(f"下载 {url.split('/')[-1]}（第 {attempt} 次）…", flush=True)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "sinan-t1/1.0"})
            with urllib.request.urlopen(req, timeout=180) as r, open(dest, "wb") as f:
                while chunk := r.read(1 << 20):
                    f.write(chunk)
            print(f"  -> {dest.stat().st_size/1e6:.1f} MB", flush=True)
            return dest
        except urllib.error.HTTPError as e:
            if e.code in (429, 503) and attempt < tries:
                wait = 20 * attempt
                print(f"  {e.code} 限流，{wait}s 后重试", flush=True)
                time.sleep(wait)
            else:
                raise

def load_thucnews_titles():
    """arrow → [(title, category)]。HuggingFace arrow 是 IPC 流，pyarrow 直接读表。"""
    import pyarrow as pa
    import pyarrow.ipc as ipc
    f = fetch(MIRROR + "datasets/seamew/THUCNewsTitle/resolve/main/thuc_news_title-train.arrow",
              CACHE / "thuc_news_title-train.arrow")
    with pa.memory_map(str(f)) as src:
        table = ipc.open_stream(src).read_all()
    # seamew/THUCNewsTitle 的真实列名是 text/label；label 是 10 类 ClassLabel 索引
    LABELS = ["education", "entertainment", "fashion", "finance", "game",
              "politic", "society", "sport", "stock", "technology"]
    titles = table.column("text").to_pylist()
    labels = table.column("label").to_pylist()
    out = []
    for t, li in zip(titles, labels):
        t = re.sub(r"\s+", " ", str(t)).strip()
        c = LABELS[li] if isinstance(li, int) and 0 <= li < len(LABELS) else str(li)
        if 4 <= len(t) <= 40 and c in CAT_EN.values():
            out.append((t, c))
    print(f"THUCNews 标题 {len(out)} 条（{len(set(c for _, c in out))} 类）", flush=True)
    return out

def load_translation_pairs(n):
    """opus-100 en-zh 的 parquet 分片 → [(en, zh)]。取第一个分片够用。"""
    import pyarrow.parquet as pq
    tree = json.load(urllib.request.urlopen(MIRROR + "api/datasets/Helsinki-NLP/opus-100/tree/main/en-zh", timeout=30))
    zh = [f for f in tree if f["path"].endswith(".parquet") and ("validation" in f["path"] or "test" in f["path"])]
    if not zh: zh = [f for f in tree if f["path"].endswith(".parquet")]
    f = fetch(MIRROR + "datasets/Helsinki-NLP/opus-100/resolve/main/" + zh[0]["path"],
              CACHE / "opus100-en-zh.parquet")
    table = pq.read_table(f)
    rows = table.column("translation").to_pylist()
    pairs = []
    for r in rows:
        en, zhv = r.get("en", "").strip(), r.get("zh", "").strip()
        # opus 校验集有拼连词的脏对（如 travelbybullettrainto）：最长词 >18 字符即拒
        longest = max((len(w) for w in en.split()), default=0)
        if 8 <= len(en) <= 120 and 4 <= len(zhv) <= 80 and longest <= 18:
            pairs.append((en, zhv))
    print(f"翻译对 {len(pairs)} 条", flush=True)
    return pairs[:n]

# ── 扰动模板：把干净标题弄"脏"，模拟真实标签页/下载名 ──────────────
JUNK_PREFIX = ["【独家】", "【新品首发】", "【限时】", "重磅：", "快讯：", "刚刚，", "震惊！"]
JUNK_SUFFIX = [" - 澎湃新闻", " _网易订阅", " – 搜狐网", "|界面新闻", " - 知乎", "（组图）", "……"]
SITES = ["淘宝网", "京东", "拼多多", "哔哩哔哩", "新浪财经", "知乎", "网易新闻"]

def dirty_title(t):
    return random.choice(JUNK_PREFIX) + t + random.choice(JUNK_SUFFIX)

def dirty_filename(t):
    base = t + " " + random.choice(["2026新款", "官方正品", "限时优惠", "完整版", "高清版", "v2"])
    return f"{base} - {random.choice(SITES)}.{'html' if random.random() < .5 else 'pdf'}"

def tidy_prompt(tabs, existing, preferences):
    lines = ["Here are my tabs, as 'id: title (site)':"]
    for (i, t) in enumerate(tabs):
        lines.append(f"{i}: {t} ({random.choice(SITES).lower()}.com)")
    if existing:
        lines.append("")
        lines.append("I already have these groups; reuse a name exactly to add tabs to it: "
                     + ", ".join(f'"{g}"' for g in existing) + ".")
    if preferences:
        lines.append("")
        lines.append("Where I moved similar pages before (follow the same pattern when a tab clearly matches):")
        for title, group in preferences[:8]:
            lines.append(f'"{title}" → "{group}"')
    return "\n".join(lines)

GROUPED_INSTRUCTIONS = """You sort a person's open browser tabs into topic groups. Assign EVERY tab id to exactly \\
one group: related tabs share a group, NEVER one group per tab, never leave a tab out, \\
and every group needs at least two tabs. Reuse the names of groups the person already \\
has when they fit, exactly as written; name new groups yourself. Write every group name \\
in Simplified Chinese (for example "云计算", "AI 编程", "购物") — the person browses in \\
Chinese. Two to four groups, two to four words each, no website names."""

def sample_tasks(titles):
    """按 6:3:1 相关度采样生成 tabs 任务样本（grouped 单遍格式）。
    - related 60%：3 个类目 × 每类 3 条 → 3 组
    - partial 30%：3 个类目不等量（2/2/3 等）→ 3 组，组内不均
    - unrelated 10%：6 个互不相关类目各 1 条 → 期望 {"groups":[]}（合理退出，OBS-1）
    返回 (task, messages, meta)。"""
    by_cat = {}
    for t, c in titles:
        by_cat.setdefault(c, []).append(t)
    cats = [c for c in by_cat if len(by_cat[c]) >= 5]
    mode = random.random()
    # 组名同义池：跨样本多样，样本内一致——防止模型死记固定组名词表
    SYN = {"finance": ["财经", "金融", "理财"], "estate": ["房产", "楼市"],
           "education": ["教育", "学习"], "technology": ["科技", "数码", "互联网"],
           "society": ["社会", "民生"], "fashion": ["时尚", "穿搭"],
           "politics": ["时政", "资讯"], "sports": ["体育", "赛事"],
           "game": ["游戏", "电竞"], "entertainment": ["娱乐", "影视"],
           "home": ["家居", "家装"], "stock": ["股票", "证券"],
           "lottery": ["彩票"], "constellation": ["星座"]}
    name_zh = lambda cat: {"finance": "财经", "estate": "房产", "education": "教育",
                           "technology": "科技", "society": "社会", "fashion": "时尚",
                           "politics": "时政", "sports": "体育", "game": "游戏",
                           "entertainment": "娱乐", "home": "家居", "stock": "股票",
                           "lottery": "彩票", "constellation": "星座"}[cat]

    def make(spec):
        """spec: [(cat, count)] → (tabs, expected)。每类目分配组名（同义池随机，
        样本内一致），组内所有标题归该组；返回按生成序排列的 tabs 与组。"""
        name_of = {cat: random.choice(SYN.get(cat, [cat])) for cat, _ in spec}
        tabs = []
        for cat, count in spec:
            tabs += random.sample(by_cat[cat], count)
        random.shuffle(tabs)
        cat_of = {}
        for cat, count in spec:
            for t in by_cat[cat]:
                cat_of.setdefault(t, cat)
        emap = {}
        for i, t in enumerate(tabs):
            emap.setdefault(name_of[cat_of[t]], []).append(i)
        return tabs, [{"name": g, "ids": ids} for g, ids in emap.items() if len(ids) >= 2]
    if mode < 0.6:
        n_groups = random.choice([2, 3, 3, 4])  # 组数多样化（真实使用 2-4 组都常见）
        chosen = random.sample(cats, n_groups)
        spec = [(c, random.choice([2, 3, 3, 4])) for c in chosen]
    elif mode < 0.9:
        chosen = random.sample(cats, 3)
        spec = [(chosen[0], 2), (chosen[1], 2),
                (chosen[2], random.choice([2, 3, 3, 4]))]
    else:
        chosen = random.sample(cats, 6)
        spec = [(c, 1) for c in chosen]

    shuffled_tabs, expected = make(spec)
    existing = []
    if spec and random.random() < 0.5 and mode < 0.9:
        # 复用已有组：把第一个类目的组名当作已有组写进 prompt，expected 沿用
        reuse = expected[0]["name"]
        existing = [reuse]
        existing_note = f"（已有组「{reuse}」）"
    prompt = tidy_prompt(shuffled_tabs, existing, [])
    answer = json.dumps({"groups": expected}, ensure_ascii=False, separators=(",", ":"))
    meta = {"mode": "related" if mode < 0.6 else "partial" if mode < 0.9 else "unrelated",
            "n_tabs": len(shuffled_tabs)}
    return ("tabs-grouped", [{"role": "system", "content": GROUPED_INSTRUCTIONS},
                             {"role": "user", "content": prompt},
                             {"role": "assistant", "content": answer}], meta)

def title_tasks(titles):
    """Tidy Tab Titles：脏标题 → 干净短标题；以及 Downloads：脏文件名 → 干净名。"""
    t = random.choice(titles)[0]
    if random.random() < 0.5:
        dirty = dirty_title(t)
        return ("tab-title", [{"role": "system", "content": "You shorten a tab's title. Keep the language (usually Chinese), drop site names, dates, 【】 decorations and clickbait. Reply with the short title only."},
                              {"role": "user", "content": dirty},
                              {"role": "assistant", "content": t}], {"mode": "tab-title"})
    dirty = dirty_filename(t)
    clean = re.sub(r"\.(html|pdf)$", "", dirty_filename(t)).split(" - ")[0] if False else t + (".html" if ".html" in dirty else ".pdf")
    return ("download-name", [{"role": "system", "content": "You rename a messy download file after the page it came from. Keep the useful product/article words, drop site names, promo spam (新款/官方正品/限时优惠), and the site suffix. Reply with the clean filename only."},
                              {"role": "user", "content": dirty},
                              {"role": "assistant", "content": clean}], {"mode": "download-name"})

def build(titles, n_tabs, n_title, n_dl, n_tr, pairs):
    out = []
    for _ in range(n_tabs):
        try: out.append(sample_tasks(titles))
        except (ValueError, IndexError): pass
    for _ in range(n_title):
        out.append(title_tasks(titles))
    for _ in range(n_dl):
        out.append(title_tasks(titles))
    for _ in range(n_tr):
        en, zh = random.choice(pairs)
        direction = random.random() < 0.5
        src, dst = (en, zh) if direction else (zh, en)
        instr = "Translate between English and Chinese. Reply with the translation only."
        out.append(("translate", [{"role": "system", "content": instr},
                                  {"role": "user", "content": src},
                                  {"role": "assistant", "content": dst}], {"mode": "translate"}))
    random.shuffle(out)
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="datasets/sinan-sft")
    ap.add_argument("--n-tabs", type=int, default=1800)
    ap.add_argument("--n-title", type=int, default=600)
    ap.add_argument("--n-dl", type=int, default=600)
    ap.add_argument("--n-tr", type=int, default=600)
    args = ap.parse_args()

    titles = load_thucnews_titles()
    pairs = load_translation_pairs(args.n_tr)
    samples = build(titles, args.n_tabs, args.n_title, args.n_dl, args.n_tr, pairs)

    outdir = pathlib.Path.home() / "Projects/cra" / args.out
    outdir.mkdir(parents=True, exist_ok=True)
    random.shuffle(samples)
    n_dev = max(1, len(samples) // 20)
    def dump(name, rows):
        with open(outdir / name, "w") as f:
            for s in rows:
                f.write(json.dumps({"task": s[0], "messages": s[1]}, ensure_ascii=False) + "\n")
    dump("train.jsonl", samples[n_dev:])
    dump("dev.jsonl", samples[:n_dev])

    # 单例陷阱 eval：全部互不相关 → 期望 {"groups":[]}
    eval_rows = []
    cats = {}
    for t, c in titles: cats.setdefault(c, []).append(t)
    cat_list = [c for c in cats if len(cats[c]) >= 3]
    for _ in range(50):
        chosen = random.sample(cat_list, 6)
        tabs = [random.choice(cats[c]) for c in chosen]
        order = list(range(len(tabs))); random.shuffle(order)
        shuffled = [tabs[i] for i in order]
        prompt = tidy_prompt(shuffled, [], [])
        eval_rows.append(json.dumps({"task": "tabs-grouped-eval",
                                     "messages": [{"role": "system", "content": GROUPED_INSTRUCTIONS},
                                                  {"role": "user", "content": prompt},
                                                  {"role": "assistant", "content": '{"groups":[]}'}]},
                                    ensure_ascii=False))
    (outdir / "eval-singleton.jsonl").write_text("\n".join(eval_rows) + "\n")

    modes = {}
    for s in samples: modes[s[0]] = modes.get(s[0], 0) + 1
    print(f"\n样本 {len(samples)}：train {len(samples)-n_dev} / dev {n_dev} / eval-singleton 50")
    for k, v in sorted(modes.items()): print(f"  {k}: {v}")
    print(f"输出目录：{outdir}")
    # 人工抽检文件：每任务前 3 条
    with open(outdir / "sample-inspect.txt", "w") as f:
        seen = {}
        for s in samples:
            if seen.get(s[0], 0) < 3:
                seen[s[0]] = seen.get(s[0], 0) + 1
                f.write(f"─── {s[0]}\n" + json.dumps(s[1], ensure_ascii=False, indent=1) + "\n\n")

if __name__ == "__main__":
    main()
