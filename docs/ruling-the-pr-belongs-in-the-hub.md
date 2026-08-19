# The PR belongs in the hub

Ruled 18 Aug 2026, in a voice session, with the hub on screen. Extends the
card's second door (`docs/ruling-the-second-door-opens-the-hub.md`) rather than
replacing it: the door still opens the hub, and the hub now has one more kind of
thing on it.

## The ruling, in the user's words

> "PRs should be in the Hub… Whenever you need to look at a PR to merge it or
> whatever, it should at least be in the Hub. We don't have to add a third type
> of thing, like report, PR, open, on the left-hand side."

Two sentences, and the second is half the ruling: **the card keeps two doors.**
A per-thing primary action stays an idea for later. The hub absorbs the need.

## Why the hub and not a door

The hub exists because correlation worked from one end only. A page could carry
a footer back to its agent, and that was a judgment call made per file that
would sometimes say no; the hub solved it from the other end, because the agent
has an address and everything it made is listed there.

A pull request is something the agent made. It had simply never been on the
list — so a session could open one, say so out loud, and leave you with no way
to reach it from the page you were already looking at. Adding a third door to
the card would have solved the same problem by growing the surface that the
hub was built to stop growing.

## What is still forbidden: the lookup

`SessionBrief` carried a standing comment saying there was no `pullRequest`
field and that this was deliberate. The deliberate part was never the field. It
was the LOOKUP: resolving a PR from the branch announced "pull request 2023 is
merged" for a PR merged months earlier whose branch was still checked out —
true, unrelated to the work, and indistinguishable from a hallucination.

That comment already contained this ruling's answer and stopped one step short
of it:

> a PR is spoken exactly when the session spoke about it. That is attributable
> by construction, needs no `gh`, no GitHub, no worktree convention, and no
> state.

So a PR is now **filed** exactly when the session spoke about it. Same evidence,
same attribution, one more field.

## The field is a copy, and that is checkable

`pullRequests` is written by the summariser, whose instruction is to COPY any
pull request URL the message printed, character for character — not to shorten
one, repair one, promote a bare `#117` into one, or construct one from a branch
name. It is explicitly told it is not being asked whether a PR exists, only
whether this message printed its address.

Because the prompt asks for a copy, the output is checkable against its
original: `groundedPRs` keeps only URLs that occur verbatim in the source
message. This is the same instrument as `groundDigits` and for the same reason —
it is **not** a quality filter on a judgment the model made, because no judgment
was requested. A URL the message never contained is not a wrong answer to "which
PR is this"; it is not an answer to the question that was asked.

## No state, ever

The hub prints the number, the repository, and the link. It does not print
open / merged / closed, and it must not learn to: that is a fact about a moment,
this page is rewritten at every visit, and the app has already paid once for
asserting a stale one. The link is the whole feature; GitHub is the only thing
that knows.

`testThePageNeverClaimsAPRState` holds this.

## What changed

- `SessionBrief.pullRequests: [String]?` — a list, because one turn can open
  two. The standing comment was rewritten to record what is still forbidden
  rather than reading as a ban on the field.
- `Summarizer` — one schema line, one instruction, and `groundedPRs` /
  `isPullRequestURL`.
- `StoredBrief.pullRequests` + migration `v12_brief_pull_requests` — one TEXT
  column, newline-joined. A URL cannot contain a newline, so the separator is
  total. An empty list stores as nil, because "this turn opened no PR" and "this
  row predates the column" are the same fact and deserve one representation.
- `HomeBase` — `Turn.pullRequests`, `prItems`, and PRs printed FIRST in the
  turn's made-list, above the pages: a branch waiting on you outranks a page you
  can read later.
- The shelf is now **Earlier work**, not "Earlier pages". It holds more than
  pages.

## What did not change

- Two doors on the card. GO TO AGENT is the terminal; OPEN HTML is the hub.
- The hub's length constraint. PRs are downsampled with their turn like
  everything else — a standing list of every PR an agent ever opened is a log,
  and this page is a briefing you can read in a sitting.
- `ArtifactStore`. A PR is not a file, and the store's guard that a record is an
  absolute path stays exactly as strict as it was.
