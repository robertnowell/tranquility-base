# The receipt is the record

Ruled 18–19 Aug 2026, over four mechanisms in one night, three of which shipped
and none of which worked until the fourth. Supersedes the pull-request halves of
`docs/rulings/ruling-the-pr-belongs-in-the-hub.md`; the ruling that a PR belongs on the hub at
all is unchanged and was right from the first minute.

## The ruling, in the user's words

> "PRs should be in the Hub… Whenever you need to look at a PR to merge it or
> whatever, it should at least be in the Hub."

and, six pull requests later:

> "There's no fucking PRs listed here. Like, what the fucking Christ? What did we
> even do?"

## What was tried, and how each one failed

Every mechanism before the fourth tried to work out a pull request from
something ADJACENT to the act of creating one.

**1. Ask the summariser to copy a URL the turn printed.** Safe, grounded, and
nearly inert: 2 briefs in 1,299. The evidence it was built on said sessions
"named the PR correctly, 7 for 7" — and naming a PR is not printing its URL.
Assistants write "PR #117". They paste the URL once, in the turn that opens it,
and never again. So the field fired on the one turn in a session that least
needed it and was empty for every turn where you want the link.

**2. Read `PR #117` with a regex, repository from the cwd.** Filed a pull
request every time a turn MENTIONED one — 172 rows for 107 distinct pull
requests, the same one filed twelve times — and assembled
`robertnowell/tranquility-base/pull/2318` out of a sentence about another
repository. A link to a pull request that has never existed.

**3. Ask GitHub which pull request the branch has.** Correct, authoritative,
and the right mechanism for the sessions it fits — this is what Kanban Code
does, and it is what already works for a session that sits in one checkout on
one branch all day. It is useless for the sessions that need it most. A session
whose turns touch the main checkout and three worktrees has no single branch,
and the branch it records is wherever its last shell command happened to leave
it. Measured on the deployed build: the turn that opened
`fix/the-cli-primes-the-hub` recorded `main`, because its final command was a
`cd` to poll a deploy log.

**4. The receipt.** `gh pr create` prints the URL of the pull request it just
made, and the hook that already sees every Bash call sees that line.

## Why the fourth is different in kind

The first three infer. The fourth observes. A receipt is written by the command
that did the thing, at the moment it did it, which is why none of the failure
modes above have anywhere to live:

- it cannot file a mention, because a mention runs no command;
- it cannot pick the wrong repository, because it does not construct a URL;
- it cannot pick the wrong branch, because it never asks about branches;
- it cannot invent a pull request, because the URL is the output of the command
  that created one.

## What is still true from the earlier rulings

- **No lookup that GUESSES.** The old ban came from a branch lookup that
  announced "pull request 2023 is merged" about a PR merged months earlier. The
  missing piece was ordering, not the mechanism, and the branch lookup survives
  as the second source with `--limit 1` — silent when a session has no single
  branch, right when it does.
- **State is shown, and read live.** A badge copied out of a turn's text goes
  stale on a page rewritten at every visit; one read from GitHub at render does
  not, and "open · 2 approvals" is the answer the page is opened to find.
- **The card keeps two doors.** No third door was ever added.

## The lesson that cost the most

Three mechanisms shipped and were announced as working. Each was verified
against a test fixture, a synthetic model, or another session's data — never
against the hub the complaint was about. The check that would have caught all
three was the same one every time, and it took four minutes: render the page
the user is looking at, and look at it.

A drill that passes is not a page that works.
