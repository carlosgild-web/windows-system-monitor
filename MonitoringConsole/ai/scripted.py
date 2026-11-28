"""ScriptedClient: replays a fixed model script, for the README GIF (e2e/showcase/).

Only used when the console starts with WSM_AI_SCRIPT pointing at a JSON script (the showcase
runner sets it). Everything around the model is real: the tools read the real state files,
the grounding gate and the number check run, the trace is real. Only the model's turns are
fixed, and the UI labels the client "Scripted replay (no AI)".

Script format:
    {"delay_sec": 1.5,
     "explain": [{"tool_calls": [{"name": "get_incident", "arguments": {...}}]}, {"content": "..."}],
     "ticket":  [...]}
Turn n of a run is the n-th model call, counted from the assistant messages already sent.
"""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Dict, List

from .base import AIError, ChatClient, ChatTurn, ToolCall, parse_task


class ScriptedClient(ChatClient):
    kind = "scripted"
    is_ai = False
    model = "scripted-replay"

    def __init__(self, script_path: Path):
        try:
            self.script = json.loads(Path(script_path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise AIError(f"the GIF script could not be read: {exc}") from None
        self.delay = float(self.script.get("delay_sec", 0))

    @property
    def label(self) -> str:
        return "Scripted replay (no AI)"

    def chat(self, messages: List[Dict[str, Any]], tools: List[Dict[str, Any]], *,
             max_tokens: int = 1024) -> ChatTurn:
        task = parse_task(messages)
        turns = self.script.get(task[0], []) if task else []
        n = sum(1 for m in messages if m.get("role") == "assistant")
        if n >= len(turns):
            raise AIError("the GIF script has no more turns")
        if self.delay:
            time.sleep(self.delay)          # so each step shows in the recording
        turn = turns[n]
        calls = [ToolCall(c["name"], c.get("arguments")) for c in turn.get("tool_calls", [])]
        return ChatTurn(content=turn.get("content", ""), tool_calls=calls)
