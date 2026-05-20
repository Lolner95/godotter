from __future__ import annotations

import sys
import unittest
from pathlib import Path

_BACKEND = Path(__file__).resolve().parents[1]
if str(_BACKEND) not in sys.path:
    sys.path.insert(0, str(_BACKEND))

from src.schemas import Plan, PlanStep
from src.task_orchestrator import _collect_execute_targets


class TestExecuteTargets(unittest.TestCase):
    def test_collect_targets_uses_step_files_when_relevant_files_empty(self) -> None:
        plan = Plan(
            summary="Fix gameplay board",
            relevant_files=[],
            relevant_scenes=[],
            steps=[
                PlanStep(
                    step_number=1,
                    description="Patch board and hud",
                    tool_calls=[],
                    files_affected=["res://scripts/board/GameplayBoard.gd", "res://scripts/ui/GameHUD.gd"],
                    risk_level="medium",
                )
            ],
            validation_plan=[],
            approval_required=True,
        )
        out = _collect_execute_targets(plan)
        self.assertEqual(
            out,
            ["res://scripts/board/GameplayBoard.gd", "res://scripts/ui/GameHUD.gd"],
        )


if __name__ == "__main__":
    unittest.main()
