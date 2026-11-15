#!/usr/bin/env python3
"""P3-R2 recall evaluation: embeds queries via CraInferenceHelper, searches
semantic-index.json (the app's live index), checks where the expected URL ranks.
Also measures the keyword path (title/desc/snippet substring) for comparison.
Baseline harness for every retrieval change (plan P3-R2 评测集)."""
import json, struct, subprocess, math, os, sys, re

HELPER = os.path.expanduser("~/Projects/cra/.build/release/CraInferenceHelper")
MODEL = os.path.expanduser("~/Library/Application Support/Cra/Models/Qwen3-Embedding-0.6B-Q8_0.gguf")
C = os.path.expanduser("~/Library/Application Support/Cra")
index = json.load(open(os.path.join(C, "semantic-index.json")))
history = {e["url"]: e for e in json.load(open(os.path.join(C, "history.json")))}

# (query, expected-url-substring) — real failures and successes from user testing + derived
CASES = [
    ("董事长", "boc.cn"),                    # job-title word, body-only
    ("中国银行 高级管理层", "boc.cn"),
    ("yu7", "yu7"),                          # model code, image-heavy page
    ("YU7", "yu7"),
    ("千问办公 优惠", "qianwen"),             # promo page, desc-only
    ("千问双11", "qianwen"),
    ("阿里云 云计算", "aliyun"),
    ("零跑汽车 参数", "leapmotor"),
    ("开源热榜 github", "bilibili"),          # video page
    ("SoulLink Live2D 桌宠", "bilibili"),
    ("Whisper 语音转写", "bilibili"),
    ("地图 时序", "bilibili"),                # 江山时序
]

def wstr(s):
    b = s.encode(); return struct.pack("<I", len(b)) + b

def start_helper():
    return subprocess.Popen([HELPER, MODEL, "60", "2048", "4", "3"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

p = start_helper()
def read_exact(n):
    d = b""
    while len(d) < n:
        c = p.stdout.read(n - len(d))
        if not c: raise RuntimeError("helper died")
        d += c
    return d

def embed(text):
    p.stdin.write(b"CRQL" + bytes([4]) + b"\x00\x00\x00" + struct.pack("<I", 0) + wstr(text))
    p.stdin.flush()
    hdr = read_exact(12)
    status, ln = hdr[4], struct.unpack("<I", hdr[8:12])[0]
    body = read_exact(ln)
    time.sleep(0.05)
    if status != 0: return None
    return struct.unpack("<%df" % (ln//4), body)

import time
def cos(a, b):
    dot = sum(x*y for x, y in zip(a, b))
    na = math.sqrt(sum(x*x for x in a)); nb = math.sqrt(sum(x*x for x in b))
    return dot/(na*nb) if na and nb else 0

docs = index["documents"]
hits1 = hits4 = kw_hits1 = kw_hits4 = 0
valid = 0
print(f"{'query':<28} {'sem@1':>6} {'sem@4':>6} {'kw@1':>6} {'kw@4':>6}  top-semantic")
for q, expect in CASES:
    v = embed(q)
    if v is None: print(f"{q:<28}  embed failed"); continue
    valid += 1
    scored = sorted(((cos(v, d["vector"]), d) for d in docs), key=lambda x: -x[0])
    sem_rank = None
    for i, (s, d) in enumerate(scored):
        if expect in d["url"]:
            sem_rank = i + 1; break
    h1 = 1 if sem_rank == 1 else 0
    h4 = 1 if sem_rank and sem_rank <= 4 else 0
    hits1 += h1; hits4 += h4
    # keyword path: substring over title+desc+snippet, ranked by simple score
    lq = q.lower()
    kw = []
    for d in docs:
        h = history.get(d["url"], {})
        hay = " ".join(filter(None, [h.get("title",""), h.get("description",""), h.get("contentSnippet","")])).lower()
        if lq in hay: kw.append((len(hay), d["url"]))
    kw.sort()
    k_rank = None
    for i, (_, url) in enumerate(kw):
        if expect in url: k_rank = i + 1; break
    k1 = 1 if k_rank == 1 else 0
    k4 = 1 if k_rank and k_rank <= 4 else 0
    kw_hits1 += k1; kw_hits4 += k4
    top = scored[0][1]
    top_t = history.get(top["url"], {}).get("title", top["url"])[:32]
    print(f"{q:<28} {str(sem_rank or '-'):>6} {str(sem_rank and sem_rank<=4 or '-'):>6} {str(k_rank or '-'):>6} {str(k_rank and k_rank<=4 or '-'):>6}  {top_t}")

print(f"\n=== semantic: hit@1 {hits1}/{valid}  hit@4 {hits4}/{valid}   keyword: hit@1 {kw_hits1}/{valid}  hit@4 {kw_hits4}/{valid}")
p.terminate()
