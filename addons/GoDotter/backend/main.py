"""GoDotter agent backend entry point.

Usage
-----
Manual start (recommended during development):
    cd tools/godot_forge_agent
    python main.py

Auto-launched by the GoDotter plugin:
    python main.py --project-root /path/to/your/godot/project

The --project-root flag is optional; the backend also auto-detects it by searching
for a project.godot file starting from the current directory.

Environment variables
---------------------
GEMINI_API_KEY or GOOGLE_API_KEY — Google Gemini / AI Studio key (never commit these).

If neither is set, the backend reads ``.godotter_api_key`` in this folder (written by the
Godot plugin from Settings → API key).

Optional: create ``.env`` next to ``main.py`` with ``GEMINI_API_KEY=...`` (see ``.env.example``).
It is loaded automatically for CLI and tests; it does not override variables already set in your shell.
"""
import argparse
import json
import os
import sys
from pathlib import Path

import uvicorn


def _load_dotenv_file() -> None:
    """Load backend/.env into os.environ if python-dotenv is available (uvicorn[standard] includes it)."""
    env_path = Path(__file__).resolve().parent / ".env"
    if not env_path.is_file():
        return
    try:
        from dotenv import load_dotenv
    except ImportError:
        print(
            "[GoDotter] Tip: install python-dotenv or use `pip install -r requirements.txt` "
            "to load variables from .env",
            file=sys.stderr,
        )
        return
    load_dotenv(env_path, override=False)


def _inject_api_key_from_file() -> None:
    """Let auto-launched Python see the key without inheriting the editor's environment."""
    if os.environ.get("GEMINI_API_KEY", "").strip() or os.environ.get("GOOGLE_API_KEY", "").strip():
        return
    key_path = Path(__file__).resolve().parent / ".godotter_api_key"
    if not key_path.is_file():
        return
    try:
        key = key_path.read_text(encoding="utf-8").strip()
        if key:
            os.environ["GEMINI_API_KEY"] = key
    except OSError as exc:
        print(f"[GoDotter] Warning: could not read .godotter_api_key: {exc}", file=sys.stderr)


def _load_config(project_root: str | None) -> None:
    """Merge config.json into environment / app config before server starts."""
    config_path = Path(__file__).parent / "config.json"
    if config_path.exists():
        try:
            cfg = json.loads(config_path.read_text())
            # Inject project_root from CLI if provided (overrides config file)
            if project_root:
                cfg["project_root"] = project_root
            # Store for the app module to pick up before lifespan
            os.environ.setdefault("GODOTTER_CONFIG_PATH", str(config_path))
            if "project_root" in cfg:
                os.environ.setdefault("GODOTTER_PROJECT_ROOT", cfg["project_root"])
        except Exception as exc:
            print(f"[GoDotter] Warning: could not read config.json: {exc}", file=sys.stderr)
    elif project_root:
        os.environ.setdefault("GODOTTER_PROJECT_ROOT", project_root)


def main() -> None:
    parser = argparse.ArgumentParser(description="GoDotter backend server")
    parser.add_argument(
        "--project-root",
        default=None,
        help="Absolute path to the Godot project root (overrides config.json)",
    )
    parser.add_argument("--host",  default="127.0.0.1")
    parser.add_argument("--port",  default=8765, type=int)
    # Default off: uvicorn --reload uses a supervisor PID; Godot tracks the child and health checks fail.
    parser.add_argument("--reload", action="store_true", help="Uvicorn autoreload (dev only)")
    parser.add_argument("--no-reload", dest="reload", action="store_false", help="Single process (default)")
    parser.set_defaults(reload=False)
    parser.add_argument("--log-level", default="info")
    args = parser.parse_args()

    _load_dotenv_file()
    _load_config(args.project_root)
    _inject_api_key_from_file()

    print(f"[GoDotter] Starting backend on {args.host}:{args.port}")
    if args.project_root:
        print(f"[GoDotter] Project root: {args.project_root}")

    try:
        uvicorn.run(
            "src.app:app",
            host=args.host,
            port=args.port,
            reload=args.reload,
            log_level=args.log_level,
        )
    except OSError as exc:
        print(
            f"[GoDotter] Failed to bind {args.host}:{args.port}: {exc}. "
            "Port may be in use — pick another port in GoDotter Settings or close the other process.",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
