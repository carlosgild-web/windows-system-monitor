"""The incident assistant (v1.7.0): a local model explains one incident and drafts ticket text with read-only tools. It decides nothing. Standard library only.
See docs/design-decisions.md sections 10-12 and the invariants in CLAUDE.md."""
from .agent import AssistantRun, run_assistant
from .base import (TASK_EXPLAIN, TASK_TICKET, AIError, ChatClient, ChatTurn, ToolCall,
                   parse_task, task_message)
from .check import check_numbers
from .demo import DemoClient
from .factory import ClientChoice, choose_client
from .fake import FakeClient
from .ollama import OllamaClient, OllamaError
from .settings import AiSettings, is_loopback_url
from .ticket import code_fields, parse_draft
from .tools import ToolContext, ToolRegistry
from .trace import TraceStore

__all__ = [
    "AssistantRun", "run_assistant",
    "TASK_EXPLAIN", "TASK_TICKET", "AIError", "ChatClient", "ChatTurn", "ToolCall", "parse_task", "task_message",
    "check_numbers", "DemoClient", "ClientChoice", "choose_client", "FakeClient", "OllamaClient", "OllamaError",
    "AiSettings", "is_loopback_url", "code_fields", "parse_draft", "ToolContext", "ToolRegistry", "TraceStore",
]
