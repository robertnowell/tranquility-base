#!/usr/bin/env python3
"""hq-figure: a report figure drawn from rows, and the fit test that decides
whether it should exist. Ruled 11 Nov 2026.

  hq-figure spec.json > out.svg             inline SVG for the page
  hq-figure spec.json --png look.png        also a picture to look at before shipping
  hq-figure spec.json --width 560           for the narrow side of a pair (default 720)

The spec is JSON, from a file or stdin. Its "form" answers the question the
claim asks. No mark is placed by hand: every position is computed from a row.

  How much, against what?      {"form": "bars", "rows": [{"label": "Table", "value": 219},
                                {"label": "Drawn figure", "value": 0, "tone": "accent"}]}
      options: "of": 10 draws each bar on a track of that size.
               "limit": {"at": 20, "label": "Pass line"} and "unit": "cents per send" draw an axis.
               "value": [31, 43] draws a range. "groups": [{"label", "tone", "rows"}] groups rows.
               "columns": ["Topics"] with "cells": [37] on each row keeps exact values beside the bar.
               "value_label": "Highlights returned, of 10" heads the bars.
  How many of how many?        {"form": "units", "of": 12, "rows": [{"label": "Orange button", "value": 12}]}
      a row may carry "note": "Honeydew Menthol missing", a few words set after its count,
      so the table can go. Filled dots are accent unless the row sets a tone.
      or one row of groups:    {"form": "units", "groups": [{"label": "wrong form", "value": 7, "tone": "accent"}]}
  When did each thing happen?  {"form": "time", "lanes": [{"label": "Check tasks", "events":
                                [{"at": "04:32", "label": "Coframe, 4 calls", "tone": "accent"}]}],
                                "marks": [{"at": "04:15", "label": "Merge"}],
                                "band": {"from": "04:15", "to": "04:32", "label": "17 minutes with no proven read"}}
      "at" is HH:MM, or an ISO date or datetime. A gap far longer than the others is cut and labelled.
  Which passed, and where not? {"form": "grid", "columns": ["Desktop", "Phone"], "rows":
                                [{"label": "Sold-out product", "cells": ["pass", {"state": "open", "note": "not run"}]}]}
      a cell is pass, fail, open (nobody ran it) or na (it does not apply). A pass is quiet, so
      the cells that are not a pass stand out. A cell may carry a "note" of a few words.
      "words": {"open": "not run"} renames a state in the key under the grid.

tone is accent (the row that matters), dim (context, the default), warn, or hollow.

The fit test, on stderr: a figure earns its space only when the reader must
see a size, a share, an order, a gap or the cells that are not a pass. One value is a sentence. Too many rows
is a table. A label that collides is a redraw. When the rows do not fit the
form it prints DO NOT SHIP AS DRAWN with the reason, and exits 2. A figure
replaces the table it restates. If the table must stay, keep only the table.
"""
import datetime, glob, html, json, os, statistics, subprocess, sys, tempfile

STYLE = (
    "<style>.hqf{--d:#b9b4a8;--k:#ebe8e0}"
    "@media (prefers-color-scheme:dark){.hqf{--d:#5c5952;--k:#26251f}}"
    ".hqf text{font-family:var(--sans,ui-sans-serif,-apple-system,'Helvetica Neue',sans-serif);font-size:13px;fill:var(--ink,#1f1e1c)}"
    ".hqf .m{fill:var(--muted,#57534c);font-size:12px}.hqf .b{font-weight:600;fill:var(--heading,#141312)}"
    ".hqf .n{font-variant-numeric:tabular-nums}"
    ".hqf .accent{fill:var(--accent,#4a5a2b)}.hqf .dim{fill:var(--d)}.hqf .warn{fill:var(--amber,#a8762a)}"
    ".hqf .hollow{fill:var(--bg,#fcfbf8);stroke:var(--ink,#1f1e1c);stroke-width:1.6}"
    ".hqf .empty{fill:none;stroke:var(--d);stroke-width:1.4}.hqf .track{fill:var(--k)}"
    ".hqf .ln{stroke:var(--line,#ddd9cf);stroke-width:1}.hqf .ax{stroke:var(--ink,#1f1e1c);stroke-width:1.2;fill:none}"
    ".hqf .band{fill:var(--accent,#4a5a2b);opacity:.08}"
    ".hqf .x{stroke:var(--amber,#a8762a);stroke-width:2.6;stroke-linecap:round;fill:none}"
    ".hqf .na{stroke:var(--d);stroke-width:2;stroke-linecap:round}</style>")
TONES = ("accent", "dim", "warn", "hollow")
MAX_BARS, MAX_UNIT_ROWS, MAX_UNITS, MAX_ROW_UNITS, MAX_EVENTS, MAX_LANES, MAX_LABEL = 12, 8, 30, 40, 12, 4, 40
MAX_GRID_ROWS, MAX_GRID_COLS = 14, 6
STATES = {"pass": "pass", "fail": "fail", "open": "not run", "na": "does not apply"}


class Spec(Exception):
    """The spec itself is wrong: a missing field, a value that is not a number."""


def tw(s, size=13):
    """Rendered width of a label, estimated. Sans at 13px averages 0.55em a character."""
    return len(str(s)) * size * 0.55


def esc(s):
    return html.escape(str(s), quote=True)


def text(x, y, s, cls="", anchor="start"):
    return '<text x="%.1f" y="%.1f" class="%s" text-anchor="%s">%s</text>' % (x, y, cls, anchor, esc(s))


def num(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise Spec("a value must be a number, got %r" % (v,))
    return v


def fmt(v):
    """A number as a report prints it: 4,163 and not 4163 (replay of 11 Nov 2026)."""
    return "{:,}".format(int(v)) if float(v).is_integer() else "{:,}".format(v)


def tone(row, default="dim"):
    t = row.get("tone", default)
    if t not in TONES:
        raise Spec("tone is one of %s, got %r" % (", ".join(TONES), t))
    return t


def wrap(w, h, body, label):
    return ('<svg class="hqf" role="img" aria-label="%s" viewBox="0 0 %d %d" style="width:%dpx;max-width:100%%;height:auto">%s%s</svg>'
            % (esc(label), w, h, w, STYLE, body))


def ticks(top):
    """Up to six round ticks from zero to at least top."""
    step = 1
    for mult in (1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000, 10000, 100000, 1000000):
        if top / mult <= 5:
            step = mult
            break
    out, v = [], 0
    while v < top + step:
        out.append(v)
        v += step
    return out


# ---- bars: how much, against what -----------------------------------------
def bars(spec, W):
    why = []
    groups = spec.get("groups") or [{"rows": spec.get("rows") or []}]
    rows = [dict(r, _tone=tone(r, tone(g))) for g in groups for r in g.get("rows", [])]
    if not rows:
        raise Spec("bars needs rows, each with a label and a value")
    for r in rows:
        v = r.get("value")
        r["_lo"], r["_hi"] = (num(v[0]), num(v[1])) if isinstance(v, list) and len(v) == 2 else (0, num(v))
        r["_range"] = isinstance(v, list)
        r["_text"] = ("%s to %s" % (fmt(r["_lo"]), fmt(r["_hi"]))) if r["_range"] else fmt(r["_hi"])
        if "label" not in r:
            raise Spec("every row needs a label")
    of, limit, cols = spec.get("of"), spec.get("limit"), spec.get("columns") or []
    if len(rows) < 2:
        why.append("one value: say it in a sentence")
    if len(rows) > MAX_BARS:
        why.append("%d rows: past %d a table reads better" % (len(rows), MAX_BARS))
    if any(r["_lo"] < 0 or r["_hi"] < r["_lo"] for r in rows):
        why.append("a value is negative or a range runs backward: bars start at zero")
    if of is not None and any(r["_hi"] > num(of) for r in rows):
        why.append("a value is larger than its whole (of %s)" % fmt(of))
    for r in rows:
        if len(str(r["label"])) > MAX_LABEL:
            why.append('label "%s..." is %d characters: shorten it to %d' % (str(r["label"])[:24], len(str(r["label"])), MAX_LABEL))
            break
    axis = bool(limit) or any(r["_range"] for r in rows)
    top = num(of) if of is not None else max([r["_hi"] for r in rows] + ([num(limit["at"])] if limit else []))
    tk = ticks(top) if axis else []
    top = max(top, tk[-1] if tk and of is None else top) or 1
    label_w = min(max(tw(r["label"]) for r in rows) + 18, W * 0.5)
    label_w = max(label_w, max([tw(g.get("label", ""), 13) + 18 for g in groups]))
    x0 = label_w + 72 * len(cols) + (18 if cols else 0)
    reserve = max(tw(r["_text"]) for r in rows) + 14
    full = W - x0 - reserve
    if full < 120:
        why.append("only %dpx is left for the bars: shorten the labels or drop a column" % max(full, 0))
        full = 120
    X = lambda v: x0 + full * v / top
    o, y = [], 0
    head = bool(cols) or bool(spec.get("value_label"))
    # The heading row sits above the limit label. Drawn the other way round, the
    # limit line ran through the heading and the fit test passed (replay, 11 Nov 2026).
    if head:
        y += 14
        for i, c in enumerate(cols):
            o.append(text(label_w + 72 * (i + 1), y, c, "m", "end"))
        if spec.get("value_label"):
            o.append(text(x0, y, spec["value_label"], "m"))
        y += 12
    limit_y = y + 16
    if limit:
        y += 30
    first = y
    for g in groups:
        if g.get("label"):
            if head or y > first:
                o.append('<line x1="0" y1="%d" x2="%d" y2="%d" class="ln"/>' % (y, W, y))
            y += 18
            o.append(text(0, y + 4, g["label"], "b"))
            y += 12
        for r0 in g.get("rows", []):
            r = next(x for x in rows if x.get("label") == r0.get("label") and x.get("value") == r0.get("value"))
            y += 14
            hot = r["_tone"] == "accent"
            o.append(text(0, y + 4.5, r["label"], "b" if hot and of is None and not axis else ""))
            for i, c in enumerate(r.get("cells", [])[:len(cols)]):
                o.append(text(label_w + 72 * (i + 1), y + 4.5, c, "n", "end"))
            tip = "<title>%s: %s</title>" % (esc(r["label"]), esc(r["_text"] + (" of " + fmt(of) if of is not None else "")))
            if of is not None:
                o.append('<rect x="%.1f" y="%d" width="%.1f" height="12" rx="3" class="track"/>' % (x0, y - 6, full))
            a, b = X(r["_lo"]), X(r["_hi"])
            if r["_range"]:
                o.append('<rect x="%.1f" y="%d" width="%.1f" height="14" rx="3" class="%s">%s</rect>' % (a, y - 7, max(b - a, 3), r["_tone"], tip))
            elif r["_hi"] == 0 and of is None:
                o.append('<circle cx="%.1f" cy="%d" r="5" class="hollow">%s</circle>' % (x0 + 6, y, tip))
                b = x0 + 12
            elif r["_hi"] > 0:
                wd = max(b - a, 5)
                if of is not None:
                    o.append('<rect x="%.1f" y="%d" width="%.1f" height="12" rx="3" class="%s">%s</rect>' % (a, y - 6, wd, r["_tone"], tip))
                else:
                    o.append('<path class="%s" d="M%.1f,%dh%.1fa4,4 0 0 1 4,4v6a4,4 0 0 1 -4,4h-%.1fz">%s</path>' % (r["_tone"], a, y - 7, wd - 4, wd - 4, tip))
            end = x0 + full if of is not None else b
            if end + 8 + tw(r["_text"]) <= W:
                o.append(text(end + 8, y + 4.5, r["_text"], "n b"))
            else:
                o.append(text(a - 8, y + 4.5, r["_text"], "n b", "end"))
            y += 14
    bottom = y + 4
    if limit:
        lx, lab = X(num(limit["at"])), limit.get("label") or fmt(limit["at"])
        half = tw(lab) / 2
        if tw(lab) > W:
            why.append("the limit label is wider than the figure: shorten it")
        o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" class="ax"/>' % (lx, limit_y + 8, lx, bottom))
        o.append(text(min(max(lx, half), W - half), limit_y, lab, "b", "middle"))
    if axis:
        o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" class="ln"/>' % (x0, bottom, X(top), bottom))
        for v in tk:
            if v <= top:
                o.append(text(X(v), bottom + 17, fmt(v), "m n", "middle"))
        bottom += 22
        if spec.get("unit"):
            o.append(text(X(top), bottom + 13, spec["unit"], "m", "end"))
            bottom += 16
    return wrap(W, bottom + 4, "".join(o), spec.get("title") or "Bars"), why, "%d rows" % len(rows)


# ---- units: how many of how many ------------------------------------------
def units(spec, W):
    why, o = [], []
    if spec.get("groups") and not spec.get("rows"):
        gs = spec["groups"]
        total = sum(num(g.get("value")) for g in gs)
        if total > MAX_ROW_UNITS:
            why.append("%d units in one row: past %d use bars" % (total, MAX_ROW_UNITS))
        if total < 2:
            why.append("one unit: say it in a sentence")
        step = min(17.6, (W - 12 - 6 * (len(gs) - 1)) / max(total, 1))
        r, x = min(6, step / 2 - 1.5), 8
        for i, g in enumerate(gs):
            n, lab = int(num(g.get("value"))), "%d %s" % (g.get("value"), g.get("label", ""))
            span = n * step + 6
            if tw(lab, 12) > (span if i < len(gs) - 1 else W - x + r):
                why.append('group label "%s" is wider than its dots: shorten it, or use bars' % lab)
            o.append('<text x="%.1f" y="46" class="m"><tspan class="b">%d</tspan> %s</text>' % (x - r, n, esc(g.get("label", ""))))
            t = tone(g)
            for _ in range(n):
                o.append('<circle cx="%.1f" cy="14" r="%.1f" class="%s"/>' % (x, r, "empty" if t == "hollow" else t))
                x += step
            x += 6
        return wrap(W, 56, "".join(o), spec.get("title") or "Units"), why, "%d units in %d groups" % (total, len(gs))
    rows = spec.get("rows") or []
    if not rows:
        raise Spec("units needs rows with a value and an of, or groups with a value")
    most = max(int(num(r.get("of", spec.get("of")))) for r in rows)
    if len(rows) > MAX_UNIT_ROWS:
        why.append("%d rows: past %d a table reads better" % (len(rows), MAX_UNIT_ROWS))
    if most > MAX_UNITS:
        why.append("%d units in a row: past %d use bars with of" % (most, MAX_UNITS))
    if len(rows) == 1 and most <= 3:
        why.append("one small count: say it in a sentence")
    count_w = max(tw("%s of %s" % (r["value"], r.get("of", spec.get("of")))) for r in rows) + 14
    step = 17.0
    dots_w = most * step
    note_w = max(tw(r.get("note", ""), 12) for r in rows)
    note_w += 16 if note_w else 0
    label_w = W - dots_w - count_w - note_w - 10
    if note_w and label_w < max(tw(r.get("label", "")) for r in rows):
        why.append("the notes do not fit beside the dots: shorten them, or keep the table and drop the figure")
        note_w, label_w = 0, W - dots_w - count_w - 10
    for r in rows:
        if num(r["value"]) > num(r.get("of", spec.get("of"))):
            why.append('"%s" counts more than its whole' % r.get("label"))
        if tw(r.get("label", "")) > label_w:
            why.append('label "%s..." does not fit beside %d dots: shorten it to about %d characters' % (str(r.get("label"))[:24], most, max(int(label_w / 7.15), 0)))
            break
    for i, r in enumerate(rows):
        y, n, of = 16 + i * 32, int(num(r["value"])), int(num(r.get("of", spec.get("of"))))
        o.append(text(0, y + 4.5, r.get("label", "")))
        t = tone(r, "accent")
        for k in range(of):
            o.append('<circle cx="%.1f" cy="%d" r="5.5" class="%s"/>' % (label_w + 6 + k * step, y, t if k < n else "empty"))
        o.append(text(W - note_w, y + 4.5, "%d of %d" % (n, of), "n b", "end"))
        if note_w and r.get("note"):
            o.append(text(W - note_w + 16, y + 4.5, r["note"], "m"))
    return wrap(W, 16 + len(rows) * 32 - 8, "".join(o), spec.get("title") or "Units"), why, "%d rows of %d" % (len(rows), most)


# ---- time: when did each thing happen -------------------------------------
def minutes(at):
    """Minutes on one line of time. HH:MM, or an ISO date or datetime."""
    s = str(at).strip()
    try:
        if len(s) <= 5 and ":" in s:
            h, m = s.split(":")
            return int(h) * 60 + int(m), s
        d = datetime.datetime.fromisoformat(s.replace("Z", ""))
        shown = d.strftime("%-d %b") if len(s) <= 10 else d.strftime("%-d %b %H:%M")
        return (d - datetime.datetime(2000, 1, 1)).total_seconds() / 60, shown
    except (ValueError, TypeError):
        raise Spec('"at" is HH:MM or an ISO date or datetime, got %r' % (at,))


def span(mins):
    mins = int(round(mins))
    d, h, m = mins // 1440, mins % 1440 // 60, mins % 60
    parts = [("%d d" % d) if d else "", ("%d h" % h) if h else "", ("%d min" % m) if m and not d else ""]
    return " ".join(p for p in parts if p) or "0 min"


def time(spec, W):
    why, o = [], []
    lanes, marks, band = spec.get("lanes") or [], spec.get("marks") or [], spec.get("band")
    events = [e for l in lanes for e in l.get("events", [])]
    if not lanes or not events:
        raise Spec("time needs lanes, each with a label and events")
    if len(events) + len(marks) < 3:
        why.append("fewer than three moments: say it in a sentence")
    if len(events) > MAX_EVENTS:
        why.append("%d events: past %d split the strip or use a table" % (len(events), MAX_EVENTS))
    if len(lanes) > MAX_LANES:
        why.append("%d lanes: past %d use a table" % (len(lanes), MAX_LANES))
    pts = sorted(set([minutes(e["at"])[0] for e in events] + [minutes(m["at"])[0] for m in marks]
                     + ([minutes(band["from"])[0], minutes(band["to"])[0]] if band else [])))
    gaps = [b - a for a, b in zip(pts, pts[1:])]
    med = statistics.median(gaps) if gaps else 0
    cut = [len(gaps) >= 3 and g > 4 * med for g in gaps]
    x0 = max(tw(l.get("label", "")) for l in lanes) + 24
    lead, tail = 60, 60
    # A cut gap is as wide as the two labels that face each other across it.
    widest = {}
    for e in events:
        k = minutes(e["at"])[0]
        widest[k] = max(widest.get(k, 0), tw(e.get("label", "")), tw(minutes(e["at"])[1], 12))
    cuts = [max(90, (widest.get(a, 0) + widest.get(b, 0)) / 2 + 24) if c else 0 for a, b, c in zip(pts, pts[1:], cut)]
    live = sum(g for g, c in zip(gaps, cut) if not c)
    room = W - x0 - lead - tail - sum(cuts)
    if room < 60 * max(sum(1 for c in cut if not c), 1) and gaps:
        why.append("only %dpx of time axis: shorten the lane labels or use fewer moments" % max(room, 0))
        room = max(room, 60)
    xs, x = {pts[0]: x0 + lead}, x0 + lead
    for b, g, c, cw in zip(pts[1:], gaps, cut, cuts):
        x += cw if c else (room * g / live if live else 0)
        xs[b] = x
    top, la = 34, 66
    bottom = la + (len(lanes) - 1) * 62 + 28
    if band:
        bx, bx2 = xs[minutes(band["from"])[0]], xs[minutes(band["to"])[0]]
        o.append('<rect x="%.1f" y="%d" width="%.1f" height="%d" class="band"/>' % (bx, top, bx2 - bx, bottom - top))
        if band.get("label"):
            if bx + 7 + tw(band["label"]) > W:
                why.append("the band label runs off the figure: shorten it")
            o.append(text(bx + 7, 24, band["label"], "b"))
    for m in marks:
        mx, shown = xs[minutes(m["at"])[0]], minutes(m["at"])[1]
        lab = ("%s %s" % (m.get("label", ""), shown)).strip()
        o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" class="ax"/>' % (mx, top, mx, bottom))
        left = mx - 7 - tw(lab, 12) >= 0
        if not left and band and abs(xs[minutes(band["from"])[0]] - mx) < 1:
            why.append("the mark label and the band label collide: shorten the lane labels")
        o.append(text(mx - 7 if left else mx + 7, 24, lab, "m", "end" if left else "start"))
    breaks = [(xs[a] + xs[b]) / 2 for a, b, c in zip(pts, pts[1:], cut) if c]
    for i, l in enumerate(lanes):
        y = la + i * 62
        o.append(text(0, y + 4.5, l.get("label", "")))
        edges = [x0] + [v for b in breaks for v in (b - 12, b + 12)] + [W]
        for a, b in zip(edges[::2], edges[1::2]):
            o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" class="ln"/>' % (a, y, b, y))
        for b in breaks:
            o.append('<path d="M%.1f,%dl6,-12M%.1f,%dl6,-12" class="ax"/>' % (b - 8, y + 6, b + 2, y + 6))
        placed = []
        for e in sorted(l.get("events", []), key=lambda e: minutes(e["at"])[0]):
            ex, shown = xs[minutes(e["at"])[0]], minutes(e["at"])[1]
            lab, half = e.get("label", ""), max(tw(e.get("label", "")), tw(shown, 12)) / 2
            cx = min(max(ex, x0 + half), W - half)
            if placed and cx - half < placed[-1] + 8:
                why.append('labels collide in lane "%s" near %s: shorten them, move one event to its own lane, or use a table' % (l.get("label", ""), shown))
            placed.append(cx + half)
            o.append('<circle cx="%.1f" cy="%d" r="6" class="%s"><title>%s, %s</title></circle>' % (ex, y, tone(e), esc(lab), esc(shown)))
            o.append(text(cx, y - 14, lab, "", "middle"))
            o.append(text(ex, y + 22, shown, "m n", "middle"))
    for (a, b, g, c), bx in zip([t for t in zip(pts, pts[1:], gaps, cut) if t[3]], breaks):
        o.append(text(bx, bottom + 18, span(g) + " later", "m", "middle"))
    return (wrap(W, bottom + (26 if breaks else 6), "".join(o), spec.get("title") or "Time strip"), why,
            "%d events in %d lanes%s" % (len(events), len(lanes), ", %d gap cut" % sum(cut) if any(cut) else ""))


# ---- grid: which passed, and where not --------------------------------------
def mark(state, cx, cy, tip=""):
    t = "<title>%s</title>" % esc(tip) if tip else ""
    if state == "pass":
        return '<circle cx="%.1f" cy="%d" r="4.5" class="dim">%s</circle>' % (cx, cy, t)
    if state == "fail":
        return '<path d="M%.1f,%dl10,10M%.1f,%dl-10,10" class="x">%s</path>' % (cx - 5, cy - 5, cx + 5, cy - 5, t)
    if state == "open":
        return '<circle cx="%.1f" cy="%d" r="5.5" class="hollow">%s</circle>' % (cx, cy, t)
    return '<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" class="na">%s</line>' % (cx - 5, cy, cx + 5, cy, t)


def grid(spec, W):
    """A check against a place, one mark a cell. Earned 12 Nov 2026: the first two
    real reports after hq-figure shipped held four tables of a check against places."""
    why, o = [], []
    cols, rows = spec.get("columns") or [], spec.get("rows") or []
    if not cols or not rows:
        raise Spec("grid needs columns, and rows that each have a label and one cell for each column")
    words = dict(STATES, **(spec.get("words") or {}))
    table = []
    for r in rows:
        if "label" not in r:
            raise Spec("every row needs a label")
        cs = r.get("cells") or []
        if len(cs) != len(cols):
            raise Spec('row "%s" has %d cells for %d columns' % (r["label"], len(cs), len(cols)))
        cs = [c if isinstance(c, dict) else {"state": c} for c in cs]
        for c in cs:
            if c.get("state") not in STATES:
                raise Spec("a cell is one of %s, got %r" % (", ".join(STATES), c.get("state")))
        table.append(cs)
    flat = [c for cs in table for c in cs]
    if len(cols) < 2:
        why.append("one column is a list: keep the table")
    elif len(flat) < 4:
        why.append("fewer than four cells: say it in a sentence")
    if len(rows) > MAX_GRID_ROWS:
        why.append("%d rows: past %d split the grid by area" % (len(rows), MAX_GRID_ROWS))
    if len(cols) > MAX_GRID_COLS:
        why.append("%d columns: past %d split the grid" % (len(cols), MAX_GRID_COLS))
    if len(set(c["state"] for c in flat)) == 1 and not any(c.get("note") for c in flat):
        why.append("every cell is %s: say that in one sentence, and list what the rows checked" % words[flat[0]["state"]])
    col_w = [max([tw(h, 12)] + [14 + tw(c["note"], 12) + 7 for cs in table for c in [cs[i]] if c.get("note")]) + 22
             for i, h in enumerate(cols)]
    label_w = W - sum(col_w)
    longest = max(rows, key=lambda r: tw(r["label"]))
    if tw(longest["label"]) > label_w - 8:
        why.append('label "%s..." does not fit beside %d columns: shorten it to about %d characters, or shorten the notes'
                   % (str(longest["label"])[:24], len(cols), max(int((label_w - 8) / 7.15), 0)))
    xs = [label_w + sum(col_w[:i]) + 6 for i in range(len(cols))]
    for x, h in zip(xs, cols):
        o.append(text(x, 13, h, "m"))
    y = 22
    for r, cs in zip(rows, table):
        o.append('<line x1="0" y1="%d" x2="%d" y2="%d" class="ln"/>' % (y, W, y))
        cy = y + 15
        o.append(text(0, cy + 4.5, r["label"], "b" if any(c["state"] in ("fail", "open") for c in cs) else ""))
        for x, h, c in zip(xs, cols, cs):
            tip = "%s, %s: %s" % (r["label"], h, " ".join(filter(None, [words[c["state"]], c.get("note")])))
            o.append(mark(c["state"], x + 6, cy, tip))
            if c.get("note"):
                o.append(text(x + 19, cy + 4, c["note"], "m"))
        y += 30
    o.append('<line x1="0" y1="%d" x2="%d" y2="%d" class="ln"/>' % (y, W, y))
    x, y = 6, y + 20
    count = [(s, sum(1 for c in flat if c["state"] == s)) for s in STATES]
    for s, n in count:
        if n:
            o.append(mark(s, x, y - 4))
            o.append('<text x="%.1f" y="%d" class="m"><tspan class="b n">%d</tspan> %s</text>' % (x + 12, y, n, esc(words[s])))
            x += 12 + tw("%d %s" % (n, words[s]), 12) + 26
    if x - 26 > W:
        why.append("the key is wider than the figure: shorten the words")
    return (wrap(W, y + 8, "".join(o), spec.get("title") or "Status grid"), why,
            "%d rows by %d columns, %s" % (len(rows), len(cols), ", ".join("%d %s" % (n, words[s]) for s, n in count if n)))


FORMS = {"bars": bars, "units": units, "time": time, "grid": grid}


def browser():
    """A Chromium to take the look picture with. HQ_FIGURE_BROWSER overrides."""
    home = os.path.expanduser("~")
    found = [os.environ.get("HQ_FIGURE_BROWSER", "")]
    found += ["/Applications/%s.app/Contents/MacOS/%s" % (n, n) for n in ("Google Chrome", "Chromium", "Microsoft Edge", "Brave Browser")]
    found += sorted(glob.glob(home + "/Library/Caches/ms-playwright/chromium_headless_shell-*/*/*headless*shell*"), reverse=True)
    found += sorted(glob.glob(home + "/Library/Caches/ms-playwright/chromium-*/*/Chromium.app/Contents/MacOS/Chromium"), reverse=True)
    return next((p for p in found if p and os.path.isfile(p) and os.access(p, os.X_OK)), None)


def look(svg, png, W):
    exe = browser()
    if not exe:
        sys.stderr.write("no browser for --png: open the page and look at the figure there\n")
        return False
    h = int(float(svg.split('viewBox="0 0 ')[1].split('"')[0].split()[1]))
    with tempfile.TemporaryDirectory() as tmp:
        page = os.path.join(tmp, "look.html")
        with open(page, "w") as f:
            f.write('<body style="margin:16px;background:#fcfbf8;width:%dpx">%s</body>' % (W, svg))
        subprocess.run([exe, "--headless", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2",
                        "--window-size=%d,%d" % (W + 32, h + 32), "--screenshot=" + os.path.abspath(png), "file://" + page],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    if not os.path.isfile(png):
        sys.stderr.write("the browser wrote no picture: open the page and look at the figure there\n")
        return False
    sys.stderr.write("look at %s before it ships (the page wears its brand colour; never name a colour in the caption)\n" % png)
    return True


def draw(spec, W=720):
    form = spec.get("form")
    if form not in FORMS:
        raise Spec('"form" is one of %s' % ", ".join(sorted(FORMS)))
    return FORMS[form](spec, W)


def main(argv):
    args = list(argv)
    if not args and sys.stdin.isatty() or args[:1] in (["-h"], ["--help"]):
        sys.stdout.write(__doc__)
        return 0
    png = W = None
    for flag in ("--png", "--width"):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                sys.stderr.write("%s needs a value\n" % flag)
                return 64
            value = args[i + 1]
            del args[i:i + 2]
            if flag == "--png":
                png = value
            else:
                W = int(value)
    try:
        spec = json.load(open(args[0]) if args else sys.stdin)
        svg, why, what = draw(spec, W or 720)
    except (Spec, json.JSONDecodeError, OSError, KeyError, TypeError) as e:
        sys.stderr.write("hq-figure: %s\n" % (("missing field %s" % e) if isinstance(e, KeyError) else e))
        return 64
    sys.stdout.write(svg + "\n")
    if why:
        sys.stderr.write("DO NOT SHIP AS DRAWN: %s\n" % "; ".join(why))
    else:
        sys.stderr.write("fit test passes: %s, %s. It replaces the table or paragraph it restates.\n" % (spec["form"], what))
    if png:
        look(svg, png, W or 720)
    return 2 if why else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
