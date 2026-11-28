"""FakeClient: a scripted model for the tests (and the scripted GIF). No network."""
from __future__ import annotations

import copy
from typing import Any, Dict, List, Optional, Sequence, Union

from .base import ChatClient, ChatTurn


class FakeClient(ChatClient):
    """Each chat() call returns the next scripted ChatTurn, or raises it when it is an
    exception. `calls` records a deep copy of what each call was sent, so tests can
    check the messages, the tools offered and max_tokens."""

    kind = "fake"
    is_ai = True

    def __init__(self, turns: Optional[Sequence[Union[ChatTurn, Exception]]] = None, model: str = "fake-model"):
        self.turns: List[Union[ChatTurn, Exception]] = list(turns or [])
        self.calls: List[Dict[str, Any]] = []
        self.model = model

    def chat(self, messages: List[Dict[str, Any]], tools: List[Dict[str, Any]], *,
             max_tokens: int = 1024) -> ChatTurn:
        self.calls.append({"messages": copy.deepcopy(messages), "tools": copy.deepcopy(tools),
                           "max_tokens": max_tokens})
        if not self.turns:
            return ChatTurn(content="[fake answer]")
        turn = self.turns.pop(0)
        if isinstance(turn, Exception):
            raise turn
        return turn
