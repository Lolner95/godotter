@tool
extends RefCounted
## TODO Phase 2+: GDScript-level static analysis.
## Check for: wrong signal syntax, typed assignment errors, broken node paths,
## missing class_name, cyclic dependencies, confusing preload/load.

func scan_scripts(_index: Dictionary) -> Dictionary:
	# TODO Phase 2: Implement script audit
	return {"status": "not_implemented", "phase": 2}

func check_syntax(path: String) -> Dictionary:
	# TODO Phase 4: Use godot --check-only or LSP to validate syntax
	return {"path": path, "status": "not_implemented", "phase": 4}
