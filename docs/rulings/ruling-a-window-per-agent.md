# A window per agent

Ruled 18 Aug 2026.

> "I guess we stick with new window, not new tab. Don't put in the janky fix for
> refocusing and then unfocusing — that's brittle and is gonna break. I think we
> just accept that at least for the Terminal app it's gonna be window per agent,
> and that's fine. You really don't need to look at your windows now."

## Why a tab is not available

Terminal.app cannot create a tab from AppleScript. This is a dictionary fact, not
a matter of finding the right incantation:

```
sdef /System/Applications/Utilities/Terminal.app
  class window:      <element type="tab" access="r">
  class application: <element type="window" access="r">
```

Read-only. There is no `make new tab` and no `open new tab`. `do script` with no
target creates a window as a side effect — the only creation verb Terminal
exposes — which is what the launcher uses today.

The near-miss is worse than useless: `do script … in window 1` does not create a
tab, it types the command into that window's **currently selected tab**. On a
machine running ten agents that is a `cd … && claude` typed into somebody's live
conversation.

## Why the workaround was refused

The one mechanism that works is pressing ⌘T through System Events, which requires
Terminal to be frontmost — the focus theft removed earlier the same day. It can be
softened by remembering the frontmost app, activating Terminal, sending the
keystroke, running the command and handing focus back: about 40 launcher-local
lines, since everything downstream addresses a tty and a tab has one exactly like
a window does.

It was costed and refused anyway, on two grounds:

1. **Brittleness.** The sequence depends on a keystroke landing in the right app
   at the right moment. When it does not — Terminal not front yet, a sheet up, the
   key going to the browser — the fallback has to be a guard that proves the front
   tab is fresh (`busy` false, unknown tty, empty contents) before typing
   anything. A correct implementation is a guard around a race, and it is
   invisible to `swift test` and to the panel self-tests by construction.
2. **The premise stopped holding.** Window count was a problem when you had to go
   find the window. You do not: the panel hails you, reads the turn, takes your
   reply and types it in. Windows you never look at do not need to be tidy.

## What this rules out

Not a preference to revisit when someone feels like it. A session that reaches for
System Events and ⌘T here is re-litigating a decision made with the dictionary in
hand and the workaround already designed. If it comes back, it comes back on a
measurement — a terminal that supports tabs properly (iTerm2 does, `create tab
with default profile`, no keystroke and no focus) is a different question and a
legitimate one.
