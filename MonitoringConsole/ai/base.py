"""The one interface every model client implements, and the messages they share.

A client answers one chat turn in Ollama's chat format: `messages` is a list of
{"role", "content", ...} dicts (roles system, user, assistant, tool) and `tools` is
Ollama's `tools` list. The reply is a `ChatTurn`: text, tool calls, or both.

Three clients implement it:
- `OllamaClient` (ollama.py): a local model over HTTP, standard library only.
- `DemoClient` (demo.py): rules and templates, no model. Labelled "Demo (rules, no AI)".
- `FakeClient` (fake.py): scripted turns for the tests.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple, Union

# The two things the assistant is asked to do. The loop (A3) builds the first user
# message with `task_message()`, so every client, including the rule-based one, can
# tell which task it is and which incident it is about.
TASK_EXPLAIN = "explain"
TASK_TICKET = "ticket"
TASKS = (TASK_EXPLAIN, TASK_TICKET)

_TASK_RE = re.compile(r"^Task: (\w+)\nIncident: `([^`\n]+)`", re.M)


def task_message(task: str, incident_id: str) -> str:
    """The first line of the user message: the task and the incident, in backticks
    because incident ids may contain spaces ("network:Monitoring Console:critical")."""
    if task not in TASKS:
        raise ValueError(f"unknown task {task!r}")
    if "`" in incident_id or "\n" in incident_id:
        raise ValueError("incident id must not contain backticks or new lines")
    return f"Task: {task}\nIncident: `{incident_id}`"


def parse_task(messages: List[Dict[str, Any]]) -> Optional[Tuple[str, str]]:
    """(task, incident_id) from the first user message, or None."""
    for m in messages:
        if m.get("role") == "user":
            match = _TASK_RE.search(str(m.get("content") or ""))
            if match and match.group(1) in TASKS:
                return match.group(1), match.group(2)
            return None
    return None


@dataclass(frozen=True)
class ToolCall:
    """One function call the model asked for. `arguments` is what the model sent:
    usually a dict, sometimes a JSON string; the tool registry parses either."""

    name: str
    arguments: Union[Dict[str, Any], str, None] = None


@dataclass(frozen=True)
class ChatTurn:
    """One reply: text, tool calls, or both, plus the token counts the server reported
    (0 when it reports none, as the rule-based client never does)."""

    content: str = ""
    tool_calls: List[ToolCall] = field(default_factory=list)
    prompt_tokens: int = 0
    completion_tokens: int = 0


class AIError(Exception):
    """A model call failed. `reason` is safe to show in the console."""

    def __init__(self, reason: str, *, retryable: bool = False):
        super().__init__(reason)
        self.reason = reason
        self.retryable = retryable


class ChatClient:
    """Base class. `kind` is "ollama", "demo" or "fake"; `is_ai` is False for the
    rule-based client, and the UI labels its answers "Demo (rules, no AI)"."""

    kind = "base"
    is_ai = True
    model = ""

    @property
    def label(self) -> str:
        return self.model if self.is_ai else "Demo (rules, no AI)"

    def chat(self, messages: List[Dict[str, Any]], tools: List[Dict[str, Any]], *,
             max_tokens: int = 1024) -> ChatTurn:
        """One non-streaming chat turn. An empty `tools` list means: answer in text.
        `max_tokens` caps this turn's output. Raises AIError on failure."""
        raise NotImplementedError
