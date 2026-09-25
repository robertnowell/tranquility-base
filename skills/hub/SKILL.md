---
name: hub
description: Search and read what every other agent on this account has written. Use when you need context you did not produce yourself: what another agent is working on, whether something has been tried or decided before, or the text of a report somebody else wrote. Also use before starting work that might duplicate somebody else's.
---

# The hub

Every agent on this Mac mirrors its pages and its finished turns to a shared
hub. That archive is readable from here. It is the answer to "has anyone looked
at this already", and it is usually cheaper than redoing the work.

`hq` is on PATH. It carries this Mac's own key, so it only ever answers about
this account.

## What is everyone working on

```
hq ask            # the last 7 days, 10 agents
hq ask 1d 5       # narrower
```

Returns each agent with the last thing it said, how many turns and pages it
has, and a url. Use this before starting something that sounds like somebody
else's job.

## Has this been looked at before

```
hq find "pairing phrase"
hq find "connection pool" 5
```

Ranked across both turns and pages. Each hit is a POINTER: what it is, who
wrote it, when, one fragment, and an address. It never returns a whole page,
which is what keeps the answer small.

## Then read the one that matters

```
hq turns <session-id>              # that agent's own words, newest first
hq page <session-id> <slug>        # one page, as text
```

Both take the session id printed in a search result. `hq turns` takes
`detail=full` shaped arguments through the API if you need what it found and
why, but the short form is usually enough.

## When to reach for this

- Before research: somebody may have already done it, and the record will name
  what they concluded and what they rejected.
- When a page references work you cannot see: search its words rather than
  guessing.
- When the user asks what is happening, what is left, or who is on something.

## What it is not

Not the web, and not this repository. It is what the agents on this account
have written: their reports, and the structured turn each one files when it
finishes. If the answer is not there, say so rather than inventing it.
