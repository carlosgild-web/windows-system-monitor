"""The editor's built-in DEFAULT_DATA (used when the page is opened without server.py)
must match monitoring_settings.json, or "Reload" in offline mode shows an old config."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class EditorDefaultsTest(unittest.TestCase):
    def test_default_data_matches_settings_file(self):
        html = (ROOT / "monitoring_editor.html").read_text(encoding="utf-8")
        match = re.search(r"^const DEFAULT_DATA = (.*);\s*$", html, re.M)
        self.assertIsNotNone(match, "DEFAULT_DATA not found in monitoring_editor.html")
        embedded = json.loads(match.group(1))
        settings = json.loads((ROOT / "monitoring_settings.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(
            embedded, settings,
            "DEFAULT_DATA is out of date: copy monitoring_settings.json into it (compact JSON, one line)",
        )


if __name__ == "__main__":
    unittest.main()
