"""TODO Phase 7: Image diff and visual comparison tools.

Uses Pillow for:
- Pixel-level diff between before/after screenshots
- Blank/white screen detection
- Large layout change detection
- Debug line detection (excessive red pixels)
"""
from pathlib import Path


def compute_diff(before_path: str, after_path: str) -> dict:
    raise NotImplementedError("compute_diff — Phase 7")


def detect_blank_screen(image_path: str, threshold: float = 0.95) -> bool:
    raise NotImplementedError("detect_blank_screen — Phase 7")


def detect_debug_lines(image_path: str) -> dict:
    raise NotImplementedError("detect_debug_lines — Phase 7")
