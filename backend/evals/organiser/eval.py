"""Measure the organiser against known-correct groupings, over repeated runs.

Eyeballing one run tells you nothing useful: the model is stochastic and the first
attempt already varied between 484 and 589 words of output. These are the two things the
product actually promises, expressed as assertions about which lines end up together.
"""
import json, os, pathlib, re, statistics, sys, time, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor

REPO = pathlib.Path("/Users/sam.osa-agbontaen/Documents/Projects/codename_promise")
MODEL = "openai/gpt-oss-120b"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/128.0 Safari/537.36")

# (label, line a, line b, must be in the same section)
CHECKS = [
    ("thread rejoins after 30 lines", 12, 42, True),   # Priya's migration <-> the conflict
    ("transition sits with what it introduces", 30, 31, True),  # "circling back to" <-> Sam
    ("unrelated topics stay apart", 4, 17, False),     # the deploy <-> calling mum
]

def key():
    if os.environ.get("GROQ_API_KEY"): return os.environ["GROQ_API_KEY"]
    return next(l.split("=",1)[1].strip().strip('"').strip("'")
                for l in (REPO/"backend/.env").read_text().splitlines()
                if l.strip().startswith("GROQ_API_KEY"))

def sentences(text):
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text.replace("\n"," ")) if s.strip()]

def run_once(system, numbered, n):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role":"system","content":system},
                     {"role":"user","content":numbered + f"\n\n(That is {n} lines. Account for every one.)"}],
        "temperature": 0.3, "max_completion_tokens": 8000,
        "response_format": {"type":"json_object"},
    }).encode()
    req = urllib.request.Request("https://api.groq.com/openai/v1/chat/completions", data=body,
        headers={"Authorization": f"Bearer {key()}", "Content-Type":"application/json", "User-Agent":UA})
    # The free tier caps tokens per minute, and one organiser call is most of a minute's
    # budget. Read what is left and wait for it rather than firing into a 429.
    for attempt in range(8):
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                out = json.loads(json.load(r)["choices"][0]["message"]["content"])
                left = r.headers.get("x-ratelimit-remaining-tokens")
                reset = r.headers.get("x-ratelimit-reset-tokens", "0s")
                if left is not None and int(left) < 6000:
                    time.sleep(float(re.sub(r"[^0-9.]", "", reset) or 0) + 2)
                return out
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 7:
                raise
            wait = float(re.sub(r"[^0-9.]", "", e.headers.get("retry-after", "") or "20") or 20)
            time.sleep(min(wait, 45) + 3)

def section_of(result, line):
    for i, s in enumerate(result.get("sections", [])):
        if line in s.get("sources", []): return i
    return None

def score(result, total):
    cited = set()
    for s in result.get("sections", []): cited |= set(s.get("sources", []))
    dropped = set(result.get("dropped", []))
    out = {"uncited": len(set(range(1,total+1)) - cited - dropped),
           "sections": len(result.get("sections", [])), "checks": {}}
    for label, a, b, same in CHECKS:
        sa, sb = section_of(result, a), section_of(result, b)
        ok = (sa is not None and sa == sb) if same else (sa != sb)
        out["checks"][label] = ok
    return out

def evaluate(system, runs=5):
    sents = sentences(pathlib.Path("ramble.txt").read_text())
    numbered = "\n".join(f"{i}. {s}" for i, s in enumerate(sents, 1))
    # Sequential on purpose: parallelism just races the same token bucket.
    results = [run_once(system, numbered, len(sents)) for _ in range(runs)]
    scores = [score(r, len(sents)) for r in results]
    print(f"  runs: {runs}   sections: {statistics.mean(s['sections'] for s in scores):.1f} avg"
          f"   silent drops: {sum(s['uncited'] for s in scores)} total")
    for label, *_ in CHECKS:
        hits = sum(s["checks"][label] for s in scores)
        bar = "#" * hits + "." * (runs - hits)
        print(f"    {bar}  {hits}/{runs}  {label}")
    return results, scores

if __name__ == "__main__":
    system = pathlib.Path(sys.argv[1]).read_text()
    results, _ = evaluate(system, runs=int(sys.argv[2]) if len(sys.argv) > 2 else 5)
    pathlib.Path("last.json").write_text(json.dumps(results[0], indent=2))
