"""Project indexer — walks a Godot 4 project filesystem and produces
a structured project_index.json in .godot_forge/index/.

Mirrors ProjectScanner.gd but richer: runs on the backend where
Python string processing is fast and no Godot API limit applies.
"""
from __future__ import annotations

import json
import logging
import os
import re
import time
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

SCENE_EXT = {".tscn"}
SCRIPT_EXT = {".gd"}
RESOURCE_EXT = {".tres", ".res"}
TEXTURE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".svg", ".bmp", ".dds", ".exr"}
AUDIO_EXT = {".ogg", ".wav", ".mp3"}
SHADER_EXT = {".gdshader", ".glsl"}
THEME_EXT = {".theme"}
FONT_EXT = {".ttf", ".otf", ".fnt"}

SKIP_DIRS = {".godot", ".git", "__pycache__", ".venv", "venv", ".godot_forge"}


def index_project(project_root: str) -> dict[str, Any]:
    """Scan a Godot project and return a rich index dictionary."""
    root = Path(project_root).resolve()
    if not root.exists():
        return {"error": f"Project root not found: {project_root}"}

    index: dict[str, Any] = {
        "project_path": str(root),
        "scanned_at": time.time(),
        "scenes": [],
        "scripts": [],
        "resources": [],
        "textures": [],
        "audio": [],
        "shaders": [],
        "themes": [],
        "fonts": [],
        "autoloads": [],
        "input_actions": [],
        "addons": [],
        "scene_count": 0,
        "script_count": 0,
        "resource_count": 0,
        "texture_count": 0,
        "audio_count": 0,
        "errors": [],
    }

    _walk(root, root, index)
    _parse_project_godot(root, index)

    index["scene_count"] = len(index["scenes"])
    index["script_count"] = len(index["scripts"])
    index["resource_count"] = len(index["resources"])
    index["texture_count"] = len(index["textures"])
    index["audio_count"] = len(index["audio"])

    _save_index(root, index)
    logger.info(
        "Indexed %s: %d scenes, %d scripts, %d resources",
        root.name,
        index["scene_count"],
        index["script_count"],
        index["resource_count"],
    )
    return index


def _walk(root: Path, current: Path, index: dict) -> None:
    try:
        entries = sorted(current.iterdir())
    except PermissionError:
        return

    for entry in entries:
        if entry.name.startswith(".") or entry.name in SKIP_DIRS:
            continue

        if entry.is_dir():
            if entry.name == "addons":
                _scan_addons(entry, index)
            else:
                _walk(root, entry, index)
        elif entry.is_file():
            _classify(root, entry, index)


def _classify(root: Path, path: Path, index: dict) -> None:
    ext = path.suffix.lower()
    rel = _res_path(root, path)

    if ext in SCENE_EXT:
        entry = _file_entry(rel, path)
        entry.update(_parse_scene_shallow(path))
        index["scenes"].append(entry)

    elif ext in SCRIPT_EXT:
        entry = _file_entry(rel, path)
        entry.update(_parse_script_shallow(path))
        index["scripts"].append(entry)

    elif ext in RESOURCE_EXT:
        index["resources"].append(_file_entry(rel, path))

    elif ext in TEXTURE_EXT:
        index["textures"].append(_file_entry(rel, path))

    elif ext in AUDIO_EXT:
        index["audio"].append(_file_entry(rel, path))

    elif ext in SHADER_EXT:
        index["shaders"].append(_file_entry(rel, path))

    elif ext in THEME_EXT:
        index["themes"].append(_file_entry(rel, path))

    elif ext in FONT_EXT:
        index["fonts"].append(_file_entry(rel, path))


def _file_entry(res_path: str, path: Path) -> dict:
    try:
        size = path.stat().st_size
    except OSError:
        size = 0
    return {"path": res_path, "name": path.name, "size": size}


def _res_path(root: Path, path: Path) -> str:
    try:
        rel = path.relative_to(root)
        return "res://" + str(rel).replace("\\", "/")
    except ValueError:
        return str(path)


def _parse_scene_shallow(path: Path) -> dict:
    """Extract node count, root node name/class, and referenced scripts from a .tscn file."""
    result = {"node_count": 0, "root_node": "", "root_class": "", "scripts": [], "missing_resources": []}
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return result

    node_count = 0
    root_found = False
    scripts: set[str] = set()

    for line in text.splitlines():
        if line.startswith("[node "):
            node_count += 1
            if not root_found:
                m = re.search(r'name="([^"]+)"', line)
                t = re.search(r'type="([^"]+)"', line)
                if m:
                    result["root_node"] = m.group(1)
                if t:
                    result["root_class"] = t.group(1)
                root_found = True
        elif line.startswith("[ext_resource ") and 'type="Script"' in line:
            m = re.search(r'path="([^"]+)"', line)
            if m:
                scripts.add(m.group(1))

    result["node_count"] = node_count
    result["scripts"] = list(scripts)
    return result


def _parse_script_shallow(path: Path) -> dict:
    """Extract class_name, signals, and exported variable names from a .gd file."""
    result = {"class_name": "", "signals": [], "exports": []}
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return result

    for line in text.splitlines()[:120]:  # scan enough of file for signals/exports
        stripped = line.strip()
        if stripped.startswith("class_name "):
            result["class_name"] = stripped[11:].split()[0].rstrip(":")
        elif stripped.startswith("signal "):
            m = re.match(r"signal (\w+)", stripped)
            if m:
                result["signals"].append(m.group(1))
        elif stripped.startswith("@export") or stripped.startswith("export"):
            m = re.search(r"var (\w+)", stripped)
            if m:
                result["exports"].append(m.group(1))

    return result


def _scan_addons(addons_dir: Path, index: dict) -> None:
    try:
        for entry in sorted(addons_dir.iterdir()):
            if entry.is_dir() and not entry.name.startswith("."):
                index["addons"].append(entry.name)
    except PermissionError:
        pass


def _parse_project_godot(root: Path, index: dict) -> None:
    """Parse project.godot to extract autoloads and input actions."""
    project_file = root / "project.godot"
    if not project_file.exists():
        return

    try:
        text = project_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return

    in_autoload = False
    in_input = False

    for line in text.splitlines():
        line = line.strip()

        if line == "[autoload]":
            in_autoload = True
            in_input = False
            continue
        elif line == "[input]":
            in_input = True
            in_autoload = False
            continue
        elif line.startswith("[") and line.endswith("]"):
            in_autoload = False
            in_input = False
            continue

        if in_autoload and "=" in line:
            parts = line.split("=", 1)
            name = parts[0].strip()
            val = parts[1].strip().strip('"').lstrip("*")
            index["autoloads"].append({"name": name, "path": val})

        if in_input and "={" in line:
            action = line.split("=")[0].strip()
            if not action.startswith("ui_"):
                index["input_actions"].append(action)


def _save_index(root: Path, index: dict) -> None:
    forge_dir = root / ".godot_forge" / "index"
    forge_dir.mkdir(parents=True, exist_ok=True)
    out_path = forge_dir / "project_index.json"
    try:
        out_path.write_text(json.dumps(index, indent=2), encoding="utf-8")
        logger.info("Saved index to %s", out_path)
    except OSError as exc:
        logger.error("Could not save index: %s", exc)


def load_index(project_root: str) -> dict[str, Any]:
    """Load the most recently saved project index, or return empty dict."""
    path = Path(project_root) / ".godot_forge" / "index" / "project_index.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        logger.error("Failed to load index: %s", exc)
        return {}


# Re-export — implementation lives in context_engine (ranking + editor hints).
from .context_engine import build_compact_context  # noqa: E402,F401
