#!/usr/bin/env python3
"""Simulated monitors for the Docker demo (standard library only).

The real monitors are Windows PowerShell scripts that read perf counters, WMI and the
desktop; none of that exists inside a Linux container. This script stands in for them:
every few seconds it writes the same logs/*_state.json files they write, so the real
console and editor can be shown on any OS.

What is real and what is simulated:
- Read from monitoring_settings.json every cycle (edit it in the editor and the demo follows):
  the processes, metrics, drives, hosts and thresholds.
- Real: the document monitor reads the actual CSV (or the file size) and applies its thresholds; localhost
  network targets (the console and the editor in this container) are real TCP checks.
- Simulated: CPU and memory (a random walk with occasional spikes), disk usage, public
  host latency, and Notepad, which "closes" for a while every couple of minutes.
"""
import csv
import io
import json
import math
import os
import random
import socket
import time
from datetime import datetime, timedelta
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
SETTINGS = BASE / "monitoring_settings.json"
LOGS = BASE / "logs"
INTERVAL = float(os.environ.get("SIM_INTERVAL_SEC", "3"))
FMT = "%Y-%m-%d %H:%M:%S"
rng = random.Random(os.environ.get("SIM_SEED"))
SIZE_UNITS = {"KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3}


def now_str(t=None):
    return (t or datetime.now()).strftime(FMT)


def write_json(name, data):
    """Write atomically, so the console never reads a half-written file."""
    LOGS.mkdir(parents=True, exist_ok=True)
    tmp = LOGS / (name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    os.replace(tmp, LOGS / name)


def load_settings():
    try:
        return json.loads(SETTINGS.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {}


def level_for(value, thresholds, key):
    """Highest threshold level reached (the monitors' "current level", without sustain)."""
    level = "ok"
    for t in sorted(thresholds or [], key=lambda t: 0 if t.get("level") == "warning" else 1):
        limit = t.get(key)
        if limit is not None and value is not None and value >= limit:
            level = t.get("level", "warning")
    return level


def tcp_ok(host, port, timeout=0.5):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


class Walk:
    """A bounded random walk with occasional spikes."""

    def __init__(self, start, low, high, step, spike_every, spike_to, spike_len):
        self.value, self.low, self.high, self.step = start, low, high, step
        self.spike_every, self.spike_to, self.spike_len = spike_every, spike_to, spike_len
        self.spike_until = 0.0
        self.next_spike = time.monotonic() + rng.uniform(.4, 1.0) * spike_every

    def next(self):
        t = time.monotonic()
        if t >= self.next_spike:
            self.spike_until = t + self.spike_len
            self.next_spike = t + self.spike_every * rng.uniform(.8, 1.3)
        if t < self.spike_until:
            target = self.spike_to + rng.uniform(-2, 2)
            self.value += (target - self.value) * 0.5
        else:
            self.value += rng.uniform(-self.step, self.step) + (((self.low + self.high) / 2) - self.value) * 0.03
        self.value = max(1.0, min(99.5, self.value))
        return round(self.value, 1)


class Simulator:
    def __init__(self):
        self.cpu = Walk(28, 8, 60, 6, spike_every=180, spike_to=96, spike_len=75)
        self.mem = Walk(72, 62, 84, 1.2, spike_every=300, spike_to=93, spike_len=90)
        self.disk_base = {}
        self.proc = {}              # name -> {"running", "down_since", "alerts"}
        self.started = time.monotonic()

    # ---- processes ----------------------------------------------------------------
    def processes(self, cfg, now):
        out = []
        cycle = (time.monotonic() - self.started) % 150
        for p in cfg.get("processes", []):
            name = p.get("name", "")
            st = self.proc.setdefault(name, {"running": True, "down_since": None, "alerts": 0})
            # Notepad (the demo toggle) is closed for 50 s out of every 150 s; the rest keep running.
            running = not (name.lower() == "notepad.exe" and cycle > 100)
            if not running and st["running"]:
                st.update(down_since=now, alerts=0)
            if not running:
                st["alerts"] += 1
            if running:
                st["down_since"] = None
            st["running"] = running
            out.append({
                "name": name, "display_name": p.get("display_name", name), "required": p.get("required", False),
                "is_running": running, "last_check": now_str(now),
                "down_since": now_str(st["down_since"]) if st["down_since"] else None,
                "alert_count": st["alerts"],
            })
        return {"updated": now_str(now), "monitor_pid": os.getpid(), "processes": out}

    # ---- performance ----------------------------------------------------------------
    def performance(self, cfg, now):
        perf = cfg.get("performance", {})
        metrics = []
        for key, label, walk in (("cpu", "CPU", self.cpu), ("memory", "Memory (RAM)", self.mem)):
            if key not in perf:
                continue
            value = walk.next()
            metrics.append({"name": key, "display_name": label, "current_value": value,
                            "current_level": level_for(value, perf[key].get("thresholds"), "percent"),
                            "last_check": now_str(now)})
        return {"updated": now_str(now), "monitor_pid": os.getpid(), "metrics": metrics}

    # ---- disk -------------------------------------------------------------------------
    def disk(self, cfg, now):
        drives = []
        size_gb = 476.0
        for d in cfg.get("disk", []):
            drive = d.get("drive", "C:\\")
            base = self.disk_base.setdefault(drive, rng.uniform(70, 80))
            used = round(base + 2.5 * math.sin(time.monotonic() / 240) + rng.uniform(-.1, .1), 1)
            drives.append({"drive": drive, "display_name": d.get("display_name", drive), "percent_used": used,
                           "free_gb": round(size_gb * (100 - used) / 100, 1),
                           "current_level": level_for(used, d.get("thresholds"), "percent_used"),
                           "last_check": now_str(now)})
        return {"updated": now_str(now), "monitor_pid": os.getpid(), "drives": drives}

    # ---- network ------------------------------------------------------------------------
    def network(self, cfg, now):
        hosts = []
        editor_host = os.environ.get("EDITOR_HOST", "127.0.0.1")
        for h in cfg.get("network", []):
            host, port = h.get("host", ""), h.get("port")
            if host in ("localhost", "127.0.0.1"):
                # This container's own services: a real check.
                probe = editor_host if port == 5757 else "127.0.0.1"
                start = time.monotonic()
                reachable = bool(port) and tcp_ok(probe, port)
                latency = max(1, int((time.monotonic() - start) * 1000)) if reachable else None
            else:
                reachable = rng.random() > 0.01
                latency = int(max(4, rng.gauss(35 if h.get("protocol") == "icmp" else 60, 12))) if reachable else None
            level = "ok"
            for t in sorted(h.get("thresholds", []), key=lambda t: 0 if t.get("level") == "warning" else 1):
                if t.get("condition") == "unreachable" and not reachable:
                    level = t.get("level", "critical")
                elif t.get("latency_ms") is not None and latency is not None and latency >= t["latency_ms"]:
                    level = t.get("level", "warning")
            hosts.append({"name": h.get("name", host), "host": host, "port": port, "protocol": h.get("protocol"),
                          "reachable": reachable, "latency_ms": latency, "current_level": level,
                          "last_check": now_str(now)})
        return {"updated": now_str(now), "monitor_pid": os.getpid(), "hosts": hosts}

    # ---- document: the real CSV, the real thresholds ------------------------------------
    @staticmethod
    def _number(text):
        t = "".join(ch for ch in (text or "") if ch.isdigit() or ch in ",.-")
        if "," in t and "." in t:
            t = t.replace(",", "")
        elif "," in t:
            t = t.replace(",", ".")
        try:
            return float(t)
        except ValueError:
            return None

    @staticmethod
    def _documents_cfg(cfg):
        """"document" is a list since v1.7; a v1.6 single object is still accepted."""
        docs = cfg.get("document")
        if isinstance(docs, dict):
            docs = [docs] if docs else []
        return [d for d in (docs or []) if isinstance(d, dict)]

    def _csv_total(self, doc, path):
        """(total, error) for measure "sum": the real CSV, like DocumentReader.ps1."""
        if path.suffix.lower() not in (".csv", ".txt"):
            return None, "The demo container reads CSV documents only (Excel needs Windows)"
        try:
            text = path.read_text(encoding="utf-8-sig")
        except OSError:
            return None, f"File not found: {doc.get('path')}"
        header = text.splitlines()[0] if text.strip() else ""
        delim = ";" if header.count(";") > header.count(",") else ","
        rows = list(csv.DictReader(io.StringIO(text), delimiter=delim))
        cols = {c.strip().lower(): c for c in (rows[0].keys() if rows else header.split(delim))}
        fcol, vcol = cols.get(str(doc.get("filter_column", "")).lower()), cols.get(str(doc.get("value_column", "")).lower())
        if not fcol or not vcol:
            return None, "Column not found"
        want = str(doc.get("filter_value", "")).strip().lower()
        return round(sum(n for r in rows if str(r.get(fcol, "")).strip().lower() == want
                         for n in [self._number(r.get(vcol))] if n is not None), 2), None

    def document(self, doc, now):
        """One document's state row (the same fields monitor_document.ps1 writes)."""
        measure = str(doc.get("measure") or "sum").lower()
        size_unit = str(doc.get("size_unit") or "MB").upper()
        if size_unit not in SIZE_UNITS:
            size_unit = "MB"
        state = {"display_name": doc.get("display_name") or "Document", "path": doc.get("path"),
                 "measure": measure, "total": None, "target": None,
                 "unit": size_unit if measure == "file_size" else doc.get("unit", ""),
                 "percent_of_target": None, "current_level": "unknown", "error": None, "note": None,
                 "last_check": now_str(now)}
        path = BASE / str(doc.get("path", "")).replace("\\", "/")
        if not doc.get("path"):
            state["error"] = "document.path is not set"
            return state
        if measure == "file_size":
            if path.is_dir():
                state["error"] = "The path is a folder, not a file"
                return state
            if path.is_file():
                total = round(path.stat().st_size / SIZE_UNITS[size_unit], 2)
            else:
                total, state["note"] = 0.0, "File not created yet: counted as 0"
        elif measure == "sum":
            total, state["error"] = self._csv_total(doc, path)
            if total is None:
                return state
        else:
            state["error"] = f"Unknown measure '{measure}': use sum or file_size"
            return state
        target = float(doc.get("target") or 0)
        pct = round(total / target * 100, 1) if target > 0 else None
        level = "ok"
        for t in sorted(doc.get("thresholds", []), key=lambda t: 0 if t.get("level") == "warning" else 1):
            limit = t.get("percent_of_target")
            if pct is None or limit is None:
                continue
            hit = pct < limit if t.get("condition") == "below" else pct >= limit
            if hit:
                level = t.get("level", "warning")
        state.update(total=total, target=target, percent_of_target=pct,
                     current_level=level if pct is not None else "unknown")
        return state

    def documents(self, cfg, now):
        return {"updated": now_str(now), "monitor_pid": os.getpid(),
                "documents": [self.document(d, now) for d in self._documents_cfg(cfg)]}

    def tick(self):
        cfg = load_settings()
        now = datetime.now()
        write_json("process_state.json", self.processes(cfg, now))
        write_json("performance_state.json", self.performance(cfg, now))
        write_json("disk_state.json", self.disk(cfg, now))
        write_json("network_state.json", self.network(cfg, now))
        write_json("document_state.json", self.documents(cfg, now))


def main():
    sim = Simulator()
    print(f"Simulator: writing state files to {LOGS} every {INTERVAL:g}s", flush=True)
    while True:
        try:
            sim.tick()
        except Exception as exc:          # keep the demo alive; the next tick retries
            print(f"Simulator error: {exc}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
