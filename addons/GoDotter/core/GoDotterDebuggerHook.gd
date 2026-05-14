@tool
extends EditorDebuggerPlugin
## Marks editor debug session start/stop in the live log buffer (F5 / remote debug).

var _mark: Callable = Callable()


func setup(mark: Callable) -> void:
	_mark = mark


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	if session == null:
		return
	if not session.started.is_connected(_on_session_started):
		session.started.connect(_on_session_started)
	if not session.stopped.is_connected(_on_session_stopped):
		session.stopped.connect(_on_session_stopped)


func _on_session_started() -> void:
	if _mark.is_valid():
		_mark.call("[GoDotter] Debug session started (game or remote debugger attached).\n")


func _on_session_stopped() -> void:
	if _mark.is_valid():
		_mark.call("[GoDotter] Debug session stopped.\n")
