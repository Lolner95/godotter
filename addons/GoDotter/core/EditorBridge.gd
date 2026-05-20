@tool
extends RefCounted

## Collects live editor context: current scene, selected node, filesystem summary,
## autoloads, input map, open scripts. Used to build the context bundle sent to the AI.

var _state: Object  # ForgeState


func setup(state: Object) -> void:
	_state = state


# --- Scene ---

func get_current_scene_path() -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return ""
	return root.scene_file_path


func get_current_scene_root_summary() -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {}
	return {
		"scene_path": root.scene_file_path,
		"root_node_name": root.name,
		"root_node_class": root.get_class(),
		"child_count": root.get_child_count(),
		"children_summary": _summarize_children(root, 0, 3),
	}


func _summarize_children(node: Node, depth: int, max_depth: int, max_siblings: int = 18) -> Array:
	if depth > max_depth:
		return []
	var result: Array = []
	var n := 0
	for child in node.get_children():
		if n >= max_siblings:
			break
		n += 1
		var entry := {
			"name": child.name,
			"class": child.get_class(),
			"script": _get_script_path(child),
		}
		if depth < max_depth and child.get_child_count() > 0:
			entry["children"] = _summarize_children(child, depth + 1, max_depth, max_siblings)
		result.append(entry)
	return result


# --- Selection ---

func get_selected_nodes_summary() -> Array:
	var selection := EditorInterface.get_selection()
	var nodes := selection.get_selected_nodes()
	var result: Array = []
	for node in nodes:
		result.append({
			"name": node.name,
			"class": node.get_class(),
			"path": str(node.get_path()),
			"script": _get_script_path(node),
		})
	return result


func get_selected_node_deep_summary() -> Dictionary:
	var selection := EditorInterface.get_selection()
	var nodes := selection.get_selected_nodes()
	if nodes.is_empty():
		return {"error": "No node selected"}
	return _deep_node_summary(nodes[0])


func _deep_node_summary(node: Node) -> Dictionary:
	var summary := {
		"name": node.name,
		"class": node.get_class(),
		"path": str(node.get_path()),
		"parent_path": str(node.get_parent().get_path()) if node.get_parent() else "",
		"children_count": node.get_child_count(),
		"script": _get_script_path(node),
		"groups": node.get_groups(),
		"signals_connected": _get_connected_signals(node),
		"exported_properties": _get_exported_properties(node),
	}

	# Class-specific properties
	match node.get_class():
		"Control", _ when node is Control:
			summary["control"] = _summarize_control(node as Control)
		"Node2D", _ when node is Node2D:
			summary["node2d"] = _summarize_node2d(node as Node2D)
		"Node3D", _ when node is Node3D:
			summary["node3d"] = _summarize_node3d(node as Node3D)

	if node is AnimationPlayer:
		summary["animations"] = (node as AnimationPlayer).get_animation_list()

	if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
		summary["audio"] = _summarize_audio(node)

	return summary


func _summarize_control(ctrl: Control) -> Dictionary:
	return {
		"anchor_left": ctrl.anchor_left,
		"anchor_top": ctrl.anchor_top,
		"anchor_right": ctrl.anchor_right,
		"anchor_bottom": ctrl.anchor_bottom,
		"size": {"x": ctrl.size.x, "y": ctrl.size.y},
		"custom_minimum_size": {"x": ctrl.custom_minimum_size.x, "y": ctrl.custom_minimum_size.y},
		"size_flags_horizontal": ctrl.size_flags_horizontal,
		"size_flags_vertical": ctrl.size_flags_vertical,
		"mouse_filter": ctrl.mouse_filter,
		"z_index": ctrl.z_index,
		"visible": ctrl.visible,
		"theme": str(ctrl.theme) if ctrl.theme else null,
	}


func _summarize_node2d(n: Node2D) -> Dictionary:
	return {
		"position": {"x": n.position.x, "y": n.position.y},
		"rotation_degrees": rad_to_deg(n.rotation),
		"scale": {"x": n.scale.x, "y": n.scale.y},
		"z_index": n.z_index,
		"visible": n.visible,
	}


func _summarize_node3d(n: Node3D) -> Dictionary:
	return {
		"position": {"x": n.position.x, "y": n.position.y, "z": n.position.z},
		"rotation_degrees": {
			"x": rad_to_deg(n.rotation.x),
			"y": rad_to_deg(n.rotation.y),
			"z": rad_to_deg(n.rotation.z),
		},
		"scale": {"x": n.scale.x, "y": n.scale.y, "z": n.scale.z},
		"visible": n.visible,
	}


func _summarize_audio(node: Node) -> Dictionary:
	var d := {}
	if node.get("stream"):
		d["stream"] = str(node.get("stream"))
	if node.get("volume_db") != null:
		d["volume_db"] = node.get("volume_db")
	if node.get("autoplay") != null:
		d["autoplay"] = node.get("autoplay")
	return d


func _get_exported_properties(node: Node) -> Array:
	var result: Array = []
	var props := node.get_property_list()
	for prop in props:
		if prop.usage & PROPERTY_USAGE_EDITOR and prop.usage & PROPERTY_USAGE_STORAGE:
			var value = node.get(prop.name)
			if value != null:
				result.append({"name": prop.name, "type": prop.type, "value": str(value)})
	return result.slice(0, 30)  # cap to avoid huge payloads


func _get_connected_signals(node: Node) -> Array:
	var result: Array = []
	for sig in node.get_signal_list():
		var connections := node.get_signal_connection_list(sig.name)
		for conn in connections:
			result.append({
				"signal": sig.name,
				"target": str(conn.callable),
			})
	return result


func _get_script_path(node: Node) -> String:
	if node.get_script() == null:
		return ""
	var script = node.get_script()
	if script is Script:
		return script.resource_path
	return ""


# --- Open scripts ---

func get_open_scripts() -> Array:
	var result: Array = []
	var se := EditorInterface.get_script_editor()
	if se == null:
		return result
	for script in se.get_open_scripts():
		if script and script.resource_path != "":
			result.append(script.resource_path)
	return result


# --- Project settings ---

func get_project_settings_summary() -> Dictionary:
	return {
		"name": ProjectSettings.get_setting("application/config/name", ""),
		"description": ProjectSettings.get_setting("application/config/description", ""),
		"main_scene": ProjectSettings.get_setting("application/run/main_scene", ""),
	}


# --- Autoloads ---

func get_autoloads_summary() -> Array:
	var result: Array = []
	for i in range(ProjectSettings.get_setting("autoload", {}).size() if ProjectSettings.has_setting("autoload") else 0):
		pass
	# Godot 4 exposes autoloads via ProjectSettings with "autoload/*" keys
	var props := ProjectSettings.get_property_list()
	for prop: Dictionary in props:
		if prop.get("name", "").begins_with("autoload/"):
			var pname: String = str(prop.get("name", ""))
			var autoload_name: String = pname.substr(9)
			result.append({
				"name": autoload_name,
				"path": str(ProjectSettings.get_setting(pname, "")),
			})
	return result


# --- Input map ---

func get_input_map_summary() -> Array:
	var result: Array = []
	var actions := InputMap.get_actions()
	for action in actions:
		if action.begins_with("ui_"):
			continue
		result.append(action)
	return result


# --- Filesystem ---

func get_filesystem_summary() -> Dictionary:
	var fs := EditorInterface.get_resource_filesystem()
	var root_dir := fs.get_filesystem()
	if root_dir == null:
		return {}
	return {
		"total_files": _count_files(root_dir),
		"scan_progress": fs.get_scanning_progress(),
	}


func _count_files(dir: EditorFileSystemDirectory) -> int:
	var count := dir.get_file_count()
	for i in range(dir.get_subdir_count()):
		count += _count_files(dir.get_subdir(i))
	return count


func get_recently_modified_files(max_count: int = 20) -> Array:
	# Returns res:// paths of recently modified .gd/.tscn files
	# Using file system scan — best-effort in editor context
	var result: Array = []
	var dir := DirAccess.open("res://")
	if dir:
		_scan_recent_files(dir, result, max_count)
	return result


func _scan_recent_files(dir: DirAccess, result: Array, max_count: int) -> void:
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "" and result.size() < max_count:
		if fname.begins_with(".") or fname == "addons":
			fname = dir.get_next()
			continue
		if dir.current_is_dir():
			var sub := DirAccess.open(dir.get_current_dir() + "/" + fname)
			if sub:
				_scan_recent_files(sub, result, max_count)
		else:
			var ext := fname.get_extension()
			if ext in ["gd", "tscn", "tres", "gdshader"]:
				result.append(dir.get_current_dir() + "/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


# --- Script previews for the context engine (bounded) ---

const _PREVIEW_MAX_FILES := 5
const _PREVIEW_MAX_LINES := 110


func _read_text_head(path: String, max_lines: int) -> String:
	if path.is_empty() or not path.begins_with("res://"):
		return ""
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var acc := PackedStringArray()
	var i := 0
	while not f.eof_reached() and i < max_lines:
		acc.append(f.get_line())
		i += 1
	f.close()
	return "\n".join(acc)


func _collect_scene_tree_script_paths(scene: Dictionary, maxn: int = 28) -> Array[String]:
	var out: Array[String] = []
	var ch: Variant = scene.get("children_summary", [])
	_collect_script_paths_recursive(ch, out, maxn)
	return out


func _collect_script_paths_recursive(children: Variant, out: Array[String], maxn: int) -> void:
	if out.size() >= maxn:
		return
	if not (children is Array):
		return
	for ch in children:
		if out.size() >= maxn:
			return
		if ch is Dictionary:
			var sp: String = str(ch.get("script", ""))
			if sp.begins_with("res://") and not out.has(sp):
				out.append(sp)
			_collect_script_paths_recursive(ch.get("children", []), out, maxn)


func _append_unique_script_path(ordered: Array[String], seen: Dictionary, p: String) -> void:
	if p.is_empty() or not p.begins_with("res://"):
		return
	if seen.has(p):
		return
	seen[p] = true
	ordered.append(p)


func _build_script_previews() -> Dictionary:
	var ordered: Array[String] = []
	var seen: Dictionary = {}

	for p in get_open_scripts():
		_append_unique_script_path(ordered, seen, str(p))

	var sel_deep := get_selected_node_deep_summary()
	if not sel_deep.has("error"):
		_append_unique_script_path(ordered, seen, str(sel_deep.get("script", "")))

	for n in get_selected_nodes_summary():
		if n is Dictionary:
			_append_unique_script_path(ordered, seen, str(n.get("script", "")))

	var scene := get_current_scene_root_summary()
	if not scene.is_empty():
		for p in _collect_scene_tree_script_paths(scene):
			_append_unique_script_path(ordered, seen, str(p))

	var previews := {}
	var count := 0
	for i in range(ordered.size()):
		if count >= _PREVIEW_MAX_FILES:
			break
		var path: String = str(ordered[i])
		var body := _read_text_head(path, _PREVIEW_MAX_LINES)
		if body.is_empty():
			continue
		previews[path] = body
		count += 1
	return previews


# --- Full context bundle ---

func build_context_bundle() -> Dictionary:
	var scene := get_current_scene_root_summary()
	var tree_scripts: Array[String] = []
	if not scene.is_empty():
		tree_scripts = _collect_scene_tree_script_paths(scene)

	var bundle := {
		"current_scene": scene,
		"selected_node": get_selected_node_deep_summary(),
		"selected_nodes": get_selected_nodes_summary(),
		"open_scripts": get_open_scripts(),
		"recent_files": get_recently_modified_files(28),
		"scene_tree_script_paths": tree_scripts,
		"script_previews": _build_script_previews(),
		"autoloads": get_autoloads_summary(),
		"input_actions": get_input_map_summary(),
		"project_settings": get_project_settings_summary(),
		"filesystem": get_filesystem_summary(),
		"engine": Engine.get_version_info(),
		"godot_executable": OS.get_executable_path(),
	}
	if _state:
		bundle["project_root_global"] = str(_state.project_root)
	return bundle
