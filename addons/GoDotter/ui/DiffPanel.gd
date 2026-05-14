@tool
extends Control

## Phase 4: Diff viewer panel.
## Shows colored unified diffs (green = added, red = removed, gray = context).
## Each task can have multiple file diffs; an expandable tree on the left lets you
## inspect previews (Cursor/VSCode-like) and open full file diffs on the right.

signal revert_requested(task_id: String, path: String)
signal approve_requested(task_id: String)

var _state: Object  # ForgeState
var _diff_manager: Object  # DiffManager

var _current_task_id: String = ""
var _current_file_path: String = ""

# UI nodes (built in _ready)
var _file_tree: Tree
var _diff_display: RichTextLabel
var _status_label: Label
var _approve_btn: Button
var _revert_btn: Button
var _revert_file_btn: Button
var _expanded_files: Dictionary = {}  # path -> bool


func _ready() -> void:
	_build_ui()


func setup(state: Object, diff_manager: Object) -> void:
	_state = state
	_diff_manager = diff_manager
	if _diff_manager:
		_diff_manager.diff_ready.connect(_on_diff_ready)
		_diff_manager.file_reverted.connect(_on_file_reverted)


func _build_ui() -> void:
	custom_minimum_size = Vector2(260, 200)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# Header
	var header := HBoxContainer.new()
	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.text = "No diffs yet"
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_status_label)

	_approve_btn = Button.new()
	_approve_btn.text = "Approve All"
	_approve_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	_approve_btn.add_theme_font_size_override("font_size", 12)
	_approve_btn.visible = false
	_approve_btn.pressed.connect(_on_approve_all)
	header.add_child(_approve_btn)

	_revert_btn = Button.new()
	_revert_btn.text = "Revert Task"
	_revert_btn.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
	_revert_btn.add_theme_font_size_override("font_size", 12)
	_revert_btn.visible = false
	_revert_btn.pressed.connect(_on_revert_task)
	header.add_child(_revert_btn)
	root.add_child(header)

	# Main split: file list + diff content
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 140
	root.add_child(split)

	# File tree
	var list_vbox := VBoxContainer.new()
	list_vbox.custom_minimum_size.x = 120
	var list_lbl := Label.new()
	list_lbl.text = "Changed Files"
	list_lbl.add_theme_font_size_override("font_size", 12)
	list_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	list_vbox.add_child(list_lbl)

	_file_tree = Tree.new()
	_file_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_file_tree.add_theme_font_size_override("font_size", 12)
	_file_tree.columns = 1
	_file_tree.hide_root = true
	_file_tree.select_mode = Tree.SELECT_SINGLE
	_file_tree.item_selected.connect(_on_file_tree_selected)
	_file_tree.item_collapsed.connect(_on_file_tree_item_collapsed)
	list_vbox.add_child(_file_tree)

	_revert_file_btn = Button.new()
	_revert_file_btn.text = "Revert File"
	_revert_file_btn.add_theme_font_size_override("font_size", 12)
	_revert_file_btn.add_theme_color_override("font_color", Color(0.9, 0.6, 0.2))
	_revert_file_btn.visible = false
	_revert_file_btn.pressed.connect(_on_revert_file)
	list_vbox.add_child(_revert_file_btn)
	split.add_child(list_vbox)

	# Diff display
	var diff_scroll := ScrollContainer.new()
	diff_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_diff_display = RichTextLabel.new()
	_diff_display.bbcode_enabled = true
	_diff_display.fit_content = true
	_diff_display.selection_enabled = true
	_diff_display.context_menu_enabled = true
	_diff_display.focus_mode = Control.FOCUS_CLICK
	_diff_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_diff_display.autowrap_mode = TextServer.AUTOWRAP_OFF
	_diff_display.add_theme_font_size_override("font_size", 14)
	_diff_display.text = "[color=#555]Select a file to view its diff.[/color]"
	diff_scroll.add_child(_diff_display)
	split.add_child(diff_scroll)


func show_task_diffs(task_id: String) -> void:
	_current_task_id = task_id
	_rebuild_file_tree([])
	_diff_display.text = "[color=#555]Select a file to view its diff.[/color]"
	_current_file_path = ""

	if not _diff_manager:
		_status_label.text = "DiffManager not initialized"
		return

	var edits: Array = _diff_manager.get_task_edits(task_id) as Array
	if edits.is_empty():
		_status_label.text = "No edits for task " + task_id
		_approve_btn.visible = false
		_revert_btn.visible = false
		return

	_status_label.text = "%d file(s) changed" % edits.size()
	_approve_btn.visible = true
	_revert_btn.visible = true

	_rebuild_file_tree(edits)
	if not edits.is_empty():
		var first_path: String = str((edits[0] as Dictionary).get("path", ""))
		if first_path != "":
			_show_diff_for_path(first_path)


func _show_diff_for_path(path: String) -> void:
	_current_file_path = path
	_revert_file_btn.visible = true

	if not _diff_manager:
		return

	var diff: String = str(_diff_manager.get_diff_for_file(_current_task_id, path))
	if diff.is_empty():
		_diff_display.text = "[color=#555](no diff available)[/color]"
		return

	_diff_display.text = _format_diff_bbcode(diff)


func _rebuild_file_tree(edits: Array) -> void:
	if _file_tree == null:
		return
	_file_tree.clear()
	var root: TreeItem = _file_tree.create_item()
	for edit in edits:
		if not (edit is Dictionary):
			continue
		var path: String = str(edit.get("path", ""))
		if path == "":
			continue
		var diff: String = str(_diff_manager.get_diff_for_file(_current_task_id, path)) if _diff_manager else ""
		var changed_count: int = _count_changed_lines(diff)
		var expanded: bool = bool(_expanded_files.get(path, false))
		var file_item := _file_tree.create_item(root)
		file_item.set_metadata(0, {"kind": "file", "path": path})
		file_item.set_tooltip_text(0, path)
		file_item.set_selectable(0, true)
		file_item.set_text(0, _file_item_label(path, changed_count, expanded))
		file_item.collapsed = not expanded

		var preview_lines: Array[String] = _extract_preview_lines(diff, 8)
		if preview_lines.is_empty():
			var child := _file_tree.create_item(file_item)
			child.set_metadata(0, {"kind": "preview", "path": path})
			child.set_text(0, "   (no hunks)")
			child.set_selectable(0, false)
			child.set_custom_color(0, Color(0.4, 0.4, 0.4))
		else:
			for ln in preview_lines:
				var child := _file_tree.create_item(file_item)
				child.set_metadata(0, {"kind": "preview", "path": path})
				child.set_text(0, "   " + ln)
				child.set_selectable(0, true)
				if ln.begins_with("+"):
					child.set_custom_color(0, Color(0.3, 0.85, 0.45))
				elif ln.begins_with("-"):
					child.set_custom_color(0, Color(0.9, 0.35, 0.35))
				else:
					child.set_custom_color(0, Color(0.75, 0.75, 0.75))

	if root.get_first_child() != null:
		var first_file: TreeItem = root.get_first_child()
		_file_tree.set_selected(first_file, 0)


func _count_changed_lines(diff: String) -> int:
	var n := 0
	for line in diff.split("\n"):
		if line.begins_with("+") and not line.begins_with("+++"):
			n += 1
		elif line.begins_with("-") and not line.begins_with("---"):
			n += 1
	return n


func _file_item_label(path: String, changed_count: int, expanded: bool) -> String:
	var name: String = path.get_file()
	var marker: String = "−" if expanded else "+"
	return "%s %s  [~%d]" % [marker, name, changed_count]


func _extract_preview_lines(diff: String, max_lines: int = 8) -> Array[String]:
	var out: Array[String] = []
	for line in diff.split("\n"):
		if line.begins_with("+++") or line.begins_with("---"):
			continue
		if line.begins_with("@@"):
			out.append(line)
		elif line.begins_with("+") or line.begins_with("-"):
			out.append(line)
		elif line.strip_edges() != "" and out.is_empty():
			# Keep one leading context line for orientation.
			out.append(line)
		if out.size() >= max_lines:
			break
	return out


func _format_diff_bbcode(diff: String) -> String:
	var out := ""
	for line in diff.split("\n"):
		if line.begins_with("+++") or line.begins_with("---"):
			out += "[color=#666]" + _escape_bbcode(line) + "[/color]\n"
		elif line.begins_with("+"):
			out += "[color=#2ecc71][bgcolor=#0d2b18]" + _escape_bbcode(line) + "[/bgcolor][/color]\n"
		elif line.begins_with("-"):
			out += "[color=#e74c3c][bgcolor=#2b0d0d]" + _escape_bbcode(line) + "[/bgcolor][/color]\n"
		elif line.begins_with("@@"):
			out += "[color=#3498db]" + _escape_bbcode(line) + "[/color]\n"
		else:
			out += "[color=#aaa]" + _escape_bbcode(line) + "[/color]\n"
	return out


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "&#91;").replace("]", "&#93;")


func _on_diff_ready(path: String, diff_text: String) -> void:
	# If we're already showing this task, refresh
	if _current_task_id != "" and _diff_manager:
		var edits: Array = _diff_manager.get_task_edits(_current_task_id) as Array
		for edit in edits:
			if edit.get("path", "") == path:
				show_task_diffs(_current_task_id)
				return


func _on_file_reverted(path: String) -> void:
	if _state:
		_state.emit_log("success", "Reverted: " + path)
	if path == _current_file_path:
		_diff_display.text = "[color=#2ecc71]File reverted.[/color]"


func _on_file_tree_selected() -> void:
	if _file_tree == null:
		return
	var item: TreeItem = _file_tree.get_selected()
	if item == null:
		return
	var md: Variant = item.get_metadata(0)
	if not (md is Dictionary):
		return
	var meta: Dictionary = md
	var kind: String = str(meta.get("kind", ""))
	var path: String = str(meta.get("path", ""))
	if kind == "file":
		_show_diff_for_path(path)
	elif kind == "preview":
		_show_diff_for_path(path)


func _on_file_tree_item_collapsed(item: TreeItem) -> void:
	if item == null:
		return
	var md: Variant = item.get_metadata(0)
	if not (md is Dictionary):
		return
	var meta: Dictionary = md
	if str(meta.get("kind", "")) != "file":
		return
	var path: String = str(meta.get("path", ""))
	var expanded: bool = not item.collapsed
	_expanded_files[path] = expanded
	var changed_count: int = _count_changed_lines(
		str(_diff_manager.get_diff_for_file(_current_task_id, path)) if _diff_manager else ""
	)
	item.set_text(0, _file_item_label(path, changed_count, expanded))


func _on_approve_all() -> void:
	approve_requested.emit(_current_task_id)
	_approve_btn.visible = false
	_revert_btn.visible = false
	if _state:
		_state.emit_log("success", "Task approved: " + _current_task_id)


func _on_revert_task() -> void:
	if not _diff_manager:
		return
	var edits: Array = _diff_manager.get_task_edits(_current_task_id) as Array
	for edit in edits:
		var path: String = edit.get("path", "")
		if path != "":
			_diff_manager.revert_file_local(path, _current_task_id)
	_revert_btn.visible = false
	_approve_btn.visible = false
	_status_label.text = "Task reverted"
	_diff_display.text = "[color=#e74c3c]All changes reverted.[/color]"


func _on_revert_file() -> void:
	if _current_file_path == "" or not _diff_manager:
		return
	revert_requested.emit(_current_task_id, _current_file_path)
	_diff_manager.revert_file_local(_current_file_path, _current_task_id)
	_revert_file_btn.visible = false
