@tool
extends Node

## Neon Debug Visualizer.
##
## Temporarily recolors every visible node in the edited scene with a distinct
## neon color per node class, then captures a viewport screenshot.
## The AI receives both the neon screenshot AND a JSON node map, giving it
## precise knowledge of:
##   - What each colored element is (by legend)
##   - Where it sits in screen space (pixel coordinates)
##   - Its size, z-index, visibility, depth in hierarchy
##   - Which script it runs
##
## For 2D: uses CanvasItem.modulate (non-destructive, restored after capture).
## For 3D: uses GeometryInstance3D.material_override with a flat neon material.
## After capture, ALL originals are restored. If anything fails, restoration
## still runs in a deferred call to protect the user's scene.

signal visualization_complete(screenshot_path: String, node_map: Array)
signal visualization_failed(reason: String)
signal restoration_complete()

var _state: Object  # ForgeState

# ---------------------------------------------------------------------------
# Neon color palette — each node type gets a unique color
# ---------------------------------------------------------------------------
const TYPE_COLORS: Dictionary = {
	# --- UI Controls ---
	"Control":               Color(1.00, 0.00, 1.00, 1.0),   # Magenta
	"Panel":                 Color(1.00, 0.00, 0.55, 1.0),   # Hot pink
	"PanelContainer":        Color(1.00, 0.20, 0.60, 1.0),   # Pink-red
	"MarginContainer":       Color(0.90, 0.10, 0.60, 1.0),   # Deep pink
	"VBoxContainer":         Color(1.00, 0.35, 0.80, 1.0),   # Light pink
	"HBoxContainer":         Color(0.80, 0.20, 0.90, 1.0),   # Violet
	"GridContainer":         Color(0.70, 0.10, 0.95, 1.0),   # Purple-violet
	"ScrollContainer":       Color(0.60, 0.00, 1.00, 1.0),   # Purple
	"TabContainer":          Color(0.50, 0.00, 1.00, 1.0),   # Blue-purple
	"Button":                Color(1.00, 0.50, 0.00, 1.0),   # Neon orange
	"Label":                 Color(0.00, 1.00, 1.00, 1.0),   # Cyan
	"RichTextLabel":         Color(0.00, 0.85, 1.00, 1.0),   # Sky blue
	"LineEdit":              Color(0.00, 0.70, 1.00, 1.0),   # Light blue
	"TextEdit":              Color(0.00, 0.55, 1.00, 1.0),   # Blue
	"TextureRect":           Color(0.00, 1.00, 0.00, 1.0),   # Lime green
	"NinePatchRect":         Color(0.20, 1.00, 0.00, 1.0),   # Yellow-green
	"ColorRect":             Color(0.50, 1.00, 0.00, 1.0),   # Yellow-lime
	"ProgressBar":           Color(0.70, 1.00, 0.00, 1.0),   # Yellow
	"Slider":                Color(1.00, 1.00, 0.00, 1.0),   # Pure yellow
	"ItemList":              Color(1.00, 0.80, 0.00, 1.0),   # Gold
	"Tree":                  Color(1.00, 0.65, 0.00, 1.0),   # Amber
	"PopupMenu":             Color(1.00, 0.55, 0.00, 1.0),   # Deep orange
	"OptionButton":          Color(1.00, 0.45, 0.00, 1.0),   # Orange-red
	# --- 2D Nodes ---
	"Node2D":                Color(1.00, 1.00, 0.00, 1.0),   # Yellow
	"Sprite2D":              Color(0.40, 1.00, 0.00, 1.0),   # Green-lime
	"AnimatedSprite2D":      Color(0.30, 1.00, 0.20, 1.0),   # Bright green
	"TileMap":               Color(0.00, 1.00, 0.50, 1.0),   # Spring green
	"Area2D":                Color(1.00, 0.10, 0.10, 1.0),   # Bright red
	"CharacterBody2D":       Color(1.00, 0.30, 0.10, 1.0),   # Red-orange
	"RigidBody2D":           Color(1.00, 0.20, 0.20, 1.0),   # Red
	"StaticBody2D":          Color(0.90, 0.10, 0.10, 1.0),   # Dark red
	"CollisionShape2D":      Color(1.00, 0.60, 0.60, 1.0),   # Salmon
	"CollisionPolygon2D":    Color(1.00, 0.65, 0.65, 1.0),   # Light salmon
	"Camera2D":              Color(0.00, 1.00, 0.55, 1.0),   # Teal
	"CanvasLayer":           Color(0.55, 0.55, 1.00, 1.0),   # Periwinkle
	"ParticleProcessMaterial": Color(0.00, 0.90, 0.80, 1.0), # Aqua
	"GPUParticles2D":        Color(0.00, 0.80, 0.80, 1.0),   # Cyan-teal
	# --- 3D Nodes ---
	"MeshInstance3D":        Color(1.00, 0.40, 0.00, 1.0),   # Neon orange (3D)
	"CSGShape3D":            Color(0.80, 0.20, 1.00, 1.0),   # Violet (CSG)
	"CSGBox3D":              Color(0.80, 0.20, 1.00, 1.0),
	"CSGSphere3D":           Color(0.80, 0.20, 1.00, 1.0),
	"CSGCylinder3D":         Color(0.80, 0.20, 1.00, 1.0),
	"Node3D":                Color(0.70, 0.00, 1.00, 1.0),   # Purple (generic 3D)
	"Camera3D":              Color(0.00, 0.80, 0.45, 1.0),   # Teal-green
	"DirectionalLight3D":    Color(1.00, 1.00, 0.80, 1.0),   # Warm white
	"OmniLight3D":           Color(1.00, 0.95, 0.00, 1.0),   # Bright yellow
	"SpotLight3D":           Color(0.95, 1.00, 0.00, 1.0),   # Yellow-green
	"Area3D":                Color(0.80, 0.20, 0.20, 1.0),   # Dark red (3D area)
	"CharacterBody3D":       Color(0.90, 0.30, 0.50, 1.0),   # Deep pink
	"RigidBody3D":           Color(0.90, 0.20, 0.30, 1.0),   # Crimson
	"CollisionShape3D":      Color(1.00, 0.50, 0.50, 1.0),   # Light red
	"VehicleBody3D":         Color(0.70, 0.30, 0.20, 1.0),   # Brown-red
	# --- Animations & Audio ---
	"AnimationPlayer":       Color(0.20, 0.40, 1.00, 1.0),   # Blue
	"AnimationTree":         Color(0.30, 0.50, 1.00, 1.0),   # Light blue
	"AudioStreamPlayer":     Color(0.00, 0.70, 0.50, 1.0),   # Sea green
	"AudioStreamPlayer2D":   Color(0.00, 0.80, 0.55, 1.0),   # Green-teal
	"AudioStreamPlayer3D":   Color(0.00, 0.90, 0.60, 1.0),   # Bright teal
}

# Fallback colors for broad categories
const FALLBACK_2D := Color(1.00, 1.00, 0.00, 1.0)    # Yellow for unknown 2D
const FALLBACK_3D := Color(0.60, 0.00, 0.90, 1.0)    # Purple for unknown 3D
const FALLBACK_UI := Color(0.80, 0.00, 0.80, 1.0)    # Magenta for unknown UI

# Neon opacity — high enough to be visible but shows depth through layers
const NEON_ALPHA := 0.88

# ---------------------------------------------------------------------------
# State backup (for restoration)
# ---------------------------------------------------------------------------
var _backup_modulate: Dictionary = {}    # node -> original Color
var _backup_materials: Dictionary = {}  # node -> original material_override
var _neon_materials: Array = []          # temp materials to free after restore
var _is_active := false


func setup(state: Object) -> void:
	_state = state


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

func visualize_and_capture(task_id: String = "") -> void:
	if _is_active:
		visualization_failed.emit("Visualization already in progress")
		return

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		visualization_failed.emit("No scene is open in the editor")
		return

	_is_active = true
	_backup_modulate.clear()
	_backup_materials.clear()
	_neon_materials.clear()

	var node_map: Array = []

	# Apply neon colors and build node map
	_apply_neon_recursive(root, node_map, 0)

	# Wait two frames for Godot to render the changes
	await get_tree().process_frame
	await get_tree().process_frame

	# Capture
	var screenshot_path := ""
	var viewport := EditorInterface.get_editor_viewport_2d()
	if viewport == null:
		viewport = get_viewport()

	if viewport:
		var image := viewport.get_texture().get_image()
		if image:
			var base := ProjectSettings.globalize_path("res://") + ".godot_forge/screenshots/"
			var sub := task_id if task_id != "" else "visualize"
			var dir_path := base + sub + "/"
			DirAccess.make_dir_recursive_absolute(dir_path)
			var ts := Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
			screenshot_path = dir_path + ts + "_neon_debug.png"
			image.save_png(screenshot_path)

	# ALWAYS restore — even if capture failed
	_restore_all()
	_is_active = false

	if screenshot_path == "" or not FileAccess.file_exists(screenshot_path):
		visualization_failed.emit("Screenshot capture failed or no viewport available")
		return

	visualization_complete.emit(screenshot_path, node_map)


# ---------------------------------------------------------------------------
# Apply neon colors
# ---------------------------------------------------------------------------

func _apply_neon_recursive(node: Node, node_map: Array, depth: int) -> void:
	if depth > 20:
		return

	var neon_color := _get_neon_color(node)
	var entry := _build_node_entry(node, neon_color, depth)

	if node is CanvasItem:
		var ci := node as CanvasItem
		if ci.visible:
			_backup_modulate[node] = ci.modulate
			var nc := neon_color
			nc.a = NEON_ALPHA
			ci.modulate = nc
	elif node is GeometryInstance3D:
		var gi := node as GeometryInstance3D
		_backup_materials[node] = gi.material_override
		var mat := _make_neon_material(neon_color)
		_neon_materials.append(mat)
		gi.material_override = mat

	node_map.append(entry)

	for child in node.get_children():
		_apply_neon_recursive(child, node_map, depth + 1)


func _get_neon_color(node: Node) -> Color:
	var cls := node.get_class()
	if TYPE_COLORS.has(cls):
		return TYPE_COLORS[cls]
	# Walk up class hierarchy
	if node is Control:
		return FALLBACK_UI
	if node is Node2D:
		return FALLBACK_2D
	if node is Node3D:
		return FALLBACK_3D
	return Color(0.9, 0.9, 0.9)


func _make_neon_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5
	return mat


func _build_node_entry(node: Node, color: Color, depth: int) -> Dictionary:
	var entry := {
		"name": node.name,
		"node_class": node.get_class(),
		"path": str(node.get_path()),
		"neon_color_hex": "#" + color.to_html(false).to_upper(),
		"depth": depth,
		"visible": true,
		"script": "",
		"children_count": node.get_child_count(),
		"screen_x": 0.0,
		"screen_y": 0.0,
		"screen_width": 0.0,
		"screen_height": 0.0,
		"z_index": 0,
	}

	if node.get_script():
		entry["script"] = node.get_script().resource_path

	if node is CanvasItem:
		entry["visible"] = (node as CanvasItem).visible

	if node is Control:
		var ctrl := node as Control
		var rect := ctrl.get_global_rect()
		entry["screen_x"] = rect.position.x
		entry["screen_y"] = rect.position.y
		entry["screen_width"] = rect.size.x
		entry["screen_height"] = rect.size.y
		entry["z_index"] = ctrl.z_index

	elif node is Node2D:
		var n2d := node as Node2D
		entry["visible"] = n2d.visible
		entry["z_index"] = n2d.z_index
		# Approximate screen pos via global_position
		entry["screen_x"] = n2d.global_position.x
		entry["screen_y"] = n2d.global_position.y

	return entry


# ---------------------------------------------------------------------------
# Restore all originals
# ---------------------------------------------------------------------------

func _restore_all() -> void:
	# Restore 2D modulate
	for node in _backup_modulate.keys():
		if is_instance_valid(node) and node is CanvasItem:
			(node as CanvasItem).modulate = _backup_modulate[node]

	# Restore 3D material overrides
	for node in _backup_materials.keys():
		if is_instance_valid(node) and node is GeometryInstance3D:
			(node as GeometryInstance3D).material_override = _backup_materials[node]

	# Free temp neon materials
	for mat in _neon_materials:
		if is_instance_valid(mat):
			mat.free()

	_backup_modulate.clear()
	_backup_materials.clear()
	_neon_materials.clear()

	restoration_complete.emit()


# ---------------------------------------------------------------------------
# Color legend for the AI
# ---------------------------------------------------------------------------

func get_color_legend() -> Dictionary:
	var legend: Dictionary = {}
	for cls in TYPE_COLORS:
		var color: Color = TYPE_COLORS[cls]
		legend[cls] = "#" + color.to_html(false).to_upper()
	legend["_FALLBACK_2D"] = "#" + FALLBACK_2D.to_html(false).to_upper()
	legend["_FALLBACK_3D"] = "#" + FALLBACK_3D.to_html(false).to_upper()
	legend["_FALLBACK_UI"] = "#" + FALLBACK_UI.to_html(false).to_upper()
	return legend


# ---------------------------------------------------------------------------
# Emergency restore (call if plugin unloads mid-visualization)
# ---------------------------------------------------------------------------

func emergency_restore() -> void:
	if _is_active:
		_restore_all()
		_is_active = false
		push_warning("[GoDotter] Emergency restore executed")


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _is_active:
		emergency_restore()
