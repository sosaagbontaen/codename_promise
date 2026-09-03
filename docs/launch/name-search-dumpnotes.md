# Name search: DumpNotes

Searched 3 September 2026. Redone from scratch because AutoReflect was taken, which is the
whole reason this happens before anything carries the name.

**I am not a lawyer and this is not a clearance opinion.** It is a screening search: enough to
tell you whether to keep going, not enough to tell you that you are safe.

## Verdict

**Not clearly free. No blocker to submitting, but the name is contested and both good domains
are gone.** Nothing found that stops an App Store submission. What was found is somebody else
actively building a product called DumpNotes right now, and a second commercial use of the
name in the same category since 2024.

The decision is yours. Three ways to read it are at the bottom.

## USPTO

No federal registration or pending application for DUMPNOTES surfaced.

Searched via the aggregators that mirror the full register (Justia Trademarks, Trademarkia,
uspto.report). None has a record for the term. Marks containing "dump" that do exist are all
in unrelated classes: DUMPSTOR, DUMPSAC, DUMP EXPRESS, DUMPTRUCK, DUMPTRUX, all waste
handling or haulage, none in class 9 or 42.

**This is the weak part of this search and you should close it yourself.** Every direct route
into USPTO's own database is blocked to scripts, so the above is the absence of a record on
mirrors rather than a search of the register. Run it at
[tmsearch.uspto.gov](https://tmsearch.uspto.gov/) and search `DUMPNOTES`, then `DUMP*NOTE*`,
in classes 9 and 42. Five minutes, free, and it is the only source that counts.

## App Store

**No app is called DumpNotes or Dump Notes.** Checked the US, UK, Canada, Australia and
Germany storefronts through Apple's own search API, then filtered to apps whose *name*
actually contains "dump" rather than trusting Apple's fuzzy matching.

29 such apps exist. None collides. The closest by name or by idea:

| App | Publisher |
|---|---|
| The Dump - AI Note Organizer | Emily Jane Simmons |
| JustPad: Brain Dump Notes | 东景 梁 |
| MindDump: Voice Notes | Collider Ventures, LLC |
| swipe stack: brain dump notes | Noah Lin |
| Brain Dump: Voice Journal | Saravanan Pitchaimani |

Apple rejects duplicate app names, so an exact-name clash would have been fatal. There is
none, and the name should be claimable in App Store Connect.

Worth saying separately from the legal question: **"brain dump" is a crowded shelf.** Fourteen
of those 29 lead with it. Being findable next to them is a marketing problem, not a
trademark one, but it is a real one.

## Who else is using the name

This is what the search actually turned up, and it is the part worth your attention.

**dumpnotes.app — registered 31 July 2026, about five weeks ago.**
Live. A deployed Next.js application with Clerk authentication and subscription redirects
wired up. Page title `DumpNotes`, meta description "Your AI-powered workspace". The root
route currently returns "This page could not be found", so it is scaffolded and not launched,
and no announcement of it exists anywhere I could find.

Someone picked this name at almost the same moment you did and is building on it.

**dumpnotes.com — registered 8 January 2024.**
Live marketing page for a note-taking app: "Clear Your Mind, Capture Your Thoughts. A simple
note-taking app designed to keep your ideas organized." Free month, then EUR 12/year. The
visible brand is *Clear Your Mind*, not DumpNotes, so the name is the address rather than the
product. Its application link points at `daily.dumpnotes.com`, **which does not resolve** -
so the product behind it may be dead or mid-migration.

**Still available:** dumpnotes.io, dumpnotes.co, dumpnotes.net.

## Reading it

**The optimistic reading.** No registration, no App Store app, and neither domain holder has
shipped anything. Trademark rights come from use in commerce; a 404 is not use. You can ship
first and be the DumpNotes people.

**The cautious reading.** Common-law rights do not need a registration, and dumpnotes.com has
been commercially attached to a note-taking product since 2024. If the .app builder ships and
registers first, you inherit their problem: a rename after launch costs your reviews, your
ranking and your links, which is worse than a rename today.

**The practical reading, and the one I would weight most.** The .com and the .app are both
gone. Even with zero legal risk you would launch onto dumpnotes.io while a stranger's
half-built site sits on the address people will type. That is a permanent tax on every
conversation about the app.

## What would settle it

1. Run the USPTO search yourself. Five minutes, and it closes the one gap above.
2. Decide how much the .com matters to you. If the answer is "a lot", this name is already
   compromised and the cheapest moment to change it is now, before the rename lands.
3. If you keep it, file an intent-to-use application (class 9) so you are the one with a
   priority date, rather than the person who has to argue about it later.

## Not done yet

The repository, bundle identifier and source are still on `codename_promise`. That rename is
deliberately **held** pending this decision, because renaming several hundred files to a
contested name and then renaming them again is the AutoReflect mistake twice.
