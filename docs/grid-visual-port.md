# The grid visual port — variant A, ruled

Baseline f6d3de0/e0a85a7 (WS-B grid + A2 hail landed). Source of truth:
`~/Projects/vd-grid-mock/index.html` variant A ("pA", light console,
columnar), plus the red-pen rulings: opaque surface on EVERY face,
CIRCULAR lamps, and the topic-source fix. App layer throughout; one
Core commit (db17b73) for the brief-topic join, taken because the Core
tree was clean at start.

## Palette

Single definition: `StateLegend.Palette` (the Lens/Lamp seam). Semantic
NSColor is dead in the panel — every color the panel paints is absolute
sRGB from this table, and the panel is pinned to the `.aqua` appearance
so AppKit's own chrome (bezels, picker, progress bar) renders for a
light surface in dark mode too. FED-STD-595 derivations are from the
vd-grid-mock research record (2026-08-04); FS numbers are nearest-family
citations, not paint-chip matches.

| token | value | role | FS-595 family |
|---|---|---|---|
| `surface` | `#C4C3B7` | console surface, panel-wide (blur deleted) | 36440 light gull gray |
| `ink` | `#23241F` | primary text; base of both hairlines | 37031/37038 black, warmed |
| `secondary` | `#4A4B43` | strip label, ready-row topics, chrome lens | ink tint |
| `muted` | `#5F6055` | quiet-row topics | ink tint |
| `faint` | `#83847A` | hints, placard, guidance lens | ink tint |
| `hairline` | ink @ 25% | strip rule, key-line rule | — |
| `hairlineSoft` | ink @ 12% | between-row rules | — |
| `hover` | `#BDBCB0` | row hover; quiet lamp fill | surface, one step down |
| `ready` | `#416B47` | go lamp, ✓ send button, ack pulse, action lens | 34128 green |
| `fault` | `#C8862A` | fault lamp (seam only; unproduced) | 33538 amber (mock `--warn`) |

Lens mapping: chrome→secondary, content→ink, guidance→faint,
action→ready. The action lens moving to ready green is the ruled
"accent = state, not user preference": `controlAccentColor` is gone from
the ✓ hands-free send button and the acknowledge pulse.

## Grid geometry (idle face)

380px panel, 14pt insets → 352pt content column.

- **Rows**: strict three columns — 26px lamp / 148px callsign / 178px
  topic — fixed 31px height, `hairlineSoft` rule between rows, none
  after the last. 8-row cap unchanged. Hover paints the row `hover`.
- **Lamps**: 9px circles (ruled — squares read as checkboxes), flat, no
  gradients/shadows. Ready = filled `ready`; quiet = `hover` fill with a
  `hairline` ring; fault = `fault` (seam only).
- **Type this pass**: callsigns `.monospacedSystemFont(12, ready ?
  .semibold : .medium)` in ink; topics system 11.5 regular, `secondary`
  on ready rows, `muted` on quiet. No custom font embedding yet (the
  Routed Gothic / IBM Plex identity is a later item).
- **Strip**: "SESSIONS" — system 10px, +0.16em tracking (kern 1.6),
  `secondary` — with the gear at right. NO "Ready" pill, NO "N waiting"
  headline on the grid face: the grid IS the status; the count lives in
  the menu bar.
- **Placard**: "+ NEW SESSION" — plus glyph in the lamp column, label
  system 9.5px +0.14em, `faint` — above the key line, `hairlineSoft`
  rule above it.
- **Key line**: replaces the Dismiss button on the grid face —
  monospaced 9.5px, `hairline` rule above:
  `⌃⌥ hear · hold ⌥ reply · ⌃⌃ why · ⌃⇧ dismiss`.
- Implementation: `GridRowView` / `PlacardRowView` (cell-less NSControls
  with real frames) — a bezel-less NSButton can only flow an attributed
  title inline, and columns need columns.

## The topic source fix

The row topic is the stored brief's composed 3–6-word `topic` field
(durable v6 `brief` table), carried into `WaitingSession.briefTopic` by
a `LEFT JOIN brief ON brief.eventRowid = latestId` on the two
grid-feeding queries (`waitingSessions`,
`waitingSessionsIncludingHeard`) — Core commit db17b73, path-scoped,
with tests. NEVER a prose prefix of `summaryText` or
`lastAssistantMessage`: `StateLegend.topic(summary:lastAssistantMessage:)`
is deleted, replaced by `StateLegend.gridTopic(_:)`, which sanitizes any
source to one line (newlines→spaces, markdown asterisks stripped,
whitespace collapsed) defensively.

The join is **per event, not per session**: a newer turn with no brief
yet shows nil — a fresh green lamp never wears a stale description — and
a session with no stored brief shows its callsign alone.

This kills the live bug: orphan fragments between rows ("**Voices for
lif") were markdown prose truncated mid-word by the old 60-char
derivation, and the ragged vertical gaps were free-height attributed
rows. Single-line composed topics + fixed 31px rows make both
unrepresentable; the grid's render log asserts `singleLine=true` and the
selftest feeds `gridTopic("**Voices for life**\ncampaign shipped")`
through the matrix run.

## Surface, panel-wide

`NSVisualEffectView` (hudWindow blur) → a plain layer-backed view filled
`surface`, corner radius 12, shadow and the non-activating panel config
untouched. Every other face is surface + palette swap ONLY this pass:
same layout, colors now resolved through the palette —
`titleLabel`/`highlight(upTo:)`/`LevelMeterView` dropped their
`labelColor` uses for `ink` so nothing goes low-contrast (or white, in
dark mode) on the light surface.

## Selftest / matrix

`--selftest-hud`: all 10 states + both legality checks pass. Intended
matrix deltas, both grid-face-only: `idleGrid title=0` (the "N waiting"
headline is gone) and `idleGrid actions=0` (the Dismiss button left the
grid face; the key line replaces it). Every other state's matrix line is
identical to the WS-B baseline. The grid render logs its ruled geometry:
`grid: N rows (R ready) rowH=31 cols=26/148/178 lamps=circular
singleLine=true`.

Verified live (bundle.sh → relaunch, 2026-08-05): 8 rows, 3 ready,
layout `buttonsFit=true textFits=true`, and a screencapture confirming
the putty surface, circular lamps, columns, placard, and key line, with
callsign-only rows where no brief exists.

## Judgment calls

- **`.aqua` pinning**: not in the mock, but implied by "opaque light
  surface panel-wide" — without it, dark-mode semantic colors and
  control bezels fight the putty. This is the structural version of
  chasing individual labels.
- **Fault amber** `#C8862A` is the mock's `--warn` token; the lamp seam
  keeps `.fault` complete though nothing emits it.
- **Hover/hairline width** spans the 352pt content column, not the full
  380 panel (the mock's rows are full-bleed with internal padding).
  Restructuring the stack for full-bleed rows touches every face's
  layout — out of bounds for a surface+palette pass on the other faces.
- **Empty idle state** keeps its "Voice Dispatch" title, Ready pill and
  Dismiss: the rulings govern the grid face; the empty state has no grid.
- **`latestStop` / `mostRecentlyHeard`** don't join the brief (not grid
  feeders); `briefTopic` is nil there by design.
- **Topic length**: the stored topic occasionally exceeds 6 words;
  tail-truncation remains as layout safety per the WS-B reading
  (composed label, not displayed source text).
