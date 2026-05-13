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

logger = logging.getLogger(__name__)


def run_agent_session(
    req: AgentRunRequest,
    gemini: Any,
    project_root: str,
) -> AgentRunResponse:
    phases: list[dict[str, Any]] = []
    hints: dict[str, Any] = dict(req.context_bundle or {})
    policy: dict[str, Any] = dict(hints.get("godotter") or {})
    allow_execute = bool(req.auto_execute) and bool(policy.get("enable_file_edits", False))

    index = load_index(project_root) or {}
    user_text = req.user_request.strip()
    if not user_text:
        return AgentRunResponse(ok=False, phases=phases, error="user_request is empty")

    plan_obj = None
    last_plan_errors: list[str] = []

    for attempt in range(req.max_plan_repairs + 1):
        aug = user_text
        if last_plan_errors:
            aug = (
                user_text
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
        user_request=user_text,
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
        godot = try_godot_script_check(path, project_root)
        post.append({"heuristic": r, "godot": godot})
    if not post:
        post_ok = True
    else:
        post_ok = all(
            bool(p.get("heuristic", {}).get("ok", True))
            for p in post
        )
    phases.append(
        {
            "phase": "post_validate",
            "ok": post_ok,
            "details": post,
        }
    )

    overall_ok = bool(ex_resp.ok) and post_ok
    return AgentRunResponse(
        ok=overall_ok,
        phases=phases,
        plan=plan_dict,
        execute=ex_resp.model_dump(mode="json"),
        validation=post,
        error=ex_resp.error,
    )
