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

## It speaks, and there is only one path

Ruled 18 Aug, second pass:

> "Just speak. […] I want a new agent. I've taken an action. That is a
> recognition that the agent is alive and ready for me to communicate. So,
> speak. […] And also, a new flag for a new user — anytime we get into that,
> the new-user experience is going to collect bugs, because it's not what I'm
> using day to day. So the elegant thing is the power user has the same
> experience as the new user."

The greeting reads itself out, on every launch, for everybody.

Two things follow, and both are the point:

1. **It goes through `announceNext(only:)`** — the same door ⌃⌥ and a grid-row
   tap already use. That function documents why the interruptibility gate does
   not apply to it ("you cannot interrupt someone who just asked"), and pressing
   NEW AGENT is exactly that ask. It also has to be this door rather than the
   ambient arrival path: that path stays quiet when the session's own tab is
   frontmost, and a launch activates Terminal by construction, so the greeting
   would be skipped nearly every time it mattered.
2. **There is no first-run flag, and no setting.** A greeting that only speaks
   the first time is a code path the person shipping this never runs, and an
   unrun path collects bugs. One experience, exercised daily by the people most
   able to notice when it breaks — accessible to a new user precisely because it
   is not a special case built for them.

The hail-and-standby protocol is unchanged for turns an AGENT produces. This is
the one turn the app produces, in answer to a button you just pressed, and
answering out loud is what the button means.

## The card comes first

Ruled 18 Aug, third pass, on the first build:

> "Absolutely not, not good at all. One, it focuses the terminal tab, which I
> obviously don't want it to do. Second, it doesn't bring up the UI until after
> the terminal is already initiated and started. […] We can create the card
> immediately and then attach it to the session ID once that's initiated. And the
> message is literally *How should we get started?* Or *What would you like to
> work on?* Two, three seconds of audio. But it should be fast, and the terminal
> window does not need to be focused."

And, a minute later, on the callsign the card was wearing:

> "What is this callsign? Why is there a callsign? You don't even know what we're
> working on."

Four things were wrong, and all four came from routing a launch through the
machinery built for turns that had already happened:

1. **Terminal was activated.** `launch` said `activate` because it always had.
   Nothing needs it — the trust prompt is answered with `do script ""` addressed
   to the tab by id, not with keystrokes — so it is gone. `resume` keeps its
   `activate`, for the reason its own ruling gives: a revived session opens on a
   question only you can answer.
2. **The card waited on the world.** A window opening, a CLI starting, a trust
   watcher settling (two polls, ~4s minimum), an id appearing in `claude agents
   --json`. None of that is a precondition for asking a question, so the panel
   waits on none of it: the card paints and speaks on the button press, and
   `bindGreeting` attaches the session underneath when it exists. The trust
   watcher now runs concurrently with the registration watch instead of in front
   of it.
3. **It narrated.** "New agent. It's up in Projects and hasn't been asked for
   anything. How would you like to get started?" — three facts you can see on the
   card, in front of the only part that was a question. Two lines now, alternating,
   nothing else: *How should we get started?* / *What would you like to work on?*
4. **It wore a callsign.** A name minted from a turn with no content, prefixed to
   a sentence you did not need attributed, on the one card in the app where you
   already know exactly which agent is talking, because you just pressed the
   button that made it.

The unbound card is nil-targeted, not placeholder-targeted: `currentTarget == nil`
is what the panel already means by "no session on this face", so GO TO AGENT, the
hub link, and the title-as-door all stay correctly shut until the binding lands.
`bindGreeting` refuses once the face has moved on — a late registration must never
repoint the reply routing at a session you have stopped looking at.

## Controls belongs to the panel, not to the grid

Ruled 18 Aug, on the greeting card:

> "There's no controls hover option on this screen. Make sure anything we change
> here will work regardless of the specific state. Since we changed the bottom —
> open hub, go to agent, et cetera — there's no controls thing here, which
> probably we do need. It's hard to put that in the top bar. It could go in the
> centre… but then probably we should move it to the centre on the grid as well."

The word lived in the grid footer and nowhere else, so the moment a card took the
stage — the face you are on when a gesture is most likely to be the next thing you
do — the only place that names the chords was gone.

- **One class, two placements.** `ControlsWordView` owns the hover behaviour, the
  ink tiers and the type; the grid footer holds one and the action row holds the
  other. Two instances, because they are two rows; one definition, because a
  second copy of the behaviour is how the two drift.
- **The middle, on both faces.** A card's bottom line already spends both edges
  (OPEN HUB left, GO TO AGENT right), so the centre is the only free space — and
  the grid's copy moves there too, because a permanent affordance that changes
  position with the face reads as a different thing each time.
- **One rule, off the state.** `cardControls.isHidden = !state.isCardOnStage`,
  written once in `render()` rather than unhidden by each arm, so a face added
  later inherits the answer instead of quietly missing it. Not while a capture is
  in flight: arming, listening, transcribing and the send countdown are the panel
  mid-transaction, and a note about how to start the thing you are already doing
  is furniture.
- **The note hangs over the row that owns the word**, placed per open rather than
  pinned at construction, and centred on the panel — it is wider than the word is
  long, so following the word's leading edge would run it off the right.

Drill: `gridWordIsCentred`, `cardKeepsTheWord`, `cardNoteOpens`,
`cardNoteFitsThePanel`, `captureDropsTheWord`, and `wordSurvivesEveryFace` — the
last asserted over the list of card faces rather than at one of them, because the
regression this ruling is about is a NEW face quietly not inheriting the rule.
