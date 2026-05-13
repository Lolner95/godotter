@tool
extends RefCounted
## TODO Phase 5: Godot CLI scene runner.
## Launches `godot --path . res://scene.tscn` as a subprocess,
## captures stdout/stderr into LogCollector, detects errors, and reports exit code.
##
## Contract (set now so Phase 5 has a clear interface to implement):
##   run_project() -> String (run_id)
##   run_scene(scene_path: String) -> String (run_id)
##   stop() -> void
##   is_running() -> bool

signal run_started(run_id: String)
signal run_output(run_id: String, line: String)
signal run_finished(run_id: String, exit_code: int)

func run_project() -> String:
	push_warning("[GoDotter] RuntimeController.run_project() — Phase 5 not yet implemented.")
	return ""

func run_scene(_scene_path: String) -> String:
	push_warning("[GoDotter] RuntimeController.run_scene() — Phase 5 not yet implemented.")
	return ""

func stop() -> void:
	push_warning("[GoDotter] RuntimeController.stop() — Phase 5 not yet implemented.")

func is_running() -> bool:
	return false
