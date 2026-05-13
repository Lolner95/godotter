<div align="center">

# GoDotter

### The AI-native cockpit for **Godot 4** — built so you can think in games, not in friction.

*A personal project, shared with the world. If it helps one person ship their dream game, it was worth it.*

[![Godot 4](https://img.shields.io/badge/Godot-4.3+-478cbf?logo=godotengine&logoColor=white)](https://godotengine.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Gemini](https://img.shields.io/badge/AI-Google%20Gemini-4285F4?logo=google)](https://aistudio.google.com/)

**Repository:** [github.com/Lolner95/godotter](https://github.com/Lolner95/godotter)

</div>

---

## Table of contents

1. [A letter from the founder](#a-letter-from-the-founder)
2. [The vision: “Cursor”, but for Godot](#the-vision-cursor-but-for-godot)
3. [What GoDotter actually does](#what-godotter-actually-does)
4. [Who this is for](#who-this-is-for)
5. [How it is put together](#how-it-is-put-together)
6. [Installation (the short honest path)](#installation-the-short-honest-path)
7. [First run: API key, backend, and trust](#first-run-api-key-backend-and-trust)
8. [Modes, chat, and slash commands](#modes-chat-and-slash-commands)
9. [Safety: plans, diffs, and when the AI touches your files](#safety-plans-diffs-and-when-the-ai-touches-your-files)
10. [Development & testing this repo](#development--testing-this-repo)
11. [Contributing & community](#contributing--community)
12. [License](#license)

---

## A letter from the founder

I make games because I love the moment when an idea becomes something you can *play*. Godot is incredible for that — open source, approachable, and powerful enough for serious work. But when I looked around for tooling that matched how I *actually* work in 2025 — with an AI partner that understands my whole project, my scenes, my scripts, and my mistakes — I kept coming up short.

Nothing on the market felt like it was **made for Godot’s way of building games**: scenes and nodes, signals, `.tscn` and `.gd`, the editor as the center of gravity. I did not want a generic chat window bolted onto the side of my life. I wanted something closer to what **Cursor** did for general code: context-aware, iterative, respectful of diffs and history — but **native to Godot**.

So I started **GoDotter** as a personal project: a dock inside the editor that talks to a small local Python server, powered by **Google Gemini**, that can **plan**, **explain**, **visualize**, and (when you explicitly allow it) **help edit** your project with guardrails.

It is still early. It will get better. I am putting it on GitHub because **I believe we can make Godot more accessible** — not by dumbing anything down, but by meeting people where they are: solo devs, small teams, learners who have the passion but not yet the muscle memory for every system in the engine.

If you try it, break it, or improve it, you are already part of the story. Welcome.

---

## The vision: “Cursor”, but for Godot

**Cursor** changed how many of us write software: inline AI, repo-wide context, and a tight loop between intent and diff. **GoDotter** chases the same *feeling* for **game development in Godot**:

| Idea | How GoDotter approaches it |
|------|-----------------------------|
| **Project-wide context** | Indexes scenes and scripts, uses editor hints (selection, open scene), and optional **project memory** markdown. |
| **Plan before you ship** | **Architect**-style planning: structured plans with steps, risks, and validation — not a wall of prose. |
| **See the scene, not just the text** | **Neon Visual Map**: every node type gets a distinct color, screenshot + AI spatial reasoning. |
| **Iterate with care** | **Diff** viewer, per-file revert, git checkpoints when files are written — you stay in control. |
| **Local-first server** | Python **FastAPI** backend runs on **your machine** (default `127.0.0.1`). Your project stays local; only API calls to Gemini go outbound. |

We are not claiming feature parity with Cursor (different domain, different editor, different constraints). We *are* claiming the same **north star**: **lower the activation energy** between “I have an idea” and “it works in my game.”

---

## What GoDotter actually does

Below is what you get **today**, as honestly as possible — the kind of list I wish every tool published.

### In the editor (Godot plugin)

- **Chat dock** — Talk to the agent in natural language. Pick a **mode** (Full agent, Plan, Execute, Scene, Node, Index, Memory, Fix logs, Visual map, Help) without memorizing slash commands (they still exist if you like them).
- **Plan tab** — Review structured plans before anything touches disk (when you work in plan-first flows).
- **Inspect tab** — Scene summary, deep **selected node** summary, hooks into visualization.
- **Diff tab** — Colored diffs, approve / revert flows when file edits are in play.
- **Memory tab** — Browse markdown memory under `.godot_forge/memory/` (architecture, style, bugs — *your* canon for the AI).
- **Settings** — Backend URL, Python path, bundled backend dir, **Gemini API key** (stored machine-wide in Editor Settings and synced to a key file for the subprocess), autostart, model presets, file-edit permissions, approval modes.
- **Setup wizard** — First-run guidance (Python / venv / key) when things are not wired yet.
- **Backend controls** — Start/stop the bundled Python server from the dock (with sensible defaults: auto-bring-up, port selection if the default is busy, health checks).

### AI capabilities (via Gemini + local backend)

- **Planning (`/agent/plan`)** — Structured **Plan** JSON: summary, relevant files/scenes, assumptions, risks, steps, validation checklist.
- **Execution (`/agent/execute`, full agent session)** — When enabled, applies file changes through controlled tools with backups and checkpoints — gated by your settings.
- **Project index & context** — Scan the project, rank files for a query, feed compact context into prompts.
- **Neon Visual Map** — Debug-style visualization: recolor nodes, capture viewport, send image + node map to Gemini for spatial questions (overlap, hierarchy, “what is wrong with this layout?”).
- **Fix from logs** — Aggregate recent Godot run errors into a batch-style fix plan.
- **3D asset review** (where applicable) — Multi-angle capture path for reviewing selected 3D assets (evolving; see in-editor hints).

### What it is *not* (yet)

- Not a replacement for learning Godot.
- Not a hosted SaaS — you run the backend locally.
- Not “unsupervised autopilot” unless you explicitly configure riskier modes — defaults lean toward **review**.

---

## Who this is for

- **Solo developers** who want a second brain for architecture and refactors.
- **Small teams** who need shared **memory** files and consistent style guidance.
- **Learners** who benefit from “explain this scene / node” and visual map feedback.
- **Anyone** who felt the same gap I did: *“Why isn’t there a serious AI workflow that feels native to Godot?”*

---

## How it is put together

Everything ships in **one addon folder** so distribution stays simple:

```text
addons/GoDotter/
├── plugin.cfg              # Godot plugin entry
├── GoDotter.gd             # EditorPlugin: dock, backend process, health
├── core/                   # GDScript: state, HTTP client, bridge, diff, viz, …
├── ui/                     # ForgeDock, wizard, diff panel, …
├── icons/
└── backend/                # Python FastAPI + uvicorn (bundled)
    ├── main.py             # CLI entry (--project-root, --host, --port, .env)
    ├── requirements.txt
    ├── .env.example        # Template for GEMINI_API_KEY (copy to .env)
    └── src/                # app.py, gemini_client, orchestrator, tools, …
```

**High-level flow**

1. You type a goal in the dock (or use `/plan`, `/agent`, etc.).
2. The plugin builds a **context bundle** (project root, index snippets, editor hints).
3. The **local** FastAPI server calls **Gemini** with structured schemas where possible.
4. Results stream back into the UI — plans, chat, diffs — depending on the workflow.

For a route-level map of the HTTP API, see [`addons/GoDotter/backend/README.md`](addons/GoDotter/backend/README.md).

---

## Installation (the short honest path)

1. **Copy** the entire `addons/GoDotter/` folder into your Godot project’s `addons/` directory.
2. Open **Project → Project Settings → Plugins** and enable **GoDotter**.
3. **Create a Python virtualenv** inside the bundled backend and install dependencies:

   **Windows (PowerShell)**

   ```powershell
   cd addons\GoDotter\backend
   python -m venv .venv
   .\.venv\Scripts\pip install -r requirements.txt
   ```

   **macOS / Linux**

   ```bash
   cd addons/GoDotter/backend
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   ```

4. **Restart Godot** (or at least reload the project) so PATH and plugin scripts pick up cleanly.

A longer, step-by-step guide (troubleshooting, wizard, etc.) lives in **[`INSTALL.md`](INSTALL.md)**.

---

## First run: API key, backend, and trust

### Gemini API key

GoDotter uses **Google Gemini** ([Google AI Studio](https://aistudio.google.com/) — you can create an API key there).

You can provide the key in either of these ways:

1. **Editor**: GoDotter **Settings** tab → paste key → save (also written for the subprocess).
2. **Environment**: `GEMINI_API_KEY` or `GOOGLE_API_KEY` before starting Python.
3. **Local file (CLI / tests)**: copy `addons/GoDotter/backend/.env.example` to `addons/GoDotter/backend/.env` and set `GEMINI_API_KEY=...`.  
   - `main.py` loads `.env` on startup (**shell variables still win** over `.env` by default — intentional for CI and power users).  
   - For **unit tests**, the integration test loads `.env` with override so a fixed local key wins over stale OS env vars — see `tests/test_plan_towers_integration.py`.

**Never commit** `.env`, `.godotter_api_key`, or real keys into git. This repository’s `.gitignore` is set accordingly.

### Starting the backend

- Prefer the **▶** button in the GoDotter dock (the plugin passes `--project-root` and picks a free port if needed).
- Or run manually from `addons/GoDotter/backend`:

  ```powershell
  .\.venv\Scripts\python.exe main.py --project-root "C:\Path\To\YourGame" --no-reload
  ```

Default URL is `http://127.0.0.1:8765` unless your Settings or auto-port logic change it.

---

## Modes, chat, and slash commands

The dock exposes **modes** (Full agent, Plan, Execute, …) so newcomers are not forced to learn slash syntax. Power users can still use commands such as:

| Command | Role |
|--------|------|
| `/plan` | Plan only — no file writes |
| `/do`, `/fix` | Plan + execute style flows (subject to settings) |
| `/scene`, `/node` | Scene / selection intelligence |
| `/audit` | Index / audit style pass |
| `/memory` | Memory files |
| `/neon`, `/visualmap` | Neon visual map |
| `/fixlogs` | Plan from recent logs |
| `/diff`, `/settings`, `/help` | Jump to tabs or help |

Exact wording may evolve; `/help` in the dock is the source of truth for your installed version.

---

## Safety: plans, diffs, and when the AI touches your files

- **Plans first** — The default mental model is: understand → plan → validate → *then* optionally execute.
- **Settings gate** — File writes are disabled unless you explicitly allow them; approval modes let you choose how much automation you want.
- **Diffs and revert** — When changes land, you get editor-side visibility and rollback paths (see Diff tab and backend tool routes).
- **Git checkpoints** — When the tool stack writes files, it can create checkpoints — use real version control habits alongside the plugin.

You are the creative director. GoDotter is the intern with encyclopedic patience — not the owner of your repository.

---

## Development & testing this repo

The `project.godot` at the **root of this repository** exists so contributors can open the **addon itself** in Godot for development. **Game projects** normally only vendor `addons/GoDotter/`.

**Godot script check (headless)**

```powershell
godot.exe --headless --path "C:\Path\To\This\Repo" --check-only
```

**Python integration test (planning endpoint)**

```powershell
cd addons\GoDotter\backend
.\.venv\Scripts\python.exe -m unittest tests.test_plan_towers_integration -v
```

Requires a valid `GEMINI_API_KEY` (see `.env` / env vars). Without a key, the test skips instead of failing CI.

---

## Contributing & community

Issues, PRs, and design discussions are welcome. If you:

- improve onboarding copy,
- harden Windows / macOS / Linux paths,
- add tests,
- document a workflow,

…you make Godot more approachable for the next person.

**Ways to contribute**

1. **Try it** on a real project and open an issue with repro steps.
2. **Improve docs** (even one paragraph helps).
3. **Share** the repo with a friend who uses Godot and wants an AI workflow that respects the editor.

Upstream repo: **[github.com/Lolner95/godotter](https://github.com/Lolner95/godotter)**

---

## License

MIT — see [`LICENSE`](LICENSE).  
You are free to use, modify, and ship GoDotter in commercial and non-commercial projects, subject to the license text (and subject to **your** compliance with the **Gemini / Google API terms** on your own keys).

---

<div align="center">

**Made with stubborn optimism and too much coffee.**

*If GoDotter saves you an afternoon of staring at the wrong node, we are winning.*

</div>
