"""OllamaClient: Ollama's native /api/chat with `tools`, over urllib (no SDK, no framework).

Safety properties, each covered by tests/python/test_ai_clients.py:
- Refuses a non-loopback URL unless ai.allow_remote is true (checked in the constructor).
- Never follows a redirect (a local server cannot bounce incident data elsewhere).
- Ignores HTTP(S)_PROXY for the call, so localhost traffic stays on the machine.
- Every call has a timeout, and a response is read up to MAX_RESPONSE_BYTES.
"""
from __future__ import annotations

import json
import socket
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional

from .base import AIError, ChatClient, ChatTurn, ToolCall
from .settings import AiSettings, is_loopback_url

MAX_RESPONSE_BYTES = 2 * 1024 * 1024
NUM_CTX = 8192


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        raise urllib.error.HTTPError(req.full_url, code, f"redirect to {newurl} refused", headers, fp)


# No ProxyHandler: urllib would otherwise send localhost traffic to a configured proxy.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


class OllamaError(AIError):
    """Ollama answered with an error, or did not answer."""

    @property
    def out_of_memory(self) -> bool:
        text = self.reason.lower()
        return "out of memory" in text or "failed to allocate" in text or "requires more system memory" in text


def _http(method: str, url: str, body: Optional[Dict[str, Any]], timeout: float, model: str = "") -> Dict[str, Any]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json", "Accept": "application/json"})
    who = f" for {model}" if model else ""
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            raw = resp.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        try:
            reason = json.loads(exc.read(64 * 1024).decode("utf-8", "replace")).get("error") or exc.reason
        except (ValueError, AttributeError, OSError):
            reason = exc.reason
        raise OllamaError(f"Ollama error {exc.code}{who}: {reason}") from None
    except (socket.timeout, TimeoutError):
        raise OllamaError(f"Ollama did not answer within {timeout:g} s{who}", retryable=True) from None
    except (urllib.error.URLError, ConnectionError, OSError) as exc:
        reason = getattr(exc, "reason", exc)
        raise OllamaError(f"Ollama is not reachable at {url.split('/api/')[0]}: {reason}", retryable=True) from None
    if len(raw) > MAX_RESPONSE_BYTES:
        raise OllamaError(f"Ollama response{who} is larger than {MAX_RESPONSE_BYTES // 1024 // 1024} MB")
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except ValueError:
        raise OllamaError(f"Ollama sent a response that is not JSON{who}") from None
    if not isinstance(parsed, dict):
        raise OllamaError(f"Ollama sent an unexpected response{who}")
    return parsed


class OllamaClient(ChatClient):
    kind = "ollama"
    is_ai = True

    def __init__(self, base_url: str, model: str, *, timeout_sec: float = 90.0, allow_remote: bool = False):
        base_url = str(base_url).rstrip("/")
        if not allow_remote and not is_loopback_url(base_url):
            raise ValueError(f"{base_url} is not this machine; set ai.allow_remote to true to use it")
        if not base_url.startswith(("http://", "https://")):
            raise ValueError("ai.ollama_url must be an http:// or https:// URL")
        self.base_url = base_url
        self.model = model
        self.timeout_sec = float(timeout_sec)

    @classmethod
    def from_settings(cls, s: AiSettings, model: Optional[str] = None) -> "OllamaClient":
        return cls(s.ollama_url, model or s.model, timeout_sec=s.timeout_sec, allow_remote=s.allow_remote)

    def list_models(self, timeout_sec: float = 3.0) -> List[str]:
        """The model tags Ollama has pulled (GET /api/tags)."""
        data = _http("GET", f"{self.base_url}/api/tags", None, timeout_sec)
        return [str(m.get("name")) for m in data.get("models") or [] if isinstance(m, dict) and m.get("name")]

    def chat(self, messages: List[Dict[str, Any]], tools: List[Dict[str, Any]], *,
             max_tokens: int = 1024) -> ChatTurn:
        body: Dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "stream": False,
            "options": {"temperature": 0, "num_ctx": NUM_CTX, "num_predict": int(max_tokens)},
        }
        if tools:
            body["tools"] = tools
        data = _http("POST", f"{self.base_url}/api/chat", body, self.timeout_sec, self.model)
        message = data.get("message") if isinstance(data.get("message"), dict) else {}
        calls = []
        for call in message.get("tool_calls") or []:
            fn = call.get("function") if isinstance(call, dict) else None
            if isinstance(fn, dict) and isinstance(fn.get("name"), str) and fn["name"]:
                calls.append(ToolCall(fn["name"], fn.get("arguments")))
        return ChatTurn(
            content=str(message.get("content") or ""),
            tool_calls=calls,
            prompt_tokens=_count(data.get("prompt_eval_count")),
            completion_tokens=_count(data.get("eval_count")),
        )


def _count(v: Any) -> int:
    return v if isinstance(v, int) and not isinstance(v, bool) and v > 0 else 0
