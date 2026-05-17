"""Phase 4: Safe file write tools with backup and unified diff.

Design: the AI sends full new file content (not a patch).
The server creates a backup, writes the new content, and returns
the unified diff so the UI can show what changed.

This is more reliable than patch application for an MVP.
"""
from __future__ import annotations

import difflib
import logging
import shutil
import time
from pathlib import Path
from typing import Optional

from .safety import check_path

logger = logging.getLogger(__name__)

MAX_FILE_SIZE_BYTES = 512 * 1024  # 512 KB — refuse to write larger files


def read_file(path: str, project_root: str, start_line: int = 0, end_line: Optional[int] = None) -> dict:
    """Read a file with optional line range. Returns content string."""
    safety = check_path(path, project_root, allow_write=False)
    if not safety["allowed"]:
        return {"ok": False, "error": safety["reason"]}

    abs_path = _resolve(path, project_root)
    if not abs_path.exists():
        return {"ok": False, "error": f"File not found: {path}"}

    try:
        raw = abs_path.read_bytes()
    except OSError as exc:
        return {"ok": False, "error": str(exc)}

    truncated = False
    if len(raw) > MAX_FILE_SIZE_BYTES:
        raw = raw[:MAX_FILE_SIZE_BYTES]
        truncated = True

    text = raw.decode("utf-8", errors="replace")
    lines = text.splitlines(keepends=True)
    total = len(lines)

    if start_line > 0 or end_line is not None:
        sl = max(0, start_line - 1)
        el = end_line if end_line is not None else len(lines)
        lines = lines[sl:el]
        text = "".join(lines)

    return {
        "ok": True,
        "content": text,
        "total_lines": total,
        "truncated": truncated,
        "path": path,
    }


def write_file(
    path: str,
    new_content: str,
    project_root: str,
    task_id: str = "",
    reason: str = "",
) -> dict:
    """
    Write new content to a file, creating a backup first.

    Returns:
        {ok, backup_path, diff_text, lines_added, lines_removed}
    """
    safety = check_path(path, project_root, allow_write=True)
    if not safety["allowed"]:
        return {"ok": False, "error": safety["reason"]}

    abs_path = _resolve(path, project_root)
    if len(new_content.encode("utf-8")) > MAX_FILE_SIZE_BYTES:
        return {"ok": False, "error": f"New content exceeds {MAX_FILE_SIZE_BYTES // 1024} KB limit."}

    existed_before = abs_path.exists()
    # Read original (if present), else treat as create.
    if existed_before:
        try:
            original = abs_path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            return {"ok": False, "error": f"Cannot read original: {exc}"}
    else:
        original = ""

    if original == new_content:
        return {
            "ok": True,
            "backup_path": "",
            "diff_text": "(no changes)",
            "lines_added": 0,
            "lines_removed": 0,
            "message": "File unchanged.",
        }

    # Create backup only for existing files.
    backup_path = ""
    if existed_before:
        backup_path = str(_make_backup(abs_path, project_root, task_id))
    else:
        try:
            abs_path.parent.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            return {"ok": False, "error": f"Cannot create parent folder(s): {exc}"}

    # Write new content
    try:
        abs_path.write_text(new_content, encoding="utf-8")
    except OSError as exc:
        return {"ok": False, "error": f"Cannot write file: {exc}"}

    # Compute diff
    diff_text, added, removed = _compute_diff(original, new_content, path)

    logger.info(
        "Wrote %s (+%d/-%d lines) | task=%s | reason=%s",
        path, added, removed, task_id or "?", reason[:80],
    )

    return {
        "ok": True,
        "path": path,
        "backup_path": backup_path,
        "diff_text": diff_text,
        "lines_added": added,
        "lines_removed": removed,
        "message": ("Created" if not existed_before else "Written") + f": +{added}/-{removed} lines",
    }


def revert_file(path: str, project_root: str, task_id: str = "") -> dict:
    """Restore a file from its backup."""
    abs_path = _resolve(path, project_root)
    backup_path = _get_backup_path(abs_path, project_root, task_id)

    if not backup_path.exists():
        # Try to find any backup for this file
        backup_path = _find_latest_backup(abs_path, project_root)
        if not backup_path:
            return {"ok": False, "error": f"No backup found for {path}"}

    try:
        shutil.copy2(str(backup_path), str(abs_path))
        logger.info("Reverted %s from %s", path, backup_path)
        return {"ok": True, "path": path, "backup_used": str(backup_path)}
    except OSError as exc:
        return {"ok": False, "error": f"Revert failed: {exc}"}


def get_diff(path: str, project_root: str, task_id: str = "") -> dict:
    """Return the diff between current file and its backup."""
    abs_path = _resolve(path, project_root)
    backup_path = _get_backup_path(abs_path, project_root, task_id)

    if not backup_path.exists():
        backup_path = _find_latest_backup(abs_path, project_root)
        if not backup_path:
            return {"ok": False, "error": "No backup to diff against"}

    try:
        original = Path(backup_path).read_text(encoding="utf-8", errors="replace")
        current = abs_path.read_text(encoding="utf-8", errors="replace")
        diff_text, added, removed = _compute_diff(original, current, path)
        return {"ok": True, "diff_text": diff_text, "lines_added": added, "lines_removed": removed}
    except OSError as exc:
        return {"ok": False, "error": str(exc)}


def check_gdscript_syntax(path: str, project_root: str, godot_executable: str = "godot") -> dict:
    """TODO Phase 4+: Run `godot --check-only` on a GDScript file."""
    # This requires knowing the Godot executable path.
    # For now, do a basic bracket/indentation sanity check.
    result = read_file(path, project_root)
    if not result["ok"]:
        return result

    content = result["content"]
    issues: list[str] = []

    for i, line in enumerate(content.splitlines(), 1):
        stripped = line.rstrip()
        # Basic checks
        if stripped.endswith("\\") and not stripped.endswith("\\\\"):
            pass  # line continuation, not an error
        # Unclosed string check (very rough)
        quote_count = stripped.count('"') - stripped.count('\\"')
        if quote_count % 2 != 0 and not stripped.lstrip().startswith("#"):
            issues.append(f"Line {i}: possible unclosed string")

    return {
        "ok": True,
        "path": path,
        "syntax_issues": issues,
        "issue_count": len(issues),
        "note": "Basic check only. Full syntax check requires Godot executable (Phase 5).",
    }


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

def _resolve(path: str, project_root: str) -> Path:
    if path.startswith("res://"):
        rel = path[6:]
        return Path(project_root) / rel
    return Path(path)


def _make_backup(abs_path: Path, project_root: str, task_id: str) -> Path:
    forge_dir = Path(project_root) / ".godot_forge" / "backups"
    sub = task_id if task_id else time.strftime("%Y%m%d_%H%M%S")
    backup_dir = forge_dir / sub
    backup_dir.mkdir(parents=True, exist_ok=True)

    rel = abs_path.relative_to(Path(project_root))
    safe_name = str(rel).replace("/", "__").replace("\\", "__") + ".bak"
    backup_path = backup_dir / safe_name

    shutil.copy2(str(abs_path), str(backup_path))
    logger.debug("Backup created: %s", backup_path)
    return backup_path


def _get_backup_path(abs_path: Path, project_root: str, task_id: str) -> Path:
    forge_dir = Path(project_root) / ".godot_forge" / "backups"
    try:
        rel = abs_path.relative_to(Path(project_root))
    except ValueError:
        rel = Path(abs_path.name)
    safe_name = str(rel).replace("/", "__").replace("\\", "__") + ".bak"
    return forge_dir / task_id / safe_name


def _find_latest_backup(abs_path: Path, project_root: str) -> Optional[Path]:
    forge_dir = Path(project_root) / ".godot_forge" / "backups"
    if not forge_dir.exists():
        return None
    try:
        rel = abs_path.relative_to(Path(project_root))
    except ValueError:
        rel = Path(abs_path.name)
    safe_name = str(rel).replace("/", "__").replace("\\", "__") + ".bak"

    latest = None
    latest_mtime = 0.0
    for sub in forge_dir.iterdir():
        if sub.is_dir():
            candidate = sub / safe_name
            if candidate.exists():
                mtime = candidate.stat().st_mtime
                if mtime > latest_mtime:
                    latest_mtime = mtime
                    latest = candidate
    return latest


def _compute_diff(original: str, modified: str, path: str) -> tuple[str, int, int]:
    orig_lines = original.splitlines(keepends=True)
    mod_lines = modified.splitlines(keepends=True)

    diff = list(difflib.unified_diff(
        orig_lines,
        mod_lines,
        fromfile=path + " (original)",
        tofile=path + " (modified)",
        lineterm="",
    ))

    added = sum(1 for l in diff if l.startswith("+") and not l.startswith("+++"))
    removed = sum(1 for l in diff if l.startswith("-") and not l.startswith("---"))

    return "\n".join(diff), added, removed
