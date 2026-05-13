# Installing GoDotter into Any Godot Project

GoDotter is a **self-contained Godot 4 editor plugin**. The AI backend is
bundled inside the plugin folder — copy one folder and you have everything.

---

## Folder structure (what you copy)

```
addons/
  GoDotter/
    plugin.cfg          ← Godot plugin definition
    GoDotter.gd         ← EditorPlugin entry point
    core/               ← plugin logic
    ui/                 ← dock UI
    agents/             ← prompt schemas
    icons/
    backend/            ← Python backend (bundled!)
      main.py
      src/
      requirements.txt
      config.example.json
      .gdignore         ← tells Godot to skip this folder
```

---

## 1. Copy the plugin

Copy the **`addons/GoDotter/`** folder into your game project's `addons/` folder.

> That's it. The backend is already inside.

---

## 2. Enable the plugin

Open your project in Godot 4.3+.  
Go to **Project → Project Settings → Plugins** and enable **GoDotter**.

The **Forge** dock appears on the right. If this is the first time, the
**Setup Wizard** opens automatically.

---

## 3. Install Python dependencies (once per machine)

The backend needs Python 3.11+ and a virtual environment.

```powershell
# Windows — from inside your project folder
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

## 4. Set your Gemini API key

Get a free key at https://aistudio.google.com/

```powershell
# Windows PowerShell — set this BEFORE starting the backend
$env:GEMINI_API_KEY = "your-key-here"
```

```bash
# macOS / Linux
export GEMINI_API_KEY="your-key-here"
```

> **Never put your API key in any file.** Always use an environment variable.

---

## 5. Start the backend

**Option A — from inside Godot (recommended):**  
Click the **▶** button in the GoDotter top bar, or enable **Auto-launch** in Settings.

**Option B — terminal:**

```powershell
cd addons\GoDotter\backend
$env:GEMINI_API_KEY = "your-key-here"
.\.venv\Scripts\python main.py
```

The dock shows **ONLINE** when the server is running.

---

## 6. Index your project

Click **Index Project** in the Chat tab (or run `/audit`).  
This teaches the AI about your scenes, scripts, and structure.

---

## 7. Start using it

Type in the Chat tab:

```
/plan Fix the card hover animation to not flicker on rapid mouse-over
```

| Command | Description |
|---------|-------------|
| `/plan <request>` | Plan changes — no files touched |
| `/do <request>` | Plan + execute with Code Agent |
| `/neon [query]` | Neon visual map + AI spatial analysis |
| `/fixlogs` | Batch fix from last run's errors |
| `/scene` `/node` | Inspect current scene / selected node |
| `/diff` | Review file diffs |
| `/memory` | Browse project memory |
| `/help` | Full command list |

---

## Updating GoDotter

Replace the `addons/GoDotter/` folder with the new version.  
Your `.venv` (inside `backend/`) is gitignored and stays intact.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Dock shows OFFLINE | Click ▶ or start backend from terminal |
| "No Gemini key" warning | Set `GEMINI_API_KEY` env var before starting backend |
| `ModuleNotFoundError` | Run `pip install -r requirements.txt` in `addons/GoDotter/backend/` |
| Wizard re-appears | Complete it or click "Open GoDotter" |
| Wrong Python | Set path in Settings tab or ensure `.venv` is inside `backend/` |
