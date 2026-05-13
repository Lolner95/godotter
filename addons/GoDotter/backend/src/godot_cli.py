"""TODO Phase 5: Godot CLI subprocess runner.

Launches:
  godot --path <project_root> [scene_path] --quit-after <N>

Captures stdout/stderr, detects errors, and reports exit code.
"""
import subprocess
from pathlib import Path


def find_godot_executable() -> str | None:
    """Try to find the Godot executable in common locations."""
    candidates = [
        "godot",
        "godot4",
        r"C:\Program Files\Godot\Godot_v4*\Godot*.exe",
        r"/usr/local/bin/godot",
        r"/Applications/Godot.app/Contents/MacOS/Godot",
    ]
    import shutil
    for c in candidates[:2]:
        if shutil.which(c):
            return c
    return None


def run_project(project_root: str, timeout: int = 30) -> dict:
    raise NotImplementedError("run_project — Phase 5")


def run_scene(project_root: str, scene_path: str, timeout: int = 30) -> dict:
    raise NotImplementedError("run_scene — Phase 5")
