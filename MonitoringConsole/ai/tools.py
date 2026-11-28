"""The assistant's tools. They only read: the state files, logs/monitor.log and the settings.

Invariant 2 (tests/python/test_ai_agent.py checks it): no tool has a side effect. Each
tool is a plain function of (context, arguments) that opens files for reading only.
The registry validates every argument before a tool runs, and rejects unknown tools
and unknown arguments, so whatever a model asks for, nothing else can happen.

Invariant 4: what the tools return (process names, document values, log lines) is data.
It goes back to the model as a role "tool" message, never into the system prompt.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

MONITORS = ("process", "performance", "disk", "network", "document")
STATE_FILES = {
    "process": "process_state.json",
    "performance": "performance_state.json",
    "disk": "disk_state.json",
    "network": "network_state.json",
    "document": "document_state.json",
}
ROW_LISTS = {"process": "processes", "performance": "metrics", "disk": "drives", "network": "hosts",
             "document": "documents"}
ROW_KEYS = {"process": "name", "performance": "name", "disk": "drive", "network": "name", "document": "display_name"}
VALUE_UNITS = {
    "process": "none (a process is running or not)",
    "performance": "percent of CPU or memory in use",
    "disk": "percent of the drive in use",
    "network": "milliseconds of latency (null: the host does not answer)",
    "document": "percent of the document's target (not money or file size; see current.total and current.target)",
}
EMAIL_RE = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
MAX_STR = 200
MAX_EVENTS = 20
LOG_TAIL_BYTES = 256 * 1024


def as_list(value) -> list:
    """"document" is a list since v1.7; a v1.6 single object is still accepted."""
    if isinstance(value, list):
        return [v for v in value if isinstance(v, dict)]
    return [value] if isinstance(value, dict) else []


@dataclass
class ToolContext:
    """Where the tools read from. `load_settings` returns the settings dict (read fresh)."""

    logs_dir: Path
    load_settings: Callable[[], Dict[str, Any]]
    now: Callable[[], datetime] = datetime.now

    def read_state(self, monitor: str) -> Dict[str, Any]:
        try:
            data = json.loads((self.logs_dir / STATE_FILES[monitor]).read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}


class ToolError(Exception):
    """A bad call: unknown tool, bad argument. Sent back to the model as the tool result."""


# ---- Settings lookups ---------------------------------------------------------------
def _items(cfg: Dict[str, Any], monitor: str) -> List[Tuple[str, Dict[str, Any]]]:
    """(target, item config, path) for each item of a monitor, target as the state files name it."""
    if monitor == "process":
        return [(str(p.get("name")), p) for p in as_list(cfg.get("processes"))]
    if monitor == "performance":
        perf = cfg.get("performance") if isinstance(cfg.get("performance"), dict) else {}
        return [(k, perf[k]) for k in ("cpu", "memory") if isinstance(perf.get(k), dict)]
    if monitor == "disk":
        return [(str(d.get("drive")), d) for d in as_list(cfg.get("disk"))]
    if monitor == "network":
        return [(str(n.get("name") or n.get("host")), n) for n in as_list(cfg.get("network"))]
    return [(str(d.get("display_name") or "Document"), d) for d in as_list(cfg.get("document"))]


def _item(cfg: Dict[str, Any], monitor: str, target: str) -> Optional[Dict[str, Any]]:
    for name, item in _items(cfg, monitor):
        if name == target:
            return item
    return None


def _max_interval(cfg: Dict[str, Any], monitor: str) -> float:
    vals = [(cfg.get("global") or {}).get("check_interval_sec")]
    vals += [item.get("check_interval_sec") for _, item in _items(cfg, monitor)]
    nums = [float(v) for v in vals if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0]
    return max(nums) if nums else 60.0


def _redact(value: Any) -> Any:
    """Copies settings with e-mail addresses replaced, so they never reach the model."""
    if isinstance(value, dict):
        return {k: _redact(v) for k, v in value.items() if k != "_comment"}
    if isinstance(value, list):
        return [_redact(v) for v in value]
    if isinstance(value, str):
        return EMAIL_RE.sub("[e-mail redacted]", value)
    return value


# ---- The tools ------------------------------------------------------------------------
def get_incident(ctx: ToolContext, incident_id: str) -> Dict[str, Any]:
    monitor = incident_id.split(":", 1)[0]
    if monitor not in MONITORS:
        return {"error": f"no open incident with id {incident_id!r}"}
    state = ctx.read_state(monitor)
    found = next((i for i in state.get("incidents") or [] if isinstance(i, dict) and i.get("id") == incident_id), None)
    if found is None:
        return {"error": f"no open incident with id {incident_id!r}; it may have closed"}
    result = dict(found)
    # What threshold, peak and last_value are measured in (the records carry bare numbers).
    result["value_unit"] = VALUE_UNITS[monitor]
    row_key = ROW_KEYS[monitor]
    row = next((r for r in state.get(ROW_LISTS[monitor]) or []
                if isinstance(r, dict) and str(r.get(row_key)) == str(found.get("target"))), None)
    if row is not None:
        result["current"] = {k: v for k, v in row.items() if k != "path"}
    cfg = ctx.load_settings()
    updated = state.get("updated")
    try:
        age = (ctx.now() - datetime.strptime(str(updated), "%Y-%m-%d %H:%M:%S")).total_seconds()
    except ValueError:
        age = None
    limit = 2 * _max_interval(cfg, monitor) + 15
    result["monitor_state_updated"] = updated
    result["monitor_stale"] = age is None or age > limit
    if result["monitor_stale"]:
        # Small models read a sentence more reliably than a boolean.
        result["note"] = (f"The {monitor} monitor has not updated its state since {updated}: this data may be out "
                          f"of date, or the monitor may have stopped. Say so in the answer.")
    return result


def _log_terms(cfg: Dict[str, Any], monitor: str, target: str) -> List[str]:
    """What identifies the item in a log line (the monitors' message templates vary)."""
    terms = [target]
    item = _item(cfg, monitor, target) or {}
    if monitor == "performance":
        terms += {"cpu": [" CPU:"], "memory": [" MEM:"]}.get(target, [])
    elif monitor == "disk":
        terms += [f"DISK {target.rstrip(chr(92))}"]
    elif monitor == "network" and item.get("host"):
        terms += [f"{item['host']}:{item['port']}" if item.get("port") else str(item["host"]), str(item["host"])]
    elif monitor == "process":
        terms += [str(item.get("display_name") or target)]
    return [t for t in terms if t and t.strip()]


def get_recent_events(ctx: ToolContext, monitor: str, target: str, limit: int = 10) -> Dict[str, Any]:
    cfg = ctx.load_settings()
    log = Path(str((cfg.get("global") or {}).get("log_file") or "logs/monitor.log").replace("\\", "/"))
    path = log if log.is_absolute() else ctx.logs_dir.parent / log
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - LOG_TAIL_BYTES))
            text = f.read().decode("utf-8-sig", "replace")
    except OSError:
        return {"events": [], "note": "the monitor log does not exist yet"}
    terms = [t.lower() for t in _log_terms(cfg, monitor, target)]
    lines = [ln.strip() for ln in text.splitlines()[1 if size > LOG_TAIL_BYTES else 0:]]
    hits = [ln[:300] for ln in lines if ln and any(t in ln.lower() for t in terms)]
    return {"events": hits[-limit:]}


def get_runbook(ctx: ToolContext, monitor: str, target: str, level: str) -> Dict[str, Any]:
    cfg = ctx.load_settings()
    item = _item(cfg, monitor, target)
    if item is None:
        return {"runbook": None, "note": f"{monitor} {target!r} is not in the settings"}
    if monitor == "process":
        acts = ((item.get("actions") or {}).get("on_not_running")) or []
        text = next((a.get("instructions") for a in acts if isinstance(a, dict) and a.get("instructions")), None)
        return {"runbook": text, "source": "the process action's instructions"}
    for t in item.get("thresholds") or []:
        if isinstance(t, dict) and t.get("level") == level:
            text = t.get("runbook") if isinstance(t.get("runbook"), str) else None
            return {"runbook": text, "source": f"the {level} threshold" if text else "none configured"}
    return {"runbook": None, "note": f"no {level} threshold"}


def get_monitor_config(ctx: ToolContext, monitor: str, target: str) -> Dict[str, Any]:
    cfg = ctx.load_settings()
    item = _item(cfg, monitor, target)
    if item is None:
        return {"error": f"{monitor} {target!r} is not in the settings"}
    return {"monitor": monitor, "target": target, "config": _redact(item)}


# ---- Registry -------------------------------------------------------------------------
@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    params: Dict[str, Dict[str, Any]]   # name -> JSON schema (type string|integer, enum, min/max)
    required: Tuple[str, ...]
    func: Callable[..., Dict[str, Any]]
    side_effects: bool = False          # every tool here must keep this False (a test checks)

    def schema(self) -> Dict[str, Any]:
        return {"type": "function", "function": {
            "name": self.name, "description": self.description,
            "parameters": {"type": "object", "properties": self.params, "required": list(self.required)}}}


_TARGET = {"type": "string", "description": "the incident's target, exactly as get_incident returns it"}
_MONITOR = {"type": "string", "enum": list(MONITORS)}
TOOLS = (
    Tool("get_incident", "Read one open incident: monitor, target, level, value, threshold, peak, start time, "
         "sustain, the current reading and whether the monitor is stale.",
         {"incident_id": {"type": "string"}}, ("incident_id",), get_incident),
    Tool("get_recent_events", "Read the latest monitor log lines about one item.",
         {"monitor": _MONITOR, "target": _TARGET,
          "limit": {"type": "integer", "minimum": 1, "maximum": MAX_EVENTS}}, ("monitor", "target"), get_recent_events),
    Tool("get_runbook", "Read the runbook (what to do) configured for one item and level.",
         {"monitor": _MONITOR, "target": _TARGET, "level": {"type": "string", "enum": ["warning", "critical"]}},
         ("monitor", "target", "level"), get_runbook),
    Tool("get_monitor_config", "Read one item's settings: thresholds and actions (e-mail addresses redacted).",
         {"monitor": _MONITOR, "target": _TARGET}, ("monitor", "target"), get_monitor_config),
)


class ToolRegistry:
    def __init__(self, ctx: ToolContext, tools=TOOLS):
        self.ctx = ctx
        self.tools = {t.name: t for t in tools}

    def schemas(self) -> List[Dict[str, Any]]:
        return [t.schema() for t in self.tools.values()]

    def parse_args(self, name: str, arguments: Any) -> Dict[str, Any]:
        tool = self.tools.get(name)
        if tool is None:
            raise ToolError(f"unknown tool {name!r}; the tools are: {', '.join(self.tools)}")
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments) if arguments.strip() else {}
            except ValueError:
                raise ToolError("arguments are not valid JSON") from None
        if arguments is None:
            arguments = {}
        if not isinstance(arguments, dict):
            raise ToolError("arguments must be an object")
        extra = set(arguments) - set(tool.params)
        if extra:
            raise ToolError(f"unknown argument(s): {', '.join(sorted(map(str, extra)))}")
        for req in tool.required:
            if req not in arguments:
                raise ToolError(f"missing argument {req!r}")
        clean = {}
        for key, value in arguments.items():
            spec = tool.params[key]
            if spec["type"] == "integer":
                if isinstance(value, str) and value.strip().isdigit():
                    value = int(value)
                if isinstance(value, bool) or not isinstance(value, int):
                    raise ToolError(f"{key} must be a whole number")
                value = max(spec.get("minimum", value), min(spec.get("maximum", value), value))
            else:
                if not isinstance(value, str) or not value.strip() or len(value) > MAX_STR:
                    raise ToolError(f"{key} must be a non-empty text of at most {MAX_STR} characters")
                if "enum" in spec and value not in spec["enum"]:
                    raise ToolError(f"{key} must be one of: {', '.join(spec['enum'])}")
            clean[key] = value
        return clean

    def run(self, name: str, arguments: Any) -> Tuple[Dict[str, Any], bool]:
        """(result, ok). A bad call is answered with {"error": ...} and ok False; it never raises."""
        try:
            args = self.parse_args(name, arguments)
            return self.tools[name].func(self.ctx, **args), True
        except ToolError as exc:
            return {"error": str(exc)}, False
        except Exception as exc:  # a reading bug must not end the run without a trace
            return {"error": f"the tool failed: {type(exc).__name__}"}, False
