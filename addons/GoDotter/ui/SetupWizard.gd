@tool
extends Control

## First-run setup wizard.
## Overlays the dock content until the user completes all 3 steps.
## After completion it hides itself and the normal dock shows.
##
## Step 1: Welcome
## Step 2: Backend directory + install/launch
## Step 3: Provider API key(s)
## Step 4: Done

signal setup_finished()
signal launch_backend_requested()

var _state: Object  # ForgeState
var _agent_client: Object  # AgentClient

var _current_step := 0
const TOTAL_STEPS := 4

# UI nodes
var _step_label: Label
var _pages: Array[Control] = []
var _page_stack: Control
var _next_btn: Button
var _back_btn: Button
var _status_label: Label

# Step 2 fields
var _backend_dir_field: LineEdit
var _python_field: LineEdit
var _autostart_check: CheckBox
var _install_btn: Button
var _launch_btn: Button
var _install_python_btn: Button
var _copy_linux_apt_btn: Button
var _step2_status: Label

# Step 3 fields
var _api_provider_option: OptionButton
var _api_key_field: LineEdit
var _wizard_openai_base_lbl: Label
var _wizard_openai_base_url: LineEdit
var _test_btn: Button
var _step3_status: Label


func setup(state: Object, agent_client: Object) -> void:
	_state = state
	_agent_client = agent_client
	if _agent_client:
		_agent_client.health_response.connect(_on_health_response)


func _ready() -> void:
	_build_ui()
	_go_to_step(0)


func _build_ui() -> void:
	custom_minimum_size = Vector2(260, 200)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg := PanelContainer.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bg.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(bg)

	var outer := VBoxContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_theme_constant_override("separation", 8)
	bg.add_child(outer)

	# Title row
	var title_row := HBoxContainer.new()
	var logo := Label.new()
	logo.text = "⬡ GoDotter"
	logo.add_theme_font_size_override("font_size", 18)
	logo.add_theme_color_override("font_color", Color(0.0, 1.0, 0.9))
	logo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(logo)
	_step_label = Label.new()
	_step_label.add_theme_font_size_override("font_size", 12)
	_step_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	title_row.add_child(_step_label)
	outer.add_child(title_row)
	outer.add_child(HSeparator.new())

	# Pages scroll container
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_page_stack = VBoxContainer.new()
	_page_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_stack.add_theme_constant_override("separation", 6)
	scroll.add_child(_page_stack)
	outer.add_child(scroll)

	# Build all pages
	_pages.append(_build_page_welcome())
	_pages.append(_build_page_backend())
	_pages.append(_build_page_api_key())
	_pages.append(_build_page_done())
	for page in _pages:
		_page_stack.add_child(page)

	outer.add_child(HSeparator.new())

	# Status
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.visible = false
	outer.add_child(_status_label)

	# Nav buttons
	var nav := HBoxContainer.new()
	_back_btn = Button.new()
	_back_btn.text = "← Back"
	_back_btn.add_theme_font_size_override("font_size", 14)
	_back_btn.pressed.connect(_on_back)
	nav.add_child(_back_btn)
	nav.add_child(_spacer())
	_next_btn = Button.new()
	_next_btn.text = "Next →"
	_next_btn.add_theme_font_size_override("font_size", 14)
	_next_btn.add_theme_color_override("font_color", Color(0.0, 1.0, 0.9))
	_next_btn.pressed.connect(_on_next)
	nav.add_child(_next_btn)
	outer.add_child(nav)


func _build_page_welcome() -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	_add_heading(vb, "Welcome to GoDotter")
	_add_body(vb,
		"GoDotter is an AI-native coding assistant that lives inside the Godot editor.\n\n"
		+ "It understands your scenes, selected nodes, scripts, and resources — then uses "
		+ "provider-aware AI backends (Gemini / OpenAI / Claude) to plan, fix, and explain changes directly in context.\n\n"
		+ "The companion backend is [b]bundled inside[/b] [code]addons/GoDotter/backend/[/code]. "
		+ "You just need to install Python dependencies and add at least one provider API key."
	)
	_add_body(vb, "💡 [b]This plugin works in any Godot project.[/b] Copy the entire "
		+ "[code]addons/GoDotter/[/code] folder and you have everything.", true)
	return vb


func _build_page_backend() -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_add_heading(vb, "Step 1 — Backend Location")
	_add_body(vb,
		"The backend is at [code]addons/GoDotter/backend/[/code] — already inside this project. "
		+ "The path below is auto-filled.\n\n"
		+ "Click [b]Install dependencies[/b] to set up the Python venv, then "
		+ "[b]Launch backend[/b] to start the server.", true
	)

	_add_field_row(vb, "Backend directory:", func(line: LineEdit) -> void:
		_backend_dir_field = line
		if _state and _state.backend_dir != "":
			line.text = _state.backend_dir
			# Show helpful note if it's the bundled default
			if line.text.ends_with("addons/GoDotter/backend") or \
			   line.text.ends_with("addons\\GoDotter\\backend"):
				line.tooltip_text = "✓ Bundled backend detected at this location"
		line.placeholder_text = "Auto-detected: addons/GoDotter/backend/"
		line.text_changed.connect(func(_t): _update_step2_fields())
	)
	_add_field_row(vb, "Python executable (leave blank to auto-detect):", func(line: LineEdit) -> void:
		_python_field = line
		if _state and _state.backend_python != "":
			line.text = _state.backend_python
		line.placeholder_text = "Auto (uses .venv inside backend dir)"
	)

	_autostart_check = CheckBox.new()
	_autostart_check.text = "Auto-launch backend when Godot opens"
	_autostart_check.add_theme_font_size_override("font_size", 14)
	if _state:
		_autostart_check.button_pressed = _state.autostart_backend
	vb.add_child(_autostart_check)

	var btn_row := HBoxContainer.new()
	_install_btn = Button.new()
	_install_btn.text = "Install dependencies"
	_install_btn.add_theme_font_size_override("font_size", 14)
	_install_btn.tooltip_text = "Creates .venv if needed, then pip install -r requirements.txt. If Python is missing, tries a system install (winget / apt / brew) first."
	_install_btn.pressed.connect(_on_install_deps)
	btn_row.add_child(_install_btn)

	_launch_btn = Button.new()
	_launch_btn.text = "▶ Launch backend"
	_launch_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	_launch_btn.add_theme_font_size_override("font_size", 14)
	_launch_btn.pressed.connect(_on_launch_backend)
	btn_row.add_child(_launch_btn)
	vb.add_child(btn_row)

	var py_row := HBoxContainer.new()
	py_row.add_theme_constant_override("separation", 6)
	_install_python_btn = Button.new()
	_install_python_btn.text = "Install Python (system)"
	_install_python_btn.add_theme_font_size_override("font_size", 14)
	_install_python_btn.tooltip_text = (
		"Windows: winget installs Python 3.12. "
		+ "Linux: tries passwordless sudo + apt. "
		+ "macOS: brew install python@3.12 if Homebrew exists."
	)
	_install_python_btn.pressed.connect(_on_install_python_system)
	py_row.add_child(_install_python_btn)
	if OS.get_name() == "Linux":
		_copy_linux_apt_btn = Button.new()
		_copy_linux_apt_btn.text = "Copy apt command"
		_copy_linux_apt_btn.add_theme_font_size_override("font_size", 14)
		_copy_linux_apt_btn.tooltip_text = "Copies a typical Ubuntu/Debian install line to the clipboard"
		_copy_linux_apt_btn.pressed.connect(_on_copy_linux_apt_command)
		py_row.add_child(_copy_linux_apt_btn)
	vb.add_child(py_row)

	_step2_status = Label.new()
	_step2_status.add_theme_font_size_override("font_size", 12)
	_step2_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_step2_status.visible = false
	vb.add_child(_step2_status)

	return vb


func _build_page_api_key() -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_add_heading(vb, "Step 2 — Provider API Keys")
	_add_body(vb,
		"Choose a provider and paste its API key (same as in Settings).\n"
		+ "Keys are stored in Godot Editor Settings and written to backend key files when you continue or test.\n\n"
		+ "[b]OpenAI-compatible servers[/b] (LM Studio, Ollama, vLLM, OpenRouter, etc.): set [b]Base URL[/b] to the server’s "
		+ "[code]/v1[/code] root (example: [code]http://127.0.0.1:1234/v1[/code]). Many local servers do not require an API key.\n\n"
		+ "Gemini key: [url=https://aistudio.google.com/]aistudio.google.com[/url]\n"
		+ "OpenAI key: [url=https://platform.openai.com/]platform.openai.com[/url] (optional for custom base URL)\n"
		+ "Claude key: [url=https://console.anthropic.com/]console.anthropic.com[/url]",
		true,
	)

	var provider_lbl := Label.new()
	provider_lbl.text = "Provider"
	provider_lbl.add_theme_font_size_override("font_size", 12)
	provider_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	vb.add_child(provider_lbl)

	_api_provider_option = OptionButton.new()
	_api_provider_option.add_theme_font_size_override("font_size", 14)
	for p in ["gemini", "openai", "claude"]:
		_api_provider_option.add_item(p)
	_api_provider_option.item_selected.connect(_on_wizard_api_provider_changed)
	vb.add_child(_api_provider_option)

	var ak_lbl := Label.new()
	ak_lbl.text = "API key"
	ak_lbl.add_theme_font_size_override("font_size", 12)
	ak_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	vb.add_child(ak_lbl)

	_api_key_field = LineEdit.new()
	_api_key_field.secret = true
	_api_key_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_api_key_field.placeholder_text = "Paste provider API key"
	_api_key_field.add_theme_font_size_override("font_size", 14)
	if _state and _state.has_method("get_provider_api_key"):
		_api_key_field.text = str(_state.get_provider_api_key("gemini"))
	vb.add_child(_api_key_field)

	_wizard_openai_base_lbl = Label.new()
	_wizard_openai_base_lbl.text = "OpenAI-compatible API base URL"
	_wizard_openai_base_lbl.add_theme_font_size_override("font_size", 12)
	_wizard_openai_base_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	_wizard_openai_base_lbl.visible = false
	vb.add_child(_wizard_openai_base_lbl)

	_wizard_openai_base_url = LineEdit.new()
	_wizard_openai_base_url.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wizard_openai_base_url.placeholder_text = "http://127.0.0.1:1234/v1 — LM Studio default; leave empty for OpenAI cloud"
	_wizard_openai_base_url.add_theme_font_size_override("font_size", 14)
	_wizard_openai_base_url.visible = false
	vb.add_child(_wizard_openai_base_url)

	var code_box := PanelContainer.new()
	var code_lbl := Label.new()
	code_lbl.text = (
		"# Windows PowerShell\n"
		+ "$env:GEMINI_API_KEY = \"your-gemini-key\"\n"
		+ "$env:OPENAI_API_KEY = \"your-openai-key\"\n"
		+ "$env:OPENAI_BASE_URL = \"https://api.openai.com/v1\"\n"
		+ "$env:ANTHROPIC_API_KEY = \"your-claude-key\"\n"
		+ "python main.py\n\n"
		+ "# macOS / Linux\n"
		+ "export GEMINI_API_KEY=\"your-gemini-key\"\n"
		+ "export OPENAI_API_KEY=\"your-openai-key\"\n"
		+ "export OPENAI_BASE_URL=\"https://api.openai.com/v1\"\n"
		+ "export ANTHROPIC_API_KEY=\"your-claude-key\"\n"
		+ "python main.py"
	)
	code_lbl.add_theme_font_size_override("font_size", 12)
	code_box.add_child(code_lbl)
	vb.add_child(code_box)

	_test_btn = Button.new()
	_test_btn.text = "Test connection (backend + key)"
	_test_btn.add_theme_font_size_override("font_size", 14)
	_test_btn.pressed.connect(_on_test_connection)
	vb.add_child(_test_btn)

	_step3_status = Label.new()
	_step3_status.add_theme_font_size_override("font_size", 12)
	_step3_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_step3_status.visible = false
	vb.add_child(_step3_status)

	return vb


func _build_page_done() -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	_add_heading(vb, "All Set!")
	_add_body(vb,
		"GoDotter is configured. Here's what you can do right now:\n\n"
		+ "• Open a scene, then type [b]/plan [your request][/b] in the Command tab\n"
		+ "• Click [b]Index Project[/b] to teach the AI about your codebase\n"
		+ "• Click [b]Visualize Scene[/b] in the Inspect tab to see a neon spatial map\n"
		+ "• Use [b]/do[/b] to execute a plan after reviewing it\n\n"
		+ "Settings can always be changed in the Settings tab.", true
	)
	_add_body(vb, "🎮 Happy developing!", false)
	return vb


# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------

func _go_to_step(step: int) -> void:
	_current_step = clamp(step, 0, TOTAL_STEPS - 1)
	for i in _pages.size():
		_pages[i].visible = (i == _current_step)

	_step_label.text = "Step %d/%d" % [_current_step + 1, TOTAL_STEPS]
	_back_btn.visible = _current_step > 0
	_status_label.visible = false

	match _current_step:
		0:
			_next_btn.text = "Get Started →"
		TOTAL_STEPS - 1:
			_next_btn.text = "✓ Open GoDotter"
		_:
			_next_btn.text = "Next →"

	_update_step2_fields()
	_sync_wizard_api_key_field_if_needed()
	_update_wizard_openai_base_visibility()


func _on_next() -> void:
	if _current_step == 2:
		_persist_wizard_api_key()
	if _current_step == TOTAL_STEPS - 1:
		_finish()
		return
	if _current_step == 1:
		_save_backend_settings()
	_go_to_step(_current_step + 1)


func _on_back() -> void:
	_go_to_step(_current_step - 1)


func _finish() -> void:
	_save_backend_settings()
	_persist_wizard_api_key()
	if _state:
		_state.mark_setup_complete()
	setup_finished.emit()


# ---------------------------------------------------------------------------
# Step 2 actions
# ---------------------------------------------------------------------------

func _save_backend_settings() -> void:
	if not _state:
		return
	if _backend_dir_field:
		_state.backend_dir = _backend_dir_field.text.strip_edges()
	if _python_field:
		_state.backend_python = _python_field.text.strip_edges()
	if _autostart_check:
		_state.autostart_backend = _autostart_check.button_pressed
	_state.save_machine_settings()


func _update_step2_fields() -> void:
	if not _install_btn or not _launch_btn:
		return
	var has_dir := _backend_dir_field != null and _backend_dir_field.text.strip_edges() != ""
	_install_btn.disabled = not has_dir
	_launch_btn.disabled = not has_dir


func _on_install_deps() -> void:
	_save_backend_settings()
	if not _state or _state.backend_dir == "":
		_set_step2_status("Set the backend directory first.", Color(0.9, 0.5, 0.2))
		return
	var reqs: String = str(_state.backend_dir.path_join("requirements.txt"))
	if not FileAccess.file_exists(reqs):
		_set_step2_status("requirements.txt not found in: " + _state.backend_dir, Color(0.9, 0.3, 0.3))
		return
	_set_step2_status("Preparing Python environment… (see Output)", Color(0.7, 0.7, 0.7))
	if _state.find_host_python_executable() == "":
		_set_step2_status("No Python on PATH — trying automatic install…", Color(0.85, 0.75, 0.35))
		var auto: Dictionary = _state.install_system_python_best_effort()
		if auto.get("ok", false):
			print("[GoDotter] %s" % str(auto.get("message", "")))
		else:
			print("[GoDotter] Auto Python install: %s" % str(auto.get("error", "")))
		if _state.find_host_python_executable() == "":
			_set_step2_status(
				str(auto.get("error", "Install Python 3.10+ and restart Godot, or use 'Install Python (system)'.")),
				Color(0.9, 0.35, 0.25),
			)
			return
	var venv_res: Dictionary = _state.ensure_backend_venv()
	if not bool(venv_res.get("ok", false)):
		_set_step2_status(str(venv_res.get("error", "venv failed.")), Color(0.9, 0.35, 0.25))
		return
	print("[GoDotter] %s" % str(venv_res.get("message", "")))
	var python: String = str(_state.get_effective_python())
	_set_step2_status("Installing packages with pip… (see Output)", Color(0.7, 0.7, 0.7))
	var output: Array = []
	var args := PackedStringArray(["-m", "pip", "install", "-r", reqs])
	var exit_code: int = OS.execute(python, args, output, true, false)
	print("[GoDotter] pip install exit code: %d" % exit_code)
	for line in output:
		print("[GoDotter pip] %s" % str(line))
	if exit_code == 0:
		_set_step2_status("Install finished OK. You can launch the backend.", Color(0.3, 0.9, 0.4))
	else:
		_set_step2_status("pip exited with code %d — check Output above." % exit_code, Color(0.9, 0.5, 0.25))


func _on_install_python_system() -> void:
	_save_backend_settings()
	if not _state:
		return
	_set_step2_status("Running system Python installer… (see Output)", Color(0.75, 0.75, 0.45))
	var r: Dictionary = _state.install_system_python_best_effort()
	if r.get("ok", false):
		print("[GoDotter] %s" % str(r.get("message", "")))
		_set_step2_status(str(r.get("message", "Done.")), Color(0.3, 0.9, 0.4))
	else:
		print("[GoDotter] System Python install: %s" % str(r.get("error", "")))
		_set_step2_status(str(r.get("error", "Failed.")), Color(0.9, 0.45, 0.25))


func _on_copy_linux_apt_command() -> void:
	var cmd := "sudo apt-get update && sudo apt-get install -y python3 python3-venv python3-pip"
	DisplayServer.clipboard_set(cmd)
	_set_step2_status("Copied to clipboard:\n" + cmd, Color(0.35, 0.85, 0.45))


func _on_launch_backend() -> void:
	_save_backend_settings()
	launch_backend_requested.emit()
	_set_step2_status("Launch requested. Allow ~3 seconds for startup.", Color(0.3, 0.9, 0.4))


func _on_test_connection() -> void:
	_persist_wizard_api_key()
	if not _agent_client:
		_set_step3_status("AgentClient not ready.", Color(0.9, 0.3, 0.3))
		return
	_set_step3_status("Testing…", Color(0.7, 0.7, 0.7))
	_agent_client.check_health()


func _on_health_response(data: Dictionary) -> void:
	if _current_step == 2:
		if data.get("status") == "ok":
			var provider: String = _selected_wizard_provider()
			var keys_present: Dictionary = data.get("api_keys_present", {})
			var key: bool = false
			if typeof(keys_present) == TYPE_DICTIONARY:
				key = bool(keys_present.get(provider, false))
			else:
				key = bool(data.get("api_key_present", data.get("gemini_key_present", false)))
			var model := data.get("model", "?")
			var msg := "✓ Backend online (v%s, model: %s)" % [data.get("version", "?"), model]
			if key:
				msg += "\n✓ %s key detected" % provider
				_set_step3_status(msg, Color(0.3, 0.9, 0.4))
			else:
				msg += "\n⚠ No %s key detected on backend — paste key above, save, then restart backend if needed." % provider
				_set_step3_status(msg, Color(0.9, 0.6, 0.2))
		else:
			_set_step3_status("Backend offline or returned an error.", Color(0.9, 0.3, 0.3))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _set_step2_status(msg: String, color: Color) -> void:
	if _step2_status:
		_step2_status.text = msg
		_step2_status.add_theme_color_override("font_color", color)
		_step2_status.visible = true


func _set_step3_status(msg: String, color: Color) -> void:
	if _step3_status:
		_step3_status.text = msg
		_step3_status.add_theme_color_override("font_color", color)
		_step3_status.visible = true


func _persist_wizard_api_key() -> void:
	if not _state or _api_key_field == null:
		return
	var provider: String = _selected_wizard_provider()
	var key: String = _api_key_field.text.strip_edges()
	if _state.has_method("set_provider_api_key"):
		_state.set_provider_api_key(provider, key)
	else:
		_state.api_key = key
	if typeof(_state.settings) == TYPE_DICTIONARY:
		var ai: Dictionary = _state.settings.get("ai_settings", {})
		if typeof(ai) != TYPE_DICTIONARY:
			ai = {}
		ai["provider"] = provider
		ai["model"] = _wizard_default_model_for_provider(provider)
		if _wizard_openai_base_url:
			ai["openai_base_url"] = _wizard_openai_base_url.text.strip_edges()
		_state.settings["ai_settings"] = ai
		_state.settings["model"] = str(ai["model"])
		_state.save_settings()
	_state.save_machine_settings()


func _update_wizard_openai_base_visibility() -> void:
	var show: bool = _selected_wizard_provider() == "openai"
	if _wizard_openai_base_lbl:
		_wizard_openai_base_lbl.visible = show
	if _wizard_openai_base_url:
		_wizard_openai_base_url.visible = show


func _sync_wizard_openai_base_from_state() -> void:
	if _wizard_openai_base_url == null or not _state:
		return
	var ai: Dictionary = _state.settings.get("ai_settings", {})
	if typeof(ai) != TYPE_DICTIONARY:
		return
	_wizard_openai_base_url.text = str(ai.get("openai_base_url", ""))


func _sync_wizard_api_key_field_if_needed() -> void:
	if _current_step != 2 or _api_key_field == null or not _state:
		return
	var provider: String = _selected_wizard_provider()
	if _state.has_method("get_provider_api_key"):
		_api_key_field.text = str(_state.get_provider_api_key(provider))
	else:
		_api_key_field.text = _state.api_key
	_sync_wizard_openai_base_from_state()


func _selected_wizard_provider() -> String:
	if _api_provider_option == null:
		return "gemini"
	return str(_api_provider_option.get_item_text(_api_provider_option.selected)).to_lower()


func _on_wizard_api_provider_changed(_idx: int) -> void:
	_sync_wizard_api_key_field_if_needed()
	_update_wizard_openai_base_visibility()


func _wizard_default_model_for_provider(provider: String) -> String:
	match provider.to_lower():
		"openai":
			return "gpt-5"
		"claude":
			return "claude-3-7-sonnet"
		_:
			return "gemini-3.1-pro-preview"


func _add_heading(parent: Control, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	parent.add_child(lbl)


func _add_body(parent: Control, text: String, bbcode: bool = false) -> void:
	if bbcode:
		var rtl := RichTextLabel.new()
		rtl.bbcode_enabled = true
		rtl.fit_content = true
		rtl.selection_enabled = true
		rtl.context_menu_enabled = true
		rtl.focus_mode = Control.FOCUS_CLICK
		rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rtl.add_theme_font_size_override("font_size", 14)
		rtl.text = text
		parent.add_child(rtl)
	else:
		var lbl := Label.new()
		lbl.text = text
		lbl.add_theme_font_size_override("font_size", 14)
		lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		parent.add_child(lbl)


func _add_field_row(parent: Control, label_text: String, configure: Callable) -> LineEdit:
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	parent.add_child(lbl)
	var line := LineEdit.new()
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_theme_font_size_override("font_size", 14)
	configure.call(line)
	parent.add_child(line)
	return line


func _spacer() -> Control:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s
