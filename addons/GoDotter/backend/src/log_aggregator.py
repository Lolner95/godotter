"""Godot run log aggregator.

Parses raw Godot stdout/stderr log text, groups errors by root cause,
and feeds the Debug Agent to produce a single batched fix plan.
"""
from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Any

from .gemini_client import GeminiClient
from .memory_store import build_memory_context
from .project_indexer import load_index
from .schemas import (
    ErrorGroup,
    FixLogsRequest,
    FixLogsResponse,
    LogBatchFixPlan,
    RiskLevel,
)

logger = logging.getLogger(__name__)

# Patterns for Godot 4 error output
_PATTERNS = [
    # SCRIPT ERROR: <msg>\n   at: <file>:<line>
    re.compile(r"(?P<level>SCRIPT ERROR|ERROR|WARNING|FATAL):\s*(?P<message>[^\n]+)", re.IGNORECASE),
    # E 0:00:00.000 <message>
    re.compile(r"^E\s+\d+:\d+:\d+\.\d+\s+(?P<message>.+)$", re.MULTILINE),
    # Failed to load resource
    re.compile(r"(?P<level>Failed to load)\s+(?P<message>resource.+?)(?:\n|$)", re.IGNORECASE),
    # at: file.gd:123
    re.compile(r"^\s+at:\s+(?P<file>[^\s:]+):(?P<line>\d+)(?:\s+.*)?$", re.MULTILINE),
    # Invalid get index / call
    re.compile(r"(?P<level>Invalid (?:get index|call|set index))\s*(?P<message>[^\n]+)"),
]


def parse_log(log_text: str) -> list[dict]:
    """Extract structured error records from a Godot log string."""
    records: list[dict] = []
    lines = log_text.splitlines()
    current: dict | None = None

    for line in lines:
        # Detect error/warning lines
        m_level = re.match(
            r"^(?P<level>SCRIPT ERROR|ERROR|WARNING|FATAL|E\b)[:\s]+(?P<message>.+)$",
            line.strip(),
            re.IGNORECASE,
        )
        if m_level:
            if current:
                records.append(current)
            current = {
                "level": m_level.group("level").upper().replace("E", "ERROR"),
                "message": m_level.group("message").strip(),
                "file": "",
                "line": 0,
                "stack": [],
            }
            continue

        # Detect stack frame: "   at: res://scripts/CardView.gd:42"
        m_at = re.match(r"^\s+at:\s+(?P<file>[^\s:]+):(?P<lineno>\d+)", line)
        if m_at and current is not None:
            if not current["file"]:
                current["file"] = m_at.group("file")
                current["line"] = int(m_at.group("lineno"))
            current["stack"].append(f"{m_at.group('file')}:{m_at.group('lineno')}")
            continue

        # Failed to load resource
        m_load = re.match(r"(?:Failed to load|Cannot open|ERROR loading)\s+(?P<path>.+)", line.strip(), re.IGNORECASE)
        if m_load:
            if current:
                records.append(current)
            current = {
                "level": "ERROR",
                "message": line.strip(),
                "file": m_load.group("path").strip().strip('"'),
                "line": 0,
                "stack": [],
            }
            continue

    if current:
        records.append(current)

    return records


def group_errors(records: list[dict]) -> list[ErrorGroup]:
    """Group error records by root cause signature (file + error class)."""
    groups: dict[str, dict] = {}

    for rec in records:
        # Build a signature: error class + file (if known)
        level = rec.get("level", "ERROR")
        msg = rec.get("message", "")
        file_ = rec.get("file", "")

        # Normalize signature
        error_class = _extract_error_class(msg)
        sig = f"{level}:{error_class}"
        if file_:
            sig += f"@{Path(file_).name}"

        if sig not in groups:
            groups[sig] = {
                "signature": sig,
                "count": 0,
                "sample_message": msg,
                "files_implicated": [],
                "stack_top": [],
                "probable_cause": "",
            }

        groups[sig]["count"] += 1
        if file_ and file_ not in groups[sig]["files_implicated"]:
            groups[sig]["files_implicated"].append(file_)

        stack = rec.get("stack", [])
        if stack and not groups[sig]["stack_top"]:
            groups[sig]["stack_top"] = stack[:3]

    return [ErrorGroup(**g) for g in groups.values()]


def _extract_error_class(message: str) -> str:
    """Extract a short error class string from the message."""
    for keyword in [
        "Invalid get index",
        "Invalid set index",
        "Invalid call",
        "Null instance",
        "Cannot call",
        "Failed to load",
        "Attempt to call",
        "Index p_index",
        "Cannot open",
        "Node not found",
        "Script inherits",
        "Parse error",
        "Expected",
    ]:
        if keyword.lower() in message.lower():
            return keyword.replace(" ", "_")
    return "GeneralError"


DEBUG_SYSTEM_PROMPT = """\
You are GoDotter, an AI game development assistant for a Godot 4 food-themed TCG.

You are the DEBUG AGENT. You have received a batch of grouped errors from a Godot run.
Your job is to:
1. Analyze each error group.
2. Identify probable root causes.
3. Group related errors that share a single root cause.
4. Produce a single ordered fix plan — one plan for all errors, not one per error.
5. Keep fix steps minimal and targeted.
6. Only reference files that appear in the error groups or project index.

Rules:
- Deduplicate: if 5 errors all come from one broken signal connection, that is ONE fix.
- Order fixes from most fundamental to most derived (fix root cause first).
- Never suggest generic "check all files" steps. Be specific.
- Each fix step must list the exact file(s) and what to change.

Respond ONLY with a valid JSON object matching the LogBatchFixPlan schema.
"""


def handle_fix_from_logs(
    req: FixLogsRequest,
    gemini: GeminiClient,
    project_root: str,
) -> FixLogsResponse:
    """Parse logs, group errors, and ask the Debug Agent for a batched fix plan."""
    if not req.log_text.strip():
        return FixLogsResponse(
            ok=False,
            error="No log text provided. Run a scene first and capture its output.",
        )

    # Parse and group
    records = parse_log(req.log_text)
    if not records:
        return FixLogsResponse(
            ok=True,
            plan=LogBatchFixPlan(
                summary="No errors or warnings detected in the log.",
                error_groups=[],
                fix_steps=[],
                approval_required=False,
            ),
            error_groups_found=0,
        )

    groups = group_errors(records)
    logger.info("Found %d error groups from %d records", len(groups), len(records))

    # Load context
    idx = load_index(project_root) if project_root else {}
    memory_ctx = build_memory_context(project_root) if project_root else ""

    # Build prompt
    user_prompt = _build_debug_prompt(groups, idx, memory_ctx, req.run_id)

    result = gemini.generate_structured(
        system_prompt=DEBUG_SYSTEM_PROMPT,
        user_prompt=user_prompt,
        response_schema=LogBatchFixPlan,
        request_model=req.model or None,
    )

    if not result["ok"]:
        return FixLogsResponse(
            ok=False,
            error=result.get("error", "AI error"),
            error_groups_found=len(groups),
            raw_response=result.get("raw"),
        )

    plan: LogBatchFixPlan = result["data"]
    return FixLogsResponse(
        ok=True,
        plan=plan,
        error_groups_found=len(groups),
    )


def _build_debug_prompt(
    groups: list[ErrorGroup],
    index: dict,
    memory_ctx: str,
    run_id: str,
) -> str:
    lines = [f"Run ID: {run_id or '(unknown)'}", ""]

    if memory_ctx:
        lines.append(memory_ctx[:3000])
        lines.append("")

    lines.append("=== ERROR GROUPS ===")
    for i, g in enumerate(groups, 1):
        lines.append(f"\n[Group {i}] {g.signature} (×{g.count})")
        lines.append(f"  Sample: {g.sample_message[:200]}")
        if g.files_implicated:
            lines.append("  Files: " + ", ".join(g.files_implicated[:5]))
        if g.stack_top:
            lines.append("  Stack top: " + " → ".join(g.stack_top[:3]))

    all_scripts = [s.get("path", "") for s in index.get("scripts", [])]
    if all_scripts:
        lines.append("\n=== PROJECT SCRIPTS ===")
        for s in all_scripts[:30]:
            lines.append(f"  {s}")

    lines.append("\nNow produce the batched fix plan as JSON matching LogBatchFixPlan schema.")
    return "\n".join(lines)
