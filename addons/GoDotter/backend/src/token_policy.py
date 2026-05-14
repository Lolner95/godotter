"""Effective LLM token budgets from plugin context (godotter.*) + env overrides.

Defaults are sized for long agent runs (large JSON edits, big context) similar in spirit
to desktop tools like Cursor: generous output cap and a large input/context budget.
"""
from __future__ import annotations

import os
from typing import Any

# Cursor-class tools commonly allow very large completion/context windows.
# Gemini API caps vary by model; we clamp to plugin-safe upper bounds.
_DEFAULT_MAX_OUTPUT = 131_072
_DEFAULT_MAX_INPUT = 2_000_000


def _clamp_int(val: Any, lo: int, hi: int, default: int) -> int:
    try:
        if val is None or val == "":
            return default
        n = int(float(val))
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, n))


def godotter_token_policy(context_bundle: dict[str, Any] | None) -> dict[str, int]:
    """Read max_output_tokens / max_input_tokens from context_bundle['godotter']."""
    g = (context_bundle or {}).get("godotter") or {}
    if not isinstance(g, dict):
        g = {}
    return {
        "max_output_tokens": _clamp_int(
            g.get("max_output_tokens"), 1024, 131_072, _DEFAULT_MAX_OUTPUT
        ),
        "max_input_tokens": _clamp_int(
            g.get("max_input_tokens"), 4096, 2_000_000, _DEFAULT_MAX_INPUT
        ),
    }


def compact_max_files(max_input_tokens: int) -> int:
    """How many ranked index paths to include in compact context."""
    return max(20, min(96, max_input_tokens // 11_000))


def architect_hint_chars(max_input_tokens: int) -> int:
    """Character budget for live editor hints in the Architect prompt."""
    return min(500_000, max(14_000, (max_input_tokens * 3) // 10))


def execute_hint_chars(max_input_tokens: int) -> int:
    """Character budget for editor hints in the Code Agent prompt."""
    return min(400_000, max(8_000, max_input_tokens // 5))


def execute_memory_chars(max_input_tokens: int) -> int:
    """Memory block size in the Code Agent prompt."""
    return min(100_000, max(3_000, max_input_tokens // 30))


def execute_per_file_chars(max_input_tokens: int, num_files: int) -> int:
    """Per-file content cap in execute prompt (split budget across files)."""
    n = max(1, num_files)
    return min(120_000, max(6_000, (max_input_tokens * 2) // (n * 3)))


def execute_max_output_tokens(context_bundle: dict[str, Any] | None) -> int:
    """Output cap for /agent/execute (JSON with full file bodies). Env wins over plugin."""
    env = os.environ.get("GODOTTER_EXECUTE_MAX_OUTPUT_TOKENS", "").strip()
    if env:
        try:
            return max(8192, min(int(env), 131_072))
        except ValueError:
            pass
    pol = godotter_token_policy(context_bundle)
    return max(8192, min(pol["max_output_tokens"], 131_072))
