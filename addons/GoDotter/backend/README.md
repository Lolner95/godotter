# GoDotter Backend

The Python companion server for the GoDotter Godot plugin.

This folder (`addons/GoDotter/backend/`) is **bundled inside the plugin** —
you don't install it separately. When you copy `addons/GoDotter/` into any
Godot project, the backend comes with it.

---

## Setup (once per machine)

```powershell
# Windows
cd addons\GoDotter\backend
python -m venv .venv
.\.venv\Scripts\pip install -r requirements.txt
```

```bash
# macOS / Linux
cd addons/GoDotter/backend
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

---

## Starting the server

**From Godot:** click the ▶ button in the GoDotter dock (recommended).

**From terminal:**
```powershell
$env:GEMINI_API_KEY = "your-key-here"
.\.venv\Scripts\python main.py
```

The server starts at `http://127.0.0.1:8765` by default.

### CLI options

```
python main.py [--project-root PATH] [--host HOST] [--port PORT] [--no-reload] [--log-level LEVEL]
```

`--project-root` is set automatically when the Godot plugin launches the backend.

---

## API endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Backend status + Gemini key check |
| POST | `/project/index` | Scan and index the Godot project |
| POST | `/project/context` | Fetch relevant context for a query |
| POST | `/agent/plan` | Architect Agent — create a plan |
| POST | `/agent/execute` | Code Agent — execute a plan |
| POST | `/agent/visual_map` | Neon debug spatial analysis |
| POST | `/agent/visual_review_3d` | 6-angle 3D asset review |
| POST | `/agent/fix_from_logs` | Batch fix from Godot run logs |
| POST | `/tools/read_file` | Safe file read |
| POST | `/tools/write_file` | Safe file write with backup |
| POST | `/tools/revert_file` | Revert file from backup |
| GET | `/tools/git_status` | Git status |
| POST | `/tools/search` | Text search across project files |
| GET | `/memory` | Read project memory |

---

## API keys and providers

Get a free Gemini key at https://aistudio.google.com/

The backend now includes provider-aware model settings (Gemini / OpenAI / Claude profiles in shared settings schemas), while runtime availability still depends on your configured adapter/runtime.

**Never put your key in `config.json`.** Always set it as an environment
variable before starting the server:

```powershell
$env:GEMINI_API_KEY = "your-key-here"
```

If you are wiring other providers in your runtime, set their provider-specific keys in your environment/config too.

---

## Config

Copy `config.example.json` to `config.json` to override defaults.
`config.json` is gitignored — never commit it.

---

## Feedback

We're actively improving GoDotter and the backend API surface. If you hit friction or want new workflows, open an issue/PR — real project feedback is what drives the roadmap.
