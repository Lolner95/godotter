@tool
extends Node

## HTTP client for communicating with the local godot_forge_agent backend.
## Uses Godot's HTTPRequest node. All requests are non-blocking.
## Emits signals on completion, provides graceful offline mode.

signal health_response(data: Dictionary)
signal plan_response(data: Dictionary)
signal index_response(data: Dictionary)
signal context_response(data: Dictionary)
signal fix_logs_response(data: Dictionary)
signal visual_review_3d_response(data: Dictionary)
signal visual_map_response(data: Dictionary)
signal execute_response(data: Dictionary)
signal agent_run_response(data: Dictionary)
signal write_file_response(data: Dictionary)
signal memory_response(data: Dictionary)
signal request_error(endpoint: String, message: String)

var _state: Object  # ForgeState

const TIMEOUT := 60.0
const TIMEOUT_AGENT_RUN := 240.0

## Avoid flooding Output + chat when /health fails in a tight loop.
var _health_warn_last_tick_ms: int = 0
const HEALTH_WARN_MIN_INTERVAL_MS := 14000


func setup(state: Object) -> void:
	_state = state


func reset_health_warning_throttle() -> void:
	_health_warn_last_tick_ms = 0


func _emit_throttled_health_warning(message: String) -> void:
	if _state == null:
		return
	var now: int = Time.get_ticks_msec()
	if now - _health_warn_last_tick_ms < HEALTH_WARN_MIN_INTERVAL_MS:
		return
	_health_warn_last_tick_ms = now
	_state.emit_log("warning", message)


func _with_model(body: Dictionary) -> Dictionary:
	var d := body.duplicate()
	if _state == null:
		return d
	var m: String = str(_state.settings.get("model", "")).strip_edges()
	if m != "":
		d["model"] = m
	return d


func _get_base_url() -> String:
	if _state and _state.has_method("normalized_backend_http_base"):
		return str(_state.normalized_backend_http_base()).rstrip("/")
	if _state:
		return str(_state.backend_url).rstrip("/")
	return "http://127.0.0.1:8765"


func _http_result_caption(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "cannot connect (wrong host/port or server not listening yet?)"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "DNS resolve failed"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "connection error"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS handshake error"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "no response"
		HTTPRequest.RESULT_REQUEST_FAILED:
			return "request failed"
		HTTPRequest.RESULT_TIMEOUT:
			return "timeout"
		_:
			return "HTTP result code %d" % result


# --- Public API ---

func get_health() -> void:
	_http_get(_get_base_url() + "/health", "_on_health_done")


# Alias used by ForgeDock health timer
func check_health() -> void:
	get_health()


func request_index(project_root: String) -> void:
	_post(_get_base_url() + "/project/index",
		{"project_root": project_root},
		"_on_index_done")


func request_context(query: String, project_root: String) -> void:
	_post(_get_base_url() + "/project/context",
		{"query": query, "project_root": project_root},
		"_on_context_done")


func request_plan(user_request: String, context_bundle: Dictionary) -> void:
	_post(_get_base_url() + "/agent/plan",
		_with_model({
			"user_request": user_request,
			"context_bundle": context_bundle,
		}),
		"_on_plan_done")


func request_fix_from_logs(run_id: String, log_text: String) -> void:
	_post(_get_base_url() + "/agent/fix_from_logs",
		_with_model({
			"run_id": run_id,
			"log_text": log_text,
		}),
		"_on_fix_logs_done")


func request_visual_review_3d(asset_path: String, angle_images: Array, goals: Array) -> void:
	_post(_get_base_url() + "/agent/visual_review_3d",
		_with_model({
			"asset_path": asset_path,
			"angle_images": angle_images,
			"goals": goals,
		}),
		"_on_visual_review_3d_done")


func get_memory() -> void:
	_http_get(_get_base_url() + "/memory", "_on_memory_done")


func request_visual_map(
		screenshot_b64: String,
		node_map: Array,
		color_legend: Dictionary,
		scene_path: String,
		query: String) -> void:
	_post(_get_base_url() + "/agent/visual_map", _with_model({
		"screenshot_base64": screenshot_b64,
		"node_map": node_map,
		"color_legend": color_legend,
		"scene_path": scene_path,
		"query": query,
	}), "_on_visual_map_done")


func request_execute(user_request: String, context_bundle: Dictionary, plan: Dictionary) -> void:
	_post(_get_base_url() + "/agent/execute", _with_model({
		"user_request": user_request,
		"context_bundle": context_bundle,
		"plan": _unwrap_plan_for_api(plan),
		"approved": true,
	}), "_on_execute_done")


func request_agent_run(user_request: String, context_bundle: Dictionary) -> void:
	_post_long(
		_get_base_url() + "/agent/run",
		_with_model({
			"user_request": user_request,
			"context_bundle": context_bundle,
			"auto_execute": true,
			"max_plan_repairs": 2,
		}),
		"_on_agent_run_done",
		TIMEOUT_AGENT_RUN,
	)


func _unwrap_plan_for_api(plan: Dictionary) -> Dictionary:
	if plan.is_empty():
		return {}
	if plan.has("plan") and typeof(plan["plan"]) == TYPE_DICTIONARY:
		return plan["plan"]
	return plan


func request_write_file(path: String, new_content: String, task_id: String, reason: String) -> void:
	_post(_get_base_url() + "/tools/write_file", {
		"path": path,
		"new_content": new_content,
		"task_id": task_id,
		"reason": reason,
		"create_checkpoint": true,
	}, "_on_write_file_done")


# --- Response handlers ---

func _on_health_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/health")
	if data.is_empty():
		if _state:
			_state.set_backend_status(false)
		return
	if _state:
		_state.set_backend_status(true, data)
	reset_health_warning_throttle()
	health_response.emit(data)


func _on_index_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/project/index")
	if data.is_empty():
		return
	if _state and data.has("index"):
		_state.project_index = data.get("index", {})
		_state.index_last_updated = Time.get_unix_time_from_system()
	index_response.emit(data)
	if _state:
		_state.emit_log("success", "Project indexed: %d scenes, %d scripts" % [
			data.get("scene_count", 0),
			data.get("script_count", 0),
		])


func _on_context_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/project/context")
	context_response.emit(data)


func _on_plan_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/agent/plan")
	if data.is_empty():
		return
	plan_response.emit(data)
	if _state:
		_state.plan_received.emit(data)
		if data.has("error"):
			_state.emit_log("error", "Plan error: " + str(data.get("error", "")))
		else:
			_state.emit_log("success", "Plan received.")
			if data.get("ok", false) and data.get("plan") != null and typeof(data.get("plan")) == TYPE_DICTIONARY:
				_state.last_plan = data["plan"]
			else:
				_state.last_plan = data


func _on_fix_logs_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/agent/fix_from_logs")
	fix_logs_response.emit(data)
	if _state:
		_state.plan_received.emit(data)


func _on_visual_review_3d_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/agent/visual_review_3d")
	visual_review_3d_response.emit(data)
	if _state:
		_state.plan_received.emit(data)


func _on_memory_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/memory")
	memory_response.emit(data)
	if _state and data.has("memory"):
		_state.emit_log("info", str(data.get("memory", "")))


func _on_visual_map_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/agent/visual_map")
	visual_map_response.emit(data)
	if _state:
		if data.get("ok", false):
			var analysis: Dictionary = data.get("analysis", {})
			var summary: String = analysis.get("scene_summary", "")
			_state.emit_log("success", "[Neon Map] " + summary)
			var findings: Array = analysis.get("spatial_findings", [])
			for f in findings:
				var severity: String = f.get("severity", "info")
				var msg: String = f.get("finding", "")
				var node_path: String = f.get("node_path", "")
				match severity:
					"error":
						_state.emit_log("error", "  %s: %s" % [node_path, msg])
					"warning":
						_state.emit_log("warning", "  %s: %s" % [node_path, msg])
					_:
						_state.emit_log("info", "  %s: %s" % [node_path, msg])
			var recs: Array = analysis.get("recommendations", [])
			if not recs.is_empty():
				_state.emit_log("info", "[b]Recommendations:[/b]")
				for r in recs:
					_state.emit_log("info", "  • " + str(r))
			var qa: String = analysis.get("query_answer", "")
			if not qa.is_empty():
				_state.emit_log("success", "[b]Query Answer:[/b] " + qa)
		else:
			_state.emit_log("error", "Visual map error: " + str(data.get("error", "")))


func _on_execute_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/agent/execute")
	execute_response.emit(data)
	if _state:
		if data.get("ok", false):
			var files: Array = data.get("files_written", [])
			_state.emit_log("success", "Code Agent wrote %d file(s)." % files.size())
			for f in files:
				_state.emit_log("info", "  • " + str(f))
			if data.has("git_checkpoint"):
				var gcs: String = str(data.get("git_checkpoint", ""))
				_state.emit_log("info", "Git checkpoint: " + gcs.substr(0, mini(8, gcs.length())))
		else:
			_state.emit_log("error", "Execute failed: " + str(data.get("error", "")))


func _on_agent_run_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/agent/run")
	agent_run_response.emit(data)
	if _state and not data.is_empty():
		if data.get("ok", false) and data.get("plan") != null and typeof(data.get("plan")) == TYPE_DICTIONARY:
			_state.last_plan = data["plan"]
			_state.emit_log("success", "Agent run finished.")
		elif data.get("error"):
			_state.emit_log("error", "Agent run: " + str(data.get("error", "")))


func _on_write_file_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/tools/write_file")
	write_file_response.emit(data)
	if _state:
		if data.get("ok", false):
			_state.emit_log("success", "File written: " + str(data.get("path", "")) +
				" (+%d/-%d lines)" % [data.get("lines_added", 0), data.get("lines_removed", 0)])
		else:
			_state.emit_log("error", "Write failed: " + str(data.get("error", "")))


# --- HTTP helpers ---

func _http_get(url: String, callback: String) -> void:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	add_child(http)
	http.request_completed.connect(Callable(self, callback), CONNECT_ONE_SHOT)
	http.request_completed.connect(func(r, c, h, b): http.queue_free(), CONNECT_ONE_SHOT)
	var err := http.request(url, [], HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		if _state:
			_state.set_backend_status(false)
			_state.emit_log("warning", "Backend unreachable at " + url)


func _post(url: String, body: Dictionary, callback) -> void:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	add_child(http)
	var json_body := JSON.stringify(body)
	if callback is String:
		http.request_completed.connect(Callable(self, callback), CONNECT_ONE_SHOT)
	elif callback is Callable:
		http.request_completed.connect(callback, CONNECT_ONE_SHOT)
	http.request_completed.connect(func(r, c, h, b): http.queue_free(), CONNECT_ONE_SHOT)
	var err := http.request(url,
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		json_body)
	if err != OK:
		http.queue_free()
		request_error.emit(url, "Failed to initiate request (err=%d)" % err)
		if _state:
			_state.emit_log("error", "Request failed: " + url)


func _post_long(url: String, body: Dictionary, callback: String, timeout_sec: float) -> void:
	var http := HTTPRequest.new()
	http.timeout = timeout_sec
	add_child(http)
	var json_body := JSON.stringify(body)
	http.request_completed.connect(Callable(self, callback), CONNECT_ONE_SHOT)
	http.request_completed.connect(func(r, c, h, b): http.queue_free(), CONNECT_ONE_SHOT)
	var err := http.request(url,
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		json_body)
	if err != OK:
		http.queue_free()
		request_error.emit(url, "Failed to initiate request (err=%d)" % err)
		if _state:
			_state.emit_log("error", "Request failed: " + url)


func _parse_response(result: int, code: int, body: PackedByteArray, endpoint: String) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS:
		if _state:
			_state.set_backend_status(false)
			var cap := _http_result_caption(result)
			if endpoint == "/health":
				_emit_throttled_health_warning(
					"Health check failed: %s — tried %s/health (Settings → Backend URL must match the server port; "
					+ "GoDotter may pick another port if the default is busy)."
					% [cap, _get_base_url()]
				)
			else:
				_state.emit_log("warning", "Backend offline or request timeout (" + endpoint + "): " + cap)
		return {}

	if code < 200 or code >= 300:
		if _state:
			_state.emit_log("warning", "HTTP %d from %s" % [code, endpoint])
		# Still try to parse error body
		pass

	var body_str := body.get_string_from_utf8()
	if body_str.is_empty():
		return {}

	var parsed = JSON.parse_string(body_str)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		if _state:
			_state.emit_log("error", "Invalid JSON from " + endpoint)
		return {}

	return parsed
