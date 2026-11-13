#!/usr/bin/env python3
"""
Web-based Process Monitoring Console.
Usage: python monitoring_console.py
       Browser opens automatically at http://localhost:5758
"""
import json
import subprocess
import threading
import time
import webbrowser
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import unquote
from socketserver import ThreadingMixIn

BASE           = Path(__file__).parent.parent.resolve()
SETTINGS_FILE  = BASE / "monitoring_settings.json"
STATE_FILE     = BASE / "logs" / "process_state.json"
PERF_STATE_FILE = BASE / "logs" / "performance_state.json"
DISK_STATE_FILE = BASE / "logs" / "disk_state.json"
NET_STATE_FILE   = BASE / "logs" / "network_state.json"
DOC_STATE_FILE   = BASE / "logs" / "document_state.json"
PORT          = 5758
WEB_DIR       = BASE / "web"
CONSOLE_HTML  = WEB_DIR / "console.html"     # the page; edited as a normal HTML file
STATIC_DIR    = WEB_DIR / "static"           # theme, icons, images (shared with the editor)

MONITOR_SCRIPTS = {
    "process":     BASE / "scripts" / "process_monitor.ps1",
    "performance": BASE / "scripts" / "performance_monitor.ps1",
    "disk":        BASE / "scripts" / "monitor_disk.ps1",
    "network":     BASE / "scripts" / "monitor_network.ps1",
    "document":    BASE / "scripts" / "monitor_document.ps1",
}


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


def resolve_project_path(p: str) -> Path:
    """Relative paths in the settings are relative to the project root."""
    path = Path(p)
    return path if path.is_absolute() else (BASE / path).resolve()


def is_same_origin(headers, port: int) -> bool:
    """True when a request comes from this console's own page.

    Host must be localhost/127.0.0.1 on our port (blocks DNS rebinding);
    Origin, when a browser sends one, must match too. This stops other
    websites from stopping or starting monitors via cross-site POSTs.
    """
    allowed = {f"localhost:{port}", f"127.0.0.1:{port}"}
    if headers.get("Host", "") not in allowed:
        return False
    origin = headers.get("Origin")
    return origin is None or origin in {f"http://{h}" for h in allowed}


def _log_action(message: str):
    try:
        cfg = json.loads(SETTINGS_FILE.read_text(encoding="utf-8-sig"))
        log_file = cfg.get("global", {}).get("log_file", "")
        if log_file:
            log_file = resolve_project_path(log_file)
            with open(log_file, "a", encoding="utf-8") as f:
                f.write(message + "\n")
    except Exception:
        pass


def stop_monitor(key: str) -> dict:
    path = MONITOR_SCRIPTS.get(key)
    if not path:
        return {"ok": False, "error": "unknown monitor"}
    stem = path.stem
    cmd = (
        f"Get-CimInstance Win32_Process | Where-Object {{"
        f" ($_.Name -eq 'powershell.exe' -or $_.Name -eq 'pwsh.exe') -and"
        f" $_.CommandLine -like '*{stem}*' }}"
        f" | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }}"
    )
    # Fire-and-forget: don't block the server waiting for PS to finish
    subprocess.Popen(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", cmd],
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    _log_action(f"[{ts}] ACTION: {key} monitor ({stem}.ps1) STOPPED by user via console.")
    return {"ok": True}


def start_monitor(key: str) -> dict:
    path = MONITOR_SCRIPTS.get(key)
    if not path:
        return {"ok": False, "error": "unknown monitor"}
    if not path.exists():
        return {"ok": False, "error": f"script not found: {path}"}
    stem = path.stem
    # Check if the script process is already running before spawning another instance
    check_cmd = (
        f"$n='{stem}';"
        f"if(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue"
        f"|Where-Object{{$_.Name -like 'power*' -and $_.ProcessId -ne $PID -and $_.CommandLine -like ('*'+$n+'*')}}){{exit 0}}else{{exit 1}}"
    )
    try:
        r = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", check_cmd],
            capture_output=True, timeout=10,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        if r.returncode == 0:
            return {"ok": False, "already_running": True,
                    "error": f"The {key} monitor is already running — no action needed."}
    except Exception:
        pass
    subprocess.Popen(
        ["powershell.exe", "-ExecutionPolicy", "Bypass", "-NoProfile",
         "-WindowStyle", "Hidden", "-File", str(path)],
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    _log_action(f"[{ts}] ACTION: {key} monitor ({path.stem}.ps1) STARTED by user via console.")
    return {"ok": True}


def _parse_dt(s):
    try:
        return datetime.strptime(s, "%Y-%m-%d %H:%M:%S")
    except Exception:
        return None


def _check_fresh(path, max_interval_sec):
    """Return True if the state file exists and was updated within the expected window."""
    try:
        d = json.loads(path.read_text(encoding="utf-8-sig"))
        dt = _parse_dt(d.get("updated", ""))
        if dt:
            return int((datetime.now() - dt).total_seconds()) < max_interval_sec * 2 + 20
    except Exception:
        pass
    return False


def check_running(exe_name: str):
    """Live check: is exe_name currently running? Returns True/False, or None on error."""
    try:
        r = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {exe_name}", "/FO", "CSV", "/NH"],
            capture_output=True, text=True, timeout=5,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        return exe_name.lower() in r.stdout.lower()
    except Exception:
        return None


def get_status():
    cfg, state = {}, {}
    try:
        cfg   = json.loads(SETTINGS_FILE.read_text(encoding="utf-8-sig"))
    except Exception:
        pass
    try:
        state = json.loads(STATE_FILE.read_text(encoding="utf-8-sig"))
    except Exception:
        pass

    updated_str  = state.get("updated", "")
    updated_dt   = _parse_dt(updated_str)
    age_sec      = int((datetime.now() - updated_dt).total_seconds()) if updated_dt else None
    max_interval = max((p.get("check_interval_sec", 30) for p in cfg.get("processes", [])), default=30)
    proc_ok      = age_sec is not None and age_sec < (max_interval * 2 + 15)

    perf_int  = cfg.get("performance", {}).get("cpu", {}).get("check_interval_sec", 10)
    disk_int  = min((d.get("check_interval_sec", 60) for d in cfg.get("disk", [])), default=60)
    net_int   = min((h.get("check_interval_sec", 30) for h in cfg.get("network", [])), default=30)
    doc_int   = (cfg.get("document") or {}).get("check_interval_sec", 60)
    monitors = {
        "process":     proc_ok,
        "performance": _check_fresh(PERF_STATE_FILE,   perf_int),
        "disk":        _check_fresh(DISK_STATE_FILE,   disk_int),
        "network":     _check_fresh(NET_STATE_FILE,    net_int),
        "document":    _check_fresh(DOC_STATE_FILE,    doc_int),
    }

    state_map = {p["name"]: p for p in state.get("processes", [])}
    processes = []
    for pc in cfg.get("processes", []):
        nm  = pc.get("name", "")
        sp  = state_map.get(nm, {})
        on_not_running = pc.get("actions", {}).get("on_not_running", [])
        actions     = [a.get("type", "") for a in on_not_running]
        instructions = next((a["instructions"] for a in on_not_running if a.get("instructions")), "")
        live        = check_running(nm) if proc_ok else None
        is_running  = live if live is not None else sp.get("is_running")
        down_since  = sp.get("down_since")
        down_sec    = None
        if is_running is False and down_since:
            ds = _parse_dt(down_since)
            if ds:
                down_sec = int((datetime.now() - ds).total_seconds())
        processes.append({
            "name":         nm,
            "display_name": pc.get("display_name", nm),
            "required":     pc.get("required", False),
            "check_sec":    pc.get("check_interval_sec", 30),
            "is_running":   is_running,
            "down_since":   down_since,
            "down_sec":     down_sec,
            "last_check":   sp.get("last_check"),
            "alert_count":  sp.get("alert_count", 0),
            "actions":      actions,
            "instructions": instructions,
        })

    running_count = sum(1 for p in processes if p["is_running"] is True)

    perf_state = {}
    try:
        perf_state = json.loads(PERF_STATE_FILE.read_text(encoding="utf-8-sig"))
    except Exception:
        pass

    disk_state = {}
    try:
        disk_state = json.loads(DISK_STATE_FILE.read_text(encoding="utf-8-sig"))
    except Exception:
        pass

    net_state = {}
    try:
        net_state = json.loads(NET_STATE_FILE.read_text(encoding="utf-8-sig"))
    except Exception:
        pass

    doc_state = {}
    try:
        doc_state = json.loads(DOC_STATE_FILE.read_text(encoding="utf-8-sig"))
    except Exception:
        pass

    return {
        "engine":        {"ok": any(monitors.values()), "monitors": monitors,
                          "updated": updated_str, "age_sec": age_sec,
                          "pid": state.get("monitor_pid")},
        "processes":     processes,
        "total":         len(processes),
        "running_count": running_count,
        "performance":   perf_state.get("metrics", []),
        "disks":         disk_state.get("drives", []),
        "network":       net_state.get("hosts", []),
        "document":      doc_state if doc_state else None,
        "config": {
            "meta":        cfg.get("_meta", {}),
            "global":      cfg.get("global", {}),
            "processes":   cfg.get("processes", []),
            "performance": cfg.get("performance", {}),
            "disk":        cfg.get("disk", []),
            "network":     cfg.get("network", []),
            "document":    cfg.get("document"),
        },
        "server_time":   datetime.now().strftime("%H:%M:%S"),
        "version":       cfg.get("_meta", {}).get("version", "?"),
    }



class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(CONSOLE_HTML.read_bytes(), "text/html; charset=utf-8")
        elif self.path.startswith(("/static/", "/web/static/")):
            target = resolve_static(self.path)
            if target is None:
                return self.send_error(404)
            self._send(target.read_bytes(), STATIC_TYPES[target.suffix.lower()])
        elif self.path == "/api/status":
            body = json.dumps(get_status(), ensure_ascii=False).encode("utf-8")
            self._send(body, "application/json; charset=utf-8")
        else:
            self.send_error(404)

    def do_POST(self):
        # Drain any body first so an early 403 is not turned into a
        # connection reset on Windows. The API itself takes no body.
        try:
            length = min(int(self.headers.get("Content-Length", 0)), 64 * 1024)
        except ValueError:
            length = 0
        if length > 0:
            self.rfile.read(length)
        if not is_same_origin(self.headers, self.server.server_address[1]):
            body = b'{"ok": false, "error": "Cross-origin request rejected"}'
            return self._send(body, "application/json; charset=utf-8", 403)
        parts = self.path.strip("/").split("/")
        if len(parts) == 3 and parts[0] == "api" and parts[1] in ("stop", "start"):
            action, key = parts[1], parts[2]
            result = stop_monitor(key) if action == "stop" else start_monitor(key)
            body = json.dumps(result, ensure_ascii=False).encode("utf-8")
            self._send(body, "application/json; charset=utf-8")
        else:
            self.send_error(404)

    def _send(self, body: bytes, ctype: str, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


class ThreadedServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    url = f"http://localhost:{PORT}"
    print(f"\n  Monitoring Console  —  Web Interface")
    print(f"  Dashboard : {url}")
    print(f"  Settings  : {SETTINGS_FILE}")
    print("  Stop      : Ctrl+C\n")
    # Open browser after a 1-second delay so the server is ready to accept connections
    threading.Thread(target=lambda: (time.sleep(1), webbrowser.open(url)), daemon=True).start()
    ThreadedServer(("localhost", PORT), Handler).serve_forever()
