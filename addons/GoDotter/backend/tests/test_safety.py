from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

_BACKEND = Path(__file__).resolve().parents[1]
if str(_BACKEND) not in sys.path:
    sys.path.insert(0, str(_BACKEND))

from src.safety import check_path


class TestSafety(unittest.TestCase):
    def test_check_path_allows_res_path_inside_project(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = str(Path(td))
            result = check_path("res://systems/horde/new_backend.gd", root, allow_write=True)
            self.assertTrue(result.get("allowed"), result)


if __name__ == "__main__":
    unittest.main()
