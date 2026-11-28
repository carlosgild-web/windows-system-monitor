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


def post(url, body=None):
    """Same-origin POST, as the console page sends it."""
    data = json.dumps(body).encode() if body is not None else b""
    headers = {"Origin": CONSOLE}
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method="POST", headers=headers)
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())


def assistant_run(task, incident_id, timeout=30):
    """Starts an assistant run and polls it to the end, as the console page will."""
    run_id = post(CONSOLE + "/api/ai/" + task, {"incident_id": incident_id})["run_id"]
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        run = json.loads(get(CONSOLE + "/api/ai/runs/" + run_id)[2])["run"]
        if run["status"] != "running":
            return run
        time.sleep(0.5)
    raise SystemExit(f"FAIL: assistant run {run_id} still running after {timeout}s")


def wait_for_status(timeout=60):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            status = json.loads(get(CONSOLE + "/api/status")[2])
            last = status
            editor_up = any(h.get("port") == 5757 and h.get("reachable") for h in status.get("network", []))
            if all(status["engine"]["monitors"].values()) and status.get("documents") and editor_up:
                return status
        except Exception as exc:          # not up yet
            last = exc
        time.sleep(2)
    raise SystemExit(f"FAIL: console not ready after {timeout}s: {last}")


def check(cond, msg):
    if not cond:
        raise SystemExit("FAIL: " + msg)
    print("ok  ", msg)


def main_ai():
    """--ai: the demo started with --profile ai answers with the Ollama container's model."""
    s = wait_for_status()
    ai = json.loads(get(CONSOLE + "/api/ai/status")[2])
    check(ai["client"]["kind"] == "ollama", f"the assistant uses the Ollama container ({ai['client']['reason']})")
    doc = next(i for i in s["incidents"] if i["monitor"] == "document")
    run = assistant_run("explain", doc["id"], timeout=600)
    check(run["status"] == "done" and run["client"]["kind"] == "ollama",
          f"Explain answered by {run['client']['label']} in {run['usage']['model_calls']} model calls")
    print(run["answer"])
    print("PASS: the demo container's assistant runs on a local model")
    return 0


def main():
    if "--ai" in sys.argv:
        return main_ai()
    s = wait_for_status()
    check(s["demo_mode"] is True, "demo mode is on")
    check(s["capabilities"] == {"control": False, "open_editor": True}, "console is read-only")
    check(len(s["processes"]) >= 3 and len(s["performance"]) == 2, "processes and CPU/RAM are reported")
    check(s["disks"] and s["network"], "disk and network are reported")
    docs = {d["display_name"]: d for d in s["documents"]}
    groceries = docs.get("Groceries spend (monthly budget)", {})
    check(groceries.get("total") == 340.15 and groceries.get("current_level") == "warning",
          "the document monitor reads the real CSV (340.15, warning)")
    check(docs.get("Eating out spend (monthly budget)", {}).get("current_level") == "ok",
          "the second budget document is reported (ok)")
    log_size = docs.get("Monitor log size", {})
    check(log_size.get("measure") == "file_size" and log_size.get("error") is None and log_size.get("unit") == "MB",
          "the file-size document is reported")
    editor_row = next(h for h in s["network"] if h["port"] == 5757)
    check(editor_row["reachable"], "the settings editor row is online (real check)")

    doc_incident = next((i for i in s.get("incidents", []) if i["monitor"] == "document"), None)
    check(doc_incident is not None and doc_incident["level"] == "warning",
          "the state files list open incidents (the groceries warning)")
    ai = json.loads(get(CONSOLE + "/api/ai/status")[2])
    check(ai["client"]["label"] == "Demo (rules, no AI)", "the assistant runs on rules in the container")
    run = assistant_run("explain", doc_incident["id"])
    check(run["status"] == "done" and run["check"]["ok"] and "340.15" in json.dumps(run["steps"]),
          "Explain answers from the tool results, every number traced")
    run = assistant_run("ticket-draft", doc_incident["id"])
    check(run["status"] == "done" and run["ticket"]["priority"] == "3 - Moderate",
          "the AI ticket draft keeps the code-owned priority")

    stop = post(CONSOLE + "/api/monitors/stop")
    check(stop["ok"] is False and "Windows" in stop["error"], "the banner's stop monitoring is refused in the container")

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
