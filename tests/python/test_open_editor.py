"""POST /api/open-editor: the console's "Open Monitoring settings" button."""
import http.client
import json
import sys
import threading
import unittest
from http.server import HTTPServer
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "MonitoringConsole"))

import monitoring_console as mc  # noqa: E402


class OpenEditorFunctionTests(unittest.TestCase):
    def test_does_not_start_a_second_editor(self):
        with mock.patch.object(mc, "_port_open", return_value=True), \
             mock.patch.object(mc.subprocess, "Popen") as popen:
            result = mc.open_editor()
        self.assertEqual(result, {"ok": True, "url": "http://localhost:5757", "already_running": True})
        popen.assert_not_called()

    def test_starts_the_editor_hidden_without_a_browser_and_waits_for_it(self):
        answers = iter([False, False, True])        # closed, still starting, listening
        with mock.patch.object(mc, "_port_open", side_effect=lambda *a, **k: next(answers)), \
             mock.patch.object(mc.subprocess, "Popen") as popen, \
             mock.patch.object(mc.time, "sleep"), \
             mock.patch.object(mc, "_log_action") as log:
            result = mc.open_editor()
        self.assertTrue(result["ok"])
        self.assertFalse(result["already_running"])
        args = popen.call_args[0][0]
        self.assertEqual(Path(args[1]), mc.EDITOR_SCRIPT)   # full path: how stop_monitoring finds it
        self.assertEqual(args[2], "--no-browser")
        log.assert_called_once()

    def test_reports_an_editor_that_never_starts(self):
        with mock.patch.object(mc, "_port_open", return_value=False), \
             mock.patch.object(mc.subprocess, "Popen"), \
             mock.patch.object(mc.time, "sleep"):
            result = mc.open_editor(wait_sec=0.01)
        self.assertFalse(result["ok"])
        self.assertIn("5757", result["error"])

    def test_reports_a_launch_failure(self):
        with mock.patch.object(mc, "_port_open", return_value=False), \
             mock.patch.object(mc.subprocess, "Popen", side_effect=OSError("denied")):
            result = mc.open_editor()
        self.assertEqual(result["ok"], False)
        self.assertIn("denied", result["error"])


class OpenEditorHttpTests(unittest.TestCase):
    def setUp(self):
        self.httpd = HTTPServer(("localhost", 0), mc.Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def post(self, origin):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("POST", "/api/open-editor", body=b"",
                      headers={"Host": f"localhost:{self.port}", "Origin": origin, "Content-Length": "0"})
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return resp.status, json.loads(body)

    def test_rejects_other_websites(self):
        with mock.patch.object(mc, "open_editor") as open_editor:
            status, body = self.post("http://evil.example")
        self.assertEqual(status, 403)
        open_editor.assert_not_called()

    def test_same_origin_request_opens_the_editor(self):
        with mock.patch.object(mc, "open_editor", return_value={"ok": True, "url": "x", "already_running": True}):
            status, body = self.post(f"http://localhost:{self.port}")
        self.assertEqual((status, body["ok"]), (200, True))


class ServerFlagTests(unittest.TestCase):
    def test_server_skips_the_browser_with_no_browser(self):
        source = (ROOT / "server.py").read_text(encoding="utf-8")
        self.assertIn('"--no-browser" not in sys.argv[1:]', source)


if __name__ == "__main__":
    unittest.main()
