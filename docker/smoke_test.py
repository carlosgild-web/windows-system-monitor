#!/usr/bin/env python3
"""Smoke test for the running demo container (used by CI, also handy locally):

    docker compose up --build -d && python docker/smoke_test.py && docker compose down

Waits up to 60 s for the console to report every monitor live, then checks the pages,
the simulated data, the read-only mode and the editor. Exits non-zero on failure.
"""
import json
import sys
import time
import urllib.request

CONSOLE = "http://localhost:5758"
EDITOR = "http://localhost:5757"


def get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return r.status, r.headers.get("Content-Type", ""), r.read()


def wait_for_status(timeout=60):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            status = json.loads(get(CONSOLE + "/api/status")[2])
            last = status
            editor_up = any(h.get("port") == 5757 and h.get("reachable") for h in status.get("network", []))
            if all(status["engine"]["monitors"].values()) and status.get("document") and editor_up:
                return status
        except Exception as exc:          # not up yet
            last = exc
        time.sleep(2)
    raise SystemExit(f"FAIL: console not ready after {timeout}s: {last}")


def check(cond, msg):
    if not cond:
        raise SystemExit("FAIL: " + msg)
    print("ok  ", msg)


def main():
    s = wait_for_status()
    check(s["demo_mode"] is True, "demo mode is on")
    check(s["capabilities"] == {"control": False, "open_editor": True}, "console is read-only")
    check(len(s["processes"]) >= 3 and len(s["performance"]) == 2, "processes and CPU/RAM are reported")
    check(s["disks"] and s["network"], "disk and network are reported")
    check(s["document"]["total"] == 340.15 and s["document"]["current_level"] == "warning",
          "the document monitor reads the real CSV (340.15, warning)")
    editor_row = next(h for h in s["network"] if h["port"] == 5757)
    check(editor_row["reachable"], "the settings editor row is online (real check)")

    status, ctype, body = get(CONSOLE + "/")
    check(status == 200 and b"Monitoring Console" in body, "console page loads")
    check(get(CONSOLE + "/static/theme.css")[0] == 200, "console static assets load")
    status, ctype, body = get(EDITOR + "/")
    check(status == 200 and b"Settings Editor" in body, "editor page loads")
    check(get(EDITOR + "/web/static/icons.svg")[0] == 200, "editor static assets load")
    settings = json.loads(get(EDITOR + "/api/settings")[2])
    check(settings["_meta"]["version"] == s["version"], "editor and console read the same settings")
    print("PASS: demo container is healthy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
