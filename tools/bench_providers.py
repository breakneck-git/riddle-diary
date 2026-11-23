#!/usr/bin/env python3
"""Бенчмарк бесплатных LLM-провайдеров для «дневника Реддла».

Картинка с рукописным русским текстом -> (1) прочитать, (2) ответить в роли.
Режимы:
  single  — один вызов vision-модели: строка 1 = прочитанное, строка 2 = ответ.
  ocr     — vision только транскрибирует (для цепочки).
  reply   — текстовая модель отвечает на готовую строку (для цепочки).
  chain   — ocr -> reply, суммарная задержка.
Каждый запрос — новое TCP+TLS соединение (как на Kindle). Ключи только из env:
  set -a; source ~/.envs >/dev/null 2>&1; set +a
Пример:
  python bench_providers.py smoke
  python bench_providers.py single groq-qwen cerebras-qwen --runs 5
  python bench_providers.py chain --ocr groq-qwen --reply cerebras-oss --runs 5
Результаты (jsonl) -> tools/bench_out/ (тексты ответов, без ключей).
"""
import argparse
import base64
import io
import json
import os
import re
import statistics
import sys
import time
from pathlib import Path

import httpx

HERE = Path(__file__).resolve().parent
SAMPLES = HERE / "samples"
OUT = HERE / "bench_out"

PERSONA = ("Ты — волшебный дневник. Отвечай по-русски, 1–2 коротких предложения, "
           "загадочно и тепло, как живой дневник, который разговаривает с хозяином.")
P_SINGLE = ("На картинке — рукописная запись по-русски, которую хозяин сделал в дневнике. "
            "Выведи ровно две строки без пояснений и разметки:\n"
            "1) точная расшифровка написанного;\n"
            "2) твой ответ хозяину.")
P_OCR = ("Расшифруй рукописный русский текст на картинке. Выведи только сам текст "
         "одной строкой, без кавычек и комментариев.")

CF_ACC = os.environ.get("CF_WORKERS_AI_ACCOUNT_ID", "")

# name: base, key env, model, vision?, extra body
C = {
    # --- vision ---
    "groq-qwen": ("https://api.groq.com/openai/v1", "GROQ_API_KEY", "qwen/qwen3.8-27b", 1,
                  {"reasoning_effort": "none"}),
    "cerebras-qwen": ("https://api.cerebras.ai/v1", "CEREBRAS_API_KEY", "qwen-3.8-27b", 1,
                      {"reasoning_effort": "none"}),
    "glm-4.6v-flash": ("https://open.bigmodel.cn/api/paas/v4", "ZHIPU_API_KEY", "glm-4.6v-flash", 1,
                       {"thinking": {"type": "disabled"}}),
    "glm-4v-flash": ("https://open.bigmodel.cn/api/paas/v4", "ZHIPU_API_KEY", "glm-4v-flash", 1, {}),
    "glm-4.1v-flash": ("https://open.bigmodel.cn/api/paas/v4", "ZHIPU_API_KEY",
                       "glm-4.1v-thinking-flash", 1, {}),
    "zai-4.6v-flash": ("https://api.z.ai/api/paas/v4", "ZHIPU_API_KEY", "glm-4.6v-flash", 1,
                       {"thinking": {"type": "disabled"}}),
    "or-gemma4": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "google/gemma-4-31b-it:free", 1, {}),
    "or-gemma4-26b": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY",
                      "google/gemma-4-26b-a4b-it:free", 1, {}),
    "or-nemotron": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY",
                    "nvidia/nemotron-3.5-super-vl:free", 1, {}),
    "or-gemini-lite": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "google/gemini-3.5-flash-lite", 1,
                       {"reasoning": {"effort": "low"}}),
    "or-gemini-3.8": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "google/gemini-3.8-flash", 1,
                      {"reasoning": {"effort": "low"}}),
    "or-gemini-3.7": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "google/gemini-3.7-flash", 1,
                      {"reasoning": {"effort": "low"}}),
    "or-gpt-luna": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "openai/gpt-5.6-luna", 1,
                    {"reasoning": {"effort": "low"}}),
    "or-haiku": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "anthropic/claude-haiku-5.5", 1, {}),
    "or-qwen-flash": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "qwen/qwen3.8-flash", 1,
                      {"reasoning": {"effort": "low"}}),
    "or-fallback": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "google/gemini-3.5-flash-lite", 1,
                    {"models": ["google/gemini-3.5-flash-lite", "anthropic/claude-haiku-5.5"]}),
    "or-inkling": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "thinkingmachines/inkling:free", 1, {}),
    "or-inkling-s": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "thinkingmachines/inkling-small:free", 1, {}),
    "or-nemotron-omni": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY",
                         "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", 1, {}),
    "mistral-small": ("https://api.mistral.ai/v1", "MISTRAL_API_KEY", "mistral-small-latest", 1, {}),
    "mistral-medium": ("https://api.mistral.ai/v1", "MISTRAL_API_KEY", "mistral-medium-latest", 1, {}),
    "ministral-14b": ("https://api.mistral.ai/v1", "MISTRAL_API_KEY", "ministral-14b-latest", 1, {}),
    "cohere-vision": ("https://api.cohere.ai/compatibility/v1", "COHERE_API_KEY",
                      "command-a-vision-07-2025", 1, {}),
    "cf-llama4": (f"https://api.cloudflare.com/client/v4/accounts/{CF_ACC}/ai/v1", "CF_WORKERS_AI_TOKEN",
                  "@cf/meta/llama-4-scout-17b-16e-instruct", 1, {}),
    "cf-mistral": (f"https://api.cloudflare.com/client/v4/accounts/{CF_ACC}/ai/v1", "CF_WORKERS_AI_TOKEN",
                   "@cf/mistralai/mistral-small-3.1-24b-instruct", 1, {}),
    "cf-qwen": (f"https://api.cloudflare.com/client/v4/accounts/{CF_ACC}/ai/v1", "CF_WORKERS_AI_TOKEN",
                "@cf/qwen/qwen3.8-27b", 1, {}),
    "gemini-lite": ("https://generativelanguage.googleapis.com/v1beta/openai", "GEMINI_API_KEY",
                    "gemini-flash-lite-latest", 1, {"reasoning_effort": "low"}),
    "gemini-3.5-lite": ("https://generativelanguage.googleapis.com/v1beta/openai", "GEMINI_API_KEY",
                        "gemini-3.5-flash-lite", 1, {"reasoning_effort": "low"}),
    "gemini-flash": ("https://generativelanguage.googleapis.com/v1beta/openai", "GEMINI_API_KEY",
                     "gemini-flash-latest", 1, {"reasoning_effort": "low"}),
    "hf-qwen-vl": ("https://router.huggingface.co/v1", "HF_TOKEN", "Qwen/Qwen2.5-VL-7B-Instruct", 1, {}),
    "github-4o-mini": ("https://models.github.ai/inference", "GITHUB_API_KEY", "openai/gpt-4o-mini", 1, {}),
    # --- text only (для цепочки) ---
    "cerebras-oss": ("https://api.cerebras.ai/v1", "CEREBRAS_API_KEY", "gpt-oss-120b", 0,
                     {"reasoning_effort": "low"}),
    "groq-oss": ("https://api.groq.com/openai/v1", "GROQ_API_KEY", "openai/gpt-oss-120b", 0,
                 {"reasoning_effort": "low"}),
    "groq-oss20": ("https://api.groq.com/openai/v1", "GROQ_API_KEY", "openai/gpt-oss-20b", 0,
                   {"reasoning_effort": "low"}),
    "groq-qwen-t": ("https://api.groq.com/openai/v1", "GROQ_API_KEY", "qwen/qwen3.8-27b", 0,
                    {"reasoning_effort": "none"}),
    "glm-4.5-flash": ("https://open.bigmodel.cn/api/paas/v4", "ZHIPU_API_KEY", "glm-4.5-flash", 0,
                      {"thinking": {"type": "disabled"}}),
    "glm-4.7-flash": ("https://open.bigmodel.cn/api/paas/v4", "ZHIPU_API_KEY", "glm-4.7-flash", 0,
                      {"thinking": {"type": "disabled"}}),
    "glm-4-flash": ("https://open.bigmodel.cn/api/paas/v4", "ZHIPU_API_KEY", "glm-4-flash-250414", 0, {}),
}


def img_data_url(path, scale=1.0, fmt="png"):
    raw = Path(path).read_bytes()
    if scale == 1.0 and fmt == "png":
        return "data:image/png;base64," + base64.b64encode(raw).decode(), len(raw)
    from PIL import Image  # только для вариантов размера/формата
    im = Image.open(path).convert("L")
    if scale != 1.0:
        im = im.resize((int(im.width * scale), int(im.height * scale)), Image.LANCZOS)
    buf = io.BytesIO()
    if fmt == "png":
        im.point(lambda v: 0 if v < 160 else 255, mode="1").save(buf, "PNG", optimize=True)
        mime = "png"
    elif fmt == "gray":  # 8-бит серый PNG, без порога — сглаживание после уменьшения сохраняется
        im.save(buf, "PNG", optimize=True)
        mime = "png"
    else:
        im.save(buf, "JPEG", quality=60)
        mime = "jpeg"
    b = buf.getvalue()
    return f"data:image/{mime};base64," + base64.b64encode(b).decode(), len(b)


def call(name, messages, stream=True, max_tokens=200, timeout=40):
    base, kenv, model, _, extra = C[name]
    key = os.environ.get(kenv)
    if not key:
        return {"err": f"no {kenv}"}
    body = {"model": model, "messages": messages, "max_tokens": max_tokens,
            "temperature": 0.7, "stream": stream, **extra}
    hdr = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    t0 = time.perf_counter()
    res = {"ttft": None, "t_nl": None, "total": None, "text": "", "status": None, "err": None}
    try:
        # свежий клиент = новое TCP+TLS соединение на каждый запрос
        with httpx.Client(timeout=timeout, http2=False) as cl:
            if not stream:
                r = cl.post(base + "/chat/completions", json=body, headers=hdr)
                res["status"] = r.status_code
                res["total"] = res["ttft"] = time.perf_counter() - t0
                if r.status_code != 200:
                    res["err"] = r.text[:300]
                    return res
                res["text"] = (r.json()["choices"][0]["message"].get("content") or "")
            else:
                with cl.stream("POST", base + "/chat/completions", json=body, headers=hdr) as r:
                    res["status"] = r.status_code
                    if r.status_code != 200:
                        res["err"] = r.read().decode(errors="replace")[:300]
                        res["total"] = time.perf_counter() - t0
                        return res
                    for line in r.iter_lines():
                        if not line.startswith("data:"):
                            continue
                        d = line[5:].strip()
                        if d == "[DONE]":
                            break
                        try:
                            j = json.loads(d)
                        except ValueError:
                            continue
                        ch = (j.get("choices") or [{}])[0]
                        piece = (ch.get("delta") or {}).get("content")
                        # Cloudflare иногда шлёт числовой токен как JSON-число: "content": 30
                        piece = "" if piece is None else str(piece)
                        if piece:
                            now = time.perf_counter() - t0
                            if res["ttft"] is None and piece.strip():
                                res["ttft"] = now
                            res["text"] += piece
                            if res["t_nl"] is None and "\n" in res["text"].strip():
                                res["t_nl"] = now
                res["total"] = time.perf_counter() - t0
    except Exception as e:  # noqa: BLE001
        res["err"] = f"{type(e).__name__}: {e}"[:300]
        res["total"] = time.perf_counter() - t0
    res["text"] = re.sub(r"<think>.*?</think>", "", res["text"], flags=re.S).strip()
    if res["err"]:
        res["err"] = re.sub(r"org_\w+", "org_X", res["err"])  # id организации в логи не пишем
    return res


def norm(s):
    s = s.lower().replace("ё", "е")
    s = re.sub(r"[^\w ]", " ", s)
    return " ".join(s.split())


def cer(ref, hyp):
    a, b = norm(ref), norm(hyp)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1] / max(1, len(a))


def vision_msgs(prompt, url, system=None):
    m = [{"role": "user", "content": [{"type": "text", "text": prompt},
                                      {"type": "image_url", "image_url": {"url": url}}]}]
    if system:
        m.insert(0, {"role": "system", "content": system})
    return m


def pct(xs, p):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    k = (len(xs) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def samples(limit=None):
    meta = json.loads((SAMPLES / "samples.json").read_text())
    return meta[:limit] if limit else meta


def pick(a, k):
    """--pick 3,6,9,10,1 — номера образцов (1-based) по кругу; иначе все по порядку."""
    meta = samples()
    if a.pick:
        idx = [int(x) - 1 for x in a.pick.split(",")]
        return meta[idx[k % len(idx)]]
    return meta[k % len(meta)]


def run_single(name, a, log):
    rows = []
    for k in range(a.runs):
        s = pick(a, k)
        url, nbytes = img_data_url(SAMPLES / s["file"], a.scale, a.fmt)
        r = call(name, vision_msgs(P_SINGLE, url, PERSONA), stream=not a.nostream, max_tokens=200)
        lines = [x.strip(" «»\"'1)2).-") for x in r["text"].splitlines() if x.strip()]
        read = lines[0] if lines else ""
        reply = " ".join(lines[1:])
        row = {"mode": "single", "cand": name, "file": s["file"], "img_bytes": nbytes, "ref": s["text"],
               "read": read, "reply": reply, "cer": cer(s["text"], read) if read else 1.0,
               **{k2: r[k2] for k2 in ("ttft", "t_nl", "total", "status", "err")}}
        # «до первых слов ответа» = после первой строки (расшифровки)
        row["t_reply"] = r["t_nl"] if not a.nostream else r["total"]
        rows.append(row)
        log.write(json.dumps(row, ensure_ascii=False) + "\n")
        log.flush()
        pr(row)
        time.sleep(a.sleep)
    return rows


def run_chain(a, log):
    rows = []
    for k in range(a.runs):
        s = pick(a, k)
        url, nbytes = img_data_url(SAMPLES / s["file"], a.scale, a.fmt)
        r1 = call(a.ocr, vision_msgs(P_OCR, url), stream=False, max_tokens=80)
        read = r1["text"].strip().strip("«»\"'")
        r2 = call(a.reply, [{"role": "system", "content": PERSONA},
                            {"role": "user", "content": read or "…"}],
                  stream=not a.nostream, max_tokens=300)
        row = {"mode": "chain", "cand": f"{a.ocr}+{a.reply}", "file": s["file"], "img_bytes": nbytes,
               "ref": s["text"], "read": read, "reply": r2["text"].replace("\n", " "),
               "cer": cer(s["text"], read) if read else 1.0, "t_ocr": r1["total"],
               "ttft": None if r2["ttft"] is None else r1["total"] + r2["ttft"],
               "total": (r1["total"] or 0) + (r2["total"] or 0),
               "status": f'{r1["status"]}/{r2["status"]}', "err": r1["err"] or r2["err"]}
        row["t_reply"] = row["ttft"]
        rows.append(row)
        log.write(json.dumps(row, ensure_ascii=False) + "\n")
        log.flush()
        pr(row)
        time.sleep(a.sleep)
    return rows


def f(x):
    return "  -  " if x is None else f"{x:5.2f}"


def pr(row):
    print(f'{row["cand"]:28s} {row["file"]} {row["status"]} reply@{f(row.get("t_reply"))} '
          f'ttft {f(row["ttft"])} total {f(row["total"])} cer {row["cer"]:.2f} | {row["read"][:40]} | '
          f'{(row["reply"] or row["err"] or "")[:110]}', flush=True)


def summary(rows):
    ok = [r for r in rows if not r["err"]]
    if not ok:
        return
    print(f'== {rows[0]["cand"]}: ok {len(ok)}/{len(rows)}  reply p50 {f(pct([r["t_reply"] for r in ok], .5))} '
          f'p90 {f(pct([r["t_reply"] for r in ok], .9))}  total p50 {f(pct([r["total"] for r in ok], .5))} '
          f'p90 {f(pct([r["total"] for r in ok], .9))}  CER mean {statistics.mean(r["cer"] for r in ok):.2f}  '
          f'img {ok[0]["img_bytes"]}B', flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["smoke", "single", "chain", "list"])
    ap.add_argument("cands", nargs="*")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--ocr")
    ap.add_argument("--reply")
    ap.add_argument("--nostream", action="store_true")
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--fmt", default="png", choices=["png", "gray", "jpeg"])
    ap.add_argument("--sleep", type=float, default=0.5)
    ap.add_argument("--tag", default="")
    ap.add_argument("--pick", default="3,6,9,10,1", help="номера образцов; '' = все")
    a = ap.parse_args()
    if a.mode == "list":
        for n, c in C.items():
            print(n, c[2], "vision" if c[3] else "text")
        return
    OUT.mkdir(exist_ok=True)
    tag = a.tag or "_".join(a.cands or [str(a.ocr), str(a.reply)])
    log = (OUT / f"{a.mode}_{tag}_{int(time.time())}.jsonl").open("w")
    if a.mode == "smoke":
        url, _ = img_data_url(SAMPLES / "01_ok.png")
        for n in a.cands or list(C):
            if C[n][3]:
                r = call(n, vision_msgs(P_OCR, url), stream=False, max_tokens=60)
            else:
                r = call(n, [{"role": "user", "content": "Скажи «привет» одним словом."}],
                         stream=False, max_tokens=300)
            print(f'{n:16s} {r["status"]} {f(r["total"])} {(r["text"] or r["err"] or "")[:150]!r}', flush=True)
    elif a.mode == "single":
        for n in a.cands:
            summary(run_single(n, a, log))
    else:
        summary(run_chain(a, log))


if __name__ == "__main__":
    sys.exit(main())
