from __future__ import annotations

import sys
import unittest
from pathlib import Path

_BACKEND = Path(__file__).resolve().parents[1]
if str(_BACKEND) not in sys.path:
    sys.path.insert(0, str(_BACKEND))

from src.godot_cli import _parse_log_errors


class TestGodotCli(unittest.TestCase):
    def test_parse_log_errors_detects_common_error_lines(self) -> None:
        sample = """
Godot Engine v4
SCRIPT ERROR: Parse Error: Unexpected indentation.
   at: res://scripts/board/GameplayBoard.gd:71
ERROR: Failed to load script "res://scripts/board/GameplayBoard.gd" with error "Parse error".
"""
        errs = _parse_log_errors(sample)
        self.assertTrue(any("SCRIPT ERROR" in e for e in errs), errs)
        self.assertTrue(any("ERROR:" in e for e in errs), errs)

    def test_glob_absolute_patterns_do_not_raise(self) -> None:
        # Regression: absolute wildcard patterns previously crashed with
        # "Non-relative patterns are unsupported" when using Path.glob.
        from src.godot_cli import find_godot_executable

        # Should return either an executable path or None, but never raise.
        _ = find_godot_executable()


if __name__ == "__main__":
    unittest.main()
