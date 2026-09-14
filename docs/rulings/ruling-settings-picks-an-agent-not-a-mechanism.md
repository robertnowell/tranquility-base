# Settings picks an agent, not a mechanism

Ruled 14 Sep 2026.

> "To the user it's just which agent do I want to use. The execution specifics
> are for Tranquility Base to figure out, not for the user to be super
> concerned with."

## The rule

The Settings agent picker lists **every agent this machine can drive**, in one
row, with no indication of how it is driven. Claude Code, Codex, local
OpenCode, crobot: same picker, same shape, same meaning. Whichever one is
selected is what New Agent starts.

**Switching the tab sets the default.** There is no separate MAKE DEFAULT
affordance. That reverses `HarnessPickerRow`'s original design, which kept
"which one am I looking at" and "which one launches" apart on the argument that
they are different questions. They are different questions and the extra click
was still not worth it; the picker shows which is current, so the change is
visible rather than silent.

## What it is not

It is **not** a claim that they work alike underneath, and nothing here asks
the two control planes to merge.

- A harness is supervised by owning a process: hooks push events, keystrokes go
  out, two witnesses are merged because they disagree, ownership is guarded.
- A provider is supervised by polling or subscribing to one authority that
  cannot be raced.

Those stay separate and they already meet where it matters, at the event and at
the row. This ruling is about the **picker**, which is a different layer
entirely, and about refusing to make the user carry a distinction that exists
for our convenience.

## What it costs

`KnownHarnesses.all` is `[any HarnessAdapter]` and the Settings picker renders
it directly. An `AgentProvider` is not a `HarnessAdapter` and never will be, so
the picker needs a third thing: a list of *selectable agents* that both worlds
contribute to, carrying a display name, an id, and whatever configuration rows
that kind of agent needs.

A harness needs LAUNCH and DIRECTORY. A provider needs a base URL and a
credential, which `Prerequisites.Item.provider` already models. The picker
shows whichever pair belongs to the selection, which is the honest version of
"the execution specifics are ours to figure out".

## The corollary that is easy to miss

`New Agent` currently runs `AgentDefaults.load(for: harness)` as a command in a
tmux pane. If the default is a provider, there is no command to run: starting
one is `AgentProvider.start`, an HTTP call, gated on `Capabilities.canStart`.

So `newSession()` branches on what kind of agent the default is. That branch is
the ONLY place the distinction may surface, and it must not leak into the
picker, the row, the card or the voice.

## What this does NOT license

**OpenCode must not become a keystroke-scraped terminal harness**, even though
that would put it in the picker tomorrow with no new concepts (ruled the same
day, rejecting that option explicitly). It ships a real server with structured
permissions and an event stream, and scraping its TUI instead would throw that
away to save a week. The picker is a presentation decision; it is not a licence
to pick the worse mechanism because the better one is not wired up yet.
