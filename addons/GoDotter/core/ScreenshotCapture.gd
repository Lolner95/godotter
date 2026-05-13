@tool
extends Node

## Captures screenshots from the editor viewport and from 3D assets
## rendered from 6 orthographic angles + perspective.
##
## Phase 6 runtime screenshot (from running game viewport) is stubbed.

signal capture_completed(paths: Array)
signal capture_failed(reason: String)

var _state: Object  # ForgeState

const ANGLES := {
	"top":         Vector3(0, -1, 0),
	"bottom":      Vector3(0, 1, 0),
	"front":       Vector3(0, 0, 1),
	"back":        Vector3(0, 0, -1),
	"left":        Vector3(-1, 0, 0),
	"right":       Vector3(1, 0, 0),
	"perspective": Vector3(1, -1, 1),
}

const VIEWPORT_SIZE := Vector2i(1024, 1024)


func setup(state: Object) -> void:
	_state = state


# --- Editor viewport capture ---

func capture_editor_viewport(task_id: String, label: String = "editor") -> String:
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		viewport = get_viewport()
	if viewport == null:
		capture_failed.emit("No viewport available")
		return ""

	var image := viewport.get_texture().get_image()
	if image == null:
		capture_failed.emit("Viewport texture returned null image")
		return ""

	var path := _make_screenshot_path(task_id, label)
	image.save_png(path)
	return path


# --- 3D multi-angle capture ---

func capture_3d_angles(node: Node3D, task_id: String) -> Array:
	if node == null:
		capture_failed.emit("Node is null")
		return []

	var aabb := _compute_world_aabb(node)
	var center := aabb.get_center()
	var radius := aabb.size.length() * 0.75 + 0.5

	# Create an isolated SubViewport with its own scene
	var sv := SubViewport.new()
	sv.size = VIEWPORT_SIZE
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.own_world_3d = true
	sv.transparent_bg = false

	# Environment
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.12, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.9, 0.9, 0.9)
	env.ambient_light_energy = 0.6
	world_env.environment = env
	sv.add_child(world_env)

	# Light
	var light := DirectionalLight3D.new()
	light.light_energy = 1.2
	light.rotation_degrees = Vector3(-45, 45, 0)
	sv.add_child(light)

	# Duplicate the node for isolated rendering
	var mesh_clone := node.duplicate()
	sv.add_child(mesh_clone)

	# Camera
	var camera := Camera3D.new()
	sv.add_child(camera)

	# Add SubViewport to scene tree
	get_tree().root.add_child(sv)

	var saved_paths: Array = []

	for angle_name in ANGLES.keys():
		var dir: Vector3 = ANGLES[angle_name].normalized()
		var cam_pos := center + dir * radius

		camera.global_position = cam_pos
		camera.look_at(center, Vector3.UP if abs(dir.y) < 0.9 else Vector3.FORWARD)

		# Orthographic for cardinal angles, perspective for diagonal
		if angle_name == "perspective":
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			camera.fov = 50.0
		else:
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = aabb.size.length() * 1.1

		# Wait one frame to render
		await RenderingServer.frame_post_draw

		var image := sv.get_texture().get_image()
		if image != null:
			var path := _make_screenshot_path(task_id, "3d_" + angle_name)
			image.save_png(path)
			saved_paths.append({"angle": angle_name, "path": path})

	# Cleanup
	sv.queue_free()

	if saved_paths.is_empty():
		capture_failed.emit("No angles captured")
	else:
		capture_completed.emit(saved_paths)

	return saved_paths


func _compute_world_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	var found := false

	if node is GeometryInstance3D:
		aabb = node.get_aabb()
		found = true

	for child in node.get_children():
		if child is Node3D:
			var child_aabb := _compute_world_aabb(child as Node3D)
			if not found:
				aabb = child_aabb
				found = true
			else:
				aabb = aabb.merge(child_aabb)

	if not found:
		return AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))

	# Fallback to a unit AABB if degenerate
	if aabb.size.length() < 0.01:
		return AABB(node.global_position - Vector3(1, 1, 1), Vector3(2, 2, 2))

	return aabb


func _make_screenshot_path(task_id: String, label: String) -> String:
	var base := ProjectSettings.globalize_path("res://") + ".godot_forge/screenshots/"
	if task_id != "":
		base += task_id + "/"
	else:
		base += "misc/"
	DirAccess.make_dir_recursive_absolute(base)
	var ts := Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	return base + ts + "_" + label + ".png"


# --- Runtime screenshot (Phase 6 stub) ---

func capture_running_game(task_id: String, label: String = "runtime") -> String:
	# TODO Phase 6: Attach to the game viewport while running and capture frame.
	# Requires RuntimeController to be active and the game window to be alive.
	push_warning("[GoDotter] Runtime screenshot not yet implemented (Phase 6).")
	return ""
