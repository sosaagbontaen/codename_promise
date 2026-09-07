"""Organise in two passes instead of one.

Single-shot asks the model to hold the whole transcript *and* write every section in one
response. For an eight-minute entry that is ~2k in and ~7k out, which exceeds an entire
minute of the free tier's token budget, and it is also where coverage got shaky.

Splitting it plays to what each pass actually needs:

  Pass 1  sees every line, decides which thread each belongs to. Needs global attention;
          produces almost no text, so it is cheap and its coverage is trivially checkable.
  Pass 2  writes one section from one thread's lines. Needs no global view at all, and
          cannot quote a line it was never shown, which is what keeps fidelity high.

Grouping still happens globally, in pass 1. Only the writing is local.
"""
import json, os, pathlib, re, time, urllib.error, urllib.request

REPO = pathlib.Path("/Users/sam.osa-agbontaen/Documents/Projects/codename_promise")
MODEL = "openai/gpt-oss-120b"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/128.0 Safari/537.36")

ASSIGN = """You are reading a transcript of someone talking freely about their day, numbered \
one sentence per line. People do not talk in order: they start a subject, wander off, and come \
back to it many lines later.

Assign every line to a thread. A thread is one subject, however scattered. If they discuss work \
at line 3 and return to work at line 60, both lines get the thread "work". Never create two \
threads for the same subject.

Lines that are pure filler ("um", "where was I", false starts carrying no content) get the \
thread "filler".

HOW MANY THREADS
A day has a few real subjects, not fifteen. Aim for three to six, plus "filler". If you find \
yourself naming a thread for a single passing mention, it is not a thread: put that line with \
the nearest larger thread it sits beside, or with the general thread about how the day felt.

Threads are subjects, not moments. Work is one thread even if it includes a deploy, a \
colleague and a worry about next quarter. A person is not a separate thread from the subject \
they came up in.

Reply with JSON only. Every line number from 1 to the last must appear exactly once:
{"threads": {"work": [3,4,60], "brother": [22,23], "filler": [10,16]}}"""

WRITE = """You are writing one section of someone's journal from their own spoken words.

You are given the lines they said about this one subject, in the order they said them. Write \
them as a few sentences of flowing prose.

- Use their words and phrasing. Keep their slang and their humour. You are arranging what they \
said, not rewriting it.
- Never add a fact, a feeling or a conclusion they did not say.
- Never soften an uncomfortable thought.
- Do not add a heading, a preamble or a summary.

Reply with JSON only: {"heading": "a short heading in their voice", "body": "the prose"}"""

def key():
    if os.environ.get("GROQ_API_KEY"): return os.environ["GROQ_API_KEY"]
    return next(l.split("=",1)[1].strip().strip('"').strip("'")
                for l in (REPO/"backend/.env").read_text().splitlines()
                if l.strip().startswith("GROQ_API_KEY"))

def chat(system, user, max_tokens, reasoning="medium"):
    body = json.dumps({"model": MODEL,
        "messages":[{"role":"system","content":system},{"role":"user","content":user}],
        "temperature":0.3, "max_completion_tokens":max_tokens,
        # gpt-oss is a reasoning model and reasoning counts against the completion budget.
        # At the default it spent 84% of the allowance thinking and returned empty JSON, which
        # surfaced as a 400 json_validate_failed and looked for all the world like a prompt
        # problem. "medium" also groups better than "low", which split Deepa out of work.
        "reasoning_effort": reasoning,
        "response_format":{"type":"json_object"}}).encode()
    req = urllib.request.Request("https://api.groq.com/openai/v1/chat/completions", data=body,
        headers={"Authorization":f"Bearer {key()}","Content-Type":"application/json","User-Agent":UA})
    for attempt in range(8):
        try:
            with urllib.request.urlopen(req, timeout=240) as r:
                out = json.loads(json.load(r)["choices"][0]["message"]["content"])
                left = r.headers.get("x-ratelimit-remaining-tokens")
                reset = r.headers.get("x-ratelimit-reset-tokens","0s")
                if left is not None and int(left) < 4000:
                    time.sleep(float(re.sub(r"[^0-9.]","",reset) or 0) + 2)
                return out
        except urllib.error.HTTPError as e:
            if e.code not in (429, 413, 400) or attempt == 7: raise
            # The per-minute bucket refills on a rolling minute. Waiting a full one is the
            # only thing that reliably clears it; shorter backoffs just re-collide.
            time.sleep(65)

def sentences(text):
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text.replace("\n"," ")) if s.strip()]

def organise(sents):
    numbered = "\n".join(f"{i}. {s}" for i, s in enumerate(sents, 1))
    plan = chat(ASSIGN, numbered + f"\n\n(That is {len(sents)} lines. Assign every one.)", 4000)
    threads = plan.get("threads", {})

    # The guard does not only detect, it repairs. A line the model forgot to assign is
    # attached to the thread its neighbour belongs to, so an imperfect plan costs a slightly
    # worse grouping rather than a lost sentence. Nothing is ever silently dropped.
    placed = {n for v in threads.values() for n in v}
    for missing in sorted(set(range(1, len(sents) + 1)) - placed):
        home = None
        for offset in range(1, len(sents)):
            for probe in (missing - offset, missing + offset):
                for name, lines in threads.items():
                    if name != "filler" and probe in lines:
                        home = name; break
                if home: break
            if home: break
        threads.setdefault(home or "other", []).append(missing)

    sections, dropped = [], sorted(threads.get("filler", []))
    for name, lines in threads.items():
        if name == "filler" or not lines: continue
        lines = sorted(lines)
        body_in = "\n".join(sents[i-1] for i in lines if 1 <= i <= len(sents))
        # Pace the section writes. Free tier is 8,000 tokens a minute and one entry needs
        # roughly 12,000 across seven calls, so an eight-minute recording takes longer than a
        # minute to organise here. On a paid tier this sleep goes away; the pipeline does not
        # change, only how fast it is allowed to run.
        out = chat(WRITE, body_in, 2000)
        time.sleep(18)
        sections.append({"heading": out.get("heading", name),
                         "body": out.get("body", ""), "sources": lines})
    sections.sort(key=lambda s: min(s["sources"]))
    return {"title": "", "sections": sections, "dropped": dropped, "threads": list(threads)}

if __name__ == "__main__":
    import sys
    sents = sentences(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "ramble_long.txt").read_text())
    r = organise(sents)
    cited = set()
    for s in r["sections"]: cited |= set(s["sources"])
    missing = sorted(set(range(1,len(sents)+1)) - cited - set(r["dropped"]))
    print(f"  sentences {len(sents)}   threads {r['threads']}")
    for s in r["sections"]:
        print(f"    [{min(s['sources'])}-{max(s['sources'])}] {s['heading']}  ({len(s['sources'])} lines)")
    print(f"  cited {len(cited)}  dropped {len(r['dropped'])}  SILENT {len(missing)}")
    pathlib.Path("twopass_last.json").write_text(json.dumps(r, indent=2))
