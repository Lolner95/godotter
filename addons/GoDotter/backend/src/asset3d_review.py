"""3D asset visual review.

Accepts 6+ orthographic angle screenshots of a 3D asset and asks Gemini
to evaluate mesh quality, UV mapping, albedo consistency, normals/shading,
scale, and PBR plausibility.
"""
from __future__ import annotations

import base64
import logging
from typing import Any

from .gemini_client import GeminiClient
from .schemas import Asset3DReview, Visual3DRequest, Visual3DResponse

logger = logging.getLogger(__name__)


ASSET_3D_SYSTEM_PROMPT = """\
You are GoDotter, an AI 3D asset reviewer for a Godot 4 game.

You have been given screenshots of a 3D asset from multiple angles.
Your job is to evaluate the asset quality across these dimensions:

1. MESH SILHOUETTE — Is the silhouette clean and consistent from all angles?
   Detect: jagged edges, z-fighting, missing faces, inverted normals (dark patches), excessive poly density.

2. UV / TEXTURE MAPPING — Look for UV stretching (texture appears stretched or skewed on any face).
   Detect: seams, checkerboard distortion, incorrect tiling.

3. ALBEDO CONSISTENCY — Does the base color / albedo texture look correct on all faces?
   Detect: wrong color on specific faces, washed-out areas, missing textures (solid color faces).

4. NORMALS / SHADING — Does the lighting look physically correct?
   Detect: hard edge shading where smooth is expected, overly dark or overly bright patches,
   incorrect smoothing groups, missing normal map.

5. SCALE — Does the asset appear to be at a reasonable world scale?
   Detect: obviously too large or too small relative to Godot's 1 unit = ~1 meter convention.

6. PBR MATERIAL PLAUSIBILITY — Do the material properties look realistic?
   Detect: full-mirror metalness on non-metal objects, zero roughness everywhere, missing emission.

For each angle (top, bottom, front, back, left, right, perspective), give a score 0-10 and list findings.
Then give an overall score and a list of priority recommendations, ordered from most impactful to least.

Be specific. Mention which angle reveals each issue.
Respond ONLY with a valid JSON object matching the Asset3DReview schema.
"""


def handle_visual_review_3d(
    req: Visual3DRequest,
    gemini: GeminiClient,
    project_root: str,
) -> Visual3DResponse:
    """
    Run the 3D asset review agent.

    req.angle_images: list of {angle: str, png_base64: str}
    """
    if not req.angle_images:
        return Visual3DResponse(
            ok=False,
            error="No angle images provided. Capture 3D angles from the editor first.",
        )

    # Decode images
    images_bytes: list[bytes] = []
    angle_labels: list[str] = []
    for item in req.angle_images:
        angle = item.get("angle", "unknown")
        b64 = item.get("png_base64", "")
        if not b64:
            continue
        try:
            img_bytes = base64.b64decode(b64)
            images_bytes.append(img_bytes)
            angle_labels.append(angle)
        except Exception as exc:
            logger.warning("Could not decode image for angle %s: %s", angle, exc)

    if not images_bytes:
        return Visual3DResponse(ok=False, error="All provided images failed to decode.")

    user_prompt = _build_3d_prompt(
        asset_path=req.asset_path,
        angles=angle_labels,
        goals=req.goals,
    )

    result = gemini.generate_structured(
        system_prompt=ASSET_3D_SYSTEM_PROMPT,
        user_prompt=user_prompt,
        response_schema=Asset3DReview,
        images=images_bytes,
        request_model=req.model or None,
    )

    if not result["ok"]:
        return Visual3DResponse(
            ok=False,
            error=result.get("error", "AI error"),
            raw_response=result.get("raw"),
        )

    review: Asset3DReview = result["data"]
    review.asset_path = req.asset_path or review.asset_path

    return Visual3DResponse(ok=True, review=review)


def _build_3d_prompt(
    asset_path: str,
    angles: list[str],
    goals: list[str],
) -> str:
    lines = []
    if asset_path:
        lines.append(f"Asset: {asset_path}")
    lines.append(f"Angles provided ({len(angles)}): {', '.join(angles)}")
    if goals:
        lines.append("Review goals: " + "; ".join(goals))
    lines.append("")
    lines.append(
        "The screenshots above show this asset from the listed angles. "
        "Evaluate the asset quality across all dimensions described in your instructions. "
        "Be specific about which angle reveals which issue. "
        "Return the Asset3DReview JSON object."
    )
    return "\n".join(lines)
