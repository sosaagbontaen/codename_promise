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

---

# Proving it before building on it

Four properties have to hold, and only the first was ever measured:

1. **Accounting** — nothing vanishes silently.
2. **Grouping** — scattered threads come back together.
3. **Fidelity** — the output is their words rearranged, not paraphrased.
4. **Restraint** — a small day stays small; one subject does not get carved up.

3 and 4 decide whether this is a journal or a summary of one, and neither is visible from
reading a single nice-looking output.

## Fidelity holds, and it is measurable

At 55 sentences, over three runs: **100% of content words in the output appeared in the lines
that section cited**, and **zero words appeared that were nowhere in the transcript**.

That is tenet 3 as a number. The model is arranging, not writing. It is the same property
`wordguard` enforces for the copy-editor, expressed in a way an organiser can actually satisfy.

## Length is where it broke, and the cause was not the prompt

At 111 sentences (~8 minutes, the real use case) single-pass lost about a third of the day.
The first diagnosis, that the model loses track at length, was wrong.

**`gpt-oss-120b` is a reasoning model, and reasoning tokens count against
`max_completion_tokens`.** Measured on the assignment call:

```
  reasoning_effort=low     completion 1680  of which reasoning 1414   (84%)
  reasoning_effort=medium  completion 3111  of which reasoning 2848   (92%)
```

With a modest ceiling the model spent the whole allowance thinking and returned an empty
string, which the API reports as `400 json_validate_failed` with an empty `failed_generation`.
That reads exactly like a broken prompt, and it is not. Raising the ceiling instead collided
with the token budget and produced `413`, which reads like an oversized payload, and is not
that either.

Two error codes, neither meaning what it says, both traceable to one cause.

`medium` also groups better than `low`: at `low` the model split Deepa into her own thread,
at `medium` it correctly folded her into work.

## Two passes instead of one

Single-shot asks the model to hold the whole transcript *and* write every section in one
response. Splitting it plays to what each pass needs:

- **Pass 1** sees every line and assigns each to a thread. Needs global attention, produces
  almost no text, and its coverage is trivially checkable.
- **Pass 2** writes one section from one thread's lines. Needs no global view, and **cannot
  quote a line it was never shown**, which is what keeps fidelity high by construction rather
  than by instruction.

Grouping still happens globally, in pass 1. Only the writing is local.

Result at 111 sentences: **zero silent drops**, which single-pass could not manage.

The guard also stopped being only a detector. A line the model forgets to assign is attached
to its neighbour's thread deterministically, so an imperfect plan costs a slightly worse
grouping rather than a lost sentence.

First attempt over-fragmented badly: 15 sections, work and Deepa split apart, a one-line
section for paying council tax. A day has a few real subjects, not fifteen, and the assignment
prompt now says so.

## What the free tier actually allows

```
  x-ratelimit-limit-tokens:    8000   per minute
  x-ratelimit-limit-requests:  1000   per day
```

One eight-minute entry costs roughly **12,000 tokens across seven calls**, which is more than
a minute's budget. So on the free tier a long entry takes over a minute to organise and the
section writes have to be paced. That is a pacing constraint, not a design one: on a paid tier
the sleep goes away and the pipeline is unchanged.

Worth carrying into the product either way, because it sets what "organising…" has to feel
like in the UI for a long recording.

## The hole in the guard, found by running it

The paced two-pass run at 111 sentences reported **zero silent drops** and full accounting.
It had also thrown away a third of the entry.

The model declared **41 of 111 lines "filler" (36%)**, which the accounting guard happily
accepted, because every line was accounted for. Eleven of those carried real content, and they
were not incidental lines:

```
   12. I always do that.
   13. I sit with something way too long before I ask anyone.
   60. That's probably the actual thing today.
   98. It's the same thing twice in one day.
  102. There's a pattern here isn't there.
  104. Things I've decided to deal with later and later has quietly become never.
  107. a lot of separate things turned out to be the same thing
```

Those are the reflective lines. They are the reason a person keeps a journal at all, and the
model discarded exactly them, because they read as asides next to "the boiler guy came at half
seven". Then it passed the guard.

**`dropped` was an unaudited escape hatch.** A model can summarise, call the remainder filler,
and score 100% on accounting. That is the precise failure the guard exists to prevent, wearing
a different hat.

### The fix: verify drops, do not trust them

Same principle as `wordguard` - do not believe the prompt, check the output. A line may be
dropped only if it is **six words or fewer and made entirely of words that carry nothing on
their own** ("um", "anyway", "where was I"). Anything with a real subject and verb survives
regardless of what the model thinks of it, and is re-attached to the nearest section.

Checked against the eleven lines it wrongly dropped and six genuine fillers:

```
  kept       I sit with something way too long before I ask anyone.
  kept       There's a pattern here isn't there.
  kept       Things I've decided to deal with later and later has quietly become never.
  droppable  'Um.'   'Anyway.'   'Where was I.'   'Um, what else.'
```

Clean separation, no model judgement involved.

A drop rate above 20% is now also reported as a warning, since genuine filler in speech runs
maybe 5-15%. The rate is the smoke; the audit is the fire.

### And the thread count over-corrected

Constraining to three-to-six threads swung too far the other way: lunch, the pasta and the
boiler ended up in one section spanning lines 23 to 111, while Deepa still appeared in two.
Relaxed to four-to-eight. The lesson is that a single number is the wrong control here, and
the honest state is that grouping quality is still the least settled of the four properties.
