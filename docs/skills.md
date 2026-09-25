# Skills ride with the app

Ruled 25 Sep 2026. The skills a session relies on to write a page the hub can
show, and to open it there, travel inside the app and are linked into every
harness on the Mac at launch, the way the hooks have been since August.

## What travels

`skills/` in this repo is the source of truth:

| skill           | what it is for                                                     |
| --------------- | ------------------------------------------------------------------ |
| `share-as-page` | turn a report into an on-brand page the hub can show               |
| `research-hq`   | index, open and publish pages; owns `hq-open`, `hq-theme`, `hq-tags` |
| `hub`           | search and read what every agent on this account has written (`hq`) |
| `bin/`          | the commands the skills' prose names, put on PATH                  |

`SkillManifest.expected` and `SkillManifest.shims` are the table. An edit to a
skill is a PR here; the next release carries it to every paired Mac within the
hour. That is the courier that was missing: on 24 Sep the other Mac opened a
report as `file://` through an `hq-open` that predated the 12 Sep "open the
hub" ruling, because `~/.claude/skills` was hand-edited on one Mac and shipped
nowhere.

## Where each harness reads them

| harness     | reads                       | presence test          |
| ----------- | --------------------------- | ---------------------- |
| Claude Code | `~/.claude/skills`          | `~/.claude` exists     |
| Codex       | `~/.agents/skills`          | `~/.codex` exists      |
| OpenCode    | `~/.config/opencode/skills` | `~/.config/opencode`   |

OpenCode also reads `~/.claude/skills` and `~/.agents/skills`; Codex follows
symlinked skill folders. `~/.codex/skills` is a legacy location: a hand-made
copy there loads beside ours as a second skill of the same name, so the repair
retires it.

## How the links are made

Symlinks, not copies. Each `<skillsDir>/<name>` is a link into the source. The
source is learned, never guessed: from a link that already resolves into a
directory holding every skill, else the directory `tbase install-skills`
recorded, else the bundle's own `Contents/Resources/skills`. The bundle ranks
last for the reason it does for hooks: a developer's checkout must keep
winning, or a debug build would repoint every link at a frozen copy.

A real directory at a skill's name is a hand-installed copy and is moved to
`<skillsDir>.before-tbase/<name>`, never deleted. Out of the scanned directory,
not renamed inside it: every harness loads every subdirectory holding a
SKILL.md, so a copy parked beside ours under any name is a second skill (the
first cut did exactly that, and the harness listed `share-as-page.before-tbase`
within the minute). The receipt is a re-audit. The same holds for the shims in
`~/.local/bin`.

```
tbase install-skills        # from the main checkout: record skills/, link every harness, put hq on PATH
```

The app does the same at every launch and logs one line per harness
(`skills_state` in analytics), and a `hud.note` when a harness could not be
linked.

## A page the hub cannot hold

The same day's other finding. The hook records project pages on purpose (a
brief built in `~/Projects` went unrecorded on 21 Aug), and on 24 Sep the
newest such page was the website's own `index.html`, git-tracked and deployed.
Open Report opened it as `file://`.

`PageDestination` is the one resolver now: a page in the agents tree is read
in the hub app; a page outside it is read at the address it declares
(`intranet:url`, `rel="canonical"`, `og:url`); only a page that declares none
is opened as a file, and the door says Open File. The local hub's row links
the same address, and the mirror sends the hosted hub a link-only row whose
`published_url` is that address, so the hub shows it as any published page.
