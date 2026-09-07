# Organiser eval

Phase 0 of the voice-first direction: can a model turn a rambling monologue into a journal
entry, and can that be verified mechanically? No app, no schema, no UI.

```bash
cd backend/evals/organiser && python3 organise.py
```

Reads `GROQ_API_KEY` from the environment or `backend/.env`. Never prints it.

## The guard

`wordguard.py` asks *is every word the user's?* An organiser must fail that by design, because
grouping a ramble means dropping "um" and moving minute 8 next to minute 1.

This asks the weaker question that still keeps the promise: **is every sentence accounted
for?** Input is numbered one sentence per line; every number must appear exactly once in a
section's `sources` or in `dropped`. Nothing may silently vanish, and what the model threw away
is visible rather than inferred.

## Why that guard is not optional

The first run, with a reasonable prompt and no output ceiling, produced two good-looking
sections and stopped. **41 of 55 sentences disappeared** with no acknowledgement: the call with
his mother, the text from Sam, the realisation about the schedule conflict, the bit about being
tired. Three quarters of somebody's day, and the output looked completely fine.

Without the accounting there is no way to see that from the result. That failure is the entire
argument for the design.

## Where it stands

After raising the completion ceiling and telling the model how many lines it must account for:

- 55 in, 100% accounted for, nothing silent, nothing duplicated.
- 6 dropped, all genuine filler: `Um.` x3, `Where was I.`, `Um, what else.`, `Anyway.`
- Voice survives. It kept "That's a fine lie", "I thought I was further along than this.
  Apparently not." and "I said I'd fix that in August. It's September." A summariser smooths
  exactly those away, and they are the reason to keep a journal.

Two seams still to fix, both real:

1. **Thread grouping is partial.** The transcript deliberately returns to work at line 42 after
   leaving it at line 15. The model noticed the link and wrote "the migration thing Priya
   mentioned", but kept it as a separate section instead of joining the work thread. That was
   the headline promise, so it is not finished.
2. **A seam error.** "And then, okay, the thing I actually keep circling back to." landed in the
   lunch section when it introduces the next one.

## Note on models

The backend's `DEFAULT_FORMATTING_MODEL` is `llama-3.3-70b-versatile`, which Groq has since
retired. It 404s. This eval uses `openai/gpt-oss-120b`, which is on the account today.

---

# Can this run on-device instead? Measured, not assumed

Run on macOS 26.5.2, M1 Pro, against Apple's `FoundationModels` framework. Same job, same
transcript. `ondevice.swift`, `probe.swift`, `repeat.swift`.

## The answer: transcription yes, organising no. Not yet.

**The context window is 4,096 tokens and that is the whole story.**

```
  ~4 min  (560 words)   fits
  ~8 min  (1120 words)  EXCEEDS WINDOW
  ~12 min (1680 words)  EXCEEDS WINDOW
```

The product is explicitly a ten-minute ramble where minute 8 has to be grouped with minute 1.
A model that cannot hold the transcript cannot make that connection, and chunking does not
rescue it: the entire value is seeing the whole day at once. **Apple's on-device model cannot
hold the core use case.**

That is a ceiling, not a bug, and it will move. Re-run these scripts when it does.

## A refusal, which needs watching rather than alarm

The first structured-generation attempt failed with
`GenerationError.Refusal — "May contain sensitive content"` on an ordinary journal entry: work
stress, a call with his mother, an ex texting, being tired. Nothing explicit anywhere in it.

It did not reproduce. Four subsequent runs of the same text through plain `respond(to:)` all
passed, and each journal topic passed individually. The difference was guided generation plus
instructions containing "never soften an uncomfortable thought", so it is likely the structured
path or the instruction wording rather than the content.

Recorded because the stakes are asymmetric. A journal is *made of* the material safety
classifiers are cautious about, and "the app refused to organise your day" is not a failure a
journalling app survives. Even a small refusal rate rules the path out. Isolate it before
depending on it.

## What this means for cost

Split the two jobs, because they have different answers:

| | Where | Cost per entry |
|---|---|---|
| Transcription | **On device.** `SpeechAnalyzer`/`SpeechTranscriber`, no window limit | **free** |
| Organising | Hosted, until the on-device window grows | **~$0.001** |

Transcription is the larger of the two hosted costs and it goes to zero. What is left is about
a tenth of a cent per entry, so a daily user costs roughly **three cents a month**. A thousand
daily users is around $30/month. That is not a dependency to be afraid of.

**The trade is privacy, not money.** With organising hosted, the transcript leaves the phone.
The onboarding screen currently promises nothing is uploaded, so either that copy changes, or
organising becomes an explicit per-entry choice, or it waits for a bigger on-device window.
That decision is a product one and is not made here.

---

# Fixing the two seams, measured

Eyeballing one run proves nothing here: the model is stochastic, and the first version's
output varied between 484 and 589 words across identical inputs. `eval.py` runs the prompt N
times and scores it against groupings that are known to be correct for this transcript.

The two things the product actually promises, as assertions:

| Check | Lines | Why |
|---|---|---|
| thread rejoins after 30 lines | 12 & 42 | Priya asks about the migration; thirty lines later he realises it clashes with Marcus's October plan. Same thread, far apart. **This is the headline promise.** |
| transition sits with what it introduces | 30 & 31 | "And then, okay, the thing I actually keep circling back to" opens the Sam thread. It is not a closing line for lunch. |
| unrelated topics stay apart | 4 & 17 | The deploy and calling his mother are not one section. A guard against merging everything. |

## Result

```
                          v1        v2
thread rejoins           3/5       4/5
transition placement     3/5       5/5
unrelated stay apart     5/5       5/5
silent drops               0         0
sections (avg)           7.0       6.2
```

Three changes did it. The prompt now works in two explicit steps, identify the threads and
then write one section per thread; it emits a `threads` field **first**, so the model plans
before it writes rather than discovering structure as it goes; and it says outright that
writing a second section about the same thread is the failure to avoid, because distance in
the transcript is the reason the job exists rather than a reason to split.

The falling section count is the merging showing up as a number.

A passing run, showing the promise working:

```
  threads: ['work', 'family', 'lunch', 'sam', 'health', 'overall']
  [3-45] work      sources: [3..15, 42, 43, 44, 45]
  [30-40] sam      sources: [30, 31, ..., 40]
```

## Honest limits

- **This is tuned against one transcript.** 4/5 on a single input is a signal, not a
  guarantee, and some of the gain may be fitted to this particular day. A second transcript
  with a different shape is the next thing this eval needs, before anyone trusts the number.
- **The remaining 1-in-5 is not catastrophic.** When it misses, work becomes two coherent
  sections rather than one; nothing is lost or invented, and the coverage guard still holds at
  zero silent drops across every run of both versions.

## Free-tier rate limits, since it shapes the eval

Groq's free tier caps **tokens per minute**, not requests, and one organiser call is roughly
4,000 tokens, which is most of a minute's budget. Fanning out five runs in parallel just races
the same bucket and earns a 429. The eval reads `x-ratelimit-remaining-tokens` and waits.

Worth carrying into the product: on a free tier, concurrent users organising at the same
moment will queue behind each other.
