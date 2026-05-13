@tool
extends RefCounted

## Phase 4: File diff management.
## Creates backups before edits, shows before/after diffs,
## and provides reliable revert capability.
##
## Edits are always server-side (via AgentClient → backend code_tools.py).
## DiffManager on the plugin side handles:
##   - Backup path resolution
##   - Tracking which files were modified per task
##   - UI-facing diff retrieval

signal backup_created(original_path: String, backup_path: String)
signal file_reverted(path: String)
signal diff_ready(path: String, diff_text: String)

var _state: Object  # ForgeState
# task_id -> [{path, backup_path, diff_text}]
var _task_edits: Dictionary = {}


func setup(state: Object) -> void:
	_state = state


# --- Backup path convention ---

func get_backup_path(original_path: String, task_id: String) -> String:
	var forge_base := ProjectSettings.globalize_path("res://") + ".godot_forge/backups/"
	var safe_name := original_path.replace("res://", "").replace("/", "__").replace("\\", "__")
	return forge_base + task_id + "/" + safe_name + ".bak"


func get_backup_dir(task_id: String) -> String:
	return ProjectSettings.globalize_path("res://") + ".godot_forge/backups/" + task_id + "/"


# --- Track an edit that was applied by the backend ---

func record_edit(task_id: String, path: String, backup_path: String, diff_text: String) -> void:
	if not _task_edits.has(task_id):
		_task_edits[task_id] = []
	_task_edits[task_id].append({
		"path": path,
		"backup_path": backup_path,
		"diff_text": diff_text,
		"timestamp": Time.get_unix_time_from_system(),
	})
	diff_ready.emit(path, diff_text)


func get_task_edits(task_id: String) -> Array:
	return _task_edits.get(task_id, [])


func get_all_modified_files(task_id: String) -> Array:
	var result: Array = []
	for edit in _task_edits.get(task_id, []):
		result.append(edit.get("path", ""))
	return result


func get_diff_for_file(task_id: String, path: String) -> String:
	for edit in _task_edits.get(task_id, []):
		if edit.get("path", "") == path:
			return edit.get("diff_text", "")
	return ""


# --- Local read file helper ---

func read_file_safe(path: String) -> Dictionary:
	var abs_path := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	if not FileAccess.file_exists(abs_path):
		return {"ok": false, "error": "File not found: " + path}
	var content := FileAccess.get_file_as_string(abs_path)
	return {"ok": true, "content": content, "path": path}


# --- Local backup creation (for client-side protection) ---

func create_local_backup(path: String, task_id: String) -> String:
	var abs_path := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	if not FileAccess.file_exists(abs_path):
		return ""
	var backup_path := get_backup_path(path, task_id)
	DirAccess.make_dir_recursive_absolute(get_backup_dir(task_id))
	var content := FileAccess.get_file_as_bytes(abs_path)
	var backup_file := FileAccess.open(backup_path, FileAccess.WRITE)
	if backup_file:
		backup_file.store_buffer(content)
		backup_file.close()
		backup_created.emit(path, backup_path)
		return backup_path
	return ""


# --- Local revert from backup ---

func revert_file_local(path: String, task_id: String) -> bool:
	var backup_path := get_backup_path(path, task_id)
	if not FileAccess.file_exists(backup_path):
		# Try any backup for this path
		backup_path = _find_latest_backup(path)
		if backup_path.is_empty():
			push_error("[DiffManager] No backup found for: " + path)
			return false

	var abs_path := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	var backup_content := FileAccess.get_file_as_bytes(backup_path)
	var out_file := FileAccess.open(abs_path, FileAccess.WRITE)
	if out_file:
		out_file.store_buffer(backup_content)
		out_file.close()
		file_reverted.emit(path)
		return true
	return false


func _find_latest_backup(path: String) -> String:
	var base := ProjectSettings.globalize_path("res://") + ".godot_forge/backups/"
	var safe_name := path.replace("res://", "").replace("/", "__").replace("\\", "__")
	var dir := DirAccess.open(base)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var latest := ""
	var latest_time := 0
	var fname := dir.get_next()
	while fname != "":
		if dir.current_is_dir():
			var candidate := base + fname + "/" + safe_name + ".bak"
			if FileAccess.file_exists(candidate):
				var info := FileAccess.get_modified_time(candidate)
				if int(info) > latest_time:
					latest_time = int(info)
					latest = candidate
		fname = dir.get_next()
	dir.list_dir_end()
	return latest


# --- Simple unified diff generator (for display, not application) ---

func compute_simple_diff(original: String, modified: String, path: String) -> String:
	var orig_lines := original.split("\n")
	var mod_lines := modified.split("\n")
	var out := "--- " + path + " (original)\n"
	out += "+++ " + path + " (modified)\n"
	var min_lines := min(orig_lines.size(), mod_lines.size())
	var changes := 0
	for i in min_lines:
		if orig_lines[i] != mod_lines[i]:
			out += "@@ line %d @@\n" % (i + 1)
			out += "- " + orig_lines[i] + "\n"
			out += "+ " + mod_lines[i] + "\n"
			changes += 1
	for i in range(min_lines, orig_lines.size()):
		out += "- " + orig_lines[i] + "\n"
		changes += 1
	for i in range(min_lines, mod_lines.size()):
		out += "+ " + mod_lines[i] + "\n"
		changes += 1
	if changes == 0:
		out += "(no changes)\n"
	return out
