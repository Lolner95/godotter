"""Integration test: POST /agent/plan with a real tower-placement user goal.

Requires a configured Gemini API key (GEMINI_API_KEY, GOOGLE_API_KEY, or
backend/.godotter_api_key). For local runs, put ``GEMINI_API_KEY`` in
``backend/.env`` (see ``.env.example``); tests load ``.env`` automatically.
Skips automatically when no key is present so CI without secrets still passes.

Run from the backend folder:
    python -m unittest tests.test_plan_towers_integration -v
"""
from __future__ import annotations

import os
import unittest
from pathlib import Path


def _load_backend_dotenv() -> None:
    """Load backend/.env so local unittest picks up GEMINI_API_KEY.

    Uses override=True so values in .env win over stale user/system GEMINI_* variables
    (common on Windows). CI machines typically have no .env file (gitignored).
    """
    try:
        from dotenv import load_dotenv
    except ImportError:
        return
    p = Path(__file__).resolve().parent.parent / ".env"
    if p.is_file():
        load_dotenv(p, override=True)


_load_backend_dotenv()


def _backend_dir() -> Path:
    return Path(__file__).resolve().parent.parent


def _go_dotter_project_root() -> Path:
    """Directory containing project.godot (walks up from this test file)."""
    here = Path(__file__).resolve().parent
    for _ in range(10):
        if (here / "project.godot").is_file():
            return here
        if here.parent == here:
            break
        here = here.parent
    # Fallback: GoDotter dev workspace layout (…/backend/tests → repo root)
    return Path(__file__).resolve().parent.parent.parent.parent.parent


def _api_key_configured() -> bool:
    if (os.environ.get("GEMINI_API_KEY") or "").strip():
        return True
    if (os.environ.get("GOOGLE_API_KEY") or "").strip():
        return True
    keyf = _backend_dir() / ".godotter_api_key"
    try:
        return keyf.is_file() and bool(keyf.read_text(encoding="utf-8").strip())
    except OSError:
        return False


TOWER_USER_REQUEST = (
    "Fix our towers, lets us be able to put it anywhere, also remove the squares "
    "that we used to put them"
)


@unittest.skipUnless(_api_key_configured(), "No Gemini API key (env or .godotter_api_key)")
class TestPlanTowersIntegration(unittest.TestCase):
    def test_plan_returns_for_tower_placement_request(self) -> None:
        from fastapi.testclient import TestClient

        from src.app import app

        project_root = str(_go_dotter_project_root())
        self.assertTrue(
            (Path(project_root) / "project.godot").is_file(),
            f"Expected project.godot under {project_root}",
        )

        payload = {
            "user_request": TOWER_USER_REQUEST,
            "context_bundle": {
                "project_root": project_root,
                "godotter": {"enable_file_edits": False, "approval_mode": "review"},
            },
            "model": "gemini-2.5-flash",
        }

        with TestClient(app) as client:
            response = client.post("/agent/plan", json=payload)

        self.assertEqual(response.status_code, 200, response.text)
        data = response.json()
        if not data.get("ok"):
            err = str(data.get("error", ""))
            if "API key not valid" in err or "API_KEY_INVALID" in err:
                raise unittest.SkipTest(
                    "Gemini rejected the API key (invalid or expired). "
                    "Set GEMINI_API_KEY or fix addons/GoDotter/backend/.godotter_api_key, then re-run."
                )
        self.assertTrue(data.get("ok"), data.get("error") or data)
        self.assertIsNone(data.get("error"), data)
        plan = data.get("plan")
        self.assertIsNotNone(plan, data)
        assert isinstance(plan, dict)
        self.assertTrue(str(plan.get("summary", "")).strip(), "plan.summary should be non-empty")
        steps = plan.get("steps") or []
        self.assertGreater(len(steps), 0, "plan should include at least one step")


if __name__ == "__main__":
    unittest.main()
