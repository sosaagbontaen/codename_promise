# Brand

Everything here is read off the AutoReflect mark: an azure-to-violet **A** with a voice
waveform in its counter and a pen nib for a leg, a deep navy **R**, and pale periwinkle
ripples beneath. Voice, writing, and reflection — the ripples are the pun the whole name
rests on, so they are the motif worth reusing.

## Palette

| Token | Light | Dark | What it is |
|---|---|---|---|
| `azure` | `#2F6FEE` | `#5B92FF` | top of the A |
| `violet` | `#8B3DF5` | `#A970FF` | foot of the A |
| `ink` | `#151C2C` | `#EEF1F8` | the R |
| `ripple` | `#C3D2F5` | `#2C3C68` | the water lines |
| `ground` | `#FCFCFE` | `#0D111C` | the mark sits on white |

Gradient: `linear-gradient(118deg, azure, violet)`.

## The one rule

**The gradient is identity, never status.** It marks the wordmark, section tags and
progress — things that say "this is AutoReflect". It never encodes meaning.

Status keeps its own vocabulary, unchanged from the app: green reached the destination,
amber has not yet, red failed. A colour has to mean the same thing on the phone and in the
docs, or it means nothing anywhere.

## Unresolved: violet is doing two jobs

Inside the app, purple already means **the model touched this** — the `formatted` badge, the
sparkles. In the mark, violet is now the *brand*. Those collide: a purple chip currently
reads as "AI", and purple chrome would read as "AutoReflect".

Worth settling before the identity moves into the app. Two ways out:

1. **Keep purple for AI, use azure as the app's chrome accent.** The gradient stays for
   launch surfaces (icon, landing page, App Store) and does not appear in the UI.
2. **Give AI a different colour** and let violet be the brand throughout.

Option 1 is cheaper and keeps every existing screen correct.

## Type

`Sora` for display, `Manrope` for body, `JetBrains Mono` for labels. Geometric, to match the
letterforms in the mark; none of them is the default anyone reaches for first.

## Where the logo lives

**Not in the repo yet.** When it lands, `docs/brand/` is its home, and the App Store build
needs a 1024x1024 PNG with no alpha and no rounded corners — Apple applies the mask itself,
so a pre-rounded icon gets rounded twice.
