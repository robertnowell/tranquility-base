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


if __name__ == "__main__":
    unittest.main()
