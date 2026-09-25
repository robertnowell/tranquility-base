---
name: research-hq
description: >
  Index and publish everything you've researched and written — one searchable local index
  over all your research reports and generated pages, plus optional one-command hosting of
  the subset you mark shareable, at deterministic URLs. Use when the user says "index my
  research", "where did that report go", "I can't find the page I made", "build my
  research index", "publish this report", "host my research", "make an index of my
  documents", or asks for a browsable directory of past work. ALSO use proactively —
  without being asked — after writing a research report or an HTML page to HQ, since the
  index is stale until it is rebuilt, and whenever a report needs a shareable URL (this
  is the publisher; never deploy HQ content per-directory).
allowed-tools: Bash, Read, Write, Edit
---

# research-hq

Your research and pages accumulate across sessions, directories, and tools. This turns them
into **one searchable index** — and publishes the subset you choose to share.

Everything is one deterministic script, no model involvement:

```
hq-publish            # build the index
hq-publish --deploy   # + push hosted items
hq-publish --init     # write a starter config
```

Re-run it any time; it is idempotent. **Run it after any session that writes a report or a
page** — the index is a build artifact, not a live view.

## What it does

1. **Normalizes** the HQ root to `<date-slug>/report.md`, leaving symlinks at legacy flat
   paths so old references keep resolving.
2. **Renders** `report.html` for any report lacking one (pandoc, editorial house style).
   It only ever regenerates its own output — a marker at byte 0 identifies it, so a
   hand-authored or brand-designed page is never overwritten.
3. **Collects declared metadata**, falling back to inference only where nothing is declared.
4. **Emits** `catalog.json` + `index.html` — search, group by brand/month/type, deep-link
   filters via `#q=`.
5. **`--deploy`**: copies items marked `visibility: hosted` into one static site and pushes
   it. URLs are deterministic — `<base>/<date-slug>/` — so nothing needs to be written back.

## The metadata contract

Producers declare; the index does not guess. Parse order, weakest to strongest:

**keyword inference → markdown frontmatter → `<meta name="intranet:*">` → `meta.json`**

In a report's frontmatter:

```yaml
---
question: <the question this answers, verbatim — the retrieval key>
brand: <who it's for/about>
type: research
status: draft | final | superseded
visibility: local | hosted
tags: two, to, four, words
---
```

In a generated page's `<head>` (same fields, `intranet:` namespace):

```html
<meta name="intranet:brand" content="Acme">
<meta name="intranet:type" content="research">
<meta name="intranet:question" content="what this page answers">
<meta name="intranet:status" content="final">
<meta name="intranet:visibility" content="local">
```

`question` and `tags` are what make the index searchable months later — work hides behind
codenames and clever titles, and those two fields are how it stays findable. `status` and
`supersedes` are what make it triageable: drafts and superseded passes render dimmed
instead of competing with current work.

A per-directory `meta.json` overrides everything, which is the escape hatch for legacy
items nobody will hand-annotate.

## Configuration

Machine-specific settings live in a config file; the script itself never changes.
Resolution: `--config PATH` → `$HQ_CONFIG` → `~/.claude/hq.json` → built-in defaults.
**With no config at all it still works**, indexing `~/Documents/deep-research` into
`~/research-hq`.

```jsonc
{
  "hq_root": "~/Documents/deep-research",  // where reports live
  "out_dir": "~/research-hq",              // where the index is generated
  "title": "Research HQ",
  "host": {
    "provider": "vercel",                  // vercel | command | none
    "base_url": null,                      // stable alias; learned on first deploy
    "deploy_cmd": null,                    // provider=command: any static-host command
    "robots": "disallow"                   // link-shareable, not search-indexed
  },
  "scan": {                                // optional: index pages living outside HQ
    "page_roots": ["~/Projects"],
    "extra_page_dirs": [], "exclude_dirs": [], "extra_html_globs": [],
    "episode_roots": []                    // trees whose docs live per-item
  },
  "brand_rules": [["acme", "Acme"]]        // keyword → label, first match wins
}
```

**Hosting on something other than Vercel** — set `provider: "command"` and give any
command that publishes the current directory:

```jsonc
"host": { "provider": "command",
          "deploy_cmd": "surge . my-research.surge.sh",
          "base_url": "https://my-research.surge.sh" }
```

Works with surge, netlify, `rsync` to a VPS, `aws s3 sync`, GitHub Pages — anything that
takes a directory. The publish *mechanism* is identical everywhere; only the target differs.

## Rules

- **Local by default.** Nothing is hosted unless an item declares `visibility: hosted`.
  The hosted index lists hosted items only, so private titles never reach a public surface.
- **Never deploy HQ content per-directory.** One site, one project, deterministic URLs —
  otherwise you get a sprawl of one-off hosting projects and hit account limits.
- **Never hand-edit `index.html` or `catalog.json`** in `out_dir` — they are regenerated on
  every run. Change `template.html` in this skill, or the config.
- **Hosted means world-readable.** `robots.txt` discourages crawlers and nothing is linked
  publicly, but a URL holder can read it and caches outlive deletions. Keep anything
  sensitive `local`.

## Dependencies

- **pandoc** for markdown→HTML rendering (`brew install pandoc`). Missing pandoc degrades
  gracefully: indexing still works, rendering is skipped with a note.
- **A static host** only if you deploy. Vercel CLI for the default provider; anything at
  all with `provider: "command"`.
- Python 3.9+, standard library only.
