"""Which client answers: Ollama with the configured model, Ollama with the fallback
model, or the rule-based DemoClient. The reason is shown in the console and saved in
the trace, so a demo answer always says why it is not the model's."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, List, Optional

from .base import AIError, ChatClient
from .demo import DemoClient
from .ollama import OllamaClient
from .settings import AiSettings


@dataclass(frozen=True)
class ClientChoice:
    client: ChatClient
    reason: str


def _pulled(tag: str, models: List[str]) -> bool:
    return tag in models or (":" not in tag and f"{tag}:latest" in models)


def choose_client(settings: AiSettings, *, demo_mode: bool = False,
                  probe: Optional[Callable[[OllamaClient], List[str]]] = None) -> ClientChoice:
    """`probe` lists the pulled models (default: GET /api/tags with a short timeout);
    tests pass their own."""
    if demo_mode:
        return ClientChoice(DemoClient(), "Demo container: the assistant runs on rules, no AI.")
    if not settings.enabled:
        return ClientChoice(DemoClient(), "The assistant is off (ai.enabled is false in the settings).")
    if not settings.url_allowed:
        return ClientChoice(DemoClient(), f"{settings.ollama_url} is not this machine and ai.allow_remote is false.")
    try:
        client = OllamaClient.from_settings(settings)
    except ValueError as exc:
        return ClientChoice(DemoClient(), str(exc))
    try:
        models = (probe or (lambda c: c.list_models()))(client)
    except AIError as exc:
        return ClientChoice(DemoClient(), f"{exc.reason}. Start Ollama to use the model.")
    if _pulled(settings.model, models):
        return ClientChoice(client, f"Ollama, {settings.model}.")
    fallback = settings.fallback_model
    if fallback and _pulled(fallback, models):
        return ClientChoice(OllamaClient.from_settings(settings, fallback),
                            f"Ollama, fallback {fallback} ({settings.model} is not pulled).")
    return ClientChoice(DemoClient(), f"{settings.model} is not pulled. Run: ollama pull {settings.model}")
