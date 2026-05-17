from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

_BACKEND = Path(__file__).resolve().parents[1]
if str(_BACKEND) not in sys.path:
    sys.path.insert(0, str(_BACKEND))

from src.code_tools import write_file


class TestCodeTools(unittest.TestCase):
    def test_write_file_can_create_new_res_path(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            out = write_file(
                "res://systems/horde/new_backend.gd",
                "extends Node\n",
                str(root),
                task_id="unit_test",
                reason="create test file",
            )
            self.assertTrue(out.get("ok"), out)
            created = root / "systems" / "horde" / "new_backend.gd"
            self.assertTrue(created.is_file(), f"Expected created file at {created}")
            self.assertEqual(created.read_text(encoding="utf-8"), "extends Node\n")


if __name__ == "__main__":
    unittest.main()
