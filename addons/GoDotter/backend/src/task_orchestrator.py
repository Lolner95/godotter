"""Task orchestrator — manages the plan→approve→execute state machine.

Phase 1-3 scope: plan-only end-to-end (plan is returned, not executed).
Phase 4+: patch application, git checkpoint, iteration loop.
"""
from __future__ import annotations

import logging
import time
from typing import Any, Optional

from .code_tools import read_file, write_file
from .gemini_client import GeminiClient
from .git_tools import create_checkpoint
from .memory_store import build_memory_context, read_memory
from .context_engine import build_compact_context, format_plugin_hints_block
from .project_indexer import load_index
from .schemas import (
    AgentFinalReport,
    AgentStatus,
    ExecuteRequest,
    ExecuteResponse,
    FileEdit,
    Plan,
    PlanRequest,
    PlanResponse,
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
- Preserve existing signals, exported variables, and coding style.
- Always include validation steps in the plan.
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
    compact_ctx = build_compact_context(
        index,
        request.user_request,
        max_files=40,
        plugin_hints=plugin_ctx,
    )
    memory_ctx = build_memory_context(project_root)

    user_prompt = _build_architect_prompt(
        user_request=request.user_request,
        project_ctx=compact_ctx,
        plugin_ctx=plugin_ctx,
        memory_ctx=memory_ctx,
    )

    result = gemini.generate_structured(
        system_prompt=ARCHITECT_SYSTEM_PROMPT,
        user_prompt=user_prompt,
        response_schema=Plan,
        request_model=request.model or None,
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
    logger.info("Plan generated: %s (%d steps)", plan.summary[:60], len(plan.steps))

    return PlanResponse(ok=True, plan=plan)


def _build_architect_prompt(
    user_request: str,
    project_ctx: dict,
    plugin_ctx: dict,
    memory_ctx: str,
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

    editor_block = format_plugin_hints_block(plugin_ctx)
    if editor_block:
        lines.append(editor_block)
        lines.append("")

    lines.append("Now produce the implementation plan as a JSON object matching the Plan schema.")
    lines.append(
        "Be specific about which files to modify. Use only paths from the project index, "
        "relevant list, or live editor context / script previews (do not invent res:// paths)."
    )
    lines.append("Include validation steps for every change.")

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
            logger.warning("Could not read %s: %s", path, r.get("error", ""))

    if not file_contents:
        return ExecuteResponse(
            ok=False,
            error="Could not read any of the relevant files.",
            git_checkpoint=git_checkpoint,
        )

    # Build prompt for Code Agent
    memory_ctx = build_memory_context(project_root)
    user_prompt = _build_code_agent_prompt(
        plan,
        file_contents,
        memory_ctx,
        req.user_request,
        req.context_bundle or {},
    )

    # Ask Gemini for file edits — expects a JSON array
    result = gemini.generate_text(
        system_prompt=CODE_AGENT_SYSTEM_PROMPT,
        user_prompt=user_prompt,
        request_model=req.model or None,
    )

    if not result["ok"]:
        return ExecuteResponse(
            ok=False,
            error=result.get("error", "Code agent failed"),
            git_checkpoint=git_checkpoint,
        )

    # Parse edits
    import json
    raw = result.get("data", "") or result.get("raw", "") or ""
    raw = raw.strip()
    if raw.startswith("```"):
        raw = "\n".join(raw.split("\n")[1:])
        if raw.endswith("```"):
            raw = raw[:-3]

    try:
        edits: list[dict] = json.loads(raw)
        if not isinstance(edits, list):
            edits = [edits]
    except json.JSONDecodeError as exc:
        return ExecuteResponse(
            ok=False,
            error=f"Code agent returned invalid JSON: {exc}",
            git_checkpoint=git_checkpoint,
            diffs=[{"raw_response": raw}],
        )

    # Apply edits
    files_written: list[str] = []
    diffs: list[dict] = []
    errors: list[str] = []

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
) -> str:
    lines = [f"TASK: {user_request or plan.summary}", ""]

    live = format_plugin_hints_block(plugin_ctx, max_chars=8000)
    if live:
        lines.append(live)
        lines.append("")

    if memory_ctx:
        lines.append(memory_ctx[:4500])
        lines.append("")

    lines.append("PLAN STEPS:")
    for step in plan.steps:
        lines.append(f"  {step.step_number}. {step.description}")
    lines.append("")

    lines.append("FILES TO EDIT (current content):")
    for path, content in file_contents.items():
        lines.append(f"\n=== {path} ===")
        lines.append(content[:12000])  # cap per file; large scenes may still truncate
        lines.append("=== END ===")

    lines.append("\nNow produce a JSON array of file edits.")
    lines.append("Each element: {\"path\": \"res://...\", \"new_content\": \"...complete file...\", \"reason\": \"...\"}")
    lines.append("Output ONLY the JSON array. No explanation text outside the JSON.")

    return "\n".join(lines)
