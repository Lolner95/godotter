from __future__ import annotations

import unittest

from src.ai_model_settings import (
    resolve_ai_settings,
    validate_resolved_ai_settings,
)


class TestAiModelSettings(unittest.TestCase):
    def test_gemini31_deep_uses_high_thinking_level(self) -> None:
        resolved = resolve_ai_settings(
            {
                "provider": "gemini",
                "model": "gemini-3.1-pro-preview",
                "preset": "Deep",
            }
        )
        self.assertEqual(resolved["active"].get("thinking_level"), "HIGH")
        self.assertNotIn("thinking_budget", resolved["active"])
        self.assertEqual(validate_resolved_ai_settings(resolved), [])

    def test_gemini31_fast_uses_low_thinking_level(self) -> None:
        resolved = resolve_ai_settings(
            {
                "provider": "gemini",
                "model": "gemini-3.1-pro-preview",
                "preset": "Fast",
            }
        )
        self.assertEqual(resolved["active"].get("thinking_level"), "LOW")
        self.assertEqual(validate_resolved_ai_settings(resolved), [])

    def test_gemini25_uses_thinking_budget(self) -> None:
        resolved = resolve_ai_settings(
            {
                "provider": "gemini",
                "model": "gemini-2.5-flash",
                "preset": "Balanced",
            }
        )
        self.assertIn("thinking_budget", resolved["active"])
        self.assertNotIn("thinking_level", resolved["active"])
        self.assertEqual(validate_resolved_ai_settings(resolved), [])

    def test_forbidden_combo_caught(self) -> None:
        resolved = resolve_ai_settings(
            {"provider": "gemini", "model": "gemini-2.5-pro", "preset": "Deep"}
        )
        resolved["active"]["thinking_level"] = "HIGH"
        resolved["active"]["thinking_budget"] = 2048
        errs = validate_resolved_ai_settings(resolved)
        self.assertTrue(any("forbidden combination" in e for e in errs))


if __name__ == "__main__":
    unittest.main()
