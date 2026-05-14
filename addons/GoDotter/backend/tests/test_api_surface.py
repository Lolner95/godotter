"""API surface and mode smoke tests for GoDotter backend.

These tests validate that endpoints used by the Godot plugin exist and return
structured responses (not 404), even when external dependencies are unavailable.
"""
from __future__ import annotations

import unittest
from pathlib import Path

from fastapi.testclient import TestClient

from src.app import app


def _project_root() -> str:
    here = Path(__file__).resolve().parent
    for _ in range(10):
        if (here / "project.godot").is_file():
            return str(here)
        if here.parent == here:
            break
        here = here.parent
    return str(Path(__file__).resolve().parents[4])


class TestApiSurface(unittest.TestCase):
    def test_openapi_contains_core_routes(self) -> None:
        expected = {
            "/health",
            "/ai/capabilities",
            "/ai/test_model_settings",
            "/project/index",
            "/project/context",
            "/agent/plan",
            "/agent/run",
            "/agent/execute",
            "/agent/fix_from_logs",
            "/agent/visual_map",
            "/memory",
        }
        with TestClient(app) as client:
            r = client.get("/openapi.json")
        self.assertEqual(r.status_code, 200, r.text)
        data = r.json()
        paths = set((data.get("paths") or {}).keys())
        missing = sorted(expected - paths)
        self.assertEqual(missing, [], f"Missing core routes in OpenAPI: {missing}")

    def test_health_shape(self) -> None:
        with TestClient(app) as client:
            r = client.get("/health")
        self.assertEqual(r.status_code, 200, r.text)
        d = r.json()
        self.assertEqual(d.get("status"), "ok")
        self.assertTrue(str(d.get("version", "")).strip())
        self.assertIn("api_key_present", d)

    def test_agent_plan_route_exists(self) -> None:
        payload = {
            "user_request": "Small planning smoke test",
            "context_bundle": {
                "project_root": _project_root(),
                "godotter": {
                    "chat_images": [
                        {
                            "name": "tiny.png",
                            "mime_type": "image/png",
                            "base64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO8fNqkAAAAASUVORK5CYII=",
                        }
                    ]
                },
            },
            "model": "",
        }
        with TestClient(app) as client:
            r = client.post("/agent/plan", json=payload)
        self.assertEqual(r.status_code, 200, r.text)
        d = r.json()
        self.assertIn("ok", d)

    def test_ai_capabilities_route_exists(self) -> None:
        with TestClient(app) as client:
            r = client.get("/ai/capabilities")
        self.assertEqual(r.status_code, 200, r.text)
        d = r.json()
        self.assertTrue(d.get("ok"))
        self.assertIn("registry", d)

    def test_ai_test_route_exists(self) -> None:
        payload = {
            "context_bundle": {
                "godotter": {
                    "ai_settings": {
                        "provider": "gemini",
                        "model": "gemini-3.1-pro-preview",
                        "preset": "Deep",
                    }
                }
            },
            "prompt": "Quick coding smoke test",
        }
        with TestClient(app) as client:
            r = client.post("/ai/test_model_settings", json=payload)
        self.assertEqual(r.status_code, 200, r.text)
        d = r.json()
        self.assertIn("ok", d)
        self.assertIn("provider", d)

    def test_ai_test_openai_mock_path(self) -> None:
        payload = {
            "context_bundle": {
                "godotter": {
                    "ai_settings": {
                        "provider": "openai",
                        "model": "gpt-5",
                        "preset": "Deep",
                    }
                }
            },
            "prompt": "Tiny coding smoke prompt",
        }
        with TestClient(app) as client:
            r = client.post("/ai/test_model_settings", json=payload)
        self.assertEqual(r.status_code, 200, r.text)
        d = r.json()
        self.assertTrue(d.get("ok"))
        self.assertEqual(d.get("provider"), "openai")
        self.assertTrue(d.get("mocked"))
        # Must never be route missing.
        self.assertNotEqual(str(d.get("error", "")), "Not Found")

    def test_agent_run_route_exists(self) -> None:
        payload = {
            "user_request": "Run-mode smoke test",
            "context_bundle": {"project_root": _project_root()},
            "auto_execute": False,
            "max_plan_repairs": 0,
        }
        with TestClient(app) as client:
            r = client.post("/agent/run", json=payload)
        self.assertEqual(r.status_code, 200, r.text)
        d = r.json()
        self.assertIn("ok", d)
        self.assertIn("phases", d)

    def test_execute_route_exists(self) -> None:
        payload = {
            "user_request": "Execute smoke test",
            "context_bundle": {"project_root": _project_root()},
            "approved": False,
        }
        with TestClient(app) as client:
            r = client.post("/agent/execute", json=payload)
        self.assertEqual(r.status_code, 200, r.text)
        d = r.json()
        self.assertIn("ok", d)

    def test_fix_logs_route_exists(self) -> None:
        payload = {"run_id": "", "log_text": "E 0:00:00 some error", "model": ""}
        with TestClient(app) as client:
            r = client.post("/agent/fix_from_logs", json=payload)
        self.assertEqual(r.status_code, 200, r.text)
        d = r.json()
        self.assertIn("ok", d)

    def test_memory_route_exists(self) -> None:
        with TestClient(app) as client:
            r = client.get("/memory")
        self.assertEqual(r.status_code, 200, r.text)
        d = r.json()
        self.assertIn("ok", d)


if __name__ == "__main__":
    unittest.main()
