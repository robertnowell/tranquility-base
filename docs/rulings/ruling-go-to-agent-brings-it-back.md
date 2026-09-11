# Go to Agent brings it back

Ruled 11 Sep 2026, 09:00, on the card for "Summarize AssemblyAI onboarding".

## The ruling, in the user's words

> "When I clicked go to agent, it says it's no longer running. Well, no shit
> it's no longer running. Like, restart it if it's no longer running. Like,
> what the fuck is that supposed to do? I had to go back to the past agents
> grid and then revive it manually. That's not very helpful. If I click go to
> agent, it's not running. Like, how about reviving it?"

GO TO AGENT on an agent that is not running revives it, then opens it. The
card no longer says "Revive it from Past Agents"; the only refusal left is an
agent with nothing on disk to bring it back from, and that refusal says so.

## What actually happened that morning, from app.log and the rollout

1. 08:59:36 Revive from Past Agents. `codex resume` on codex-cli 0.153.4 with
   0.154.0 released stopped on Codex's update chooser: "› 1. Update now (runs
   `curl … | sh`)  2. Skip  3. Skip until next version".
2. The launcher refused to press through it, correctly
   (`neverAutoAcceptNeedles`), and returned a `.failure`. `revive()` read any
   non-attached answer as "already running somewhere, adopt it", adopted the
   process sitting on the menu, and said "✓ RESUMED".
3. 09:00:08 A 15-second dictation was routed to the agent. The floor check
   read the `›` menu row as a composer holding someone's text, joined the
   words after it, and pressed Return. On that screen Return is "1. Update
   now". The installer ran (the `codex` symlink is stamped 09:00), the old
   process exited, the transport could not confirm, and the words went to the
   clipboard and the utterance store.
4. 09:00:39 GO TO AGENT found no live process and said "Revive it from Past
   Agents." Twice.
5. 09:00:57 A second revive attached cleanly, because Codex was now 0.154.0
   and had nothing to ask.

## What changed

- **The chooser never appears.** The Codex default command carries
  `-c check_for_update_on_startup=false`, Codex's own documented switch,
  measured live: with it off, a start that otherwise prints the update banner
  prints nothing about updates. The 28 Aug default, stored verbatim, is
  upgraded in place, the same way the 25 Aug default was. Updating Codex is a
  thing a person does with `codex update`, not a thing a revive can trigger.
- **A pane on a question is not a session to adopt.** `attemptCodexResume`
  returns `.stoppedOnPrompt(says:screen:pane:)`, a named outcome, and
  `revive()` shows the pane and says what it asks instead of adopting it.
- **A pane on a question is never typed into.** `DispatchTarget` carries the
  harness's `neverAutoAcceptNeedles`; `TmuxTransport.send` reads the screen
  once before anything is pasted and defers with "can't take this yet, it's
  waiting on a question in its tab. Codex is asking whether to update itself
  before it starts. Your words are kept."
- **GO TO AGENT revives, then opens.** `goToSession(_:reviveIfGone:)` hands a
  dead, revivable session to `revive(thenGoTo: true)`, which comes back to
  open it once the pid is confirmed.

## What was not lost

The 09:00:08 words were on the clipboard from the moment the send failed, and
are in the utterance store as `EF974A4A…` (`dispatched_unconfirmed`). The card
said "Copied your words to the clipboard." The 09:02 re-dictation said the same
thing at greater length and reached the agent.
