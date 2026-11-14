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
    def own_identity(self):
        return {"app": "settings-editor", "copy_id": mc.copy_id(mc.BASE), "version": "1.7.0"}

    def test_does_not_start_a_second_editor(self):
        with mock.patch.object(mc, "_port_open", return_value=True), \
             mock.patch.object(mc, "editor_identity", return_value=self.own_identity()), \
             mock.patch.object(mc.subprocess, "Popen") as popen:
            result = mc.open_editor()
        self.assertEqual(result, {"ok": True, "url": "http://localhost:5757", "already_running": True})
        popen.assert_not_called()

    def test_refuses_the_editor_of_another_copy(self):
        other = dict(self.own_identity(), copy_id="0123456789abcdef", version="1.6.0")
        with mock.patch.object(mc, "_port_open", return_value=True), \
             mock.patch.object(mc, "editor_identity", return_value=other), \
             mock.patch.object(mc.subprocess, "Popen") as popen:
            result = mc.open_editor()
        self.assertFalse(result["ok"])
        self.assertTrue(result["foreign_editor"])
        self.assertIn("another copy", result["error"])
        self.assertIn("v1.6.0", result["error"])
        popen.assert_not_called()

    def test_refuses_an_editor_without_an_identity(self):
        # An editor from before /api/identity existed, or another program on the port.
        with mock.patch.object(mc, "_port_open", return_value=True), \
             mock.patch.object(mc, "editor_identity", return_value=None), \
             mock.patch.object(mc.subprocess, "Popen") as popen:
            result = mc.open_editor()
        self.assertTrue(result["foreign_editor"])
        self.assertIn("older settings editor", result["error"])
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


class EditorIdentityTests(unittest.TestCase):
    """GET /api/identity on the real editor server, read by the console."""

    def setUp(self):
        sys.path.insert(0, str(ROOT))
        import server
        self.server = server
        self.httpd = HTTPServer(("localhost", 0), server.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def test_console_and_editor_compute_the_same_copy_id(self):
        self.assertEqual(self.server.copy_id(self.server.BASE), mc.copy_id(mc.BASE))
        self.assertEqual(mc.copy_id(Path("C:/A/Repo")), mc.copy_id(Path("c:/a/repo")))   # Windows paths ignore case
        self.assertNotEqual(mc.copy_id(Path("C:/one/repo")), mc.copy_id(Path("C:/two/repo")))

    def test_identity_names_the_copy_without_its_path(self):
        port = self.httpd.server_address[1]
        with mock.patch.object(mc, "EDITOR_HOST", "127.0.0.1"), mock.patch.object(mc, "EDITOR_PORT", port):
            ident = mc.editor_identity()
        self.assertEqual(ident["copy_id"], mc.copy_id(mc.BASE))
        self.assertEqual(ident["app"], "settings-editor")
        self.assertNotIn(str(ROOT).lower(), json.dumps(ident).lower())

    def test_an_older_editor_or_nothing_has_no_identity(self):
        from http.server import BaseHTTPRequestHandler

        class OldEditor(BaseHTTPRequestHandler):       # answers, but has no /api/identity
            def do_GET(self):
                self.send_error(404)

            def log_message(self, *args):
                pass

        old = HTTPServer(("localhost", 0), OldEditor)
        threading.Thread(target=old.serve_forever, daemon=True).start()
        self.addCleanup(old.server_close)
        self.addCleanup(old.shutdown)
        with mock.patch.object(mc, "EDITOR_HOST", "127.0.0.1"), \
             mock.patch.object(mc, "EDITOR_PORT", old.server_address[1]):
            self.assertIsNone(mc.editor_identity())
        free = HTTPServer(("localhost", 0), OldEditor)       # grab a port, then free it: nothing listens
        port = free.server_address[1]
        free.server_close()
        with mock.patch.object(mc, "EDITOR_HOST", "127.0.0.1"), mock.patch.object(mc, "EDITOR_PORT", port):
            self.assertIsNone(mc.editor_identity(timeout=0.5))


class ServerFlagTests(unittest.TestCase):
    def test_server_skips_the_browser_with_no_browser(self):
        source = (ROOT / "server.py").read_text(encoding="utf-8")
        self.assertIn('"--no-browser" not in sys.argv[1:]', source)


if __name__ == "__main__":
    unittest.main()
