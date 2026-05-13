@tool
extends RefCounted
## TODO Phase 2+: Local memory index search.
## Reads .godot_forge/memory/*.md files and provides keyword search.
## Later: vector embeddings for semantic memory search.

const MEMORY_DIR_RELATIVE := ".godot_forge/memory/"

func read_all() -> Dictionary:
	var base := ProjectSettings.globalize_path("res://") + MEMORY_DIR_RELATIVE
	var result := {}
	var files := ["architecture.md", "style_guide.md", "known_bugs.md", "validation_recipes.md"]
	for f: String in files:
		var path: String = base + f
		if FileAccess.file_exists(path):
			result[f.get_basename()] = FileAccess.get_file_as_string(path)
	return result

func search(_query: String) -> Array:
	# TODO Phase 2+: keyword/semantic search across memory files
	return []

func write_fact(_category: String, _fact: String) -> void:
	# TODO Phase 2+: Append fact to appropriate memory file
	push_warning("[GoDotter] MemoryIndex.write_fact() — Phase 2+ not yet implemented.")
