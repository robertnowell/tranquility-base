import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("hqpage", ROOT / "skills/research-hq/scripts/hqpage.py")
hqpage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hqpage)


class PagePublicationTests(unittest.TestCase):
    def test_disclosures_stop_before_move_or_open_and_keep_live_page(self):
        for markup in ['<details><summary>Claim</summary>Evidence</details>',
                       '<DETAILS open class="claim">Evidence</DETAILS>']:
            with tempfile.TemporaryDirectory() as root:
                hub = Path(root) / "session"
                draft = hub / "_drafts" / "report.html"
                draft.parent.mkdir(parents=True)
                draft.write_text(markup)
                live = hub / "report.html"
                live.write_text("previous publication")
                with patch.object(hqpage, "agents_root", return_value=Path(root)), patch.object(hqpage.subprocess, "run") as opened:
                    self.assertEqual(hqpage.publish("session", "report"), 1)
                    opened.assert_not_called()
                self.assertEqual(draft.read_text(), markup)
                self.assertEqual(live.read_text(), "previous publication")

    def test_sections_and_escaped_code_examples_publish(self):
        with tempfile.TemporaryDirectory() as root:
            draft = Path(root) / "session/_drafts/report.html"
            draft.parent.mkdir(parents=True)
            markup = '<section class="claim"><pre>&lt;details&gt;</pre></section><!-- <details> -->'
            draft.write_text(markup)
            with patch.object(hqpage, "agents_root", return_value=Path(root)), \
                 patch.object(hqpage, "rules_dir", return_value=Path(root) / "rules"), \
                 patch.object(hqpage.subprocess, "run") as opened:
                self.assertEqual(hqpage.publish("session", "report"), 0)
                opened.assert_called_once()
            self.assertFalse(draft.exists())
            self.assertTrue((draft.parent.parent / "report.html").read_text().endswith(markup))

    def test_timeline_words_do_not_trigger_diagram_warning(self):
        source = (ROOT / "hooks/artifact-hook.sh").read_text()
        start = source.index('_DRAWN = ')
        stop = source.index('\n    return flags', start) + len('\n    return flags')
        import re
        namespace = {"re": re}
        exec(source[start:stop], namespace)
        page = '<section class="claim" data-shows="text"><span class="c">Before launch, then after launch.</span><ol><li>Before</li><li>After</li></ol></section>'
        self.assertEqual(namespace['_evidence_flags'](page), [])

    def flags(self, shows, inner):
        import re
        source = (ROOT / "hooks/artifact-hook.sh").read_text()
        start = source.index('_DRAWN = ')
        stop = source.index('\n    return flags', start) + len('\n    return flags')
        namespace = {"re": re}
        exec(source[start:stop], namespace)
        return namespace['_evidence_flags']('<section class="claim" data-shows="%s"><span class="c">A claim.</span>%s</section>' % (shows, inner))

    def test_a_size_an_order_or_a_share_without_a_figure_is_named_and_with_one_is_not(self):
        for shows in ("ranking", "timeline", "share", "status"):
            self.assertEqual(self.flags(shows, "<table><tr><td>1</td></tr></table>"),
                             ['"A claim." shows %s but carries no figure (hq-figure)' % shows])
            self.assertEqual(self.flags(shows, "<svg></svg>"), [])

    def test_shares_as_text_in_a_table_are_named_and_two_are_not(self):
        table = lambda n: "<table><tr><th>Problem</th><th>Drafts</th></tr>" + "".join(
            "<tr><td>P%d</td><td>%d of 12</td></tr>" % (i, i) for i in range(n)) + "</table>"
        self.assertEqual(self.flags("lookup", table(3)), ['"A claim." gives 3 shares as text in a table: hq-figure units draws them'])
        self.assertEqual(self.flags("lookup", table(2)), [])
        self.assertEqual(self.flags("lookup", table(3) + "<svg></svg>"), [])

    def test_results_as_words_against_two_places_are_named_and_a_result_list_is_not(self):
        # The La Belle reports of 11 Nov 2026: a check against desktop and phone, and a Check and Result list.
        grid = lambda n: "<table><tr><th>Check</th><th>Desktop 1440</th><th>Phone 390</th></tr>" + (
            "<tr><td>Quiz opens</td><td>Pass</td><td>Pass. A phone uses the dots.</td></tr>" * n) + "</table>"
        self.assertEqual(self.flags("lookup", grid(3)), ['"A claim." gives 6 results as words in a table: hq-figure grid draws them'])
        self.assertEqual(self.flags("lookup", grid(2)), [])
        self.assertEqual(self.flags("lookup", grid(3) + "<svg></svg>"), [])
        listed = "<table><tr><th>Check</th><th>Result</th></tr>%s</table>" % ("<tr><td>The tile opens its page</td><td>Pass. It showed 48 products.</td></tr>" * 10)
        self.assertEqual(self.flags("lookup", listed), [])

    def test_a_time_column_is_not_named(self):
        # Replay of 11 Nov 2026: this advice sent a send calendar to a time strip, and it read worse.
        table = "<table><tr><th>Task</th><th>Started, UTC</th></tr>%s</table>" % ("<tr><td>T</td><td>04:19</td></tr>" * 3)
        self.assertEqual(self.flags("lookup", table), [])

    def test_a_figure_with_a_table_under_it_is_named_and_alone_it_is_not(self):
        figure, table = '<svg class="hqf"></svg>', "<table><tr><td>Missing</td></tr></table>"
        self.assertEqual(self.flags("share", figure), [])
        self.assertEqual(self.flags("lookup", table), [])
        self.assertEqual(len(self.flags("share", figure + table)), 1)
        self.assertIn("a figure replaces the table", self.flags("share", figure + table)[0])


def _hook_namespace():
    import re
    source = (ROOT / "hooks/artifact-hook.sh").read_text()
    start = source.index('_DRAWN = ')
    stop = source.index('# A REPORT THAT WILL NOT WORK')
    namespace = {"re": re}
    exec(source[start:stop], namespace)
    return namespace


class ProvenanceTests(unittest.TestCase):
    """24 Oct 2026: every page says which rules its session was given, or "none"."""

    def publish_with(self, seen):
        with tempfile.TemporaryDirectory() as root:
            rules = Path(root) / "rules"
            if seen is not None:
                (rules / "seen").mkdir(parents=True)
                (rules / "seen" / "session").write_text(seen + "\n")
            draft = Path(root) / "session/_drafts/report.html"
            draft.parent.mkdir(parents=True)
            draft.write_text('<head><meta name="intranet:session" content="session"></head><p>Body.</p>')
            with patch.object(hqpage, "agents_root", return_value=Path(root)), \
                 patch.object(hqpage, "rules_dir", return_value=rules), \
                 patch.object(hqpage.subprocess, "run"):
                self.assertEqual(hqpage.publish("session", "report"), 0)
            return (Path(root) / "session/report.html").read_text()

    def test_a_page_from_a_session_with_rules_carries_the_version(self):
        page = self.publish_with("3f6d1085bd5e")
        self.assertIn('<meta name="intranet:rules" content="3f6d1085bd5e">', page)
        self.assertIn('<meta name="intranet:app" content="none">', page)

    def test_a_page_from_a_session_without_rules_says_none(self):
        page = self.publish_with(None)
        self.assertIn('<meta name="intranet:rules" content="none">', page)

    def test_restamping_replaces_rather_than_duplicates(self):
        with patch.object(hqpage, "provenance", return_value=("abc123def456", "none")):
            once = hqpage.stamp_provenance('<meta name="intranet:session" content="s">', "s")
            twice = hqpage.stamp_provenance(once, "s")
        self.assertEqual(twice.count("intranet:rules"), 1)


class WritingStandardCheckTests(unittest.TestCase):
    """Both sides, on headlines from the 24 Oct audit: a checker that passes
    everything, or flags everything, is worse than none."""

    def test_headline_fragments_are_flagged_and_sentences_are_not(self):
        has_verb = _hook_namespace()["_ste_headline_has_verb"]
        for bad in ["Seat, not viewer.", "Four tiers, every cell filled.", "Three built, none live.",
                    "Proven by API, unseen by you.", "Ready for review.", "Backfill, then plan.",
                    "Four fixes, five checks.", "Wave 5 in, holdout set."]:
            self.assertFalse(has_verb(bad), bad)
        for good in ["You are right.", "The rules took hold.", "Gate 3 passes.", "K2 picks the empty metric.",
                     "Half of it still matters.", "We print both numbers, never the gap.",
                     "Repeat the early-bird week.", "Two chips moved.", "The delete cannot fire"]:
            self.assertTrue(has_verb(good), good)

    def test_prose_breaks_are_quoted_and_evidence_is_not_read(self):
        flags = _hook_namespace()["_ste_flags"]
        clean = ('<h1>Two chips moved.</h1><p class="lede">We moved two chips. The tests pass.</p>'
                 '<pre>a; b; c; d; e; f; g; h; i; j; k; l; m; n; o; p; q; r; s; t; u; v</pre>'
                 '<table><tr><td>x; y</td></tr></table>')
        self.assertEqual(flags(clean), [])
        dirty = ('<h1>Four fixes, five checks.</h1>'
                 '<p class="lede">The sync fails; the alert stays green. '
                 'This sentence keeps going well past the twenty word limit because it adds one more clause '
                 'and then another one after that.</p>')
        found = flags(dirty)
        self.assertEqual([rule for rule, _ in found], ["headline with no verb", "semicolon", "22 words"])

    def test_the_ask_tells_the_agent_to_rewrite_and_never_blocks(self):
        ask = _hook_namespace()["_ste_ask"]('<h1>Ready for review.</h1>')
        self.assertIn("Rewrite these sentences under brief.md, Writing standard, then publish again.", ask)
        self.assertIn('"Ready for review."', ask)


class PageMetricsLineTests(unittest.TestCase):
    """The hook's half of page_published: one line per live page, none for drafts."""

    def run_hook_on(self, home, rel, page):
        import json, os, re
        ns = _hook_namespace()
        source = (ROOT / "hooks/artifact-hook.sh").read_text()
        start = source.index("def _record_page_metrics(path):")
        stop = source.index("\n_record_page_metrics(path)", start)
        ns.update({"os": os, "json": json, "re": re})
        target = Path(home) / "Documents/agents" / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(page)
        with patch.dict(os.environ, {"HOME": home, "TB_PAGE_HARNESS": "codex"}):
            exec(source[start:stop], ns)
            ns["_record_page_metrics"](str(target))
        log = Path(home) / "Library/Application Support/VoiceDispatch/rules/pages.jsonl"
        return [json.loads(l) for l in log.read_text().splitlines()] if log.exists() else []

    PAGE = ('<head><meta name="intranet:session" content="s"><meta name="intranet:type" content="audit">'
            '<meta name="intranet:brand" content="U Vape"></head><h1>Four fixes, five checks.</h1>'
            '<p class="lede">The sync fails; the alert stays green.</p>'
            '<section class="claim" data-shows="text"><span class="c">One claim holds.</span></section>')

    def test_a_live_page_writes_one_line_with_its_counts_and_none_without_a_record(self):
        with tempfile.TemporaryDirectory() as home:
            lines = self.run_hook_on(home, "abcdef12-3456/report.html", self.PAGE)
        self.assertEqual(len(lines), 1)
        line = lines[0]
        self.assertEqual((line["session"], line["harness"], line["type"], line["rules"]),
                         ("abcdef12-3456", "codex", "audit", "none"))
        self.assertEqual((line["claims"], line["semicolons"], line["headline_has_verb"], line["ste_flags"]),
                         (1, 1, False, 2))

    def test_a_page_stamped_with_rules_reports_them(self):
        with tempfile.TemporaryDirectory() as home:
            page = self.PAGE.replace("</head>", '<meta name="intranet:rules" content="3f6d1085bd5e"></head>')
            self.assertEqual(self.run_hook_on(home, "abcdef12-3456/r.html", page)[0]["rules"], "3f6d1085bd5e")

    def test_drafts_and_hubs_are_not_pages(self):
        with tempfile.TemporaryDirectory() as home:
            self.assertEqual(self.run_hook_on(home, "abcdef12-3456/_drafts/report.html", self.PAGE), [])
            self.assertEqual(self.run_hook_on(home, "abcdef12-3456/index.html", self.PAGE), [])


if __name__ == "__main__":
    unittest.main()
