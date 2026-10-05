# Reports that show the point

The reader hears agents by voice and opens about a hundred pages a day. A page is a work instrument, not reading. It has one job: let them find the message in seconds, find what needs them, and check any claim they doubt without reading the rest. Detail exists for trust, not for completeness.

Ruled 25 Sep 2026 after a deep research pass (agent a8e3f054, `2026-09-25-information-design-for-decisions`). The rules below are what the evidence supports; the discipline is what Robert asked for in his own words.

## The shape: three levels, far apart

1. **The message.** Three to six words at seven times body size: "Two chips moved." Then the lede, whose first sentence, in bold, is the one-sentence claim with a verb; two more sentences at most. Then the dark block: what needs them, or "nothing to decide". The scale is measured, not felt: typesafe.ai sets a four-word headline at 140px over 17px body, an eight-to-one jump; a sentence at 54px over 16px was called "relatively indistinguished" (27 Sep).
2. **The claims.** One row per claim, a full sentence each, with a status dot and one figure. Read only the rows and the argument survives. Five to seven rows; a second, smaller list for what deliberately did not change.
3. **The artifacts.** Under their claim, never in a separate section, and never collapsed: no accordion, no toggle (ruled 5 Oct 2026; an accordion that starts open hides nothing, and a click on it hides what you were reading). The thing itself: the screenshot, the diff hunk, the raw rows, the literal prompt, or a diagram when the draw test says so. A one-line caption saying what to look at. See Evidence rules below.

Start with `hq-page new <slug> --session=<your full session id>` (add `--brand=NAME` for a brand page). It writes `templates/brief.html` as a draft, `<hub>/_drafts/<slug>.html`, with the session line, the kicker and the `:root` tokens filled in, binds the brand to your session, and refuses to overwrite. Nothing publishes, announces or opens a draft. When the page is finished, `hq-page publish <slug> --session=<id>` moves it to `<hub>/<slug>.html` and opens it; it refuses a draft whose placeholders are still there. Ruled 29 Sep 2026, after an empty scaffold was announced to Robert while its agent waited on a deploy. Ruled 27 Sep 2026 after two hours of watching: sessions copy their own last page because it is the cheapest start; this makes the template cheaper. The worked example is `agents/a8e3f054-8583-45f2-8bc0-3dfe55d47a06/uvape-what-is-different-redone.html`: a real report, five claims, the signed-in app under each.

## The six rules, each with what it rests on

| # | Rule | Evidence | How to check it |
|---|---|---|---|
| 1 | **Verdict first.** The answer is a sentence in the first screen, and it is conclusive. | Cochrane mandated a key-message slot; 80% of summaries still had no conclusion. A slot is not an answer. | Is there an answer, not a box, in the first screen? |
| 2 | **One anchor.** One element is visibly the most important. | Dashboard reading opens on the title 66% of the time; big numbers are visited early, long text late and inconsistently. | Count elements at the largest size. One. |
| 3 | **Headings are claims.** Every heading is a sentence with a verb. | Assertion-evidence: sentence headline over visual evidence beat topic headings on comprehension and delayed recall, N=110, p<.01. | Read only the headings. Does the argument survive? |
| 4 | **Evidence is the artifact, beside the claim.** The screenshot, the diff, the rows, the prompt. Prose about the evidence is not evidence. | Contiguity is a measured multimedia lever; the trust half is a ruling: "editorial over the data is way less useful than the data itself." | For each claim: a checkable artifact within one screen? Artifact 2, derived table 1, prose 0. |
| 5 | **Encoding fits the task.** Trends as graphs on a common scale, lookups as tables, status as colour plus shape plus label, counts with denominators. | Cognitive fit: graphs win simple trend tasks and lose to tables as tasks get complex. Natural frequencies moved physicians from 10% correct to most correct. | Any trend told in prose? Any bare percentage without its denominator? |
| 6 | **Big jumps in hierarchy.** Three levels; detail attached to its claim, open. No paragraph over 80 words. | Readers scan: 79% scan, 20 to 28% of words get read, half a page only under about 111 words. | Words above the fold; longest paragraph; can every detail be reached from its claim without scrolling? |

Red flags that zero a page whatever else it does: a paragraph over 150 words; a decision that exists only in prose; a chart headed by a topic instead of a finding.

## Artifacts: whitespace first, a rule second, a box only for code

Ruled 27 Sep 2026 after the beige boxes were called "not doing it": the reader could not tell a quote from a table from a code block, and the labels were muted uppercase above a fill the same colour as the page. The evidence (Palmer 1992, NN/g on common region, Material's divider rule, GOV.UK inset text, Primer's diff tokens, the display-polarity studies) is in `2026-09-27-artifact-blocks-contrast/report.md`.

| Artifact | Treatment |
|---|---|
| Any block | Whitespace separates it. A single rule when whitespace is not enough. A filled box only for code, where the boundary means "verbatim". |
| Quote | A 3px left rule and an indent, one size step down, no quotation marks, no fill. Under fifty words. Who, where and when in the caption. |
| Code, diff, raw rows, prompts | Dark text on the light neutral panel (`--panel`), hairline, radius 4. Never dark on light: dark-on-light wins for precision reading in every polarity study. Diff rows use Primer's tints, contrast in the text colour. |
| Screenshot | A hairline, no shadow, no device frame. Never drawn on: to point at a passage, crop to it (`.crop`, `--ar`, `--pos`), so what is shown is what was shot. The image is a link to the live thing it shows. A sentence caption below saying what the crop shows, where, when. |
| Before and after | Two screenshots side by side, captions carrying Before and After, each linked to its source. |
| Diagram | Inline SVG from `hq-diagram`, between hairlines, no box. Only when the draw test passes; see Evidence rules. |
| Table | Hairlines only, title above as the caption, header sentence case at full weight, numbers right-aligned in tabular figures. Stripes only when rows are long. |
| Caption, not label | Every artifact carries a caption below, in a sentence, at full ink. No label bar above. Uppercase tracked mono is for the kicker, the section labels and the status figure, nothing longer. |
| Gap | Plain italic text with a faint left rule, where the artifact would sit. |

Three page rules came with it. The kicker is two items, brand and date; refs and "follows" go in the tail as links. The lede is under 45 words with one bold clause. Options in the needs-you block are regular weight, one line each; the recommendation is marked with a filled dot and the word, not bolded.

## The screenshot discipline

"Showing is always better than telling. If there's a QA element to this, show it. Open up the browser, take a screenshot." That is a process rule as much as a design one.

- **A claim about a UI carries a screenshot of that UI**, taken this session, labelled with where and when. A change carries a before and an after.
- **A claim about data carries the rows**, verbatim, from the live system, with the call that produced them named.
- **A claim about code carries the hunk**, from the merged diff, with the file and PR named. Mark the load-bearing value.
- **A claim about a prompt carries the prompt**, the literal compiled text, before and after.
- **A login is not a reason to skip it.** For Kopi: `promotions/scripts/render-authed.ts` on `origin/main` signs in as a real user with a Firebase custom token and screenshots any `trykopi.ai` path (`TARGET_URL`, `TARGET_PATH`, `TARGET_EMAIL`, `TARGET_BRAND_ID`, `CLICK_SELECTOR`, `SCROLL_TO`, `TYPE_SELECTOR`). Run it from a worktree that has `node_modules`, on Node 22. Use exact selectors (`text=/^Products$/`); a loose one clicks something else. For local pages: headless Chrome with `--screenshot`. For hub pages: `hq page <session> <slug>`.
- **The only honest gap is a "before" nobody shot at the time.** Say so where the screenshot would sit, and show the nearest raw substitute.
- **Look at what you shot before you embed it.** A crop can miss the popover; a selector can open the wrong panel.

## The page wears the brand it is about

The shape never changes. The skin is one `:root` block, and it belongs to the subject of the page, not to the agent. Ruled 26 Sep 2026.

- **Decide the brand once per session**, from the conversation, at the first page: `hq-theme <session> --brand=NAME`. That binds it; every later `hq-theme <session>` resolves the same brand. A page about you, or about nobody, wears the house theme and takes the agent's ink.
- **An unknown brand falls to the house, and says so.** The header reads `NO THEME ON RECORD FOR 'X', this is the house fallback`. That is a correct page, not a failure.
- **Then do the quick research yourself, and record it.** A Kopi customer has a brand record (`set_active_brand` then `get_context`: `colors.primary`, `colors.textHeading`); a site may declare `theme-color`; a logo gives one or two real colours. `hq-theme --learn=NAME --accent=#hex [--brand=#hex] --from='the source' [--url=…]` writes the row. Colours only: a font the site names is recorded as seen and never applied, because a face without its file renders system sans.
- **Tell the user in one line, do not ask.** "Recorded U Vape from its Kopi brand record, accent #FF6699" or "Coframe declares no colour; its pages stay on the house theme." Permission is not needed; a wrong colour is one `--learn` away from right and the source is on the row.
- **Never invent a token.** The frequency of hexes in a stylesheet is not a brand. If no source gives a colour, the house is the honest answer.

## What stays out

Methodology, agent counts, source tiers, the order you did the work in, and findings that are true but bear on no decision. They belong in the record (a `report.md` beside the page, or the transcript), not on the page. The page cites the record in one line at the bottom.

## Vocabulary, so the shape is chosen before the writing

Brief (one reader, one decision) · status board (many items, one state each) · annotated chart (one finding, the chart carries it) · small multiples · before/after pair · comparison matrix · postmortem (impact, cause, actions, timeline) · lead plus infobox · table (exact lookups, wins as complexity rises) · checklist · timeline. A report is usually two or three of these stacked, not one long one.

## Editorial patterns, ruled 28 Sep 2026

From the editorial pass (`2026-09-27-editorial-design-patterns`, agent a8e3f054): what newspapers, long-form journalism, postmortems and design-led documentation do that the template did not.

- **Artifacts open, always.** GOV.UK: do not use disclosure for what most readers need; users avoid the control. Nielsen Norman: scrolling beats deciding which heading to click. The eight-claim exception was withdrawn on 5 Oct 2026: claims are sections, not accordions.
- **Text at 720px, evidence at 1000px.** Distill and Tufte hold text near 60 characters and give figures the page. A screenshot inside the text column is a click away from legible.
- **Air between claims; a rule only under the section label.** tufte-css and Distill rule only the coarsest boundary. The number and the space carry the rows.
- **The headline is under ten words and the lede answers it.** Axios: more than ten words means the lead is not found yet. The lede's first sentence answers the headline and carries the number, as Buffett's letters open with the year's gain.
- **Figures line up.** Tabular figures in the status column and in any count (Butterick, grids of numbers).
- **The summary is one declared sentence under 160 characters** (GOV.UK's rule, for the same reason: it is what every index shows).
- **Two weights; tracked capitals only for labels.** Every text token passes 4.5:1 on the house paper and the status dots pass 3:1; a brand paper darker than the house needs the faint token re-measured.
- **A hub is a list, so it takes the postmortem's facts block and the changelog's day headers:** turns, pull requests, pages and last active under the needs-you block; a day header before the first turn of each day; no hairlines between turns.

## Evidence rules, ruled 5 Oct 2026

From three passes (`2026-10-03-diagrams-for-report-evidence`, `2026-10-03-diagram-calibration`, agent a8e3f054) and two replays: ten claims rebuilt with diagrams (four better, four mixed, two worse, and the draw test below accounts for all ten), then four reports rewritten from their agents' raw turns (the evidence improved, and three of the four originals were caught stating something the turn never showed). Robert ruled: ship it, with every number cited and one piece of literal evidence per claim.

**Claims are sections.** `<section class="claim" data-shows="TYPE">`, TYPE one of flow, structure, states, change, ranking, screen, versions, lookup, text. Never `<details>`, even with `open`. Before authoring, read this brief and the generated draft in a separate tool call whose contents reach your context. Do not suppress helper output or combine scaffolding, writing and publication. `hq-page publish` refuses disclosures before moving or opening the draft.

**The draw test decides the artifact.** Diagrams win where the reader has to relate several things at once (Larkin and Simon: a diagram keeps what one inference needs side by side) and lose everywhere else, so:

1. The evidence is one sentence: write the sentence. A one-line rule drawn as a decision diamond lost to the sentence.
2. It is numbers, twenty or fewer: a table. Tufte: "Tables usually outperform graphics in reporting on small data sets of 20 numbers or less." Never a hand-drawn chart; the one in the replay read backward.
3. Nothing branches, merges or loops: a numbered list, or a table if the items do not connect at all. Three parallel sensors drawn as boxes lost to their table.
4. Otherwise, and only otherwise: draw it.

**Drawing it.** `hq-diagram in.dot --png look.png > out.svg`. Write plain Graphviz dot; the helper adds the house style. Mark the one important node or edge `tone=accent`, a broken part `tone=warn`; label every edge with what it carries or causes. It runs the draw test and prints `draw test passes` or `DO NOT SHIP AS DRAWN: why`, exiting 2. Obey it: redraw (rankdir=TB, shorter labels, split) or use what it names. The limits: one connected graph, a branch, merge or loop, at most 15 boxes, labels at 12px or more in the 700px column (ONS asks 14px for charts; 11.3px read fine in the replay, 9.6px did not), no crossing edges (Purchase 1997: "by far the most important aesthetic"). Look at look.png before embedding it.

**A diagram replaces what it restates.** Its numbers go in its labels, and the table or paragraph it redraws comes out. For an expert reader the same content twice costs time and adds nothing (expertise reversal); every replayed rebuild that stacked a diagram on its table got longer, 35% across ten claims. A table stays only for values the drawing does not carry.

**One piece of literal evidence per claim.** Code, diff, rows, log or prompt: one block, two only when the claim rests on both. The rewrites that quoted everything ran 14% longer than the originals.

**Every number cites its source.** A count or figure in a claim names the row, query or log line it came from, in the caption. Writing from the rows is what caught the overstatements: ten readers that included four test accounts, six pull requests that were seven, a proof tile that was a different file.

**Every image links to the live thing it shows**: the PR, the commit, the file at a commit, the page, the dashboard. Never to the image file. No live address: no link, and the caption says so. Never invent one.

**The page check names breaks**, after every write: a claim typed flow, structure, states or change with no diagram;  an image that links nowhere; a claim with more than two literal blocks; any `<details>`. It advises; `hq-page publish` refuses disclosure markup. A straight timeline remains a list, even when its prose says before or after.

**Measured weekly.** Three to five claims, one comprehension question each, answered from the prose and then with the diagram, plus better, mixed or worse; pooled, and read as a sign test once about twenty are not ties. Not an automated judge: the best model agrees with experts at 0.43 (VisJudge-Bench).

