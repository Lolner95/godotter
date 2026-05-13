"""Project memory store.

Manages:
- SQLite database for task history
- Markdown memory files (architecture, style guide, known bugs, validation recipes)
- Pre-seeded with food-TCG game identity facts from the project spec

Memory files are written to .godot_forge/memory/ inside the Godot project.
"""
from __future__ import annotations

import json
import logging
import sqlite3
import time
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

MEMORY_FILES = ["architecture.md", "style_guide.md", "known_bugs.md", "validation_recipes.md"]


# ---------------------------------------------------------------------------
# Seed content — pre-filled from project spec section 12
# ---------------------------------------------------------------------------

SEED_ARCHITECTURE = """\
# Architecture

## Game Identity
- Food-only card identities. No fantasy monster naming.
- Cards are dishes, ingredients, preparations, drinks, sauces, desserts, and food concepts.
- Fusion is the emotional core of the game — food combinations create powerful hybrid cards.
- Target platform: Godot 4.x, desktop-first.

## Engine
- Godot 4.x — GDScript only. No external web UI.
- UI built with Godot Control nodes (not HTML/CSS).
- Autoloads for global systems (GameManager, AudioManager, etc.).
- Scenes for each game state (MainMenu, BattleScene, CardSelectionScene, etc.).

## Card System
- CardView.gd — renders a single card (art, name, attack, defense, fusion markers).
- Hand management script — tracks cards in player's hand, selection state.
- Board management script — tracks played cards, their visual state.
- Fusion selection state must be fully isolated from board card display state.
- After a card is played to the board, it must show ZERO fusion selection markers or colors.

## Key Scenes
- res://scenes/battle/ — main battle scene
- res://ui/ — UI components including card views, hand, board
- res://scripts/ — game logic scripts
- res://assets/ — card art, audio, fonts, themes

## Audio
- AudioStreamPlayer nodes for sound effects
- Should NOT stop overlapping sounds (use multiple players or bus routing)
- Game start must not trigger multiple attack sounds
"""

SEED_STYLE_GUIDE = """\
# Style Guide

## Visual Identity
- Tropical, premium, early-2000s sunny game energy.
- Satisfying TCG feel. Food duel energy.
- Colors: warm golds, tropical greens, deep rich backgrounds.
- UI must feel polished, juicy, tactile, and addictive.
- No cheap placeholder UI. Card readability matters.
- Sound and animation sync matters.

## Card Visual Rules
- Card art must fill the intended card art region (not leave whitespace).
- Attack and defense values must always be readable (high contrast).
- Played board cards must look NEUTRAL unless actively targeted.
- Fusion selection state (glow, color overlay, "(1)/(2)" labels) applies ONLY to hand cards during fusion selection.
- Played board cards must never retain fusion selection visuals.
- Hovered cards must not turn white (white card = broken material/shader).
- Card backs must look premium, not overly noisy.
- Background supports the cards — does not compete visually.

## GDScript Style
- Use typed variables and typed function signatures.
- Use @onready for node references.
- Use signal declarations with types.
- Prefer small, focused scripts over giant monolithic ones.
- Preserve existing signals and exported variables unless intentionally changed.
- Style matches existing code in the project.

## Naming
- Food card names: dish names, ingredients, cooking techniques, beverages.
- Script names: PascalCase for classes, snake_case for variables/functions.
- Signal names: snake_case, verb-noun pattern (card_played, fusion_selected).
"""

SEED_KNOWN_BUGS = """\
# Known Recurring Issues

## Card Art
- **CardView ignored art_path**: CardView.gd sometimes overwrites displayed texture
  with a placeholder because the `art_path` property is set but not applied during
  `_ready()` or after scene instantiation. Fix: ensure `_apply_art()` is called
  whenever `art_path` is set.

## Visual State Leaks
- **Played cards keep fusion selection colors**: When a card is moved from hand to board,
  the fusion selection visual state (glow, color overlay, "(1)/(2)" label) persists on the
  board card. Root cause: board card render uses same visual state as hand card.
  Fix: Reset all selection/fusion state when a card transitions to the board.

- **Played cards keep "(1)" or "(2)" labels**: Same root cause as above.
  Fusion ingredient labels must be cleared when the card is played.

## Hover Issues
- **Hovered cards turn white**: Card becomes white rectangle on hover.
  Root cause: Usually a missing or broken material/shader, or TextureRect with wrong
  stretch mode, or CanvasItem modulate reset to white Color(1,1,1) incorrectly.

## Debug Artifacts
- **Red vertical debug line**: Caused by `AttackUXValidation.draw_line()` left enabled.
  Fix: Remove or guard `draw_line` call with `if debug_mode:`.

## Audio
- **Sound playback cuts previous sounds**: AudioStreamPlayer re-used for multiple
  sounds without checking if already playing. Fix: Use separate AudioStreamPlayer
  nodes or an audio pool. Never call `.play()` on an already-playing player without
  first stopping it intentionally.
- **Multiple attack sounds at game start**: Some initialization loop triggers
  attack sound emitters. Fix: Guard audio triggers with game state checks.

## Performance
- **Slow scene load**: Large texture imports without mipmaps. Check import settings.
"""

SEED_VALIDATION_RECIPES = """\
# Validation Recipes

## Card Hover Validation
1. Load battle scene.
2. Hover over each hand card.
3. Assert: card texture is NOT white/blank.
4. Assert: card art fills the art region.
5. Assert: attack/defense values are visible.
6. Capture screenshot labeled "hover_card_{n}".

## Card Play Validation
1. Load battle scene with known card in hand.
2. Play card to board.
3. Assert: played card has NO "(1)" or "(2)" label.
4. Assert: played card has NO fusion selection glow/color.
5. Assert: played card art is correct.
6. Assert: hand card count decreased by 1.
7. Capture before/after screenshots.

## Fusion Selection Validation
1. Load battle scene.
2. Select first fusion ingredient (should show "(1)" label, color glow).
3. Assert: only the selected hand card shows fusion state.
4. Assert: board cards show NO fusion state.
5. Select second ingredient.
6. Assert: fusion animation triggers.
7. After fusion: assert result card has no selection state.

## Audio Validation
1. Start game.
2. Assert: no attack sound plays during initialization.
3. Play attack action.
4. Assert: attack sound plays once.
5. Play second attack quickly.
6. Assert: two sounds overlap correctly (not cut off).

## Screenshot Comparison Checklist
- Before screenshot: capture BEFORE making changes.
- After screenshot: capture AFTER changes + game run.
- Check: card art fills art region.
- Check: text is readable (not white-on-white, not clipped).
- Check: no obvious placeholder textures.
- Check: no debug draw lines.
- Check: layout matches intended design.
"""


# ---------------------------------------------------------------------------
# Memory file management
# ---------------------------------------------------------------------------

def ensure_memory_files(project_root: str) -> dict[str, str]:
    """Create memory directory and seed files if they don't exist. Return paths."""
    mem_dir = Path(project_root) / ".godot_forge" / "memory"
    mem_dir.mkdir(parents=True, exist_ok=True)

    seeds = {
        "architecture.md": SEED_ARCHITECTURE,
        "style_guide.md": SEED_STYLE_GUIDE,
        "known_bugs.md": SEED_KNOWN_BUGS,
        "validation_recipes.md": SEED_VALIDATION_RECIPES,
    }

    paths = {}
    for filename, content in seeds.items():
        path = mem_dir / filename
        if not path.exists():
            path.write_text(content, encoding="utf-8")
            logger.info("Seeded memory file: %s", filename)
        paths[filename] = str(path)

    return paths


def read_memory(project_root: str) -> dict[str, str]:
    """Read all memory files and return their contents."""
    mem_dir = Path(project_root) / ".godot_forge" / "memory"
    result = {}
    for filename in MEMORY_FILES:
        path = mem_dir / filename
        if path.exists():
            result[filename[:-3]] = path.read_text(encoding="utf-8", errors="replace")
    return result


def append_memory(project_root: str, category: str, fact: str) -> bool:
    """Append a new fact to a memory category file."""
    filename_map = {
        "architecture": "architecture.md",
        "style": "style_guide.md",
        "bugs": "known_bugs.md",
        "validation": "validation_recipes.md",
    }
    filename = filename_map.get(category)
    if not filename:
        return False

    path = Path(project_root) / ".godot_forge" / "memory" / filename
    if not path.exists():
        return False

    existing = path.read_text(encoding="utf-8")
    path.write_text(existing + f"\n\n## Added {time.strftime('%Y-%m-%d')}\n{fact}\n", encoding="utf-8")
    return True


def build_memory_context(project_root: str) -> str:
    """Build a compact memory context string for inclusion in agent prompts."""
    memory = read_memory(project_root)
    if not memory:
        return ""
    parts = ["=== PROJECT MEMORY ==="]
    for key, content in memory.items():
        parts.append(f"\n--- {key.upper()} ---\n{content[:2000]}")  # cap per section
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# SQLite task store
# ---------------------------------------------------------------------------

def get_db_path(project_root: str) -> str:
    forge_dir = Path(project_root) / ".godot_forge"
    forge_dir.mkdir(parents=True, exist_ok=True)
    return str(forge_dir / "tasks.sqlite")


def init_db(project_root: str) -> sqlite3.Connection:
    db_path = get_db_path(project_root)
    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("""
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            title TEXT,
            user_request TEXT,
            status TEXT,
            created_at REAL,
            updated_at REAL,
            plan_json TEXT,
            final_report_json TEXT,
            error TEXT
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS task_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT,
            timestamp REAL,
            level TEXT,
            message TEXT
        )
    """)
    conn.commit()
    return conn


def save_task(conn: sqlite3.Connection, task: dict) -> None:
    conn.execute("""
        INSERT OR REPLACE INTO tasks
            (id, title, user_request, status, created_at, updated_at, plan_json, final_report_json, error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        task.get("id", ""),
        task.get("title", ""),
        task.get("user_request", ""),
        task.get("status", "queued"),
        task.get("created_at", time.time()),
        time.time(),
        json.dumps(task.get("plan", {})),
        json.dumps(task.get("final_report", {})),
        task.get("error", ""),
    ))
    conn.commit()


def load_tasks(conn: sqlite3.Connection, limit: int = 50) -> list[dict]:
    rows = conn.execute(
        "SELECT * FROM tasks ORDER BY created_at DESC LIMIT ?", (limit,)
    ).fetchall()
    return [dict(row) for row in rows]
