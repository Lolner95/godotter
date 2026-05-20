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
signal mcp_probe_response(data: Dictionary)
signal mcp_route_test_response(data: Dictionary)

var _state: Object  # ForgeState
var _backend_capabilities: Dictionary = {}

const TIMEOUT := 60.0
const TIMEOUT_AGENT_RUN := 180.0
const TIMEOUT_EXECUTE := 180.0
const TIMEOUT_MAX_ADAPTIVE := 900.0
const LONG_REQUEST_MIN_ATTEMPTS := 1
const LONG_REQUEST_MAX_ATTEMPTS := 6
const LONG_REQUEST_RETRYABLE_HTTP := [429, 502, 503, 504]

## Avoid flooding Output + chat when /health fails in a tight loop.
var _health_warn_last_tick_ms: int = 0
const HEALTH_WARN_MIN_INTERVAL_MS := 14000
var _last_effective_timeout_by_endpoint: Dictionary = {}
var _last_effective_attempts_by_endpoint: Dictionary = {}


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
		var ob: String = str(ai.get("openai_base_url", "")).strip_edges()
		if ob == "":
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


func _http_result_kind(result: int) -> String:
	match result:
		HTTPRequest.RESULT_TIMEOUT:
			return "timeout"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "dns"
		HTTPRequest.RESULT_CANT_CONNECT:
			return "connect"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "connection"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "tls"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "no_response"
		HTTPRequest.RESULT_REQUEST_FAILED:
			return "request_failed"
		_:
			return "other"


func _is_retryable_transport_error(result: int) -> bool:
	match result:
		HTTPRequest.RESULT_TIMEOUT:
			return true
		HTTPRequest.RESULT_CANT_RESOLVE:
			return true
		HTTPRequest.RESULT_CANT_CONNECT:
			return true
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return true
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return true
		HTTPRequest.RESULT_NO_RESPONSE:
			return true
		HTTPRequest.RESULT_REQUEST_FAILED:
			return true
		_:
			return false


func _is_retryable_http_status(http_code: int) -> bool:
	return LONG_REQUEST_RETRYABLE_HTTP.has(http_code)


func _retry_delay_seconds(attempt_index: int, network_kind: String = "") -> float:
	var base: float = 1.15
	if network_kind == "dns" or network_kind == "connect":
		base = 2.5
	elif network_kind == "timeout" or network_kind == "no_response":
		base = 1.9
	var expo: float = pow(base, float(max(0, attempt_index)))
	var jitter: float = randf_range(0.0, 0.7)
	return minf(18.0, expo + jitter)


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


func _adaptive_timeout_for_payload(
		base_sec: float,
		payload: Dictionary,
		max_sec: float = TIMEOUT_MAX_ADAPTIVE) -> float:
	var json_len: int = JSON.stringify(payload).length()
	var user_chars: int = str(payload.get("user_request", "")).length()
	var user_lines: int = str(payload.get("user_request", "")).count("\n")
	var extra: float = 0.0
	# Large payloads (big context/images/log tails) need more backend + model time.
	if json_len > 8000:
		extra += (float(json_len - 8000) / 22000.0) * 22.0
	if json_len > 60000:
		extra += (float(json_len - 60000) / 70000.0) * 26.0
	if json_len > 180000:
		extra += (float(json_len - 180000) / 140000.0) * 38.0
	# Very long user prompts (multi-paragraph specs) are much slower on /plan and /agent/run.
	if user_chars > 2000:
		extra += (float(user_chars - 2000) / 2500.0) * 40.0
	if user_chars > 9000:
		extra += (float(user_chars - 9000) / 5000.0) * 55.0
	if user_lines > 30:
		extra += (float(user_lines - 30) / 20.0) * 18.0
	return clampf(base_sec + extra, 25.0, max_sec)


func _resolved_ai_preset_values() -> Dictionary:
	if _state == null:
		return {}
	var ai: Dictionary = _state.settings.get("ai_settings", {})
	var preset: String = str(ai.get("preset", "Deep")).strip_edges()
	var presets: Dictionary = ai.get("presets", {})
	if typeof(presets) == TYPE_DICTIONARY and presets.has(preset):
		var p = presets.get(preset, {})
		if typeof(p) == TYPE_DICTIONARY:
			return p
	return {}


func _configured_retry_attempts() -> int:
	var active: Dictionary = _resolved_ai_preset_values()
	var retries: int = int(active.get("retries", 2))
	return clampi(retries + 1, LONG_REQUEST_MIN_ATTEMPTS, LONG_REQUEST_MAX_ATTEMPTS)


func _configured_timeout_floor() -> float:
	var active: Dictionary = _resolved_ai_preset_values()
	var timeout_sec: float = float(active.get("timeout_sec", 0.0))
	return maxf(0.0, timeout_sec)


func _register_effective_timeout(endpoint: String, timeout_sec: float) -> void:
	_last_effective_timeout_by_endpoint[endpoint] = timeout_sec


func get_last_effective_timeout(endpoint: String) -> float:
	return float(_last_effective_timeout_by_endpoint.get(endpoint, 0.0))


func _register_effective_attempts(endpoint: String, attempts: int) -> void:
	_last_effective_attempts_by_endpoint[endpoint] = max(1, attempts)


func get_last_effective_attempts(endpoint: String) -> int:
	return int(_last_effective_attempts_by_endpoint.get(endpoint, 1))


func get_long_request_budget_seconds(endpoint: String) -> float:
	var timeout_sec: float = get_last_effective_timeout(endpoint)
	var attempts: int = get_last_effective_attempts(endpoint)
	if timeout_sec <= 0.0:
		return 0.0
	# Worst-case upper bound: per-attempt timeout + retry backoff envelope.
	var backoff_envelope: float = float(max(0, attempts - 1)) * 8.0
	return timeout_sec * float(attempts) + backoff_envelope


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
	var payload := _with_model({
		"user_request": user_request,
		"context_bundle": _with_ai_settings_context(context_bundle),
	})
	_post_long(
		_get_base_url() + "/agent/plan",
		payload,
		"_on_plan_done",
		_adaptive_timeout_for_payload(TIMEOUT, payload, 520.0),
	)


func request_fix_from_logs(run_id: String, log_text: String) -> void:
	var payload := _with_model({
		"run_id": run_id,
		"log_text": log_text,
		"context_bundle": _with_ai_settings_context({}),
	})
	_post_long(
		_get_base_url() + "/agent/fix_from_logs",
		payload,
		"_on_fix_logs_done",
		_adaptive_timeout_for_payload(80.0, payload, 260.0),
	)


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
	var endpoint := "/agent/execute"
	var timeout_sec := _adaptive_timeout_for_payload(TIMEOUT_EXECUTE, payload, 600.0)
	timeout_sec = maxf(timeout_sec, _configured_timeout_floor())
	var attempts: int = _configured_retry_attempts()
	_register_effective_timeout(endpoint, timeout_sec)
	_register_effective_attempts(endpoint, attempts)
	_post_long_retryable(
		_get_base_url() + endpoint,
		payload,
		"_on_execute_done",
		timeout_sec,
		attempts,
	)


func request_agent_run(user_request: String, context_bundle: Dictionary, auto_execute: bool = true) -> void:
	var payload := _with_model({
		"user_request": user_request,
		"context_bundle": _with_ai_settings_context(context_bundle),
		"auto_execute": auto_execute,
		"max_plan_repairs": 1,
	})
	var endpoint := "/agent/run"
	var timeout_sec := _adaptive_timeout_for_payload(TIMEOUT_AGENT_RUN, payload, 780.0)
	timeout_sec = maxf(timeout_sec, _configured_timeout_floor())
	var attempts: int = _configured_retry_attempts()
	_register_effective_timeout(endpoint, timeout_sec)
	_register_effective_attempts(endpoint, attempts)
	_post_long_retryable(
		_get_base_url() + endpoint,
		payload,
		"_on_agent_run_done",
		timeout_sec,
		attempts,
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


func request_mcp_probe(base_url: String, probe_id: String = "godot_mcp") -> void:
	var base: String = str(base_url).strip_edges().trim_suffix("/")
	if base == "":
		mcp_probe_response.emit({
			"ok": false,
			"probe_id": probe_id,
			"error": "Empty MCP base URL.",
		})
		return
	_http_get(base + "/openapi.json", Callable(self, "_on_mcp_probe_done").bind(base, probe_id))


func request_mcp_route_smoke(base_url: String, method: String, route_path: String, probe_id: String = "godot_mcp") -> void:
	var base: String = str(base_url).strip_edges().trim_suffix("/")
	var route: String = str(route_path).strip_edges()
	var meth: String = str(method).to_upper().strip_edges()
	if base == "" or route == "" or meth == "":
		mcp_route_test_response.emit({
			"ok": false,
			"probe_id": probe_id,
			"method": meth,
			"path": route,
			"error": "Missing base/method/path.",
		})
		return
	var url: String = base + route
	if meth == "GET":
		_http_get(url, Callable(self, "_on_mcp_route_smoke_done").bind(probe_id, meth, route))
		return
	if meth == "POST":
		_post(url, {}, Callable(self, "_on_mcp_route_smoke_done").bind(probe_id, meth, route))
		return
	# Fallback to GET for unknown method kinds in OpenAPI.
	_http_get(url, Callable(self, "_on_mcp_route_smoke_done").bind(probe_id, meth, route))


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
		data = {"ok": false, "error": "Empty response from /agent/plan."}
	plan_response.emit(data)
	if _state:
		_state.plan_received.emit(data)
		var err_msg: String = _normalized_error_message(data)
		if err_msg != "" or not bool(data.get("ok", true)):
			if err_msg == "":
				err_msg = "Plan generation failed."
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
		if data.is_empty():
			_state.emit_log("error", "Execute failed: backend returned no payload (timeout or server-side error).")
			return
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


func _on_mcp_probe_done(
		result: int,
		code: int,
		_headers: PackedStringArray,
		body: PackedByteArray,
		base_url: String,
		probe_id: String) -> void:
	var payload := {
		"ok": false,
		"probe_id": probe_id,
		"base_url": base_url,
		"http_code": code,
		"routes": [],
	}
	if result != HTTPRequest.RESULT_SUCCESS:
		payload["error"] = _http_result_caption(result)
		mcp_probe_response.emit(payload)
		return
	var body_str: String = body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(body_str)
	if code < 200 or code >= 300 or typeof(parsed) != TYPE_DICTIONARY:
		payload["error"] = "OpenAPI probe failed (%d)." % code
		mcp_probe_response.emit(payload)
		return
	var dict: Dictionary = parsed
	var paths: Dictionary = dict.get("paths", {})
	var routes: Array = []
	for p in paths.keys():
		var methods: Array = []
		var node: Variant = paths.get(p, {})
		if typeof(node) == TYPE_DICTIONARY:
			for mk in (node as Dictionary).keys():
				methods.append(str(mk).to_upper())
		routes.append({
			"path": str(p),
			"methods": methods,
		})
	payload["ok"] = true
	payload["routes"] = routes
	mcp_probe_response.emit(payload)


func _on_mcp_route_smoke_done(
		result: int,
		code: int,
		_headers: PackedStringArray,
		body: PackedByteArray,
		probe_id: String,
		method: String,
		path: String) -> void:
	var reachable: bool = false
	var reason := ""
	if result == HTTPRequest.RESULT_SUCCESS:
		if (code >= 200 and code < 300) or code == 400 or code == 401 or code == 403 or code == 405 or code == 422:
			reachable = true
			reason = "reachable"
		elif code == 404:
			reason = "missing route"
		elif code >= 500:
			reason = "server error"
		else:
			reason = "http %d" % code
	else:
		reason = _http_result_caption(result)
	mcp_route_test_response.emit({
		"ok": reachable,
		"probe_id": probe_id,
		"method": method,
		"path": path,
		"http_code": code,
		"result_code": result,
		"reason": reason,
		"body": body.get_string_from_utf8(),
	})


# --- HTTP helpers ---

func _http_get(url: String, callback) -> void:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	add_child(http)
	var endpoint: String = _endpoint_from_url(url)
	request_started.emit(endpoint)
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


func _invoke_http_callback(callback: String, result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if callback.strip_edges() == "":
		return
	if has_method(callback):
		call(callback, result, code, headers, body)


func _post_long_retryable(
		url: String,
		body: Dictionary,
		callback: String,
		timeout_sec: float,
		max_attempts: int) -> void:
	var endpoint: String = _endpoint_from_url(url)
	var attempts: int = clampi(max_attempts, LONG_REQUEST_MIN_ATTEMPTS, LONG_REQUEST_MAX_ATTEMPTS)
	var payload_json: String = JSON.stringify(body)
	var state := {
		"attempt": 0,
		"max_attempts": attempts,
		"timeout": timeout_sec,
	}
	request_started.emit(endpoint)
	_issue_retryable_long_attempt(url, endpoint, payload_json, callback, state)


func _issue_retryable_long_attempt(
		url: String,
		endpoint: String,
		payload_json: String,
		callback: String,
		retry_state: Dictionary) -> void:
	var attempt: int = int(retry_state.get("attempt", 0))
	var max_attempts: int = int(retry_state.get("max_attempts", 1))
	var timeout_sec: float = float(retry_state.get("timeout", TIMEOUT_AGENT_RUN))
	var http := HTTPRequest.new()
	http.timeout = timeout_sec
	add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
			var should_retry: bool = false
			var kind: String = ""
			if result != HTTPRequest.RESULT_SUCCESS:
				kind = _http_result_kind(result)
				should_retry = _is_retryable_transport_error(result)
			elif code < 200 or code >= 300:
				kind = "http_%d" % code
				should_retry = _is_retryable_http_status(code)

			var can_retry: bool = should_retry and (attempt + 1 < max_attempts)
			if can_retry:
				var next_attempt: int = attempt + 1
				var delay_sec: float = _retry_delay_seconds(next_attempt, kind)
				if _state:
					var msg := (
						"Transient %s on %s. Retry %d/%d in %.1fs."
						% [kind, endpoint, next_attempt + 1, max_attempts, delay_sec]
					)
					if kind == "dns" or kind == "connect" or kind == "no_response":
						msg += " Network may be unstable/offline — waiting longer."
					_state.emit_log("warning", msg)
				http.queue_free()
				retry_state["attempt"] = next_attempt
				var timer := get_tree().create_timer(delay_sec)
				timer.timeout.connect(
					func() -> void:
						_issue_retryable_long_attempt(url, endpoint, payload_json, callback, retry_state),
					CONNECT_ONE_SHOT
				)
				return

			_invoke_http_callback(callback, result, code, headers, body)
			var ok: bool = (result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300)
			request_finished.emit(endpoint, ok, code)
			http.queue_free(),
		CONNECT_ONE_SHOT
	)
	var err := http.request(
		url,
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		payload_json
	)
	if err != OK:
		http.queue_free()
		var kind: String = "request_init_error"
		var can_retry: bool = (attempt + 1 < max_attempts)
		if can_retry:
			var next_attempt: int = attempt + 1
			var delay_sec: float = _retry_delay_seconds(next_attempt, "connect")
			if _state:
				_state.emit_log(
					"warning",
					("Request init failed on %s (err=%d). Retry %d/%d in %.1fs."
						% [endpoint, err, next_attempt + 1, max_attempts, delay_sec])
				)
			retry_state["attempt"] = next_attempt
			var timer := get_tree().create_timer(delay_sec)
			timer.timeout.connect(
				func() -> void:
					_issue_retryable_long_attempt(url, endpoint, payload_json, callback, retry_state),
				CONNECT_ONE_SHOT
			)
			return
		request_finished.emit(endpoint, false, -1)
		request_error.emit(url, "Failed to initiate request (err=%d)" % err)
		if _state:
			_state.emit_log("error", "Request failed: " + url + " (" + kind + ")")


func _parse_response(result: int, code: int, body: PackedByteArray, endpoint: String) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS:
		var cap := _http_result_caption(result)
		if _state:
			_state.set_backend_status(false)
			if endpoint == "/health":
				_emit_throttled_health_warning(
					"Health check failed: %s — tried %s/health (Settings → Backend URL must match the server port; "
					+ "GoDotter may pick another port if the default is busy)."
					% [cap, _get_base_url()]
				)
			else:
				_state.emit_log("warning", "Backend offline or request timeout (" + endpoint + "): " + cap)
		return {"ok": false, "error": "Network error on %s: %s" % [endpoint, cap]}

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
		if code < 200 or code >= 300:
			return {"ok": false, "error": "HTTP %d from %s (empty response body)" % [code, endpoint]}
		return {}

	var parsed = JSON.parse_string(body_str)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		if _state:
			_state.emit_log("error", "Invalid JSON from " + endpoint)
		if code < 200 or code >= 300:
			return {"ok": false, "error": "HTTP %d from %s with invalid JSON body" % [code, endpoint]}
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
