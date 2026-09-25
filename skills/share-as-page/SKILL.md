---
name: share-as-page
description: >
  Turn ANY document, report, research finding, analysis, audit, runbook, checklist, plan,
  meeting recap, or conversation summary into a polished, on-brand, self-contained HTML page,
  OPEN IT IN THE KNOWLEDGE BASE (hq-open), and optionally host it on a shareable URL. Resolves brand tokens
  (color, fonts, logo) so the page looks like it belongs to the ASSOCIATED brand. This is the
  DEFAULT path for any visual/document deliverable for this user — there is NO side panel
  here, so NEVER use SendUserFile and never dump long content to the terminal; build the page
  and open it in the Knowledge Base with `hq-open <path>` (never `open` on the file; ruled 12 Sep 2026). Use whenever producing a runbook / doc / one-pager / checklist
  / report / plan / page for the user to read, or when the user says "show me", "display
  this", "turn this into a page", "make it an HTML <anything>", "make it shareable / host this
  / send a link", or hands over finished content to look at or share.
allowed-tools: Bash, Write, Read, WebFetch, Edit
---

# share-as-page

Turn content you already have (a report, research, audit, recap) into **one self-contained,
on-brand HTML file** and **deploy it to a shareable URL**. One template → brand tokens →
inline everything → one deploy command.

Skill dir (`<skill dir>` below): the directory holding this SKILL.md; Tranquility Base links it into every harness — `templates/report.html`, `references/layout.md`,
`scripts/deploy.sh`.

**Where the page lands — decide first, it's binary:**

- **A document for the user** (research brief, report, runbook, audit, plan, recap — anything
  they read or archive): land it in HQ — `<hq_root>/YYYY-MM-DD-<slug>/index.html`, where
  `hq_root` defaults to `~/Documents/deep-research` (see the **research-hq** skill's config).
  Create the dir; a `report.md` may already be there if this is a research brief. Hosting for
  HQ pages goes through the central publisher (`hq-publish --deploy`,
  gated on the `intranet:visibility` meta tag) — NOT the per-dir deploy below.
- **Client-facing standalone deliverable** (a page someone external receives as its own URL,
  wearing their brand): work in `~/Projects/<slug>-page/` — the `-page` suffix is REQUIRED, the
  dir name becomes the URL — and deploy with `scripts/deploy.sh`.

When unsure, it's a document; HQ is the default.

This is the *default reusable* path. If the content has a strong native metaphor (e.g. a
boarding pass for a travel brand) you may design a bespoke layout instead — but still follow
the same token + inline + deploy rules below.

## Workflow

### 1. Gather the content
Identify exactly what to render — the report/analysis/recap text, its sections, any tables.
Don't re-research; this skill packages content that already exists in the conversation or a file.
Pick a short kebab-case slug for the project dir and the URL.

### 2. Name the brand — an explicit decision, out loud

**Every page belongs to exactly one brand, and you must say which before you author anything.**
Not "implied." State it: *"Styling this as **&lt;Brand&gt;** (`&lt;brand id or domain&gt;`)."*

- The brand is usually whoever the document is *about* or *for* — the client in a client report,
  the user's own company for internal docs.
- **Internal Kopi documents → the Kopi brand.** See `references/brands.md`, which records
  Kopi's own tokens so you never have to reconstruct them.
- If two readings are plausible (a Kopi analysis *of* a customer — Kopi's brand or theirs?), ask.
  It's one line and it prevents the whole page being wrong.

If no brand genuinely applies, say **"unbranded — using the editorial default."** That is a
legitimate outcome (and a good-looking one — see rung 5). Silently drifting into it is not.

### 2a. Resolve the tokens — and record where each one came from

You need: `--color-brand`, `--color-accent`, `--color-text`, `--color-bg`, `--color-heading`,
`--font-heading`, `--font-body`, and a logo (data URI).

Work down this ladder and **stop at the first rung that yields a value**:

1. **Explicit** — the user gave colors/logo/fonts in conversation.
2. **Recorded** — `references/brands.md` has this brand.
3. **Kopi brand record** — `set_active_brand` (query by name) → `get_context`. Map the briefing:
   - `colors.primary` → `--color-brand`; `colors.primaryForeground` → on-brand foreground
   - `colors.bodyBackground` → `--color-bg`; `colors.textBody` → `--color-text`
   - `colors.textHeading` (or `--color-brand` if null) → `--color-heading`
   - `fonts.heading.family` / `fonts.body.family` → font tokens
   - Logo: the brand's logo if present; else rung 4 for the logo only.
   Take `--color-accent` from the brand's secondary colour, or sample the logo.
4. **Site scrape** — `WebFetch`/curl the brand site: `meta[name=theme-color]` → brand colour;
   `og:image` / `apple-touch-icon` / a `.logo` img → logo. Base64-embed it (see references/layout.md).
5. **Editorial default** — the house style already in `templates/report.html`: Newsreader
   (serif, embedded) + Libre Franklin (labels, embedded), near-black ink on warm paper white,
   hairline rules, kicker/dek/byline masthead. It is a deliberate, publication-grade *unbranded*
   look — NYT/FT-class newspaper typography, recognisably a well-set independent document, never
   a guessed-at brand. Falling back here is a fine outcome, not a failure; say "unbranded —
   editorial default" and ship it. (Old grey-band template preserved at
   `templates/report-v1-corporate.html` if a page needs the previous look.)

**The provenance block is mandatory.** The template's `:root` opens with a `PROVENANCE` comment.
Fill in every token with the rung it came from, then state the same summary to the user in chat:

```
/* PROVENANCE — brand: Kopi (V8UOFCQfdeUrGvYDp_gPE)
   --color-brand   #1E3A52  rung 2, references/brands.md
   --color-accent  #FF6B4A  rung 2, references/brands.md
   --font-heading  Bricolage Grotesque  rung 2, embedded @font-face below
   logo            rung 4, scraped trykopi.ai/apple-touch-icon.png            */
```

**A token with no rung is a bug, not a style choice.**

> ### NEVER INVENT A TOKEN
> Do not pick a hex because it feels right for the brand. Do not nudge the template defaults
> "toward" a vibe. Do not derive a palette from a company's name, industry, or product metaphor.
> Do not treat an app's own UI theme as its brand — a product's `globals.css` / Tailwind config
> is usually **shadcn-style neutrals, deliberately colourless so customer brand colours can sit
> inside it**. That is chrome, not identity. Sampling a favicon gives you *one or two* real
> colours; it does not give you a background, a text colour, or a rule colour.
>
> When the ladder runs out, take rung 5 and **tell the user which tokens are unresolved**.
> A page honestly marked "unbranded — editorial default" is fine; the house style exists so the
> fallback is handsome without pretending to be anyone's brand. A page that *looks* branded but
> isn't is worse than a plain one, because the `:root` block implies a provenance it doesn't
> have — and the user has no way to see the difference. (The editorial default's own accent red
> and paper tones are house-style constants, not brand claims — leave them as-is or override
> with rung-sourced values only.)

**Fonts must actually load.** Naming a family in a stack does nothing on a machine that lacks it.
Either embed it as a data-URI `@font-face` (`scripts/embed-font.sh`) or use a system stack and say
so. A named-but-unembedded font is a silent failure — the page renders in a fallback and looks fine.

**Foreground rule** (accessible, one line): for any colored background, compute relative
luminance L; if **L > 0.179 use black text, else white** (guarantees ≥4.5:1). Logos are exempt.

### 2b. Lead with what needs the reader — mandatory ordering

**If the page contains anything the reader must decide, approve, or answer, that
block goes directly after the dek — above the findings, not at the end.** One
line per decision, the options, and your recommendation. Everything below it is
support.

Ruled 18 Aug 2026 after a report buried two "your call" blocks under 2,000 words
of evidence: *"hierarchy means needs-you is at the top, not the bottom."* Writing
the page in the order you did the work is the failure mode — the reader is there
to act, not to follow the investigation. If nothing needs them, say that at the
top too.

### 3. Author the HTML
Copy `templates/report.html` to `<project>/index.html`, then:
- **Declare the intranet metadata in `<head>` — mandatory on every page**, same footing as
  the PROVENANCE block. The intranet index parses these deterministically; a page without
  them gets keyword-guessed metadata, which is how work goes missing:
  ```html
  <meta name="intranet:brand" content="<the brand named in step 2>">
  <meta name="intranet:type" content="<research|page|runbook|plan|audit — what it IS>">
  <meta name="intranet:question" content="<one line: what this page answers or decides>">
  <meta name="intranet:status" content="<draft|final|shipped>">
  <meta name="intranet:visibility" content="<local|hosted>">
  ```
- **Close the page with the agent footer — mandatory on every HQ page**, same footing as the
  intranet metadata. A page without it is orphaned: found in a browser tab weeks later with no
  way back to the agent that made it, or to the rest of that agent's work. You already have
  everything it needs — your full session id is in your own scratchpad and transcript paths,
  `SHORT` is its first 8 characters, and the hub address is computable from `SHORT` alone.
  Write it yourself as the last element inside `<body>`; do not wait to be given it:
  ```html
  <footer data-tb-agent="SHORT" style="margin-top:64px;padding-top:20px;
    border-top:1px solid #ddd8cc;font:13px/1.5 ui-monospace,Menlo,monospace;color:#8f8a7c;
    display:flex;flex-wrap:wrap;gap:10px;align-items:center">
    <div style="flex:1;min-width:220px">Created by <b>WHAT THIS SESSION DID</b> &middot; session SHORT &middot; D MON YYYY</div>
    <a href="file:///Users/USER/Documents/agents/SHORT/index.html" style="text-decoration:none;color:#5d5a51;border:1px solid #ddd8cc;padding:7px 13px;border-radius:7px;font-weight:640">Open hub</a>
    <a href="tranquilitybase://discuss?session=FULL_SESSION_ID&amp;ref=ABSOLUTE_PAGE_PATH" style="text-decoration:none;background:#1f4f8f;color:#fbfaf8;padding:8px 14px;border-radius:7px;font-weight:640">Discuss with agent</a>
  </footer>
  ```
  The `data-tb-agent` attribute is what makes this safe to write yourself: the stamping hook
  replaces its own block and never touches a footer somebody else wrote, so writing it means
  one footer whether or not the hook ever sees the write. Omitting the attribute is what
  produces two.
- Set the `:root` tokens to the resolved brand values.
- Replace the `<title>`, nameplate (`<!-- BRAND NAME -->`, optional `<!-- LOGO -->`), the
  `<!-- KICKER -->` (section label, e.g. "Research Brief"), `<!-- TITLE -->`, `<!-- DEK -->`
  (one-sentence standfirst), `<!-- BYLINE -->`, **and the editorial `<footer>` line** — it names
  the page's own subject and date, so an inherited one is a lie about what you just wrote.
- **If you seeded this page by copying a previous page rather than the exemplar, every item in the
  list above is someone else's until you replace it.** The footer is the one that survives, because
  it sits below the content you rewrote and reads as furniture: 40 pages in this HQ carried
  "Stop operating the newsletter workflow · August 11, 2026" across nine days and a dozen unrelated
  subjects, each copied from the last. Check the bottom of the page before you call it done.
- Replace `<!-- CONTENT -->` with the report as semantic HTML (`<section>`, `<h2>`, `<p>`,
  `<table>`, `<ul>`). Keep prose to the `--measure` width; tables/chips may go full width.
  Editorial devices available: `<p class="dropcap">` opening graf, pull-quote `<blockquote>`
  with `<cite>`, top-rule stat `.chips`, `<span class="endmark">` on the final paragraph.
- **Inline everything** — no external requests. CSS stays in `<style>`; embed the logo and any
  non-system fonts as data URIs. The template ships with Newsreader + Libre Franklin already
  embedded; keep them for unbranded pages, replace/remove them when a brand's fonts take over.
- Keep the readable defaults (66ch measure, 18px/1.65, the `@media print` block). See
  `references/layout.md` for the cheat sheet and snippets.

Raise the page to the brand **using the tokens you resolved** — an accent band, a logo lockup,
on-brand section styling. Craft lives in *how you deploy* the resolved values (weight, spacing,
proportion, where the accent lands), never in inventing new ones. If the page feels generic and
the tokens are all rung 5, the honest fix is to resolve a brand — not to add colour by feel.

### 4. Visual eval — **REQUIRED, before any deploy**
Never ship a page you haven't looked at. Render it and inspect the actual pixels:
```bash
bash <skill dir>/scripts/shot.sh <project-dir> /tmp/preview.png
```
Then **Read `/tmp/preview.png`** and check, concretely:
- **Centering & width** — masthead, chips, prose, and tables share one aligned column; no
  content pinned left with a dead right gutter; no horizontal overflow.
- **Contrast** — text readable on any brand-colored surface (the `--on-brand` choice was right).
- **Serif actually rendered** — headline and body must show Newsreader (or the brand face), not
  a fallback sans; if headings render sans, the `@font-face` blocks were stripped or renamed.
- **Spacing & overflow** — nothing clipped, no text overlapping, tables not blown out.

Then run the **brand-fidelity check**, which is a different question from "does it look good."
A page with an invented palette looks perfectly good — that is exactly why this check exists and
why the rendering checks above cannot catch the failure:

- **Provenance first** — re-read your `PROVENANCE` block. Every token has a rung? Any token you
  cannot name a source for is invented; go back to step 2a and resolve or fall back to neutral.
- **Against ground truth, not vibes** — put the screenshot next to the brand's actual logo,
  site, or recorded tokens. Would someone who knows this brand recognise the page as theirs?
  "Coherent and attractive" is not the bar; "unmistakably *this* brand" is.
- **Font actually rendered** — compare the heading glyphs to the font you claimed. If you
  declared a distinctive family and the screenshot shows plain system sans, the `@font-face`
  is missing and the token is a lie. This is invisible in every other check.
- **Logo is the real mark** — it renders, and it is the brand's actual logo, not a favicon
  frame, a placeholder, or a coloured shape you drew.

If a check fails, fix the tokens — not the layout. Re-shoot. Only then deploy.

Fix the HTML and re-shoot until it's right. Only then deploy. (Optionally shoot a narrow
width too, e.g. `... /tmp/m.png 420 900`, to catch mobile breakage.) This gate is not optional —
the most common failures (off-center columns, missing logo, low contrast) are invisible until rendered.

### 5. Deploy
```bash
bash <skill dir>/scripts/deploy.sh <project-dir>
```
Prints the live `*.vercel.app` URL. (Primary = Vercel, proven non-interactive. Fallbacks below.)

### 6. Hand off
Give the user the URL and offer **one revision pass**. Mention they can ⌘P → Save as PDF
(the print CSS is wired). If any benchmark/number came from the conversation, don't invent new ones.

## Hosting reference
- **Vercel (default):** `deploy.sh` runs `vercel deploy --prod --yes`; reads `VERCEL_TOKEN`
  from env if set, else ambient login. Persistent clean alias.
- **surge.sh (fallback, pick-your-subdomain):** `surge ./dir my-slug.surge.sh` with
  `SURGE_TOKEN`+`SURGE_LOGIN`. Unlimited, persists until `surge teardown`.
- **Netlify anonymous (zero-auth one-shot):** `netlify deploy --dir=./dir --allow-anonymous`
  — but the claim window is ~1h with undocumented persistence; use only for throwaway links.
- **Skip GitHub Pages** for agent use — needs repo + branch + Actions, too multi-step.

## Rules
- **One self-contained file.** It must render double-clicked offline and over the web with zero
  external requests. Inline CSS and fonts (data URIs) — always, no exception. Type is the
  difference between a page that looks right offline and one that does not.
- **Images may live in the bucket, and only there.** Measured 07 Sep 2026: 72 of 1756 archive
  pages hold inline images and those 72 carry 94.6 MB — 35% of all the HTML on disk, four pages
  alone accounting for 75 MB. So raster media is the one class worth an outside dependency.
  It is allowed from `assets.base_url` in `hq.json` and from nowhere else: a `.png` on somebody
  else's CDN is still a page that stops working when they reorganise, and `check-brand.sh` still
  fails it. While `assets.base_url` is unset the old rule stands unchanged and everything must
  be inline. Use `research-hq/scripts/extract-media.py` to move existing pages; it verifies each
  object at the origin before it drops the inline copy, and never half-rewrites a page.
- **The way back ships with the page.** The agent footer (step 3) is not decoration and is not
  the hook's job — the hook only sees writes it can attribute, and a page written by heredoc,
  `cp`, or a script carries no path for it to attribute. Write the footer; then it does not
  matter whether anything noticed.
- **Metadata is part of the artifact.** The five `intranet:*` meta tags (step 3) and the
  PROVENANCE block ship on every page, no exceptions — they are how the intranet index files
  the page without guessing. A page missing them is unfinished.
- **Tokens, not hard-codes.** All brand color/font decisions live in `:root` custom properties so
  a re-brand is a few-line edit.
- **Don't fabricate data.** Render only what's in the source content; never invent metrics.
- **Don't fabricate tokens either.** A colour, font, or logo you chose by feel is fabricated
  design data, and it is harder to spot than a fabricated number because a `:root` block looks
  authoritative by construction. Every token traces to a rung, or the page is declared unbranded.
- **State the brand and the provenance in chat**, not only in a CSS comment. The user cannot
  see your reasoning, and a wrong-but-plausible palette is invisible to them until they ask.
- **Lightweight.** No JSON data model, no logo pipeline, no build step beyond the deploy. The only
  script is the deterministic deploy.
