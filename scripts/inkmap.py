#!/usr/bin/env python3
"""
Measure the panel's spacing in PAINT, not in frames.

Why this exists: every layout assertion this repo has ever written measures
boxes — a frame, a constraint constant, a stack's spacing — and the eye does not
see boxes. It sees ink. The two are NOT the same number here, on purpose: the
gear is a 14pt glyph in a 26pt hit target, the back chevron is 9pt in 26, the
Controls word is a ~10pt cap-height in a 20pt hover box. Every one of those
paddings is deliberate and invisible, and wherever such a control lands first or
last against an edge, its padding becomes MARGIN that nobody chose.

So this reads the pixels. `scripts/faces.sh` renders each face from the view
hierarchy (no screen-recording grant, no awake display); this turns those PNGs
into a map of where paint actually starts and stops.

    scripts/faces.sh /tmp/tb-faces
    scripts/inkmap.py /tmp/tb-faces/berkeley

What it prints, per face: every horizontal band of paint, its height, its left
and right ink edges, and the gap above it — then the four painted margins. Then
a summary across faces that groups each margin by value, because the finding is
never one number, it is two faces disagreeing about the same edge.

Coordinates are POINTS. The shots are retina, so pixels are halved; a reading of
`10.5` means ten and a half points of real estate, and half-point values are
normal for antialiased type.
"""
import os
import sys
from collections import Counter, defaultdict

try:
    from PIL import Image
except ImportError:                                   # pragma: no cover
    sys.exit("needs Pillow:  python3 -m pip install --user Pillow")

# A pixel counts as paint when it differs from the surface by more than this on
# any channel. 10 is comfortably above the panel's antialiasing floor and well
# below `faint`, the dimmest thing the palette ever draws.
THRESHOLD = 10
SCALE = 2               # retina pixels per point
# Skip past the 8pt corner radius so the housing's own rounded edge — which is
# not content and is present on every face — is never read as paint.
EDGE_INSET_PX = 24


def bands(path):
    """Every horizontal run of paint in one face, in points."""
    image = Image.open(path).convert("RGB")
    width, height = image.size
    pixel = image.load()

    interior = Counter(pixel[x, y]
                       for y in range(height // 4, 3 * height // 4)
                       for x in range(4, width - 4, 3))
    surface = interior.most_common(1)[0][0]

    def painted(p):
        return max(abs(p[i] - surface[i]) for i in range(3)) > THRESHOLD

    left, right = EDGE_INSET_PX, width - EDGE_INSET_PX
    inked_columns = [[x for x in range(left, right) if painted(pixel[x, y])]
                     for y in range(height)]

    out, y = [], 0
    while y < height:
        if not inked_columns[y]:
            y += 1
            continue
        top = y
        while y < height and inked_columns[y]:
            y += 1
        xs = [x for row in inked_columns[top:y] for x in row]
        out.append({"top": top / SCALE, "bottom": (y - 1) / SCALE,
                    "height": (y - top) / SCALE,
                    "left": min(xs) / SCALE, "right": max(xs) / SCALE})
    return surface, width / SCALE, height / SCALE, out


# A face whose paint reaches its own bottom edge is not a face with no margin —
# it is almost certainly a face photographed before the panel finished growing
# to fit its content. Earned 20 Aug: the first run of this script reported
# `settings` with a painted bottom margin of 0.0 and it was written up as a
# defect, when the pose had simply caught the panel mid-resize with its last row
# cut in half. The instrument now says so itself, because the audit's own method
# section warns about exactly this transient and the audit walked into it anyway.
CLIPPED_BELOW = 6.0


def margins(width, height, found):
    if not found:
        return None
    return {"top": found[0]["top"],
            "bottom": height - 1 / SCALE - found[-1]["bottom"],
            "left": min(b["left"] for b in found),
            "right": width - 1 / SCALE - max(b["right"] for b in found)}


def main(directory):
    shots = sorted(f for f in os.listdir(directory) if f.endswith(".png"))
    if not shots:
        sys.exit(f"no PNGs in {directory} — run scripts/faces.sh first")

    edges = defaultdict(lambda: defaultdict(list))
    clipped = []
    for shot in shots:
        face = shot[:-4]
        surface, width, height, found = bands(os.path.join(directory, shot))
        print(f"### {face}   {width:.0f}x{height:.0f}pt   "
              f"surface #{surface[0]:02X}{surface[1]:02X}{surface[2]:02X}")
        previous = None
        for i, b in enumerate(found):
            gap = "" if previous is None else f"   gap above {b['top'] - previous:5.1f}"
            print(f"   band {i:2d}  y {b['top']:6.1f}..{b['bottom']:6.1f}"
                  f"  h {b['height']:5.1f}"
                  f"  x {b['left']:6.1f}..{b['right']:6.1f}{gap}")
            previous = b["bottom"] + 1 / SCALE
        m = margins(width, height, found)
        if m:
            print("   painted margins  " + "  ".join(
                f"{k} {v:.1f}" for k, v in m.items()))
            if m["bottom"] < CLIPPED_BELOW:
                print(f"   ⚠ CLIPPED — bottom margin {m['bottom']:.1f}pt. The pose was very "
                      "likely caught mid-resize; this face's bottom is not a measurement. "
                      "Re-shoot before reading anything into it.")
                clipped.append(face)
            for edge, value in m.items():
                # A clipped face's BOTTOM is not a fact. Its other three edges
                # still are — the panel grows downward.
                if edge == "bottom" and m["bottom"] < CLIPPED_BELOW:
                    continue
                edges[edge][value].append(face)
        print()

    print("=" * 72)
    print("SUMMARY — each painted margin, grouped by the value it takes")
    print("A single value per edge is the goal. Two is a finding.")
    print("=" * 72)
    if clipped:
        print(f"\nEXCLUDED as clipped: {', '.join(clipped)} — bottom not measured.")
    for edge in ("top", "right", "bottom", "left"):
        print(f"\n{edge.upper()}")
        for value in sorted(edges[edge]):
            faces = ", ".join(sorted(edges[edge][value]))
            print(f"  {value:6.1f}pt  ({len(edges[edge][value]):2d})  {faces}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/tb-faces/berkeley")
