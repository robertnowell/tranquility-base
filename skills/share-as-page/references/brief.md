# Reports that show the point

The reader hears agents by voice and opens about a hundred pages a day. A page is a work instrument, not reading. It has one job: let them find the message in seconds, find what needs them, and check any claim they doubt without reading the rest. Detail exists for trust, not for completeness.

Ruled 25 Sep 2026 after a deep research pass (agent a8e3f054, `2026-09-25-information-design-for-decisions`). The rules below are what the evidence supports; the discipline is what Robert asked for in his own words.

## The shape: three levels, far apart

1. **The message.** One sentence at headline size, with a verb. A lede of two or three sentences. Then the dark block: what needs them, or "nothing to decide".
2. **The claims.** One row per claim, a full sentence each, with a status dot and one figure. Read only the rows and the argument survives. Five to seven rows; a second, smaller list for what deliberately did not change.
3. **The artifacts.** Collapsed under their claim, never in a separate section. The thing itself: the screenshot, the diff hunk, the raw rows, the literal prompt. A one-line caption saying what to look at.

Start from `templates/brief.html`. Replace the `:root` block with `hq-theme <session id>`. The worked example is `agents/a8e3f054-8583-45f2-8bc0-3dfe55d47a06/uvape-what-is-different-redone.html`: a real report, five claims, the signed-in app under each.

## The six rules, each with what it rests on

| # | Rule | Evidence | How to check it |
|---|---|---|---|
| 1 | **Verdict first.** The answer is a sentence in the first screen, and it is conclusive. | Cochrane mandated a key-message slot; 80% of summaries still had no conclusion. A slot is not an answer. | Is there an answer, not a box, in the first screen? |
| 2 | **One anchor.** One element is visibly the most important. | Dashboard reading opens on the title 66% of the time; big numbers are visited early, long text late and inconsistently. | Count elements at the largest size. One. |
| 3 | **Headings are claims.** Every heading is a sentence with a verb. | Assertion-evidence: sentence headline over visual evidence beat topic headings on comprehension and delayed recall, N=110, p<.01. | Read only the headings. Does the argument survive? |
| 4 | **Evidence is the artifact, beside the claim.** The screenshot, the diff, the rows, the prompt. Prose about the evidence is not evidence. | Contiguity is a measured multimedia lever; the trust half is a ruling: "editorial over the data is way less useful than the data itself." | For each claim: a checkable artifact within one screen? Artifact 2, derived table 1, prose 0. |
| 5 | **Encoding fits the task.** Trends as graphs on a common scale, lookups as tables, status as colour plus shape plus label, counts with denominators. | Cognitive fit: graphs win simple trend tasks and lose to tables as tasks get complex. Natural frequencies moved physicians from 10% correct to most correct. | Any trend told in prose? Any bare percentage without its denominator? |
| 6 | **Big jumps in hierarchy.** Three levels; detail attached to its claim, collapsed. No paragraph over 80 words. | Readers scan: 79% scan, 20 to 28% of words get read, half a page only under about 111 words. | Words above the fold; longest paragraph; can every detail be reached from its claim without scrolling? |

Red flags that zero a page whatever else it does: a paragraph over 150 words; a decision that exists only in prose; a chart headed by a topic instead of a finding.

## The screenshot discipline

"Showing is always better than telling. If there's a QA element to this, show it. Open up the browser, take a screenshot." That is a process rule as much as a design one.

- **A claim about a UI carries a screenshot of that UI**, taken this session, labelled with where and when. A change carries a before and an after.
- **A claim about data carries the rows**, verbatim, from the live system, with the call that produced them named.
- **A claim about code carries the hunk**, from the merged diff, with the file and PR named. Mark the load-bearing value.
- **A claim about a prompt carries the prompt**, the literal compiled text, before and after.
- **A login is not a reason to skip it.** For Kopi: `promotions/scripts/render-authed.ts` on `origin/main` signs in as a real user with a Firebase custom token and screenshots any `trykopi.ai` path (`TARGET_URL`, `TARGET_PATH`, `TARGET_EMAIL`, `TARGET_BRAND_ID`, `CLICK_SELECTOR`, `SCROLL_TO`, `TYPE_SELECTOR`). Run it from a worktree that has `node_modules`, on Node 22. Use exact selectors (`text=/^Products$/`); a loose one clicks something else. For local pages: headless Chrome with `--screenshot`. For hub pages: `hq page <session> <slug>`.
- **The only honest gap is a "before" nobody shot at the time.** Say so where the screenshot would sit, and show the nearest raw substitute.
- **Look at what you shot before you embed it.** A crop can miss the popover; a selector can open the wrong panel.

## What stays out

Methodology, agent counts, source tiers, the order you did the work in, and findings that are true but bear on no decision. They belong in the record (a `report.md` beside the page, or the transcript), not on the page. The page cites the record in one line at the bottom.

## Vocabulary, so the shape is chosen before the writing

Brief (one reader, one decision) · status board (many items, one state each) · annotated chart (one finding, the chart carries it) · small multiples · before/after pair · comparison matrix · postmortem (impact, cause, actions, timeline) · lead plus infobox · table (exact lookups, wins as complexity rises) · checklist · timeline. A report is usually two or three of these stacked, not one long one.
