# Recorded brands (rung 2)

Brands whose tokens are known, so pages can be built on-brand without a live lookup.

**Rules for this file**
- Only record values with a real source: a stated decision, a brand record, or a scrape you ran.
- Every entry names its source and its date. Stale is fine; unsourced is not.
- If a brand isn't here, work the ladder in SKILL.md §2a. Do not guess and do not add guesses here.
- When you resolve a new brand from rung 3 or 4, **add it here** so the next page is cheaper.

---

## Kopi (own brand)

**Brand id:** `V8UOFCQfdeUrGvYDp_gPE` · trykopi.ai
**Use for:** all internal Kopi documents — research, reports, runbooks, plans, recaps.
**Identity:** "The Press" — two-ink risograph printcraft.
**Source:** Robert's decision, 2026-07-13, from the hero-aesthetic deep research
(`~/Documents/deep-research/2026-07-13-kopi-hero-aesthetic-direction.md`; Print Shop chosen over
Desk-at-Dawn / Workshop / Documentary). Recorded in memory `kopi-press-visual-identity`.

### Tokens

| Token | Value | Notes |
|---|---|---|
| Ink 1 (primary accent) | `#FF6B4A` | burnt orange |
| Ink 2 (secondary accent) | `#FFC54A` | amber |
| Paper (brand surface) | `#1E3A52` | navy |
| `--font-heading` | `Bricolage Grotesque` | `promotions/src/styles/globals.css:50`. **Must be embedded** as a data-URI `@font-face` — naming it alone renders system sans. |
| `--font-body` | `Plus Jakarta Sans`, else system stack | same source, second in the stack |

### How the identity maps to a reading document

The Press was decided as an **image-generation** identity (hero art direction, brand
`generationInstructions`), not as a document design system. The palette transfers directly;
the surface treatment needs a judgement call, so pick one deliberately and say which:

- **Full press** — navy `#1E3A52` as the page surface throughout, two inks on top. Highest
  fidelity to the identity; heavy for long-form body copy.
- **Press on light stock** — navy masthead and accents, orange/amber highlights, ink-on-light
  body. Better for 1,000+ words. **Default to this for research reports and long documents.**

Riso texture (visible grain, slight misregistration, halftone) is cheap in CSS and carries the
identity well on the masthead. Keep it off body text.

### Exemplar — copy this, don't re-derive it

`references/exemplars/kopi-press-light-stock.html` — "Stop operating the newsletter workflow"
(Aug 11, 2026). Robert's call: *"a beautiful use of colour on the Kopi colour scheme."*
**Start any new Kopi reading document from this file**, replace the masthead and `<main>`, and
leave `:root` alone. It is a frozen copy; the live page it came from will drift.

What makes it work, so it survives being edited:

| Role | Token | Where it lands |
|---|---|---|
| Heading ink | `#1E3A52` navy | Every `h1`/`h2`/`h3`, nameplate, table header rules |
| Body ink | `#1F1E1C` near-black | Prose only — never navy, which greys out at body size |
| Accent | `#FF6B4A` Ink 1 | Kicker, the short rule above each `h2`, pull-quote mark, `pre` left border, end mark |
| Page | `#FCFBF8` warm white | The "light stock" |
| Panel | `#F4F2EC` | `.panel`, `pre` background |

The discipline is **navy carries structure, orange only punctuates**. Orange appears as hairlines
and marks — never as a fill, never as body text, never on more than a few percent of the page.
The two-ink identity reads because the second ink is rationed; using it for a heading or a
filled block collapses the effect into ordinary corporate colour.

Fonts are non-negotiable here: Bricolage Grotesque (600/800) headings, Plus Jakarta Sans
(400/600/700) body, both embedded as data-URI `@font-face` via `scripts/embed-font.sh`. Naming
them without embedding renders system sans and silently loses most of the identity — the
exemplar carries both, which is most of its 412 KB.

Amber `#FFC54A` (Ink 2) is unused in the exemplar. That was the right call for a text document;
reach for it only when a page genuinely needs a third signal (a second series in a chart, a
status band), and never as a second accent competing with the orange.

### Traps specific to Kopi

- **`promotions/src/styles/globals.css` is NOT the brand.** Its `--primary: hsl(0 0% 15%)` /
  `--background: hsl(0 0% 100%)` are shadcn neutrals — deliberately colourless so *customer*
  brand colours can render inside the product. That file is app chrome. Using it as brand
  produced a monochrome page that contradicted the actual navy/two-ink identity.
- **`public/favicon-frames/kopi-*.svg` is an animation frame, not a palette.** Its fills
  (`#FF7670`, `#FFC070`, `#FFF06F`) are close to but not the Press inks. Near-misses read as
  intentional and are harder to catch than obvious errors. Use `#FF6B4A` / `#FFC54A`.

### Open / to verify

- These values come from a decision record, not a live read. Confirm against the brand record
  (`set_active_brand` → `get_context` on `V8UOFCQfdeUrGvYDp_gPE`) when convenient and update here.
- No canonical Kopi wordmark/logo file is recorded yet. The blob mark in
  `promotions/public/favicon-frames/kopi-1.svg` is the mark in use; scrape trykopi.ai for a
  proper logo and record it here.
