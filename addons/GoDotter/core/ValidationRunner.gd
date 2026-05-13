@tool
extends RefCounted
## TODO Phase 8: Runs ForgeValidation scenes via Godot CLI.
## Parses JSON results, captures screenshots at each step, reports pass/fail.

signal validation_started(name: String)
signal validation_finished(name: String, result: Dictionary)

const VALIDATION_DIR := "res://tests/forge_validations/"

func run_validation(_validation_name: String) -> void:
	push_warning("[GoDotter] ValidationRunner.run_validation() — Phase 8 not yet implemented.")

func list_validations() -> Array:
	var result: Array = []
	var dir := DirAccess.open(VALIDATION_DIR)
	if dir == null:
		return result
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".tscn"):
			result.append(fname.get_basename())
		fname = dir.get_next()
	dir.list_dir_end()
	return result
