#!/usr/bin/env python3
"""Container entry point: runs the simulator, the settings editor and the console together.

One container keeps the three sharing the same files: the editor writes
monitoring_settings.json, and the simulator and the console read it on their next cycle.
If any of them exits, the others are stopped and the container exits with its code.
"""
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
# Servers first, so the simulator's first network check already finds them listening.
CHILDREN = [
    ("editor", [sys.executable, str(BASE / "server.py"), "--no-browser"]),
    ("console", [sys.executable, str(BASE / "MonitoringConsole" / "monitoring_console.py")]),
    ("simulator", [sys.executable, str(BASE / "docker" / "simulator.py")]),
]


def main():
    os.environ.setdefault("BIND_HOST", "0.0.0.0")
    os.environ.setdefault("NO_BROWSER", "1")
    os.environ.setdefault("DEMO_MODE", "1")
    procs = {name: subprocess.Popen(cmd, cwd=str(BASE)) for name, cmd in CHILDREN}
    print("Windows System Monitor demo: console http://localhost:5758 | editor http://localhost:5757", flush=True)

    def stop(*_):
        for p in procs.values():
            if p.poll() is None:
                p.terminate()
        for p in procs.values():
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()

    signal.signal(signal.SIGTERM, lambda *a: (stop(), sys.exit(0)))
    signal.signal(signal.SIGINT, lambda *a: (stop(), sys.exit(0)))
    while True:
        for name, p in procs.items():
            code = p.poll()
            if code is not None:
                print(f"{name} exited with code {code}; stopping the demo", flush=True)
                stop()
                sys.exit(code or 1)
        time.sleep(1)


if __name__ == "__main__":
    main()
