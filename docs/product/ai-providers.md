# Where the AI runs

Researched 7 September 2026, after deciding against on-device. Prices move; the reasoning
should not.

## The workload

One entry is roughly:

- **10 minutes of audio** to transcribe
- **~2,500 tokens in, ~1,200 out** to organise (a numbered transcript in, sections with source
  citations out)

That shape matters. Transcription is billed by the minute and dominates. Organising is a
small, cheap call that needs good instruction-following and reliable structured output rather
than a big model.

## Transcription: Groq, and it is not close

| Provider | Per hour | Per 10-min entry |
|---|---|---|
| **Groq** whisper-large-v3-turbo | **$0.04** | **$0.007** |
| Deepgram Nova-3 (batch) | $0.26 | $0.043 |
| OpenAI Whisper | $0.36 | $0.060 |
| Google Chirp 3 | $0.96 | $0.160 |

Groq is roughly 9x cheaper than OpenAI and 6x cheaper than Deepgram for the same job. The
cheap tiers are cheap partly by omission - no diarization, for instance - and this app has one
speaker talking to their phone, so none of what is missing is missing here.

**Keep Groq for transcription.** It is already wired up and nothing else is close.

## Organising: there is a genuine free tier

Since April 2026 Google's Gemini Flash and Flash-Lite are **free**, capped at 1,500 requests
per day. One entry is one request, so that ceiling is around **1,500 daily users** before a
bill exists at all.

If it is exceeded, Flash-Lite is $0.10/M in and $0.40/M out, which is **$0.0007 per entry**.

Other standing free tiers as of August 2026: Groq (30 req/min), OpenRouter (14 free models, 50
req/day), Cloudflare Workers AI, Mistral, SambaNova, Vercel AI Gateway.

Gemini also carries a very large context window, which is the constraint that ruled out the
on-device model. A thirty-minute recording fits with room to spare.

## The actual risk is deprecation, not price

The app is carrying a live example. `DEFAULT_FORMATTING_MODEL` is
`llama-3.3-70b-versatile`; Groq has retired it and it 404s today. Formatting is broken in the
shipped app right now, and nobody changed a line of code to break it.

**That** is the lock-in that bites. Not the invoice, which is pennies. The provider changing
underneath you while you sleep.

Two defences, and the app already has the first:

1. **The Protocol boundary in `app/services.py`.** Providers sit behind
   `Transcriber` / `Formatter`, and the Groq client is OpenAI-compatible, so the base URL is
   most of what ties it to Groq. Keep it that way.
2. **A router in front of the organiser.** OpenRouter takes an ordered `models` array and walks
   it when one is unavailable, falling back on deprecation, rate limits, downtime *and
   moderation refusals*. One OpenAI-compatible endpoint, and the model list is the part that
   survives a retirement. Put the model you trust most last, so the floor is something you are
   happy to ship.

## Recommendation

| Job | Provider | Cost per entry |
|---|---|---|
| Transcription | Groq whisper-large-v3-turbo | $0.007 |
| Organising | Gemini Flash-Lite, free tier | $0 up to 1,500/day |
| Organising, at scale | via OpenRouter with a fallback list | ~$0.0007 |

**Roughly $0.007 an entry, so about 21 cents per month per daily user, and effectively all of
it is transcription.** A thousand daily users is around $200/month, which any subscription
covers several times over.

Two jobs to do, in this order:

1. **Fix the retired model.** Formatting is broken in production today.
2. **Point the organiser at a router rather than one vendor**, so the next retirement is a
   config line instead of an outage.
