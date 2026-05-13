@tool
extends Control
## TODO Phase 6: Screenshot capture and before/after comparison UI.
## Shows thumbnail grid, opens large preview on click, highlights differences.

func _ready() -> void:
	var lbl := Label.new()
	lbl.text = "Screenshot Panel — Phase 6"
	lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	add_child(lbl)
