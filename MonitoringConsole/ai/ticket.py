"""Ticket fields (invariant 1). The model writes three text fields; the code sets the rest.

The category, assignment group, impact, urgency, priority and severity come from the
incident's monitor and level, with the same table as web/ticket.html (a test keeps the
two equal). Whatever the model returns, only the three text fields are taken from it.
"""
from __future__ import annotations

import json
import re
from typing import Any, Dict, Optional

MONITORS = {
    "process": {"category": "Software", "subcategory": "Application", "assignment_group": "Application Support"},
    "performance": {"category": "Hardware", "subcategory": "CPU / Memory", "assignment_group": "Server Operations"},
    "disk": {"category": "Hardware", "subcategory": "Storage", "assignment_group": "Server Operations"},
    "network": {"category": "Network", "subcategory": "Connectivity", "assignment_group": "Network Operations"},
    "document": {"category": "Business application", "subcategory": "Data threshold",
                 "assignment_group": "Business Systems"},
}
UNKNOWN_MONITOR = {"category": "Monitoring", "subcategory": "Alert", "assignment_group": "IT Operations"}
LEVELS = {
    "critical": {"impact": "1 - High", "urgency": "1 - High", "priority": "1 - Critical", "severity": "1 - High"},
    "warning": {"impact": "2 - Medium", "urgency": "2 - Medium", "priority": "3 - Moderate", "severity": "2 - Medium"},
}
TEXT_FIELDS = {"short_description": 160, "description": 4000, "work_notes": 4000}


def code_fields(incident: Dict[str, Any]) -> Dict[str, str]:
    """The fields the model never sets."""
    level = incident.get("level") if incident.get("level") in LEVELS else "warning"
    return dict(MONITORS.get(str(incident.get("monitor")), UNKNOWN_MONITOR), **LEVELS[level])


def parse_draft(content: str) -> Optional[Dict[str, str]]:
    """The three text fields from the model's answer (JSON, possibly in a ``` fence or
    with text around it). Other keys are dropped. None when no usable JSON is found."""
    text = (content or "").strip()
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    candidates = [fenced.group(1)] if fenced else []
    start, end = text.find("{"), text.rfind("}")
    if start != -1 and end > start:
        candidates.append(text[start:end + 1])
    for cand in candidates:
        try:
            data = json.loads(cand)
        except ValueError:
            continue
        if not isinstance(data, dict):
            continue
        draft = {k: str(data.get(k) or "").strip()[:limit] for k, limit in TEXT_FIELDS.items()}
        if draft["short_description"]:
            return draft
    return None
