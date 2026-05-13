"""Static validators for plans, paths, and post-edit GDScript / scene files.

Used by the autonomous agent runner to gate execute and to collect repair hints.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from typing import Any

from .code_tools import read_file
from .schemas import Plan
from .safety import check_path


def collect_index_paths(index: dict[str, Any]) -> set[str]:
    out: set[str] = set()
    if not index:
        return out
    for key in ("scenes", "scripts", "resources", "shaders"):
        for e in index.get(key) or []:
            if isinstance(e, dict):
                p = e.get("path")
                if isinstance(p, str) and p.startswith("res://"):
                    out.add(p)
    return out


def collect_hint_paths(hints: dict[str, Any]) -> set[str]:
    out: set[str] = set()
    if not hints:
        return out
    for key in ("open_scripts", "recent_files", "scene_tree_script_paths"):
        for p in hints.get(key) or []:
            if isinstance(p, str) and p.startswith("res://"):
                out.add(p)
    sn = hints.get("selected_node") or {}
    if isinstance(sn, dict):
        sp = sn.get("script") or ""
        if isinstance(sp, str) and sp.startswith("res://"):
            out.add(sp)
    for n in hints.get("selected_nodes") or []:
        if isinstance(n, dict):
            sp2 = n.get("script") or ""
            if isinstance(sp2, str) and sp2.startswith("res://"):
                out.add(sp2)
    cur = hints.get("current_scene") or {}
    if isinstance(cur, dict):
        scp = cur.get("scene_path") or ""
        if isinstance(scp, str) and scp.startswith("res://"):
            out.add(scp)
    return out


def validate_plan_paths(plan: Plan, index: dict[str, Any], hints: dict[str, Any]) -> list[str]:
    """Ensure every path in the plan is known (index or live editor hints)."""
    errs: list[str] = []
    index_paths = collect_index_paths(index)
    hint_paths = collect_hint_paths(hints)
    allowed = index_paths | hint_paths
    index_missing = not index_paths

    def check_one(label: str, p: str) -> None:
        ok, reason = path_allowed_for_plan(p, allowed, index_missing)
        if not ok:
            errs.append(f"{label}: {p!r} — {reason}")

    for p in plan.relevant_files:
        check_one("relevant_files", p)
    for p in plan.relevant_scenes:
        check_one("relevant_scenes", p)

    for step in plan.steps:
        for fp in step.files_affected:
            check_one(f"step {step.step_number} files_affected", fp)

    if not plan.relevant_files and not plan.relevant_scenes:
        errs.append("Plan has no relevant_files or relevant_scenes — cannot execute safely.")

    return errs


def path_allowed_for_plan(path: str, allowed: set[str], index_missing: bool) -> tuple[bool, str]:
    if not isinstance(path, str) or not path.startswith("res://"):
        return False, "invalid path"
    norm = path.replace("\\", "/")
    if "/addons/" in norm:
        return False, "editing addons is blocked"
    if path in allowed:
        return True, ""
    if index_missing:
        return True, ""
    return False, "not in project index or editor hints (run Index Project)"


def _balance_symbol_lines(content: str, open_ch: str, close_ch: str) -> int:
    """Ignore # comments; rough balance for GDScript."""
    depth = 0
    for line in content.splitlines():
        code = line.split("#", 1)[0]
        depth += code.count(open_ch) - code.count(close_ch)
        if depth < 0:
            return -1
    return depth


def validate_gdscript_heuristic(content: str, path: str = "") -> list[str]:
    """Fast static checks (not a full parser)."""
    issues: list[str] = []
    if not content.strip():
        issues.append(f"{path}: empty file")
        return issues

    for pair in (("(", ")"), ("[", "]"), ("{", "}")):
        b = _balance_symbol_lines(content, pair[0], pair[1])
        if b != 0:
            issues.append(f"{path}: unbalanced {pair[0]}{pair[1]} (net {b})")

    return issues[:25]


def validate_tscn_heuristic(content: str, path: str = "") -> list[str]:
    issues: list[str] = []
    if "[gd_scene" not in content[:500]:
        issues.append(f"{path}: does not look like a .tscn (missing [gd_scene)")
    if content.count("[node ") == 0 and "[gd_scene" in content:
        issues.append(f"{path}: no [node entries found")
    return issues


def validate_file_after_write(path: str, project_root: str) -> dict[str, Any]:
    """Read back file and run extension-specific validators."""
    r = read_file(path, project_root)
    if not r["ok"]:
        return {"path": path, "ok": False, "errors": [r.get("error", "read failed")]}
    content = r.get("content", "")
    ext = Path(path).suffix.lower()
    errs: list[str] = []
    if ext == ".gd":
        errs.extend(validate_gdscript_heuristic(content, path))
    elif ext == ".tscn":
        errs.extend(validate_tscn_heuristic(content, path))
    return {"path": path, "ok": len(errs) == 0, "errors": errs}


def try_godot_script_check(path: str, project_root: str) -> dict[str, Any]:
    """If GODOT_PATH is set, run `Godot --headless --check-only` (Godot 4.3+)."""
    exe = os.environ.get("GODOT_PATH", "").strip()
    if not exe:
        return {"skipped": True, "note": "Set GODOT_PATH to enable Godot binary syntax check."}
    abs_proj = str(Path(project_root).resolve())
    abs_file = str(Path(path).resolve()) if not path.startswith("res://") else ""
    if path.startswith("res://"):
        try:
            rel = path.replace("res://", "").replace("/", os.sep)
            abs_file = str((Path(project_root) / rel).resolve())
        except Exception as exc:
            return {"ok": False, "error": str(exc)}
    try:
        proc = subprocess.run(
            [exe, "--path", abs_proj, "--headless", "--check-only", abs_file],
            capture_output=True,
            text=True,
            timeout=120,
        )
        ok = proc.returncode == 0
        return {
            "ok": ok,
            "returncode": proc.returncode,
            "stdout": (proc.stdout or "")[-2000:],
            "stderr": (proc.stderr or "")[-2000:],
        }
    except FileNotFoundError:
        return {"ok": False, "error": f"GODOT_PATH executable not found: {exe}"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Godot check timed out"}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def validate_execute_paths_before_write(
    edits: list[dict[str, Any]],
    project_root: str,
) -> list[str]:
    """Ensure each edit path passes safety + exists (MVP: no new file creation)."""
    errs: list[str] = []
    for ed in edits:
        path = ed.get("path", "")
        if not path:
            errs.append("Edit missing path")
            continue
        s = check_path(path, project_root, allow_write=True)
        if not s["allowed"]:
            errs.append(f"{path}: {s['reason']}")
    return errs
