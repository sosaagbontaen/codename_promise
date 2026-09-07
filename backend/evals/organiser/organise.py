"""Phase 0: can a model turn a ramble into a journal entry, accountably?

No app, no schema, no UI. The only question is whether the output is good enough to
build around, and whether the coverage guard can be enforced mechanically.

The guard replaces wordguard on this path. wordguard asks "is every word the user's?",
which an organiser must fail by design. This asks the weaker question that still keeps
the promise: "is every sentence accounted for?" Every numbered sentence must appear in
exactly one section's sources, or be explicitly listed as dropped. Nothing may silently
vanish, and what the model chose to throw away is visible rather than inferred.
"""
import json, os, re, sys, pathlib, urllib.request

REPO = pathlib.Path("/Users/sam.osa-agbontaen/Documents/Projects/codename_promise")
MODEL = "openai/gpt-oss-120b"

def api_key() -> str:
    """From the backend's own .env. Never printed, never logged."""
    if os.environ.get("GROQ_API_KEY"):
        return os.environ["GROQ_API_KEY"]
    for line in (REPO / "backend/.env").read_text().splitlines():
        if line.strip().startswith("GROQ_API_KEY"):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("no GROQ_API_KEY")

def sentences(text: str):
    """Whisper emits punctuated prose with no paragraphs. Split on terminals, keep dashes."""
    parts, buf = [], ""
    for tok in re.split(r"(?<=[.!?])\s+", text.replace("\n", " ")):
        tok = tok.strip()
        if not tok: continue
        # Fragments like "Um." are their own sentence and must still be accounted for.
        parts.append(tok)
    return parts

SYSTEM = """You are organising a spoken journal entry. The input is a transcript of someone \
talking freely about their day, numbered one sentence per line. People ramble: they jump \
between topics, double back, and return to something they mentioned earlier.

Your job is to produce the journal entry they would have written if they had the patience to \
write it.

RULES
- Group related thoughts together, including ones that are far apart in the transcript. If \
they talk about work at line 3 and again at line 40, those belong in the same section.
- Use their own words and voice. Keep their phrasing, their slang, their humour. You are \
arranging what they said, not rewriting it.
- You may drop pure filler: "um", "where was I", false starts that go nowhere, \
sentence fragments that carry no content.
- Never invent a fact, a feeling, or a conclusion they did not say.
- Never soften or tidy an uncomfortable thought. If they said something bleak about \
themselves, it stays.
- Sections should be a few sentences of flowing prose, not bullet points.

ACCOUNTING
Every input line number from 1 to the last must appear exactly once, either in a section's \
"sources" or in "dropped". This is checked automatically and a mismatch is rejected outright.

Before you answer, count the lines you were given. Your sources and dropped lists together \
must contain every number in that range with none missing. Cover the whole transcript to the \
final line, not just the opening. A partial answer is a failure.

Reply with JSON only:
{"title": "a short title in their voice, from what they actually said",
 "sections": [{"heading": "...", "body": "...", "sources": [1,2,9]}],
 "dropped": [4,7]}"""

def organise(numbered: str) -> dict:
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": numbered
                      + f"\n\n(That is {numbered.count(chr(10))+1} lines. Account for every one.)"}],
        "temperature": 0.3,
        "max_completion_tokens": 8000,
        "response_format": {"type": "json_object"},
    }).encode()
    req = urllib.request.Request(
        "https://api.groq.com/openai/v1/chat/completions", data=body,
        headers={"Authorization": f"Bearer {api_key()}", "Content-Type": "application/json",
                 # Cloudflare 1010 blocks urllib's default signature.
                 "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                               "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(json.load(r)["choices"][0]["message"]["content"])

def check(result: dict, total: int) -> dict:
    """The guard. Coverage, not word identity."""
    cited, dupes = set(), []
    for s in result.get("sections", []):
        for i in s.get("sources", []):
            if i in cited: dupes.append(i)
            cited.add(i)
    dropped = set(result.get("dropped", []))
    every = set(range(1, total + 1))
    return {
        "uncited": sorted(every - cited - dropped),
        "duplicated": sorted(set(dupes)),
        "out_of_range": sorted((cited | dropped) - every),
        "dropped": sorted(dropped),
        "covered_pct": round(100 * len(cited) / total, 1),
    }

if __name__ == "__main__":
    sents = sentences(pathlib.Path("ramble.txt").read_text())
    numbered = "\n".join(f"{i}. {s}" for i, s in enumerate(sents, 1))
    print(f"input: {len(sents)} sentences\n" + "="*72)
    result = organise(numbered)
    pathlib.Path("out.json").write_text(json.dumps(result, indent=2))

    print(f"\nTITLE: {result.get('title')}\n")
    for s in result.get("sections", []):
        print(f"## {s.get('heading')}   [{len(s.get('sources',[]))} lines]")
        print(f"{s.get('body')}\n")

    v = check(result, len(sents))
    print("="*72 + "\nGUARD")
    print(f"  coverage           {v['covered_pct']}% of sentences cited")
    print(f"  uncited (silent)   {v['uncited'] or 'none'}")
    print(f"  duplicated         {v['duplicated'] or 'none'}")
    print(f"  out of range       {v['out_of_range'] or 'none'}")
    print(f"\n  dropped as filler ({len(v['dropped'])}):")
    for i in v["dropped"]:
        print(f"    {i:>3}. {sents[i-1][:88]}")
