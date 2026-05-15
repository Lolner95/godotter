"""FastAPI application for the GoDotter agent backend.

Start with: python main.py (or uvicorn src.app:app --reload)
"""
from __future__ import annotations

import json
import logging
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .code_tools import get_diff, read_file, revert_file, write_file
from .gemini_client import GeminiClient, _DEFAULT_OPENAI_API_BASE, openai_runtime_fingerprint_from_env
from .git_tools import create_checkpoint, get_status, is_git_repo
from .memory_store import ensure_memory_files, read_memory
from .project_indexer import build_compact_context, index_project, load_index
from .schemas import (
    AITestSettingsRequest,
    AITestSettingsResponse,
    AgentRunRequest,
    AgentRunResponse,
    ContextRequest,
    ContextResponse,
    ExecuteRequest,
    ExecuteResponse,
    FixLogsRequest,
    FixLogsResponse,
    HealthResponse,
    IndexRequest,
    IndexResponse,
    PlanRequest,
    PlanResponse,
    ReadFileRequest,
    ReadFileResponse,
    RevertFileRequest,
    VisualMapRequest,
    VisualMapResponse,
    Visual3DRequest,
    Visual3DResponse,
    WriteFileRequest,
    WriteFileResponse,
)
from .task_orchestrator import build_plan
from .agent_run import run_agent_session
from .ai_model_settings import extract_and_resolve_ai_settings, registry_payload

logger = logging.getLogger(__name__)

VERSION = "0.2.0"


# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

def load_config() -> dict:
    # config.json lives next to main.py, one level above src/
    config_path = Path(__file__).parent.parent / "config.json"
    defaults = {
        "model": "gemini-3.1-pro-preview",
        "temperature": 0.2,
        "max_output_tokens": 131072,
        "max_input_tokens": 2000000,
        "max_retries": 2,
        "port": 8765,
        "host": "127.0.0.1",
        "log_level": "info",
        "project_root": "",
    }
    if config_path.exists():
        try:
            user_config = json.loads(config_path.read_text(encoding="utf-8"))
            defaults.update(user_config)
        except Exception as exc:
            logger.warning("Could not read config.json: %s", exc)
    return defaults


# ---------------------------------------------------------------------------
# App lifespan (startup/shutdown)
# ---------------------------------------------------------------------------

_gemini: GeminiClient | None = None
_config: dict = {}


def _backend_root() -> Path:
    return Path(__file__).resolve().parent.parent


def ensure_api_key_env_from_file() -> None:
    """Load provider keys from plugin-managed key files when env vars are missing."""
    root = _backend_root()
    # New provider-aware key map.
    keys_path = root / ".godotter_api_keys.json"
    if keys_path.is_file():
        try:
            payload = json.loads(keys_path.read_text(encoding="utf-8"))
            if isinstance(payload, dict):
                gemini_key = str(payload.get("gemini", "")).strip()
                openai_key = str(payload.get("openai", "")).strip()
                claude_key = str(payload.get("claude", "")).strip()
                if gemini_key and not (
                    os.environ.get("GEMINI_API_KEY", "").strip()
                    or os.environ.get("GOOGLE_API_KEY", "").strip()
                ):
                    os.environ["GEMINI_API_KEY"] = gemini_key
                if openai_key and not os.environ.get("OPENAI_API_KEY", "").strip():
                    os.environ["OPENAI_API_KEY"] = openai_key
                if claude_key and not (
                    os.environ.get("ANTHROPIC_API_KEY", "").strip()
                    or os.environ.get("CLAUDE_API_KEY", "").strip()
                ):
                    os.environ["ANTHROPIC_API_KEY"] = claude_key
                openai_base = str(payload.get("openai_base_url", "")).strip()
                if openai_base and not os.environ.get("OPENAI_BASE_URL", "").strip():
                    os.environ["OPENAI_BASE_URL"] = openai_base
        except Exception as exc:
            logger.warning("Could not read .godotter_api_keys.json: %s", exc)
    # Backward-compatible legacy Gemini key file.
    if os.environ.get("GEMINI_API_KEY", "").strip() or os.environ.get("GOOGLE_API_KEY", "").strip():
        return
    key_path = root / ".godotter_api_key"
    if key_path.is_file():
        try:
            key = key_path.read_text(encoding="utf-8").strip()
            if key:
                os.environ["GEMINI_API_KEY"] = key
        except OSError as exc:
            logger.warning("Could not read .godotter_api_key: %s", exc)


def refresh_gemini_if_env_has_key() -> None:
    """Recreate client after plugin writes key files while server is already running."""
    global _gemini
    ensure_api_key_env_from_file()
    openai_sig = openai_runtime_fingerprint_from_env()
    env_has = bool(
        os.environ.get("GEMINI_API_KEY", "").strip() or os.environ.get("GOOGLE_API_KEY", "").strip()
        or os.environ.get("OPENAI_API_KEY", "").strip()
        or os.environ.get("ANTHROPIC_API_KEY", "").strip()
        or os.environ.get("CLAUDE_API_KEY", "").strip()
        or openai_sig[1] != _DEFAULT_OPENAI_API_BASE
    )
    if _gemini is None:
        _gemini = GeminiClient(_config or {})
        return
    old_sig = getattr(_gemini, "_runtime_openai_sig", None)
    if old_sig != openai_sig:
        _gemini = GeminiClient(_config or {})
        return
    if env_has and (not _gemini.ready or not _gemini.key_present):
        _gemini = GeminiClient(_config or {})


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _gemini, _config
    logging.basicConfig(level=logging.INFO)
    _config = load_config()

    log_level = getattr(logging, _config.get("log_level", "info").upper(), logging.INFO)
    logging.getLogger().setLevel(log_level)

    _gemini = GeminiClient(_config)

    project_root = _config.get("project_root", "")

    # CLI arg takes priority (set via env var by main.py)
    env_root = os.environ.get("GODOTTER_PROJECT_ROOT", "")
    if env_root and not project_root:
        project_root = env_root
        _config["project_root"] = project_root
        logger.info("Project root from CLI: %s", project_root)

    if not project_root:
        # Walk upward from app.py searching for project.godot.
        # New layout: <project>/addons/GoDotter/backend/src/app.py  (4 levels up)
        # Old layout: <project>/tools/godot_forge_agent/src/app.py  (3 levels up)
        # We scan upward instead of hard-coding depth so it works from any install.
        search = Path(__file__).resolve()
        for _ in range(8):
            search = search.parent
            if (search / "project.godot").exists():
                project_root = str(search)
                _config["project_root"] = project_root
                logger.info("Auto-detected project root: %s", project_root)
                break
        if not project_root:
            # Last resort: CWD (works when launched from the project directory)
            if (Path.cwd() / "project.godot").exists():
                project_root = str(Path.cwd())
                _config["project_root"] = project_root
                logger.info("Project root from CWD: %s", project_root)

    if project_root:
        ensure_memory_files(project_root)

    logger.info(
        "GoDotter backend %s started. Model: %s | Key: %s",
        VERSION,
        _gemini.model,
        "present" if _gemini.key_present else "MISSING",
    )
    yield
    logger.info("GoDotter backend shutting down.")


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(
    title="GoDotter Agent Backend",
    description="Local AI backend for the GoDotter Godot editor plugin.",
    version=VERSION,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
def root():
    """Browser-friendly landing (avoids bare 404 on http://127.0.0.1:8765/)."""
    return {
        "service": "GoDotter backend",
        "version": VERSION,
        "health": "/health",
        "docs": "/docs",
        "openapi_json": "/openapi.json",
        "hint": "Open /health for JSON status; use the Godot plugin to call /agent/plan.",
    }


def _get_gemini() -> GeminiClient:
    refresh_gemini_if_env_has_key()
    if _gemini is None:
        raise HTTPException(status_code=503, detail="Backend not initialized")
    return _gemini


def _get_project_root() -> str:
    root = _config.get("project_root", "")
    if not root:
        raise HTTPException(
            status_code=400,
            detail="project_root not configured. Pass it in the request or set it in config.json.",
        )
    return root


def _mock_test_response(invocation: dict[str, Any]) -> AITestSettingsResponse:
    active = invocation.get("active", {}) if isinstance(invocation.get("active"), dict) else {}
    model = str(invocation.get("model", ""))
    provider = str(invocation.get("provider", ""))
    return AITestSettingsResponse(
        ok=True,
        provider=provider,
        model=model,
        latency_ms=120,
        token_usage={
            "input_tokens_estimate": 80,
            "output_tokens_estimate": min(int(active.get("max_output_tokens", 512)), 256),
        },
        settings_applied=active,
        mocked=True,
    )


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/health", response_model=HealthResponse)
def get_health():
    global _gemini
    refresh_gemini_if_env_has_key()
    if _gemini is None:
        _gemini = GeminiClient(_config or {})
    info = _gemini.get_health_info()
    return HealthResponse(
        status="ok",
        version=VERSION,
        gemini_key_present=info.get("gemini_key_present", False),
        api_key_present=info.get("api_key_present", info.get("gemini_key_present", False)),
        api_keys_present=info.get("api_keys_present", {}),
        model=info.get("model", ""),
    )


@app.get("/ai/capabilities")
def get_ai_capabilities():
    return {"ok": True, "registry": registry_payload()}


@app.post("/ai/test_model_settings", response_model=AITestSettingsResponse)
def post_ai_test_model_settings(req: AITestSettingsRequest):
    gemini = _get_gemini()
    invocation = extract_and_resolve_ai_settings(req.context_bundle, req.model or None)
    if invocation.get("errors"):
        return AITestSettingsResponse(
            ok=False,
            provider=str(invocation.get("provider", "")),
            model=str(invocation.get("model", "")),
            settings_applied=invocation.get("active", {}),
            error="Invalid AI settings: " + "; ".join(invocation["errors"]),
        )
    provider = str(invocation.get("provider", "gemini"))
    t0 = time.time()
    if not gemini.can_call_provider(provider):
        return _mock_test_response(invocation)
    test_prompt = req.prompt.strip() or "Fix this GDScript bug: null reference in _process()"
    result = gemini.generate_text(
        system_prompt="You are an expert Godot coding assistant. Reply briefly.",
        user_prompt=test_prompt,
        request_model=invocation.get("model") or None,
        invocation=invocation,
    )
    latency = int((time.time() - t0) * 1000)
    if not result.get("ok"):
        return AITestSettingsResponse(
            ok=False,
            provider=provider,
            model=str(invocation.get("model", "")),
            latency_ms=latency,
            settings_applied=invocation.get("active", {}),
            mocked=False,
            error=str(result.get("error", "test failed")),
        )
    raw = str(result.get("data", "") or "")
    return AITestSettingsResponse(
        ok=True,
        provider=provider,
        model=str(invocation.get("model", "")),
        latency_ms=latency,
        token_usage={
            "input_tokens_estimate": max(1, len(test_prompt) // 4),
            "output_tokens_estimate": max(1, len(raw) // 4),
        },
        settings_applied=invocation.get("active", {}),
        mocked=False,
    )


# ---------------------------------------------------------------------------
# Project routes
# ---------------------------------------------------------------------------

@app.post("/project/index", response_model=IndexResponse)
def post_project_index(req: IndexRequest):
    project_root = req.project_root or _config.get("project_root", "")
    if not project_root:
        return IndexResponse(ok=False, error="project_root is required")

    _config["project_root"] = project_root
    ensure_memory_files(project_root)

    try:
        idx = index_project(project_root)
    except Exception as exc:
        logger.exception("Index error")
        return IndexResponse(ok=False, error=str(exc))

    return IndexResponse(
        ok=True,
        scene_count=idx.get("scene_count", 0),
        script_count=idx.get("script_count", 0),
        resource_count=idx.get("resource_count", 0),
        index=idx,
    )


@app.post("/project/context", response_model=ContextResponse)
def post_project_context(req: ContextRequest):
    project_root = req.project_root or _config.get("project_root", "")
    if not project_root:
        return ContextResponse(ok=False, error="project_root is required")

    idx = load_index(project_root)
    if not idx:
        return ContextResponse(
            ok=False,
            error="No project index found. Run /project/index first.",
        )

    compact = build_compact_context(idx, req.query, req.max_files)
    memory = read_memory(project_root)
    memory_str = "\n\n".join(f"## {k}\n{v}" for k, v in memory.items())

    return ContextResponse(
        ok=True,
        relevant_files=compact.get("relevant_files", []),
        memory_context=memory_str,
    )


# ---------------------------------------------------------------------------
# Agent routes — implemented
# ---------------------------------------------------------------------------

@app.post("/agent/plan", response_model=PlanResponse)
def post_agent_plan(req: PlanRequest):
    gemini = _get_gemini()
    project_root = _config.get("project_root", "")

    # Allow project_root from context_bundle if not configured
    if not project_root and req.context_bundle.get("project_root"):
        project_root = req.context_bundle["project_root"]
        _config["project_root"] = project_root
        ensure_memory_files(project_root)

    try:
        response = build_plan(req, gemini, project_root)
    except Exception as exc:
        logger.exception("Plan agent error")
        return PlanResponse(ok=False, error=str(exc))

    return response


@app.post("/agent/run", response_model=AgentRunResponse)
def post_agent_run(req: AgentRunRequest):
    """Full agent: plan → validate → optional execute → post-validate (Roo-style single session)."""
    refresh_gemini_if_env_has_key()
    gemini = _get_gemini()
    project_root = _config.get("project_root", "")
    if not project_root and req.context_bundle.get("project_root"):
        project_root = str(req.context_bundle["project_root"])
        _config["project_root"] = project_root
        ensure_memory_files(project_root)
    if not project_root:
        return AgentRunResponse(ok=False, phases=[], error="project_root not configured")

    try:
        return run_agent_session(req, gemini, project_root)
    except Exception as exc:
        logger.exception("agent/run failed")
        return AgentRunResponse(ok=False, phases=[], error=str(exc))


# ---------------------------------------------------------------------------
# Memory
# ---------------------------------------------------------------------------

@app.get("/memory")
def get_memory():
    project_root = _config.get("project_root", "")
    if not project_root:
        return {"ok": False, "error": "project_root not set"}
    memory = read_memory(project_root)
    return {"ok": True, "memory": memory}


# ---------------------------------------------------------------------------
# Stubbed agent routes (Phase 4+)
# ---------------------------------------------------------------------------

def _stub(phase: int, name: str):
    return JSONResponse(
        status_code=501,
        content={
            "ok": False,
            "error": f"{name} not yet implemented",
            "phase": phase,
            "hint": f"This feature is planned for Phase {phase}. Use /agent/plan for now.",
        },
    )


@app.post("/agent/execute", response_model=ExecuteResponse)
def post_agent_execute(req: ExecuteRequest):
    gemini = _get_gemini()
    project_root = _config.get("project_root", "")
    if not project_root:
        return ExecuteResponse(ok=False, error="project_root not configured")

    from .task_orchestrator import execute_plan
    try:
        return execute_plan(req, gemini, project_root)
    except Exception as exc:
        logger.exception("Execute error")
        return ExecuteResponse(ok=False, error=str(exc))


@app.post("/agent/validate")
def post_agent_validate():
    """Metadata for static validators (used by Full agent internally)."""
    return {
        "ok": True,
        "validators": [
            "plan_paths — relevant_files/scenes must exist in index or editor hints",
            "gdscript_heuristic — bracket balance + read-back after write",
            "tscn_heuristic — gd_scene / node sections after write",
            "godot_cli_optional — set GODOT_PATH for `godot --headless --check-only`",
        ],
        "hint": "The Full agent pipeline is POST /agent/run",
    }


@app.post("/agent/visual_review", include_in_schema=False)
def post_agent_visual_review():
    return _stub(7, "agent/visual_review")


@app.post("/agent/debug", include_in_schema=False)
def post_agent_debug():
    return _stub(4, "agent/debug")


@app.post("/agent/refactor", include_in_schema=False)
def post_agent_refactor():
    return _stub(4, "agent/refactor")


# ---------------------------------------------------------------------------
# Remaining stubbed tool routes (Phase 5+)
# ---------------------------------------------------------------------------

@app.post("/tools/run_godot", include_in_schema=False)
def post_tools_run_godot():
    return _stub(5, "tools/run_godot")


@app.post("/tools/capture_screenshot", include_in_schema=False)
def post_tools_capture_screenshot():
    return _stub(6, "tools/capture_screenshot")


@app.post("/tools/compare_screenshots", include_in_schema=False)
def post_tools_compare_screenshots():
    return _stub(7, "tools/compare_screenshots")


# ---------------------------------------------------------------------------
# File tool routes (Phase 4 — implemented)
# ---------------------------------------------------------------------------

@app.post("/tools/read_file", response_model=ReadFileResponse)
def post_tools_read_file(req: ReadFileRequest):
    project_root = _config.get("project_root", "")
    if not project_root:
        return ReadFileResponse(ok=False, error="project_root not configured")
    result = read_file(req.path, project_root, req.start_line, req.end_line)
    return ReadFileResponse(**result)


@app.post("/tools/write_file", response_model=WriteFileResponse)
def post_tools_write_file(req: WriteFileRequest):
    project_root = _config.get("project_root", "")
    if not project_root:
        return WriteFileResponse(ok=False, error="project_root not configured")

    if not _config.get("enable_file_edits", False):
        return WriteFileResponse(
            ok=False,
            error="File edits are disabled. Enable in plugin settings or set enable_file_edits=true in config.",
        )

    # Git checkpoint before first edit of a task
    if req.create_checkpoint:
        cp = create_checkpoint(project_root, f"Before task: {req.task_id or 'edit'}")
        if not cp.get("ok"):
            logger.warning("Git checkpoint failed: %s", cp.get("error", ""))

    result = write_file(
        req.path,
        req.new_content,
        project_root,
        task_id=req.task_id,
        reason=req.reason,
    )
    return WriteFileResponse(**result)


@app.post("/tools/revert_file")
def post_tools_revert_file(req: RevertFileRequest):
    project_root = _config.get("project_root", "")
    if not project_root:
        return {"ok": False, "error": "project_root not configured"}
    result = revert_file(req.path, project_root, req.task_id)
    return result


@app.get("/tools/git_status")
def get_tools_git_status():
    project_root = _config.get("project_root", "")
    if not project_root:
        return {"ok": False, "error": "project_root not configured"}
    return get_status(project_root)


@app.post("/tools/search")
def post_tools_search_impl(body: dict):
    project_root = _config.get("project_root", "")
    if not project_root:
        return {"ok": False, "error": "project_root not configured"}
    from .file_tools import search_text
    query = body.get("query", "")
    pattern = body.get("glob", "**/*.gd")
    return search_text(query, project_root, pattern)


# ---------------------------------------------------------------------------
# Stubbed task routes (Phase 4+)
# ---------------------------------------------------------------------------

@app.get("/tasks", include_in_schema=False)
def get_tasks():
    return _stub(4, "tasks (list)")


@app.post("/tasks", include_in_schema=False)
def post_tasks():
    return _stub(4, "tasks (create)")


@app.post("/tasks/{task_id}/run", include_in_schema=False)
def post_task_run(task_id: str):
    return _stub(4, f"tasks/{task_id}/run")


@app.post("/tasks/{task_id}/cancel", include_in_schema=False)
def post_task_cancel(task_id: str):
    return _stub(4, f"tasks/{task_id}/cancel")


@app.post("/tasks/{task_id}/revert", include_in_schema=False)
def post_task_revert(task_id: str):
    return _stub(4, f"tasks/{task_id}/revert")


# ---------------------------------------------------------------------------
# 3D visual review and fix-from-logs are imported from their own modules
# and wired below after they are defined in later files.
# They are registered here as forward references; the actual implementation
# is in asset3d_review.py and log_aggregator.py, imported at the bottom.
# ---------------------------------------------------------------------------

from .asset3d_review import handle_visual_review_3d  # noqa: E402
from .log_aggregator import handle_fix_from_logs      # noqa: E402
from .visual_map import handle_visual_map             # noqa: E402


@app.post("/agent/visual_review_3d", response_model=Visual3DResponse)
def post_agent_visual_review_3d(req: Visual3DRequest):
    gemini = _get_gemini()
    project_root = _config.get("project_root", "")
    return handle_visual_review_3d(req, gemini, project_root)


@app.post("/agent/fix_from_logs", response_model=FixLogsResponse)
def post_agent_fix_from_logs(req: FixLogsRequest):
    gemini = _get_gemini()
    project_root = _config.get("project_root", "")
    return handle_fix_from_logs(req, gemini, project_root)


@app.post("/agent/visual_map", response_model=VisualMapResponse)
def post_agent_visual_map(req: VisualMapRequest):
    gemini = _get_gemini()
    project_root = _config.get("project_root", "")
    return handle_visual_map(req, gemini, project_root)
