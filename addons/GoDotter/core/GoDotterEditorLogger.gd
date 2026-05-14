@tool
extends Logger
## Captures Godot's internal log stream (prints, stderr, script errors) into LogCollector.
## Called from worker threads — only buffer here; drain on the main thread.

var _collector: Object = null
var _mutex := Mutex.new()
var _pending: String = ""


func setup(collector: Object) -> void:
	_collector = collector


func drain_pending_to_collector() -> void:
	if _collector == null or not _collector.has_method("append_live_capture"):
		return
	_mutex.lock()
	var chunk := _pending
	_pending = ""
	_mutex.unlock()
	if chunk != "":
		_collector.append_live_capture(chunk)


func _push_line(line: String) -> void:
	if line.is_empty():
		return
	_mutex.lock()
	_pending += line
	_mutex.unlock()


func _log_message(message: String, is_error: bool) -> void:
	var tag := "stderr" if is_error else "stdout"
	_push_line("[%s] %s\n" % [tag, message])


func _log_error(
	_function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	_error_type: int,
	_script_backtraces: Array,
) -> void:
	var loc := ""
	if file != "":
		loc = "%s:%d " % [file, line]
	var core := code if code != "" else rationale
	_push_line("SCRIPT ERROR: %s%s\n" % [loc, core])
