"""The console off Windows (the Docker demo): read-only, no Windows tools, nothing spawned."""
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "MonitoringConsole"))

import monitoring_console as mc  # noqa: E402
import server  # noqa: E402


class OffWindowsConsoleTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(mc, "IS_WINDOWS", False)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_no_live_process_check(self):
        with mock.patch.object(mc.subprocess, "run") as run:
            self.assertIsNone(mc.check_running("explorer.exe"))
        run.assert_not_called()

    def test_monitors_cannot_be_started_or_stopped(self):
        with mock.patch.object(mc.subprocess, "Popen") as popen, mock.patch.object(mc.subprocess, "run") as run:
            for fn in (mc.stop_monitor, mc.start_monitor):
                result = fn("disk")
                self.assertFalse(result["ok"])
                self.assertIn("Windows", result["error"])
        popen.assert_not_called()
        run.assert_not_called()

    def test_editor_is_probed_on_the_configured_host_and_never_spawned(self):
        with mock.patch.object(mc, "EDITOR_HOST", "editor"), \
             mock.patch.object(mc, "_port_open", return_value=True) as probe, \
             mock.patch.object(mc.subprocess, "Popen") as popen:
            self.assertEqual(mc.open_editor()["url"], "http://localhost:5757")
        self.assertEqual(probe.call_args.kwargs["host"], "editor")
        with mock.patch.object(mc, "_port_open", return_value=False), mock.patch.object(mc.subprocess, "Popen") as popen:
            self.assertFalse(mc.open_editor()["ok"])
        popen.assert_not_called()

    def test_status_reports_the_capabilities(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        with mock.patch.object(mc, "SETTINGS_FILE", tmp / "missing.json"), \
             mock.patch.object(mc, "STATE_FILE", tmp / "p.json"), \
             mock.patch.object(mc, "DEMO_MODE", True):
            status = mc.get_status()
        self.assertEqual(status["capabilities"], {"control": False, "open_editor": True})
        self.assertTrue(status["demo_mode"])


class OffWindowsEditorTests(unittest.TestCase):
    def test_open_file_explains_instead_of_crashing(self):
        source = (ROOT / "server.py").read_text(encoding="utf-8")
        self.assertIn('not hasattr(os, "startfile")', source)

    def test_bind_host_defaults_to_localhost(self):
        self.assertEqual(server.BIND_HOST, "localhost")
        self.assertEqual(mc.BIND_HOST, "localhost")


if __name__ == "__main__":
    unittest.main()
