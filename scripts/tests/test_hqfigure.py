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
