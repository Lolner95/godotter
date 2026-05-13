@tool
extends Control
## TODO Phase 8: Validation scenes runner UI.
## Shows visual checks, mechanics checks, performance checks, scene integrity checks.
## Each check has pass/fail with screenshots and logs.

func _ready() -> void:
	var lbl := Label.new()
	lbl.text = "Validation Panel — Phase 8"
	lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	add_child(lbl)
