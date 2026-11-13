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
from socketserver import ThreadingMixIn

BASE           = Path(__file__).parent.parent.resolve()
SETTINGS_FILE  = BASE / "monitoring_settings.json"
STATE_FILE     = BASE / "logs" / "process_state.json"
PERF_STATE_FILE = BASE / "logs" / "performance_state.json"
DISK_STATE_FILE = BASE / "logs" / "disk_state.json"
NET_STATE_FILE   = BASE / "logs" / "network_state.json"
DOC_STATE_FILE   = BASE / "logs" / "document_state.json"
PORT          = 5758

MONITOR_SCRIPTS = {
    "process":     BASE / "scripts" / "process_monitor.ps1",
    "performance": BASE / "scripts" / "performance_monitor.ps1",
    "disk":        BASE / "scripts" / "monitor_disk.ps1",
    "network":     BASE / "scripts" / "monitor_network.ps1",
    "document":    BASE / "scripts" / "monitor_document.ps1",
}


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


HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Monitoring Console</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#f0f4f9;--bg2:#ffffff;--bg3:#e8edf7;--card:#ffffff;
  --border:#d0d9eb;--text:#1a2740;--muted:#5e7191;
  --green:#15803d;--green-bg:#f0fdf4;--green-bd:#86efac;
  --red:#b91c1c;--red-bg:#fef2f2;--red-bd:#fca5a5;
  --orange:#c2410c;--orange-bg:#fff7ed;--orange-bd:#fed7aa;
  --accent:#2563eb;
}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;font-size:14px;height:100vh;display:flex;flex-direction:column;overflow:hidden}

/* ── TOP BAR ── */
.topbar{background:var(--bg2);border-bottom:1px solid var(--border);padding:0 18px;height:46px;display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.topbar-left{display:flex;align-items:center;gap:9px}
.app-icon{width:26px;height:26px;background:linear-gradient(135deg,#2563eb,#0891b2);border-radius:6px;display:flex;align-items:center;justify-content:center;font-size:13px;flex-shrink:0}
.app-title{font-size:14px;font-weight:700;color:var(--text)}
.version-badge{background:var(--bg3);border:1px solid var(--border);border-radius:20px;padding:2px 8px;font-size:10px;color:var(--muted)}
.topbar-right{display:flex;align-items:center;gap:8px;font-size:11px;color:var(--muted)}
.pulse-dot{width:6px;height:6px;border-radius:50%;background:var(--green);animation:pulse 2.5s ease-in-out infinite;flex-shrink:0}
.pulse-dot.off{background:var(--muted);animation:none}

/* ── STATUS BAR ── */
.status-bar{background:var(--bg2);border-bottom:1px solid var(--border);padding:0 18px;height:38px;display:flex;align-items:center;gap:14px;flex-shrink:0;font-size:13px}
.bar-sep{width:1px;height:16px;background:var(--border)}
.clr-green{color:var(--green)}.clr-red{color:var(--red)}.clr-muted{color:var(--muted)}
.stat-pill{display:flex;align-items:center;gap:4px}
.stat-num{font-weight:700;font-size:14px}
.mon-item{display:flex;align-items:center;gap:5px;font-size:12px;font-weight:600;color:var(--muted);white-space:nowrap}
.mon-dot{width:9px;height:9px;border-radius:50%;flex-shrink:0;background:#94a3b8}
.mon-active .mon-dot{background:var(--green)}
.mon-active{color:var(--green)}

/* ── MAIN LAYOUT ── */
.main-outer{flex:1;overflow-y:auto;padding:8px 14px 14px;min-height:0}
.console-layout{display:grid;grid-template-columns:1fr 1fr;gap:12px;align-items:start}
.col-system,.col-content{display:flex;flex-direction:column;gap:8px}
.group-hdr{display:flex;align-items:center;gap:0;margin:6px 0 8px}
.group-hdr-line{flex:1;height:1px;background:var(--border)}
.group-hdr-lbl{font-size:9px;font-weight:700;letter-spacing:1.3px;text-transform:uppercase;color:var(--muted);padding:0 10px;white-space:nowrap}
.section{background:var(--card);border:1px solid var(--border);border-radius:9px;display:flex;flex-direction:column;min-height:0;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.06)}
.sec-head{padding:7px 13px 6px;border-bottom:1px solid var(--border);flex-shrink:0}
.sec-title{font-size:12px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:var(--muted)}
.sec-body{overflow:auto;flex:1}

/* ── ITEM ROW ── */
.item-row{display:flex;align-items:center;gap:9px;padding:6px 13px;border-bottom:1px solid var(--border);transition:background .12s;min-height:44px}
.item-row:last-child{border-bottom:none}
.item-row:hover{background:var(--bg)}
.item-accent{width:3px;height:26px;border-radius:2px;flex-shrink:0}
.item-info{width:16px;height:16px;border-radius:50%;background:#cbd5e1;color:#475569;font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0;cursor:pointer;user-select:none;transition:background .15s,color .15s}
.item-info:hover{background:#64748b;color:#fff}
.acc-green{background:var(--green)}.acc-red{background:var(--red)}.acc-orange{background:var(--orange)}.acc-gray{background:#94a3b8}
.item-name{flex:1;min-width:0}
.item-label{font-weight:600;font-size:14px;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.item-sub{font-size:12px;color:var(--muted);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.item-metric{flex-shrink:0;text-align:right;min-width:78px}
.metric-val{font-size:16px;font-weight:700;color:var(--text)}
.metric-bar{height:5px;background:var(--bg3);border-radius:2px;overflow:hidden;margin-top:4px;width:78px}
.metric-fill{height:100%;border-radius:2px;transition:width .5s ease}
.fill-ok{background:var(--green)}.fill-warn{background:var(--orange)}.fill-crit{background:var(--red)}
.item-badge{flex-shrink:0;min-width:76px;text-align:right}
.badge{display:inline-block;padding:3px 9px;border-radius:20px;font-size:11px;font-weight:700;letter-spacing:.3px;white-space:nowrap}
.badge-green{background:var(--green-bg);color:var(--green);border:1px solid var(--green-bd)}
.badge-red{background:var(--red-bg);color:var(--red);border:1px solid var(--red-bd)}
.badge-orange{background:var(--orange-bg);color:var(--orange);border:1px solid var(--orange-bd)}
.badge-gray{background:var(--bg3);color:var(--muted);border:1px solid var(--border)}
.btn-warn{background:var(--red-bg);color:var(--red);border:1px solid var(--red-bd);border-radius:5px;padding:3px 8px;font-size:11px;font-weight:700;cursor:pointer;white-space:nowrap;margin-left:4px}
.btn-warn:hover{background:var(--red-bd)}
.empty-row{padding:18px 13px;text-align:center;color:var(--muted);font-size:12px}
/* ── SECTION COLORS ── */
.sec-head{background:var(--bg3);display:flex;align-items:center;justify-content:space-between}
.sec-processes .sec-head,.sec-perf .sec-head,.sec-disk .sec-head,.sec-net .sec-head{background:#9dc8c2;border-bottom-color:#7db0a9}
.sec-processes .sec-title,.sec-perf .sec-title,.sec-disk .sec-title,.sec-net .sec-title{color:#1a2740}
.sec-doc .sec-head{background:#9fa6c8;border-bottom-color:#818ab5}
.sec-doc .sec-title{color:#1a2740}
.sec-head.danger{background:#dc2626 !important;border-bottom-color:#991b1b !important}
.sec-head.danger .sec-title{color:#ffffff !important}
.sec-head.danger .btn-start{background:#ffffff;color:#dc2626;border-color:#ffffff}
.sec-head.danger .btn-start:hover{background:#fee2e2}
.sec-body{background:#ffffff}
.btn-stop{background:#dc2626;color:#ffffff;border:1px solid #b91c1c;border-radius:5px;padding:4px 11px;font-size:10px;font-weight:700;cursor:pointer;white-space:nowrap;box-shadow:0 1px 3px rgba(185,28,28,.35);letter-spacing:.3px;text-shadow:0 1px 1px rgba(0,0,0,.2)}
.btn-stop:hover{background:#b91c1c;border-color:#991b1b;box-shadow:0 2px 6px rgba(185,28,28,.5)}
.btn-start{background:var(--green-bg);color:var(--green);border:1px solid var(--green-bd);border-radius:5px;padding:3px 9px;font-size:10px;font-weight:700;cursor:pointer;white-space:nowrap}
.btn-start:hover{background:var(--green-bd)}
.sec-body.monitor-paused{filter:grayscale(1) opacity(.45);pointer-events:none}

/* ── FOOTER ── */
.footer{background:var(--bg2);border-top:1px solid var(--border);height:32px;padding:0 18px;display:flex;align-items:center;justify-content:space-between;font-size:11px;color:var(--muted);flex-shrink:0}
.cdbar-wrap{display:flex;align-items:center;gap:6px}
.cdbar{width:56px;height:3px;background:var(--border);border-radius:2px;overflow:hidden}
.cdbar-fill{height:100%;background:var(--accent);border-radius:2px;transition:width 1s linear}

/* ── MODAL ── */
.overlay{position:fixed;inset:0;background:rgba(0,0,0,.35);display:none;align-items:center;justify-content:center;z-index:200;backdrop-filter:blur(3px)}
.overlay.open{display:flex}
.modal{background:var(--bg2);border:1px solid var(--border);border-radius:11px;padding:22px 24px;max-width:420px;width:calc(100% - 32px);box-shadow:0 12px 40px rgba(0,0,0,.14);animation:slideUp .2s ease}
.modal-title{font-size:15px;font-weight:700;color:var(--text);margin-bottom:3px}
.modal-sub{font-size:11px;color:var(--muted);margin-bottom:16px}
.mrow{margin-bottom:12px}
.mrow-label{font-size:9px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:var(--muted);margin-bottom:4px}
.mrow-val{font-size:12px;color:var(--text)}.mrow-val.red{color:var(--red)}.mrow-val.orange{color:var(--orange)}
.chips{display:flex;gap:5px;flex-wrap:wrap}
.chip{background:var(--bg3);border:1px solid var(--border);border-radius:20px;padding:2px 10px;font-size:11px;color:var(--text)}
.modal-note{background:var(--orange-bg);border:1px solid var(--orange-bd);border-left:3px solid var(--orange);border-radius:7px;padding:10px 13px;font-size:12px;color:var(--text);line-height:1.6;margin-bottom:16px;white-space:pre-line}
.btn-close{width:100%;padding:9px;background:var(--bg3);border:1px solid var(--border);border-radius:7px;color:var(--text);font-size:13px;font-weight:600;cursor:pointer}
.btn-close:hover{background:var(--border)}

/* ── DETAILS PANEL ── */
.det-ov{position:fixed;inset:0;background:rgba(0,0,0,.4);display:none;align-items:flex-start;justify-content:center;z-index:300;backdrop-filter:blur(4px);overflow-y:auto;padding:28px 16px}
.det-ov.open{display:flex}
.det-panel{background:var(--bg2);border:1px solid var(--border);border-radius:13px;width:100%;max-width:700px;box-shadow:0 16px 48px rgba(0,0,0,.2);animation:slideUp .2s ease;margin:auto}
.det-head{display:flex;align-items:center;justify-content:space-between;padding:18px 22px 0}
.det-title{font-size:15px;font-weight:700;color:var(--text)}
.det-tabs{display:flex;padding:14px 22px 0;border-bottom:2px solid var(--border);gap:2px;overflow-x:auto}
.det-tab{padding:7px 13px;font-size:12px;font-weight:600;color:var(--muted);cursor:pointer;white-space:nowrap;border-bottom:2px solid transparent;margin-bottom:-2px;border-radius:5px 5px 0 0}
.det-tab.active{color:var(--accent);border-bottom-color:var(--accent)}
.det-tab:hover:not(.active){background:var(--bg3);color:var(--text)}
.det-body{padding:18px 22px 22px;max-height:68vh;overflow-y:auto}
.det-sec{display:none}.det-sec.active{display:block}
.det-card{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:14px 16px;margin-bottom:12px}
.det-card-title{font-size:13px;font-weight:700;color:var(--text);margin-bottom:10px;display:flex;align-items:center;gap:8px}
.det-row{display:flex;gap:8px;margin-bottom:6px;font-size:12px}
.det-lbl{font-size:10px;font-weight:700;letter-spacing:.8px;text-transform:uppercase;color:var(--muted);min-width:125px;flex-shrink:0;padding-top:1px}
.det-val{color:var(--text);flex:1;word-break:break-all}
.det-thresh-hd{font-size:10px;font-weight:700;letter-spacing:.8px;text-transform:uppercase;color:var(--muted);margin:10px 0 6px}
.det-tlvl{display:flex;gap:8px;background:var(--bg2);border:1px solid var(--border);border-radius:6px;padding:9px 12px;margin-bottom:6px;font-size:12px}
.det-tlvl-warning{border-left:3px solid var(--orange)}
.det-tlvl-critical{border-left:3px solid var(--red)}
.det-act-chip{display:inline-flex;align-items:center;gap:4px;background:var(--bg3);border:1px solid var(--border);border-radius:4px;padding:2px 8px;font-size:10px;font-weight:600;color:var(--text);white-space:nowrap}
.btn-det{background:var(--bg3);border:1px solid var(--border);border-radius:6px;padding:4px 11px;font-size:11px;font-weight:600;color:var(--muted);cursor:pointer;white-space:nowrap;transition:background .15s,color .15s}
.btn-det:hover{background:var(--border);color:var(--text)}

/* ── ANIMATIONS ── */
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
@keyframes slideUp{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
@keyframes fadeIn{from{opacity:0}to{opacity:1}}
.fade-in{animation:fadeIn .2s ease}

/* ── TOOLTIP ── */
#tt-box{position:fixed;display:none;z-index:9999;pointer-events:none;background:#1e2d4a;color:#e2e8f0;border:1px solid #2d4a7a;border-radius:10px;padding:13px 16px;font-size:12px;min-width:280px;max-width:370px;box-shadow:0 10px 32px rgba(0,0,0,.35);line-height:1.6}
.tt-title{font-weight:700;font-size:13px;color:#fff;margin-bottom:2px}
.tt-meta{font-size:11px;color:#94a3b8;margin-bottom:6px}
.tt-hr{height:1px;background:#2d4a7a;margin:8px 0}
.tt-cur{font-size:11px;color:#94a3b8;margin-bottom:6px}
.tt-cur b{color:#e2e8f0}
.tt-thresh{margin-bottom:5px}
.tt-lvl-warn{color:#fb923c;font-weight:700;font-size:11px}
.tt-lvl-crit{color:#f87171;font-weight:700;font-size:11px}
.tt-cond{color:#cbd5e1;font-size:11px;margin-left:6px}
.tt-acts{font-size:11px;color:#64748b;padding-left:4px;margin-top:1px}
.tt-instr{font-size:11px;color:#cbd5e1;white-space:pre-wrap;margin-top:4px;max-height:72px;overflow:hidden}
</style>
</head>
<body>

<div class="topbar">
  <div class="topbar-left">
    <div class="app-icon">📊</div>
    <div class="app-title">Monitoring Console</div>
    <span class="version-badge" id="ver">v—</span>
  </div>
  <div class="topbar-right">
    <button class="btn-det" onclick="showDetails()">&#128269; View all monitoring details</button>
    <div class="pulse-dot" id="pdot"></div>
    <span id="refresh-lbl">Connecting…</span>
  </div>
</div>

<div class="status-bar">
  <div id="mon-process" class="mon-item"><span class="mon-dot"></span><span>Process</span></div>
  <div id="mon-perf" class="mon-item"><span class="mon-dot"></span><span>Performance</span></div>
  <div id="mon-disk" class="mon-item"><span class="mon-dot"></span><span>Disk</span></div>
  <div id="mon-net" class="mon-item"><span class="mon-dot"></span><span>Network</span></div>
  <div id="mon-doc" class="mon-item"><span class="mon-dot"></span><span>Document</span></div>
</div>

<div class="main-outer">
  <div class="console-layout">

    <div class="col-system">
      <div class="group-hdr">
        <div class="group-hdr-line"></div>
        <span class="group-hdr-lbl">System Monitoring</span>
        <div class="group-hdr-line"></div>
      </div>
      <div class="section sec-processes">
        <div class="sec-head" id="head-process"><span class="sec-title">Processes</span><span id="ctrl-process"></span></div>
        <div class="sec-body" id="proc-list"><div class="empty-row">Loading…</div></div>
      </div>
      <div class="section sec-perf">
        <div class="sec-head" id="head-performance"><span class="sec-title">Performance</span><span id="ctrl-performance"></span></div>
        <div class="sec-body" id="perf-list"><div class="empty-row">Loading…</div></div>
      </div>
      <div class="section sec-disk">
        <div class="sec-head" id="head-disk"><span class="sec-title">Disk</span><span id="ctrl-disk"></span></div>
        <div class="sec-body" id="disk-list"><div class="empty-row">Loading…</div></div>
      </div>
      <div class="section sec-net">
        <div class="sec-head" id="head-network"><span class="sec-title">Network</span><span id="ctrl-network"></span></div>
        <div class="sec-body" id="net-list"><div class="empty-row">Loading…</div></div>
      </div>
    </div>

    <div class="col-content">
      <div class="group-hdr">
        <div class="group-hdr-line"></div>
        <span class="group-hdr-lbl">Content Monitoring</span>
        <div class="group-hdr-line"></div>
      </div>
      <div class="section sec-doc">
        <div class="sec-head" id="head-document"><span class="sec-title">Document</span><span id="ctrl-document"></span></div>
        <div class="sec-body" id="doc-list"><div class="empty-row">Loading…</div></div>
      </div>
    </div>

  </div>
</div>

<div class="footer">
  <span id="footer-lbl">Last refresh: —</span>
  <div class="cdbar-wrap">
    Auto-refresh in <span id="cd-num">10</span>s
    <div class="cdbar"><div class="cdbar-fill" id="cd-fill" style="width:100%"></div></div>
  </div>
</div>

<div class="det-ov" id="det-ov" onclick="if(event.target===this)closeDet()">
  <div class="det-panel">
    <div class="det-head">
      <div class="det-title">&#128270; Monitoring Configuration Details</div>
      <button class="btn-close" style="width:auto;padding:5px 16px" onclick="closeDet()">&#10005; Close</button>
    </div>
    <div class="det-tabs" id="det-tabs"></div>
    <div class="det-body" id="det-body"></div>
  </div>
</div>

<div class="overlay" id="overlay" onclick="if(event.target===this)closeModal()">
  <div class="modal">
    <div class="modal-title" id="m-title">Process Not Running</div>
    <div class="modal-sub"   id="m-exe"></div>
    <div class="mrow">
      <div class="mrow-label">Current Status</div>
      <div class="mrow-val red">● NOT RUNNING</div>
    </div>
    <div class="mrow" id="m-down-row">
      <div class="mrow-label">Down Since</div>
      <div class="mrow-val orange" id="m-down">—</div>
    </div>
    <div class="mrow">
      <div class="mrow-label">Alerts Sent</div>
      <div class="mrow-val" id="m-alerts">0</div>
    </div>
    <div class="mrow" id="m-act-row">
      <div class="mrow-label">Configured Actions</div>
      <div class="chips" id="m-chips"></div>
    </div>
    <div class="modal-note" id="m-note"></div>
    <button class="btn-close" onclick="closeModal()">Close</button>
  </div>
</div>

<div id="tt-box"></div>

<script>
const REFRESH = 10;
const ACT_ICONS = {popup:'🔔', log_to_file:'📝', email_draft:'📧', run_script:'⚙️'};
const KEY_TO_BODY={process:'proc-list',performance:'perf-list',disk:'disk-list',network:'net-list',document:'doc-list'};
let cdTimer, cdVal = REFRESH;
const pendingStop = new Set();

function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
function fmtDur(sec){
  if(sec==null||sec<0) return '—';
  const h=Math.floor(sec/3600),m=Math.floor((sec%3600)/60),s=sec%60;
  if(h>0) return h+'h '+m+'m'; if(m>0) return m+'m '+s+'s'; return s+'s';
}
function lvlBadge(lvl){
  const l=(lvl||'ok').toLowerCase();
  if(l==='critical') return '<span class="badge badge-red">CRITICAL</span>';
  if(l==='warning')  return '<span class="badge badge-orange">WARNING</span>';
  if(l==='unknown')  return '<span class="badge badge-gray">UNKNOWN</span>';
  return '<span class="badge badge-green">OK</span>';
}
function accColor(lvl){
  const l=(lvl||'ok').toLowerCase();
  return l==='critical'?'acc-red':l==='warning'?'acc-orange':l==='unknown'?'acc-gray':'acc-green';
}

// ── Tooltip ──────────────────────────────────────────────────────────────────
const _ttBox = document.getElementById('tt-box');
const _ttCache = {};

document.addEventListener('mouseover', e => {
  const row = e.target.closest('[data-ttid]');
  if(!row || !_ttCache[row.dataset.ttid]){ _ttBox.style.display='none'; return; }
  _ttBox.innerHTML = _ttCache[row.dataset.ttid];
  _ttBox.style.display = 'block';
  _posTt(e);
});
document.addEventListener('mousemove', e => {
  if(_ttBox.style.display==='none') return;
  if(!e.target.closest('[data-ttid]')){ _ttBox.style.display='none'; return; }
  _posTt(e);
});
function _posTt(e){
  const pad=16, w=_ttBox.offsetWidth, h=_ttBox.offsetHeight;
  let x=e.clientX+pad, y=e.clientY+pad;
  if(x+w>window.innerWidth-8)  x=e.clientX-w-pad;
  if(y+h>window.innerHeight-8) y=e.clientY-h-pad;
  _ttBox.style.left=x+'px'; _ttBox.style.top=y+'px';
}

function _ttThresh(thresholds, type){
  return (thresholds||[]).map(t=>{
    const cls = t.level==='critical'?'tt-lvl-crit':'tt-lvl-warn';
    const icon = t.level==='critical'?'🔴':'⚠️';
    let cond='';
    if(type==='perf') cond=`≥ ${t.percent}%  sustained ${t.sustain_sec}s`;
    else if(type==='disk') cond=`≥ ${t.percent_used}% used`;
    else if(type==='net') cond = t.condition==='unreachable'?'Unreachable':t.latency_ms?`Latency &gt; ${t.latency_ms}ms`:'';
    const acts=(t.actions||[]).map(a=>ACT_ICONS[a.type]||'•').join(' ');
    return `<div class="tt-thresh"><span class="${cls}">${icon} ${t.level.toUpperCase()}</span><span class="tt-cond">${cond}</span><div class="tt-acts">${acts||'—'}</div></div>`;
  }).join('');
}
function _ttPerf(m, cfg){
  const cur=m.current_value!=null?`Current: <b>${Math.round(m.current_value)}%</b>`:'';
  return `<div class="tt-title">${esc(m.display_name)}</div>`+
    `<div class="tt-meta">Check every ${(cfg||{}).check_interval_sec||5}s</div>`+
    (cur?`<div class="tt-cur">${cur}</div>`:'')+
    `<div class="tt-hr"></div>`+_ttThresh((cfg||{}).thresholds,'perf');
}
function _ttDisk(m, cfg){
  const cur=m.percent_used!=null?`Current: <b>${Math.round(m.percent_used)}%</b> &nbsp;·&nbsp; Free: <b>${m.free_gb} GB</b>`:'Drive unavailable';
  return `<div class="tt-title">${esc(m.display_name)}</div>`+
    `<div class="tt-meta">Drive: ${esc(m.drive)} &nbsp;·&nbsp; Check every ${(cfg||{}).check_interval_sec||60}s</div>`+
    `<div class="tt-cur">${cur}</div>`+
    `<div class="tt-hr"></div>`+_ttThresh((cfg||{}).thresholds,'disk');
}
function _ttNet(m, cfg){
  const lat=m.latency_ms!=null?` &nbsp;·&nbsp; Latency: <b>${m.latency_ms}ms</b>`:'';
  const cur=`Status: <b>${m.reachable?'Online':'Offline'}</b>${lat}`;
  return `<div class="tt-title">${esc(m.name)}</div>`+
    `<div class="tt-meta">Host: ${esc(m.host)}${m.port?':'+m.port:''} &nbsp;·&nbsp; ${esc((m.protocol||'').toUpperCase())} &nbsp;·&nbsp; Check every ${(cfg||{}).check_interval_sec||30}s &nbsp;·&nbsp; Timeout: ${(cfg||{}).timeout_sec||5}s</div>`+
    `<div class="tt-cur">${cur}</div>`+
    `<div class="tt-hr"></div>`+_ttThresh((cfg||{}).thresholds,'net');
}
function _ttProc(p){
  const acts=(p.actions||[]).map(a=>ACT_ICONS[a]||'•').join(' ');
  const instr=p.instructions?`<div class="tt-hr"></div><div class="tt-meta">Instructions:</div><div class="tt-instr">${esc(p.instructions.substring(0,220))}</div>`:'';
  return `<div class="tt-title">${esc(p.display_name)}</div>`+
    `<div class="tt-meta">Process: ${esc(p.name)} &nbsp;·&nbsp; ${p.required?'Required':'Optional'} &nbsp;·&nbsp; Check every ${p.check_sec}s</div>`+
    `<div class="tt-hr"></div><div class="tt-meta">On not running: ${acts||'—'}</div>${instr}`;
}
function _docRule(t){
  return `${t.condition==='below'?'Below':'Above'} <b>${t.percent_of_target}%</b> of target`;
}
function _ttDoc(ds, cfg){
  const c=cfg||{}, u=ds.unit||'';
  const chk=c.check_interval_sec||60;
  const cur=ds.error
    ?`<span style="color:#f87171">Error: ${esc(ds.error)}</span>`
    :`Current: <b>${esc(u)}${Number(ds.total||0).toFixed(2)}</b> &nbsp;(${ds.percent_of_target}% of ${esc(u)}${ds.target})`;
  const rules=(c.thresholds||[]).map(t=>`<div class="tt-thresh"><span class="${t.level==='critical'?'tt-lvl-crit':'tt-lvl-warn'}">${esc((t.level||'').toUpperCase())}</span><span class="tt-cond">${_docRule(t)}</span></div>`).join('');
  return `<div class="tt-title">${esc(ds.display_name||'Document')}</div>`+
    `<div class="tt-meta">${esc(c.path||ds.path||'')} &nbsp;·&nbsp; ${esc(c.filter_column||'')} = ${esc(c.filter_value||'')} &nbsp;·&nbsp; sum of ${esc(c.value_column||'')} &nbsp;·&nbsp; every ${chk}s</div>`+
    `<div class="tt-cur">${cur}</div>${rules?'<div class="tt-hr"></div>'+rules:''}`;
}
// ─────────────────────────────────────────────────────────────────────────────

function render(d){
  _detData = d;
  document.getElementById('ver').textContent         = 'v'+d.version;
  document.getElementById('refresh-lbl').textContent = 'Refreshed '+d.server_time;
  document.getElementById('footer-lbl').textContent  = 'Last refresh: '+d.server_time;

  const eng=d.engine, pd=document.getElementById('pdot');
  const mons=eng.monitors||{};
  const monIds={process:'mon-process',performance:'mon-perf',disk:'mon-disk',network:'mon-net',document:'mon-doc'};
  Object.entries(monIds).forEach(([k,id])=>{
    const el=document.getElementById(id);
    if(el) el.className='mon-item '+(mons[k]?'mon-active':'');
  });
  const anyActive=Object.values(mons).some(v=>v);
  pd.className=anyActive?'pulse-dot':'pulse-dot off';

  // per-section header color + start/stop button
  Object.entries(mons).forEach(([key, active])=>{
    const head=document.getElementById('head-'+key);
    const ctrl=document.getElementById('ctrl-'+key);
    const body=document.getElementById(KEY_TO_BODY[key]);
    if(!head||!ctrl) return;
    if(active){
      head.classList.remove('danger');
      ctrl.innerHTML=`<button class="btn-stop" onclick="ctrlMonitor('stop','${key}')">&#9646;&#9646; Pause Monitoring</button>`;
      if(body) body.classList.remove('monitor-paused');
    } else {
      head.classList.add('danger');
      ctrl.innerHTML=`<button class="btn-start" onclick="ctrlMonitor('start','${key}')">&#9654; Resume Monitoring</button>`;
      if(body) body.classList.add('monitor-paused');
      pendingStop.delete(key);
    }
  });

  const cfg = d.config || {};

  // processes
  const pl=document.getElementById('proc-list');
  if(!d.processes.length){ pl.innerHTML='<div class="empty-row">No processes configured.</div>'; }
  else { pl.innerHTML = d.processes.map((p,i) => {
    const run=p.is_running===true, unk=p.is_running===null;
    const lvl=run?'ok':unk?'unknown':'critical';
    const sub=run?(p.last_check?'Last check: '+esc(p.last_check):''):
              p.down_since?'Down '+fmtDur(p.down_sec)+' &nbsp;·&nbsp; Alerts: '+p.alert_count:'Not detected';
    const btn=!run?`<button class="btn-warn" onclick='showModal(${JSON.stringify(p)})'>&#9881; Perform Actions</button>`:'';
    const ttid=`proc-${i}`; _ttCache[ttid]=_ttProc(p);
    return `<div class="item-row fade-in">
  <div class="item-accent ${accColor(lvl)}"></div>
  <div class="item-info" data-ttid="${ttid}">i</div>
  <div class="item-name"><div class="item-label">${esc(p.display_name)}</div><div class="item-sub">${esc(p.name)}&nbsp;·&nbsp;${p.required?'Required':'Optional'}&nbsp;·&nbsp;${sub}</div></div>
  <div class="item-badge">${run?'<span class="badge badge-green">RUNNING</span>':unk?'<span class="badge badge-gray">UNKNOWN</span>':'<span class="badge badge-red">NOT RUNNING</span>'}</div>
  ${btn}
</div>`;
  }).join(''); }

  // performance
  const pfl=document.getElementById('perf-list');
  if(!d.performance||!d.performance.length){ pfl.innerHTML='<div class="empty-row">Start performance_monitor.ps1</div>'; }
  else { pfl.innerHTML = d.performance.map((m,i) => {
    const lvl=(m.current_level||'ok').toLowerCase();
    const val=m.current_value!=null?Math.round(m.current_value):null;
    const pct=m.current_value!=null?Math.min(100,Math.round(m.current_value)):0;
    const fc=lvl==='critical'?'fill-crit':lvl==='warning'?'fill-warn':'fill-ok';
    const perfCfg=(cfg.performance||{})[m.name]||{};
    const ttid=`perf-${i}`; _ttCache[ttid]=_ttPerf(m,perfCfg);
    return `<div class="item-row fade-in">
  <div class="item-accent ${accColor(lvl)}"></div>
  <div class="item-info" data-ttid="${ttid}">i</div>
  <div class="item-name"><div class="item-label">${esc(m.display_name)}</div><div class="item-sub">Last check: ${esc(m.last_check||'—')}</div></div>
  <div class="item-metric"><div class="metric-val">${val!=null?val+'%':'—'}</div><div class="metric-bar"><div class="metric-fill ${fc}" style="width:${pct}%"></div></div></div>
  <div class="item-badge">${lvlBadge(lvl)}</div>
</div>`;
  }).join(''); }

  // disk
  const dkl=document.getElementById('disk-list');
  if(!d.disks||!d.disks.length){ dkl.innerHTML='<div class="empty-row">Start monitor_disk.ps1</div>'; }
  else { dkl.innerHTML = d.disks.map((m,i) => {
    const lvl=(m.current_level||'ok').toLowerCase();
    const val=m.percent_used!=null?Math.round(m.percent_used):null;
    const pct=m.percent_used!=null?Math.min(100,Math.round(m.percent_used)):0;
    const fc=lvl==='critical'?'fill-crit':lvl==='warning'?'fill-warn':'fill-ok';
    const sub=m.free_gb!=null?`${esc(m.drive)}&nbsp;·&nbsp;${m.free_gb} GB free`:`${esc(m.drive)}&nbsp;·&nbsp;Unavailable`;
    const diskCfg=(cfg.disk||[]).find(dc=>dc.drive===m.drive)||{};
    const ttid=`disk-${i}`; _ttCache[ttid]=_ttDisk(m,diskCfg);
    return `<div class="item-row fade-in">
  <div class="item-accent ${accColor(lvl)}"></div>
  <div class="item-info" data-ttid="${ttid}">i</div>
  <div class="item-name"><div class="item-label">${esc(m.display_name)}</div><div class="item-sub">${sub}</div></div>
  <div class="item-metric">${val!=null?`<div class="metric-val">${val}%</div><div class="metric-bar"><div class="metric-fill ${fc}" style="width:${pct}%"></div></div>`:'<div class="metric-val clr-muted">—</div>'}</div>
  <div class="item-badge">${lvlBadge(lvl)}</div>
</div>`;
  }).join(''); }

  // network
  const ntl=document.getElementById('net-list');
  if(!d.network||!d.network.length){ ntl.innerHTML='<div class="empty-row">Start monitor_network.ps1</div>'; }
  else { ntl.innerHTML = d.network.map((m,i) => {
    const lvl=(m.current_level||'ok').toLowerCase(), ok=m.reachable===true;
    const lat=(ok&&m.latency_ms!=null)?`${m.latency_ms} ms`:'';
    const sub=`${esc(m.host)}${m.port?':'+m.port:''}&nbsp;·&nbsp;${esc((m.protocol||'').toUpperCase())}${lat?'&nbsp;·&nbsp;'+lat:''}`;
    const netCfg=(cfg.network||[]).find(nc=>nc.name===m.name)||{};
    const ttid=`net-${i}`; _ttCache[ttid]=_ttNet(m,netCfg);
    return `<div class="item-row fade-in">
  <div class="item-accent ${accColor(lvl)}"></div>
  <div class="item-info" data-ttid="${ttid}">i</div>
  <div class="item-name"><div class="item-label">${esc(m.name)}</div><div class="item-sub">${sub}</div></div>
  <div class="item-badge">${ok?'<span class="badge badge-green">ONLINE</span>':'<span class="badge badge-red">OFFLINE</span>'}</div>
  <div class="item-badge">${lvlBadge(lvl)}</div>
</div>`;
  }).join(''); }

  // document (CSV / Excel) -- the level comes from the monitor's thresholds
  const dl=document.getElementById('doc-list');
  const docCfg=cfg.document||{};
  if(!d.document){
    dl.innerHTML='<div class="empty-row">Start monitor_document.ps1</div>';
  } else {
    const ds=d.document;
    const ttid='doc-0'; _ttCache[ttid]=_ttDoc(ds,docCfg);
    if(ds.error){
      dl.innerHTML=`<div class="item-row fade-in">
  <div class="item-accent acc-red"></div>
  <div class="item-info" data-ttid="${ttid}">i</div>
  <div class="item-name">
    <div class="item-label">${esc(ds.display_name||'Document')}</div>
    <div class="item-sub" style="color:var(--red)">${esc(ds.error)}</div>
  </div>
  <div class="item-badge"><span class="badge badge-red">DATA ERROR</span></div>
</div>`;
    } else {
      const u=ds.unit||'';
      const total=Number(ds.total||0), pct=Number(ds.percent_of_target||0);
      const lvl=ds.current_level||'ok';
      const fc=lvl==='critical'?'fill-crit':lvl==='warning'?'fill-warn':'fill-ok';
      dl.innerHTML=`<div class="item-row fade-in">
  <div class="item-accent ${accColor(lvl)}"></div>
  <div class="item-info" data-ttid="${ttid}">i</div>
  <div class="item-name">
    <div class="item-label">${esc(ds.display_name||'Document')}</div>
    <div class="item-sub">${esc(ds.path||'')}&nbsp;&middot;&nbsp;Target: ${esc(u)}${Number(ds.target||0).toFixed(2)}&nbsp;&middot;&nbsp;Updated: ${esc(ds.updated||'')}</div>
  </div>
  <div class="item-metric">
    <div class="metric-val">${esc(u)}${total.toFixed(2)}</div>
    <div class="metric-bar" title="${pct}% of target"><div class="metric-fill ${fc}" style="width:${Math.min(100,pct)}%"></div></div>
    <div style="font-size:10px;color:var(--muted);text-align:right;margin-top:2px">${pct}% of target</div>
  </div>
  <div class="item-badge">${lvlBadge(lvl)}</div>
</div>`;
    }
  }
}

function showModal(p){
  document.getElementById('m-title').textContent  = p.display_name+' — Not Running';
  document.getElementById('m-exe').textContent    = p.name+(p.required?' · Required':' · Optional');
  document.getElementById('m-alerts').textContent = p.alert_count;
  const dr=document.getElementById('m-down-row');
  if(p.down_since){ dr.style.display=''; document.getElementById('m-down').textContent=p.down_since+(p.down_sec!=null?'  ('+fmtDur(p.down_sec)+')':''); }
  else { dr.style.display='none'; }
  const ar=document.getElementById('m-act-row'), chips=document.getElementById('m-chips');
  if(p.actions&&p.actions.length){ ar.style.display=''; chips.innerHTML=p.actions.map(a=>`<span class="chip">${ACT_ICONS[a]||'•'} ${esc(a)}</span>`).join(''); }
  else { ar.style.display='none'; }
  document.getElementById('m-note').textContent = p.instructions||
    (p.display_name+' ('+p.name+') is currently not running. '+(p.required?'This process is marked as Required. ':'')+'Start the process manually to stop alerts.');
  document.getElementById('overlay').classList.add('open');
}
function closeModal(){ document.getElementById('overlay').classList.remove('open'); }
document.addEventListener('keydown', e=>{ if(e.key==='Escape'){ closeModal(); closeDet(); } });

async function ctrlMonitor(action, key){
  const label = key.charAt(0).toUpperCase()+key.slice(1);
  if(action==='stop' && pendingStop.has(key)){
    alert(`A Pause action for the ${label} monitor is already running in the background.\nPlease wait a moment — the monitor will stop shortly.`);
    return;
  }
  const msg = action==='stop'
    ? `Pause the ${label} monitor?\n\nThis will terminate the background script. You can resume it from this console.`
    : `Resume the ${label} monitor?\n\nThis will launch the background script.`;
  if(!confirm(msg)) return;
  if(action==='stop') pendingStop.add(key);
  try{
    const r = await fetch(`/api/${action}/${key}`, {method:'POST'});
    const d = await r.json();
    if(d.already_running){
      alert(`The ${label} monitor is already running — no action needed.`);
      fetchStatus();
    } else if(d.ok){
      if(action==='start') alert(`Resume command sent for ${label} monitor.`);
      fetchStatus();
    } else {
      if(action==='stop') pendingStop.delete(key);
      alert(`Could not ${action} ${label} monitor:\n${d.error||'Unknown error'}`);
    }
  } catch(e){
    if(action==='stop') pendingStop.delete(key);
    alert(`Request failed: ${e.message}`);
  }
}

// ── Details panel ────────────────────────────────────────────────────────────
let _detData = null;
let _detTab  = 'settings';
const DET_TABS   = ['settings','processes','performance','disk','network','document'];
const DET_LABELS = ['&#9881; Settings','&#128203; Processes','&#128200; Performance','&#128190; Disk','&#127760; Network','&#128196; Document'];

function showDetails(){
  if(!_detData) return;
  _detRender(_detData);
  document.getElementById('det-ov').classList.add('open');
}
function closeDet(){ document.getElementById('det-ov').classList.remove('open'); }

function _detRender(d){
  const cfg = d.config||{};
  document.getElementById('det-tabs').innerHTML = DET_TABS.map((t,i)=>
    `<div class="det-tab${t===_detTab?' active':''}" onclick="_detSwitch('${t}')">${DET_LABELS[i]}</div>`
  ).join('');
  document.getElementById('det-body').innerHTML = DET_TABS.map(t=>
    `<div class="det-sec${t===_detTab?' active':''}" id="det-sec-${t}">${_detSection(t,cfg)}</div>`
  ).join('');
}
function _detSwitch(t){
  _detTab = t;
  document.querySelectorAll('.det-tab').forEach((el,i)=>el.classList.toggle('active', DET_TABS[i]===t));
  document.querySelectorAll('.det-sec').forEach(el=>el.classList.toggle('active', el.id==='det-sec-'+t));
}
function _detSection(tab, cfg){
  if(tab==='settings')    return _dSettings(cfg.meta||{}, cfg.global||{});
  if(tab==='processes')   return _dProcesses(cfg.processes||[]);
  if(tab==='performance') return _dPerformance(cfg.performance||{});
  if(tab==='disk')        return _dDisk(cfg.disk||[]);
  if(tab==='network')     return _dNetwork(cfg.network||[]);
  if(tab==='document')    return _dDocument(cfg.document);
  return '';
}
function _drow(lbl,val){ return `<div class="det-row"><div class="det-lbl">${lbl}</div><div class="det-val">${val||'<span style="color:var(--muted)">—</span>'}</div></div>`; }

function _dActions(actions){
  if(!actions||!actions.length) return '<div style="font-size:11px;color:var(--muted);padding:4px 0">No actions configured</div>';
  return actions.map(a=>{
    const icon=ACT_ICONS[a.type]||'•';
    const lvlClr=a.level==='critical'?'var(--red)':a.level==='warning'?'var(--orange)':'var(--muted)';
    const template=a.message_template||a.instructions||'';
    const extra=template?`<div style="font-size:10px;color:var(--muted);margin-top:3px;white-space:pre-wrap">${esc(template.substring(0,140))}${template.length>140?'…':''}</div>`:'';
    const subj=a.subject_template?`<div style="font-size:10px;color:var(--muted);margin-top:2px">Subject: ${esc(a.subject_template)}</div>`:'';
    return `<div style="display:flex;gap:8px;padding:6px 0;border-bottom:1px solid var(--border);align-items:flex-start">
  <span class="det-act-chip">${icon} ${esc(a.type)}</span>
  <div style="flex:1"><span style="font-size:11px;font-weight:700;color:${lvlClr}">${esc((a.level||'').toUpperCase())}</span>${extra}${subj}</div>
</div>`;
  }).join('');
}
function _dThresholds(thresholds){
  if(!thresholds||!thresholds.length) return '<div style="font-size:11px;color:var(--muted);padding:4px 0">No thresholds configured</div>';
  return thresholds.map(t=>{
    const badge=`<span class="badge ${t.level==='critical'?'badge-red':'badge-orange'}" style="font-size:9px">${(t.level||'').toUpperCase()}</span>`;
    const cond=t.description?esc(t.description)
      :t.percent!=null&&t.sustain_sec!=null?`Above <b>${t.percent}%</b> for <b>${t.sustain_sec}s</b>`
      :t.percent_used!=null?`Usage above <b>${t.percent_used}%</b>`
      :t.latency_ms!=null?`Latency above <b>${t.latency_ms}ms</b>`
      :t.percent_of_target!=null?_docRule(t)
      :t.condition?esc(t.condition):'';
    return `<div class="det-tlvl det-tlvl-${t.level}">
  <div style="flex:1">${badge} <span style="font-size:12px;margin-left:4px">${cond}</span>
  <div style="margin-top:8px">${_dActions(t.actions||[])}</div></div>
</div>`;
  }).join('');
}

function _dSettings(meta, gl){
  return `<div class="det-card">
  <div class="det-card-title">&#128196; Config Metadata</div>
  ${_drow('Version',esc(meta.version||'?'))}
  ${_drow('Last Updated',esc(meta.last_updated||'?'))}
  ${_drow('Description',esc(meta.description||''))}
</div>
<div class="det-card">
  <div class="det-card-title">&#9881; Global Settings</div>
  ${_drow('Default Check Interval',`<b>${gl.check_interval_sec||'?'}s</b>`)}
  ${_drow('Log File',`<code style="font-size:10px;background:var(--bg3);padding:1px 5px;border-radius:3px">${esc(gl.log_file||'')}</code>`)}
  ${_drow('Log Max Size',`${gl.log_max_size_mb||'?'} MB`)}
  ${_drow('Email Recipient',esc(gl.email_recipient||''))}
  ${_drow('Email Sender',esc(gl.email_sender||''))}
  ${_drow('Scripts Directory',`<code style="font-size:10px;background:var(--bg3);padding:1px 5px;border-radius:3px">${esc(gl.scripts_dir||'')}</code>`)}
</div>`;
}
function _dProcesses(procs){
  if(!procs.length) return '<div class="empty-row">No processes configured.</div>';
  return procs.map(p=>{
    const acts=(p.actions&&p.actions.on_not_running)||[];
    const reqBadge=p.required?'<span class="badge badge-red" style="font-size:9px">Required</span>':'<span class="badge badge-gray" style="font-size:9px">Optional</span>';
    return `<div class="det-card">
  <div class="det-card-title">&#128249; ${esc(p.display_name||p.name)} ${reqBadge}</div>
  ${_drow('Executable',esc(p.name))}
  ${_drow('Check Interval',`<b>${p.check_interval_sec||30}s</b>`)}
  <div class="det-thresh-hd">On Not Running</div>${_dActions(acts)}
</div>`;
  }).join('');
}
function _dPerformance(perf){
  const entries=Object.entries(perf);
  if(!entries.length) return '<div class="empty-row">No performance monitors configured.</div>';
  return entries.map(([key,m])=>`<div class="det-card">
  <div class="det-card-title">&#128200; ${esc(key.toUpperCase())}</div>
  ${_drow('Check Interval',`<b>${m.check_interval_sec||5}s</b>`)}
  <div class="det-thresh-hd">Thresholds</div>${_dThresholds(m.thresholds)}
</div>`).join('');
}
function _dDisk(disks){
  if(!disks.length) return '<div class="empty-row">No disk monitors configured.</div>';
  return disks.map(d=>`<div class="det-card">
  <div class="det-card-title">&#128190; ${esc(d.display_name||d.drive)}</div>
  ${_drow('Drive',esc(d.drive))}
  ${_drow('Check Interval',`<b>${d.check_interval_sec||60}s</b>`)}
  <div class="det-thresh-hd">Thresholds</div>${_dThresholds(d.thresholds)}
</div>`).join('');
}
function _dNetwork(nets){
  if(!nets.length) return '<div class="empty-row">No network monitors configured.</div>';
  return nets.map(n=>`<div class="det-card">
  <div class="det-card-title">&#127760; ${esc(n.name||n.host)}</div>
  ${_drow('Host',esc(n.host+(n.port?':'+n.port:'')))}
  ${_drow('Protocol',esc((n.protocol||'').toUpperCase()))}
  ${_drow('Timeout',`${n.timeout_sec||5}s`)}
  ${_drow('Check Interval',`<b>${n.check_interval_sec||30}s</b>`)}
  <div class="det-thresh-hd">Thresholds</div>${_dThresholds(n.thresholds)}
</div>`).join('');
}
function _dDocument(doc){
  if(!doc) return '<div class="empty-row">No document monitor configured.</div>';
  return `<div class="det-card">
  <div class="det-card-title">&#128196; ${esc(doc.display_name||'Document')}</div>
  ${_drow('File',`<code style="font-size:10px;background:var(--bg3);padding:1px 5px;border-radius:3px">${esc(doc.path||'')}</code>`)}
  ${doc.sheet_name?_drow('Sheet',esc(doc.sheet_name)):''}
  ${_drow('Rows',`${esc(doc.filter_column||'')} = <b>${esc(doc.filter_value||'')}</b>`)}
  ${_drow('Sum of',esc(doc.value_column||''))}
  ${_drow('Target',`<b>${esc(doc.unit||'')}${esc(doc.target)}</b>`)}
  ${_drow('Check Interval',`<b>${doc.check_interval_sec||60}s</b>`)}
  <div class="det-thresh-hd">Thresholds</div>${_dThresholds(doc.thresholds)}
</div>`;
}

async function fetchStatus(){
  try{
    const r=await fetch('/api/status');
    if(!r.ok) throw new Error('HTTP '+r.status);
    render(await r.json());
  } catch(e){ document.getElementById('etxt').textContent='Error: '+e.message; }
}
function startCountdown(){
  clearInterval(cdTimer); cdVal=REFRESH;
  const fill=document.getElementById('cd-fill'), num=document.getElementById('cd-num');
  fill.style.transition='none'; fill.style.width='100%';
  void fill.offsetWidth;
  fill.style.transition=`width ${REFRESH}s linear`; fill.style.width='0%';
  cdTimer=setInterval(()=>{ num.textContent=--cdVal; if(cdVal<=0){ clearInterval(cdTimer); fetchStatus().then(startCountdown); } },1000);
}
fetchStatus().then(startCountdown);
</script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            body = HTML.encode("utf-8")
            self._send(body, "text/html; charset=utf-8")
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
