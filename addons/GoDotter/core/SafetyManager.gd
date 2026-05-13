@tool
extends RefCounted

## Safety gate for all agent actions.
## Checks approval mode, operation risk level, and dangerous path patterns.
## Every file edit, scene edit, or command execution must pass through here.

var _state: Object  # ForgeState

const APPROVAL_MODES := ["review", "assisted", "autopilot", "yolo"]

const DANGEROUS_PATTERNS := [
	".godot/",
	"addons/",
	"project.godot",
	".import",
	".godot_forge/",
]

const DANGEROUS_OPERATIONS := [
	"delete_file",
	"rename_folder",
	"modify_addon",
	"modify_project_godot",
	"modify_import",
	"run_shell_command",
	"install_dependency",
	"change_git_branch",
	"reset_git",
	"revert_many_files",
]


func setup(state: Object) -> void:
	_state = state


func check_file_edit(path: String) -> Dictionary:
	var mode := _get_mode()

	if _is_dangerous_path(path):
		return {
			"allowed": false,
			"reason": "Path is in a protected location: " + path,
			"requires_approval": true,
		}

	match mode:
		"review":
			return {"allowed": false, "reason": "Review mode: all edits require human approval.", "requires_approval": true}
		"assisted":
			return {"allowed": true, "reason": "Assisted mode: file edit allowed.", "requires_approval": false}
		"autopilot", "yolo":
			return {"allowed": true, "reason": "Autopilot mode: file edit allowed.", "requires_approval": false}

	return {"allowed": false, "reason": "Unknown approval mode.", "requires_approval": true}


func check_operation(operation: String, details: Dictionary = {}) -> Dictionary:
	var mode := _get_mode()

	if operation in DANGEROUS_OPERATIONS:
		if mode == "yolo":
			return {
				"allowed": true,
				"reason": "YOLO mode: dangerous operation allowed.",
				"requires_approval": false,
				"warning": "YOLO mode is active. Dangerous operation permitted.",
			}
		return {
			"allowed": false,
			"reason": "Dangerous operation requires explicit approval: " + operation,
			"requires_approval": true,
		}

	return {"allowed": true, "reason": "Operation permitted.", "requires_approval": false}


func check_scene_edit(scene_path: String) -> Dictionary:
	var mode := _get_mode()

	if _is_dangerous_path(scene_path):
		return {
			"allowed": false,
			"reason": "Scene is in a protected location: " + scene_path,
			"requires_approval": true,
		}

	match mode:
		"review", "assisted":
			return {
				"allowed": false,
				"reason": "Scene edits require approval in " + mode + " mode.",
				"requires_approval": true,
			}
		"autopilot", "yolo":
			return {"allowed": true, "reason": "Scene edit allowed.", "requires_approval": false}

	return {"allowed": false, "reason": "Unknown mode.", "requires_approval": true}


func is_yolo_mode() -> bool:
	return _get_mode() == "yolo"


func _get_mode() -> String:
	if _state:
		return _state.settings.get("approval_mode", "review")
	return "review"


func _is_dangerous_path(path: String) -> bool:
	var normalized := path.replace("\\", "/")
	for pattern in DANGEROUS_PATTERNS:
		if pattern in normalized:
			return true
	return false


func get_current_mode_description() -> String:
	match _get_mode():
		"review":
			return "Review: AI plans only. You approve every edit."
		"assisted":
			return "Assisted: AI edits files, but scene edits and dangerous ops need approval."
		"autopilot":
			return "Autopilot: AI plans, edits, runs, and validates. Still blocks on dangerous ops."
		"yolo":
			return "YOLO: AI has broad permissions. Git checkpoint always created first."
	return "Unknown mode"
