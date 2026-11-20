"""figlib: explanatory figures as inline SVG, in one grammar.

Rules it encodes (chapter.md, Figures): a boundary is an enclosing region with no arrow; layers are stacked rows;
an arrow means something moves or causes, labelled with what crosses it, at most two arrow styles; every box carries
a type and a role; one accent for the thing being taught, one warn tone for the attacker or the break; text in the
figure is 14px or more and never wears the data colour; the smallest effective difference.
"""
import html

INK = "var(--ink)"; MUTED = "var(--muted)"; LINE = "var(--line)"; PAPER = "var(--paper)"; BG = "var(--bg)"
ACC = "var(--accent)"; WARN = "var(--amber)"; RED = "var(--red)"
FONT = "font-family:var(--sans)"

class Fig:
    def __init__(self, w, h, label, scale=1.0):
        self.w, self.h, self.label = w, h, label
        self.parts = []
        self.defs = set()
    def arrowdef(self, color_id, color):
        key = f"ah-{color_id}"
        self.defs.add(f'<marker id="{key}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>')
        return key
    def region(self, x, y, w, h, title=None, tone=None, dashed=False, fill=None, r=10):
        stroke = {None: LINE, "accent": ACC, "warn": WARN, "red": RED}[tone]
        sw = 1 if tone is None else 1.5
        dash = ' stroke-dasharray="6 5"' if dashed else ""
        f = fill or "none"
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{f}" stroke="{stroke}" stroke-width="{sw}"{dash}/>')
        if title:
            self.text(x + 12, y + 20, title, size=13, color=MUTED if tone is None else stroke, weight=600, tracking=True)
    def box(self, x, y, w, h, kind, role=None, tone=None, align="middle"):
        fill = {None: PAPER, "accent": ACC, "warn": WARN, "red": RED, "ink": INK}[tone]
        tcol = INK if tone is None else BG
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fill}"/>')
        cx = x + w / 2 if align == "middle" else x + 12
        anchor = "middle" if align == "middle" else "start"
        if role:
            self.text(cx, y + h / 2 - 3, kind, size=14, weight=600, color=tcol, anchor=anchor)
            self.text(cx, y + h / 2 + 15, role, size=13, color=tcol, anchor=anchor, opacity=0.85)
        else:
            self.text(cx, y + h / 2 + 5, kind, size=14, weight=600, color=tcol, anchor=anchor)
    def text(self, x, y, s, size=14, weight=400, color=INK, anchor="start", italic=False, tracking=False, opacity=1):
        style = f'{FONT};font-size:{size}px;font-weight:{weight};' + ("font-style:italic;" if italic else "") + ("letter-spacing:.06em;text-transform:uppercase;" if tracking else "")
        self.parts.append(f'<text x="{x}" y="{y}" text-anchor="{anchor}" fill="{color}" opacity="{opacity}" style="{style}">{html.escape(s)}</text>')
    def arrow(self, pts, label=None, tone=None, dashed=False, lpos=0.5, loff=(0, -8), both=False):
        color = {None: INK, "ink": INK, "accent": ACC, "warn": WARN, "red": RED, "muted": MUTED}[tone]
        key = self.arrowdef(tone or "ink", color)
        d = "M" + " L".join(f"{x},{y}" for x, y in pts)
        dash = ' stroke-dasharray="5 4"' if dashed else ""
        start = f' marker-start="url(#{key})"' if both else ""
        self.parts.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="1.6"{dash} marker-end="url(#{key})"{start}/>')
        if label:
            # label at a fraction along the first segment pair
            (x1, y1), (x2, y2) = pts[0], pts[-1]
            lx, ly = x1 + (x2 - x1) * lpos + loff[0], y1 + (y2 - y1) * lpos + loff[1]
            self.text(lx, ly, label, size=13, color=MUTED, anchor="middle")
    def line(self, pts, tone=None, dashed=False, width=1.2):
        color = {None: LINE, "ink": INK, "accent": ACC, "warn": WARN, "muted": MUTED}[tone]
        d = "M" + " L".join(f"{x},{y}" for x, y in pts)
        dash = ' stroke-dasharray="5 4"' if dashed else ""
        self.parts.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{dash}/>')
    def dot(self, x, y, r=5, tone="accent"):
        color = {None: INK, "accent": ACC, "warn": WARN, "red": RED}[tone]
        self.parts.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{color}" stroke="{BG}" stroke-width="2"/>')
    def key(self, x, y, items):
        """items: list of (kind, label) where kind in box-tone names or 'arrow','dashed','region'"""
        cx = x
        for kind, label in items:
            if kind in ("arrow", "dashed"):
                self.line([(cx, y), (cx + 26, y)], tone="ink", dashed=(kind == "dashed"), width=1.6)
            elif kind == "region":
                self.parts.append(f'<rect x="{cx}" y="{y-7}" width="26" height="14" rx="3" fill="none" stroke="{LINE}"/>')
            else:
                fill = {"paper": PAPER, "accent": ACC, "warn": WARN, "red": RED}[kind]
                self.parts.append(f'<rect x="{cx}" y="{y-7}" width="26" height="14" rx="3" fill="{fill}"/>')
            self.text(cx + 32, y + 5, label, size=13, color=MUTED)
            cx += 32 + 8 * len(label) + 28
    def svg(self):
        defs = f"<defs>{''.join(sorted(self.defs))}</defs>" if self.defs else ""
        return (f'<svg viewBox="0 0 {self.w} {self.h}" role="img" aria-label="{html.escape(self.label, quote=True)}" '
                f'style="width:100%;max-width:{self.w}px;height:auto;display:block">{defs}{"".join(self.parts)}</svg>')
