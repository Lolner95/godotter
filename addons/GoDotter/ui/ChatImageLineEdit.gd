extends TextEdit
## Chat input that accepts image paste (Ctrl+V) and file drops like Cursor.
## Enter submits, Alt+Enter inserts a newline.

signal files_dropped(paths: PackedStringArray)
signal clipboard_image_pasted(image: Image)
signal submit_requested(text: String)


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if data is Dictionary and str(data.get("type", "")) == "files":
		return true
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var paths := _extract_file_paths(data)
	if not paths.is_empty():
		files_dropped.emit(paths)


func _extract_file_paths(data: Variant) -> PackedStringArray:
	if not (data is Dictionary):
		return PackedStringArray()
	var raw: Variant = (data as Dictionary).get("files", [])
	if raw is PackedStringArray:
		return raw as PackedStringArray
	if raw is Array:
		var out := PackedStringArray()
		for x in raw as Array:
			out.append(str(x))
		return out
	return PackedStringArray()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			if event.alt_pressed:
				# Let TextEdit insert a newline naturally.
				return
			submit_requested.emit(text)
			accept_event()
			return
		if event.keycode == KEY_V and event.ctrl_pressed and not event.alt_pressed:
			var img: Image = DisplayServer.clipboard_get_image()
			if img != null and img.get_width() > 0 and img.get_height() > 0:
				clipboard_image_pasted.emit(img)
				accept_event()
				return
