@tool
extends RefCounted

## Maps slash commands to agent modes and builds system prompt components.
## The actual prompts sent to Gemini are built on the backend
## (tools/godot_forge_agent/src/task_orchestrator.py + gemini_client.py).
## This file provides client-side context and routing logic.


const SLASH_COMMANDS := {
	"/plan": {
		"agent": "architect",
		"description": "Create a plan only — no file edits.",
		"requires_project_index": true,
		"requires_context": true,
		"phase": 1,
	},
	"/do": {
		"agent": "code",
		"description": "Plan → approve → execute.",
		"requires_project_index": true,
		"requires_context": true,
		"phase": 4,
	},
	"/fix": {
		"agent": "debug",
		"description": "Debug and fix a specific bug.",
		"requires_project_index": true,
		"requires_context": true,
		"phase": 4,
	},
	"/visual": {
		"agent": "visual_qa",
		"description": "Visual task requiring before/after screenshots.",
		"requires_project_index": true,
		"requires_context": true,
		"phase": 6,
	},
	"/visual3d": {
		"agent": "asset_3d_review",
		"description": "Review selected 3D node from 6 orthographic angles.",
		"requires_project_index": false,
		"requires_context": false,
		"phase": 1,
	},
	"/fixlogs": {
		"agent": "debug",
		"description": "Aggregate last run's errors and propose a batched fix plan.",
		"requires_project_index": false,
		"requires_context": false,
		"phase": 1,
	},
	"/visualmap": {
		"agent": "visual_map",
		"description": "Apply neon colors to all nodes, capture screenshot, send to AI for spatial analysis.",
		"requires_project_index": false,
		"requires_context": true,
		"phase": 1,
	},
	"/neon": {
		"agent": "visual_map",
		"description": "Alias for /visualmap.",
		"requires_project_index": false,
		"requires_context": true,
		"phase": 1,
	},
	"/visualize": {
		"agent": "visual_map",
		"description": "Alias for /visualmap.",
		"requires_project_index": false,
		"requires_context": true,
		"phase": 1,
	},
	"/validate": {
		"agent": "mechanics_qa",
		"description": "Run validation scenes and report pass/fail.",
		"requires_project_index": true,
		"requires_context": true,
		"phase": 8,
	},
	"/scene": {
		"agent": "scene_inspector",
		"description": "Explain current scene.",
		"requires_project_index": false,
		"requires_context": true,
		"phase": 1,
	},
	"/node": {
		"agent": "scene_inspector",
		"description": "Explain selected node.",
		"requires_project_index": false,
		"requires_context": true,
		"phase": 1,
	},
	"/audit": {
		"agent": "asset",
		"description": "Full project health audit.",
		"requires_project_index": true,
		"requires_context": true,
		"phase": 2,
	},
	"/diff": {
		"agent": "diff_viewer",
		"description": "Show current file diffs.",
		"requires_project_index": false,
		"requires_context": false,
		"phase": 4,
	},
	"/revert": {
		"agent": "revert",
		"description": "Revert last task's changes.",
		"requires_project_index": false,
		"requires_context": false,
		"phase": 4,
	},
	"/refactor": {
		"agent": "refactor",
		"description": "Clean code without breaking behavior.",
		"requires_project_index": true,
		"requires_context": true,
		"phase": 4,
	},
	"/screenshot": {
		"agent": "screenshot",
		"description": "Capture editor or viewport screenshot.",
		"requires_project_index": false,
		"requires_context": false,
		"phase": 6,
	},
	"/compare": {
		"agent": "visual_qa",
		"description": "Compare before/after screenshots.",
		"requires_project_index": false,
		"requires_context": false,
		"phase": 7,
	},
	"/memory": {
		"agent": "memory",
		"description": "Show project memory.",
		"requires_project_index": false,
		"requires_context": false,
		"phase": 1,
	},
	"/remember": {
		"agent": "memory_write",
		"description": "Write a fact to project memory.",
		"requires_project_index": false,
		"requires_context": false,
		"phase": 1,
	},
	"/queue": {
		"agent": "task_queue",
		"description": "Show and manage task queue.",
		"requires_project_index": false,
		"requires_context": false,
		"phase": 1,
	},
	"/settings": {
		"agent": "settings",
		"description": "Open settings panel.",
		"requires_project_index": false,
		"requires_context": false,
		"phase": 1,
	},
	"/explain": {
		"agent": "architect",
		"description": "Explain how something works in the codebase.",
		"requires_project_index": true,
		"requires_context": true,
		"phase": 1,
	},
}


static func get_command_info(cmd: String) -> Dictionary:
	return SLASH_COMMANDS.get(cmd, {})


static func is_implemented(cmd: String) -> bool:
	var info := get_command_info(cmd)
	if info.is_empty():
		return false
	return info.get("phase", 99) <= 4


static func get_unimplemented_message(cmd: String) -> String:
	var info := get_command_info(cmd)
	if info.is_empty():
		return "Unknown command: " + cmd
	return "%s is planned for Phase %d. Use /plan for now." % [cmd, info.get("phase", "?")]


static func build_system_context_header(project_name: String, approal_mode: String) -> String:
	return (
		"You are GoDotter, an AI game development assistant embedded inside the Godot 4 editor.\n"
		+ "Project: " + project_name + "\n"
		+ "Approval mode: " + approal_mode + "\n"
		+ "Infer game genre, mechanics, and style from project files, scenes, and memory — stay faithful to what exists.\n"
		+ "Always read project memory before planning. Never make up file paths.\n"
		+ "Always respond with structured JSON matching the requested schema.\n"
	)
