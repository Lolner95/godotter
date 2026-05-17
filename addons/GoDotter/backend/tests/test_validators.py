"""Unit tests for GoDotter static validators (no Gemini, no Godot binary required)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

_BACKEND = Path(__file__).resolve().parents[1]
if str(_BACKEND) not in sys.path:
    sys.path.insert(0, str(_BACKEND))

from src.validators import (
    path_allowed_for_plan,
    validate_gdscript_heuristic,
    validate_plan_paths,
    validate_tscn_heuristic,
)
from src.schemas import Plan, PlanStep
from src.task_orchestrator import _normalize_plan_minimums
from src.task_orchestrator import _ensure_plan_targets
from src.task_orchestrator import _canonicalize_plan_paths
from src.task_orchestrator import _salvage_file_edits_from_raw


class TestSalvageEdits(unittest.TestCase):
    def test_salvage_extracts_first_object_from_truncated_json_array(self) -> None:
        raw = (
            '[\n  {"path": "res://a.gd", "new_content": "extends Node\\n", "reason": "fix"},\n'
            '  {"path": "res://b.gd", "new_content": "extends Node\\nfunc _ready'
        )
        edits = _salvage_file_edits_from_raw(raw)
        self.assertEqual(len(edits), 1)
        self.assertEqual(edits[0]["path"], "res://a.gd")
        self.assertIn("extends Node", edits[0]["new_content"])


class TestPathPolicy(unittest.TestCase):
    def test_addon_blocked(self) -> None:
        ok, reason = path_allowed_for_plan("res://addons/Foo/bar.gd", set(), True)
        self.assertFalse(ok)
        self.assertIn("addons", reason)

    def test_hint_allowed_when_index_missing(self) -> None:
        ok, _ = path_allowed_for_plan("res://player.gd", set(), True)
        self.assertTrue(ok)

    def test_unknown_blocked_when_indexed(self) -> None:
        ok, _ = path_allowed_for_plan("res://ghost.gd", {"res://ok.gd"}, False)
        self.assertFalse(ok)

    def test_new_systems_file_allowed_when_indexed(self) -> None:
        ok, reason = path_allowed_for_plan("res://systems/horde/horde_swarm_manager.gd", {"res://ok.gd"}, False)
        self.assertTrue(ok)
        self.assertIn("new project file", reason)

    def test_new_scene_file_allowed_when_indexed(self) -> None:
        ok, reason = path_allowed_for_plan("res://scenes/debug/HordeStressTest.tscn", {"res://ok.gd"}, False)
        self.assertTrue(ok)
        self.assertIn("new project file", reason)


class TestPlanValidation(unittest.TestCase):
    def test_valid_plan(self) -> None:
        index = {
            "scenes": [{"path": "res://main.tscn"}],
            "scripts": [{"path": "res://player.gd"}],
        }
        plan = Plan(
            summary="test",
            relevant_files=["res://player.gd"],
            relevant_scenes=["res://main.tscn"],
            steps=[PlanStep(step_number=1, description="x", files_affected=["res://player.gd"])],
        )
        errs = validate_plan_paths(plan, index, {})
        self.assertEqual(errs, [])

    def test_empty_targets_allowed_when_index_missing(self) -> None:
        plan = Plan(
            summary="smoke",
            relevant_files=[],
            relevant_scenes=[],
            steps=[PlanStep(step_number=1, description="do checks", files_affected=[])],
        )
        errs = validate_plan_paths(plan, {}, {})
        self.assertEqual(errs, [])


class TestGdScriptHeuristic(unittest.TestCase):
    def test_balanced(self) -> None:
        src = "extends Node\nfunc _ready():\n\tpass\n"
        self.assertEqual(validate_gdscript_heuristic(src, "res://a.gd"), [])

    def test_unbalanced(self) -> None:
        src = "extends Node\nfunc _ready(\n\tpass\n"
        issues = validate_gdscript_heuristic(src, "res://a.gd")
        self.assertTrue(any("(" in i for i in issues))


class TestTscnHeuristic(unittest.TestCase):
    def test_minimal_scene(self) -> None:
        txt = "[gd_scene format=3]\n[node name=\"Root\" type=\"Node\"]\n"
        self.assertEqual(validate_tscn_heuristic(txt, "res://x.tscn"), [])


class TestPlanNormalization(unittest.TestCase):
    def test_normalize_fills_blank_step_fields(self) -> None:
        plan = Plan(
            summary="",
            relevant_files=["res://player.gd", "res://main.tscn"],
            steps=[
                PlanStep(step_number=8, description="", files_affected=[]),
            ],
            validation_plan=[],
        )
        out = _normalize_plan_minimums(plan, "Make movement smoother")
        self.assertEqual(out.summary, "Make movement smoother")
        self.assertEqual(out.steps[0].step_number, 1)
        self.assertTrue(out.steps[0].description.strip())
        self.assertGreater(len(out.steps[0].files_affected), 0)
        self.assertGreater(len(out.validation_plan), 0)

    def test_normalize_infers_plan_relevant_files_from_steps(self) -> None:
        plan = Plan(
            summary="Fix input lag",
            relevant_files=[],
            steps=[
                PlanStep(step_number=2, description="Edit player controller", files_affected=["res://player.gd"]),
                PlanStep(step_number=3, description="Tune HUD", files_affected=["res://ui/hud.gd"]),
            ],
        )
        out = _normalize_plan_minimums(plan, "Fix input lag")
        self.assertEqual(out.steps[0].step_number, 1)
        self.assertEqual(out.steps[1].step_number, 2)
        self.assertEqual(out.relevant_files, ["res://player.gd", "res://ui/hud.gd"])

    def test_ensure_plan_targets_fills_missing_plan_targets(self) -> None:
        plan = Plan(
            summary="Fix menu behavior",
            relevant_files=[],
            relevant_scenes=[],
            steps=[PlanStep(step_number=1, description="Fix menu script", files_affected=["res://ui/menu.gd"])],
        )
        project_ctx = {"relevant_files": ["res://ui/menu.gd", "res://levels/main.tscn"]}
        index = {"scripts": [{"path": "res://player.gd"}], "scenes": [{"path": "res://main.tscn"}]}
        out = _ensure_plan_targets(plan, project_ctx, index)
        self.assertEqual(out.relevant_files, ["res://ui/menu.gd"])
        self.assertEqual(out.relevant_scenes, ["res://levels/main.tscn"])

    def test_normalize_filters_non_res_scheme_paths(self) -> None:
        plan = Plan(
            summary="Fix run mode",
            relevant_files=["res://ok.gd", "C:/tmp/not-valid.gd"],
            relevant_scenes=["The main battle scene (path unknown)", "res://main.tscn"],
            steps=[PlanStep(step_number=1, description="x", files_affected=["res://ok.gd"])],
        )
        out = _normalize_plan_minimums(plan, "Fix run mode")
        self.assertEqual(out.relevant_files, ["res://ok.gd"])
        self.assertEqual(out.relevant_scenes, ["res://main.tscn"])

    def test_canonicalize_maps_step_file_basenames(self) -> None:
        plan = Plan(
            summary="Fix card view",
            relevant_files=["CardView.gd"],
            relevant_scenes=[],
            steps=[PlanStep(step_number=1, description="Fix visuals", files_affected=["CardView.gd"])],
        )
        project_ctx = {"relevant_files": ["res://ui/CardView.gd", "res://main.tscn"]}
        index = {"scripts": [{"path": "res://ui/CardView.gd"}], "scenes": [{"path": "res://main.tscn"}]}
        out = _canonicalize_plan_paths(plan, project_ctx, index)
        self.assertEqual(out.relevant_files, ["res://ui/CardView.gd"])
        self.assertEqual(out.steps[0].files_affected, ["res://ui/CardView.gd"])


if __name__ == "__main__":
    unittest.main()
