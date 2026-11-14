"""hq-figure: every fit rule is asserted on both sides, and the four report
claims that were redrawn on 11 Nov 2026 are the fixtures that must pass."""
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "skills/share-as-page/scripts/hq-figure.py"
spec = importlib.util.spec_from_file_location("hqfigure", SCRIPT)
fig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fig)

TASKS = {"form": "time", "lanes": [
    {"label": "Cash App tasks", "events": [{"at": "04:19", "label": "Port, 0 calls", "tone": "hollow"},
                                           {"at": "04:28", "label": "Build round, 0 calls", "tone": "hollow"}]},
    {"label": "Check tasks", "events": [{"at": "04:32", "label": "Coframe, 4 calls", "tone": "accent"},
                                        {"at": "19:07", "label": "Cofresso, 4 calls", "tone": "accent"}]}],
    "marks": [{"at": "04:15", "label": "Merge"}],
    "band": {"from": "04:15", "to": "04:32", "label": "17 minutes with no proven read"}}
FEEDS = {"form": "bars", "of": 10, "columns": ["Topics", "Products"], "value_label": "Highlights returned, of 10", "groups": [
    {"label": "No products chosen", "rows": [{"label": "BlankShirts", "value": 10, "cells": [0, 0]},
                                             {"label": "Apparel.com", "value": 10, "cells": [37, 0]}]},
    {"label": "Products chosen", "tone": "accent", "rows": [{"label": "BlankCaps", "value": 2, "cells": [34, 10]},
                                                            {"label": "BlankApparel", "value": 0, "cells": [40, 10]},
                                                            {"label": "BlankAthletics", "value": 0, "cells": [32, 7]},
                                                            {"label": "T-ShirtWholesaler", "value": 0, "cells": [37, 10]}]}]}
REVENUE = {"form": "bars", "unit": "cents per send", "limit": {"at": 20, "label": "Pass line: 20 cents for two weeks"},
           "rows": [{"label": "Today", "value": [3, 4], "tone": "accent"}, {"label": "Old flow, August", "value": [31, 43]}]}
DRAFTS = {"form": "units", "of": 12, "rows": [{"label": "Hero button is orange, not gold", "value": 12},
                                               {"label": "Hero woman is not M2", "value": 9},
                                               {"label": "Grid shows the old Summer Sale image", "value": 5},
                                               {"label": "Hero is a light product shot", "value": 3}]}


# The first real report after the forms shipped, 11 Nov 2026 (La Belle, "The combined copy passes"):
# eight areas against two sizes and the overlay, 22 passes and the two cells nobody ran.
CHECKS = {"form": "grid", "columns": ["Desktop 1440", "Phone 390", "Overlay on"], "rows": [
    {"label": "Home: hero, tiles and quiz", "cells": ["pass", "pass", {"state": "pass", "note": "desktop"}]},
    {"label": "Navigation: brands tile, scent menu, phone menu", "cells": ["pass", "pass", {"state": "pass", "note": "phone"}]},
    {"label": "Product page: one add for each click", "cells": ["pass", "pass", {"state": "pass", "note": "phone"}]},
    {"label": "Sold-out product: button is disabled", "cells": [{"state": "open", "note": "single build only"}, "pass", "open"]},
    {"label": "Cart drawer: Seel line off and on", "cells": ["pass", "pass", {"state": "pass", "note": "desktop"}]},
    {"label": "Cart page: summary card, total $81.68", "cells": ["pass", "pass", {"state": "pass", "note": "desktop"}]},
    {"label": "Checkout: same total, $81.68", "cells": ["pass", "pass", "pass"]},
    {"label": "No page errors beyond live", "cells": ["pass", "pass", "pass"]}]}


def grid(states, cols=2, **more):
    return dict({"form": "grid", "columns": ["Place %d" % i for i in range(cols)],
                 "rows": [{"label": "Check %d" % i, "cells": [s] * cols} for i, s in enumerate(states)]}, **more)


def bars(n, **more):
    return dict({"form": "bars", "rows": [{"label": "Row %d" % i, "value": i + 1} for i in range(n)]}, **more)


class RealClaims(unittest.TestCase):
    def test_the_four_redrawn_claims_pass_at_the_width_they_were_drawn(self):
        for name, s, w in (("tasks", TASKS, 720), ("feeds", FEEDS, 560), ("revenue", REVENUE, 560), ("drafts", DRAFTS, 560)):
            svg, why, _ = fig.draw(s, w)
            self.assertEqual(why, [], name)
            self.assertTrue(svg.startswith('<svg class="hqf"') and svg.endswith("</svg>"), name)

    def test_every_number_and_label_in_the_rows_is_in_the_drawing(self):
        svg = fig.draw(FEEDS, 560)[0]
        for wanted in ("BlankShirts", "T-ShirtWholesaler", ">37<", ">34<", ">7<", "Highlights returned, of 10"):
            self.assertIn(wanted, svg)
        svg = fig.draw(DRAFTS, 560)[0]
        for wanted in ("12 of 12", "9 of 12", "5 of 12", "3 of 12"):
            self.assertIn(wanted, svg)
        self.assertEqual(svg.count('class="accent"'), 12 + 9 + 5 + 3)
        self.assertEqual(svg.count('class="empty"'), 0 + 3 + 7 + 9)


class Geometry(unittest.TestCase):
    def test_bar_lengths_are_proportional_to_their_values(self):
        svg = fig.draw({"form": "bars", "rows": [{"label": "A", "value": 200}, {"label": "B", "value": 50}]})[0]
        long, short = [float(w) + 4 for w in re.findall(r'd="M[\d.]+,\d+h([\d.]+)a4', svg)]
        self.assertAlmostEqual(long / short, 4.0, places=1)

    def test_a_bar_on_a_whole_fills_its_share_of_the_track(self):
        svg = fig.draw(FEEDS, 560)[0]
        track = float(re.search(r'width="([\d.]+)" height="12" rx="3" class="track"', svg).group(1))
        two = float(re.search(r'width="([\d.]+)" height="12" rx="3" class="accent"', svg).group(1))
        self.assertAlmostEqual(two / track, 0.2, places=2)

    def test_the_limit_sits_between_the_two_ranges_it_separates(self):
        svg = fig.draw(REVENUE, 560)[0]
        limit = float(re.search(r'<line x1="([\d.]+)"[^>]*class="ax"', svg).group(1))
        starts = [float(x) for x in re.findall(r'<rect x="([\d.]+)"[^>]*height="14"', svg)]
        self.assertLess(starts[0], limit)
        self.assertGreater(starts[1], limit)

    def test_a_heading_and_a_limit_never_share_a_line(self):
        # Replay of 11 Nov 2026: the limit line ran through the bar heading and the fit test passed.
        svg = fig.draw(dict(REVENUE, value_label="Revenue per send, never-bought path"), 560)[0]
        heading_y = float(re.search(r'y="([\d.]+)" class="m" text-anchor="start">Revenue per send', svg).group(1))
        label_y = float(re.search(r'y="([\d.]+)" class="b" text-anchor="middle">Pass line', svg).group(1))
        line_top = float(re.search(r'<line x1="[\d.]+" y1="(\d+)"[^>]*class="ax"', svg).group(1))
        self.assertLess(heading_y, label_y - 10)
        self.assertGreater(line_top, label_y)

    def test_two_rows_with_one_label_and_one_value_keep_their_own_cells(self):
        # Replay of 12 Nov 2026: the second row was drawn with the first row's cells, and the fit test passed.
        runs = {"form": "bars", "columns": ["Hero shown"], "groups": [
            {"label": "Run 3", "rows": [{"label": "Copy", "value": 11.8, "cells": ["not recorded"]}, {"label": "Live", "value": 6.4, "cells": [""]}]},
            {"label": "Run 4", "rows": [{"label": "Copy", "value": 11.8, "cells": ["0.7 s"]}, {"label": "Live", "value": 13.2, "cells": [""]}]}]}
        svg = fig.draw(runs, 720)[0]
        self.assertEqual(svg.count(">not recorded<"), 1)
        self.assertEqual(svg.count(">0.7 s<"), 1)
        self.assertLess(svg.index(">not recorded<"), svg.index(">0.7 s<"))

    def test_a_unit_is_drawn_with_or_without_an_axis_and_a_value_prints_as_written(self):
        svg = fig.draw({"form": "bars", "unit": "seconds to largest paint", "rows": [
            {"label": "Copy", "value": 18.0, "text": "18.0 s"}, {"label": "Live", "value": 6.9}]}, 720)[0]
        self.assertIn(">seconds to largest paint<", svg)
        self.assertIn(">18.0 s<", svg)
        self.assertIn(">6.9<", svg)

    def test_large_numbers_print_with_commas(self):
        svg = fig.draw({"form": "bars", "rows": [{"label": "Week of Sep 7", "value": 4163}, {"label": "Week of Oct 5", "value": 2757}]})[0]
        self.assertIn(">4,163<", svg)
        self.assertNotIn(">4163<", svg)
        self.assertIn(">43<", fig.draw({"form": "bars", "rows": [{"label": "A", "value": 43}, {"label": "B", "value": 2.5}]})[0])

    def test_a_unit_row_carries_a_short_note_and_refuses_a_long_one(self):
        rows = lambda note: {"form": "units", "rows": [{"label": "STLTH pods", "value": 3, "of": 4, "note": note},
                                                       {"label": "Sunday stock-up", "value": 6, "of": 6}]}
        svg, why, _ = fig.draw(rows("Honeydew Menthol missing"))
        self.assertEqual(why, [])
        self.assertIn("Honeydew Menthol missing", svg)
        count_x = float(re.search(r'x="([\d.]+)" y="[\d.]+" class="n b" text-anchor="end">3 of 4', svg).group(1))
        note_x = float(re.search(r'x="([\d.]+)" y="[\d.]+" class="m" text-anchor="start">Honeydew', svg).group(1))
        self.assertGreater(note_x, count_x)
        long = "Lemon Drop Freebase Blue Raspberry 100ml, Lemon Drop Salt Nic Peach 60ml, and two more products"
        self.assertIn("keep the table", " ".join(fig.draw(rows(long))[1]))

    def test_time_runs_left_to_right_and_the_long_gap_is_cut_and_named(self):
        svg = fig.draw(TASKS)[0]
        xs = [float(x) for x in re.findall(r'<circle cx="([\d.]+)"', svg)]
        self.assertEqual(xs, sorted(xs))
        self.assertIn("14 h 35 min later", svg)
        self.assertLess(xs[3] - xs[2], xs[1] - xs[0])  # 14 hours drawn shorter than 9 minutes

    def test_even_gaps_are_not_cut(self):
        s = {"form": "time", "lanes": [{"label": "Sends", "events": [{"at": "2026-11-0%d" % d, "label": "S%d" % d} for d in (1, 3, 5, 7)]}]}
        svg, why, what = fig.draw(s)
        self.assertEqual(why, [])
        self.assertNotIn("later", svg)
        self.assertNotIn("cut", what)


class Grid(unittest.TestCase):
    def test_the_real_check_table_passes_and_every_cell_has_its_mark(self):
        svg, why, what = fig.draw(CHECKS, 720)
        self.assertEqual(why, [])
        self.assertEqual(what, "8 rows by 3 columns, 22 pass, 2 not run")
        # one mark a cell, and one more for each state in the key
        self.assertEqual(svg.count('class="ok"'), 22 + 1)
        self.assertEqual(svg.count('class="unrun"'), 2 + 1)
        for wanted in ("Sold-out product: button is disabled", "single build only", "Overlay on", ">22</tspan> pass", ">2</tspan> not run"):
            self.assertIn(wanted, svg)

    def test_each_state_has_its_own_shape_so_colour_is_not_the_only_sign(self):
        svg = fig.draw(grid(["pass", "fail", "open", "na"]), 720)[0]
        self.assertEqual([svg.count('class="%s"' % c) for c in ("ok", "x", "unrun", "na")], [3, 3, 3, 3])

    def test_a_pass_is_a_green_check_and_never_a_grey_dot_or_the_brand_accent(self):
        # Ruled 12 Nov 2026 on the first published grid: grey read as nothing there.
        svg = fig.draw(grid(["pass", "fail"]), 720)[0]
        self.assertIn(".hqf .ok{stroke:var(--ok)", svg)
        self.assertIn("--ok:#2a7a4b", svg)
        self.assertIn(".hqf .x{stroke:var(--bad)", svg)
        self.assertNotIn('class="dim"', svg)

    def test_marks_in_a_column_share_one_x(self):
        svg = fig.draw(grid(["pass", "open", "pass"]), 720)[0]
        xs = re.findall(r'<path d="M([\d.]+),([\d.]+)l3.6', svg)[:4]
        self.assertEqual(len(xs), 4)
        self.assertEqual(len(set(x for x, _ in xs)), 2)
        self.assertEqual(len(set(y for _, y in xs)), 2)

    def test_all_the_same_is_a_sentence_and_one_exception_is_a_grid(self):
        self.assertIn("every cell is pass", " ".join(fig.draw(grid(["pass"] * 4), 720)[1]))
        self.assertEqual(fig.draw(grid(["pass", "pass", "pass", "open"]), 720)[1], [])

    def test_one_column_is_a_list_and_two_are_a_grid(self):
        self.assertIn("one column is a list", " ".join(fig.draw(grid(["pass", "fail", "open"], cols=1), 720)[1]))
        self.assertEqual(fig.draw(grid(["pass", "fail", "open"], cols=2), 720)[1], [])

    def test_fourteen_rows_pass_and_fifteen_are_split(self):
        self.assertEqual(fig.draw(grid(["pass"] * 13 + ["fail"]), 720)[1], [])
        self.assertIn("15 rows", " ".join(fig.draw(grid(["pass"] * 14 + ["fail"]), 720)[1]))

    def test_a_label_that_does_not_fit_beside_the_columns_is_refused(self):
        long = grid(["pass", "open"])
        long["rows"][0]["label"] = "Uncheck removes the Seel line, and the total goes from $40.98 to $40.00, in one request each way"
        self.assertIn("does not fit beside 2 columns", " ".join(fig.draw(long, 720)[1]))
        long["rows"][0]["label"] = "Uncheck removes the Seel line: $40.98 to $40.00"
        self.assertEqual(fig.draw(long, 720)[1], [])

    def test_a_cell_count_or_state_that_is_wrong_is_an_error(self):
        bad = grid(["pass", "open"])
        bad["rows"][0]["cells"] = ["pass"]
        self.assertRaises(fig.Spec, fig.draw, bad, 720)
        self.assertRaises(fig.Spec, fig.draw, grid(["pass", "maybe"]), 720)


class FitTest(unittest.TestCase):
    def reasons(self, s, w=720):
        return " ".join(fig.draw(s, w)[1])

    def test_one_value_is_a_sentence_and_two_are_a_figure(self):
        self.assertIn("sentence", self.reasons(bars(1)))
        self.assertEqual(self.reasons(bars(2)), "")

    def test_twelve_bars_pass_and_thirteen_are_a_table(self):
        self.assertEqual(self.reasons(bars(12)), "")
        self.assertIn("table", self.reasons(bars(13)))

    def test_a_value_over_its_whole_is_refused_and_one_equal_to_it_is_not(self):
        self.assertIn("larger than its whole", self.reasons(bars(3, of=2)))
        self.assertEqual(self.reasons(bars(3, of=3)), "")

    def test_a_long_label_is_refused_and_a_forty_character_one_is_not(self):
        row = lambda n: {"form": "bars", "rows": [{"label": "x" * n, "value": 1}, {"label": "B", "value": 2}]}
        self.assertEqual(self.reasons(row(40)), "")
        self.assertIn("shorten", self.reasons(row(41)))

    def test_units_past_thirty_in_a_row_go_to_bars(self):
        unit = lambda of: {"form": "units", "of": of, "rows": [{"label": "A", "value": 3}, {"label": "B", "value": 2}]}
        self.assertEqual(self.reasons(unit(30)), "")
        self.assertIn("use bars", self.reasons(unit(31)))

    def test_a_unit_label_that_does_not_fit_beside_its_dots_is_refused(self):
        s = dict(DRAFTS, rows=[dict(DRAFTS["rows"][0], label="The hero button is orange, and the prompt asked for gold.")] + DRAFTS["rows"][1:])
        self.assertIn("does not fit", self.reasons(s, 560))
        self.assertEqual(self.reasons(DRAFTS, 560), "")

    def test_colliding_time_labels_are_refused_and_named(self):
        s = {"form": "time", "lanes": [{"label": "Tasks", "events": [
            {"at": "04:19", "label": "Port of the referral page test"}, {"at": "04:20", "label": "Build round for the same test"},
            {"at": "04:50", "label": "Check"}]}]}
        self.assertIn('labels collide in lane "Tasks"', self.reasons(s))
        self.assertEqual(self.reasons(TASKS), "")

    def test_two_moments_are_a_sentence(self):
        s = {"form": "time", "lanes": [{"label": "Sends", "events": [{"at": "04:00", "label": "A"}, {"at": "05:00", "label": "B"}]}]}
        self.assertIn("sentence", self.reasons(s))

    def test_a_wrong_spec_is_an_error_not_a_drawing(self):
        for bad in ({"form": "pie"}, {"form": "bars", "rows": [{"label": "A", "value": "many"}, {"label": "B", "value": 1}]},
                    {"form": "bars", "rows": [{"label": "A", "value": 1, "tone": "red"}, {"label": "B", "value": 1}]},
                    {"form": "time", "lanes": [{"label": "L", "events": [{"at": "yesterday", "label": "A"}]}]}):
            with self.assertRaises(fig.Spec):
                fig.draw(bad)

    def test_text_from_the_rows_is_escaped(self):
        svg = fig.draw({"form": "bars", "rows": [{"label": "<b>A & B</b>", "value": 1}, {"label": "C", "value": 2}]})[0]
        self.assertIn("&lt;b&gt;A &amp; B&lt;/b&gt;", svg)
        self.assertNotIn("<b>", svg)


class CommandLine(unittest.TestCase):
    def run_cli(self, text, *args, env=None):
        return subprocess.run([sys.executable, str(SCRIPT), *args], input=text, capture_output=True, text=True, env=env)

    def test_exit_codes_say_pass_refuse_and_error(self):
        import json
        ok = self.run_cli(json.dumps(DRAFTS), "--width", "560")
        self.assertEqual(ok.returncode, 0)
        self.assertIn("fit test passes", ok.stderr)
        self.assertTrue(ok.stdout.startswith("<svg"))
        refused = self.run_cli(json.dumps(bars(1)))
        self.assertEqual(refused.returncode, 2)
        self.assertIn("DO NOT SHIP AS DRAWN", refused.stderr)
        self.assertEqual(self.run_cli("{not json").returncode, 64)
        self.assertEqual(self.run_cli('{"form": "pie"}').returncode, 64)

    def test_no_browser_still_draws_and_says_so(self):
        import json
        with tempfile.TemporaryDirectory() as home:
            real = fig.browser
            try:
                fig.browser = lambda: None
                self.assertFalse(fig.look("<svg viewBox=\"0 0 10 10\"></svg>", os.path.join(home, "look.png"), 720))
            finally:
                fig.browser = real

    def test_the_shim_runs_the_script(self):
        import json
        out = subprocess.run([str(ROOT / "skills/bin/hq-figure")], input=json.dumps(DRAFTS), capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("<svg", out.stdout)


if __name__ == "__main__":
    unittest.main()
