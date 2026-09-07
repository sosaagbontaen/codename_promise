"""Score the organiser prompt across several transcripts and several runs.

Four things have to hold before this is worth building an app around, and only the first
was ever measured:

1. **Accounting.**  Nothing vanishes silently. Already enforced by the coverage guard.
2. **Grouping.**    Threads that scatter across the transcript come back together.
3. **Fidelity.**    The output is the person's words rearranged, not a paraphrase of them.
4. **Restraint.**   A small day stays small. A single-topic day does not get carved up.

3 and 4 are the ones that decide whether this is a journal or a summary of a journal, and
neither is visible by reading one nice-looking output.
"""
import json, os, pathlib, re, statistics, sys, time, urllib.error, urllib.request

REPO = pathlib.Path("/Users/sam.osa-agbontaen/Documents/Projects/codename_promise")
MODEL = "openai/gpt-oss-120b"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/128.0 Safari/537.36")

STOP = set("""a an the and or but so then it its it's i i'm i've id ill im me my we us our you
your he she they them their this that these those is are was were be been being do does did
of to in on at for with from by as if not no nen just really very much more most about into
out up down over under again very can could would should will shall may might must have has
had what when where who how why all any some own too s t don didn""".split())

def words(text):
    return {w for w in re.findall(r"[a-z']+", text.lower()) if w not in STOP and len(w) > 2}

# Each transcript, and what must be true of its organisation.
# Grouping checks name distinctive phrases rather than line numbers, so editing a
# transcript does not silently invalidate the assertions.
CASES = {
    "ramble.txt": {
        "runs": 3,
        "same": [("work thread rejoins", "one-on-one with Priya", "back to work stuff"),
                 ("transition opens its thread", "circling back to", "Sam texted me")],
        "apart": [("deploy vs mum", "the deploy that we've been", "called my mom back")],
    },
    "ramble_long.txt": {
        "runs": 3,
        "same": [("Deepa thread rejoins", "Deepa mentioned she's interviewing",
                  "Back to the Deepa thing"),
                 ("brother thread rejoins", "the thing with my brother",
                  "that connects to the brother thing")],
        "apart": [("boiler vs brother", "The guy came at half seven", "the thing with my brother")],
        "max_sections": 9,
    },
    "ramble_single.txt": {"runs": 2, "same": [], "apart": [], "max_sections": 3},
    "ramble_short.txt":  {"runs": 2, "same": [], "apart": [], "max_sections": 2},
}

def key():
    if os.environ.get("GROQ_API_KEY"): return os.environ["GROQ_API_KEY"]
    return next(l.split("=",1)[1].strip().strip('"').strip("'")
                for l in (REPO/"backend/.env").read_text().splitlines()
                if l.strip().startswith("GROQ_API_KEY"))

def sentences(text):
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text.replace("\n"," ")) if s.strip()]

def call(system, numbered, n):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role":"system","content":system},
                     {"role":"user","content":numbered + f"\n\n(That is {n} lines. Account for every one.)"}],
        "temperature": 0.3,
        # Deliberately not higher. The free tier bills the *requested* ceiling against a
        # tokens-per-minute bucket, so asking for 16k both earns 413s when the bucket is low
        # and appeared to correlate with truncated, under-covered answers. 8k is comfortably
        # above the ~6.9k a 111-sentence transcript actually needs.
        "max_completion_tokens": 8000,
        "response_format": {"type":"json_object"},
    }).encode()
    req = urllib.request.Request("https://api.groq.com/openai/v1/chat/completions", data=body,
        headers={"Authorization": f"Bearer {key()}", "Content-Type":"application/json", "User-Agent":UA})
    for attempt in range(8):
        try:
            with urllib.request.urlopen(req, timeout=240) as r:
                out = json.loads(json.load(r)["choices"][0]["message"]["content"])
                left = r.headers.get("x-ratelimit-remaining-tokens")
                reset = r.headers.get("x-ratelimit-reset-tokens", "0s")
                if left is not None and int(left) < 8000:
                    time.sleep(float(re.sub(r"[^0-9.]", "", reset) or 0) + 2)
                return out
        except urllib.error.HTTPError as e:
            # 429 is "too fast". 413 here is "your remaining per-minute budget is smaller
            # than what this request reserves", which is the same wait with a different name.
            if e.code not in (429, 413) or attempt == 7: raise
            wait = float(re.sub(r"[^0-9.]", "", e.headers.get("retry-after", "") or "0") or 0)
            time.sleep(min(wait, 45) + 20)

def line_for(sents, phrase):
    for i, s in enumerate(sents, 1):
        if phrase.lower() in s.lower(): return i
    raise SystemExit(f"phrase not found in transcript: {phrase!r}")

def assess(result, sents, spec):
    n = len(sents)
    cited, per = set(), {}
    for idx, s in enumerate(result.get("sections", [])):
        for i in s.get("sources", []):
            cited.add(i); per[i] = idx
    dropped = set(result.get("dropped", []))

    transcript_words = words(" ".join(sents))
    invented, fidelity = set(), []
    for s in result.get("sections", []):
        bw = words(s.get("body", ""))
        src = words(" ".join(sents[i-1] for i in s.get("sources", []) if 1 <= i <= n))
        if bw:
            fidelity.append(len(bw & src) / len(bw))
            invented |= (bw - transcript_words)

    out = {
        "silent": len(set(range(1, n+1)) - cited - dropped),
        "sections": len(result.get("sections", [])),
        "fidelity": statistics.mean(fidelity) if fidelity else 0.0,
        "invented": sorted(invented),
        "checks": {},
    }
    for label, a, b in spec.get("same", []):
        la, lb = line_for(sents, a), line_for(sents, b)
        out["checks"][label] = per.get(la) is not None and per.get(la) == per.get(lb)
    for label, a, b in spec.get("apart", []):
        la, lb = line_for(sents, a), line_for(sents, b)
        out["checks"][label] = per.get(la) != per.get(lb)
    if "max_sections" in spec:
        out["checks"][f"at most {spec['max_sections']} sections"] = out["sections"] <= spec["max_sections"]
    return out

if __name__ == "__main__":
    system = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "prompt.txt").read_text()
    only = sys.argv[2] if len(sys.argv) > 2 else None
    for name, spec in CASES.items():
        if only and only not in name: continue
        sents = sentences(pathlib.Path(name).read_text())
        numbered = "\n".join(f"{i}. {s}" for i, s in enumerate(sents, 1))
        runs = [assess(call(system, numbered, len(sents)), sents, spec) for _ in range(spec["runs"])]
        print(f"\n{name}  ({len(sents)} sentences, {spec['runs']} runs)")
        print(f"  silent drops   {sum(r['silent'] for r in runs)}")
        print(f"  sections       {statistics.mean(r['sections'] for r in runs):.1f} avg")
        print(f"  voice fidelity {statistics.mean(r['fidelity'] for r in runs)*100:.0f}% of output words came from the lines cited")
        inv = sorted({w for r in runs for w in r["invented"]})
        print(f"  invented words {inv if inv else 'none'}")
        for label in (runs[0]["checks"] if runs else {}):
            hits = sum(r["checks"][label] for r in runs)
            print(f"    {'#'*hits}{'.'*(spec['runs']-hits)}  {hits}/{spec['runs']}  {label}")
