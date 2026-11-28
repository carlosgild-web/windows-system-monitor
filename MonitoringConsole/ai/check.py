"""The answer check (invariant 3): every number in an answer must appear in a tool result.

Numbers are compared by value, so "97.20" matches 97.2 and "1,234" matches 1234. List
markers at the start of a line ("1." or "2)") are not facts and are skipped. A number the
check cannot trace is reported, and the console flags it next to the answer.
"""
from __future__ import annotations

import json
import re
from decimal import Decimal, InvalidOperation
from typing import Any, Dict, Iterable, List, Set

_NUMBER = re.compile(r"(?<![\w.])-?\d{1,3}(?:,\d{3})+(?:\.\d+)?(?![\w])|(?<![\w.])-?\d+(?:\.\d+)?")
_LIST_MARKER = re.compile(r"^\s*(?:[-*]\s*)?\d+[.)](?=\s)", re.M)


def _value(text: str):
    try:
        return Decimal(text.replace(",", "")).normalize()
    except InvalidOperation:
        return None


def numbers_in(text: str) -> List[str]:
    """The numbers written in `text`, as written, without list markers."""
    return [m.group(0) for m in _NUMBER.finditer(_LIST_MARKER.sub(" ", text or ""))]


def _source_values(sources: Iterable[Any]) -> Set[Decimal]:
    values: Set[Decimal] = set()
    for src in sources:
        text = src if isinstance(src, str) else json.dumps(src, ensure_ascii=False)
        for raw in _NUMBER.findall(text):
            v = _value(raw)
            if v is not None:
                values.add(v)
                values.add(abs(v))
    return values


def check_numbers(answer: str, sources: Iterable[Any]) -> Dict[str, Any]:
    """{"checked": [...], "untraced": [...], "ok": bool} for the numbers in `answer`.
    `sources` are the tool results (dicts) and any other text the answer may quote."""
    known = _source_values(sources)
    checked, untraced = [], []
    for raw in numbers_in(answer):
        v = _value(raw)
        if v is None:
            continue
        (checked if v in known or abs(v) in known else untraced).append(raw)
    return {"checked": sorted(set(checked), key=checked.index),
            "untraced": sorted(set(untraced), key=untraced.index),
            "ok": not untraced}
