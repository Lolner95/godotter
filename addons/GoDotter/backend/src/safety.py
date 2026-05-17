"""Safety gate for all file system and OS operations.

Every destructive or sensitive operation must pass through this module.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Optional


DANGEROUS_PATH_PATTERNS = [
    ".godot/",
    "/.godot/",
    "project.godot",
    ".import",
    "addons/",
    "/addons/",
    ".godot_forge/",
]

DANGEROUS_OPERATIONS = {
    "delete_file",
    "rename_folder",
    "modify_addon",
    "modify_project_godot",
    "modify_import",
    "run_shell_command",
    "install_dependency",
    "change_git_branch",
    "reset_git",
    "revert_many_files",
}

# Extensions that should never be modified by the agent
PROTECTED_EXTENSIONS = {".import", ".godot"}


def check_path(path: str, project_root: str, allow_write: bool = False) -> dict:
    """
    Check if a file path is safe to access.

    Returns:
        {"allowed": bool, "reason": str}
    """
    norm = path.replace("\\", "/")

    # Must be inside project root
    try:
        root_resolved = Path(project_root).resolve()
        if path.startswith("res://"):
            resolved = (root_resolved / path[6:]).resolve()
        else:
            resolved = Path(path).resolve()
        resolved.relative_to(root_resolved)
    except ValueError:
        return {"allowed": False, "reason": f"Path is outside project root: {path}"}

    # Check dangerous patterns
    for pattern in DANGEROUS_PATH_PATTERNS:
        if pattern in norm:
            return {
                "allowed": False,
                "reason": f"Path matches protected pattern '{pattern}': {path}",
            }

    # Check protected extensions
    ext = Path(path).suffix.lower()
    if allow_write and ext in PROTECTED_EXTENSIONS:
        return {
            "allowed": False,
            "reason": f"Extension '{ext}' is protected from writes: {path}",
        }

    return {"allowed": True, "reason": "ok"}


def check_operation(operation: str, yolo_mode: bool = False) -> dict:
    """Check if a named dangerous operation is permitted."""
    if operation in DANGEROUS_OPERATIONS:
        if yolo_mode:
            return {
                "allowed": True,
                "reason": "YOLO mode: dangerous operation permitted.",
                "warning": f"YOLO mode active — dangerous op '{operation}' allowed.",
            }
        return {
            "allowed": False,
            "reason": f"Dangerous operation '{operation}' requires explicit user approval.",
        }
    return {"allowed": True, "reason": "ok"}


def is_safe_read(path: str, project_root: str) -> bool:
    """Quick check: is reading this path safe?"""
    return check_path(path, project_root, allow_write=False)["allowed"]


def is_safe_write(path: str, project_root: str) -> bool:
    """Quick check: is writing to this path safe?"""
    return check_path(path, project_root, allow_write=True)["allowed"]
