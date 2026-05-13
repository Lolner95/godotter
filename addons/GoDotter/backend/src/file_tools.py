"""Safe file read and list operations for the backend.

All paths are validated through safety.py before access.
Write operations are Phase 4+ — stubs raise NotImplementedError for now.
"""
from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Optional

from .safety import check_path

logger = logging.getLogger(__name__)

MAX_READ_BYTES = 256 * 1024  # 256 KB — cap to avoid huge Gemini context


def read_file(path: str, project_root: str, start_line: int = 0, end_line: Optional[int] = None) -> dict:
    """
    Read a file safely, returning its content with optional line range.

    Returns:
        {"ok": True, "content": str, "lines": int, "truncated": bool}
        or {"ok": False, "error": str}
    """
    safety = check_path(path, project_root, allow_write=False)
    if not safety["allowed"]:
        return {"ok": False, "error": safety["reason"]}

    try:
        raw = Path(path).read_bytes()
    except OSError as exc:
        return {"ok": False, "error": str(exc)}

    truncated = False
    if len(raw) > MAX_READ_BYTES:
        raw = raw[:MAX_READ_BYTES]
        truncated = True

    try:
        text = raw.decode("utf-8", errors="replace")
    except Exception as exc:
        return {"ok": False, "error": f"Decode error: {exc}"}

    lines = text.splitlines()
    total_lines = len(lines)

    if start_line > 0 or end_line is not None:
        sl = max(0, start_line - 1)
        el = end_line if end_line is not None else len(lines)
        lines = lines[sl:el]
        text = "\n".join(lines)

    return {
        "ok": True,
        "content": text,
        "lines": total_lines,
        "truncated": truncated,
        "path": path,
    }


def list_files(project_root: str, glob_pattern: str = "**/*.gd") -> dict:
    """List files matching a glob pattern inside the project root."""
    root = Path(project_root)
    if not root.exists():
        return {"ok": False, "error": f"Project root not found: {project_root}"}

    try:
        matches = [
            "res://" + str(p.relative_to(root)).replace("\\", "/")
            for p in root.glob(glob_pattern)
            if not any(skip in str(p) for skip in [".godot", "__pycache__", ".venv"])
        ]
        return {"ok": True, "files": sorted(matches), "count": len(matches)}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def search_text(query: str, project_root: str, glob_pattern: str = "**/*.gd") -> dict:
    """Search for a text string in files matching glob."""
    root = Path(project_root)
    results: list[dict] = []
    query_lower = query.lower()

    for path in root.glob(glob_pattern):
        if any(skip in str(path) for skip in [".godot", "__pycache__", ".venv"]):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
            for i, line in enumerate(text.splitlines(), 1):
                if query_lower in line.lower():
                    results.append({
                        "path": "res://" + str(path.relative_to(root)).replace("\\", "/"),
                        "line": i,
                        "content": line.strip(),
                    })
                    if len(results) >= 100:
                        return {"ok": True, "results": results, "truncated": True}
        except OSError:
            continue

    return {"ok": True, "results": results, "truncated": False}


def search_text(query: str, project_root: str, glob_pattern: str = "**/*.gd") -> dict:
    """Simple text search across project files matching a glob pattern."""
    import fnmatch
    results = []
    root = Path(project_root)
    try:
        for file_path in root.rglob("*"):
            if file_path.is_file():
                rel = str(file_path.relative_to(root)).replace("\\", "/")
                if not fnmatch.fnmatch(rel, glob_pattern):
                    continue
                try:
                    text = file_path.read_text(encoding="utf-8", errors="replace")
                    for i, line in enumerate(text.splitlines(), 1):
                        if query.lower() in line.lower():
                            results.append({
                                "path": "res://" + rel,
                                "line": i,
                                "content": line.strip()[:200],
                            })
                            if len(results) >= 50:
                                return {"ok": True, "results": results, "truncated": True}
                except OSError:
                    continue
    except Exception as exc:
        return {"ok": False, "error": str(exc)}
    return {"ok": True, "results": results, "truncated": False}


# --- Phase 4: Delegated to code_tools.py ---
# write_file, revert_file, patch_file are now in code_tools.py.
