"""Godot CLI subprocess runner.

Launches:
  godot --path <project_root> [--headless] [scene_path] --quit

Captures stdout/stderr, detects common parse/runtime errors, and reports exit code.
"""
from __future__ import annotations

import os
import re
import subprocess
import glob
from pathlib import Path
from typing import Any


def resolve_godot_executable(hints: dict[str, Any] | None = None) -> str | None:
    """Prefer editor-provided path, then GODOT_PATH, then common install locations."""
    if hints:
        direct = str(hints.get("godot_executable", "") or "").strip()
        if direct and Path(direct).is_file():
            return direct
        godotter = hints.get("godotter") or {}
        if isinstance(godotter, dict):
            from_editor = str(godotter.get("godot_executable", "") or "").strip()
            if from_editor and Path(from_editor).is_file():
                return from_editor
    return find_godot_executable()


def find_godot_executable() -> str | None:
    """Try to find the Godot executable in common locations."""
    env = os.environ.get("GODOT_PATH", "").strip()
    if env:
        p = Path(env)
        if p.is_file():
            return str(p)
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
    for raw in candidates[2:]:
        if "*" in raw:
            # Use glob.glob for absolute wildcard patterns (Path.glob rejects them).
            for m in glob.glob(raw):
                p = Path(m)
                if p.is_file():
                    return str(p)
        else:
            p = Path(raw)
            if p.is_file():
                return str(p)
    return None


def _parse_log_errors(output: str) -> list[str]:
    errs: list[str] = []
    lines = output.splitlines()
    for ln in lines:
        s = ln.strip()
        if not s:
            continue
        if re.search(r"\b(SCRIPT ERROR|Parse Error|ERROR:)\b", s, re.IGNORECASE):
            errs.append(s)
        elif re.search(r"Invalid (call|get index|set index)|Node not found", s, re.IGNORECASE):
            errs.append(s)
    return errs[:120]


def _run_godot(project_root: str, args: list[str], timeout: int = 40) -> dict:
    exe = find_godot_executable()
    if not exe:
        return {"ok": False, "error": "Godot executable not found (set GODOT_PATH).", "output": "", "errors": []}
    cmd = [exe, "--path", project_root] + args + ["--quit"]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        out = (proc.stdout or "") + "\n" + (proc.stderr or "")
        errors = _parse_log_errors(out)
        ok = (proc.returncode == 0) and len(errors) == 0
        return {
            "ok": ok,
            "returncode": proc.returncode,
            "command": cmd,
            "output": out[-16000:],
            "errors": errors,
        }
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or "") + "\n" + (exc.stderr or "")
        return {
            "ok": False,
            "returncode": -1,
            "command": cmd,
            "error": "Godot run timed out",
            "output": out[-16000:],
            "errors": _parse_log_errors(out) or ["Godot run timed out"],
        }
    except Exception as exc:
        return {"ok": False, "returncode": -1, "command": cmd, "error": str(exc), "output": "", "errors": [str(exc)]}


def run_project(
    project_root: str,
    timeout: int = 40,
    *,
    hints: dict[str, Any] | None = None,
) -> dict:
    return _run_godot(project_root, ["--headless"], timeout=timeout, hints=hints)


def run_scene(
    project_root: str,
    scene_path: str,
    timeout: int = 40,
    *,
    hints: dict[str, Any] | None = None,
) -> dict:
    scene = str(scene_path or "").strip()
    if not scene.startswith("res://"):
        return {"ok": False, "error": f"Invalid scene path: {scene_path}", "output": "", "errors": [f"Invalid scene path: {scene_path}"]}
    return _run_godot(project_root, ["--headless", scene], timeout=timeout, hints=hints)
