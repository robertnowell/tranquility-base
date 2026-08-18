# A launch is a turn

Ruled 18 Aug 2026.

> "We don't need to go to the terminal to start a new agent. We can just kick off
> the agent with an agent message of 'How would you like to get started?' That
> doesn't actually even have to be sent to our Claude Code or whatever agent. The
> first user message can just be whatever. […] keep it simple and clean
> architecturally."

## What was wrong

`+ NEW AGENT` opened a Terminal window and stopped. The grid grew a row when the
session registered, and the row had nothing to say, because nothing had happened.
Every other way into this app is voice — you hear what an agent concluded, you
answer out loud — and the one moment where you always know what you want to say
was the moment that sent you to a keyboard in another window.

## The shape

A launch is a turn, and the app writes it.

One row in `events` and one row in `brief`, for the **real** session id Claude
Code minted, written in one transaction (`QueueStore.insert(event:brief:…)`).
Nothing else is new. The card appears because the grid draws waiting sessions;
the hail sounds because a turn arrived; ⌃⌥ reads it because a brief exists;
what you say back is typed into the tab because that is what a reply is.

- **The greeting is never sent to the agent.** It is the app speaking on its own
  behalf about a session it just started. The transcript stays empty until you
  answer, and your answer is the first thing in it.
- **No shadow session, no shadow transcript.** A greeting is exactly what every
  other turn is — an event with a brief. There is no second store to keep in
  agreement with the first, and nothing to migrate when the real turns start.
- **No model call.** The words are known, so the brief is written with them and
  the announcer's restore path (`Coordinator.restoredSummary`) reads them for
  free. The transaction is what guarantees this: an event that exists without
  its brief is an event the five-second prewarm will spend a model call on.
- **The real session id, which means waiting for registration.** There is no
  callback and no id in the launch, so the launcher watches the directory it
  launched into and takes the first id that was not there before. That watcher
  replaced the bare 30-second trust-prompt timer: registering IS the evidence
  the prompt was answered, so one watcher answers both questions.
- **No callsign yet.** Minting happens at a session's first successful summary
  and freezes for life; a name derived from a turn with no content is a name
  derived from nothing. Until then the greeting is attributed by its directory
  word, which is the only true thing about the session.
- **Not on the artifact invitation.** That launch already knows what it is for.

## The open question: does it speak by itself?

> "For me, as a power user, I don't want it to talk to me automatically, but for
> a new user, it is nice that it introduces itself and its voice."

As shipped, the greeting follows the protocol every other turn follows: **hail
and standby** — chime plus the agent's own name, then silence until ⌃⌥. So it
does not read itself out, and the power-user case is the default with no setting.

The alternative, if the first run should demonstrate the voice rather than
describe it: speak the greeting outright the FIRST time only, keyed off a
`UserDefaults` flag, and hail-and-standby forever after. That is one flag and one
call at the point where `appAuthoredArrival` is set — deliberately not built,
because the ruling above did not settle it.
