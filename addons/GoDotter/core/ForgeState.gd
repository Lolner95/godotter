@tool
extends RefCounted

## Shared plugin state — passed by reference to every subsystem.
##
## Two separate settings namespaces:
##   MACHINE_SETTINGS  → stored in EditorSettings (per Godot install, any project)
##   PROJECT_SETTINGS  → stored in EditorSettings too, but keyed per-project path
##
## This lets GoDotter work in ANY project without touching the project's files.

signal backend_status_changed(online: bool)
signal settings_changed()
signal task_started(task_id: String)
signal task_finished(task_id: String, success: bool)
signal plan_received(plan: Dictionary)
signal log_message(level: String, message: String)
signal setup_state_changed(complete: bool)

# ---------------------------------------------------------------------------
# Backend connection (runtime, not persisted)
# ---------------------------------------------------------------------------
var backend_url: String = "http://127.0.0.1:8765"
var backend_online: bool = false
var backend_version: String = ""
var backend_gemini_key_present: bool = false  # legacy flag used by existing UI checks
var backend_api_keys_present: Dictionary = {"gemini": false, "openai": false, "claude": false}
var backend_model: String = ""
var backend_pid: int = -1  # PID of the process we launched, -1 if not ours

# ---------------------------------------------------------------------------
# Editor plugin reference
# ---------------------------------------------------------------------------
var editor_plugin: EditorPlugin = null

# ---------------------------------------------------------------------------
# Machine-level settings (EditorSettings — apply to ALL projects on this machine)
# ---------------------------------------------------------------------------
## Path to the godot_forge_agent directory (e.g. /home/user/GoDotter/tools/godot_forge_agent)
## or C:\GoDotter\tools\godot_forge_agent on Windows.
var backend_dir: String = ""

## Path to the Python executable inside the venv.
## Windows: <backend_dir>/.venv/Scripts/python.exe
## macOS/Linux: <backend_dir>/.venv/bin/python
var backend_python: String = ""

## If true, GoDotter tries to launch the backend automatically when the plugin loads.
var autostart_backend: bool = true

## Legacy single API key (kept for backward compatibility, mapped to Gemini).
var api_key: String = ""
## Provider-aware API keys (machine-wide). Synced to backend key files on save.
var provider_api_keys: Dictionary = {
	"gemini": "",
	"openai": "",
	"claude": "",
}

## Whether the user completed the setup wizard for **this Godot project** (EditorSettings, per project).
var is_setup_complete: bool = false

const _MACHINE_PREFIX := "godotter/machine/"

# ---------------------------------------------------------------------------
# Per-project settings (EditorSettings — keyed by project path)
# ---------------------------------------------------------------------------
var settings: Dictionary = {
	"backend_url":           "http://127.0.0.1:8765",
	"model":                 "gemini-3.1-pro-preview",
	"max_output_tokens":     131072,
	"max_input_tokens":      2000000,
	"temperature":           0.2,
	"ai_settings": {
		"provider": "gemini",
		"model": "gemini-3.1-pro-preview",
		"preset": "Deep",
		"presets": {
			"Fast": {
				"temperature": 0.2,
				"top_p": 0.9,
				"max_output_tokens": 32768,
				"thinking_level": "LOW",
				"thinking_summaries": false,
				"streaming": false,
				"timeout_sec": 90,
				"retries": 1
			},
			"Balanced": {
				"temperature": 0.2,
				"top_p": 0.9,
				"max_output_tokens": 65536,
				"thinking_level": "MEDIUM",
				"thinking_summaries": false,
				"streaming": false,
				"timeout_sec": 120,
				"retries": 2
			},
			"Deep": {
				"temperature": 0.2,
				"top_p": 0.9,
				"max_output_tokens": 131072,
				"thinking_level": "HIGH",
				"thinking_summaries": true,
				"streaming": false,
				"timeout_sec": 150,
				"retries": 2
			},
			"Extreme": {
				"temperature": 0.2,
				"top_p": 0.9,
				"max_output_tokens": 131072,
				"thinking_level": "HIGH",
				"thinking_summaries": true,
				"streaming": false,
				"timeout_sec": 180,
				"retries": 3
			}
		}
	},
	"mcp_settings": {
		"name": "Godot MCP",
		"base_url": "http://127.0.0.1:4000",
		"auto_probe_on_open": true,
	},
	"approval_mode":         "review",  # review | assisted | autopilot | yolo
	"max_files_per_run":     20,
	"max_lines_per_file":    500,
	"enable_file_edits":     false,
	"enable_scene_edits":    false,
	"enable_screenshots":    true,
	"enable_auto_run_tests": false,
}

const _PROJECT_PREFIX := "godotter/project/"
## How many TCP ports to try after the preferred port (inclusive) when auto-picking a free listen port.
const BACKEND_PORT_SCAN_SPAN := 64

# ---------------------------------------------------------------------------
# Active state (runtime)
# ---------------------------------------------------------------------------
var active_task_id: String = ""
var active_task_status: String = ""
var project_index: Dictionary = {}
var project_root: String = ""
var index_last_updated: int = 0
var last_plan: Dictionary = {}


func initialize(plugin: EditorPlugin) -> void:
	editor_plugin = plugin
	project_root = ProjectSettings.globalize_path("res://")
	_load_machine_settings()
	_load_project_settings()
	_load_wizard_completed()
	backend_url = settings.get("backend_url", backend_url)


## Host + TCP port parsed from [member backend_url] (or defaults). Used to match uvicorn to health checks.
func get_backend_tcp_listen() -> Dictionary:
	var raw: String = str(backend_url).strip_edges().trim_suffix("/")
	if raw.is_empty():
		return {"host": "127.0.0.1", "port": 8765}
	var rest := raw
	if rest.begins_with("https://"):
		rest = rest.substr(8)
	elif rest.begins_with("http://"):
		rest = rest.substr(7)
	var slash := rest.find("/")
	if slash >= 0:
		rest = rest.substr(0, slash)
	# Handle IPv6 literals: [::1]:8765 or [::1]
	if rest.begins_with("["):
		var close_idx: int = rest.find("]")
		if close_idx > 0:
			var host_v6: String = rest.substr(1, close_idx - 1)
			var remain_v6: String = rest.substr(close_idx + 1).strip_edges()
			var port_v6: int = 8765
			if remain_v6.begins_with(":"):
				var p6: String = remain_v6.substr(1).strip_edges()
				if p6.is_valid_int():
					var p6n: int = int(p6)
					if p6n >= 1 and p6n <= 65534:
						port_v6 = p6n
			return {"host": host_v6, "port": port_v6}
	var host := "127.0.0.1"
	var port := 8765
	var colon := rest.rfind(":")
	if colon > 0:
		host = rest.substr(0, colon)
		var ps := rest.substr(colon + 1).strip_edges()
		if ps.is_valid_int():
			var parsed_port: int = int(ps)
			if parsed_port >= 1 and parsed_port <= 65534:
				port = parsed_port
	elif rest != "":
		host = rest
	if host.to_lower() == "localhost":
		host = "127.0.0.1"
	return {"host": host, "port": port}


## Normalized base URL (localhost → 127.0.0.1) so Godot HTTPRequest hits the same stack uvicorn binds.
func normalized_backend_http_base() -> String:
	var raw_full: String = str(backend_url).strip_edges().trim_suffix("/")
	var scheme := "http"
	if raw_full.begins_with("https://"):
		scheme = "https"
	var d: Dictionary = get_backend_tcp_listen()
	return "%s://%s:%d" % [scheme, d["host"], int(d["port"])]


## True if we can bind TCP [code]host:port[/code] right now (nothing else listening on that address).
func is_tcp_listen_available(host: String, port: int) -> bool:
	var h: String = host.strip_edges()
	if h.to_lower() == "localhost":
		h = "127.0.0.1"
	var srv := TCPServer.new()
	var err: int = srv.listen(port, h)
	srv.stop()
	return err == OK


## First free port in [preferred_port, preferred_port + BACKEND_PORT_SCAN_SPAN). Returns [code]-1[/code] if none found.
func pick_backend_listen_port(host: String, preferred_port: int) -> int:
	var h: String = host.strip_edges()
	if h.to_lower() == "localhost":
		h = "127.0.0.1"
	var lo: int = clampi(preferred_port, 1, 65534)
	var hi: int = mini(lo + BACKEND_PORT_SCAN_SPAN - 1, 65534)
	for p in range(lo, hi + 1):
		if is_tcp_listen_available(h, p):
			return p
	return -1


## Point the editor + HTTP client at [code]host:port[/code] and persist to project EditorSettings.
func apply_auto_backend_url(host: String, port: int) -> void:
	var raw_full: String = str(backend_url).strip_edges().trim_suffix("/")
	var scheme := "http"
	if raw_full.begins_with("https://"):
		scheme = "https"
	var h: String = host.strip_edges()
	if h.to_lower() == "localhost":
		h = "127.0.0.1"
	var u: String = "%s://%s:%d" % [scheme, h, port]
	backend_url = u
	settings["backend_url"] = u
	save_settings()


# ---------------------------------------------------------------------------
# Machine settings
# ---------------------------------------------------------------------------

func _load_machine_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	_es_load_or_default(es, _MACHINE_PREFIX + "backend_dir",        "")
	_es_load_or_default(es, _MACHINE_PREFIX + "backend_python",     "")
	_es_load_or_default(es, _MACHINE_PREFIX + "autostart_backend",  true)
	_es_load_or_default(es, _MACHINE_PREFIX + "api_key",            "")
	_es_load_or_default(es, _MACHINE_PREFIX + "provider_api_keys",  provider_api_keys.duplicate(true))

	backend_dir        = es.get_setting(_MACHINE_PREFIX + "backend_dir")
	backend_python     = es.get_setting(_MACHINE_PREFIX + "backend_python")
	autostart_backend  = es.get_setting(_MACHINE_PREFIX + "autostart_backend")
	api_key            = str(es.get_setting(_MACHINE_PREFIX + "api_key"))
	var raw_provider_keys: Variant = es.get_setting(_MACHINE_PREFIX + "provider_api_keys")
	provider_api_keys = {"gemini": "", "openai": "", "claude": ""}
	if typeof(raw_provider_keys) == TYPE_DICTIONARY:
		for p in provider_api_keys.keys():
			provider_api_keys[p] = str((raw_provider_keys as Dictionary).get(p, "")).strip_edges()
	if str(provider_api_keys.get("gemini", "")).strip_edges() == "" and api_key.strip_edges() != "":
		provider_api_keys["gemini"] = api_key.strip_edges()
	api_key = str(provider_api_keys.get("gemini", "")).strip_edges()


func save_machine_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	api_key = str(provider_api_keys.get("gemini", api_key)).strip_edges()
	es.set_setting(_MACHINE_PREFIX + "backend_dir",        backend_dir)
	es.set_setting(_MACHINE_PREFIX + "backend_python",     backend_python)
	es.set_setting(_MACHINE_PREFIX + "autostart_backend",  autostart_backend)
	es.set_setting(_MACHINE_PREFIX + "api_key",            api_key)
	es.set_setting(_MACHINE_PREFIX + "provider_api_keys",  provider_api_keys.duplicate(true))
	settings_changed.emit()
	sync_backend_api_key_file()


func _wizard_done_editor_key() -> String:
	return "godotter/proj_wizard/" + str(abs(project_root.hash())) + "/setup_done"


func _load_wizard_completed() -> void:
	var es := EditorInterface.get_editor_settings()
	var k := _wizard_done_editor_key()
	_es_load_or_default(es, k, false)
	is_setup_complete = bool(es.get_setting(k))


func mark_setup_complete() -> void:
	is_setup_complete = true
	var es := EditorInterface.get_editor_settings()
	es.set_setting(_wizard_done_editor_key(), true)
	save_machine_settings()
	setup_state_changed.emit(true)


func reset_wizard_completed() -> void:
	is_setup_complete = false
	var es := EditorInterface.get_editor_settings()
	es.set_setting(_wizard_done_editor_key(), false)
	setup_state_changed.emit(false)


# ---------------------------------------------------------------------------
# Project settings
# ---------------------------------------------------------------------------

func _load_project_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	for key in settings.keys():
		_es_load_or_default(es, _PROJECT_PREFIX + key, settings[key])
		settings[key] = es.get_setting(_PROJECT_PREFIX + key)


func save_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	for key in settings.keys():
		es.set_setting(_PROJECT_PREFIX + key, settings[key])
	backend_url = settings.get("backend_url", backend_url)
	settings_changed.emit()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _es_load_or_default(es: EditorSettings, key: String, default) -> void:
	if not es.has_setting(key):
		es.set_setting(key, default)


func set_backend_status(online: bool, info: Dictionary = {}) -> void:
	backend_online = online
	if not online:
		backend_gemini_key_present = false
		backend_api_keys_present = {"gemini": false, "openai": false, "claude": false}
		backend_version = ""
		backend_model = ""
		backend_status_changed.emit(online)
		return
	if info.has("version"):
		backend_version = info.get("version", "")
	if info.has("api_keys_present") and typeof(info.get("api_keys_present", {})) == TYPE_DICTIONARY:
		var keys_present: Dictionary = info.get("api_keys_present", {})
		backend_api_keys_present = {
			"gemini": bool(keys_present.get("gemini", false)),
			"openai": bool(keys_present.get("openai", false)),
			"claude": bool(keys_present.get("claude", false)),
		}
		backend_gemini_key_present = bool(backend_api_keys_present.get("gemini", false))
	elif info.has("gemini_key_present") or info.has("api_key_present"):
		backend_gemini_key_present = bool(
			info.get("api_key_present", info.get("gemini_key_present", false))
		)
		backend_api_keys_present = {
			"gemini": backend_gemini_key_present,
			"openai": false,
			"claude": false,
		}
	if info.has("model"):
		backend_model = info.get("model", "")
	backend_status_changed.emit(online)


func emit_log(level: String, message: String) -> void:
	log_message.emit(level, message)
	match level:
		"error":   push_error("[GoDotter] " + message)
		"warning": push_warning("[GoDotter] " + message)
		_:         print("[GoDotter] " + message)


## Derive the Python venv executable from backend_dir if not set explicitly.
func get_effective_python() -> String:
	if backend_python != "":
		return backend_python
	if backend_dir == "":
		var h0: String = find_host_python_executable()
		return h0 if h0 != "" else "python"
	# Windows venv convention
	var win := backend_dir.path_join(".venv/Scripts/python.exe")
	if FileAccess.file_exists(win):
		return win
	# Unix venv convention
	var unix := backend_dir.path_join(".venv/bin/python")
	if FileAccess.file_exists(unix):
		return unix
	var host: String = find_host_python_executable()
	return host if host != "" else "python"


func editor_api_key_configured() -> bool:
	return str(provider_api_keys.get("gemini", api_key)).strip_edges() != ""


func editor_any_api_key_configured() -> bool:
	for p in provider_api_keys.keys():
		if str(provider_api_keys.get(p, "")).strip_edges() != "":
			return true
	return false


func get_provider_api_key(provider: String) -> String:
	var p: String = provider.to_lower().strip_edges()
	if p == "":
		p = "gemini"
	return str(provider_api_keys.get(p, "")).strip_edges()


func set_provider_api_key(provider: String, key: String) -> void:
	var p: String = provider.to_lower().strip_edges()
	if p == "":
		p = "gemini"
	if not provider_api_keys.has(p):
		provider_api_keys[p] = ""
	provider_api_keys[p] = key.strip_edges()
	if p == "gemini":
		api_key = str(provider_api_keys[p]).strip_edges()


func _global_backend_dir() -> String:
	var b: String = backend_dir.strip_edges()
	if b == "":
		return ""
	if b.begins_with("res://"):
		return ProjectSettings.globalize_path(b)
	return b


## First python/py/python3 on PATH that runs --version successfully (editor-only helper).
func find_host_python_executable() -> String:
	var candidates: Array = []
	if OS.get_name() == "Windows":
		candidates = [
			["python", PackedStringArray(["--version"])],
			["py", PackedStringArray(["-3", "--version"])],
			["python3", PackedStringArray(["--version"])],
		]
	else:
		candidates = [
			["python3", PackedStringArray(["--version"])],
			["python", PackedStringArray(["--version"])],
		]
	for item in candidates:
		var exe: String = str(item[0])
		var args: PackedStringArray = item[1]
		var out: Array = []
		var code: int = OS.execute(exe, args, out, true, false)
		if code == 0:
			return exe
	return ""


## Creates backend/.venv if missing using a host Python. Returns {ok, message|error}.
func ensure_backend_venv() -> Dictionary:
	var base: String = _global_backend_dir()
	if base == "":
		return {"ok": false, "error": "Backend directory is empty."}
	var win_path: String = base.path_join(".venv/Scripts/python.exe")
	var unix_path: String = base.path_join(".venv/bin/python")
	if FileAccess.file_exists(win_path) or FileAccess.file_exists(unix_path):
		return {"ok": true, "message": "Python venv already exists."}
	var host: String = find_host_python_executable()
	if host == "":
		return {
			"ok": false,
			"error": "No Python found on PATH. Install Python 3.10+ (wizard: Install Python button on Windows).",
		}
	var venv_dir: String = base.path_join(".venv")
	var out: Array = []
	var args: PackedStringArray
	if host == "py":
		args = PackedStringArray(["-3", "-m", "venv", venv_dir])
	else:
		args = PackedStringArray(["-m", "venv", venv_dir])
	var code: int = OS.execute(host, args, out, true, false)
	for line in out:
		print("[GoDotter venv] %s" % str(line))
	if code != 0:
		return {"ok": false, "error": "python -m venv failed (exit %d). See Godot Output." % code}
	return {"ok": true, "message": "Created .venv in backend folder."}


## Best-effort system Python install before venv/pip. Windows: winget. Linux: apt via passwordless sudo. macOS: Homebrew if present.
func install_system_python_best_effort() -> Dictionary:
	var os_name: String = OS.get_name()
	if os_name == "Windows":
		return _install_python_winget_windows()
	if os_name == "Linux":
		return _install_python_apt_linux_passwordless()
	if os_name == "macOS":
		return _install_python_brew_macos()
	return {
		"ok": false,
		"error": "Automatic Python install is not mapped for this OS. Install Python 3.10+ from python.org and restart Godot.",
	}


func _install_python_winget_windows() -> Dictionary:
	var probe: Array = []
	if OS.execute("winget", PackedStringArray(["--version"]), probe, true, false) != 0:
		return {
			"ok": false,
			"error": "winget not available. Install [App Installer] from the Microsoft Store, or install Python from https://www.python.org/downloads/windows/",
		}
	var out: Array = []
	var args := PackedStringArray([
		"install", "-e", "--id", "Python.Python.3.12",
		"--accept-package-agreements", "--accept-source-agreements",
	])
	var code: int = OS.execute("winget", args, out, true, false)
	for line in out:
		print("[GoDotter winget] %s" % str(line))
	if code == 0:
		return {
			"ok": true,
			"message": "winget reported success. If Godot still cannot find Python, close Godot completely and reopen (PATH refresh).",
		}
	return {
		"ok": false,
		"error": "winget exited with code %d — see Godot Output. You can install Python manually from python.org." % code,
	}


func _install_python_apt_linux_passwordless() -> Dictionary:
	var out: Array = []
	var script := (
		"export DEBIAN_FRONTEND=noninteractive; "
		+ "command -v apt-get >/dev/null || exit 2; "
		+ "apt-get update -qq && apt-get install -y python3 python3-venv python3-pip"
	)
	var code: int = OS.execute("sudo", PackedStringArray(["-n", "bash", "-lc", script]), out, true, false)
	for line in out:
		print("[GoDotter apt] %s" % str(line))
	if code == 0:
		return {"ok": true, "message": "Installed python3, venv, and pip via apt."}
	if code == 2:
		return {
			"ok": false,
			"error": "apt-get not found. Install Python 3 using your distro packages, then restart Godot.",
		}
	return {
		"ok": false,
		"error": "Passwordless sudo is not available (or install failed). Open a terminal and run: "
		+ "sudo apt-get update && sudo apt-get install -y python3 python3-venv python3-pip",
	}


func _install_python_brew_macos() -> Dictionary:
	var probe: Array = []
	if OS.execute("brew", PackedStringArray(["--version"]), probe, true, false) != 0:
		return {
			"ok": false,
			"error": "Homebrew not found. Install from https://brew.sh/ or install Python from https://www.python.org/downloads/macos/",
		}
	var out: Array = []
	var code: int = OS.execute(
		"brew",
		PackedStringArray(["install", "python@3.12"]),
		out,
		true,
		false,
	)
	for line in out:
		print("[GoDotter brew] %s" % str(line))
	if code == 0:
		return {
			"ok": true,
			"message": "brew install finished. If python3 is still missing from PATH, restart Godot or run: brew link python@3.12",
		}
	return {"ok": false, "error": "brew exited with code %d — see Godot Output." % code}


func get_backend_main() -> String:
	if backend_dir == "":
		return ""
	return backend_dir.path_join("main.py")


## Writes provider API keys into backend key files so auto-launched Python can read them.
func sync_backend_api_key_file() -> void:
	var base: String = backend_dir.strip_edges()
	if base == "":
		return
	if base.begins_with("res://"):
		base = ProjectSettings.globalize_path(base)
	var gemini_path: String = base.path_join(".godotter_api_key")
	var keys_path: String = base.path_join(".godotter_api_keys.json")
	var gemini_key: String = str(provider_api_keys.get("gemini", api_key)).strip_edges()
	if gemini_key == "":
		if FileAccess.file_exists(gemini_path):
			DirAccess.remove_absolute(gemini_path)
	else:
		var fg := FileAccess.open(gemini_path, FileAccess.WRITE)
		if fg:
			fg.store_string(gemini_key)
			fg.close()
	var payload := {
		"gemini": str(provider_api_keys.get("gemini", "")).strip_edges(),
		"openai": str(provider_api_keys.get("openai", "")).strip_edges(),
		"claude": str(provider_api_keys.get("claude", "")).strip_edges(),
	}
	var has_any := false
	for v in payload.values():
		if str(v).strip_edges() != "":
			has_any = true
			break
	if not has_any:
		if FileAccess.file_exists(keys_path):
			DirAccess.remove_absolute(keys_path)
		return
	var fk := FileAccess.open(keys_path, FileAccess.WRITE)
	if fk:
		fk.store_string(JSON.stringify(payload))
		fk.close()


## True when the backend folder exists at the expected location.
func backend_bundled_and_present() -> bool:
	return backend_dir != "" and FileAccess.file_exists(get_backend_main())
