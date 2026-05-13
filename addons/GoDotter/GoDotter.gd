@tool
extends EditorPlugin

## GoDotter — AI IDE plugin for Godot 4.
## Distribution: drop addons/GoDotter/ into any project's addons/ folder.

var _forge_dock: Control

# Backend process management
var _backend_pid: int = -1
var _backend_monitor_timer: Timer = null
## Monotonic tick when we last spawned the backend (grace before treating PID as stale).
var _backend_spawn_tick_ms: int = 0
const BACKEND_PID_GRACE_MS := 2200


func _enter_tree() -> void:
	# Build dock from script using paths derived from this plugin file — not the
	# hardcoded res://addons/GoDotter/... inside ForgeDock.tscn (breaks if the
	# folder is renamed or the scene references a missing script).
	var addon_root: String = get_script().resource_path.get_base_dir()
	var forge_path: String = addon_root.path_join("ui/ForgeDock.gd")
	var forge_script: GDScript = load(forge_path) as GDScript
	if forge_script == null:
		push_error("[GoDotter] Could not load ForgeDock script: " + forge_path)
		return
	_forge_dock = Control.new()
	_forge_dock.name = "GoDotter"
	_forge_dock.set_script(forge_script)
	if not _forge_dock.has_method("initialize"):
		push_error(
			"[GoDotter] ForgeDock.gd did not attach (missing initialize). " +
			"Check Output for parse/compile errors in ForgeDock.gd or dependencies."
		)
		_forge_dock.queue_free()
		_forge_dock = null
		return
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _forge_dock)
	_forge_dock.initialize(self)
	_connect_editor_signals()
	print("[GoDotter] Plugin loaded for project: " + ProjectSettings.globalize_path("res://"))

	# Seed the default backend dir from our own location if not already set
	var state = _forge_dock.state
	if state:
		if state.backend_dir == "":
			state.backend_dir = _default_backend_dir()
			state.save_machine_settings()
		# Auto-start if configured (default on — user can disable in Settings)
		if state.autostart_backend:
			call_deferred("_try_launch_backend")
	# Always try to bring the backend up shortly after load (health + launch if still down)
	call_deferred("_schedule_backend_bringup")


func _exit_tree() -> void:
	_disconnect_editor_signals()
	_stop_backend_monitor()
	# Stop backend if WE launched it (don't kill backends the user started manually)
	if _backend_pid > 0:
		_kill_backend()
	if _forge_dock:
		# Emergency restore neon colors if visualization was in progress
		if _forge_dock.has_method("emergency_restore"):
			_forge_dock.emergency_restore()
		remove_control_from_docks(_forge_dock)
		_forge_dock.queue_free()
		_forge_dock = null
	print("[GoDotter] Plugin unloaded.")


# ---------------------------------------------------------------------------
# Backend process management
# ---------------------------------------------------------------------------

## Returns the absolute path to addons/GoDotter/backend/ for this installation.
## Works regardless of which project the plugin is installed in.
func _default_backend_dir() -> String:
	# get_script().resource_path = "res://addons/GoDotter/GoDotter.gd"
	var addon_dir: String = get_script().resource_path.get_base_dir()
	return ProjectSettings.globalize_path(addon_dir + "/backend")


func try_launch_backend() -> Dictionary:
	return _try_launch_backend()


## True when this plugin started the backend process and it is still alive.
func is_backend_process_tracked() -> bool:
	return _backend_pid > 0 and OS.is_process_running(_backend_pid)


func _schedule_backend_bringup() -> void:
	var t := Timer.new()
	t.wait_time = 1.0
	t.one_shot = true
	add_child(t)
	t.timeout.connect(_on_backend_bringup_timer, CONNECT_ONE_SHOT)
	t.start()


func _on_backend_bringup_timer() -> void:
	_sanitize_backend_pid()
	if _forge_dock and _forge_dock.has_method("trigger_health_check"):
		_forge_dock.trigger_health_check()
	# If still offline after a short wait, try launching once
	var t2 := Timer.new()
	t2.wait_time = 1.5
	t2.one_shot = true
	add_child(t2)
	t2.timeout.connect(_on_backend_bringup_try_launch, CONNECT_ONE_SHOT)
	t2.start()


func _on_backend_bringup_try_launch() -> void:
	var st = _forge_dock.state if _forge_dock else null
	if st and st.backend_online:
		return
	_sanitize_backend_pid()
	if _backend_pid > 0 and OS.is_process_running(_backend_pid):
		if _forge_dock and _forge_dock.has_method("trigger_health_check"):
			_forge_dock.trigger_health_check()
		return
	_try_launch_backend()


func _sanitize_backend_pid() -> void:
	if _backend_pid <= 0:
		return
	var now: int = Time.get_ticks_msec()
	if now - _backend_spawn_tick_ms < BACKEND_PID_GRACE_MS:
		return
	if OS.is_process_running(_backend_pid):
		return
	print("[GoDotter] Clearing stale backend PID (process ended): ", _backend_pid)
	_backend_pid = -1
	if _forge_dock and _forge_dock.state:
		_forge_dock.state.backend_pid = -1


func _poke_forge_health() -> void:
	if _forge_dock and _forge_dock.has_method("trigger_health_check"):
		_forge_dock.trigger_health_check()


func _try_launch_backend() -> Dictionary:
	var state = _forge_dock.state if _forge_dock else null
	if not state:
		return {"ok": false, "error": "Plugin not initialized"}

	_sanitize_backend_pid()

	var python: String = str(state.get_effective_python())
	var main_py: String = str(state.get_backend_main())
	if main_py.begins_with("res://"):
		main_py = ProjectSettings.globalize_path(main_py)

	if main_py == "" or not FileAccess.file_exists(main_py):
		return {
			"ok": false,
			"error": "main.py not found. Set backend directory in GoDotter Settings.",
		}

	if not FileAccess.file_exists(python) and python != "python" and python != "python3" and python != "py":
		return {
			"ok": false,
			"error": "Python executable not found: " + python +
				"\nUse the wizard: Install Python / create venv, or set Python path in Settings.",
		}

	# Don't double-launch a live process we started
	if _backend_pid > 0 and OS.is_process_running(_backend_pid):
		call_deferred("_poke_forge_health")
		return {"ok": true, "message": "Backend already running (PID " + str(_backend_pid) + ")"}

	if state.has_method("sync_backend_api_key_file"):
		state.sync_backend_api_key_file()

	# Build args — absolute main.py cwd-independent; --no-reload avoids uvicorn reloader PID confusion.
	# Pick a TCP port we can bind now (avoids silent uvicorn exit when the port is already taken).
	var project_root := ProjectSettings.globalize_path("res://")
	var bind := {"host": "127.0.0.1", "port": 8765}
	if state.has_method("get_backend_tcp_listen"):
		bind = state.get_backend_tcp_listen()
	var host_s: String = str(bind.get("host", "127.0.0.1"))
	var preferred_port: int = int(bind.get("port", 8765))
	var port_n: int = preferred_port
	if state.has_method("pick_backend_listen_port"):
		port_n = state.pick_backend_listen_port(host_s, preferred_port)
	if port_n < 0:
		return {
			"ok": false,
			"error": (
				"No free TCP port found for the backend (tried 64 ports from %d). "
				+ "Close other servers or change Settings → Backend URL."
			) % preferred_port,
		}
		print("[GoDotter] Preferred port %d busy; auto-selected %d (saved to project Settings)." % [preferred_port, port_n])
		if state.has_method("apply_auto_backend_url"):
			state.apply_auto_backend_url(host_s, port_n)

	print("[GoDotter] Backend bind: %s:%d" % [host_s, port_n])
	var exe: String = python
	var args := PackedStringArray([
		main_py, "--project-root", project_root, "--no-reload",
		"--host", host_s, "--port", str(port_n),
	])
	if python == "py":
		args = PackedStringArray([
			"-3", main_py, "--project-root", project_root, "--no-reload",
			"--host", host_s, "--port", str(port_n),
		])

	_backend_pid = OS.create_process(exe, args, false)

	if _backend_pid < 0:
		_backend_pid = -1
		return {"ok": false, "error": "OS.create_process failed. Check Python path."}

	print("[GoDotter] Backend launched, PID: " + str(_backend_pid))
	_backend_spawn_tick_ms = Time.get_ticks_msec()
	if state:
		state.backend_pid = _backend_pid

	# Start monitoring — update dock health check after a short delay
	_start_backend_monitor()
	call_deferred("_poke_forge_health")

	return {"ok": true, "pid": _backend_pid, "message": "Backend starting…"}


func _kill_backend() -> void:
	if _backend_pid > 0 and OS.is_process_running(_backend_pid):
		OS.kill(_backend_pid)
		print("[GoDotter] Backend process killed (PID %d)." % _backend_pid)
	_backend_pid = -1
	if _forge_dock and _forge_dock.state:
		_forge_dock.state.backend_pid = -1


func _start_backend_monitor() -> void:
	if _backend_monitor_timer:
		return
	_backend_monitor_timer = Timer.new()
	_backend_monitor_timer.wait_time = 4.0
	_backend_monitor_timer.one_shot = true
	_backend_monitor_timer.timeout.connect(_on_backend_startup_delay)
	add_child(_backend_monitor_timer)
	_backend_monitor_timer.start()


func _stop_backend_monitor() -> void:
	if _backend_monitor_timer:
		_backend_monitor_timer.queue_free()
		_backend_monitor_timer = null


func _on_backend_startup_delay() -> void:
	# Trigger a health check now that the backend had time to start
	if _forge_dock and _forge_dock.has_method("trigger_health_check"):
		_forge_dock.trigger_health_check()
	_stop_backend_monitor()


# ---------------------------------------------------------------------------
# Editor signals
# ---------------------------------------------------------------------------

func _connect_editor_signals() -> void:
	var selection := get_editor_interface().get_selection()
	if not selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.connect(_on_selection_changed)

	var fs := get_editor_interface().get_resource_filesystem()
	if not fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.connect(_on_filesystem_changed)

	if not scene_changed.is_connected(_on_scene_changed):
		scene_changed.connect(_on_scene_changed)


func _disconnect_editor_signals() -> void:
	var selection := get_editor_interface().get_selection()
	if selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)

	var fs := get_editor_interface().get_resource_filesystem()
	if fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.disconnect(_on_filesystem_changed)

	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)


func _on_selection_changed() -> void:
	if _forge_dock and _forge_dock.has_method("on_selection_changed"):
		_forge_dock.on_selection_changed()


func _on_filesystem_changed() -> void:
	if _forge_dock and _forge_dock.has_method("on_filesystem_changed"):
		_forge_dock.on_filesystem_changed()


func _on_scene_changed(scene_root: Node) -> void:
	if _forge_dock and _forge_dock.has_method("on_scene_changed"):
		_forge_dock.on_scene_changed(scene_root)
