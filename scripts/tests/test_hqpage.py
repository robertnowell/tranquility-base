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
            with patch.object(hqpage, "agents_root", return_value=Path(root)), patch.object(hqpage.subprocess, "run") as opened:
                self.assertEqual(hqpage.publish("session", "report"), 0)
                opened.assert_called_once()
            self.assertFalse(draft.exists())
            self.assertEqual((draft.parent.parent / "report.html").read_text(), markup)

    def test_timeline_words_do_not_trigger_diagram_warning(self):
        source = (ROOT / "hooks/artifact-hook.sh").read_text()
        start = source.index('_DRAWN = ')
        stop = source.index('\n    return flags', start) + len('\n    return flags')
        import re
        namespace = {"re": re}
        exec(source[start:stop], namespace)
        page = '<section class="claim" data-shows="text"><span class="c">Before launch, then after launch.</span><ol><li>Before</li><li>After</li></ol></section>'
        self.assertEqual(namespace['_evidence_flags'](page), [])


if __name__ == "__main__":
    unittest.main()
