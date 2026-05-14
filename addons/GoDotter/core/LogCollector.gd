@tool
extends RefCounted

## Collects and stores log output from Godot runs (stdout/stderr).
## Phase 5: Will be populated by RuntimeController after each run.
## Phase 6+: Used by /fixlogs to send to the Debug Agent.

var _logs: Dictionary = {}  # run_id -> log text
var _recent_run_id: String = ""

## Live editor / Output stream (thread-safe append via GoDotterEditorLogger).
var _live_mutex := Mutex.new()
var _live_buffer: String = ""

const MAX_LOG_SIZE_BYTES := 512 * 1024  # 512 KB cap per run
const MAX_LIVE_BUFFER_CHARS := 384 * 1024


func record_log(run_id: String, text: String) -> void:
	if not _logs.has(run_id):
		_logs[run_id] = ""
	_logs[run_id] += text
	if _logs[run_id].length() > MAX_LOG_SIZE_BYTES:
		_logs[run_id] = "...[truncated]...\n" + _logs[run_id].substr(-MAX_LOG_SIZE_BYTES)
	_recent_run_id = run_id


func get_log(run_id: String) -> String:
	return _logs.get(run_id, "")


func get_recent_log() -> String:
	if _recent_run_id == "":
		return ""
	return _logs.get(_recent_run_id, "")


func get_recent_run_id() -> String:
	return _recent_run_id


func append_live_capture(fragment: String) -> void:
	if fragment.is_empty():
		return
	_live_mutex.lock()
	_live_buffer += fragment
	if _live_buffer.length() > MAX_LIVE_BUFFER_CHARS:
		_live_buffer = "...[truncated]...\n" + _live_buffer.substr(-MAX_LIVE_BUFFER_CHARS)
	_live_mutex.unlock()


func get_editor_output_tail(max_chars: int = 32000) -> String:
	max_chars = clampi(max_chars, 1024, 200000)
	_live_mutex.lock()
	var s := _live_buffer
	_live_mutex.unlock()
	if s.length() <= max_chars:
		return s
	return s.substr(s.length() - max_chars)


func clear_live_capture() -> void:
	_live_mutex.lock()
	_live_buffer = ""
	_live_mutex.unlock()


## For /fixlogs: prefer live Output capture, then last aggregated run log.
func get_recent_log_for_fix() -> String:
	var live := get_editor_output_tail(200000)
	var run := get_recent_log()
	if live.is_empty():
		return run
	if run.is_empty():
		return live
	return live + "\n--- (older run log buffer) ---\n" + run


func clear_log(run_id: String) -> void:
	_logs.erase(run_id)


func save_log_to_disk(run_id: String) -> String:
	var text := get_log(run_id)
	if text.is_empty():
		return ""
	var base := ProjectSettings.globalize_path("res://") + ".godot_forge/logs/"
	DirAccess.make_dir_recursive_absolute(base)
	var path := base + run_id + ".log"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(text)
		file.close()
	return path


func load_log_from_disk(run_id: String) -> String:
	var path := ProjectSettings.globalize_path("res://") + ".godot_forge/logs/" + run_id + ".log"
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)
