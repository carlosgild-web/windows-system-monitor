"""The /static/ route of both servers (shared theme, icons, images) and the console page."""
import http.client
import sys
import threading
import unittest
from http.server import HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "MonitoringConsole"))

import monitoring_console as mc  # noqa: E402
import server  # noqa: E402


class ResolveStaticTests(unittest.TestCase):
    """Same rules in both servers."""

    MODULES = (server, mc)

    def test_serves_known_assets(self):
        for mod in self.MODULES:
            with self.subTest(mod=mod.__name__):
                self.assertEqual(mod.resolve_static("/static/theme.css"), mod.STATIC_DIR / "theme.css")
                self.assertIsNotNone(mod.resolve_static("/static/icons.svg?v=2"))

    def test_rejects_paths_outside_the_static_folder(self):
        attempts = [
            "/static/../server.py",
            "/static/%2e%2e/server.py",
            "/static/..%2fmonitoring_settings.json",
            "/static/..%5C..%5Cserver.py",
            "/static/../../monitoring_settings.json",
            "/static/",
            "/static/missing.css",
            "/other/theme.css",
        ]
        for mod in self.MODULES:
            for path in attempts:
                with self.subTest(mod=mod.__name__, path=path):
                    self.assertIsNone(mod.resolve_static(path))

    def test_rejects_unknown_file_types(self):
        for mod in self.MODULES:
            with self.subTest(mod=mod.__name__):
                probe = mod.STATIC_DIR / "probe.json"
                probe.write_text("{}", encoding="utf-8")
                try:
                    self.assertIsNone(mod.resolve_static("/static/probe.json"))
                finally:
                    probe.unlink()


class ServedOverHttpTests(unittest.TestCase):
    def serve(self, handler):
        httpd = HTTPServer(("localhost", 0), handler)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        return httpd.server_address[1]

    def get(self, port, path):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request("GET", path, headers={"Host": f"localhost:{port}"})
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return resp.status, resp.getheader("Content-Type"), body

    def test_console_page_and_assets(self):
        port = self.serve(mc.Handler)
        status, ctype, body = self.get(port, "/")
        self.assertEqual(status, 200)
        self.assertIn(b"Monitoring Console", body)
        self.assertIn(b"/static/theme.css", body)
        status, ctype, _ = self.get(port, "/static/theme.css")
        self.assertEqual((status, ctype), (200, "text/css; charset=utf-8"))
        status, ctype, body = self.get(port, "/static/icons.svg")
        self.assertEqual((status, ctype), (200, "image/svg+xml"))
        self.assertIn(b'id="i-cpu"', body)
        self.assertEqual(self.get(port, "/static/../monitoring_settings.json")[0], 404)

    def test_editor_serves_the_same_assets(self):
        port = self.serve(server.Handler)
        status, ctype, _ = self.get(port, "/static/theme.js")
        self.assertEqual((status, ctype), (200, "text/javascript; charset=utf-8"))
        self.assertEqual(self.get(port, "/static/%2e%2e/%2e%2e/server.py")[0], 404)


class IconSpriteTests(unittest.TestCase):
    def test_every_icon_the_console_uses_exists(self):
        import re
        sprite = (ROOT / "web" / "static" / "icons.svg").read_text(encoding="utf-8")
        defined = set(re.findall(r'<symbol id="i-([\w-]+)"', sprite))
        page = (ROOT / "web" / "console.html").read_text(encoding="utf-8")
        used = set(re.findall(r"icons\.svg#i-([\w-]+)", page))
        used |= set(re.findall(r"ico\('([\w-]+)'", page))
        used |= set(re.findall(r":'([\w-]+)'", re.search(r"const ACT_ICON = \{(.*?)\};", page).group(1)))
        self.assertFalse(used - defined, f"icons used but not in the sprite: {sorted(used - defined)}")


if __name__ == "__main__":
    unittest.main()
