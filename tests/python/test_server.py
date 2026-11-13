"""Tests for server.py (settings editor backend).

Each test runs the real HTTP handler on a free port against a temporary
project folder, so nothing in the repository is modified.
"""
import http.client
import json
import shutil
import sys
import tempfile
import threading
import unittest
from http.server import HTTPServer
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

import server  # noqa: E402


class EditorServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / "sample_data").mkdir()
        (self.tmp / "sample_data" / "book.xlsx").write_bytes(b"fake")
        (self.tmp / "tool.exe").write_bytes(b"fake")
        self.settings = self.tmp / "monitoring_settings.json"
        self.settings.write_text('{"_meta": {"version": "1.0.0"}}', encoding="utf-8")
        html = self.tmp / "monitoring_editor.html"
        html.write_text("<html>editor</html>", encoding="utf-8")

        self.patches = [
            mock.patch.object(server, "BASE", self.tmp.resolve()),
            mock.patch.object(server, "JSON_FILE", self.settings),
            mock.patch.object(server, "HTML_FILE", html),
            mock.patch.object(server.os, "startfile", create=True),
        ]
        for p in self.patches:
            p.start()
        self.startfile = server.os.startfile

        self.httpd = HTTPServer(("localhost", 0), server.Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        for p in self.patches:
            p.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ── helpers ──────────────────────────────────────────────────────────────
    def request(self, method, path, body=None, origin="same", host=None):
        # Connect to 127.0.0.1 directly: on Windows "localhost" tries IPv6
        # first and waits ~2 s per connection before falling back to IPv4.
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {"Host": host or f"localhost:{self.port}"}
        if origin == "same":
            headers["Origin"] = f"http://localhost:{self.port}"
        elif origin:
            headers["Origin"] = origin
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        else:
            data = None
        conn.request(method, path, body=data, headers=headers)
        resp = conn.getresponse()
        payload = resp.read()
        conn.close()
        return resp.status, payload

    # ── GET ──────────────────────────────────────────────────────────────────
    def test_serves_editor_page(self):
        status, body = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn(b"editor", body)

    def test_get_settings_returns_file(self):
        status, body = self.request("GET", "/api/settings")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["_meta"]["version"], "1.0.0")

    def test_unknown_route_is_404(self):
        self.assertEqual(self.request("GET", "/nope")[0], 404)

    # ── POST /api/settings ───────────────────────────────────────────────────
    def test_save_settings_round_trip(self):
        new = {"_meta": {"version": "2.0.0"}, "note": "café — ok"}
        status, body = self.request("POST", "/api/settings", new)
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)["ok"])
        self.assertEqual(json.loads(self.settings.read_text(encoding="utf-8")), new)

    def test_save_without_origin_header_is_allowed(self):
        # Non-browser clients (curl, scripts) send no Origin header.
        status, _ = self.request("POST", "/api/settings", {"a": 1}, origin=None)
        self.assertEqual(status, 200)

    def test_cross_origin_save_is_rejected(self):
        before = self.settings.read_text(encoding="utf-8")
        status, _ = self.request("POST", "/api/settings", {"hacked": True}, origin="https://evil.example")
        self.assertEqual(status, 403)
        self.assertEqual(self.settings.read_text(encoding="utf-8"), before)

    def test_dns_rebinding_host_is_rejected(self):
        status, _ = self.request("POST", "/api/settings", {"a": 1}, origin=None, host=f"evil.example:{self.port}")
        self.assertEqual(status, 403)

    def test_invalid_json_returns_400(self):
        status, body = self.request("POST", "/api/settings", b"not json")
        self.assertEqual(status, 400)
        self.assertIn("Invalid JSON", json.loads(body)["error"])

    def test_non_object_json_returns_400(self):
        self.assertEqual(self.request("POST", "/api/settings", [1, 2])[0], 400)

    def test_empty_body_returns_400(self):
        self.assertEqual(self.request("POST", "/api/settings", b"")[0], 400)

    # ── POST /api/open-file ──────────────────────────────────────────────────
    def test_open_file_opens_project_spreadsheet(self):
        status, _ = self.request("POST", "/api/open-file", {"path": "sample_data/book.xlsx"})
        self.assertEqual(status, 200)
        self.startfile.assert_called_once()

    def test_open_file_rejects_path_traversal(self):
        status, _ = self.request("POST", "/api/open-file", {"path": "../../Windows/System32/notepad.exe"})
        self.assertEqual(status, 400)
        self.startfile.assert_not_called()

    def test_open_file_rejects_non_spreadsheet_inside_project(self):
        status, _ = self.request("POST", "/api/open-file", {"path": "tool.exe"})
        self.assertEqual(status, 400)
        self.startfile.assert_not_called()

    def test_open_file_missing_spreadsheet_is_404(self):
        status, _ = self.request("POST", "/api/open-file", {"path": "sample_data/missing.xlsx"})
        self.assertEqual(status, 404)
        self.startfile.assert_not_called()

    def test_open_file_cross_origin_is_rejected(self):
        status, _ = self.request("POST", "/api/open-file", {"path": "sample_data/book.xlsx"},
                                 origin="https://evil.example")
        self.assertEqual(status, 403)
        self.startfile.assert_not_called()


class SameOriginTests(unittest.TestCase):
    def test_rules(self):
        cases = [
            ({"Host": "localhost:5757"}, True),
            ({"Host": "127.0.0.1:5757", "Origin": "http://127.0.0.1:5757"}, True),
            ({"Host": "localhost:5757", "Origin": "http://localhost:5757"}, True),
            ({"Host": "localhost:5757", "Origin": "null"}, False),
            ({"Host": "localhost:5757", "Origin": "http://localhost:9999"}, False),
            ({"Host": "evil.example:5757"}, False),
            ({}, False),
        ]
        for headers, expected in cases:
            with self.subTest(headers=headers):
                self.assertEqual(server.is_same_origin(headers, 5757), expected)


if __name__ == "__main__":
    unittest.main()
