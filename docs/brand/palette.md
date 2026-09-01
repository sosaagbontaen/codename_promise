# Brand — DumpNotes

**Dump anything. Save everything.**

> DumpNotes is an app that lets you quickly capture thoughts, moments, and experiences
> through text, voice, images, or video, and automatically adds them to your Notion journals.

Read off `logos/DumpNotes Concept.png`: a violet tray with confetti — a mic, an image, a
doc, a video — flying into it. Energetic and slightly irreverent, but clean.

## Palette

Exact values from the brand sheet (`logos/DumpNotes Concept 2.png`), not sampled.

| Token | Value | What it is |
|---|---|---|
| `violet` | `#6C4CFF` | the tray, the wordmark, "Dump it" |
| `pink` | `#FF4DA6` | video |
| `amber` | `#FFB02E` | the fourth confetti |
| `green` | `#22C55E` | photo |
| `blue` | `#3B82F6` | text |
| `night` | `#0F1115` | the dark mark's ground |
| `muted` | `#6B7280` | secondary text |
| `ground` | `#F2F4F7` | app background, light |

### Confetti — one per capture mode

`text` blue · `voice` violet · `photo` green · `video` pink · `extra` amber

That is the whole idea of the mark: things of different kinds, flying into the same tray.

## The one rule

**Confetti colours are identity, never status.** Green there means *photo*, never *it
worked*. Status keeps its own three and never borrows from the set:

- green `reached` — it got to Notion
- amber `waiting` — it hasn't yet, and that's normal
- red `failed` — it tried and couldn't

## Provenance moved

Purple used to mean "the model touched this". After the rebrand violet means *the app*, so
provenance took the **blue** confetti colour rather than competing with the brand.

## Type

**Poppins** — Bold / SemiBold / Regular, per the sheet, plus Medium. One family throughout
rather than a display/body pair: Poppins is geometric with circular bowls and generous
counters, which is what makes the brand read friendly rather than corporate, and a second
face would dilute exactly that.

Bundled as static weights (OFL). Static rather than variable on purpose — a variable file
loads happily and then serves only its default instance, which is a silent, hard-to-spot
failure.

## Still to do

- The app icon: 1024x1024 PNG, **no alpha, no pre-rounded corners** — Apple masks it itself.
- `PRODUCT_BUNDLE_IDENTIFIER` is still `com.codenamepromise.journal`. It is permanent once
  shipped and nothing has shipped, so this is the free moment to change it.
- Trademark search needs redoing for "DumpNotes".
