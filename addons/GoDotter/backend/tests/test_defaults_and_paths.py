from __future__ import annotations

import sys
import unittest
from pathlib import Path

_BACKEND = Path(__file__).resolve().parents[1]
if str(_BACKEND) not in sys.path:
    sys.path.insert(0, str(_BACKEND))

from src.schemas import ExecuteResponse
from src.validators import path_allowed_for_plan


class TestDefaultsAndPaths(unittest.TestCase):
    def test_execute_response_default_ok_is_false(self) -> None:
        r = ExecuteResponse()
        self.assertFalse(r.ok)

    def test_path_not_allowed_when_index_missing_and_unknown_root(self) -> None:
        ok, _ = path_allowed_for_plan("res://totally_unknown/new_script.gd", set(), True)
        self.assertFalse(ok)

if __name__ == "__main__":
    unittest.main()
