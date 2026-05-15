"""Provider-aware AI client for Gemini / OpenAI / Claude runtimes."""
from __future__ import annotations

import base64
import json
import logging
import os
import time
from typing import Any, Optional, Type

import httpx
from pydantic import BaseModel

logger = logging.getLogger(__name__)

# Official OpenAI API default (empty env → this). Custom URLs enable local / 3rd-party OpenAI-compatible servers.
_DEFAULT_OPENAI_API_BASE = "https://api.openai.com/v1"


def openai_runtime_fingerprint_from_env() -> tuple[str, str]:
    """Stable (api_key, base_url) tuple for reload detection."""
    base = os.environ.get("OPENAI_BASE_URL", "").strip().rstrip("/") or _DEFAULT_OPENAI_API_BASE
    return (os.environ.get("OPENAI_API_KEY", "").strip(), base)


try:
    from google import genai
    from google.genai import types as genai_types

    GENAI_AVAILABLE = True
except ImportError:
    GENAI_AVAILABLE = False
    logger.warning("google-genai not installed. Run: pip install google-genai")


class GeminiClient:
    """Backward-compatible class name, now dispatching by provider."""

    VERSION = "0.2.0"

    def __init__(self, config: dict):
        self.model = config.get("model", "gemini-3.1-pro-preview")
        self.temperature = config.get("temperature", 0.2)
        self.max_output_tokens = int(config.get("max_output_tokens", 131_072))
        self.max_input_tokens = int(config.get("max_input_tokens", 2_000_000))
        self.max_retries = int(config.get("max_retries", 2))

        self.gemini_key = (
            os.environ.get("GEMINI_API_KEY", "").strip()
            or os.environ.get("GOOGLE_API_KEY", "").strip()
        )
        self.openai_key = os.environ.get("OPENAI_API_KEY", "").strip()
        self.openai_base_url = (
            os.environ.get("OPENAI_BASE_URL", "").strip().rstrip("/")
            or _DEFAULT_OPENAI_API_BASE
        )
        self.claude_key = (
            os.environ.get("ANTHROPIC_API_KEY", "").strip()
            or os.environ.get("CLAUDE_API_KEY", "").strip()
        )
        self.key_present = bool(self.gemini_key)
        self._runtime_openai_sig = (self.openai_key, self.openai_base_url)

        self._client = None
        if GENAI_AVAILABLE and self.gemini_key:
            try:
                self._client = genai.Client(api_key=self.gemini_key)
                logger.info("Gemini client initialized. Model: %s", self.model)
            except Exception as exc:
                logger.error("Failed to init Gemini client: %s", exc)

    @property
    def ready(self) -> bool:
        return self._client is not None and GENAI_AVAILABLE

    def can_call_provider(self, provider: str) -> bool:
        p = (provider or "gemini").strip().lower()
        if p == "gemini":
            return self.ready
        if p == "openai":
            if bool(self.openai_key):
                return True
            # LM Studio / vLLM / Ollama compat often work without a key when base URL is not the official API.
            return not self._is_official_openai_api_base(self.openai_base_url)
        if p == "claude":
            return bool(self.claude_key)
        return False

    @staticmethod
    def _is_official_openai_api_base(base_url: str) -> bool:
        u = (base_url or "").strip().rstrip("/").lower()
        if not u:
            return True
        return u in ("https://api.openai.com/v1", "http://api.openai.com/v1")

    def _effective_openai_base_url(self, invocation: dict[str, Any] | None) -> str:
        inv = invocation or {}
        raw = str(inv.get("openai_base_url", "")).strip().rstrip("/")
        if raw:
            return raw
        return str(self.openai_base_url or _DEFAULT_OPENAI_API_BASE).strip().rstrip("/")

    def _openai_chat_completions_url(self, invocation: dict[str, Any] | None) -> str:
        base = self._effective_openai_base_url(invocation)
        return f"{base}/chat/completions"

    def _provider_from_model(self, model: str | None) -> str:
        m = (model or "").strip().lower()
        if m.startswith("gemini-"):
            return "gemini"
        if m.startswith("claude-"):
            return "claude"
        if m.startswith("gpt-") or "openai" in m:
            return "openai"
        return "gemini"

    def _resolve_model(self, request_model: str | None) -> str:
        m = (request_model or "").strip()
        return m if m else self.model

    def generate_structured(
        self,
        system_prompt: str,
        user_prompt: str,
        response_schema: Type[BaseModel],
        images: Optional[list[bytes]] = None,
        request_model: str | None = None,
        max_output_tokens: int | None = None,
        invocation: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        invocation = invocation or {}
        provider = str(
            invocation.get("provider", self._provider_from_model(request_model or self.model))
        ).strip().lower()
        if provider == "gemini":
            return self._generate_structured_gemini(
                system_prompt=system_prompt,
                user_prompt=user_prompt,
                response_schema=response_schema,
                images=images,
                request_model=request_model,
                max_output_tokens=max_output_tokens,
                invocation=invocation,
            )

        # Non-Gemini providers: force strict JSON output then validate.
        schema_json = "{}"
        try:
            schema_json = json.dumps(response_schema.model_json_schema(), ensure_ascii=False)
        except Exception:
            pass
        strict_user = (
            user_prompt
            + "\n\nReturn ONLY valid JSON matching this schema (no markdown fences):\n"
            + schema_json
        )
        text_res = self.generate_text(
            system_prompt=system_prompt,
            user_prompt=strict_user,
            images=images,
            request_model=request_model,
            invocation=invocation,
        )
        if not text_res.get("ok"):
            return {"ok": False, "error": str(text_res.get("error", "provider call failed")), "raw": text_res.get("raw")}
        raw = str(text_res.get("data", "") or "")
        return self._parse_and_validate(raw, response_schema)

    def _generate_structured_gemini(
        self,
        system_prompt: str,
        user_prompt: str,
        response_schema: Type[BaseModel],
        images: Optional[list[bytes]],
        request_model: str | None,
        max_output_tokens: int | None,
        invocation: dict[str, Any],
    ) -> dict[str, Any]:
        if not self.ready:
            return self._no_key_response("gemini")

        active = invocation.get("active", {}) if isinstance(invocation.get("active"), dict) else {}
        contents = self._build_contents(system_prompt, user_prompt, images)
        model_id = self._resolve_model(request_model)
        out_tokens = int(max_output_tokens if max_output_tokens is not None else active.get("max_output_tokens", self.max_output_tokens))
        temperature = float(active.get("temperature", self.temperature))
        retries = int(active.get("retries", self.max_retries))
        top_p = active.get("top_p", None)
        thinking_level = active.get("thinking_level", None)
        thinking_budget = active.get("thinking_budget", None)
        thinking_summaries = bool(active.get("thinking_summaries", False))

        for attempt in range(retries + 1):
            try:
                cfg_kwargs: dict[str, Any] = {
                    "temperature": temperature,
                    "max_output_tokens": out_tokens,
                    "response_mime_type": "application/json",
                    "response_schema": response_schema,
                }
                if top_p is not None:
                    cfg_kwargs["top_p"] = float(top_p)
                if thinking_level is not None or thinking_budget is not None:
                    th_kwargs: dict[str, Any] = {"include_thoughts": thinking_summaries}
                    if thinking_level is not None:
                        th_kwargs["thinking_level"] = str(thinking_level).upper()
                    if thinking_budget is not None:
                        th_kwargs["thinking_budget"] = int(thinking_budget)
                    cfg_kwargs["thinking_config"] = genai_types.ThinkingConfig(**th_kwargs)
                response = self._client.models.generate_content(
                    model=model_id,
                    contents=contents,
                    config=genai_types.GenerateContentConfig(**cfg_kwargs),
                )
                raw = response.text or ""
                parsed = self._parse_and_validate(raw, response_schema)
                if parsed["ok"]:
                    return parsed
                if attempt < retries:
                    raw_snip = raw[:7000] + ("\n...[truncated]...\n" if len(raw) > 14000 else "") + (raw[-7000:] if len(raw) > 14000 else "")
                    repair_prompt = (
                        "Your previous response failed JSON schema validation.\n"
                        "Error: " + parsed.get("error", "unknown") + "\n"
                        "Previous output:\n" + raw_snip + "\n\n"
                        "Output ONLY valid JSON matching the required schema."
                    )
                    contents = self._build_contents(system_prompt, repair_prompt, images)
                else:
                    return {"ok": False, "error": parsed.get("error", "Validation failed"), "raw": raw}
            except Exception as exc:
                logger.error("Gemini API error (attempt %d): %s", attempt + 1, exc)
                if attempt >= retries:
                    return {"ok": False, "error": str(exc), "raw": None}
                time.sleep(1.5 ** attempt)
        return {"ok": False, "error": "Max retries exceeded", "raw": None}

    def generate_text(
        self,
        system_prompt: str,
        user_prompt: str,
        images: Optional[list[bytes]] = None,
        request_model: str | None = None,
        invocation: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        invocation = invocation or {}
        provider = str(
            invocation.get("provider", self._provider_from_model(request_model or self.model))
        ).strip().lower()
        if provider == "gemini":
            return self._generate_text_gemini(system_prompt, user_prompt, images, request_model, invocation)
        if provider == "openai":
            return self._generate_text_openai(system_prompt, user_prompt, images, request_model, invocation)
        if provider == "claude":
            return self._generate_text_claude(system_prompt, user_prompt, images, request_model, invocation)
        return {"ok": False, "error": f"Unsupported provider '{provider}'", "raw": None}

    def _generate_text_gemini(
        self,
        system_prompt: str,
        user_prompt: str,
        images: Optional[list[bytes]],
        request_model: str | None,
        invocation: dict[str, Any],
    ) -> dict[str, Any]:
        if not self.ready:
            return self._no_key_response("gemini")
        active = invocation.get("active", {}) if isinstance(invocation.get("active"), dict) else {}
        contents = self._build_contents(system_prompt, user_prompt, images)
        model_id = self._resolve_model(request_model)
        out_tokens = int(active.get("max_output_tokens", self.max_output_tokens))
        temperature = float(active.get("temperature", self.temperature))
        retries = int(active.get("retries", self.max_retries))
        for attempt in range(retries + 1):
            try:
                response = self._client.models.generate_content(
                    model=model_id,
                    contents=contents,
                    config=genai_types.GenerateContentConfig(
                        temperature=temperature,
                        max_output_tokens=out_tokens,
                    ),
                )
                return {"ok": True, "data": response.text or "", "raw": response.text}
            except Exception as exc:
                logger.error("Gemini text error (attempt %d): %s", attempt + 1, exc)
                if attempt >= retries:
                    return {"ok": False, "error": str(exc), "raw": None}
                time.sleep(1.5 ** attempt)
        return {"ok": False, "error": "Max retries exceeded", "raw": None}

    def _generate_text_openai(
        self,
        system_prompt: str,
        user_prompt: str,
        images: Optional[list[bytes]],
        request_model: str | None,
        invocation: dict[str, Any],
    ) -> dict[str, Any]:
        base_for_auth = self._effective_openai_base_url(invocation)
        if not self.openai_key and self._is_official_openai_api_base(base_for_auth):
            return self._no_key_response("openai")
        active = invocation.get("active", {}) if isinstance(invocation.get("active"), dict) else {}
        model_id = self._resolve_model(request_model)
        out_tokens = int(active.get("max_output_tokens", self.max_output_tokens))
        temperature = float(active.get("temperature", self.temperature))
        retries = int(active.get("retries", self.max_retries))
        content: list[dict[str, Any]] = [{"type": "text", "text": user_prompt}]
        for img in images or []:
            b64 = base64.b64encode(img).decode("ascii")
            content.append({"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}})
        payload = {
            "model": model_id,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": content},
            ],
            "temperature": temperature,
            "max_tokens": out_tokens,
        }
        if "top_p" in active:
            payload["top_p"] = float(active["top_p"])
        url = self._openai_chat_completions_url(invocation)
        headers: dict[str, str] = {"Content-Type": "application/json"}
        if self.openai_key:
            headers["Authorization"] = f"Bearer {self.openai_key}"
        for attempt in range(retries + 1):
            try:
                with httpx.Client(timeout=float(active.get("timeout_sec", 120))) as client:
                    res = client.post(
                        url,
                        headers=headers,
                        json=payload,
                    )
                if res.status_code >= 400:
                    return {"ok": False, "error": f"OpenAI-compatible API {res.status_code}: {res.text[:500]}", "raw": None}
                data = res.json()
                choices = data.get("choices", [])
                if not choices:
                    return {"ok": False, "error": "OpenAI-compatible server returned no choices", "raw": res.text}
                msg = choices[0].get("message", {}).get("content", "")
                if isinstance(msg, list):
                    msg = "".join(str(part.get("text", "")) for part in msg if isinstance(part, dict))
                return {"ok": True, "data": str(msg), "raw": str(msg)}
            except Exception as exc:
                logger.error("OpenAI text error (attempt %d): %s", attempt + 1, exc)
                if attempt >= retries:
                    return {"ok": False, "error": str(exc), "raw": None}
                time.sleep(1.5 ** attempt)
        return {"ok": False, "error": "Max retries exceeded", "raw": None}

    def _generate_text_claude(
        self,
        system_prompt: str,
        user_prompt: str,
        images: Optional[list[bytes]],
        request_model: str | None,
        invocation: dict[str, Any],
    ) -> dict[str, Any]:
        if not self.claude_key:
            return self._no_key_response("claude")
        active = invocation.get("active", {}) if isinstance(invocation.get("active"), dict) else {}
        model_id = self._resolve_model(request_model)
        out_tokens = int(active.get("max_output_tokens", self.max_output_tokens))
        temperature = float(active.get("temperature", self.temperature))
        retries = int(active.get("retries", self.max_retries))
        content: list[dict[str, Any]] = [{"type": "text", "text": user_prompt}]
        for img in images or []:
            b64 = base64.b64encode(img).decode("ascii")
            content.append({
                "type": "image",
                "source": {"type": "base64", "media_type": "image/png", "data": b64},
            })
        payload: dict[str, Any] = {
            "model": model_id,
            "system": system_prompt,
            "max_tokens": out_tokens,
            "temperature": temperature,
            "messages": [{"role": "user", "content": content}],
        }
        if "top_p" in active:
            payload["top_p"] = float(active["top_p"])
        for attempt in range(retries + 1):
            try:
                with httpx.Client(timeout=float(active.get("timeout_sec", 120))) as client:
                    res = client.post(
                        "https://api.anthropic.com/v1/messages",
                        headers={
                            "x-api-key": self.claude_key,
                            "anthropic-version": "2023-06-01",
                            "content-type": "application/json",
                        },
                        json=payload,
                    )
                if res.status_code >= 400:
                    return {"ok": False, "error": f"Claude API {res.status_code}: {res.text[:500]}", "raw": None}
                data = res.json()
                blocks = data.get("content", [])
                txt = "".join(str(b.get("text", "")) for b in blocks if isinstance(b, dict))
                return {"ok": True, "data": txt, "raw": txt}
            except Exception as exc:
                logger.error("Claude text error (attempt %d): %s", attempt + 1, exc)
                if attempt >= retries:
                    return {"ok": False, "error": str(exc), "raw": None}
                time.sleep(1.5 ** attempt)
        return {"ok": False, "error": "Max retries exceeded", "raw": None}

    def _build_contents(
        self,
        system_prompt: str,
        user_prompt: str,
        images: Optional[list[bytes]] = None,
    ) -> list:
        parts: list = []
        if system_prompt:
            parts.append(system_prompt + "\n\n")
        if images:
            for img_bytes in images:
                parts.append(genai_types.Part.from_bytes(data=img_bytes, mime_type="image/png"))
        parts.append(user_prompt)
        return parts

    def _parse_and_validate(self, raw: str, schema: Type[BaseModel]) -> dict[str, Any]:
        raw = (raw or "").strip()
        if raw.startswith("```"):
            lines = raw.split("\n")
            raw = "\n".join(lines[1:-1] if lines and lines[-1].strip() == "```" else lines[1:])
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            return {"ok": False, "error": f"JSON parse error: {exc}", "raw": raw}
        try:
            instance = schema.model_validate(data)
            return {"ok": True, "data": instance, "raw": raw}
        except Exception as exc:
            return {"ok": False, "error": f"Schema validation error: {exc}", "raw": raw}

    def _no_key_response(self, provider: str = "gemini") -> dict[str, Any]:
        hints = {
            "gemini": "Set GEMINI_API_KEY or GOOGLE_API_KEY (or save Gemini key in GoDotter Settings).",
            "openai": (
                "Set OPENAI_API_KEY (official API), or configure a custom OpenAI-compatible base URL "
                "(LM Studio, Ollama, vLLM, etc.) — many local servers do not require a key."
            ),
            "claude": "Set ANTHROPIC_API_KEY / CLAUDE_API_KEY (or save Claude key in GoDotter Settings).",
        }
        return {
            "ok": False,
            "error": f"{provider} API key not set",
            "hint": hints.get(provider, "Set a provider API key before starting the backend."),
            "raw": None,
        }

    def get_health_info(self) -> dict[str, Any]:
        keys_present = {
            "gemini": bool(self.gemini_key),
            "openai": bool(self.openai_key) or not self._is_official_openai_api_base(self.openai_base_url),
            "claude": bool(self.claude_key),
        }
        return {
            "gemini_key_present": bool(self.gemini_key),
            "api_key_present": any(keys_present.values()),
            "api_keys_present": keys_present,
            "model": self.model,
            "sdk_available": GENAI_AVAILABLE,
            "ready": self.ready,
        }
