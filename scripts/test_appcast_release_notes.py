#!/usr/bin/env python3
"""Regression tests: every release-notes layout must yield real appcast text."""
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import appcast_release_notes as notes  # noqa: E402

LEGACY = """## ClashFX 1.1.11.13 (Lab)

### Improvements

- **Show the Selected Proxy Group by Default** — Outer menu shows Proxies.
- **Keep Route Details Available** — Tooltips keep the path.

Validation: tests passed.

---

### 中文

- **旧条目** — 旧说明
"""

BILINGUAL = """## ClashFX 1.1.11.16 (Lab)

### 中文

- 修复唤醒后 DNS 监听失效。
- 新增 <尖括号> & 符号。

已知问题：端口可能冲突。

### English

- Fix the DNS listener failing after wake.
- Add a post-wake check.

Experimental Lab release.

## ClashFX 1.1.11.15 (Lab)

### English

- Older release must never leak in.
"""


class AppcastReleaseNotesTests(unittest.TestCase):
    def test_legacy_layout_keeps_titles(self):
        out = notes.render_html("1.1.11.13", " (Lab)", LEGACY)
        self.assertIn("<strong>Show the Selected Proxy Group by Default</strong>", out)
        self.assertNotIn("See release notes on GitHub", out)

    def test_bilingual_layout_renders_both_languages(self):
        out = notes.render_html("1.1.11.16", " (Lab)", BILINGUAL)
        self.assertIn("<h3>中文</h3>", out)
        self.assertIn("<h3>English</h3>", out)
        self.assertIn("修复唤醒后 DNS 监听失效。", out)
        self.assertIn("Fix the DNS listener failing after wake.", out)
        self.assertNotIn("See release notes on GitHub", out)

    def test_only_newest_release_is_used(self):
        self.assertNotIn("Older release", notes.render_html("1.1.11.16", "", BILINGUAL))

    def test_html_is_escaped_and_cdata_safe(self):
        out = notes.render_html("1", "", BILINGUAL + "\n- x ]]> y")
        self.assertIn("&lt;尖括号&gt; &amp;", out)
        self.assertNotIn("]]>", out)

    def test_unparseable_notes_fall_back(self):
        self.assertIn("See release notes on GitHub", notes.render_html("1", "", "no bullets"))

    def test_summaries_for_website_payload(self):
        self.assertEqual(notes.first_summary(BILINGUAL, "en"), "Fix the DNS listener failing after wake.")
        self.assertEqual(notes.first_summary(BILINGUAL, "zh"), "修复唤醒后 DNS 监听失效。")
        self.assertEqual(notes.first_summary(LEGACY, "en"), "Outer menu shows Proxies.")

    def test_published_release_notes_never_fall_back(self):
        """The repository's own RELEASE_NOTES.md must render real content."""
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        path = os.path.join(root, "RELEASE_NOTES.md")
        content = open(path, encoding="utf-8").read()
        out = notes.render_html("0", "", content)
        self.assertNotIn("<p>See release notes on GitHub.</p>", out)
        self.assertIn("<li>", out)
        self.assertTrue(notes.first_summary(content, "en"))
        self.assertTrue(notes.first_summary(content, "zh"))

    def test_cli(self):
        script = os.path.join(os.path.dirname(__file__), "appcast_release_notes.py")
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        out = subprocess.run([sys.executable, script, "html", "9.9", " (Lab)"], cwd=root,
                             capture_output=True, text=True, check=True).stdout
        self.assertIn("<h2>ClashFX v9.9 (Lab)</h2>", out)


if __name__ == "__main__":
    unittest.main()
