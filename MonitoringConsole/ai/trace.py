"""Run traces (invariant 6): every run is saved as JSON under logs/ai_traces/.

A run's file is rewritten after each step, so the console can poll GET /api/ai/runs/{id}
while it is in progress. Only the newest `max_traces` files are kept.
"""
from __future__ import annotations

import json
import os
import re
import secrets
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Optional

RUN_ID_RE = re.compile(r"^\d{8}-\d{6}-[0-9a-f]{8}$")


class TraceStore:
    def __init__(self, directory: Path, max_traces: int = 200):
        self.dir = Path(directory)
        self.max_traces = max(1, int(max_traces))

    @staticmethod
    def new_id(now: Optional[datetime] = None) -> str:
        return f"{(now or datetime.now()).strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(4)}"

    def path(self, run_id: str) -> Path:
        if not RUN_ID_RE.match(str(run_id)):           # never a path from the request
            raise ValueError("bad run id")
        return self.dir / f"{run_id}.json"

    def save(self, trace: Dict[str, Any]) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        path = self.path(trace["id"])
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(trace, indent=2, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, path)

    def load(self, run_id: str) -> Optional[Dict[str, Any]]:
        try:
            return json.loads(self.path(run_id).read_text(encoding="utf-8"))
        except (ValueError, OSError):
            return None

    def rotate(self) -> int:
        """Deletes the oldest traces beyond max_traces. Returns how many were deleted."""
        try:
            files = sorted(p for p in self.dir.glob("*.json") if RUN_ID_RE.match(p.stem))
        except OSError:
            return 0
        extra = files[:-self.max_traces] if len(files) > self.max_traces else []
        for p in extra:
            try:
                p.unlink()
            except OSError:
                pass
        return len(extra)
