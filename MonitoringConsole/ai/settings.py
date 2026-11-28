"""The "ai" section of monitoring_settings.json, with its defaults.

The doctor (scripts/lib/Doctor.psm1, Test-AiConfig) validates the same fields; this
module only reads them, falling back to a default for anything missing or malformed,
so a bad value can never turn the assistant into something it was not configured to be.
"""
from __future__ import annotations

import ipaddress
from dataclasses import dataclass
from typing import Any, Dict, Optional
from urllib.parse import urlsplit

DEFAULT_URL = "http://localhost:11434"
DEFAULT_MODEL = "qwen3:4b-instruct-2507-q4_K_M"


def is_loopback_url(url: str) -> bool:
    """True for an http(s) URL whose host is this machine: localhost, 127.x.x.x or ::1."""
    try:
        parts = urlsplit(str(url))
        host = parts.hostname or ""
        parts.port                      # raises ValueError on a malformed port
    except ValueError:
        return False
    if parts.scheme not in ("http", "https") or not host:
        return False
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _bool(v: Any, default: bool) -> bool:
    return v if isinstance(v, bool) else default


def _int(v: Any, default: int, lo: int, hi: int) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
        return default
    return v


def _num(v: Any, default: float) -> float:
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v <= 0:
        return default
    return float(v)


def _str(v: Any, default: Optional[str]) -> Optional[str]:
    return v.strip() if isinstance(v, str) and v.strip() else default


@dataclass(frozen=True)
class AiSettings:
    enabled: bool = False
    ollama_url: str = DEFAULT_URL
    allow_remote: bool = False
    model: str = DEFAULT_MODEL
    fallback_model: Optional[str] = "qwen2.5:3b"
    timeout_sec: float = 90.0
    max_model_calls: int = 5
    token_budget: int = 12000
    max_traces: int = 200

    @classmethod
    def from_config(cls, config: Optional[Dict[str, Any]]) -> "AiSettings":
        """From the whole settings dict (or None). A missing "ai" section means off."""
        ai = (config or {}).get("ai")
        if not isinstance(ai, dict):
            return cls()
        d = cls()
        return cls(
            enabled=_bool(ai.get("enabled"), d.enabled),
            ollama_url=(_str(ai.get("ollama_url"), d.ollama_url) or d.ollama_url).rstrip("/"),
            allow_remote=_bool(ai.get("allow_remote"), d.allow_remote),
            model=_str(ai.get("model"), d.model) or d.model,
            fallback_model=_str(ai.get("fallback_model"), None) if "fallback_model" in ai else d.fallback_model,
            timeout_sec=_num(ai.get("timeout_sec"), d.timeout_sec),
            max_model_calls=_int(ai.get("max_model_calls"), d.max_model_calls, 1, 20),
            token_budget=_int(ai.get("token_budget"), d.token_budget, 500, 1_000_000),
            max_traces=_int(ai.get("max_traces"), d.max_traces, 1, 100_000),
        )

    @property
    def url_allowed(self) -> bool:
        """Invariant 5: the model runs on localhost unless ai.allow_remote is true."""
        if self.allow_remote:
            return urlsplit(self.ollama_url).scheme in ("http", "https")
        return is_loopback_url(self.ollama_url)
