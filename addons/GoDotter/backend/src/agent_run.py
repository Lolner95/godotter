"""Full autonomous agent session: plan → validate → (optional) execute → post-validate.

This is the closest analogue to Roo / Claude Code style flows we can run inside one HTTP
request: bounded repair loop on the plan, then a single code-agent write pass with checks.
"""
from __future__ import annotations

import logging
import time
from typing import Any

from .schemas import AgentRunRequest, AgentRunResponse, ExecuteRequest, PlanRequest
from .task_orchestrator import build_plan, execute_plan
from .validators import (
    validate_file_after_write,
    validate_plan_paths,
    try_godot_script_check,
)
from .project_indexer import load_index
from .context_images import extract_context_images
from .godot_cli import run_project, run_scene

logger = logging.getLogger(__name__)


def run_agent_session(
    req: AgentRunRequest,
    gemini: Any,
    project_root: str,
) -> AgentRunResponse:
    phases: list[dict[str, Any]] = []
    hints: dict[str, Any] = dict(req.context_bundle or {})
    user_text = req.user_request.strip()
    hints = _adapt_hints_for_small_tasks(hints, user_text)
    policy: dict[str, Any] = dict(hints.get("godotter") or {})
    allow_execute = bool(req.auto_execute) and bool(policy.get("enable_file_edits", False))

    index = load_index(project_root) or {}
    ctx_imgs = extract_context_images(hints)
    if not user_text and not ctx_imgs:
        return AgentRunResponse(ok=False, phases=phases, error="user_request is empty")
    effective_user = user_text or (
        "(The user attached image(s) with no text. Infer goals from the images and project context.)"
    )

    plan_obj = None
    last_plan_errors: list[str] = []

    max_repairs = _effective_max_plan_repairs(req.max_plan_repairs, effective_user)
    for attempt in range(max_repairs + 1):
        aug = effective_user
        if last_plan_errors:
            aug = (
                effective_user
                + "\n\n---\nThe previous plan failed static validation. Fix ONLY paths/files:\n"
                + "\n".join(f"- {e}" for e in last_plan_errors)
            )
        plan_req = PlanRequest(user_request=aug, context_bundle=hints, model=req.model or "")
        t0 = time.time()
        plan_resp = build_plan(plan_req, gemini, project_root)
        phases.append(
            {
                "phase": "plan",
                "attempt": attempt,
                "ok": plan_resp.ok,
                "ms": int((time.time() - t0) * 1000),
                "error": plan_resp.error,
            }
        )

        if not plan_resp.ok or not plan_resp.plan:
            return AgentRunResponse(
                ok=False,
                phases=phases,
                error=plan_resp.error or "Plan generation failed",
                plan=None,
            )

        plan_obj = plan_resp.plan
        v_errs = validate_plan_paths(plan_obj, index, hints)
        phases.append(
            {
                "phase": "validate_plan",
                "attempt": attempt,
                "ok": len(v_errs) == 0,
                "errors": v_errs,
            }
        )
        if not v_errs:
            break
        last_plan_errors = v_errs
        logger.warning("Plan validation failed (attempt %s): %s", attempt, v_errs)
    else:
        return AgentRunResponse(
            ok=False,
            phases=phases,
            error="Plan still invalid after repair rounds: " + "; ".join(last_plan_errors),
            plan=plan_obj.model_dump() if plan_obj else None,
        )

    assert plan_obj is not None
    plan_dict = plan_obj.model_dump()

    if not allow_execute:
        phases.append(
            {
                "phase": "execute_skipped",
                "ok": True,
                "reason": "enable_file_edits is off in Settings (godotter.enable_file_edits).",
            }
        )
        return AgentRunResponse(ok=True, phases=phases, plan=plan_dict, execute=None)

    ex_req = ExecuteRequest(
        plan=plan_obj,
        user_request=effective_user,
        context_bundle=hints,
        approved=True,
        model=req.model or "",
        task_id=f"agent_{int(time.time())}",
    )
    t1 = time.time()
    ex_resp = execute_plan(ex_req, gemini, project_root)
    phases.append(
        {
            "phase": "execute",
            "ok": ex_resp.ok,
            "ms": int((time.time() - t1) * 1000),
            "files_written": list(ex_resp.files_written),
            "errors": list(ex_resp.errors),
        }
    )

    post: list[dict[str, Any]] = []
    for path in ex_resp.files_written:
        r = validate_file_after_write(path, project_root)
        godot = try_godot_script_check(path, project_root, hints)
        post.append({"heuristic": r, "godot": godot})
    if not post:
        post_ok = True
        post_errors: list[str] = []
    else:
        post_ok = True
        post_errors = _summarize_post_validate_errors(post)
        post_ok = len(post_errors) == 0
    phases.append(
        {
            "phase": "post_validate",
            "ok": post_ok,
            "errors": post_errors,
            "details": post,
        }
    )

    runtime_checks: list[dict[str, Any]] = []
    runtime_ok = True
    runtime_errors: list[str] = []
    if ex_resp.files_written:
        # Run scene-local smoke checks first, then whole-project run.
        for scn in _pick_changed_scenes(plan_obj, ex_resp.files_written):
            rs = run_scene(project_root, scn, timeout=50, hints=hints)
            runtime_checks.append({"scope": "scene", "scene": scn, "result": rs})
            if not bool(rs.get("ok", False)):
                runtime_ok = False
                runtime_errors.extend(_summarize_runtime_errors(rs, f"scene {scn}"))
        rp = run_project(project_root, timeout=70, hints=hints)
        runtime_checks.append({"scope": "project", "result": rp})
        if not bool(rp.get("ok", False)):
            runtime_ok = False
            runtime_errors.extend(_summarize_runtime_errors(rp, "project"))
    phases.append(
        {
            "phase": "runtime_regression_loop",
            "ok": runtime_ok,
            "errors": runtime_errors[:24],
            "details": runtime_checks,
        }
    )

    overall_ok = bool(ex_resp.ok) and post_ok and runtime_ok
    final_error: str | None = ex_resp.error
    if not overall_ok and not final_error:
        if not bool(ex_resp.ok):
            final_error = "Execute phase failed."
        elif not post_ok:
            final_error = "Post-validate failed (heuristic or Godot syntax checks)."
        elif not runtime_ok:
            final_error = "Runtime regression loop detected errors in scene/project run."
    return AgentRunResponse(
        ok=overall_ok,
        phases=phases,
        plan=plan_dict,
        execute=ex_resp.model_dump(mode="json"),
        validation=post,
        error=final_error,
    )


def _summarize_post_validate_errors(post: list[dict[str, Any]]) -> list[str]:
    out: list[str] = []
    for block in post:
        heuristic = block.get("heuristic") or {}
        path = str(heuristic.get("path", "res://?"))
        if not bool(heuristic.get("ok", True)):
            for err in list(heuristic.get("errors") or []):
                out.append(f"{path}: {err}")
        godot = block.get("godot") or {}
        if isinstance(godot, dict) and not bool(godot.get("skipped", False)):
            if not bool(godot.get("ok", False)):
                note = str(godot.get("error", "") or godot.get("stderr", "") or "Godot syntax check failed").strip()
                if note:
                    out.append(f"{path}: {note[:400]}")
                else:
                    out.append(f"{path}: Godot syntax check failed (rc={godot.get('returncode', '?')})")
    return out[:24]


def _summarize_runtime_errors(result: dict[str, Any], label: str) -> list[str]:
    out: list[str] = []
    for err in list(result.get("errors") or []):
        out.append(f"[{label}] {err}")
    top = str(result.get("error", "") or "").strip()
    if top:
        out.append(f"[{label}] {top}")
    return out[:12]


def _pick_changed_scenes(plan_obj, files_written: list[str]) -> list[str]:
    out: list[str] = []
    for s in list(plan_obj.relevant_scenes):
        ss = str(s).strip()
        if ss.startswith("res://") and ss.endswith(".tscn") and ss not in out:
            out.append(ss)
    for p in files_written:
        pp = str(p).strip()
        if pp.endswith(".tscn") and pp.startswith("res://") and pp not in out:
            out.append(pp)
    return out[:3]


def _looks_like_small_task(user_text: str) -> bool:
    txt = user_text.strip().lower()
    if not txt:
        return False
    if len(txt) > 220 or txt.count("\n") > 2:
        return False
    broad_markers = (
        "refactor",
        "architecture",
        "migrate",
        "entire",
        "whole",
        "all files",
        "full project",
        "rewrite",
        "overhaul",
    )
    return not any(m in txt for m in broad_markers)


def _adapt_hints_for_small_tasks(hints: dict[str, Any], user_text: str) -> dict[str, Any]:
    """Reduce token/context size for quick tasks to cut latency significantly."""
    if not _looks_like_small_task(user_text):
        return hints
    out = dict(hints)
    godotter = dict((out.get("godotter") or {}))
    if not isinstance(godotter, dict):
        godotter = {}
    max_out = int(godotter.get("max_output_tokens", 131072) or 131072)
    max_in = int(godotter.get("max_input_tokens", 2000000) or 2000000)
    # Only auto-shrink when on default max profile.
    if max_out >= 131072 and max_in >= 2000000:
        godotter["max_output_tokens"] = 32768
        godotter["max_input_tokens"] = 400000
    out["godotter"] = godotter
    return out


def _effective_max_plan_repairs(requested: int, user_text: str) -> int:
    if _looks_like_small_task(user_text):
        return min(1, max(0, int(requested)))
    return max(0, int(requested))
