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


if __name__ == "__main__":
    unittest.main()
