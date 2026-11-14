"""docker/simulator.py: the stand-in monitors of the Docker demo."""
import json
import shutil
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "docker"))

import simulator as sim  # noqa: E402


class SimulatorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        shutil.copy(ROOT / "monitoring_settings.json", self.tmp)
        (self.tmp / "sample_data").mkdir()
        shutil.copy(ROOT / "sample_data" / "monthly_budget_sample.csv", self.tmp / "sample_data")
        for name, value in (("BASE", self.tmp), ("SETTINGS", self.tmp / "monitoring_settings.json"),
                            ("LOGS", self.tmp / "logs")):
            p = mock.patch.object(sim, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.cfg = json.loads((self.tmp / "monitoring_settings.json").read_text(encoding="utf-8"))

    def test_writes_every_state_file_the_console_reads(self):
        with mock.patch.object(sim, "tcp_ok", return_value=False):
            sim.Simulator().tick()
        for name in ("process", "performance", "disk", "network", "document"):
            data = json.loads((self.tmp / "logs" / f"{name}_state.json").read_text(encoding="utf-8"))
            datetime.strptime(data["updated"], sim.FMT)       # same timestamp format as the monitors
        self.assertFalse(list((self.tmp / "logs").glob("*.tmp")), "writes are atomic")

    def docs(self):
        return {d["display_name"]: d for d in sim.Simulator().documents(self.cfg, datetime.now())["documents"]}

    def test_document_uses_the_real_csv_and_thresholds(self):
        doc = self.docs()["Groceries spend (monthly budget)"]
        self.assertEqual((doc["total"], doc["percent_of_target"], doc["current_level"]), (340.15, 85.0, "warning"))
        self.cfg["document"][0]["target"] = 300
        self.assertEqual(self.docs()["Groceries spend (monthly budget)"]["current_level"], "critical")

    def test_every_shipped_document_is_reported(self):
        docs = self.docs()
        self.assertEqual(len(docs), len(self.cfg["document"]))
        self.assertEqual(docs["Eating out spend (monthly budget)"]["current_level"], "ok")
        self.assertTrue(all(d["error"] is None for d in docs.values()))

    def test_document_explains_excel_files(self):
        self.cfg["document"][0]["path"] = "sample_data\\book.xlsx"
        self.assertIn("CSV documents only", self.docs()["Groceries spend (monthly budget)"]["error"])

    def test_file_size_reads_the_real_file(self):
        log = self.tmp / "logs" / "monitor.log"
        log.parent.mkdir(exist_ok=True)
        log.write_bytes(b"x" * (2 * 1024 * 1024))           # 2 MB of a 50 MB target: 4 %
        doc = self.docs()["Monitor log size"]
        self.assertEqual((doc["total"], doc["unit"], doc["percent_of_target"], doc["current_level"]),
                         (2.0, "MB", 4.0, "ok"))
        self.cfg["document"][2]["target"] = 2.2              # 2 MB is now 90.9 %: warning
        self.assertEqual(self.docs()["Monitor log size"]["current_level"], "warning")

    def test_file_size_counts_a_missing_file_as_zero(self):
        doc = self.docs()["Monitor log size"]
        self.assertEqual((doc["total"], doc["current_level"], doc["error"]), (0.0, "ok", None))
        self.assertIn("not created yet", doc["note"])

    def test_v16_single_document_object_still_works(self):
        self.cfg["document"] = self.cfg["document"][0]
        self.assertEqual(list(self.docs()), ["Groceries spend (monthly budget)"])

    def test_notepad_is_the_only_process_that_stops(self):
        s = sim.Simulator()
        s.started -= 120            # inside the 50 s "closed" window of the 150 s cycle
        procs = {p["name"]: p for p in s.processes(self.cfg, datetime.now())["processes"]}
        self.assertFalse(procs["notepad.exe"]["is_running"])
        self.assertTrue(procs["explorer.exe"]["is_running"] and procs["dwm.exe"]["is_running"])

    def test_levels_follow_the_configured_thresholds(self):
        cpu = self.cfg["performance"]["cpu"]["thresholds"]
        self.assertEqual(sim.level_for(50, cpu, "percent"), "ok")
        self.assertEqual(sim.level_for(85, cpu, "percent"), "warning")
        self.assertEqual(sim.level_for(97, cpu, "percent"), "critical")

    def test_localhost_targets_are_checked_for_real(self):
        with mock.patch.object(sim, "tcp_ok", return_value=False) as probe:
            hosts = sim.Simulator().network(self.cfg, datetime.now())["hosts"]
        editor = next(h for h in hosts if h["port"] == 5757)
        self.assertFalse(editor["reachable"])
        self.assertEqual(editor["current_level"], "warning")
        self.assertTrue(any(call.args[1] == 5757 for call in probe.call_args_list))


if __name__ == "__main__":
    unittest.main()
