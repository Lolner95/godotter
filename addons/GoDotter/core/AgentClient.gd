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
signal capabilities_updated(capabilities: Dictionary)
signal request_started(endpoint: String)
signal request_finished(endpoint: String, ok: bool, http_code: int)
signal request_error(endpoint: String, message: String)
signal ai_capabilities_response(data: Dictionary)
signal ai_test_response(data: Dictionary)

var _state: Object  # ForgeState
var _backend_capabilities: Dictionary = {}

const TIMEOUT := 60.0
const TIMEOUT_AGENT_RUN := 240.0
const TIMEOUT_EXECUTE := 240.0

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
	var ai: Dictionary = _state.settings.get("ai_settings", {})
	var m: String = str(ai.get("model", _state.settings.get("model", ""))).strip_edges()
	var provider: String = str(ai.get("provider", "gemini")).to_lower()
	if provider == "gemini" and not m.begins_with("gemini-"):
		m = "gemini-3.1-pro-preview"
	if provider == "claude" and not m.begins_with("claude-"):
		m = "claude-3-7-sonnet"
	if provider == "openai" and not m.begins_with("gpt-"):
		m = "gpt-5"
	if m != "":
		d["model"] = m
	return d


func _with_ai_settings_context(context_bundle: Dictionary) -> Dictionary:
	var ctx: Dictionary = context_bundle.duplicate(true)
	var god: Dictionary = ctx.get("godotter", {})
	if typeof(god) != TYPE_DICTIONARY:
		god = {}
	if _state and typeof(_state.settings.get("ai_settings", null)) == TYPE_DICTIONARY:
		god["ai_settings"] = _state.settings.get("ai_settings", {})
	ctx["godotter"] = god
	return ctx


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


func _endpoint_from_url(url: String) -> String:
	var u: String = url.strip_edges()
	var scheme_idx: int = u.find("://")
	var start: int = 0
	if scheme_idx >= 0:
		start = scheme_idx + 3
	var slash_idx: int = u.find("/", start)
	if slash_idx < 0:
		return "/"
	var endpoint: String = u.substr(slash_idx, u.length() - slash_idx)
	return endpoint if endpoint != "" else "/"


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
			"context_bundle": _with_ai_settings_context(context_bundle),
		}),
		"_on_plan_done")


func request_fix_from_logs(run_id: String, log_text: String) -> void:
	_post(_get_base_url() + "/agent/fix_from_logs",
		_with_model({
			"run_id": run_id,
			"log_text": log_text,
			"context_bundle": _with_ai_settings_context({}),
		}),
		"_on_fix_logs_done")


func request_visual_review_3d(asset_path: String, angle_images: Array, goals: Array) -> void:
	_post(_get_base_url() + "/agent/visual_review_3d",
		_with_model({
			"asset_path": asset_path,
			"angle_images": angle_images,
			"goals": goals,
			"context_bundle": _with_ai_settings_context({}),
		}),
		"_on_visual_review_3d_done")


func get_memory() -> void:
	_http_get(_get_base_url() + "/memory", "_on_memory_done")


func probe_backend_capabilities() -> void:
	_http_get(_get_base_url() + "/openapi.json", "_on_openapi_done")


func supports_route(route: String) -> bool:
	if _backend_capabilities.is_empty():
		return true
	return bool(_backend_capabilities.get(route, false))


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
		"context_bundle": _with_ai_settings_context({}),
	}), "_on_visual_map_done")


func request_execute(user_request: String, context_bundle: Dictionary, plan: Dictionary) -> void:
	var payload := _with_model({
		"user_request": user_request,
		"context_bundle": _with_ai_settings_context(context_bundle),
		"approved": true,
	})
	var unwrapped: Dictionary = _unwrap_plan_for_api(plan)
	if not unwrapped.is_empty():
		payload["plan"] = unwrapped
	_post_long(_get_base_url() + "/agent/execute", payload, "_on_execute_done", TIMEOUT_EXECUTE)


func request_agent_run(user_request: String, context_bundle: Dictionary) -> void:
	_post_long(
		_get_base_url() + "/agent/run",
		_with_model({
			"user_request": user_request,
			"context_bundle": _with_ai_settings_context(context_bundle),
			"auto_execute": true,
			"max_plan_repairs": 2,
		}),
		"_on_agent_run_done",
		TIMEOUT_AGENT_RUN,
	)


func request_ai_capabilities() -> void:
	_http_get(_get_base_url() + "/ai/capabilities", "_on_ai_capabilities_done")


func request_ai_test(context_bundle: Dictionary, prompt: String = "") -> void:
	_post_long(
		_get_base_url() + "/ai/test_model_settings",
		_with_model({
			"context_bundle": _with_ai_settings_context(context_bundle),
			"prompt": prompt,
		}),
		"_on_ai_test_done",
		TIMEOUT,
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
	if not _looks_like_godotter_health(data):
		if _state:
			_state.set_backend_status(false)
			_emit_throttled_health_warning(
				"Health endpoint responded, but this does not look like a GoDotter backend at %s "
				+ "(missing expected fields like version/status). "
				+ "Check Settings → Backend URL or press Stop then Launch backend."
				% _get_base_url()
			)
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
		var err_msg: String = _normalized_error_message(data)
		if err_msg != "":
			_state.emit_log("error", "Plan error: " + err_msg)
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


func _on_openapi_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		return
	var body_str := body.get_string_from_utf8()
	if body_str.is_empty():
		return
	var parsed = JSON.parse_string(body_str)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return
	var caps := {}
	if parsed.has("paths") and typeof(parsed["paths"]) == TYPE_DICTIONARY:
		var paths: Dictionary = parsed["paths"]
		for p in paths.keys():
			caps[str(p)] = true
	_backend_capabilities = caps
	capabilities_updated.emit(_backend_capabilities)


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
			var msg: String = _normalized_error_message(data)
			if msg == "":
				msg = "Request was rejected by backend validation."
			_state.emit_log("error", "Execute failed: " + msg)


func _on_agent_run_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/agent/run")
	agent_run_response.emit(data)
	if _state and not data.is_empty():
		if data.get("plan") != null and typeof(data.get("plan")) == TYPE_DICTIONARY:
			_state.last_plan = data["plan"]
		if data.get("ok", false):
			_state.emit_log("success", "Agent run finished.")
		else:
			var run_err: String = _normalized_error_message(data)
			if run_err != "":
				_state.emit_log("error", "Agent run: " + run_err)


func _on_write_file_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/tools/write_file")
	write_file_response.emit(data)
	if _state:
		if data.get("ok", false):
			_state.emit_log("success", "File written: " + str(data.get("path", "")) +
				" (+%d/-%d lines)" % [data.get("lines_added", 0), data.get("lines_removed", 0)])
		else:
			_state.emit_log("error", "Write failed: " + str(data.get("error", "")))


func _on_ai_capabilities_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/ai/capabilities")
	ai_capabilities_response.emit(data)


func _on_ai_test_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data := _parse_response(result, code, body, "/ai/test_model_settings")
	ai_test_response.emit(data)


# --- HTTP helpers ---

func _http_get(url: String, callback: String) -> void:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	add_child(http)
	var endpoint: String = _endpoint_from_url(url)
	request_started.emit(endpoint)
	http.request_completed.connect(Callable(self, callback), CONNECT_ONE_SHOT)
	http.request_completed.connect(
		func(r, c, _h, _b):
			var ok: bool = (r == HTTPRequest.RESULT_SUCCESS and c >= 200 and c < 300)
			request_finished.emit(endpoint, ok, c),
		CONNECT_ONE_SHOT
	)
	http.request_completed.connect(func(r, c, h, b): http.queue_free(), CONNECT_ONE_SHOT)
	var err := http.request(url, [], HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		request_finished.emit(endpoint, false, -1)
		if _state:
			_state.set_backend_status(false)
			_state.emit_log("warning", "Backend unreachable at " + url)


func _post(url: String, body: Dictionary, callback) -> void:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	add_child(http)
	var endpoint: String = _endpoint_from_url(url)
	request_started.emit(endpoint)
	var json_body := JSON.stringify(body)
	if callback is String:
		http.request_completed.connect(Callable(self, callback), CONNECT_ONE_SHOT)
	elif callback is Callable:
		http.request_completed.connect(callback, CONNECT_ONE_SHOT)
	http.request_completed.connect(
		func(r, c, _h, _b):
			var ok: bool = (r == HTTPRequest.RESULT_SUCCESS and c >= 200 and c < 300)
			request_finished.emit(endpoint, ok, c),
		CONNECT_ONE_SHOT
	)
	http.request_completed.connect(func(r, c, h, b): http.queue_free(), CONNECT_ONE_SHOT)
	var err := http.request(url,
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		json_body)
	if err != OK:
		http.queue_free()
		request_finished.emit(endpoint, false, -1)
		request_error.emit(url, "Failed to initiate request (err=%d)" % err)
		if _state:
			_state.emit_log("error", "Request failed: " + url)


func _post_long(url: String, body: Dictionary, callback: String, timeout_sec: float) -> void:
	var http := HTTPRequest.new()
	http.timeout = timeout_sec
	add_child(http)
	var endpoint: String = _endpoint_from_url(url)
	request_started.emit(endpoint)
	var json_body := JSON.stringify(body)
	http.request_completed.connect(Callable(self, callback), CONNECT_ONE_SHOT)
	http.request_completed.connect(
		func(r, c, _h, _b):
			var ok: bool = (r == HTTPRequest.RESULT_SUCCESS and c >= 200 and c < 300)
			request_finished.emit(endpoint, ok, c),
		CONNECT_ONE_SHOT
	)
	http.request_completed.connect(func(r, c, h, b): http.queue_free(), CONNECT_ONE_SHOT)
	var err := http.request(url,
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		json_body)
	if err != OK:
		http.queue_free()
		request_finished.emit(endpoint, false, -1)
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
			if code == 404 and endpoint != "/health":
				_state.set_backend_status(false)
				_state.emit_log(
					"warning",
					"HTTP 404 from %s — backend route not found. "
					+ "This usually means Backend URL points to another service or an outdated backend. "
					+ "Try Stop + Launch backend in GoDotter." % endpoint
				)
			else:
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

	if code < 200 or code >= 300:
		if _normalized_error_message(parsed) == "":
			var detail_msg: String = _extract_http_detail_message(parsed.get("detail", null))
			if detail_msg != "":
				parsed["error"] = detail_msg

	return parsed


func _looks_like_godotter_health(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	if str(data.get("status", "")).to_lower() != "ok":
		return false
	if str(data.get("version", "")).strip_edges() == "":
		return false
	var has_key_state: bool = data.has("api_key_present") or data.has("gemini_key_present")
	return has_key_state


func _normalized_error_message(data: Dictionary) -> String:
	if data == null or not data.has("error"):
		return ""
	var v = data.get("error", null)
	if v == null:
		return ""
	var s: String = str(v).strip_edges()
	if s == "" or s == "<null>" or s.to_lower() == "null":
		return ""
	return s


func _extract_http_detail_message(detail) -> String:
	if detail == null:
		return ""
	if typeof(detail) == TYPE_STRING:
		return str(detail).strip_edges()
	if typeof(detail) == TYPE_ARRAY:
		var parts: Array[String] = []
		for item in detail:
			if typeof(item) == TYPE_DICTIONARY:
				var d: Dictionary = item
				var locv = d.get("loc", [])
				var loc: String = ".".join(locv) if typeof(locv) == TYPE_ARRAY else str(locv)
				var msg: String = str(d.get("msg", "")).strip_edges()
				if msg != "":
					if loc != "":
						parts.append(loc + ": " + msg)
					else:
						parts.append(msg)
			elif item != null:
				parts.append(str(item))
		return "; ".join(parts)
	if typeof(detail) == TYPE_DICTIONARY:
		var dd: Dictionary = detail
		if dd.has("msg"):
			return str(dd.get("msg", "")).strip_edges()
	return str(detail).strip_edges()
