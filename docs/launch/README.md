# Launch

`shipping-autoreflect.html` is the release-readiness checklist — a working document, not a
snapshot. It is the source of truth for what stands between the current build and a first
App Store release, and it is meant to be edited as work lands.

**Published at:** https://claude.ai/code/artifact/a6db436a-dc30-4fdc-a915-0cc80bccc050

Republish that same URL after editing so the link stays stable; publishing without it
creates a second, competing copy.

## How the checkboxes work

Two layers, deliberately:

- **`checked` in the markup** means done and committed. This file is the record.
- **Ticks made in the browser** are the reader's own, kept in `localStorage`.

On load the two are unioned, so stale local state can never un-tick something the markup
says is finished, and the reader's own ticks survive a republish. "Clear my ticks" resets
only the local layer.

When a task is genuinely complete, add `checked` to its input here and republish — don't
rely on a tick that only exists in one browser.
