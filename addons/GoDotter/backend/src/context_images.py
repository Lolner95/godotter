"""Decode optional chat image attachments from plugin context_bundle."""
from __future__ import annotations

import base64
from typing import Any


def extract_context_images(context_bundle: dict[str, Any] | None, max_images: int = 4) -> list[bytes]:
    ctx = context_bundle or {}
    god = ctx.get("godotter", {}) if isinstance(ctx, dict) else {}
    if not isinstance(god, dict):
        return []
    raw_images = god.get("chat_images", [])
    if not isinstance(raw_images, list):
        return []
    out: list[bytes] = []
    for item in raw_images[:max_images]:
        if not isinstance(item, dict):
            continue
        b64 = str(item.get("base64", "")).strip()
        if not b64:
            continue
        try:
            img = base64.b64decode(b64, validate=True)
        except Exception:
            continue
        if not img:
            continue
        # Keep payloads bounded for request stability.
        if len(img) > 6 * 1024 * 1024:
            continue
        out.append(img)
    return out
