@tool
extends RefCounted

## Deep-scans a .tscn file by parsing its text format.
## Extracts: node hierarchy, script refs, ext_resource refs, signals,
## missing paths, broken references, and layout anomalies.

const IGNORE_DIRS := [".godot"]


func scan_scene(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "File not found: " + path}

	var text := FileAccess.get_file_as_string(path)
	var result := {
		"path": path,
		"nodes": [],
		"ext_resources": [],
		"sub_resources": [],
		"signals": [],
		"missing_scripts": [],
		"missing_resources": [],
		"issues": [],
		"node_count": 0,
	}

	_parse_scene_text(text, result)
	_detect_issues(result)

	return result


func _parse_scene_text(text: String, result: Dictionary) -> void:
	var lines := text.split("\n")
	var current_node: Dictionary = {}

	for line in lines:
		line = line.strip_edges()

		# ext_resource line
		if line.begins_with("[ext_resource "):
			var res := _parse_header_line(line)
			result["ext_resources"].append(res)

			# Check if resource file exists
			var rpath: String = res.get("path", "")
			if rpath != "" and not FileAccess.file_exists(rpath):
				result["missing_resources"].append(rpath)

		# sub_resource
		elif line.begins_with("[sub_resource "):
			var res := _parse_header_line(line)
			result["sub_resources"].append(res)

		# node
		elif line.begins_with("[node "):
			if not current_node.is_empty():
				result["nodes"].append(current_node)
			current_node = _parse_header_line(line)
			current_node["properties"] = {}

			# Check script reference
			var script_id: String = current_node.get("script", "")
			if script_id != "":
				var script_path := _resolve_ext_resource_path(result["ext_resources"], script_id)
				if script_path != "" and not FileAccess.file_exists(script_path):
					result["missing_scripts"].append({
						"node": current_node.get("name", "?"),
						"script": script_path,
					})

		# Signal connection line
		elif line.begins_with("[connection "):
			var conn := _parse_header_line(line)
			result["signals"].append(conn)

		# Property assignment (inside a node block)
		elif "=" in line and not current_node.is_empty():
			var parts := line.split("=", false, 1)
			if parts.size() == 2:
				current_node["properties"][parts[0].strip_edges()] = parts[1].strip_edges()

	# Don't forget the last node
	if not current_node.is_empty():
		result["nodes"].append(current_node)

	result["node_count"] = result["nodes"].size()


func _parse_header_line(line: String) -> Dictionary:
	# Parses: [node name="Foo" type="Bar" parent="." script=ExtResource("1_abc")]
	var result := {}
	var content := line.lstrip("[").rstrip("]")
	var kv_regex := RegEx.new()
	kv_regex.compile(r'(\w+)\s*=\s*"([^"]*)"')
	for match in kv_regex.search_all(content):
		result[match.get_string(1)] = match.get_string(2)
	# Also catch unquoted values
	var unquoted_regex := RegEx.new()
	unquoted_regex.compile(r'(\w+)\s*=\s*([^\s"]+)')
	for match in unquoted_regex.search_all(content):
		if not result.has(match.get_string(1)):
			result[match.get_string(1)] = match.get_string(2)
	return result


func _resolve_ext_resource_path(ext_resources: Array, resource_id: String) -> String:
	# ext_resource id might be bare "1" or "1_xyz"
	for res in ext_resources:
		if res.get("id", "") == resource_id:
			return res.get("path", "")
	return ""


func _detect_issues(result: Dictionary) -> void:
	var issues: Array = result["issues"]

	if result["missing_scripts"].size() > 0:
		issues.append({
			"type": "missing_script",
			"count": result["missing_scripts"].size(),
			"paths": result["missing_scripts"],
		})

	if result["missing_resources"].size() > 0:
		issues.append({
			"type": "missing_resource",
			"count": result["missing_resources"].size(),
			"paths": result["missing_resources"],
		})

	# Detect duplicate node names at same level — simplified check
	var names := {}
	for node in result["nodes"]:
		var parent: String = node.get("parent", ".")
		var name: String = node.get("name", "")
		var key := parent + "/" + name
		if names.has(key):
			issues.append({
				"type": "duplicate_node_name",
				"node": name,
				"parent": parent,
			})
		else:
			names[key] = true

	# Detect nodes with visibility=false that might be bugs
	for node in result["nodes"]:
		var props: Dictionary = node.get("properties", {})
		if props.get("visible", "true") == "false":
			issues.append({
				"type": "node_invisible",
				"node": node.get("name", "?"),
				"note": "Node is hidden — may be intentional or a bug",
			})


func scan_open_scene() -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": "No scene open"}
	var path := root.scene_file_path
	if path == "":
		return {"error": "Scene has not been saved yet"}
	return scan_scene(path)


func get_node_tree_summary(root: Node, depth: int = 0, max_depth: int = 4) -> Dictionary:
	if depth > max_depth:
		return {}
	var summary := {
		"name": root.name,
		"class": root.get_class(),
		"script": "",
		"children": [],
	}
	if root.get_script():
		summary["script"] = root.get_script().resource_path
	for child in root.get_children():
		summary["children"].append(get_node_tree_summary(child, depth + 1, max_depth))
	return summary
