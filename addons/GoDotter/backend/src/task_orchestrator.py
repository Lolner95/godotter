"""Task orchestrator — manages the plan→approve→execute state machine.

Phase 1-3 scope: plan-only end-to-end (plan is returned, not executed).
Phase 4+: patch application, git checkpoint, iteration loop.
"""
from __future__ import annotations

import json
import logging
import re
import time
from typing import Any, Optional

from .code_tools import read_file, write_file
from .gemini_client import GeminiClient
from .git_tools import create_checkpoint
from .memory_store import build_memory_context, read_memory
from .context_engine import build_compact_context, format_plugin_hints_block
from .project_indexer import load_index
from .safety import check_path
from .token_policy import (
    architect_hint_chars,
    compact_max_files,
    execute_hint_chars,
    execute_max_output_tokens,
    execute_memory_chars,
    execute_per_file_chars,
    godotter_token_policy,
)
from .ai_model_settings import extract_and_resolve_ai_settings
from .context_images import extract_context_images
from .schemas import (
    AgentFinalReport,
    AgentStatus,
    ExecuteRequest,
    ExecuteResponse,
    FileEditList,
    Plan,
    PlanStep,
    PlanRequest,
    PlanResponse,
    RiskLevel,
)

logger = logging.getLogger(__name__)


ARCHITECT_SYSTEM_PROMPT = """\
You are GoDotter, an AI game development assistant embedded inside the Godot 4 editor.

You are the ARCHITECT AGENT. Your job is to:
1. Understand the requested change or fix.
2. Read the project index and memory to understand the codebase.
3. Identify the minimal set of relevant files and scenes.
4. Create a precise implementation plan.
5. Identify risks and validation steps.

Rules:
- Never invent file paths. Only reference files from the project index.
- Prefer small targeted patches over full file rewrites.
- Break implementation into small, high-confidence steps that can be executed and validated independently.
- Favor one gameplay/system concern per step (input, movement, combat, UI wiring, save/load, VFX, audio).
- Keep each step focused on a very small file set (usually 1-3 files, max 5).
- Sequence steps by dependency order: data/contracts -> core logic -> scene wiring -> UI/FX -> polish.
- Preserve existing signals, exported variables, and coding style.
- Always include validation steps in the plan.
- Include at least one validation item per step, including explicit Godot editor/runtime actions.
- For game-engine work, include both quick smoke checks and at least one end-to-end in-engine play check.
- Always set approval_required=true unless the change is trivially safe.
- For visual changes, always include screenshot capture in the validation plan.

Infer genre, art style, and core mechanics from project files, memory, and scene/script names —
do not assume a specific theme (e.g. TCG) unless the codebase clearly reflects it.
Visual/UI tasks should mention how to validate in-editor (run scene, check nodes).

Respond ONLY with a valid JSON object matching the Plan schema. No explanations outside the JSON.
"""


def build_plan(
    request: PlanRequest,
    gemini: GeminiClient,
    project_root: str,
) -> PlanResponse:
    """
    Run the Architect Agent to produce a structured Plan.

    Returns PlanResponse with the plan or an error.
    """
    # Load project context + rank files using query + live editor hints from the plugin
    index = load_index(project_root) or {}
    plugin_ctx = request.context_bundle or {}
    pol = godotter_token_policy(plugin_ctx)
    compact_ctx = build_compact_context(
        index,
        request.user_request,
        max_files=compact_max_files(pol["max_input_tokens"]),
        plugin_hints=plugin_ctx,
    )
    memory_ctx = build_memory_context(project_root)

    user_prompt = _build_architect_prompt(
        user_request=request.user_request,
        project_ctx=compact_ctx,
        plugin_ctx=plugin_ctx,
        memory_ctx=memory_ctx,
        hint_max_chars=architect_hint_chars(pol["max_input_tokens"]),
    )
    ai_invocation = extract_and_resolve_ai_settings(plugin_ctx, request.model or None)
    if ai_invocation.get("errors"):
        return PlanResponse(
            ok=False,
            error="Invalid AI settings: " + "; ".join(ai_invocation["errors"]),
        )
    ctx_images = extract_context_images(plugin_ctx, max_images=4)

    result = gemini.generate_structured(
        system_prompt=ARCHITECT_SYSTEM_PROMPT,
        user_prompt=user_prompt,
        response_schema=Plan,
        images=ctx_images if ctx_images else None,
        request_model=ai_invocation.get("model") or request.model or None,
        max_output_tokens=pol["max_output_tokens"],
        invocation=ai_invocation,
    )

    if not result["ok"]:
        return PlanResponse(
            ok=False,
            plan=None,
            error=result.get("error", "Unknown error"),
            hint=result.get("hint"),
            raw_response=result.get("raw"),
        )

    plan: Plan = result["data"]
    plan = _normalize_plan_minimums(plan, request.user_request)
    plan = _ensure_plan_targets(plan, compact_ctx, index)
    plan = _canonicalize_plan_paths(plan, compact_ctx, index)
    logger.info("Plan generated: %s (%d steps)", plan.summary[:60], len(plan.steps))

    return PlanResponse(ok=True, plan=plan)


def _build_architect_prompt(
    user_request: str,
    project_ctx: dict,
    plugin_ctx: dict,
    memory_ctx: str,
    *,
    hint_max_chars: int = 14000,
) -> str:
    lines = [
        f"USER REQUEST: {user_request}",
        "",
    ]

    if memory_ctx:
        lines.append(memory_ctx)
        lines.append("")

    if project_ctx:
        lines.append("=== PROJECT INDEX (compact) ===")
        lines.append(f"Scenes: {project_ctx.get('scene_count', 'unknown')}")
        lines.append(f"Scripts: {project_ctx.get('script_count', 'unknown')}")
        lines.append(f"Resources: {project_ctx.get('resource_count', 'unknown')}")
        autoloads = project_ctx.get("autoloads", [])
        if autoloads:
            names = [a.get("name") if isinstance(a, dict) else a for a in autoloads]
            lines.append("Autoloads: " + ", ".join(names))

        relevant = project_ctx.get("relevant_files", [])
        if relevant:
            lines.append("\nTop relevant paths (query + editor signals):")
            for f in relevant[:32]:
                lines.append(f"  {f}")

        entries = project_ctx.get("relevant_entries") or []
        if entries:
            lines.append("\nIndex metadata for top paths (signals / exports / scene links):")
            for e in entries[:28]:
                if not isinstance(e, dict):
                    continue
                p = e.get("path", "")
                kind = e.get("kind", "")
                if kind == "script":
                    cn = e.get("class_name") or ""
                    sig = ", ".join(e.get("signals") or [])[:120]
                    ex = ", ".join(e.get("exports") or [])[:120]
                    lines.append(f"  [script] {p}  class_name={cn}  signals=[{sig}]  exports=[{ex}]")
                elif kind == "scene":
                    lines.append(
                        f"  [scene] {p}  root={e.get('root_node', '')} ({e.get('root_class', '')}) "
                        f"nodes≈{e.get('node_count', 0)} scripts={e.get('attached_scripts', [])}"
                    )
                else:
                    lines.append(f"  [{kind}] {p}")

        if project_ctx.get("index_missing"):
            lines.append("\n(No saved project index — hints only. Recommend indexing the project.)")

        all_scenes = project_ctx.get("all_scenes", [])
        if all_scenes:
            lines.append("\nAll scenes:")
            for s in all_scenes[:30]:
                lines.append(f"  {s}")

        all_scripts = project_ctx.get("all_scripts", [])
        if all_scripts:
            lines.append("\nAll scripts:")
            for s in all_scripts[:40]:
                lines.append(f"  {s}")

        lines.append("")

    editor_block = format_plugin_hints_block(plugin_ctx, max_chars=hint_max_chars)
    if editor_block:
        lines.append(editor_block)
        lines.append("")

    lines.append("Now produce the implementation plan as a JSON object matching the Plan schema.")
    lines.append(
        "Be specific about which files to modify. Use only paths from the project index, "
        "relevant list, or live editor context / script previews (do not invent res:// paths)."
    )
    lines.append("Include validation steps for every change.")
    lines.append(
        "Decompose work into many small steps with clear scope and ordering. "
        "Each step should be independently testable inside Godot."
    )

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Phase 4: Code Agent — reads files, asks Gemini for edits, writes with backup
# ---------------------------------------------------------------------------

CODE_AGENT_SYSTEM_PROMPT = """\
You are GoDotter, an AI game development assistant for a Godot 4 project.

You are the CODE AGENT. You have been given:
1. A plan describing what needs to change.
2. The current content of files that need to be modified.
3. Project memory and context.

Your job is to produce the edited version of each file.
Rules:
- Output ONLY the complete new file content for each file. Do not truncate.
- Preserve the existing code style, indentation, and conventions.
- Make only the changes needed for the plan step. Do not refactor unrelated code.
- Preserve all existing signals and @export variables unless specifically told to change them.
- For GDScript: use Godot 4.x syntax (@tool, @onready, typed vars, new signal syntax).
- Never delete comments that explain intent.
- If you cannot safely make a change, explain why in the "reason" field and leave content unchanged.

Respond with a JSON array of file edits:
[{"path": "res://...", "new_content": "...", "reason": "..."}]
"""


def execute_plan(req: ExecuteRequest, gemini: GeminiClient, project_root: str) -> ExecuteResponse:
    """
    Phase 4: Execute a plan by having the Code Agent read each relevant file,
    produce edited versions, and write them with backups.
    """
    if not req.approved:
        return ExecuteResponse(
            ok=False,
            error="Execution requires explicit approval. Set approved=true.",
        )

    plan = req.plan
    if not plan:
        return ExecuteResponse(ok=False, error="No plan provided.")

    task_id = req.task_id or f"task_{int(time.time())}"
    files_to_edit = plan.relevant_files[:20]  # safety cap

    if not files_to_edit:
        return ExecuteResponse(
            ok=False,
            error="Plan has no relevant_files to edit.",
        )

    # Git checkpoint before any edits
    cp = create_checkpoint(project_root, f"Before GoDotter task: {plan.summary[:60]}")
    git_checkpoint = cp.get("commit_hash", "") or cp.get("message", "")

    # Read all relevant files
    file_contents: dict[str, str] = {}
    for path in files_to_edit:
        r = read_file(path, project_root)
        if r["ok"]:
            file_contents[path] = r["content"]
        else:
            err_msg = str(r.get("error", ""))
            if err_msg.startswith("File not found:"):
                # Allow new-file workflows (e.g., creating new system modules).
                file_contents[path] = ""
                logger.info("File does not exist yet (will allow create): %s", path)
            else:
                logger.warning("Could not read %s: %s", path, err_msg)

    if not file_contents:
        return ExecuteResponse(
            ok=False,
            error="Could not read any of the relevant files.",
            git_checkpoint=git_checkpoint,
        )

    memory_ctx = build_memory_context(project_root)
    pol = godotter_token_policy(req.context_bundle)
    user_prompt = _build_code_agent_prompt(
        plan,
        file_contents,
        memory_ctx,
        req.user_request,
        req.context_bundle or {},
        hint_max_chars=execute_hint_chars(pol["max_input_tokens"]),
        memory_max_chars=execute_memory_chars(pol["max_input_tokens"]),
        per_file_cap=execute_per_file_chars(pol["max_input_tokens"], len(file_contents)),
    )
    ai_invocation = extract_and_resolve_ai_settings(req.context_bundle, req.model or None)
    if ai_invocation.get("errors"):
        return ExecuteResponse(
            ok=False,
            error="Invalid AI settings: " + "; ".join(ai_invocation["errors"]),
            git_checkpoint=git_checkpoint,
        )
    ctx_images = extract_context_images(req.context_bundle, max_images=4)

    # Ask Gemini for file edits with schema validation. Use a high output token budget
    # because JSON payloads include full file bodies; the default 8k often truncates mid-string.
    result = gemini.generate_structured(
        system_prompt=CODE_AGENT_SYSTEM_PROMPT,
        user_prompt=user_prompt,
        response_schema=FileEditList,
        images=ctx_images if ctx_images else None,
        request_model=ai_invocation.get("model") or req.model or None,
        max_output_tokens=execute_max_output_tokens(req.context_bundle),
        invocation=ai_invocation,
    )

    edits: list[dict] = []
    raw_text = str(result.get("raw", "") or "")

    if result["ok"]:
        edits_model: FileEditList = result["data"]
        edits = [e.model_dump() for e in edits_model.root]
    else:
        logger.warning(
            "Structured code-agent output failed (will try salvage): %s",
            result.get("error", "unknown"),
        )

    if not edits:
        edits = _salvage_file_edits_from_raw(raw_text)
        if edits:
            logger.warning("Salvaged %d file edit(s) from partial/invalid model JSON.", len(edits))

    if not edits:
        err = (
            result.get("error", "Code agent failed")
            if not result["ok"]
            else "Code agent returned no file edits."
        )
        return ExecuteResponse(
            ok=False,
            error=err,
            git_checkpoint=git_checkpoint,
            diffs=[{"raw_response": raw_text[:12000]}],
        )

    edits, path_notes = _filter_edits_by_path_policy(edits, project_root)
    if not edits:
        detail = "; ".join(path_notes[:10]) if path_notes else "(none)"
        return ExecuteResponse(
            ok=False,
            error="No file edits passed path safety checks after salvage. " + detail,
            git_checkpoint=git_checkpoint,
        )

    # Apply edits
    files_written: list[str] = []
    diffs: list[dict] = []
    errors: list[str] = []
    for n in path_notes:
        errors.append(f"[path policy] {n}")

    for edit in edits:
        path = edit.get("path", "")
        new_content = edit.get("new_content", "")
        reason = edit.get("reason", "")

        if not path or not new_content:
            errors.append(f"Skipped edit with missing path or content: {edit.keys()}")
            continue

        write_result = write_file(path, new_content, project_root, task_id=task_id, reason=reason)
        if write_result["ok"]:
            files_written.append(path)
            diffs.append({
                "path": path,
                "diff_text": write_result.get("diff_text", ""),
                "lines_added": write_result.get("lines_added", 0),
                "lines_removed": write_result.get("lines_removed", 0),
                "backup_path": write_result.get("backup_path", ""),
            })
        else:
            errors.append(f"Write failed for {path}: {write_result.get('error', '')}")

    report = AgentFinalReport(
        status=AgentStatus.complete if files_written else AgentStatus.failed,
        summary=f"Edited {len(files_written)}/{len(edits)} files for: {plan.summary[:80]}",
        files_changed=files_written,
        remaining_issues=errors,
        recommended_next_tasks=plan.validation_plan,
    )

    return ExecuteResponse(
        ok=bool(files_written),
        task_id=task_id,
        files_written=files_written,
        diffs=diffs,
        git_checkpoint=git_checkpoint,
        errors=errors,
        final_report=report,
    )


def _build_code_agent_prompt(
    plan: Plan,
    file_contents: dict[str, str],
    memory_ctx: str,
    user_request: str,
    plugin_ctx: dict[str, Any],
    *,
    hint_max_chars: int = 8000,
    memory_max_chars: int = 4500,
    per_file_cap: int = 12000,
) -> str:
    lines = [f"TASK: {user_request or plan.summary}", ""]

    live = format_plugin_hints_block(plugin_ctx, max_chars=hint_max_chars)
    if live:
        lines.append(live)
        lines.append("")

    if memory_ctx:
        lines.append(memory_ctx[:memory_max_chars])
        lines.append("")

    lines.append("PLAN STEPS:")
    for step in plan.steps:
        lines.append(f"  {step.step_number}. {step.description}")
    lines.append("")

    lines.append("FILES TO EDIT (current content):")
    for path, content in file_contents.items():
        lines.append(f"\n=== {path} ===")
        lines.append(content[:per_file_cap])
        lines.append("=== END ===")

    lines.append("\nNow produce a JSON array of file edits.")
    lines.append("Each element: {\"path\": \"res://...\", \"new_content\": \"...complete file...\", \"reason\": \"...\"}")
    lines.append("Output ONLY the JSON array. No explanation text outside the JSON.")

    return "\n".join(lines)


def _parse_file_edits_fallback(raw: str) -> list[dict]:
    """Best-effort salvage for malformed JSON-like model output."""
    txt = raw.strip()
    if not txt:
        return []
    if txt.startswith("```"):
        lines = txt.split("\n")
        txt = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:]).strip()
    lb = txt.find("[")
    rb = txt.rfind("]")
    if lb >= 0 and rb > lb:
        txt = txt[lb : rb + 1]
    try:
        obj = json.loads(txt)
    except Exception:
        return []
    if isinstance(obj, dict):
        obj = [obj]
    if not isinstance(obj, list):
        return []
    out: list[dict] = []
    for e in obj:
        if not isinstance(e, dict):
            continue
        path = str(e.get("path", "")).strip()
        new_content = str(e.get("new_content", ""))
        reason = str(e.get("reason", "")).strip()
        if path != "" and new_content != "":
            out.append({"path": path, "new_content": new_content, "reason": reason})
    return out


def _extract_balanced_json_object(s: str, start_idx: int) -> str:
    """Return a balanced {...} slice starting at start_idx, respecting JSON-ish strings."""
    if start_idx < 0 or start_idx >= len(s) or s[start_idx] != "{":
        return ""
    depth = 0
    i = start_idx
    in_str = False
    esc = False
    str_delim = ""
    while i < len(s):
        ch = s[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == str_delim:
                in_str = False
        else:
            if ch in "\"'":
                in_str = True
                str_delim = ch
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return s[start_idx : i + 1]
        i += 1
    return ""


def _extract_partial_file_edits(raw: str) -> list[dict[str, Any]]:
    """Recover complete edit objects from truncated or invalid JSON arrays."""
    if not raw or '{"path"' not in raw:
        return []
    out: list[dict[str, Any]] = []
    needle = '{"path"'
    start = 0
    seen_paths: set[str] = set()
    while True:
        j = raw.find(needle, start)
        if j < 0:
            break
        chunk = _extract_balanced_json_object(raw, j)
        if not chunk:
            start = j + len(needle)
            continue
        try:
            obj = json.loads(chunk)
        except json.JSONDecodeError:
            start = j + len(needle)
            continue
        if isinstance(obj, dict):
            p = str(obj.get("path", "")).strip()
            nc = str(obj.get("new_content", ""))
            rs = str(obj.get("reason", "")).strip()
            if p.startswith("res://") and nc != "" and p not in seen_paths:
                seen_paths.add(p)
                out.append({"path": p, "new_content": nc, "reason": rs})
        start = j + max(len(chunk), len(needle))
    return out


def _salvage_file_edits_from_raw(raw: str) -> list[dict[str, Any]]:
    fb = _parse_file_edits_fallback(raw)
    if fb:
        return fb
    return _extract_partial_file_edits(raw)


def _filter_edits_by_path_policy(
    edits: list[dict[str, Any]], project_root: str
) -> tuple[list[dict[str, Any]], list[str]]:
    ok_list: list[dict[str, Any]] = []
    notes: list[str] = []
    for edit in edits:
        path = str(edit.get("path", "")).strip()
        nc = str(edit.get("new_content", ""))
        if not path or not nc:
            notes.append("skipped edit with missing path or content")
            continue
        r = check_path(path, project_root, allow_write=True)
        if r.get("allowed"):
            ok_list.append(edit)
        else:
            notes.append(f"{path}: {r.get('reason', 'blocked')}")
    return ok_list, notes


def _normalize_plan_minimums(plan: Plan, user_request: str) -> Plan:
    if not plan.summary.strip():
        plan.summary = user_request.strip() if user_request.strip() else "Implementation plan"
    # Ensure there is always at least one actionable step.
    if len(plan.steps) == 0:
        plan.steps = [
            PlanStep(
                step_number=1,
                description="Inspect relevant files and implement requested behavior safely.",
                tool_calls=[],
                files_affected=list(plan.relevant_files[:3]),
                risk_level="medium",
            )
        ]
    else:
        for i, step in enumerate(plan.steps):
            step.step_number = i + 1
            if not step.description.strip():
                step.description = "Implement and verify the requested change."
            # Keep files_affected actionable for Execute even when the model omits it.
            cleaned_paths: list[str] = []
            for p in list(step.files_affected):
                pp = str(p).strip()
                if pp and pp not in cleaned_paths:
                    cleaned_paths.append(pp)
            if not cleaned_paths:
                cleaned_paths = [str(p).strip() for p in plan.relevant_files if str(p).strip()][:3]
            step.files_affected = cleaned_paths
    # Keep plan-level relevant files populated for downstream validators/run mode.
    if len(plan.relevant_files) == 0:
        inferred: list[str] = []
        for step in plan.steps:
            for p in step.files_affected:
                pp = str(p).strip()
                if pp and pp not in inferred:
                    inferred.append(pp)
        plan.relevant_files = inferred[:12]
    # Sanitize model outputs: keep only canonical project-style paths.
    plan.relevant_files = [
        str(p).strip() for p in plan.relevant_files
        if str(p).strip().startswith("res://")
    ]
    plan.relevant_scenes = [
        str(p).strip() for p in plan.relevant_scenes
        if str(p).strip().startswith("res://")
    ]
    if len(plan.validation_plan) == 0:
        plan.validation_plan = [
            "Run static checks and verify no parse errors.",
            "Test the affected gameplay flow manually in the editor.",
        ]
    plan = _expand_plan_for_small_executable_steps(plan)
    return plan


def _expand_plan_for_small_executable_steps(plan: Plan) -> Plan:
    """Ensure plans are granular enough for reliable game-engine iteration."""
    if not plan.steps:
        return plan

    expanded: list[PlanStep] = []
    for step in plan.steps:
        desc = step.description.strip()
        if not desc:
            expanded.append(step)
            continue

        # Split broad directives, but avoid breaking file extensions like ".gd"/".tscn".
        parts = _smart_split_step_description(desc)
        if len(parts) == 1:
            lower = parts[0].lower()
            if " and " in lower and len(lower) > 80:
                pieces = [p.strip() for p in parts[0].split(" and ") if p.strip()]
                if len(pieces) >= 2:
                    parts = pieces

        if len(parts) <= 1:
            expanded.append(step)
            continue

        for part in parts:
            expanded.append(
                PlanStep(
                    step_number=0,  # normalized later
                    description=part[0].upper() + part[1:] if len(part) > 1 else part.upper(),
                    tool_calls=list(step.tool_calls),
                    files_affected=list(step.files_affected),
                    risk_level=step.risk_level,
                )
            )

    if expanded:
        plan.steps = expanded

    # Keep high signal and practical upper bound for execution UX.
    if len(plan.steps) < 4:
        files = plan.relevant_files[:6]
        while len(plan.steps) < 4:
            idx = len(plan.steps) + 1
            focus = files[(idx - 1) % len(files)] if files else "primary relevant files"
            plan.steps.append(
                PlanStep(
                    step_number=0,
                    description=f"Implement and validate focused change slice {idx} on {focus}.",
                    tool_calls=[],
                    files_affected=[focus] if isinstance(focus, str) and focus.startswith("res://") else [],
                    risk_level=RiskLevel.medium,
                )
            )
    if len(plan.steps) > 18:
        plan.steps = plan.steps[:18]
    return plan


def _smart_split_step_description(desc: str) -> list[str]:
    txt = desc.strip()
    if not txt:
        return []
    # First split on semicolons/newlines (safe delimiters for multi-actions).
    chunks = [c.strip(" .") for c in re.split(r"[;\n]+", txt) if c.strip()]
    out: list[str] = []
    for c in chunks:
        # Then split sentence boundaries only when dot+space+Capital starts a new sentence.
        # This keeps ".gd", ".tscn", paths, and tokens intact.
        parts = [
            p.strip(" .")
            for p in re.split(r"(?<=[a-z0-9\)])\.\s+(?=[A-Z])", c)
            if p.strip()
        ]
        out.extend(parts if parts else [c])
    return out if out else [txt]


def _ensure_plan_targets(plan: Plan, project_ctx: dict[str, Any], index: dict[str, Any]) -> Plan:
    """Populate plan-level file/scene targets when the model omits them."""
    if plan.relevant_files or plan.relevant_scenes:
        return plan

    inferred_files: list[str] = []
    inferred_scenes: list[str] = []

    # Prefer ranked context selected for this request.
    for p in project_ctx.get("relevant_files", []) or []:
        pp = str(p).strip()
        if not pp or not pp.startswith("res://"):
            continue
        if pp.lower().endswith(".tscn"):
            if pp not in inferred_scenes:
                inferred_scenes.append(pp)
        else:
            if pp not in inferred_files:
                inferred_files.append(pp)

    # Fallback to indexed project files/scenes.
    if not inferred_files:
        for entry in index.get("scripts", []) or []:
            p = str((entry or {}).get("path", "")).strip()
            if p.startswith("res://") and p not in inferred_files:
                inferred_files.append(p)
            if len(inferred_files) >= 12:
                break
    if not inferred_scenes:
        for entry in index.get("scenes", []) or []:
            p = str((entry or {}).get("path", "")).strip()
            if p.startswith("res://") and p not in inferred_scenes:
                inferred_scenes.append(p)
            if len(inferred_scenes) >= 6:
                break

    plan.relevant_files = inferred_files[:12]
    plan.relevant_scenes = inferred_scenes[:6]
    return plan


def _canonicalize_plan_paths(plan: Plan, project_ctx: dict[str, Any], index: dict[str, Any]) -> Plan:
    """Convert shorthand model paths (e.g. 'Player.gd') into canonical res:// paths."""
    known_files, known_scenes = _collect_known_project_paths(project_ctx, index)

    normalized_files: list[str] = []
    for p in plan.relevant_files:
        rp = _resolve_to_res_path(str(p), known_files)
        if rp and rp not in normalized_files:
            normalized_files.append(rp)
    plan.relevant_files = normalized_files

    normalized_scenes: list[str] = []
    for p in plan.relevant_scenes:
        rp = _resolve_to_res_path(str(p), known_scenes)
        if rp and rp not in normalized_scenes:
            normalized_scenes.append(rp)
    plan.relevant_scenes = normalized_scenes

    fallback_targets: list[str] = plan.relevant_files[:]
    if not fallback_targets:
        fallback_targets = [p for p in known_files[:6] if p.startswith("res://")]

    for step in plan.steps:
        fixed: list[str] = []
        for p in step.files_affected:
            rp = _resolve_to_res_path(str(p), known_files + known_scenes)
            if rp and rp not in fixed:
                fixed.append(rp)
        if not fixed:
            fixed = fallback_targets[:3]
        step.files_affected = fixed

    return plan


def _collect_known_project_paths(project_ctx: dict[str, Any], index: dict[str, Any]) -> tuple[list[str], list[str]]:
    files: list[str] = []
    scenes: list[str] = []

    for p in project_ctx.get("relevant_files", []) or []:
        pp = str(p).strip()
        if not pp.startswith("res://"):
            continue
        if pp.lower().endswith(".tscn"):
            if pp not in scenes:
                scenes.append(pp)
        else:
            if pp not in files:
                files.append(pp)

    for bucket in ("scripts", "resources", "shaders"):
        for entry in index.get(bucket, []) or []:
            p = str((entry or {}).get("path", "")).strip()
            if p.startswith("res://") and p not in files:
                files.append(p)

    for entry in index.get("scenes", []) or []:
        p = str((entry or {}).get("path", "")).strip()
        if p.startswith("res://") and p not in scenes:
            scenes.append(p)

    return files, scenes


def _resolve_to_res_path(raw: str, candidates: list[str]) -> str:
    p = raw.strip().replace("\\", "/")
    if p.startswith("res://"):
        return p
    if not p:
        return ""
    base = p.split("/")[-1].lower()
    if not base:
        return ""
    matches = [c for c in candidates if c.lower().endswith("/" + base) or c.lower() == ("res://" + base)]
    if len(matches) == 1:
        return matches[0]
    return ""
