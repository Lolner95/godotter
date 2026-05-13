@tool
extends RefCounted

## Scans the Godot project filesystem and produces a structured project index.
## Used locally (in GDScript) for fast context gathering.
## A richer backend version lives in tools/godot_forge_agent/src/project_indexer.py.

var _state: Object  # ForgeState

const SCENE_EXT := "tscn"
const SCRIPT_EXT := "gd"
const RESOURCE_EXTS := ["tres", "res"]
const TEXTURE_EXTS := ["png", "jpg", "jpeg", "webp", "svg", "bmp"]
const AUDIO_EXTS := ["ogg", "wav", "mp3"]
const SHADER_EXT := "gdshader"
const THEME_EXT := "theme"
const FONT_EXTS := ["ttf", "otf", "fnt"]


func setup(state: Object) -> void:
	_state = state


func scan_project() -> Dictionary:
	var index := {
		"scanned_at": Time.get_unix_time_from_system(),
		"project_path": "res://",
		"scenes": [],
		"scripts": [],
		"resources": [],
		"textures": [],
		"audio": [],
		"shaders": [],
		"themes": [],
		"fonts": [],
		"autoloads": [],
		"input_actions": [],
		"addons": [],
		"scene_count": 0,
		"script_count": 0,
		"resource_count": 0,
		"missing_resource_count": 0,
		"errors": [],
	}

	_scan_directory("res://", index)
	_collect_autoloads(index)
	_collect_input_map(index)
	_collect_addons(index)

	index["scene_count"] = index["scenes"].size()
	index["script_count"] = index["scripts"].size()
	index["resource_count"] = index["resources"].size()

	if _state:
		_state.project_index = index
		_state.index_last_updated = Time.get_unix_time_from_system()

	return index


func _scan_directory(path: String, index: Dictionary) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.begins_with("."):
			fname = dir.get_next()
			continue

		var full_path := path + fname
		if dir.current_is_dir():
			# Skip .godot import cache and addons (we handle addons separately)
			if fname == ".godot":
				fname = dir.get_next()
				continue
			_scan_directory(full_path + "/", index)
		else:
			_classify_file(full_path, index)

		fname = dir.get_next()
	dir.list_dir_end()


func _classify_file(path: String, index: Dictionary) -> void:
	var ext := path.get_extension().to_lower()

	match ext:
		SCENE_EXT:
			var entry := _make_file_entry(path)
			entry["node_count"] = _count_nodes_in_scene(path)
			index["scenes"].append(entry)
		SCRIPT_EXT:
			var entry := _make_file_entry(path)
			entry["class_name"] = _extract_class_name(path)
			index["scripts"].append(entry)
		"tres", "res":
			index["resources"].append(_make_file_entry(path))
		"png", "jpg", "jpeg", "webp", "svg", "bmp":
			index["textures"].append(_make_file_entry(path))
		"ogg", "wav", "mp3":
			index["audio"].append(_make_file_entry(path))
		SHADER_EXT:
			index["shaders"].append(_make_file_entry(path))
		THEME_EXT:
			index["themes"].append(_make_file_entry(path))
		"ttf", "otf", "fnt":
			index["fonts"].append(_make_file_entry(path))


func _make_file_entry(path: String) -> Dictionary:
	return {
		"path": path,
		"name": path.get_file(),
		"size": FileAccess.get_file_as_bytes(path).size() if FileAccess.file_exists(path) else 0,
	}


func _count_nodes_in_scene(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	var text := FileAccess.get_file_as_string(path)
	var count := 0
	for line in text.split("\n"):
		if line.begins_with("[node "):
			count += 1
	return count


func _extract_class_name(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var line_count := 0
	while not file.eof_reached() and line_count < 20:
		var line := file.get_line()
		line_count += 1
		if line.begins_with("class_name "):
			return line.substr(11).strip_edges()
	return ""


func _collect_autoloads(index: Dictionary) -> void:
	var props := ProjectSettings.get_property_list()
	for prop in props:
		if prop.name.begins_with("autoload/"):
			var name: String = str(prop.name).substr(9)
			var val: String = str(ProjectSettings.get_setting(prop.name, ""))
			index["autoloads"].append({"name": name, "path": val.lstrip("*")})


func _collect_input_map(index: Dictionary) -> void:
	var actions := InputMap.get_actions()
	for action in actions:
		if not action.begins_with("ui_"):
			index["input_actions"].append(str(action))


func _collect_addons(index: Dictionary) -> void:
	var dir := DirAccess.open("res://addons")
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not fname.begins_with(".") and dir.current_is_dir():
			index["addons"].append(fname)
		fname = dir.get_next()
	dir.list_dir_end()


func get_compact_summary() -> Dictionary:
	if not _state or _state.project_index.is_empty():
		return {"error": "Project not indexed. Run index first."}
	var idx: Dictionary = _state.project_index
	var autoload_names: Array = []
	for a in idx.get("autoloads", []):
		if a is Dictionary:
			autoload_names.append(a.get("name", ""))
	return {
		"scene_count": idx.get("scene_count", 0),
		"script_count": idx.get("script_count", 0),
		"resource_count": idx.get("resource_count", 0),
		"autoloads": autoload_names,
		"addons": idx.get("addons", []),
		"top_scenes": _top_n(idx.get("scenes", []), 10),
		"top_scripts": _top_n(idx.get("scripts", []), 20),
	}


func _top_n(arr: Array, n: int) -> Array:
	var result: Array = []
	for i in min(n, arr.size()):
		result.append(arr[i].get("path", ""))
	return result
