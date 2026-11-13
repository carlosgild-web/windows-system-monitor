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

    def test_document_uses_the_real_csv_and_thresholds(self):
        doc = sim.Simulator().document(self.cfg, datetime.now())
        self.assertEqual((doc["total"], doc["percent_of_target"], doc["current_level"]), (340.15, 85.0, "warning"))
        self.cfg["document"]["target"] = 300
        self.assertEqual(sim.Simulator().document(self.cfg, datetime.now())["current_level"], "critical")

    def test_document_explains_excel_files(self):
        self.cfg["document"]["path"] = "sample_data\\book.xlsx"
        self.assertIn("CSV documents only", sim.Simulator().document(self.cfg, datetime.now())["error"])

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
