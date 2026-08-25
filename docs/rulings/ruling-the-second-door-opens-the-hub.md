# The card's second door opens the hub

Ruled 15 Aug 2026, in a text session, with the card on screen. Supersedes the
door's first landing (`43d9cc3`, "this agent, and the last thing it made"),
which pointed OPEN HTML at the latest artifact and hid it when there was none.

## The ruling, in the user's words

> "This is a GUI app — every session should have [an] open html that opens the
> hub. Discuss with agent is the button in the html that opens the tb agent to
> discuss."

One sentence: **OPEN HTML opens the agent's hub** — the page that lists
everything the agent made and carries "Discuss with agent" — and the artifacts
are one click past it.

## The evidence, not an argument

The operator asked "where did our tb hub go" while looking at a card with one
door. The card was not broken; it was built to a different sentence. The
artifact door required `ArtifactStore.latest` to name a file, so a session that
had written no page showed no door at all, and the hub — written after every
announcement since it shipped — had no entrance anywhere in the panel. The
`home` deep link existed (`tranquilitybase://home`), but nothing fired it. A
surface reachable only by a URL nobody types is a surface that disappeared,
and the operator's question is the measurement.

The old door also had nowhere for its own children to stand: an agent with six
pages showed a door to one of them, chosen by recency, and the other five were
invisible from the card. The hub already solves exactly that — it is the list.

## What changed

- `StatusHUD` resolves `hubForSession` (an existence check against
  `~/Documents/agents/<slug>/index.html`) instead of `artifactForSession`, and
  the tap hands the app a session id, not a path.
- The app rewrites the hub fresh at the click (`openHub(session:)`) and then
  focuses or opens it — the same code path the `home` deep link now uses, so
  the button and the link cannot drift.
- The door appears with the agent's first spoken turn (every announcement
  writes the hub) rather than with its first artifact. The absence drill
  (`noHubNoDoor`) still holds for sessions never summarized.

## What did not change

- The button keeps its name. OPEN HTML still opens an HTML file; the file is
  the right one now.
- Two doors still bracket the card (ui-pass-7). GO TO AGENT is the terminal;
  OPEN HTML is the browser.
- The artifact record (`artifact-hook.sh` → `ArtifactStore`) is untouched: the
  hub's page list is rendered from it, so the record's job moved one page back,
  not away.
- "Discuss with agent" stays on the hub, unchanged: either the agent is here
  and you land on it, or you are offered one.
