"""DemoClient: the assistant without a model. Rules and templates, labelled
"Demo (rules, no AI)" in the console. Used when ai.enabled is false, when Ollama does
not answer, and in the Docker demo.

It speaks the same protocol as a model, so the loop, the traces and the Agent steps
view are the same: it asks for get_incident, then get_recent_events and get_runbook,
then writes the answer from the tool results only. Every number it writes comes from
a tool result, so the answer check always passes on it.

Tool results it reads (the "content" of role "tool" messages, JSON):
- get_incident: an incident record (see New-IncidentRecord), or {"error": ...}.
- get_recent_events: {"events": ["log line", ...]}.
- get_runbook: {"runbook": "1. ...\\n2. ..."} or {"runbook": null}.
"""
from __future__ import annotations

import json
from typing import Any, Dict, List, Optional

from .base import TASK_TICKET, ChatClient, ChatTurn, ToolCall, parse_task

LIKELY_CAUSES = {
    "cpu": ["A process is using the CPU heavily: an update, an indexer, a scan or a runaway application."],
    "memory": ["An application is holding a lot of memory, or several large ones are open.",
               "A process that keeps growing may be leaking memory."],
    "disk": ["Files are piling up: downloads, temporary files, logs or Windows updates."],
    "network_down": ["The connection is down, the target is down, or a firewall blocks it."],
    "network_slow": ["The network is congested, or the route to the host is slow."],
    "document": ["The tracked value passed its share of the target: new rows, larger amounts or a larger file."],
    "process": ["The process was closed, crashed, or did not start."],
}


UNITS = {"performance": "%", "disk": "% used", "network": " ms", "document": "% of target"}


def _val(inc: Dict[str, Any], key: str) -> str:
    """A measured number with the unit of its monitor (the records carry bare numbers)."""
    return _fmt(inc[key]) + UNITS.get(str(inc.get("monitor")), "")


def _fmt(v: Any) -> str:
    if isinstance(v, bool) or v is None:
        return str(v)
    if isinstance(v, (int, float)):
        return f"{v:g}"
    return str(v)


def _tool_results(messages: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Latest parsed result per tool name (unparseable results count as {})."""
    out: Dict[str, Any] = {}
    for m in messages:
        if m.get("role") != "tool":
            continue
        try:
            value = json.loads(m.get("content") or "")
        except ValueError:
            value = {}
        out[str(m.get("tool_name") or "")] = value if isinstance(value, dict) else {}
    return out


def _cause_key(inc: Dict[str, Any]) -> str:
    monitor, target = inc.get("monitor"), str(inc.get("target") or "").lower()
    if monitor == "performance":
        return "memory" if target == "memory" else "cpu"
    if monitor == "network":
        return "network_down" if inc.get("last_value") is None else "network_slow"
    return monitor if monitor in LIKELY_CAUSES else "process"


def _what_happened(inc: Dict[str, Any]) -> List[str]:
    who = f"{inc.get('target')} ({inc.get('monitor')})"
    lines = [f"{who} has an open {inc.get('level')} incident."]
    facts = []
    if inc.get("last_value") is not None:
        facts.append(f"last value {_val(inc, 'last_value')}")
    if inc.get("threshold") is not None:
        facts.append(f"threshold {_val(inc, 'threshold')}")
    if inc.get("peak") is not None:
        facts.append(f"peak {_val(inc, 'peak')}")
    if inc.get("monitor") == "network" and inc.get("last_value") is None:
        facts.append("the host does not answer")
    if inc.get("monitor") == "process":
        facts.append("the process is not running")
    if facts:
        lines.append("Measured: " + ", ".join(facts) + ".")
    cur = inc.get("current") if isinstance(inc.get("current"), dict) else {}
    reading = _current_reading(inc.get("monitor"), cur)
    if reading:
        lines.append(reading)
    if inc.get("opened_at"):
        since = f"Open since {inc['opened_at']}"
        if inc.get("exceeded_since") and inc.get("exceeded_since") != inc.get("opened_at"):
            since += f" (past the threshold since {inc['exceeded_since']}, sustain {_fmt(inc.get('sustain_sec'))} s)"
        lines.append(since + ".")
    if inc.get("alert_count"):
        lines.append(f"Alerts so far: {_fmt(inc['alert_count'])}.")
    if inc.get("monitor_stale"):
        lines.append(f"The {inc.get('monitor')} monitor has not updated its state since "
                     f"{inc.get('monitor_state_updated')}: this data may be out of date.")
    return lines


def _current_reading(monitor: Any, cur: Dict[str, Any]) -> str:
    """The item's current reading, from get_incident's "current" row."""
    if monitor == "document" and cur.get("total") is not None and cur.get("target") is not None:
        unit = str(cur.get("unit") or "")
        if cur.get("measure") == "file_size":
            return f"Current: {_fmt(cur['total'])} {unit} of {_fmt(cur['target'])} {unit}."
        return f"Current total: {unit}{_fmt(cur['total'])} of a {unit}{_fmt(cur['target'])} target."
    if monitor == "network" and cur.get("host"):
        where = f"{cur['host']}:{cur['port']}" if cur.get("port") else str(cur["host"])
        return f"Target {where} ({str(cur.get('protocol') or '').upper()}), " + \
               ("reachable." if cur.get("reachable") else "not answering.")
    if monitor == "disk" and cur.get("free_gb") is not None:
        return f"Free space: {_fmt(cur['free_gb'])} GB."
    return ""


def _runbook_steps(runbook: Optional[str]) -> List[str]:
    """The runbook's lines as written (their own numbering kept, so no number is added)."""
    return [line.strip() for line in (runbook or "").splitlines() if line.strip()]


class DemoClient(ChatClient):
    kind = "demo"
    is_ai = False
    model = "rules"

    def chat(self, messages: List[Dict[str, Any]], tools: List[Dict[str, Any]], *,
             max_tokens: int = 1024) -> ChatTurn:
        offered = {t.get("function", {}).get("name") for t in tools or [] if isinstance(t, dict)}
        task = parse_task(messages)
        if task is None:
            return ChatTurn(content="The demo assistant only explains an incident from the console.")
        kind, incident_id = task
        results = _tool_results(messages)

        if "get_incident" not in results and "get_incident" in offered:
            return ChatTurn(tool_calls=[ToolCall("get_incident", {"incident_id": incident_id})])
        inc = results.get("get_incident") or {}
        if not inc.get("id"):
            reason = inc.get("error") or "it is not open any more"
            return ChatTurn(content=f"Incident `{incident_id}` could not be read: {reason}.")

        follow_up = []
        if "get_recent_events" not in results and "get_recent_events" in offered:
            follow_up.append(ToolCall("get_recent_events", {"monitor": inc.get("monitor"), "target": inc.get("target"),
                                                            "limit": 5}))
        if "get_runbook" not in results and "get_runbook" in offered:
            follow_up.append(ToolCall("get_runbook", {"monitor": inc.get("monitor"), "target": inc.get("target"),
                                                      "level": inc.get("level")}))
        if follow_up:
            return ChatTurn(tool_calls=follow_up)

        steps = _runbook_steps((results.get("get_runbook") or {}).get("runbook"))
        events = [str(e) for e in (results.get("get_recent_events") or {}).get("events") or []]
        if kind == TASK_TICKET:
            return ChatTurn(content=json.dumps(self._ticket(inc, steps, events), ensure_ascii=False))
        return ChatTurn(content=self._explanation(inc, steps, events))

    @staticmethod
    def _next_steps(steps: List[str]) -> List[str]:
        if steps:
            return ["From the runbook:"] + steps
        return ["No runbook is configured for this threshold. Check the item on the console, then add a runbook "
                "to the threshold in the settings editor."]

    def _explanation(self, inc: Dict[str, Any], steps: List[str], events: List[str]) -> str:
        parts = ["What happened"] + [f"- {x}" for x in _what_happened(inc)]
        if events:
            parts.append("- The recent log lines for it are in Agent steps.")
        parts += ["", "Likely causes"] + [f"- {x}" for x in LIKELY_CAUSES[_cause_key(inc)]]
        parts += ["", "Next steps"] + [f"- {x}" for x in self._next_steps(steps)]
        return "\n".join(parts)

    def _ticket(self, inc: Dict[str, Any], steps: List[str], events: List[str]) -> Dict[str, str]:
        short = f"{str(inc.get('level', '')).capitalize()}: {inc.get('target')} ({inc.get('monitor')})"
        if inc.get("last_value") is not None and inc.get("threshold") is not None:
            short += f" at {_val(inc, 'last_value')}, threshold {_val(inc, 'threshold')}"
        elif inc.get("monitor") == "network":
            short += " unreachable"
        elif inc.get("monitor") == "process":
            short += " not running"
        description = "\n".join(_what_happened(inc) + ["", "Likely causes:"] +
                                [f"- {x}" for x in LIKELY_CAUSES[_cause_key(inc)]])
        notes = "\n".join(["Next steps:"] + [f"- {x}" for x in self._next_steps(steps)] +
                          (["Recent log lines: see the assistant's Agent steps."] if events else []))
        return {"short_description": short, "description": description, "work_notes": notes}
