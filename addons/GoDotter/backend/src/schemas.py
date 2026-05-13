"""Pydantic v2 schemas for all GoDotter agent inputs and outputs.

These are used for:
- Request/response validation in FastAPI routes
- Structured JSON response schemas passed to Gemini
- Documentation and prompt building
"""
from __future__ import annotations

from enum import Enum
from typing import Any, Literal, Optional
from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class TaskStatus(str, Enum):
    queued = "queued"
    gathering_context = "gathering_context"
    planning = "planning"
    waiting_for_approval = "waiting_for_approval"
    editing = "editing"
    running_project = "running_project"
    capturing_screenshot = "capturing_screenshot"
    validating = "validating"
    reviewing = "reviewing"
    complete = "complete"
    failed = "failed"
    blocked = "blocked"
    reverted = "reverted"


class RiskLevel(str, Enum):
    low = "low"
    medium = "medium"
    high = "high"


class AgentStatus(str, Enum):
    complete = "complete"
    failed = "failed"
    partial = "partial"


# ---------------------------------------------------------------------------
# Core building blocks
# ---------------------------------------------------------------------------

class PlanStep(BaseModel):
    step_number: int
    description: str
    tool_calls: list[str] = Field(default_factory=list)
    files_affected: list[str] = Field(default_factory=list)
    risk_level: RiskLevel = RiskLevel.low


class Plan(BaseModel):
    summary: str
    relevant_files: list[str] = Field(default_factory=list)
    relevant_scenes: list[str] = Field(default_factory=list)
    assumptions: list[str] = Field(default_factory=list)
    risks: list[str] = Field(default_factory=list)
    steps: list[PlanStep] = Field(default_factory=list)
    validation_plan: list[str] = Field(default_factory=list)
    approval_required: bool = True


class Subtask(BaseModel):
    id: str
    title: str
    status: TaskStatus = TaskStatus.queued
    agent: str = ""
    result: dict[str, Any] = Field(default_factory=dict)


class Task(BaseModel):
    id: str
    title: str
    user_request: str
    created_at: float
    status: TaskStatus = TaskStatus.queued
    priority: int = 1
    current_step: int = 0
    plan: Optional[Plan] = None
    subtasks: list[Subtask] = Field(default_factory=list)
    context_bundle: dict[str, Any] = Field(default_factory=dict)
    files_to_inspect: list[str] = Field(default_factory=list)
    files_modified: list[str] = Field(default_factory=list)
    scenes_modified: list[str] = Field(default_factory=list)
    screenshots: list[str] = Field(default_factory=list)
    validation_results: list[dict] = Field(default_factory=list)
    logs: list[str] = Field(default_factory=list)
    final_report: dict[str, Any] = Field(default_factory=dict)
    approval_required: bool = True
    retry_count: int = 0
    parent_task_id: str = ""


class ToolCall(BaseModel):
    tool_name: str
    arguments: dict[str, Any] = Field(default_factory=dict)
    reason: str
    risk_level: RiskLevel = RiskLevel.low


class ToolResult(BaseModel):
    tool: str
    success: bool
    data: dict[str, Any] = Field(default_factory=dict)
    error: Optional[str] = None
    artifacts: list[str] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# File tools
# ---------------------------------------------------------------------------

class FilePatch(BaseModel):
    path: str
    unified_diff: str
    reason: str
    risk_level: RiskLevel = RiskLevel.medium
    backup_required: bool = True


# ---------------------------------------------------------------------------
# Scene / Node summaries
# ---------------------------------------------------------------------------

class NodeSummary(BaseModel):
    name: str
    node_class: str
    path: str
    script: str = ""
    groups: list[str] = Field(default_factory=list)
    children_count: int = 0
    exported_properties: list[dict] = Field(default_factory=list)
    signals_connected: list[dict] = Field(default_factory=list)
    issues: list[str] = Field(default_factory=list)


class SceneSummary(BaseModel):
    path: str
    node_count: int = 0
    root_node: str = ""
    root_class: str = ""
    scripts: list[str] = Field(default_factory=list)
    missing_scripts: list[str] = Field(default_factory=list)
    missing_resources: list[str] = Field(default_factory=list)
    issues: list[dict] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Project index
# ---------------------------------------------------------------------------

class ProjectIndex(BaseModel):
    project_path: str
    scanned_at: float
    scene_count: int = 0
    script_count: int = 0
    resource_count: int = 0
    scenes: list[dict] = Field(default_factory=list)
    scripts: list[dict] = Field(default_factory=list)
    resources: list[dict] = Field(default_factory=list)
    textures: list[dict] = Field(default_factory=list)
    audio: list[dict] = Field(default_factory=list)
    shaders: list[dict] = Field(default_factory=list)
    themes: list[dict] = Field(default_factory=list)
    autoloads: list[dict] = Field(default_factory=list)
    input_actions: list[str] = Field(default_factory=list)
    addons: list[str] = Field(default_factory=list)
    errors: list[str] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

class ValidationStep(BaseModel):
    action: str
    expected: str
    actual: str = ""
    passed: bool = False
    screenshot: str = ""


class ValidationResult(BaseModel):
    validation: str
    passed: bool
    steps: list[ValidationStep] = Field(default_factory=list)
    errors: list[str] = Field(default_factory=list)
    screenshots: list[str] = Field(default_factory=list)
    metrics: dict[str, Any] = Field(default_factory=dict)


# ---------------------------------------------------------------------------
# Screenshot / Visual review
# ---------------------------------------------------------------------------

class ScreenshotArtifact(BaseModel):
    task_id: str
    label: str
    path: str
    timestamp: float
    width: int = 0
    height: int = 0


class VisualReviewResult(BaseModel):
    improved: bool
    score_before: int = Field(ge=0, le=10)
    score_after: int = Field(ge=0, le=10)
    issues_found: list[str] = Field(default_factory=list)
    evidence: list[str] = Field(default_factory=list)
    recommended_next_fixes: list[str] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0, default=0.5)


# ---------------------------------------------------------------------------
# 3D Asset Review (new)
# ---------------------------------------------------------------------------

class AngleFinding(BaseModel):
    angle: str
    score: int = Field(ge=0, le=10)
    findings: list[str] = Field(default_factory=list)


class Asset3DReview(BaseModel):
    asset_path: str
    overall_score: int = Field(ge=0, le=10)
    per_angle_findings: list[AngleFinding] = Field(default_factory=list)
    mesh_issues: list[str] = Field(default_factory=list)
    uv_issues: list[str] = Field(default_factory=list)
    albedo_issues: list[str] = Field(default_factory=list)
    normal_issues: list[str] = Field(default_factory=list)
    scale_issues: list[str] = Field(default_factory=list)
    lighting_issues: list[str] = Field(default_factory=list)
    priority_recommendations: list[str] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0, default=0.5)


# ---------------------------------------------------------------------------
# Agent final report
# ---------------------------------------------------------------------------

class AgentFinalReport(BaseModel):
    status: AgentStatus
    summary: str
    files_changed: list[str] = Field(default_factory=list)
    scenes_changed: list[str] = Field(default_factory=list)
    tests_run: list[str] = Field(default_factory=list)
    screenshots: list[str] = Field(default_factory=list)
    before_after_result: str = ""
    remaining_issues: list[str] = Field(default_factory=list)
    recommended_next_tasks: list[str] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Agent-specific output schemas
# ---------------------------------------------------------------------------

class CodeAgentOutput(BaseModel):
    files_to_edit: list[str] = Field(default_factory=list)
    patches: list[FilePatch] = Field(default_factory=list)
    reasoning_summary: str
    expected_behavior_change: str
    validation_required: list[str] = Field(default_factory=list)


class SceneAgentOutput(BaseModel):
    scene_path: str
    node_changes: list[dict] = Field(default_factory=list)
    resource_changes: list[dict] = Field(default_factory=list)
    signal_changes: list[dict] = Field(default_factory=list)
    layout_changes: list[dict] = Field(default_factory=list)
    risks: list[str] = Field(default_factory=list)


class DebugAgentOutput(BaseModel):
    error_summary: str
    root_cause: str
    files_involved: list[str] = Field(default_factory=list)
    fix_plan: list[str] = Field(default_factory=list)
    patches: list[FilePatch] = Field(default_factory=list)
    validation_plan: list[str] = Field(default_factory=list)


class RefactorAgentOutput(BaseModel):
    refactor_goal: str
    behavior_preserved: bool = True
    files_changed: list[str] = Field(default_factory=list)
    before_architecture: str = ""
    after_architecture: str = ""
    risks: list[str] = Field(default_factory=list)
    tests_required: list[str] = Field(default_factory=list)


class AssetAgentOutput(BaseModel):
    asset_issues: list[str] = Field(default_factory=list)
    missing_assets: list[str] = Field(default_factory=list)
    unused_assets: list[str] = Field(default_factory=list)
    oversized_assets: list[str] = Field(default_factory=list)
    recommendations: list[str] = Field(default_factory=list)


class MechanicsQAOutput(BaseModel):
    mechanic: str
    steps_run: list[str] = Field(default_factory=list)
    expected_results: list[str] = Field(default_factory=list)
    actual_results: list[str] = Field(default_factory=list)
    passed: bool
    failures: list[str] = Field(default_factory=list)
    logs: list[str] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Log batch fix plan (new)
# ---------------------------------------------------------------------------

class ErrorGroup(BaseModel):
    signature: str
    count: int = 1
    sample_message: str
    files_implicated: list[str] = Field(default_factory=list)
    stack_top: list[str] = Field(default_factory=list)
    probable_cause: str = ""


class FixStep(BaseModel):
    order: int
    description: str
    files_to_edit: list[str] = Field(default_factory=list)
    target_line_hints: list[str] = Field(default_factory=list)
    risk_level: RiskLevel = RiskLevel.low
    addresses_groups: list[str] = Field(default_factory=list)


class LogBatchFixPlan(BaseModel):
    summary: str
    error_groups: list[ErrorGroup] = Field(default_factory=list)
    fix_steps: list[FixStep] = Field(default_factory=list)
    estimated_risk: RiskLevel = RiskLevel.medium
    approval_required: bool = True
    notes: list[str] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Request / Response wrappers
# ---------------------------------------------------------------------------

class PlanRequest(BaseModel):
    user_request: str
    context_bundle: dict[str, Any] = Field(default_factory=dict)
    mode: str = "plan"
    model: str = ""


class PlanResponse(BaseModel):
    ok: bool = True
    plan: Optional[Plan] = None
    error: Optional[str] = None
    hint: Optional[str] = None
    raw_response: Optional[str] = None


class IndexRequest(BaseModel):
    project_root: str


class IndexResponse(BaseModel):
    ok: bool = True
    scene_count: int = 0
    script_count: int = 0
    resource_count: int = 0
    index: dict[str, Any] = Field(default_factory=dict)
    error: Optional[str] = None


class ContextRequest(BaseModel):
    query: str
    project_root: str
    max_files: int = 20


class ContextResponse(BaseModel):
    ok: bool = True
    relevant_files: list[str] = Field(default_factory=list)
    scene_summaries: list[SceneSummary] = Field(default_factory=list)
    script_snippets: list[dict] = Field(default_factory=list)
    memory_context: str = ""
    error: Optional[str] = None


class FixLogsRequest(BaseModel):
    run_id: str = ""
    log_text: str
    project_index_ref: str = ""
    model: str = ""


class FixLogsResponse(BaseModel):
    ok: bool = True
    plan: Optional[LogBatchFixPlan] = None
    error_groups_found: int = 0
    error: Optional[str] = None
    raw_response: Optional[str] = None


class Visual3DRequest(BaseModel):
    asset_path: str = ""
    angle_images: list[dict] = Field(default_factory=list)  # [{angle, png_base64}]
    goals: list[str] = Field(default_factory=list)
    model: str = ""


class Visual3DResponse(BaseModel):
    ok: bool = True
    review: Optional[Asset3DReview] = None
    error: Optional[str] = None
    raw_response: Optional[str] = None


class HealthResponse(BaseModel):
    status: str = "ok"
    version: str = "0.2.0"
    gemini_key_present: bool = False
    api_key_present: bool = False
    model: str = ""


# ---------------------------------------------------------------------------
# File tool request/response (Phase 4)
# ---------------------------------------------------------------------------

class ReadFileRequest(BaseModel):
    path: str
    start_line: int = 0
    end_line: Optional[int] = None


class ReadFileResponse(BaseModel):
    ok: bool = True
    content: str = ""
    total_lines: int = 0
    truncated: bool = False
    path: str = ""
    error: Optional[str] = None


class WriteFileRequest(BaseModel):
    path: str
    new_content: str
    task_id: str = ""
    reason: str = ""
    create_checkpoint: bool = True


class WriteFileResponse(BaseModel):
    ok: bool = True
    path: str = ""
    backup_path: str = ""
    diff_text: str = ""
    lines_added: int = 0
    lines_removed: int = 0
    message: str = ""
    error: Optional[str] = None


class RevertFileRequest(BaseModel):
    path: str
    task_id: str = ""


# ---------------------------------------------------------------------------
# Execute agent (Phase 4)
# ---------------------------------------------------------------------------

class FileEdit(BaseModel):
    path: str
    new_content: str
    reason: str


class ExecuteRequest(BaseModel):
    plan: Optional[Plan] = None
    user_request: str = ""
    context_bundle: dict[str, Any] = Field(default_factory=dict)
    task_id: str = ""
    approved: bool = False
    model: str = ""


class ExecuteResponse(BaseModel):
    ok: bool = True
    task_id: str = ""
    files_written: list[str] = Field(default_factory=list)
    diffs: list[dict] = Field(default_factory=list)
    git_checkpoint: str = ""
    errors: list[str] = Field(default_factory=list)
    final_report: Optional[AgentFinalReport] = None
    error: Optional[str] = None


class AgentRunRequest(BaseModel):
    """One-shot autonomous session (plan + validate + optional execute)."""

    user_request: str
    context_bundle: dict[str, Any] = Field(default_factory=dict)
    model: str = ""
    auto_execute: bool = True
    max_plan_repairs: int = Field(2, ge=0, le=5)


class AgentRunResponse(BaseModel):
    ok: bool = True
    phases: list[dict[str, Any]] = Field(default_factory=list)
    plan: Optional[dict[str, Any]] = None
    execute: Optional[dict[str, Any]] = None
    validation: list[dict[str, Any]] = Field(default_factory=list)
    error: Optional[str] = None


# ---------------------------------------------------------------------------
# Visual map / neon debug visualization (new)
# ---------------------------------------------------------------------------

class NeonNodeEntry(BaseModel):
    """A single node's entry in the neon color map."""
    name: str
    node_class: str
    path: str
    neon_color_hex: str
    screen_x: float = 0.0
    screen_y: float = 0.0
    screen_width: float = 0.0
    screen_height: float = 0.0
    z_index: int = 0
    visible: bool = True
    script: str = ""
    children_count: int = 0
    depth: int = 0


class VisualMapRequest(BaseModel):
    screenshot_base64: str
    node_map: list[NeonNodeEntry] = Field(default_factory=list)
    color_legend: dict[str, str] = Field(default_factory=dict)  # class -> hex color
    scene_path: str = ""
    query: str = ""
    model: str = ""


class SpatialFinding(BaseModel):
    node_path: str
    node_class: str
    finding: str
    severity: Literal["info", "warning", "error"] = "info"
    screen_position: str = ""


class VisualMapAnalysis(BaseModel):
    scene_summary: str
    spatial_findings: list[SpatialFinding] = Field(default_factory=list)
    layout_issues: list[str] = Field(default_factory=list)
    depth_issues: list[str] = Field(default_factory=list)
    overlap_issues: list[str] = Field(default_factory=list)
    invisible_nodes: list[str] = Field(default_factory=list)
    recommendations: list[str] = Field(default_factory=list)
    node_count_visible: int = 0
    query_answer: str = ""


class VisualMapResponse(BaseModel):
    ok: bool = True
    analysis: Optional[VisualMapAnalysis] = None
    error: Optional[str] = None
    raw_response: Optional[str] = None
