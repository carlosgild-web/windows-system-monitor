"""What the console's /api/ai/* routes call. No HTTP here: methods return (status, body).

- One run at a time: a small local model is slow, and two runs at once would only
  thrash it. A second request while one runs gets 409 with the running run's id.
- A run works in a background thread; its trace is saved after every step, and the
  console page polls GET /api/ai/runs/{id} until the status is no longer "running".
- The client (Ollama model, fallback model or rules) is chosen per run and the choice
  is cached for CHOICE_TTL_SEC, so the status call does not probe Ollama every time.
"""
from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Tuple

from .agent import AssistantRun
from .base import TASKS
from .factory import ClientChoice, choose_client
from .settings import AiSettings
from .tools import ToolContext, ToolRegistry
from .trace import TraceStore

CHOICE_TTL_SEC = 30.0
MAX_ID_LEN = 300
LANGUAGES = ("en", "es")

Response = Tuple[int, Dict[str, Any]]


class AssistantService:
    def __init__(self, settings_file: Path, logs_dir: Path, *, demo_mode: bool = False,
                 chooser: Callable[..., ClientChoice] = choose_client, run_in_thread: bool = True,
                 ai_overrides: Optional[Dict[str, Any]] = None, unavailable_hint: str = ""):
        # ai_overrides replace fields of the settings' "ai" section for the assistant only (the
        # Docker demo's Ollama container, docs/docker.md); the file on disk is not changed.
        # unavailable_hint is added to the reason when the rules answer instead of the model.
        self.settings_file = Path(settings_file)
        self.logs_dir = Path(logs_dir)
        self.demo_mode = demo_mode
        self.ai_overrides = dict(ai_overrides or {})
        self.unavailable_hint = unavailable_hint
        self.chooser = chooser
        self.run_in_thread = run_in_thread
        self._lock = threading.Lock()
        self._active: Optional[str] = None
        self._live: Dict[str, str] = {}          # run id -> latest trace (JSON) while it runs
        self._choice: Optional[Tuple[float, AiSettings, ClientChoice]] = None

    # ---- helpers ---------------------------------------------------------------------
    def load_settings(self) -> Dict[str, Any]:
        try:
            data = json.loads(self.settings_file.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            return {}
        if not isinstance(data, dict):
            return {}
        if self.ai_overrides:
            data["ai"] = dict(data.get("ai") if isinstance(data.get("ai"), dict) else {}, **self.ai_overrides)
        return data

    def _registry(self) -> ToolRegistry:
        return ToolRegistry(ToolContext(self.logs_dir, self.load_settings))

    def _choose(self, settings: AiSettings, fresh: bool = False) -> ClientChoice:
        cached = self._choice
        if not fresh and cached and cached[1] == settings and time.monotonic() - cached[0] < CHOICE_TTL_SEC:
            return cached[2]
        choice = self.chooser(settings, demo_mode=self.demo_mode)
        if self.unavailable_hint and not choice.client.is_ai:
            choice = ClientChoice(choice.client, f"{choice.reason} {self.unavailable_hint}")
        self._choice = (time.monotonic(), settings, choice)
        return choice

    def _store(self, settings: AiSettings) -> TraceStore:
        return TraceStore(self.logs_dir / "ai_traces", settings.max_traces)

    # ---- API -------------------------------------------------------------------------
    def status(self) -> Response:
        settings = AiSettings.from_config(self.load_settings())
        choice = self._choose(settings)
        return 200, {"ok": True, "enabled": settings.enabled, "busy": self._active,
                     "client": {"kind": choice.client.kind, "model": choice.client.model,
                                "label": choice.client.label, "is_ai": choice.client.is_ai, "reason": choice.reason}}

    def start(self, task: str, body: Any) -> Response:
        if task not in TASKS:
            return 404, {"ok": False, "error": "unknown task"}
        if not isinstance(body, dict):
            return 400, {"ok": False, "error": "send a JSON object such as {\"incident_id\": \"...\"}"}
        incident_id = body.get("incident_id")
        language = body.get("language", "en")
        if not isinstance(incident_id, str) or not incident_id.strip() or len(incident_id) > MAX_ID_LEN \
                or "`" in incident_id or "\n" in incident_id or "\r" in incident_id:
            return 400, {"ok": False, "error": "incident_id must be the id of an open incident"}
        if language not in LANGUAGES:
            return 400, {"ok": False, "error": "language must be en or es"}

        registry = self._registry()
        found, ok = registry.run("get_incident", {"incident_id": incident_id})
        if not ok or "error" in found:
            return 404, {"ok": False, "error": found.get("error", "no open incident with that id")}

        with self._lock:
            if self._active is not None:
                return 409, {"ok": False, "error": "The assistant is already working on another request.",
                             "run_id": self._active}
            settings = AiSettings.from_config(self.load_settings())
            choice = self._choose(settings, fresh=True)
            run = AssistantRun(task, incident_id, client=choice.client, registry=registry, settings=settings,
                               store=self._store(settings), reason=choice.reason, language=language,
                               on_save=self._remember)
            run_id = run.trace["id"]
            self._remember(run.trace)              # GET /api/ai/runs/{id} works at once
            self._active = run_id

        def work() -> None:
            try:
                run.run()
            finally:
                with self._lock:
                    if self._active == run_id:
                        self._active = None
                    if not run.trace.get("save_error"):
                        self._live.pop(run_id, None)   # from now on the file on disk is complete

        if self.run_in_thread:
            threading.Thread(target=work, name=f"ai-run-{run_id}", daemon=True).start()
        else:
            work()
        return 202, {"ok": True, "run_id": run_id, "client": run.trace["client"]}

    def _remember(self, trace: Dict[str, Any]) -> None:
        # A JSON snapshot, so a poll never reads the dict while the run thread changes it,
        # and never opens the trace file while the run thread replaces it.
        self._live[trace["id"]] = json.dumps(trace, ensure_ascii=False)

    def get_run(self, run_id: str) -> Response:
        live = self._live.get(run_id)
        if live is not None:
            return 200, {"ok": True, "run": json.loads(live)}
        store = self._store(AiSettings.from_config(self.load_settings()))
        try:
            trace = store.load(run_id)
        except ValueError:
            trace = None
        if trace is None:
            return 404, {"ok": False, "error": "no run with that id"}
        return 200, {"ok": True, "run": trace}
