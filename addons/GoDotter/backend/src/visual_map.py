"""Visual Map analysis — neon debug screenshot + node map → spatial understanding.

The plugin applies a distinct neon color to every scene node by type,
captures a screenshot, and sends it here along with a JSON node map.

Gemini sees:
1. The neon screenshot (visual spatial layout)
2. The color legend (what each color means)
3. The node map (name, path, class, screen position for each colored node)

It can then answer questions like:
- "What is at screen position (200, 400)?"
- "Which nodes are overlapping?"
- "Is the CardView covering the HealthBar?"
- "What z-index ordering issue causes X?"
- "Which nodes are invisible?"
- "What is the layout of the HUD?"
"""
from __future__ import annotations

import base64
import logging
from typing import Any

from .gemini_client import GeminiClient
from .schemas import (
    NeonNodeEntry,
    SpatialFinding,
    VisualMapAnalysis,
    VisualMapRequest,
    VisualMapResponse,
)

logger = logging.getLogger(__name__)


VISUAL_MAP_SYSTEM_PROMPT = """\
You are GoDotter, an AI game development assistant for Godot 4.

You have been given a screenshot of a game scene where each node type has been
painted with a DISTINCT NEON COLOR. You also have:
1. A COLOR LEGEND telling you which color corresponds to which node class.
2. A NODE MAP listing every node's name, class, screen position, and size.

Your job is to analyze the scene's SPATIAL LAYOUT and STRUCTURE:

1. LAYOUT ANALYSIS
   - Describe what the scene looks like spatially.
   - Identify the major UI regions or game areas.
   - Note the spatial hierarchy (what is on top of what).

2. OVERLAP DETECTION
   - Find nodes whose screen rectangles overlap when they should not.
   - Identify nodes that are hidden behind other nodes unexpectedly.

3. Z-INDEX / DEPTH ISSUES
   - Are any nodes drawn in the wrong order?
   - Does z_index match the expected visual layering?

4. INVISIBLE / ZERO-SIZE NODES
   - Note nodes that exist but have zero or near-zero size on screen.
   - Note nodes whose color does not appear in the screenshot (may be hidden).

5. ANSWER THE QUERY
   - If a specific query is provided, answer it precisely using the node map
     and the screenshot together.

Be specific: name the exact nodes, their paths, and their screen coordinates.
The color legend tells you the exact mapping.

Respond ONLY with a valid JSON object matching the VisualMapAnalysis schema.
"""


def handle_visual_map(
    req: VisualMapRequest,
    gemini: GeminiClient,
    project_root: str,
) -> VisualMapResponse:
    """Run the Visual Map Agent on a neon debug screenshot + node map."""
    if not req.screenshot_base64:
        return VisualMapResponse(ok=False, error="No screenshot provided.")

    # Decode screenshot
    try:
        screenshot_bytes = base64.b64decode(req.screenshot_base64)
    except Exception as exc:
        return VisualMapResponse(ok=False, error=f"Failed to decode screenshot: {exc}")

    # Build prompt
    user_prompt = _build_visual_map_prompt(req)

    result = gemini.generate_structured(
        system_prompt=VISUAL_MAP_SYSTEM_PROMPT,
        user_prompt=user_prompt,
        response_schema=VisualMapAnalysis,
        images=[screenshot_bytes],
        request_model=req.model or None,
    )

    if not result["ok"]:
        return VisualMapResponse(
            ok=False,
            error=result.get("error", "AI error"),
            raw_response=result.get("raw"),
        )

    analysis: VisualMapAnalysis = result["data"]
    analysis.node_count_visible = sum(1 for n in req.node_map if n.visible)

    return VisualMapResponse(ok=True, analysis=analysis)


def _build_visual_map_prompt(req: VisualMapRequest) -> str:
    lines = []

    if req.scene_path:
        lines.append(f"Scene: {req.scene_path}")

    if req.query:
        lines.append(f"QUERY: {req.query}")
        lines.append("")

    # Color legend
    if req.color_legend:
        lines.append("=== COLOR LEGEND (node class → neon hex color) ===")
        for cls, hex_color in sorted(req.color_legend.items()):
            lines.append(f"  {hex_color}  →  {cls}")
        lines.append("")

    # Node map
    if req.node_map:
        lines.append(f"=== NODE MAP ({len(req.node_map)} nodes) ===")
        lines.append(
            "Format: [depth] class 'name' at (x,y) size WxH  z={z}  "
            "color={color}  script={script}"
        )
        lines.append("")

        # Sort by depth then y position for readability
        sorted_nodes = sorted(req.node_map, key=lambda n: (n.depth, n.screen_y))

        for node in sorted_nodes:
            indent = "  " * node.depth
            pos = f"({node.screen_x:.0f},{node.screen_y:.0f})"
            size = f"{node.screen_width:.0f}×{node.screen_height:.0f}"
            script_short = node.script.split("/")[-1] if node.script else "—"
            visibility = "" if node.visible else "  [HIDDEN]"
            lines.append(
                f"{indent}[{node.depth}] {node.node_class} '{node.name}' "
                f"at {pos} size {size}  z={node.z_index}  "
                f"color={node.neon_color_hex}  script={script_short}{visibility}"
            )
        lines.append("")

    lines.append(
        "The neon screenshot is attached. Analyze the spatial layout, "
        "overlaps, z-ordering, and hidden nodes. "
        "Answer any query using the node map as ground truth for positions."
    )
    lines.append("Return the VisualMapAnalysis JSON object.")

    return "\n".join(lines)
