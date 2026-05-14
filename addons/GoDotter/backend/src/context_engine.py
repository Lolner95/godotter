"""Context packing for planner / executor — merges project index + live editor hints.

Keeps prompts informative but bounded; boosts files the user is actually touching.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

# --- Compact index context -------------------------------------------------


def build_compact_context(
    index: dict[str, Any],
    query: str,
    max_files: int = 36,
    plugin_hints: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Rank scenes/scripts by user query + live editor signals; attach index metadata."""
    plugin_hints = plugin_hints or {}
    if not index:
        return _empty_compact_fallback(plugin_hints, max_files)

    query_words = [w.lower() for w in re.split(r"[\s_./,-]+", query) if len(w) > 2]

    hint_paths: list[str] = []
    for key in ("open_scripts", "recent_files", "scene_tree_script_paths"):
        for p in plugin_hints.get(key) or []:
            if isinstance(p, str) and p.startswith("res://"):
                hint_paths.append(p.lower())

    sn = plugin_hints.get("selected_node") or {}
    if isinstance(sn, dict):
        sp = sn.get("script") or ""
        if isinstance(sp, str) and sp.startswith("res://"):
            hint_paths.append(sp.lower())
        for n in plugin_hints.get("selected_nodes") or []:
            if isinstance(n, dict):
                sp2 = n.get("script") or ""
                if isinstance(sp2, str) and sp2.startswith("res://"):
                    hint_paths.append(sp2.lower())

    cur = plugin_hints.get("current_scene") or {}
    if isinstance(cur, dict):
        scp = cur.get("scene_path") or ""
        if isinstance(scp, str) and scp.startswith("res://"):
            hint_paths.append(scp.lower())

    script_by_path = {s["path"]: s for s in index.get("scripts", []) if isinstance(s, dict) and "path" in s}
    scene_by_path = {s["path"]: s for s in index.get("scenes", []) if isinstance(s, dict) and "path" in s}

    all_files: list[tuple[str, str]] = (
        [(s["path"], "scene") for s in index.get("scenes", []) if isinstance(s, dict) and "path" in s]
        + [(s["path"], "script") for s in index.get("scripts", []) if isinstance(s, dict) and "path" in s]
    )

    def score(path: str) -> int:
        p = path.lower()
        s = sum(1 for w in query_words if w in p)
        base = Path(path).stem.lower()
        s += sum(4 for w in query_words if w == base)
        for hp in hint_paths:
            if not hp:
                continue
            if hp == p or hp.endswith(p.split("/")[-1]) or p.endswith(hp.split("/")[-1]):
                s += 10
            elif hp in p or p in hp:
                s += 6
        return s

    scored = sorted(all_files, key=lambda x: score(x[0]), reverse=True)
    ranked_paths = [p for p, _ in scored]

    # Always pin editor-open / selected scripts near the top if present in index
    pinned: list[str] = []
    for hp in hint_paths:
        normalized = hp if hp.startswith("res://") else ""
        if not normalized:
            continue
        for candidate in ranked_paths:
            if candidate.lower() == normalized and candidate not in pinned:
                pinned.append(candidate)
                break

    merged: list[str] = []
    for p in pinned + ranked_paths:
        if p not in merged:
            merged.append(p)
        if len(merged) >= max_files:
            break

    relevant_entries: list[dict[str, Any]] = []
    for p in merged:
        entry: dict[str, Any] = {"path": p, "kind": "file"}
        if p in script_by_path:
            e = script_by_path[p]
            entry["kind"] = "script"
            entry["class_name"] = e.get("class_name", "")
            entry["signals"] = (e.get("signals") or [])[:14]
            entry["exports"] = (e.get("exports") or [])[:24]
        elif p in scene_by_path:
            e = scene_by_path[p]
            entry["kind"] = "scene"
            entry["root_node"] = e.get("root_node", "")
            entry["root_class"] = e.get("root_class", "")
            entry["node_count"] = e.get("node_count", 0)
            entry["attached_scripts"] = (e.get("scripts") or [])[:10]
        relevant_entries.append(entry)

    return {
        "scene_count": index.get("scene_count", 0),
        "script_count": index.get("script_count", 0),
        "resource_count": index.get("resource_count", 0),
        "autoloads": index.get("autoloads", []),
        "addons": index.get("addons", []),
        "relevant_files": merged,
        "relevant_entries": relevant_entries,
        "all_scenes": [s["path"] for s in index.get("scenes", []) if isinstance(s, dict) and "path" in s],
        "all_scripts": [s["path"] for s in index.get("scripts", []) if isinstance(s, dict) and "path" in s],
    }


def _empty_compact_fallback(plugin_hints: dict[str, Any], max_files: int) -> dict[str, Any]:
    paths: list[str] = []
    for key in ("open_scripts", "recent_files", "scene_tree_script_paths"):
        for p in plugin_hints.get(key) or []:
            if isinstance(p, str) and p.startswith("res://") and p not in paths:
                paths.append(p)
            if len(paths) >= max_files:
                break
        if len(paths) >= max_files:
            break
    return {
        "scene_count": 0,
        "script_count": 0,
        "resource_count": 0,
        "autoloads": [],
        "addons": [],
        "relevant_files": paths,
        "relevant_entries": [{"path": p, "kind": "hint"} for p in paths],
        "all_scenes": [],
        "all_scripts": [],
        "index_missing": True,
    }


def format_plugin_hints_block(plugin_ctx: dict[str, Any], max_chars: int = 14000) -> str:
    """Structured dump of live editor context for the architect prompt."""
    if not plugin_ctx:
        return ""

    slim = dict(plugin_ctx)
    previews = slim.pop("script_previews", None)
    lines: list[str] = ["=== LIVE EDITOR CONTEXT ==="]

    proj = slim.get("project_settings") or {}
    if isinstance(proj, dict) and proj.get("name"):
        lines.append(f"Project name: {proj.get('name', '')}")
        lines.append(f"Main scene (project.godot): {proj.get('main_scene', '')}")

    eng = slim.get("engine")
    if isinstance(eng, dict):
        lines.append(
            "Godot engine: "
            + f"{eng.get('string', eng.get('major', '?'))}.{eng.get('minor', '')}.{eng.get('patch', '')}"
        )

    cs = slim.get("current_scene") or {}
    if isinstance(cs, dict) and cs.get("scene_path"):
        lines.append(f"Open in editor scene: {cs.get('scene_path', '')}")
        lines.append(f"  Root: {cs.get('root_node_name', '')} ({cs.get('root_node_class', '')}) "
                       f"children: {cs.get('child_count', 0)}")

    st_scripts = slim.get("scene_tree_script_paths") or []
    if st_scripts:
        lines.append("Scripts attached under current scene tree (sample): " + ", ".join(st_scripts[:16]))

    sns = slim.get("selected_nodes") or []
    if sns:
        lines.append("Multi-selection:")
        for n in sns[:8]:
            if isinstance(n, dict):
                lines.append(f"  - {n.get('path', '')} [{n.get('class', '')}] script={n.get('script', '')}")

    sn = slim.get("selected_node") or {}
    if isinstance(sn, dict) and not sn.get("error"):
        lines.append("Primary selected node (detail):")
        try:
            lines.append(json.dumps(sn, indent=2, default=str)[:6000])
        except Exception:
            lines.append(str(sn)[:6000])

    osrc = slim.get("open_scripts") or []
    if osrc:
        lines.append("Open in script editor: " + ", ".join(str(x) for x in osrc[:12]))

    rf = slim.get("recent_files") or []
    if rf:
        lines.append("Recently touched (heuristic): " + ", ".join(str(x) for x in rf[:16]))

    al = slim.get("autoloads") or []
    if al:
        lines.append("Autoloads: " + ", ".join(
            (a.get("name") if isinstance(a, dict) else str(a)) for a in al[:20]
        ))

    ia = slim.get("input_actions") or []
    if ia:
        lines.append("Input actions (non-ui): " + ", ".join(str(x) for x in ia[:24]))

    godotter = slim.get("godotter") or {}
    if isinstance(godotter, dict):
        completed = godotter.get("completed_tasks") or []
        pending = godotter.get("pending_tasks") or []
        if completed:
            lines.append("Checklist completed by user:")
            for t in completed[:20]:
                lines.append(f"  - {t}")
        if pending:
            lines.append("Checklist still pending:")
            for t in pending[:20]:
                lines.append(f"  - {t}")
        tail = godotter.get("editor_output_tail", "")
        if isinstance(tail, str) and tail.strip():
            lines.append("")
            lines.append("=== RECENT EDITOR / DEBUG OUTPUT (errors, warnings, prints) ===")
            lines.append(tail.strip()[-14000:])

    body = "\n".join(lines)
    if previews and isinstance(previews, dict):
        prev_lines = ["", "=== SCRIPT HEADERS (first lines; same as editor) ==="]
        used = len(body)
        for path, text in previews.items():
            chunk = f"\n--- {path} ---\n{text}\n"
            if used + len(chunk) > max_chars:
                prev_lines.append(f"\n--- {path} ---\n(truncated; budget exhausted)\n")
                break
            prev_lines.append(chunk)
            used += len(chunk)
        body += "\n".join(prev_lines)

    if len(body) > max_chars:
        return body[: max_chars - 40] + "\n…(editor context truncated)…"
    return body
