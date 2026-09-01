# Brand — DumpNotes

**Dump anything. Save everything.**

> DumpNotes is an app that lets you quickly capture thoughts, moments, and experiences
> through text, voice, images, or video, and automatically adds them to your Notion journals.

Read off `logos/DumpNotes Concept.png`: a violet tray with confetti — a mic, an image, a
doc, a video — flying into it. Energetic and slightly irreverent, but clean.

## Palette

Sampled from the concept rather than eyeballed.

| Token | Light | Dark | What it is |
|---|---|---|---|
| `violet` | `#603CE4` | `#8265FF` | the tray, the wordmark, "Dump it" |
| `violetDeep` | `#4A28C4` | `#6B4AE8` | pressed states, gradient tail |
| `night` | `#090D19` | `#090D19` | the hero ground |
| `ground` | `#F4F3FB` | `#0B0F1C` | app background |
| `surface` | `#FFFFFF` | `#141928` | cards |

### Confetti — one per capture mode

`text` `#3B82F6` · `voice` `#8B5CF6` · `photo` `#22C55E` · `video` `#EC4899` ·
`extra` `#F97316`

That is the whole idea of the mark: things of different kinds, flying into the same tray.

## The one rule

**Confetti colours are identity, never status.** Green there means *photo*, never *it
worked*. Status keeps its own three and never borrows from the set:

- green `reached` — it got to Notion
- amber `waiting` — it hasn't yet, and that's normal
- red `failed` — it tried and couldn't

## Provenance moved

Purple used to mean "the model touched this". After the rebrand violet means *the app*, so
provenance moved to the **voice** confetti colour — adjacent enough to stay familiar,
different enough not to read as chrome.

## Type

`Sora` display, `Manrope` body, both bundled as variable fonts (OFL). See
`CodenamePromise/Design/Typography.swift` — weights come from the `wght` axis, because iOS
otherwise serves only a variable font's default instance.

## Still to do

- The app icon: 1024x1024 PNG, **no alpha, no pre-rounded corners** — Apple masks it itself.
- `PRODUCT_BUNDLE_IDENTIFIER` is still `com.codenamepromise.journal`. It is permanent once
  shipped and nothing has shipped, so this is the free moment to change it.
- Trademark search needs redoing for "DumpNotes".
