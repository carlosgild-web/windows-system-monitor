#!/usr/bin/env python3
"""
Minimal local server for the Monitoring Settings Editor (stdlib only).

Routes:
  GET  /                 -> monitoring_editor.html
  GET  /api/settings     -> reads  monitoring_settings.json
  GET  /api/identity     -> which copy of the project this is (a hash, no path) + settings version
  POST /api/settings     -> writes monitoring_settings.json (JSON object only)
  POST /api/open-file    -> opens a project .xlsx file in its default app

Security: the server binds to localhost only, and every POST must come from
the editor page itself (Host + Origin checks). Without this, any website open
in the browser could rewrite the settings -- including the run_script actions
-- or launch files through /api/open-file (CSRF / DNS rebinding).
"""
import hashlib
import json
import os
import sys
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import unquote

BASE = Path(__file__).parent.resolve()
JSON_FILE = BASE / "monitoring_settings.json"
HTML_FILE = BASE / "monitoring_editor.html"
STATIC_DIR = BASE / "web" / "static"   # theme, icons, images (shared with the console)
PORT = 5757
# localhost by default. The demo container sets BIND_HOST=0.0.0.0 and publishes the port
# on 127.0.0.1 only, so the Host/Origin checks below still see localhost:5757.
BIND_HOST = os.environ.get("BIND_HOST", "localhost")
MAX_BODY_BYTES = 2 * 1024 * 1024
OPENABLE_EXTENSIONS = {".xlsx", ".xlsm", ".xls", ".csv"}


def copy_id(base: Path) -> str:
    """Identifies this copy of the project without revealing its path.

    The console compares it with its own before opening the editor on port 5757, so a
    second copy of the project elsewhere on the machine is never opened by mistake.
    monitoring_console.py has the same function; a test keeps the two in step.
    """
    return hashlib.sha256(str(base).lower().encode("utf-8")).hexdigest()[:16]


def identity() -> dict:
    try:
        version = json.loads(JSON_FILE.read_text(encoding="utf-8-sig")).get("_meta", {}).get("version", "?")
    except (OSError, ValueError, AttributeError):
        version = "?"
    return {"app": "settings-editor", "copy_id": copy_id(BASE), "version": version}


def is_same_origin(headers, port: int) -> bool:
    """True when a request comes from this server's own page.

    Host must be localhost/127.0.0.1 on our port (blocks DNS rebinding).
    Origin, when present, must match too. Browsers always send Origin on
    cross-site POSTs, so a missing Origin means a non-browser client such
    as curl, which already has local access.
    """
    allowed = {f"localhost:{port}", f"127.0.0.1:{port}"}
    if headers.get("Host", "") not in allowed:
        return False
    origin = headers.get("Origin")
    if origin is None:
        return True
    return origin in {f"http://{h}" for h in allowed}


STATIC_TYPES = {
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".webp": "image/webp",
    ".ico": "image/x-icon",
    ".woff2": "font/woff2",
}


def resolve_static(url_path: str):
    """Map /static/<file> (or /web/static/<file>) to a file inside STATIC_DIR, or None.

    Only known asset types are served, and the resolved path must stay inside
    STATIC_DIR, so /static/../server.py or an encoded traversal returns 404.
    """
    rel = url_path.split("?", 1)[0].split("#", 1)[0]
    # /web/static/ is how the editor links them: relative paths also work from file://
    for prefix in ("/static/", "/web/static/"):
        if rel.startswith(prefix):
            rel = unquote(rel[len(prefix):])
            break
    else:
        return None
    if not rel or "\\" in rel or "\x00" in rel:
        return None
    try:
        target = (STATIC_DIR / rel).resolve()
    except (OSError, ValueError):
        return None
    if STATIC_DIR not in target.parents or not target.is_file():
        return None
    if target.suffix.lower() not in STATIC_TYPES:
        return None
    return target


def resolve_openable(rel: str):
    """Resolve a user-supplied path; None unless it is a spreadsheet inside BASE."""
    try:
        target = (BASE / rel).resolve()
    except (OSError, ValueError):
        return None
    if target != BASE and BASE not in target.parents:
        return None                      # path traversal (../../...)
    if target.suffix.lower() not in OPENABLE_EXTENSIONS:
        return None
    return target


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # silence request logs in the console

    # ── GET ──────────────────────────────────────────────────────────────────
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(HTML_FILE.read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/api/settings":
            self._send(JSON_FILE.read_bytes(), "application/json; charset=utf-8")
        elif self.path == "/api/identity":
            self._send(json.dumps(identity()).encode("utf-8"), "application/json; charset=utf-8")
        elif self.path.startswith(("/static/", "/web/static/")):
            target = resolve_static(self.path)
            if target is None:
                return self.send_error(404)
            self._send(target.read_bytes(), STATIC_TYPES[target.suffix.lower()])
        else:
            self.send_error(404)

    # ── POST ─────────────────────────────────────────────────────────────────
    def do_POST(self):
        # Read the body before any early reply: on Windows, closing a socket
        # with unread data resets the connection and the client never sees
        # the error response.
        raw = self._read_body()
        if raw is None:
            return  # error response already sent

        if not is_same_origin(self.headers, self.server.server_address[1]):
            return self._json(403, {"ok": False, "error": "Cross-origin request rejected"})

        try:
            data = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            return self._json(400, {"ok": False, "error": f"Invalid JSON: {exc}"})

        if self.path == "/api/settings":
            if not isinstance(data, dict):
                return self._json(400, {"ok": False, "error": "Settings must be a JSON object"})
            JSON_FILE.write_text(
                json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            self._json(200, {"ok": True})

        elif self.path == "/api/open-file":
            rel = data.get("path", "") if isinstance(data, dict) else ""
            target = resolve_openable(str(rel))
            if target is None:
                self._json(400, {"ok": False,
                                 "error": "Only spreadsheet files inside the project folder can be opened"})
            elif not target.exists():
                self._json(404, {"ok": False, "error": f"File not found: {rel}"})
            elif not hasattr(os, "startfile"):
                self._json(501, {"ok": False,
                                 "error": "Opening files needs Windows (not available in the demo container)"})
            else:
                os.startfile(str(target))  # Windows only
                self._json(200, {"ok": True})
        else:
            self.send_error(404)

    # ── helpers ──────────────────────────────────────────────────────────────
    def _read_body(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            length = -1
        if length <= 0 or length > MAX_BODY_BYTES:
            self.close_connection = True
            self._json(400, {"ok": False, "error": "Missing or oversized request body"})
            return None
        return self.rfile.read(length)

    def _json(self, status: int, payload: dict):
        self._send(json.dumps(payload).encode("utf-8"),
                   "application/json; charset=utf-8", status)

    def _send(self, body: bytes, ctype: str, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    url = f"http://localhost:{PORT}"
    print(f"\n  Monitoring Settings Editor")
    print(f"  Open: {url}")
    print("  Stop: Ctrl+C\n")
    # --no-browser: started by the console's "Open Monitoring settings" button,
    # which opens the page itself.
    if "--no-browser" not in sys.argv[1:] and not os.environ.get("NO_BROWSER"):
        webbrowser.open(url)
    HTTPServer((BIND_HOST, PORT), Handler).serve_forever()
