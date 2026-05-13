"""Phase 4: Git integration for checkpoints, diffs, and reverts.

All operations use subprocess to call git. If git is not available or
the project is not a git repo, operations fail gracefully with a clear message.
"""
from __future__ import annotations

import logging
import subprocess
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


def _run_git(args: list[str], cwd: str) -> dict:
    """Run a git command and return {ok, stdout, stderr, returncode}."""
    try:
        result = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return {
            "ok": result.returncode == 0,
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
            "returncode": result.returncode,
        }
    except FileNotFoundError:
        return {"ok": False, "error": "git not found. Install git or use file backups instead."}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "git command timed out"}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def is_git_repo(project_root: str) -> bool:
    result = _run_git(["rev-parse", "--git-dir"], project_root)
    return result.get("ok", False)


def get_status(project_root: str) -> dict:
    if not is_git_repo(project_root):
        return {"ok": False, "error": "Not a git repository", "files": []}
    result = _run_git(["status", "--porcelain"], project_root)
    if not result["ok"]:
        return result
    files = []
    for line in result["stdout"].splitlines():
        if len(line) >= 2:
            status = line[:2].strip()
            path = line[3:].strip()
            files.append({"status": status, "path": path})
    return {"ok": True, "files": files, "raw": result["stdout"]}


def get_diff(project_root: str, path: Optional[str] = None) -> dict:
    """Get unified diff of current changes."""
    if not is_git_repo(project_root):
        return {"ok": False, "error": "Not a git repository"}
    args = ["diff", "--unified=3"]
    if path:
        args.append("--")
        args.append(path)
    result = _run_git(args, project_root)
    return {
        "ok": result.get("ok", False),
        "diff_text": result.get("stdout", ""),
        "error": result.get("error") or (result.get("stderr") if not result.get("ok") else None),
    }


def create_checkpoint(project_root: str, message: str = "GoDotter checkpoint") -> dict:
    """
    Create a git checkpoint before making changes.
    Stages all changes and creates a WIP commit, or stashes if clean.
    Returns the commit hash if successful.
    """
    if not is_git_repo(project_root):
        return {
            "ok": False,
            "error": "Not a git repository. Using file backups instead.",
            "fallback": "backup",
        }

    # Check if there are any changes to commit
    status = get_status(project_root)
    if not status["ok"]:
        return status

    if not status["files"]:
        # Nothing to checkpoint — record current HEAD
        head = _run_git(["rev-parse", "HEAD"], project_root)
        return {
            "ok": True,
            "commit_hash": head.get("stdout", ""),
            "message": "No changes to checkpoint. HEAD recorded.",
            "type": "clean",
        }

    # Stage all changes
    stage = _run_git(["add", "-A"], project_root)
    if not stage["ok"]:
        return {"ok": False, "error": "git add failed: " + stage.get("stderr", "")}

    # Create checkpoint commit
    commit = _run_git(
        ["commit", "-m", f"[GoDotter] {message}"],
        project_root,
    )
    if not commit["ok"]:
        # Try to unstage
        _run_git(["reset", "HEAD"], project_root)
        return {"ok": False, "error": "git commit failed: " + commit.get("stderr", "")}

    head = _run_git(["rev-parse", "HEAD"], project_root)
    logger.info("Git checkpoint created: %s", head.get("stdout", "")[:8])

    return {
        "ok": True,
        "commit_hash": head.get("stdout", ""),
        "message": f"Checkpoint created: {message}",
        "type": "commit",
    }


def revert_file(path: str, project_root: str) -> dict:
    """Revert a single file to HEAD using git checkout."""
    if not is_git_repo(project_root):
        return {"ok": False, "error": "Not a git repository"}
    result = _run_git(["checkout", "HEAD", "--", path], project_root)
    if result["ok"]:
        logger.info("Git reverted: %s", path)
    return {
        "ok": result["ok"],
        "path": path,
        "error": result.get("stderr") if not result["ok"] else None,
    }


def revert_to_checkpoint(commit_hash: str, project_root: str) -> dict:
    """Revert to a specific checkpoint commit (soft reset)."""
    if not is_git_repo(project_root):
        return {"ok": False, "error": "Not a git repository"}
    result = _run_git(["reset", "--soft", commit_hash + "^"], project_root)
    return {
        "ok": result["ok"],
        "error": result.get("stderr") if not result["ok"] else None,
    }


def get_log(project_root: str, max_count: int = 10) -> dict:
    """Get recent git log."""
    if not is_git_repo(project_root):
        return {"ok": False, "error": "Not a git repository", "commits": []}
    result = _run_git(
        ["log", f"--max-count={max_count}", "--oneline", "--no-walk"],
        project_root,
    )
    commits = []
    for line in result.get("stdout", "").splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            commits.append({"hash": parts[0], "message": parts[1]})
    return {"ok": True, "commits": commits}
