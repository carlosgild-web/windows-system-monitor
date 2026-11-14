"""Tests for MonitoringConsole/monitoring_console.py status merging.

get_status() combines monitoring_settings.json, the monitors' state files
and a live tasklist check. These tests point the module at temporary files
and stub the live check, so no real processes are inspected.
"""
import json
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "MonitoringConsole"))

import monitoring_console as mc  # noqa: E402

FMT = "%Y-%m-%d %H:%M:%S"


def ts(seconds_ago=0):
    return (datetime.now() - timedelta(seconds=seconds_ago)).strftime(FMT)


class GetStatusTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.files = {
            "SETTINGS_FILE": self.tmp / "settings.json",
            "STATE_FILE": self.tmp / "process_state.json",
            "PERF_STATE_FILE": self.tmp / "performance_state.json",
            "DISK_STATE_FILE": self.tmp / "disk_state.json",
            "NET_STATE_FILE": self.tmp / "network_state.json",
            "DOC_STATE_FILE": self.tmp / "document_state.json",
        }
        self.patches = [mock.patch.object(mc, k, v) for k, v in self.files.items()]
        self.live = mock.patch.object(mc, "check_running", return_value=None)
        self.patches.append(self.live)
        for p in self.patches:
            p.start()
        self.write("SETTINGS_FILE", {
            "_meta": {"version": "9.9.9"},
            "global": {"check_interval_sec": 6},
            "processes": [
                {"name": "app.exe", "display_name": "App", "check_interval_sec": 30,
                 "actions": {"on_not_running": [
                     {"type": "log_to_file", "level": "warning", "instructions": "Restart App."}]}},
            ],
            "performance": {"cpu": {"check_interval_sec": 5}},
            "disk": [{"drive": "C:\\", "check_interval_sec": 60}],
            "network": [{"name": "gw", "check_interval_sec": 30}],
            "document": [
                {"display_name": "Budget", "check_interval_sec": 30, "path": "sample_data\\budget.csv", "target": 400},
                {"display_name": "Log", "measure": "file_size", "check_interval_sec": 60, "path": "logs\\monitor.log",
                 "size_unit": "MB", "target": 50},
            ],
        })

    def tearDown(self):
        for p in self.patches:
            p.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, key, data):
        # The PowerShell monitors write UTF-8 with a BOM; mimic that.
        self.files[key].write_text(json.dumps(data), encoding="utf-8-sig")

    def process_state(self, seconds_ago, running, down_since=None):
        self.write("STATE_FILE", {
            "updated": ts(seconds_ago), "monitor_pid": 1234,
            "processes": [{"name": "app.exe", "is_running": running,
                           "down_since": down_since, "alert_count": 3, "last_check": ts(seconds_ago)}],
        })

    # ── resilience ───────────────────────────────────────────────────────────
    def test_no_state_files_does_not_crash(self):
        status = mc.get_status()
        self.assertFalse(status["engine"]["ok"])
        self.assertTrue(all(v is False for v in status["engine"]["monitors"].values()))
        self.assertEqual(status["documents"], [])
        self.assertEqual(status["version"], "9.9.9")

    def test_settings_saved_with_bom_are_read(self):
        # setUp writes the settings with a UTF-8 BOM (as PowerShell's
        # Set-Content -Encoding UTF8 does); the config must still load.
        status = mc.get_status()
        self.assertEqual(status["config"]["meta"]["version"], "9.9.9")
        self.assertEqual(len(status["processes"]), 1)

    def test_corrupt_state_file_is_ignored(self):
        self.files["PERF_STATE_FILE"].write_text("{ not json", encoding="utf-8")
        self.assertFalse(mc.get_status()["engine"]["monitors"]["performance"])

    # ── freshness ────────────────────────────────────────────────────────────
    def test_fresh_state_files_mark_monitors_alive(self):
        self.process_state(5, True)
        for key in ("PERF_STATE_FILE", "DISK_STATE_FILE", "NET_STATE_FILE", "DOC_STATE_FILE"):
            self.write(key, {"updated": ts(2)})
        monitors = mc.get_status()["engine"]["monitors"]
        self.assertTrue(all(monitors.values()), monitors)

    def test_stale_process_state_marks_monitor_down(self):
        # Limit is 2 x 30s + 15s = 75s.
        self.process_state(200, True)
        status = mc.get_status()
        self.assertFalse(status["engine"]["monitors"]["process"])
        self.assertEqual(status["engine"]["pid"], 1234)

    def test_document_state_and_config_are_passed_through(self):
        self.write("DOC_STATE_FILE", {"updated": ts(3), "documents": [
            {"display_name": "Budget", "total": 340.15, "target": 400, "percent_of_target": 85.0, "current_level": "warning"},
            {"display_name": "Log", "measure": "file_size", "total": 1.25, "unit": "MB", "current_level": "ok"},
        ]})
        status = mc.get_status()
        self.assertTrue(status["engine"]["monitors"]["document"])
        self.assertEqual([d["current_level"] for d in status["documents"]], ["warning", "ok"])
        self.assertEqual([d["target"] for d in status["config"]["document"]], [400, 50])

    def test_v16_single_document_state_and_config_become_lists(self):
        settings = json.loads(self.files["SETTINGS_FILE"].read_text(encoding="utf-8-sig"))
        settings["document"] = settings["document"][0]
        self.write("SETTINGS_FILE", settings)
        self.write("DOC_STATE_FILE", {"updated": ts(3), "display_name": "Budget", "total": 10, "current_level": "ok"})
        status = mc.get_status()
        self.assertEqual(status["documents"][0]["display_name"], "Budget")
        self.assertEqual(len(status["config"]["document"]), 1)

    def test_document_freshness_uses_the_shortest_interval(self):
        # Shortest interval 30s: limit 2 x 30 + 20 = 80s.
        self.write("DOC_STATE_FILE", {"updated": ts(70), "documents": []})
        self.assertTrue(mc.get_status()["engine"]["monitors"]["document"])
        self.write("DOC_STATE_FILE", {"updated": ts(100), "documents": []})
        self.assertFalse(mc.get_status()["engine"]["monitors"]["document"])

    def test_stale_performance_state_marks_monitor_down(self):
        self.write("PERF_STATE_FILE", {"updated": ts(600)})
        self.assertFalse(mc.get_status()["engine"]["monitors"]["performance"])

    # ── process merging ──────────────────────────────────────────────────────
    def test_process_fields_come_from_config_and_state(self):
        self.process_state(5, False, down_since=ts(120))
        proc = mc.get_status()["processes"][0]
        self.assertEqual(proc["display_name"], "App")
        self.assertFalse(proc["is_running"])
        self.assertEqual(proc["alert_count"], 3)
        self.assertEqual(proc["instructions"], "Restart App.")
        self.assertEqual(proc["actions"], ["log_to_file"])
        self.assertGreaterEqual(proc["down_sec"], 119)

    def test_live_check_overrides_state_when_engine_is_fresh(self):
        self.process_state(5, False, down_since=ts(60))
        self.live.target.check_running.return_value = True
        status = mc.get_status()
        self.assertTrue(status["processes"][0]["is_running"])
        self.assertEqual(status["running_count"], 1)
        self.assertIsNone(status["processes"][0]["down_sec"])

    def test_live_check_skipped_when_engine_is_stale(self):
        self.process_state(500, False)
        mc.get_status()
        mc.check_running.assert_not_called()


class AllMonitorsTests(unittest.TestCase):
    """The banner's Start / Stop monitoring buttons."""

    def setUp(self):
        for name, value in (("IS_WINDOWS", True), ("_log_action", mock.Mock())):
            p = mock.patch.object(mc, name, value)
            p.start()
            self.addCleanup(p.stop)

    def test_start_all_only_starts_the_missing_monitors(self):
        with mock.patch.object(mc, "running_monitors", return_value={"process", "disk"}), \
             mock.patch.object(mc.subprocess, "Popen") as popen:
            result = mc.start_all()
        self.assertTrue(result["ok"])
        self.assertEqual(sorted(result["started"]), ["document", "network", "performance"])
        self.assertEqual(result["already_running"], ["disk", "process"])
        launched = [c.args[0][-1] for c in popen.call_args_list]
        self.assertEqual(sorted(Path(p).stem for p in launched),
                         ["monitor_document", "monitor_network", "performance_monitor"])
        self.assertTrue(all("Hidden" in c.args[0] for c in popen.call_args_list))

    def test_stop_all_targets_every_monitor_but_not_the_console(self):
        with mock.patch.object(mc.subprocess, "Popen") as popen:
            self.assertTrue(mc.stop_all()["ok"])
        cmd = popen.call_args.args[0][-1]
        for path in mc.MONITOR_SCRIPTS.values():
            self.assertIn(path.stem, cmd)
        self.assertNotIn("monitoring_console", cmd)
        self.assertNotIn("server", cmd)

    def test_running_monitors_only_counts_this_install(self):
        scripts = mc.MONITOR_SCRIPTS
        out = (f'powershell.exe -File "{scripts["disk"]}"\n'
               f'powershell.exe -File "{str(scripts["process"]).upper()}"\n'
               "powershell.exe -File C:\\other-copy\\scripts\\monitor_network.ps1\n"
               "powershell.exe -NoProfile -Command something else\n")
        with mock.patch.object(mc.subprocess, "run", return_value=mock.Mock(stdout=out)):
            self.assertEqual(mc.running_monitors(), {"disk", "process"})

    def test_stop_all_matches_full_paths_so_other_installs_keep_running(self):
        with mock.patch.object(mc.subprocess, "Popen") as popen:
            mc.stop_all()
        cmd = popen.call_args.args[0][-1]
        for path in mc.MONITOR_SCRIPTS.values():
            self.assertIn(str(path).lower(), cmd)
        self.assertNotIn("-match", cmd)
        self.assertNotIn("-like", cmd)

    def test_off_windows_nothing_is_started_or_stopped(self):
        with mock.patch.object(mc, "IS_WINDOWS", False), mock.patch.object(mc.subprocess, "Popen") as popen, \
             mock.patch.object(mc.subprocess, "run") as run:
            for fn in (mc.start_all, mc.stop_all):
                result = fn()
                self.assertFalse(result["ok"])
                self.assertIn("Windows", result["error"])
        popen.assert_not_called()
        run.assert_not_called()


class AllMonitorsHttpTests(unittest.TestCase):
    def setUp(self):
        import threading
        from http.server import HTTPServer
        self.httpd = HTTPServer(("localhost", 0), mc.Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def post(self, path, origin):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("POST", path, body=b"",
                     headers={"Host": f"localhost:{self.port}", "Origin": origin, "Content-Length": "0"})
        resp = conn.getresponse()
        body = json.loads(resp.read())
        conn.close()
        return resp.status, body

    def test_rejects_other_websites(self):
        with mock.patch.object(mc, "stop_all") as stop_all, mock.patch.object(mc, "start_all") as start_all:
            for action in ("start", "stop"):
                status, _ = self.post(f"/api/monitors/{action}", "http://evil.example")
                self.assertEqual(status, 403)
        stop_all.assert_not_called()
        start_all.assert_not_called()

    def test_same_origin_routes_to_start_and_stop(self):
        with mock.patch.object(mc, "start_all", return_value={"ok": True, "started": ["disk"]}), \
             mock.patch.object(mc, "stop_all", return_value={"ok": True}):
            self.assertEqual(self.post("/api/monitors/start", f"http://localhost:{self.port}")[1]["started"], ["disk"])
            self.assertTrue(self.post("/api/monitors/stop", f"http://localhost:{self.port}")[1]["ok"])


class HelperTests(unittest.TestCase):
    def test_as_list(self):
        self.assertEqual(mc.as_list([{"a": 1}, None]), [{"a": 1}])
        self.assertEqual(mc.as_list({"a": 1}), [{"a": 1}])
        self.assertEqual(mc.as_list(None), [])
        self.assertEqual(mc.as_list({}), [])

    def test_resolve_project_path(self):
        self.assertEqual(mc.resolve_project_path("logs/monitor.log"), (mc.BASE / "logs/monitor.log").resolve())
        absolute = Path("C:/ops/monitor.log")
        self.assertEqual(mc.resolve_project_path(str(absolute)), absolute)

    def test_same_origin_rules(self):
        self.assertTrue(mc.is_same_origin({"Host": "localhost:5758"}, 5758))
        self.assertTrue(mc.is_same_origin({"Host": "127.0.0.1:5758", "Origin": "http://127.0.0.1:5758"}, 5758))
        self.assertFalse(mc.is_same_origin({"Host": "localhost:5758", "Origin": "https://evil.example"}, 5758))
        self.assertFalse(mc.is_same_origin({"Host": "evil.example:5758"}, 5758))


if __name__ == "__main__":
    unittest.main()
