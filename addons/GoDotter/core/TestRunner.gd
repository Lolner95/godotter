@tool
extends RefCounted
## TODO Phase 8: Test framework integration (GUT, gdUnit4, ForgeValidation).
## Detects installed frameworks, runs tests, parses results, reports pass/fail.

signal tests_started(framework: String)
signal tests_finished(results: Dictionary)

func detect_framework() -> String:
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://addons/gut")):
		return "gut"
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://addons/gdUnit4")):
		return "gdunit4"
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://tests/forge_validations")):
		return "forge_validation"
	return "none"

func run_all() -> void:
	push_warning("[GoDotter] TestRunner.run_all() — Phase 8 not yet implemented.")

func run_scene_tests(_scene_path: String) -> void:
	push_warning("[GoDotter] TestRunner.run_scene_tests() — Phase 8 not yet implemented.")
