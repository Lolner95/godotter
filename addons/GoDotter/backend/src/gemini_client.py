"""Gemini API client using the google-genai SDK.

Key design choices:
- Structured JSON responses via response_schema (not prompt engineering)
- Multimodal support for 3D asset review screenshots
- Graceful behavior when no API key is set (GEMINI_API_KEY, GOOGLE_API_KEY, or .godotter_api_key via main.py)
- One automatic repair pass on JSON validation failures
- Configurable model, temperature, max_tokens
"""
from __future__ import annotations

import base64
import json
import logging
import os
import time
from typing import Any, Optional, Type

from pydantic import BaseModel

logger = logging.getLogger(__name__)

try:
    from google import genai
    from google.genai import types as genai_types
    GENAI_AVAILABLE = True
except ImportError:
    GENAI_AVAILABLE = False
    logger.warning("google-genai not installed. Run: pip install google-genai")


class GeminiClient:
    """Wrapper around google-genai for structured agent outputs."""

    VERSION = "0.2.0"

    def __init__(self, config: dict):
        self.model = config.get("model", "gemini-3.1-pro-preview")
        self.temperature = config.get("temperature", 0.2)
        self.max_output_tokens = int(config.get("max_output_tokens", 131_072))
        self.max_input_tokens = int(config.get("max_input_tokens", 2_000_000))
        self.max_retries = config.get("max_retries", 2)

        api_key = (
            os.environ.get("GEMINI_API_KEY", "").strip()
            or os.environ.get("GOOGLE_API_KEY", "").strip()
        )
        self.key_present = bool(api_key)

        self._client = None
        if GENAI_AVAILABLE and api_key:
            try:
                self._client = genai.Client(api_key=api_key)
                logger.info("Gemini client initialized. Model: %s", self.model)
            except Exception as exc:
                logger.error("Failed to init Gemini client: %s", exc)

    @property
    def ready(self) -> bool:
        return self._client is not None and GENAI_AVAILABLE

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
        """
        Generate a response constrained to the given pydantic schema.

        Returns a dict with:
          {"ok": True, "data": <validated model instance>, "raw": str}
        or on failure:
          {"ok": False, "error": str, "raw": str | None}
        """
        if not self.ready:
            return self._no_key_response()

        invocation = invocation or {}
        provider = str(invocation.get("provider", "gemini")).strip().lower()
        if provider != "gemini":
            return {
                "ok": False,
                "error": f"Provider '{provider}' is not available in this backend runtime. Use Gemini or run Test Model Settings in mocked mode.",
                "raw": None,
            }

        active = invocation.get("active", {}) if isinstance(invocation.get("active"), dict) else {}
        contents = self._build_contents(system_prompt, user_prompt, images)
        model_id = self._resolve_model(request_model)
        out_tokens = int(
            max_output_tokens
            if max_output_tokens is not None
            else active.get("max_output_tokens", self.max_output_tokens)
        )
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

                # Repair pass: ask the model to fix its own invalid JSON
                if attempt < retries:
                    logger.warning("JSON validation failed on attempt %d, requesting repair…", attempt + 1)
                    raw_snip = raw
                    if len(raw_snip) > 14000:
                        raw_snip = (
                            raw_snip[:7000]
                            + "\n\n...[truncated for repair prompt; output was too long]...\n\n"
                            + raw_snip[-7000:]
                        )
                    repair_prompt = (
                        "Your previous response failed JSON schema validation.\n"
                        "Error: " + parsed.get("error", "unknown") + "\n"
                        "Previous output (may be truncated):\n" + raw_snip + "\n\n"
                        "Please output ONLY valid JSON matching the required schema. "
                        "No explanation, no markdown fences, just the JSON object."
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
        """Free-text generation (used only for memory summaries, not for agent actions)."""
        if not self.ready:
            return self._no_key_response()

        invocation = invocation or {}
        provider = str(invocation.get("provider", "gemini")).strip().lower()
        if provider != "gemini":
            return {
                "ok": False,
                "error": f"Provider '{provider}' is not available in this backend runtime.",
                "raw": None,
            }
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

    def _build_contents(
        self,
        system_prompt: str,
        user_prompt: str,
        images: Optional[list[bytes]] = None,
    ) -> list:
        """Build the contents list for the Gemini API."""
        parts: list = []

        if system_prompt:
            parts.append(system_prompt + "\n\n")

        if images:
            for img_bytes in images:
                parts.append(
                    genai_types.Part.from_bytes(data=img_bytes, mime_type="image/png")
                )

        parts.append(user_prompt)
        return parts

    def _parse_and_validate(
        self, raw: str, schema: Type[BaseModel]
    ) -> dict[str, Any]:
        """Parse raw JSON string and validate against pydantic schema."""
        raw = raw.strip()
        # Strip markdown code fences if present
        if raw.startswith("```"):
            lines = raw.split("\n")
            raw = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:])

        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            return {"ok": False, "error": f"JSON parse error: {exc}", "raw": raw}

        try:
            instance = schema.model_validate(data)
            return {"ok": True, "data": instance, "raw": raw}
        except Exception as exc:
            return {"ok": False, "error": f"Schema validation error: {exc}", "raw": raw}

    def _no_key_response(self) -> dict[str, Any]:
        return {
            "ok": False,
            "error": "API key not set",
            "hint": (
                "Set GEMINI_API_KEY or GOOGLE_API_KEY before starting the backend, "
                "or paste your key in GoDotter Settings (stored in Editor Settings and "
                "backend/.godotter_api_key). Get a Gemini key at https://aistudio.google.com/."
            ),
            "raw": None,
        }

    def get_health_info(self) -> dict[str, Any]:
        return {
            "gemini_key_present": self.key_present,
            "api_key_present": self.key_present,
            "model": self.model,
            "sdk_available": GENAI_AVAILABLE,
            "ready": self.ready,
        }
