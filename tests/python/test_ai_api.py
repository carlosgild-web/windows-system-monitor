"""The console's /api/ai/* routes (A4) and /tickets/<number>: same-origin checks, one run
at a time, polling a run to the end. The assistant is off in these settings, so the
rule-based client answers and no Ollama is needed."""
import copy
import http.client
import json
import shutil
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime
from http.server import HTTPServer
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "MonitoringConsole"))

import monitoring_console as mc  # noqa: E402
from ai import FakeClient, ChatTurn  # noqa: E402
from ai.factory import ClientChoice  # noqa: E402
from ai.service import AssistantService  # noqa: E402
from ai import OllamaError  # noqa: E402
from ai.factory import choose_client as ai_choose  # noqa: E402

SHIPPED = json.loads((ROOT / "monitoring_settings.json").read_text(encoding="utf-8-sig"))
CPU = "performance:cpu:critical"


def write_project(tmp: Path) -> None:
    logs = tmp / "logs"
    (logs / "tickets").mkdir(parents=True)
    cfg = copy.deepcopy(SHIPPED)
    cfg["global"]["log_file"] = str(logs / "monitor.log")
    (tmp / "settings.json").write_text(json.dumps(cfg), encoding="utf-8")
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    perf = {"updated": now, "metrics": [{"name": "cpu", "current_value": 97.2, "current_level": "critical"}],
            "incidents": [{"id": CPU, "monitor": "performance", "target": "cpu", "level": "critical",
                           "opened_at": now, "exceeded_since": now, "sustain_sec": 60, "threshold": 95,
                           "peak": 98.4, "last_value": 97.2, "alert_count": 1}]}
    (logs / "performance_state.json").write_text(json.dumps(perf), encoding="utf-8-sig")
    (logs / "monitor.log").write_text(f"[{now}] CRITICAL CPU: 97.2% sustained 60s (threshold: 95%)\n", encoding="utf-8")
    (logs / "tickets" / "INC0010001.html").write_text("<!doctype html><title>INC0010001</title>", encoding="utf-8")


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        write_project(self.tmp)
        self.svc = AssistantService(self.tmp / "settings.json", self.tmp / "logs", run_in_thread=False)

    def test_runs_to_the_end_and_the_trace_can_be_read(self):
        status, body = self.svc.start("explain", {"incident_id": CPU})
        self.assertEqual(status, 202)
        self.assertEqual(body["client"]["label"], "Demo (rules, no AI)")
        status, got = self.svc.get_run(body["run_id"])
        self.assertEqual((status, got["run"]["status"]), (200, "done"))
        self.assertIn("98.4", got["run"]["answer"])

    def test_rejects_bad_requests(self):
        for body, code in ((None, 400), ([], 400), ({}, 400), ({"incident_id": 5}, 400),
                           ({"incident_id": "x`y"}, 400), ({"incident_id": CPU, "language": "fr"}, 400),
                           ({"incident_id": "performance:memory:critical"}, 404)):
            self.assertEqual(self.svc.start("explain", body)[0], code, body)
        self.assertEqual(self.svc.start("stop_monitors", {"incident_id": CPU})[0], 404)
        self.assertEqual(self.svc.get_run("../../monitoring_settings")[0], 404)

    def test_one_run_at_a_time(self):
        gate = threading.Event()

        class Slow(FakeClient):
            def chat(self, *a, **kw):
                gate.wait(5)
                return ChatTurn(content="What happened\n- CPU critical.")

        svc = AssistantService(self.tmp / "settings.json", self.tmp / "logs",
                               chooser=lambda s, demo_mode: ClientChoice(Slow(), "test"))
        status, first = svc.start("explain", {"incident_id": CPU})
        self.assertEqual(status, 202)
        status, second = svc.start("ticket", {"incident_id": CPU})
        self.assertEqual((status, second["run_id"]), (409, first["run_id"]))
        gate.set()
        for _ in range(100):
            if svc.get_run(first["run_id"])[1]["run"]["status"] != "running":
                break
            time.sleep(0.05)
        self.assertEqual(svc.get_run(first["run_id"])[1]["run"]["status"], "done")
        self.assertEqual(svc.start("ticket", {"incident_id": CPU})[0], 202, "free again")

    def test_status_reports_the_rules_while_the_assistant_is_off(self):
        status, body = self.svc.status()
        self.assertEqual((status, body["enabled"], body["client"]["kind"]), (200, False, "demo"))
        self.assertIn("ai.enabled is false", body["client"]["reason"])

    def test_the_docker_demo_always_uses_the_rules(self):
        cfg = json.loads((self.tmp / "settings.json").read_text(encoding="utf-8"))
        cfg["ai"]["enabled"] = True
        (self.tmp / "settings.json").write_text(json.dumps(cfg), encoding="utf-8")
        svc = AssistantService(self.tmp / "settings.json", self.tmp / "logs", demo_mode=True)
        self.assertEqual(svc.status()[1]["client"]["kind"], "demo")


class DockerDemoTests(unittest.TestCase):
    """A7: the Docker demo answers with rules, unless the compose profile "ai" runs Ollama."""

    def options(self, demo_mode, windows, url):
        with mock.patch.object(mc, "DEMO_MODE", demo_mode), mock.patch.object(mc, "IS_WINDOWS", windows), \
             mock.patch.object(mc, "DEMO_OLLAMA_URL", url), mock.patch.object(mc, "DEMO_AI_MODEL", "qwen2.5:3b"):
            return mc.assistant_options()

    def test_windows_uses_the_settings_and_ignores_the_demo_variable(self):
        self.assertEqual(self.options(False, True, "http://ollama:11434"), {"demo_mode": False})

    def test_the_demo_without_an_ollama_url_uses_rules(self):
        self.assertEqual(self.options(True, False, ""), {"demo_mode": True})

    def test_the_demo_with_the_ai_profile_points_at_the_container(self):
        opts = self.options(True, False, "http://ollama:11434")
        self.assertFalse(opts["demo_mode"])
        self.assertEqual(opts["ai_overrides"]["ollama_url"], "http://ollama:11434")
        self.assertIn("--profile ai", opts["unavailable_hint"])

    def test_overrides_reach_the_client_choice_but_not_the_settings_file(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        write_project(tmp)
        before = (tmp / "settings.json").read_text(encoding="utf-8")
        seen = {}

        def chooser(settings, demo_mode):
            seen.update(settings=settings, demo_mode=demo_mode)
            return ai_choose(settings, demo_mode=demo_mode, probe=lambda c: (_ for _ in ()).throw(
                OllamaError("Ollama is not reachable at http://ollama:11434: name not resolved", retryable=True)))

        opts = self.options(True, False, "http://ollama:11434")
        svc = AssistantService(tmp / "settings.json", tmp / "logs", chooser=chooser, **opts)
        body = svc.status()[1]
        s = seen["settings"]
        self.assertEqual((s.enabled, s.ollama_url, s.allow_remote, s.model, seen["demo_mode"]),
                         (True, "http://ollama:11434", True, "qwen2.5:3b", False))
        self.assertEqual(body["client"]["kind"], "demo", "no Ollama container: rules")
        self.assertIn("docker compose --profile ai up", body["client"]["reason"])
        self.assertEqual((tmp / "settings.json").read_text(encoding="utf-8"), before)

    def test_the_compose_file_keeps_ollama_private(self):
        compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        ollama = compose.split("  ollama:")[1].split("  ollama-pull:")[0]
        self.assertNotIn("ports", ollama, "the Ollama container must not publish a port")
        self.assertIn('profiles: ["ai"]', ollama)
        self.assertRegex(ollama, r"image: ollama/ollama:\$\{OLLAMA_IMAGE_TAG:-\d+\.\d+\.\d+\}", "a pinned default")


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        write_project(self.tmp)
        logs = self.tmp / "logs"
        patches = {"SETTINGS_FILE": self.tmp / "settings.json", "LOGS_DIR": logs,
                   "STATE_FILE": logs / "process_state.json", "PERF_STATE_FILE": logs / "performance_state.json",
                   "DISK_STATE_FILE": logs / "disk_state.json", "NET_STATE_FILE": logs / "network_state.json",
                   "DOC_STATE_FILE": logs / "document_state.json", "_assistant": None}
        for name, value in patches.items():
            p = mock.patch.object(mc, name, value)
            p.start()
            self.addCleanup(p.stop)
        live = mock.patch.object(mc, "check_running", return_value=None)
        live.start()
        self.addCleanup(live.stop)
        self.httpd = HTTPServer(("localhost", 0), mc.Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.me = f"http://localhost:{self.port}"

    def request(self, method, path, body=None, host=None, origin=None, ctype="application/json"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        data = json.dumps(body).encode() if body is not None else b""
        headers = {"Host": host or f"localhost:{self.port}", "Content-Length": str(len(data))}
        if origin:
            headers["Origin"] = origin
        if ctype and method == "POST":
            headers["Content-Type"] = ctype
        conn.request(method, path, body=data, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        conn.close()
        try:
            return resp.status, json.loads(raw)
        except ValueError:
            return resp.status, raw

    def traces(self):
        return list((self.tmp / "logs" / "ai_traces").glob("*.json"))

    def test_other_websites_and_rebinding_hosts_are_rejected(self):
        for route in ("/api/ai/explain", "/api/ai/ticket-draft"):
            self.assertEqual(self.request("POST", route, {"incident_id": CPU}, origin="http://evil.example")[0], 403)
            self.assertEqual(self.request("POST", route, {"incident_id": CPU}, host=f"evil.example:{self.port}")[0], 403)
        for route in ("/api/ai/status", "/api/ai/runs/20261128-100000-00000000", "/tickets/INC0010001"):
            self.assertEqual(self.request("GET", route, host=f"evil.example:{self.port}")[0], 403, route)
        self.assertEqual(self.traces(), [], "no run was started")

    def test_a_form_post_without_json_is_refused(self):
        status, _ = self.request("POST", "/api/ai/explain", {"incident_id": CPU}, origin=self.me,
                                 ctype="application/x-www-form-urlencoded")
        self.assertEqual(status, 415)
        self.assertEqual(self.traces(), [])

    def test_explain_then_poll_the_run(self):
        status, body = self.request("POST", "/api/ai/explain", {"incident_id": CPU}, origin=self.me)
        self.assertEqual(status, 202, body)
        run = None
        for _ in range(100):
            status, got = self.request("GET", f"/api/ai/runs/{body['run_id']}")
            run = got["run"]
            if run["status"] != "running":
                break
            time.sleep(0.05)
        self.assertEqual(run["status"], "done", run.get("error"))
        self.assertTrue(run["check"]["ok"])
        self.assertTrue(any(s["type"] == "tool" for s in run["steps"]))

    def test_ticket_draft_has_code_owned_fields(self):
        status, body = self.request("POST", "/api/ai/ticket-draft", {"incident_id": CPU}, origin=self.me)
        self.assertEqual(status, 202, body)
        for _ in range(100):
            run = self.request("GET", f"/api/ai/runs/{body['run_id']}")[1]["run"]
            if run["status"] != "running":
                break
            time.sleep(0.05)
        self.assertEqual((run["ticket"]["priority"], run["ticket"]["assignment_group"]),
                         ("1 - Critical", "Server Operations"))

    def test_unknown_routes_and_runs(self):
        self.assertEqual(self.request("POST", "/api/ai/stop_monitors", {"incident_id": CPU}, origin=self.me)[0], 404)
        self.assertEqual(self.request("GET", "/api/ai/runs/..%2F..%2Fmonitoring_settings")[0], 404)
        self.assertEqual(self.request("GET", "/api/ai/status")[1]["client"]["label"], "Demo (rules, no AI)")

    def test_status_lists_open_incidents(self):
        status, body = self.request("GET", "/api/status")
        self.assertEqual([i["id"] for i in body["incidents"]], [CPU])

    def test_the_console_serves_a_monitors_ticket_and_nothing_else(self):
        status, page = self.request("GET", "/tickets/INC0010001")
        self.assertEqual(status, 200)
        self.assertIn(b"INC0010001", page)
        for bad in ("/tickets/INC0010002", "/tickets/..%2Fmonitor.log", "/tickets/INC001", "/tickets/next_number"):
            self.assertEqual(self.request("GET", bad)[0], 404, bad)


if __name__ == "__main__":
    unittest.main()
