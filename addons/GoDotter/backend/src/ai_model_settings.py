"""Central AI model capability registry + preset/runtime resolution.

This module is provider-aware (Gemini / Claude / OpenAI) and is the single
source of truth for:
- supported parameters per model
- allowed ranges
- forbidden combinations
- recommended coding presets (Fast/Balanced/Deep/Extreme)

UI and backend request validation should both consume this registry.
"""
from __future__ import annotations

from copy import deepcopy
from typing import Any

PRESET_NAMES = ("Fast", "Balanced", "Deep", "Extreme")


def _base_caps(provider: str, model: str) -> dict[str, Any]:
    return {
        "provider": provider,
        "model": model,
        "supports": {
            "temperature": True,
            "max_output_tokens": True,
            "top_p": False,
            "streaming": True,
            "timeout_sec": True,
            "retries": True,
            "thinking_level": False,
            "thinking_budget": False,
            "reasoning_effort": False,
            "thinking_summaries": False,
        },
        "ranges": {
            "temperature": [0.0, 2.0],
            "max_output_tokens": [1024, 131072],
            "top_p": [0.0, 1.0],
            "timeout_sec": [10, 300],
            "retries": [0, 6],
            "thinking_budget": [-1, 32768],
        },
        "forbidden_combinations": [],
        "notes": [],
    }


MODEL_CAPABILITY_REGISTRY: dict[str, dict[str, dict[str, Any]]] = {
    "gemini": {
        "gemini-3.1-pro-preview": {
            **_base_caps("gemini", "gemini-3.1-pro-preview"),
            "supports": {
                **_base_caps("gemini", "gemini-3.1-pro-preview")["supports"],
                "top_p": True,
                "thinking_level": True,
                "thinking_summaries": True,
            },
            "forbidden_combinations": [
                {"all_of": ["thinking_level", "thinking_budget"]},
                {"forbid_values": {"thinking_level": ["MINIMAL", "OFF", "DISABLED"]}},
                {"forbid_keys": ["disable_thinking"]},
            ],
            "notes": [
                "Gemini 3.1 Pro uses thinking_level; do not send thinking_budget.",
                "Thinking cannot be disabled on this model in GoDotter policy.",
            ],
        },
        "gemini-2.5-pro": {
            **_base_caps("gemini", "gemini-2.5-pro"),
            "supports": {
                **_base_caps("gemini", "gemini-2.5-pro")["supports"],
                "top_p": True,
                "thinking_budget": True,
                "thinking_summaries": True,
            },
            "forbidden_combinations": [
                {"all_of": ["thinking_level", "thinking_budget"]},
            ],
            "notes": [
                "Gemini 2.5 models use thinking_budget; do not send thinking_level.",
            ],
        },
        "gemini-2.5-flash": {
            **_base_caps("gemini", "gemini-2.5-flash"),
            "supports": {
                **_base_caps("gemini", "gemini-2.5-flash")["supports"],
                "top_p": True,
                "thinking_budget": True,
                "thinking_summaries": True,
            },
            "forbidden_combinations": [{"all_of": ["thinking_level", "thinking_budget"]}],
            "notes": ["Gemini 2.5 Flash uses thinking_budget."],
        },
        "gemini-2.5-flash-lite": {
            **_base_caps("gemini", "gemini-2.5-flash-lite"),
            "supports": {
                **_base_caps("gemini", "gemini-2.5-flash-lite")["supports"],
                "top_p": True,
                "thinking_budget": True,
                "thinking_summaries": True,
            },
            "forbidden_combinations": [{"all_of": ["thinking_level", "thinking_budget"]}],
            "notes": ["Gemini 2.5 Flash-Lite uses thinking_budget."],
        },
    },
    "claude": {
        "claude-3-7-sonnet": {
            **_base_caps("claude", "claude-3-7-sonnet"),
            "supports": {
                **_base_caps("claude", "claude-3-7-sonnet")["supports"],
                "top_p": True,
                "reasoning_effort": True,
                "thinking_summaries": True,
            },
            "ranges": {
                **_base_caps("claude", "claude-3-7-sonnet")["ranges"],
                "max_output_tokens": [1024, 131072],
            },
            "notes": [
                "Claude support is validated and configurable.",
                "Actual provider invocation may require provider key/runtime availability.",
            ],
        }
    },
    "openai": {
        "gpt-5": {
            **_base_caps("openai", "gpt-5"),
            "supports": {
                **_base_caps("openai", "gpt-5")["supports"],
                "top_p": True,
                "reasoning_effort": True,
                "thinking_summaries": True,
            },
            "ranges": {
                **_base_caps("openai", "gpt-5")["ranges"],
                "max_output_tokens": [1024, 131072],
            },
            "notes": [
                "OpenAI reasoning models should use Responses API semantics.",
                "Keep final output verbosity separate from reasoning effort.",
            ],
        }
    },
}


def _default_model_for_provider(provider: str) -> str:
    if provider == "gemini":
        return "gemini-3.1-pro-preview"
    if provider == "claude":
        return "claude-3-7-sonnet"
    return "gpt-5"


def _provider_for_model(model: str) -> str:
    m = (model or "").strip().lower()
    if m.startswith("gemini-"):
        return "gemini"
    if m.startswith("claude-"):
        return "claude"
    if m.startswith("gpt-") or "openai" in m:
        return "openai"
    return "gemini"


def get_model_caps(provider: str, model: str) -> dict[str, Any]:
    p = (provider or "").strip().lower()
    m = (model or "").strip()
    bucket = MODEL_CAPABILITY_REGISTRY.get(p, {})
    if m in bucket:
        return deepcopy(bucket[m])
    # Unknown model under known provider: inherit nearest defaults.
    fallback_model = _default_model_for_provider(p if p in MODEL_CAPABILITY_REGISTRY else "gemini")
    fallback_provider = p if p in MODEL_CAPABILITY_REGISTRY else "gemini"
    caps = deepcopy(MODEL_CAPABILITY_REGISTRY[fallback_provider][fallback_model])
    caps["model"] = m or fallback_model
    caps["notes"] = list(caps.get("notes", [])) + ["Model not in registry; using provider defaults."]
    return caps


def _recommended_preset_values(provider: str, model: str, preset: str) -> dict[str, Any]:
    pr = preset if preset in PRESET_NAMES else "Balanced"
    base = {
        "temperature": 0.2,
        "max_output_tokens": 131072,
        "top_p": 0.9,
        "streaming": False,
        "timeout_sec": 120,
        "retries": 2,
        "thinking_summaries": False,
    }
    if provider == "gemini" and model == "gemini-3.1-pro-preview":
        levels = {"Fast": "LOW", "Balanced": "MEDIUM", "Deep": "HIGH", "Extreme": "HIGH"}
        base["thinking_level"] = levels[pr]
        base["thinking_summaries"] = pr in ("Deep", "Extreme")
        return base
    if provider == "gemini":
        budgets = {"Fast": 0, "Balanced": -1, "Deep": 8192, "Extreme": 24576}
        base["thinking_budget"] = budgets[pr]
        base["thinking_summaries"] = pr in ("Deep", "Extreme")
        return base
    if provider == "claude":
        effort = {"Fast": "low", "Balanced": "medium", "Deep": "high", "Extreme": "max"}
        base["reasoning_effort"] = effort[pr]
        base["thinking_summaries"] = pr in ("Deep", "Extreme")
        return base
    # openai
    effort = {"Fast": "low", "Balanced": "medium", "Deep": "high", "Extreme": "xhigh"}
    base["reasoning_effort"] = effort[pr]
    base["thinking_summaries"] = pr in ("Deep", "Extreme")
    return base


def default_ai_settings(provider: str = "gemini", model: str = "gemini-3.1-pro-preview") -> dict[str, Any]:
    p = provider if provider in MODEL_CAPABILITY_REGISTRY else _provider_for_model(model)
    m = model.strip() if model.strip() else _default_model_for_provider(p)
    presets: dict[str, dict[str, Any]] = {}
    for pr in PRESET_NAMES:
        presets[pr] = _recommended_preset_values(p, m, pr)
    return {
        "provider": p,
        "model": m,
        "preset": "Deep",
        "presets": presets,
    }


def _clamp_num(v: Any, lo: float, hi: float, default: float) -> float:
    try:
        n = float(v)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, n))


def _clamp_int(v: Any, lo: int, hi: int, default: int) -> int:
    try:
        n = int(float(v))
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, n))


def resolve_ai_settings(raw_ai: dict[str, Any] | None) -> dict[str, Any]:
    src = dict(raw_ai or {})
    provider = str(src.get("provider", "")).strip().lower()
    model = str(src.get("model", "")).strip()
    if not provider:
        provider = _provider_for_model(model)
    if provider not in MODEL_CAPABILITY_REGISTRY:
        provider = "gemini"
    if not model:
        model = _default_model_for_provider(provider)

    preset = str(src.get("preset", "Deep")).strip()
    if preset not in PRESET_NAMES:
        preset = "Deep"

    defaults = default_ai_settings(provider, model)
    presets = deepcopy(defaults["presets"])
    user_presets = src.get("presets", {})
    if isinstance(user_presets, dict):
        for pr in PRESET_NAMES:
            uv = user_presets.get(pr)
            if isinstance(uv, dict):
                presets[pr].update(uv)

    active = deepcopy(presets[preset])
    caps = get_model_caps(provider, model)
    ranges = caps.get("ranges", {})
    supports = caps.get("supports", {})

    # Generic clamping
    active["temperature"] = _clamp_num(
        active.get("temperature"),
        float(ranges.get("temperature", [0.0, 2.0])[0]),
        float(ranges.get("temperature", [0.0, 2.0])[1]),
        0.2,
    )
    active["max_output_tokens"] = _clamp_int(
        active.get("max_output_tokens"),
        int(ranges.get("max_output_tokens", [1024, 131072])[0]),
        int(ranges.get("max_output_tokens", [1024, 131072])[1]),
        131072,
    )
    active["timeout_sec"] = _clamp_int(
        active.get("timeout_sec"),
        int(ranges.get("timeout_sec", [10, 300])[0]),
        int(ranges.get("timeout_sec", [10, 300])[1]),
        120,
    )
    active["retries"] = _clamp_int(
        active.get("retries"),
        int(ranges.get("retries", [0, 6])[0]),
        int(ranges.get("retries", [0, 6])[1]),
        2,
    )
    active["streaming"] = bool(active.get("streaming", False))
    active["thinking_summaries"] = bool(active.get("thinking_summaries", False))

    if supports.get("top_p"):
        active["top_p"] = _clamp_num(
            active.get("top_p"),
            float(ranges.get("top_p", [0.0, 1.0])[0]),
            float(ranges.get("top_p", [0.0, 1.0])[1]),
            0.9,
        )
    else:
        active.pop("top_p", None)

    if supports.get("thinking_budget"):
        active["thinking_budget"] = _clamp_int(
            active.get("thinking_budget"),
            int(ranges.get("thinking_budget", [-1, 32768])[0]),
            int(ranges.get("thinking_budget", [-1, 32768])[1]),
            -1,
        )
    else:
        active.pop("thinking_budget", None)

    if supports.get("thinking_level"):
        lvl = str(active.get("thinking_level", "MEDIUM")).strip().upper()
        if provider == "gemini" and model == "gemini-3.1-pro-preview" and lvl in ("MINIMAL", "OFF", "DISABLED"):
            lvl = "LOW"
        if lvl not in ("LOW", "MEDIUM", "HIGH"):
            lvl = "MEDIUM"
        active["thinking_level"] = lvl
    else:
        active.pop("thinking_level", None)

    if supports.get("reasoning_effort"):
        effort = str(active.get("reasoning_effort", "medium")).strip().lower()
        allowed = ("minimal", "low", "medium", "high", "xhigh", "max")
        if effort not in allowed:
            effort = "medium"
        active["reasoning_effort"] = effort
    else:
        active.pop("reasoning_effort", None)

    return {
        "provider": provider,
        "model": model,
        "preset": preset,
        "presets": presets,
        "active": active,
        "capabilities": caps,
    }


def validate_resolved_ai_settings(resolved: dict[str, Any]) -> list[str]:
    errs: list[str] = []
    caps = resolved.get("capabilities", {}) or {}
    supports = caps.get("supports", {}) or {}
    active = resolved.get("active", {}) or {}
    provider = str(resolved.get("provider", ""))
    model = str(resolved.get("model", ""))
    if provider == "gemini" and not model.startswith("gemini-"):
        errs.append(f"{provider}/{model}: invalid model id for Gemini provider.")
    if provider == "claude" and not model.startswith("claude-"):
        errs.append(f"{provider}/{model}: invalid model id for Claude provider.")
    if provider == "openai" and not model.startswith("gpt-"):
        errs.append(f"{provider}/{model}: invalid model id for OpenAI provider.")

    # Unknown keys not supported by model
    for key in ("top_p", "thinking_level", "thinking_budget", "reasoning_effort", "thinking_summaries"):
        if key in active and not supports.get(key, False):
            errs.append(f"{provider}/{model}: parameter '{key}' is not supported by this model.")

    # Forbidden combinations
    for comb in caps.get("forbidden_combinations", []) or []:
        all_of = comb.get("all_of", [])
        if all_of and all(k in active for k in all_of):
            errs.append(f"{provider}/{model}: forbidden combination: {', '.join(all_of)}")
        fv = comb.get("forbid_values", {})
        for k, vals in fv.items():
            if k in active and str(active.get(k)).upper() in [str(v).upper() for v in vals]:
                errs.append(f"{provider}/{model}: value '{active.get(k)}' is invalid for {k}.")
        fk = comb.get("forbid_keys", [])
        for k in fk:
            if k in active:
                errs.append(f"{provider}/{model}: key '{k}' must not be sent for this model.")

    # Explicit policy constraints
    if provider == "gemini" and model == "gemini-3.1-pro-preview":
        if "thinking_level" not in active:
            errs.append("gemini-3.1-pro-preview requires thinking_level.")
        if "thinking_budget" in active:
            errs.append("gemini-3.1-pro-preview must not include thinking_budget.")
    if provider == "gemini" and model.startswith("gemini-2.5"):
        if "thinking_level" in active and "thinking_budget" in active:
            errs.append("Gemini 2.5 must not send thinking_level and thinking_budget together.")

    return errs


def extract_and_resolve_ai_settings(
    context_bundle: dict[str, Any] | None,
    request_model: str | None = None,
) -> dict[str, Any]:
    ctx = context_bundle or {}
    god = ctx.get("godotter", {}) if isinstance(ctx, dict) else {}
    raw_ai = god.get("ai_settings", {}) if isinstance(god, dict) else {}

    resolved = resolve_ai_settings(raw_ai if isinstance(raw_ai, dict) else {})
    m = (request_model or "").strip()
    if m:
        resolved["model"] = m
        # keep provider inferred from model when explicit request model overrides UI model
        resolved["provider"] = _provider_for_model(m)
        resolved = resolve_ai_settings({
            "provider": resolved["provider"],
            "model": resolved["model"],
            "preset": resolved.get("preset", "Deep"),
            "presets": resolved.get("presets", {}),
        })

    resolved["errors"] = validate_resolved_ai_settings(resolved)
    return resolved


def registry_payload() -> dict[str, Any]:
    return {
        "providers": {
            p: {"models": list(models.keys())}
            for p, models in MODEL_CAPABILITY_REGISTRY.items()
        },
        "models": deepcopy(MODEL_CAPABILITY_REGISTRY),
        "preset_names": list(PRESET_NAMES),
        "recommended_defaults": {
            p: {
                m: default_ai_settings(p, m)
                for m in models.keys()
            }
            for p, models in MODEL_CAPABILITY_REGISTRY.items()
        },
    }
