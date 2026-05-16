@tool
extends Control

## GoDotter Forge Dock — the main plugin UI.
##
## Layout
##   ┌─ Top bar: logo · status · backend btn ──────────────────────┐
##   ├─ Context bar: current scene · selected node ────────────────┤
##   ├─ Tabs: [Chat] [Plan] [Inspect] [Node] [Diff] [Memory] [Settings] ───────┤
##   │  (content area)                                             │
##   └─────────────────────────────────────────────────────────────┘
##
## First-run: a SetupWizard overlay appears until setup is complete.

const ForgeStateScript      := preload("res://addons/GoDotter/core/ForgeState.gd")
const EditorBridgeScript    := preload("res://addons/GoDotter/core/EditorBridge.gd")
const AgentClientScript     := preload("res://addons/GoDotter/core/AgentClient.gd")
const TaskQueueScript       := preload("res://addons/GoDotter/core/TaskQueue.gd")
const ProjectScannerScript  := preload("res://addons/GoDotter/core/ProjectScanner.gd")
const LogCollectorScript    := preload("res://addons/GoDotter/core/LogCollector.gd")
const DiffManagerScript     := preload("res://addons/GoDotter/core/DiffManager.gd")
const DebugVisualizerScript := preload("res://addons/GoDotter/core/DebugVisualizer.gd")
const DIFF_PANEL_SCRIPT_PATH := "res://addons/GoDotter/ui/DiffPanel.gd"
const SetupWizardScript     := preload("res://addons/GoDotter/ui/SetupWizard.gd")
const CHAT_IMAGE_LINE_EDIT_SCRIPT_PATH := "res://addons/GoDotter/ui/ChatImageLineEdit.gd"

# ---------------------------------------------------------------------------
# Subsystems
# ---------------------------------------------------------------------------
var state: Object
var editor_bridge: Object
var agent_client: Object
var task_queue: Object
var project_scanner: Object
var log_collector: Object
var diff_manager: Object
var debug_visualizer: Object

# ---------------------------------------------------------------------------
# UI — top level
# ---------------------------------------------------------------------------
var _root_vbox: VBoxContainer
var _setup_overlay: Control          # wizard overlay
var _main_content: Control           # normal dock content

# Top bar
var _status_dot: ColorRect
var _status_label: Label
var _backend_version_label: Label
var _queue_status_label: Label
var _launch_btn: Button
var _stop_btn: Button

# Context bar
var _ctx_scene_label: Label
var _ctx_node_label: Label
var _ctx_errors_label: Label

# Tabs
var _tabs: TabContainer
var _chat_tab: Control
var _plan_tab: Control
var _inspect_tab: Control
var _diff_tab: Control
var _memory_tab: Control
var _settings_tab: Control

# Chat tab internals
var _chat_log: RichTextLabel
var _chat_session_option: OptionButton
var _chat_new_session_btn: Button
var _chat_rename_session_btn: Button
var _chat_delete_session_btn: Button
var _chat_session_rename_dialog: ConfirmationDialog
var _chat_session_rename_edit: LineEdit
var _cmd_input: LineEdit
var _send_btn: Button
var _attach_btn: Button
var _clear_attachments_btn: Button
var _attachments_label: Label
var _chat_attachment_strip: HBoxContainer
var _image_file_dialog: FileDialog
var _chat_attached_images: Array = []  # [{name, mime_type, base64, preview?}]
var _chat_sessions: Array = []  # [{id,title,created_at,updated_at,log_text}]
var _chat_current_session_id: String = ""
var _chat_sessions_loaded := false
var _thinking_bar: Control
var _thinking_spinner_grid: GridContainer
var _thinking_spinner_cells: Array = []  # Array[ColorRect]
var _thinking_label: Label
var _thinking_model_label: Label
var _thinking_toggle_btn: Button
var _thinking_trace_container: PanelContainer
var _thinking_trace_scroll: ScrollContainer
var _thinking_trace: RichTextLabel
var _thinking_trace_autoscroll_btn: Button
var _thinking_trace_mode_btn: Button
var _thinking_clear_btn: Button
var _thinking_copy_btn: Button

## Chat bar: Cursor-style mode + model (mirrors Settings model into requests).
var _chat_mode_option: OptionButton
var _chat_model_option: OptionButton
var _chat_plan_option: OptionButton

const CHAT_MODE_LABELS: Array[String] = [
	"Full agent",
	"Plan",
	"Execute",
	"Scene",
	"Node",
	"Index",
	"Memory",
	"Fix logs",
	"Visual map",
	"Help",
]
const CHAT_PLAN_LABELS: Array[String] = [
	"Require approval",
	"Auto-run (no approval)",
]
const CHAT_SESSIONS_MAX := 80

# Plan tab internals
var _plan_text: RichTextLabel
var _plan_actions: Control
var _plan_tasks_box: VBoxContainer
var _plan_task_checks: Array = []
var _plan_steps_cache: Array = []
var _plan_step_done: Array = []
var _plan_auto_approve_timer: Timer
var _plan_auto_approve_sec: int = 15

# Inspect tab internals
var _inspect_scene_text: RichTextLabel
var _inspect_node_text: RichTextLabel
var _node_text: RichTextLabel
var _node_tab: Control
var _viz_query_input: LineEdit

# Memory tab
var _memory_file_list: ItemList
var _memory_content: RichTextLabel

# Settings tab
var _set_backend_dir: LineEdit
var _set_python_path: LineEdit
var _set_api_key_gemini: LineEdit
var _set_api_key_openai: LineEdit
var _set_api_key_claude: LineEdit
var _set_url: LineEdit
var _ai_openai_base_title: Label
var _ai_openai_base_hint: Label
var _ai_openai_base_url: LineEdit
var _model_preset: OptionButton
var _model_custom: LineEdit
var _set_autostart: CheckBox
var _set_file_edits: CheckBox
var _set_approval_mode: OptionButton
var _set_max_output_tokens: SpinBox
var _set_max_input_tokens: SpinBox
var _ai_provider_option: OptionButton
var _ai_model_option: OptionButton
var _ai_preset_option: OptionButton
var _ai_temperature_spin: SpinBox
var _ai_top_p_spin: SpinBox
var _ai_reasoning_effort_option: OptionButton
var _ai_thinking_level_option: OptionButton
var _ai_thinking_budget_spin: SpinBox
var _ai_thinking_summary_check: CheckBox
var _ai_streaming_check: CheckBox
var _ai_timeout_spin: SpinBox
var _ai_retries_spin: SpinBox
var _ai_settings_status: Label
var _caps_status: RichTextLabel
var _save_api_keys_btn: Button

# Avoid duplicate "Health check failed" lines in the chat panel (Output is throttled in AgentClient).
var _chat_health_warn_suppress_until_ms: int = 0

# Health check timer
var _health_timer: Timer
const HEALTH_INTERVAL_ONLINE := 6.0
const HEALTH_INTERVAL_OFFLINE := 18.0

## Preset Gemini model ids (Custom… uses _model_custom).
const MODEL_PRESETS: Array[String] = [
	"gemini-3.1-pro-preview",
	"gemini-2.5-pro",
	"gemini-2.5-flash",
	"gemini-2.5-flash-lite",
	"gemini-2.0-flash",
]
const AI_PRESET_NAMES: Array[String] = ["Fast", "Balanced", "Deep", "Extreme"]
const TAB_CHAT := 0
const TAB_PLAN := 1
const TAB_INSPECT := 2
const TAB_NODE := 3
const TAB_DIFF := 4
const TAB_MEMORY := 5
const TAB_SETTINGS := 6

# Thinking state — only reflects user-initiated work, not background polls (/health, /openapi.json).
var _is_thinking := false
var _thinking_timer: Timer
var _thinking_active_endpoint: String = ""
var _thinking_http_started_ms: int = 0
var _thinking_session_started_ms: int = 0
var _thinking_spinner_idx: int = 0
var _thinking_spinner_pattern_idx: int = 0
var _thinking_spinner_pattern_loops: int = 0
var _thinking_trace_visible := false
var _thinking_trace_entries: Array = []  # [{text,severity,elapsed_s,phase_ms}]
var _thinking_trace_revealed_entries: int = 0
var _thinking_trace_partial_chars: int = 0
var _thinking_trace_timer: Timer
var _thinking_trace_auto_scroll := true
var _thinking_trace_compact := false
var _plan_reveal_timer: Timer
var _plan_reveal_target_chars: int = 0
const THINKING_SPINNER_PATTERNS: Array = [
	[0, 3, 6, 1, 4, 7, 2, 5, 8], # 1 4 7 / 2 5 8 / 3 6 9
	[0, 1, 2, 3, 4, 5, 6, 7, 8], # 1 2 3 / 4 5 6 / 7 8 9
	[0, 1, 2, 5, 4, 3, 6, 7, 8], # 1 2 3 / 6 5 4 / 7 8 9
]
const THINKING_SPINNER_PATTERN_LOOPS: Array[int] = [3, 2, 2]

# Avoid spamming chat when health timer fires every few seconds
var _nagged_no_backend_api_key: bool = false
var _nagged_restart_backend_for_key: bool = false
var _backend_caps: Dictionary = {}
var _backend_caps_last_state: String = ""
var _backend_caps_last_probe_url: String = ""

# Serialized command execution queue (fail-safe: one active task at a time).
var _pending_command_tasks: Array = []
var _active_command_task: Dictionary = {}
var _queue_watchdog: Timer
const QUEUE_WATCHDOG_SEC := 360.0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

func initialize(plugin: EditorPlugin) -> void:
	state = ForgeStateScript.new()
	state.initialize(plugin)

	editor_bridge = EditorBridgeScript.new()
	editor_bridge.setup(state)

	agent_client = AgentClientScript.new()
	agent_client.setup(state)
	add_child(agent_client)

	task_queue    = TaskQueueScript.new()
	log_collector = LogCollectorScript.new()

	project_scanner = ProjectScannerScript.new()
	project_scanner.setup(state)

	diff_manager = DiffManagerScript.new()
	diff_manager.setup(state)

	debug_visualizer = DebugVisualizerScript.new()
	debug_visualizer.setup(state)
	add_child(debug_visualizer)
	debug_visualizer.visualization_complete.connect(_on_visualization_complete)
	debug_visualizer.visualization_failed.connect(_on_visualization_failed)

	_connect_state_signals()
	_build_ui()
	_start_health_timer()
	call_deferred("_sync_backend_control_buttons")


func _connect_state_signals() -> void:
	state.backend_status_changed.connect(_on_backend_status_changed)
	state.plan_received.connect(_on_plan_received)
	state.log_message.connect(_on_log_message)
	state.setup_state_changed.connect(_on_setup_state_changed)
	if not state.settings_changed.is_connected(_on_state_settings_changed):
		state.settings_changed.connect(_on_state_settings_changed)

	agent_client.visual_map_response.connect(_on_visual_map_response)
	agent_client.execute_response.connect(_on_execute_response)
	agent_client.agent_run_response.connect(_on_agent_run_response)
	if agent_client.has_signal("capabilities_updated"):
		agent_client.capabilities_updated.connect(_on_backend_capabilities_updated)
	if agent_client.has_signal("request_started"):
		agent_client.request_started.connect(_on_agent_request_started)
	if agent_client.has_signal("request_finished"):
		agent_client.request_finished.connect(_on_agent_request_finished)
	if agent_client.has_signal("ai_capabilities_response"):
		agent_client.ai_capabilities_response.connect(_on_ai_capabilities_response)
	if agent_client.has_signal("ai_test_response"):
		agent_client.ai_test_response.connect(_on_ai_test_response)


func _build_ai_context_bundle(chat_images_override: Variant = null) -> Dictionary:
	var context: Dictionary = editor_bridge.build_context_bundle() if editor_bridge else {}
	context["project_index"] = state.project_index
	context["project_root"] = state.project_root
	var checklist: Array = []
	var completed: Array = []
	var pending: Array = []
	for i in range(_plan_steps_cache.size()):
		var step: Dictionary = _plan_steps_cache[i] if i < _plan_steps_cache.size() else {}
		var desc: String = str(step.get("description", "")).strip_edges()
		var done: bool = bool(_plan_step_done[i]) if i < _plan_step_done.size() else false
		if desc == "":
			continue
		checklist.append({"step_number": i + 1, "description": desc, "done": done})
		if done:
			completed.append(desc)
		else:
			pending.append(desc)
	var chat_src: Array = _chat_attached_images
	if chat_images_override != null and chat_images_override is Array:
		chat_src = (chat_images_override as Array).duplicate(true)
	var chat_out: Array = []
	for it in chat_src:
		if it is Dictionary:
			var d: Dictionary = (it as Dictionary).duplicate(true)
			d.erase("preview")
			chat_out.append(d)
		else:
			chat_out.append(it)
	var editor_tail := ""
	if log_collector and log_collector.has_method("get_editor_output_tail"):
		editor_tail = str(log_collector.get_editor_output_tail(28000))
	context["godotter"] = {
		"enable_file_edits": bool(state.settings.get("enable_file_edits", false)),
		"approval_mode": str(state.settings.get("approval_mode", "review")),
		"max_output_tokens": clampi(int(state.settings.get("max_output_tokens", 131072)), 1024, 131072),
		"max_input_tokens": clampi(int(state.settings.get("max_input_tokens", 2000000)), 4096, 2000000),
		"ai_settings": state.settings.get("ai_settings", {}),
		"chat_images": chat_out,
		"editor_output_tail": editor_tail,
		"task_checklist": checklist,
		"completed_tasks": completed,
		"pending_tasks": pending,
	}
	return context


func _active_queued_chat_images() -> Array:
	if _active_command_task.is_empty():
		return []
	var arr: Variant = _active_command_task.get("chat_images", [])
	return arr as Array if arr is Array else []


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	# Non-zero minimum height so the dock stays usable when embedded in a narrow
	# slot (e.g. Inspector tab strip) — height 0 collapses the whole UI to blank.
	custom_minimum_size = Vector2(320, 400)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	_root_vbox = VBoxContainer.new()
	_root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root_vbox.add_theme_constant_override("separation", 0)
	add_child(_root_vbox)

	# Normal dock content
	_main_content = VBoxContainer.new()
	_main_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_content.add_theme_constant_override("separation", 0)
	_root_vbox.add_child(_main_content)

	_main_content.add_child(_build_top_bar())
	_main_content.add_child(_build_context_bar())
	_main_content.add_child(HSeparator.new())
	_main_content.add_child(_build_tabs())

	# Setup wizard overlay — added AFTER main content so it sits on top
	_setup_overlay = SetupWizardScript.new()
	_setup_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_setup_overlay.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_setup_overlay.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_setup_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_setup_overlay.setup(state, agent_client)
	_setup_overlay.setup_finished.connect(_on_setup_finished)
	_setup_overlay.launch_backend_requested.connect(_on_setup_launch_backend)
	add_child(_setup_overlay)

	# Show/hide based on setup state
	_setup_overlay.visible = not state.is_setup_complete
	_main_content.visible = state.is_setup_complete
	# Fail-safe: never leave both layers hidden (would show a blank panel).
	if not _main_content.visible and not _setup_overlay.visible:
		_main_content.visible = true


func _build_top_bar() -> Control:
	var bar := PanelContainer.new()
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	bar.add_child(hb)

	# Logo + title
	var logo := Label.new()
	logo.text = "⬡"
	logo.add_theme_color_override("font_color", Color(0.0, 1.0, 0.9))
	logo.add_theme_font_size_override("font_size", 18)
	hb.add_child(logo)

	var title := Label.new()
	title.text = "GoDotter"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(title)

	# Status dot
	_status_dot = ColorRect.new()
	_status_dot.custom_minimum_size = Vector2(10, 10)
	_status_dot.color = Color(0.4, 0.4, 0.4)
	var dot_container := CenterContainer.new()
	dot_container.add_child(_status_dot)
	hb.add_child(dot_container)

	# Status + version label
	_status_label = Label.new()
	_status_label.text = "OFFLINE"
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	hb.add_child(_status_label)

	_backend_version_label = Label.new()
	_backend_version_label.text = ""
	_backend_version_label.add_theme_font_size_override("font_size", 11)
	_backend_version_label.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
	hb.add_child(_backend_version_label)

	_queue_status_label = Label.new()
	_queue_status_label.text = "Queue: idle"
	_queue_status_label.tooltip_text = "Shows active and pending queued AI commands."
	_queue_status_label.add_theme_font_size_override("font_size", 11)
	_queue_status_label.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	hb.add_child(_queue_status_label)

	# Launch / stop buttons
	_launch_btn = Button.new()
	_launch_btn.text = "▶"
	_launch_btn.tooltip_text = "Launch backend"
	_launch_btn.custom_minimum_size = Vector2(52, 44)
	_launch_btn.add_theme_font_size_override("font_size", 22)
	_launch_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	_launch_btn.flat = true
	_launch_btn.pressed.connect(_on_launch_backend_pressed)
	hb.add_child(_launch_btn)

	_stop_btn = Button.new()
	_stop_btn.text = "■"
	_stop_btn.tooltip_text = "Stop backend (only if GoDotter launched it)"
	_stop_btn.custom_minimum_size = Vector2(52, 44)
	_stop_btn.add_theme_font_size_override("font_size", 22)
	_stop_btn.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
	_stop_btn.flat = true
	_stop_btn.visible = false
	_stop_btn.pressed.connect(_on_stop_backend_pressed)
	hb.add_child(_stop_btn)
	_refresh_queue_status_label()

	return bar


func _build_context_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 4)
	margin.add_theme_constant_override("margin_top", 2)
	margin.add_theme_constant_override("margin_bottom", 2)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)

	_ctx_scene_label = Label.new()
	_ctx_scene_label.text = "No scene"
	_ctx_scene_label.add_theme_font_size_override("font_size", 16)
	_ctx_scene_label.add_theme_color_override("font_color", Color(0.45, 0.75, 1.0))
	_ctx_scene_label.clip_text = true
	_ctx_scene_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(_ctx_scene_label)

	var sep := Label.new()
	sep.text = "│"
	sep.add_theme_font_size_override("font_size", 16)
	sep.add_theme_color_override("font_color", Color(0.3, 0.3, 0.3))
	inner.add_child(sep)

	_ctx_node_label = Label.new()
	_ctx_node_label.text = "No node"
	_ctx_node_label.add_theme_font_size_override("font_size", 16)
	_ctx_node_label.add_theme_color_override("font_color", Color(0.6, 0.85, 0.6))
	_ctx_node_label.clip_text = true
	_ctx_node_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(_ctx_node_label)

	_ctx_errors_label = Label.new()
	_ctx_errors_label.text = ""
	_ctx_errors_label.add_theme_font_size_override("font_size", 16)
	_ctx_errors_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
	inner.add_child(_ctx_errors_label)

	margin.add_child(inner)
	bar.add_child(margin)
	return bar


func _build_tabs() -> Control:
	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tabs_visible = true
	_tabs.tab_alignment = TabBar.ALIGNMENT_LEFT
	_tabs.add_theme_font_size_override("font_size", 18)

	_chat_tab = _build_chat_tab()
	if _chat_tab == null:
		_chat_tab = _build_unavailable_tab("Chat", "Chat tab failed to build. Check Output for errors.")
	_chat_tab.name = "Chat"
	_tabs.add_child(_chat_tab)

	_plan_tab = _build_plan_tab()
	if _plan_tab == null:
		_plan_tab = _build_unavailable_tab("Plan", "Plan tab failed to build.")
	_plan_tab.name = "Plan"
	_tabs.add_child(_plan_tab)

	_inspect_tab = _build_inspect_tab()
	if _inspect_tab == null:
		_inspect_tab = _build_unavailable_tab("Inspect", "Inspect tab failed to build.")
	_inspect_tab.name = "Inspect"
	_tabs.add_child(_inspect_tab)

	_node_tab = _build_node_tab()
	if _node_tab == null:
		_node_tab = _build_unavailable_tab("Node", "Node tab failed to build.")
	_node_tab.name = "Node"
	_tabs.add_child(_node_tab)

	_diff_tab = _build_diff_tab_safe()
	if _diff_tab == null:
		_diff_tab = _build_unavailable_tab("Diff", "Diff tab failed to build.")
	_tabs.add_child(_diff_tab)

	_memory_tab = _build_memory_tab()
	if _memory_tab == null:
		_memory_tab = _build_unavailable_tab("Memory", "Memory tab failed to build.")
	_memory_tab.name = "Memory"
	_tabs.add_child(_memory_tab)

	_settings_tab = _build_settings_tab()
	if _settings_tab == null:
		_settings_tab = _build_unavailable_tab("Settings", "Settings tab failed to build.")
	_settings_tab.name = "Settings"
	_tabs.add_child(_settings_tab)
	_tabs.current_tab = 0

	return _tabs


func _build_unavailable_tab(tab_name: String, message: String) -> Control:
	var fallback := VBoxContainer.new()
	fallback.name = tab_name
	fallback.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fallback.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var msg := Label.new()
	msg.text = message
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.add_theme_color_override("font_color", Color(0.9, 0.6, 0.2))
	msg.add_theme_font_size_override("font_size", 14)
	fallback.add_child(msg)
	return fallback


func _build_diff_tab_safe() -> Control:
	var diff_script: GDScript = load(DIFF_PANEL_SCRIPT_PATH) as GDScript
	if diff_script == null:
		push_warning("[GoDotter] DiffPanel script failed to load; using fallback.")
		return _build_unavailable_tab("Diff", "Diff panel unavailable (script missing).")
	var created: Variant = diff_script.new()
	if not (created is Control):
		push_warning("[GoDotter] DiffPanel.new() did not return Control; using fallback.")
		return _build_unavailable_tab("Diff", "Diff panel unavailable (unexpected script return type).")
	var tab := created as Control
	tab.name = "Diff"
	if tab.has_method("setup"):
		tab.call("setup", state, diff_manager)
	if tab.has_signal("approve_requested"):
		tab.connect("approve_requested", _on_diff_approved)
	if tab.has_signal("revert_requested"):
		tab.connect("revert_requested", _on_diff_file_reverted)
	return tab


# ---------------------------------------------------------------------------
# Tab: Chat
# ---------------------------------------------------------------------------

func _build_chat_tab() -> Control:
	var vb := VBoxContainer.new()
	# TabContainer lays out tab pages — use size flags, not full-rect anchors
	# (anchors here can collapse content to zero height in docked layouts).
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 6)

	# Quick actions
	var qa_vb := VBoxContainer.new()
	qa_vb.add_theme_constant_override("separation", 4)

	var qa_label := Label.new()
	qa_label.text = "Quick actions"
	qa_label.add_theme_font_size_override("font_size", 11)
	qa_label.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	qa_vb.add_child(qa_label)

	var qa_row1 := HBoxContainer.new()
	qa_row1.add_theme_constant_override("separation", 6)
	_qa_btn(qa_row1, "Index Project",   Color(0.3, 0.7, 1.0),  _on_qa_index)
	_qa_btn(qa_row1, "Visualize Scene", Color(0.0, 1.0, 0.9),  _on_qa_visualize)
	_qa_btn(qa_row1, "Fix Logs",        Color(0.9, 0.6, 0.2),  _on_qa_fixlogs)
	qa_vb.add_child(qa_row1)

	vb.add_child(qa_vb)

	vb.add_child(HSeparator.new())

	# Session row (Cursor-like history)
	var session_row := HBoxContainer.new()
	session_row.add_theme_constant_override("separation", 6)
	var session_lbl := Label.new()
	session_lbl.text = "Session"
	session_lbl.add_theme_font_size_override("font_size", 14)
	session_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	session_row.add_child(session_lbl)
	_chat_session_option = OptionButton.new()
	_chat_session_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_session_option.add_theme_font_size_override("font_size", 14)
	_chat_session_option.tooltip_text = "Switch between saved chat sessions."
	_chat_session_option.item_selected.connect(_on_chat_session_selected)
	session_row.add_child(_chat_session_option)
	_chat_new_session_btn = Button.new()
	_chat_new_session_btn.text = "New"
	_chat_new_session_btn.add_theme_font_size_override("font_size", 13)
	_chat_new_session_btn.tooltip_text = "Start a new session."
	_chat_new_session_btn.pressed.connect(_on_chat_new_session_pressed)
	session_row.add_child(_chat_new_session_btn)
	_chat_rename_session_btn = Button.new()
	_chat_rename_session_btn.text = "Rename"
	_chat_rename_session_btn.add_theme_font_size_override("font_size", 13)
	_chat_rename_session_btn.tooltip_text = "Rename current session."
	_chat_rename_session_btn.pressed.connect(_on_chat_rename_session_pressed)
	session_row.add_child(_chat_rename_session_btn)
	_chat_delete_session_btn = Button.new()
	_chat_delete_session_btn.text = "Delete"
	_chat_delete_session_btn.add_theme_font_size_override("font_size", 13)
	_chat_delete_session_btn.tooltip_text = "Delete current session."
	_chat_delete_session_btn.pressed.connect(_on_chat_delete_session_pressed)
	session_row.add_child(_chat_delete_session_btn)
	vb.add_child(session_row)

	_chat_session_rename_dialog = ConfirmationDialog.new()
	_chat_session_rename_dialog.title = "Rename Chat Session"
	_chat_session_rename_dialog.get_ok_button().text = "Save"
	_chat_session_rename_dialog.confirmed.connect(_on_chat_rename_session_confirmed)
	var rename_wrap := VBoxContainer.new()
	var rename_lbl := Label.new()
	rename_lbl.text = "Session name"
	rename_lbl.add_theme_font_size_override("font_size", 13)
	rename_wrap.add_child(rename_lbl)
	_chat_session_rename_edit = LineEdit.new()
	_chat_session_rename_edit.placeholder_text = "Enter a title"
	_chat_session_rename_edit.add_theme_font_size_override("font_size", 14)
	rename_wrap.add_child(_chat_session_rename_edit)
	_chat_session_rename_dialog.add_child(rename_wrap)
	vb.add_child(_chat_session_rename_dialog)

	# Chat log
	var log_scroll := ScrollContainer.new()
	log_scroll.name = "LogScroll"
	log_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_chat_log = RichTextLabel.new()
	_chat_log.name = "LogText"
	_chat_log.bbcode_enabled = true
	_chat_log.fit_content = true
	_chat_log.selection_enabled = true
	_chat_log.context_menu_enabled = true
	_chat_log.focus_mode = Control.FOCUS_CLICK
	_chat_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_log.add_theme_font_size_override("font_size", 18)
	_chat_log.text = _welcome_message()
	log_scroll.add_child(_chat_log)
	vb.add_child(log_scroll)

	# Thinking bar
	_thinking_bar = HBoxContainer.new()
	_thinking_bar.visible = false
	_thinking_bar.add_theme_constant_override("separation", 5)
	_thinking_spinner_grid = GridContainer.new()
	_thinking_spinner_grid.columns = 3
	_thinking_spinner_grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_thinking_spinner_grid.add_theme_constant_override("h_separation", 1)
	_thinking_spinner_grid.add_theme_constant_override("v_separation", 1)
	_thinking_spinner_grid.custom_minimum_size = Vector2(14, 14)
	_thinking_spinner_cells = []
	for _i in range(9):
		var cell := ColorRect.new()
		cell.custom_minimum_size = Vector2(4, 4)
		cell.color = Color(0.19, 0.16, 0.15)
		_thinking_spinner_cells.append(cell)
		_thinking_spinner_grid.add_child(cell)
	_thinking_bar.add_child(_thinking_spinner_grid)
	_thinking_label = Label.new()
	_thinking_label.text = "GoDotter is thinking…"
	_thinking_label.add_theme_font_size_override("font_size", 16)
	_thinking_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_thinking_bar.add_child(_thinking_label)
	_thinking_model_label = Label.new()
	_thinking_model_label.add_theme_font_size_override("font_size", 16)
	_thinking_model_label.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
	_thinking_bar.add_child(_thinking_model_label)
	_thinking_toggle_btn = Button.new()
	_thinking_toggle_btn.text = "Show details ▸"
	_thinking_toggle_btn.flat = true
	_thinking_toggle_btn.add_theme_font_size_override("font_size", 14)
	_thinking_toggle_btn.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	_thinking_toggle_btn.pressed.connect(_on_thinking_toggle_pressed)
	_thinking_bar.add_child(_thinking_toggle_btn)
	vb.add_child(_thinking_bar)
	_thinking_trace_container = PanelContainer.new()
	_thinking_trace_container.visible = false
	_thinking_trace_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_thinking_trace_container.custom_minimum_size = Vector2(0, 88)
	var thinking_vb := VBoxContainer.new()
	thinking_vb.add_theme_constant_override("separation", 4)
	var thinking_header := HBoxContainer.new()
	thinking_header.add_theme_constant_override("separation", 6)
	var trace_label := Label.new()
	trace_label.text = "Live trace"
	trace_label.add_theme_font_size_override("font_size", 13)
	trace_label.add_theme_color_override("font_color", Color(0.6, 0.63, 0.68))
	trace_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thinking_header.add_child(trace_label)
	_thinking_trace_mode_btn = Button.new()
	_thinking_trace_mode_btn.text = "Verbose"
	_thinking_trace_mode_btn.flat = true
	_thinking_trace_mode_btn.add_theme_font_size_override("font_size", 13)
	_thinking_trace_mode_btn.tooltip_text = "Toggle compact/verbose trace layout"
	_thinking_trace_mode_btn.pressed.connect(_on_trace_mode_toggle_pressed)
	thinking_header.add_child(_thinking_trace_mode_btn)
	_thinking_trace_autoscroll_btn = Button.new()
	_thinking_trace_autoscroll_btn.text = "Auto-scroll: On"
	_thinking_trace_autoscroll_btn.flat = true
	_thinking_trace_autoscroll_btn.add_theme_font_size_override("font_size", 13)
	_thinking_trace_autoscroll_btn.tooltip_text = "Keep trace pinned to latest lines"
	_thinking_trace_autoscroll_btn.pressed.connect(_on_trace_autoscroll_toggle_pressed)
	thinking_header.add_child(_thinking_trace_autoscroll_btn)
	_thinking_clear_btn = Button.new()
	_thinking_clear_btn.text = "Clear trace"
	_thinking_clear_btn.flat = true
	_thinking_clear_btn.add_theme_font_size_override("font_size", 13)
	_thinking_clear_btn.tooltip_text = "Clear all trace entries"
	_thinking_clear_btn.pressed.connect(_on_clear_trace_pressed)
	thinking_header.add_child(_thinking_clear_btn)
	_thinking_copy_btn = Button.new()
	_thinking_copy_btn.text = "Copy trace"
	_thinking_copy_btn.flat = true
	_thinking_copy_btn.add_theme_font_size_override("font_size", 13)
	_thinking_copy_btn.tooltip_text = "Copy thinking trace to clipboard"
	_thinking_copy_btn.disabled = true
	_thinking_copy_btn.pressed.connect(_on_copy_trace_pressed)
	thinking_header.add_child(_thinking_copy_btn)
	thinking_vb.add_child(thinking_header)
	_thinking_trace_scroll = ScrollContainer.new()
	_thinking_trace_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_thinking_trace_scroll.custom_minimum_size = Vector2(0, 88)
	_thinking_trace_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_thinking_trace = RichTextLabel.new()
	_thinking_trace.bbcode_enabled = true
	_thinking_trace.fit_content = true
	_thinking_trace.selection_enabled = true
	_thinking_trace.context_menu_enabled = true
	_thinking_trace.focus_mode = Control.FOCUS_CLICK
	_thinking_trace.add_theme_font_size_override("font_size", 14)
	_thinking_trace.add_theme_color_override("default_color", Color(0.62, 0.66, 0.71))
	_thinking_trace_scroll.add_child(_thinking_trace)
	thinking_vb.add_child(_thinking_trace_scroll)
	_thinking_trace_container.add_child(thinking_vb)
	vb.add_child(_thinking_trace_container)

	# Mode + model row (Cursor-style)
	var mode_bar := HBoxContainer.new()
	mode_bar.add_theme_constant_override("separation", 6)
	var mode_lbl := Label.new()
	mode_lbl.text = "Mode"
	mode_lbl.add_theme_font_size_override("font_size", 16)
	mode_lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	mode_bar.add_child(mode_lbl)
	_chat_mode_option = OptionButton.new()
	_chat_mode_option.add_theme_font_size_override("font_size", 16)
	_chat_mode_option.custom_minimum_size = Vector2(96, 0)
	for ml in CHAT_MODE_LABELS:
		_chat_mode_option.add_item(ml)
	_chat_mode_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_mode_option.tooltip_text = "What happens when you press Enter (plain text, no slash needed)."
	mode_bar.add_child(_chat_mode_option)
	var model_lbl := Label.new()
	model_lbl.text = "Model"
	model_lbl.add_theme_font_size_override("font_size", 16)
	model_lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	mode_bar.add_child(model_lbl)
	_chat_model_option = OptionButton.new()
	_chat_model_option.add_theme_font_size_override("font_size", 16)
	_chat_model_option.custom_minimum_size = Vector2(120, 0)
	for mid in MODEL_PRESETS:
		_chat_model_option.add_item(mid)
	_chat_model_option.add_item("Custom (Settings)")
	_chat_model_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_model_option.tooltip_text = "Gemini model for this project (same as Settings → AI)."
	_chat_model_option.item_selected.connect(_on_chat_model_bar_selected)
	mode_bar.add_child(_chat_model_option)
	var plan_lbl := Label.new()
	plan_lbl.text = "Plan"
	plan_lbl.add_theme_font_size_override("font_size", 16)
	plan_lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	mode_bar.add_child(plan_lbl)
	_chat_plan_option = OptionButton.new()
	_chat_plan_option.add_theme_font_size_override("font_size", 16)
	_chat_plan_option.custom_minimum_size = Vector2(180, 0)
	for p in CHAT_PLAN_LABELS:
		_chat_plan_option.add_item(p)
	_chat_plan_option.tooltip_text = (
		"Require approval: full agent stops after plan.\n"
		+ "Auto-run: full agent executes immediately."
	)
	_chat_plan_option.item_selected.connect(_on_chat_plan_bar_selected)
	mode_bar.add_child(_chat_plan_option)
	_chat_mode_option.item_selected.connect(_on_chat_mode_bar_changed)
	call_deferred("_on_chat_mode_bar_changed", 0)
	vb.add_child(mode_bar)
	call_deferred("_sync_chat_model_bar_from_state")
	call_deferred("_sync_chat_plan_bar_from_state")

	# Attachments block (displayed ABOVE input row, Cursor-style)
	_chat_attachment_strip = HBoxContainer.new()
	_chat_attachment_strip.add_theme_constant_override("separation", 6)
	_chat_attachment_strip.visible = false
	vb.add_child(_chat_attachment_strip)

	var attach_row := HBoxContainer.new()
	attach_row.add_theme_constant_override("separation", 6)
	_attachments_label = Label.new()
	_attachments_label.text = "No images attached"
	_attachments_label.add_theme_font_size_override("font_size", 13)
	_attachments_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	_attachments_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	attach_row.add_child(_attachments_label)
	_clear_attachments_btn = Button.new()
	_clear_attachments_btn.text = "Clear"
	_clear_attachments_btn.add_theme_font_size_override("font_size", 13)
	_clear_attachments_btn.flat = true
	_clear_attachments_btn.pressed.connect(_on_clear_attachments_pressed)
	attach_row.add_child(_clear_attachments_btn)
	vb.add_child(attach_row)

	# Input row
	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 4)
	_attach_btn = Button.new()
	_attach_btn.text = "📎"
	_attach_btn.custom_minimum_size = Vector2(44, 36)
	_attach_btn.add_theme_font_size_override("font_size", 16)
	_attach_btn.tooltip_text = "Pick files — or drop images / paste (Ctrl+V) on the input"
	_attach_btn.pressed.connect(_on_attach_image_pressed)
	input_row.add_child(_attach_btn)
	_cmd_input = _build_chat_input_line()
	_cmd_input.name = "CommandInput"
	_cmd_input.placeholder_text = "Message, or drop / paste images here…"
	_cmd_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cmd_input.add_theme_font_size_override("font_size", 18)
	_cmd_input.text_submitted.connect(_on_command_submitted)
	if _cmd_input.has_signal("files_dropped"):
		_cmd_input.files_dropped.connect(_on_chat_image_files_dropped)
	if _cmd_input.has_signal("clipboard_image_pasted"):
		_cmd_input.clipboard_image_pasted.connect(_on_chat_clipboard_image_pasted)
	input_row.add_child(_cmd_input)

	_send_btn = Button.new()
	_send_btn.text = "→"
	_send_btn.custom_minimum_size = Vector2(44, 36)
	_send_btn.add_theme_font_size_override("font_size", 16)
	_send_btn.add_theme_color_override("font_color", Color(0.0, 1.0, 0.9))
	_send_btn.flat = true
	_send_btn.pressed.connect(func(): _on_command_submitted(_cmd_input.text))
	input_row.add_child(_send_btn)
	vb.add_child(input_row)

	_image_file_dialog = FileDialog.new()
	_image_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	_image_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_image_file_dialog.use_native_dialog = true
	_image_file_dialog.title = "Attach image(s)"
	_image_file_dialog.add_filter("*.png,*.jpg,*.jpeg,*.webp,*.bmp ; Images")
	_image_file_dialog.files_selected.connect(_on_chat_images_selected)
	vb.add_child(_image_file_dialog)
	_refresh_attachment_chrome()
	call_deferred("_load_chat_sessions")

	return vb


func _build_chat_input_line() -> LineEdit:
	var input_script: GDScript = load(CHAT_IMAGE_LINE_EDIT_SCRIPT_PATH) as GDScript
	if input_script != null:
		var created: Variant = input_script.new()
		if created is LineEdit:
			return created as LineEdit
		push_warning("[GoDotter] ChatImageLineEdit.new() did not return LineEdit; falling back.")
	else:
		push_warning("[GoDotter] ChatImageLineEdit script failed to load; falling back.")
	var fallback := LineEdit.new()
	fallback.tooltip_text = "Image drop/paste input unavailable; using basic LineEdit."
	return fallback


func _qa_btn(parent: Control, label: String, color: Color, cb: Callable) -> void:
	var btn := Button.new()
	btn.text = label
	btn.add_theme_font_size_override("font_size", 16)
	btn.add_theme_color_override("font_color", color)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0, 36)
	btn.flat = false
	btn.pressed.connect(cb)
	parent.add_child(btn)


# ---------------------------------------------------------------------------
# Tab: Plan
# ---------------------------------------------------------------------------

func _build_plan_tab() -> Control:
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 6)

	var hint := Label.new()
	hint.text = "Plans from Chat (Plan mode or /plan) appear here."
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(hint)
	vb.add_child(HSeparator.new())

	_plan_tasks_box = VBoxContainer.new()
	_plan_tasks_box.name = "PlanTasksBox"
	_plan_tasks_box.visible = false
	_plan_tasks_box.add_theme_constant_override("separation", 4)
	vb.add_child(_plan_tasks_box)
	vb.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_plan_text = RichTextLabel.new()
	_plan_text.name = "PlanText"
	_plan_text.bbcode_enabled = true
	_plan_text.fit_content = true
	_plan_text.selection_enabled = true
	_plan_text.context_menu_enabled = true
	_plan_text.focus_mode = Control.FOCUS_CLICK
	_plan_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plan_text.add_theme_font_size_override("font_size", 18)
	_plan_text.text = "[color=#555]No plan yet. Use [b]Plan[/b] mode in Chat or [b]/plan[/b] to request one.[/color]"
	scroll.add_child(_plan_text)
	vb.add_child(scroll)

	_plan_actions = HBoxContainer.new()
	_plan_actions.name = "PlanActions"
	_plan_actions.visible = false
	_plan_actions.add_theme_constant_override("separation", 6)

	var execute_btn := Button.new()
	execute_btn.text = "▶ Execute Plan"
	execute_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	execute_btn.add_theme_font_size_override("font_size", 18)
	execute_btn.pressed.connect(_on_plan_execute_pressed)
	_plan_actions.add_child(execute_btn)

	var reject_btn := Button.new()
	reject_btn.text = "✕ Reject"
	reject_btn.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
	reject_btn.add_theme_font_size_override("font_size", 18)
	reject_btn.pressed.connect(_on_plan_reject_pressed)
	_plan_actions.add_child(reject_btn)

	var edit_btn := Button.new()
	edit_btn.text = "Refine…"
	edit_btn.add_theme_font_size_override("font_size", 18)
	edit_btn.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	edit_btn.pressed.connect(func():
		_tabs.current_tab = 0
		if _chat_mode_option:
			_chat_mode_option.select(1)
		_cmd_input.grab_focus()
	)
	_plan_actions.add_child(edit_btn)
	vb.add_child(_plan_actions)

	return vb


# ---------------------------------------------------------------------------
# Tab: Inspect
# ---------------------------------------------------------------------------

func _build_inspect_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vb := VBoxContainer.new()
	vb.name = "InspectorVBox"
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 6)
	scroll.add_child(vb)

	# --- Scene section ---
	vb.add_child(_section_header("Current Scene"))
	_inspect_scene_text = RichTextLabel.new()
	_inspect_scene_text.bbcode_enabled = true
	_inspect_scene_text.fit_content = true
	_inspect_scene_text.selection_enabled = true
	_inspect_scene_text.context_menu_enabled = true
	_inspect_scene_text.focus_mode = Control.FOCUS_CLICK
	_inspect_scene_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspect_scene_text.add_theme_font_size_override("font_size", 18)
	_inspect_scene_text.text = "[color=#555](no scene open)[/color]"
	vb.add_child(_inspect_scene_text)

	vb.add_child(HSeparator.new())

	# --- Node section ---
	vb.add_child(_section_header("Selected Node"))
	_inspect_node_text = RichTextLabel.new()
	_inspect_node_text.bbcode_enabled = true
	_inspect_node_text.fit_content = true
	_inspect_node_text.selection_enabled = true
	_inspect_node_text.context_menu_enabled = true
	_inspect_node_text.focus_mode = Control.FOCUS_CLICK
	_inspect_node_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspect_node_text.add_theme_font_size_override("font_size", 18)
	_inspect_node_text.text = "[color=#555](no node selected)[/color]"
	vb.add_child(_inspect_node_text)

	vb.add_child(HSeparator.new())

	# --- Neon visualizer section ---
	vb.add_child(_section_header("AI Visual Map"))

	var viz_desc := Label.new()
	viz_desc.text = (
		"Paints every node a unique neon color by type, captures a screenshot,\n"
		+ "and asks Gemini to describe the spatial layout, overlaps, and z-ordering."
	)
	viz_desc.add_theme_font_size_override("font_size", 16)
	viz_desc.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	viz_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(viz_desc)

	var viz_row := HBoxContainer.new()
	viz_row.add_theme_constant_override("separation", 4)

	_viz_query_input = LineEdit.new()
	_viz_query_input.name = "VizQueryInput"
	_viz_query_input.placeholder_text = "Optional query: which nodes overlap?"
	_viz_query_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viz_query_input.add_theme_font_size_override("font_size", 16)
	viz_row.add_child(_viz_query_input)

	var viz_btn := Button.new()
	viz_btn.text = "Visualize"
	viz_btn.add_theme_color_override("font_color", Color(0.0, 1.0, 0.9))
	viz_btn.add_theme_font_size_override("font_size", 18)
	viz_btn.pressed.connect(_on_visualize_scene_pressed)
	viz_row.add_child(viz_btn)
	vb.add_child(viz_row)

	vb.add_child(HSeparator.new())

	# --- 3D asset review ---
	vb.add_child(_section_header("3D Asset Review"))
	var review_desc := Label.new()
	review_desc.text = "Select a Node3D / MeshInstance3D, then click to capture from 6 angles."
	review_desc.add_theme_font_size_override("font_size", 16)
	review_desc.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	review_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(review_desc)

	var review_3d_btn := Button.new()
	review_3d_btn.name = "Review3DBtn"
	review_3d_btn.text = "Review 3D Asset (6 Angles)"
	review_3d_btn.visible = false
	review_3d_btn.add_theme_font_size_override("font_size", 18)
	review_3d_btn.pressed.connect(_on_review_3d_pressed)
	vb.add_child(review_3d_btn)

	return scroll


func _build_node_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 6)
	scroll.add_child(vb)

	vb.add_child(_section_header("Selected Node"))

	_node_text = RichTextLabel.new()
	_node_text.bbcode_enabled = true
	_node_text.fit_content = true
	_node_text.selection_enabled = true
	_node_text.context_menu_enabled = true
	_node_text.focus_mode = Control.FOCUS_CLICK
	_node_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_node_text.add_theme_font_size_override("font_size", 18)
	_node_text.text = "[color=#555](no node selected)[/color]"
	vb.add_child(_node_text)

	return scroll


# ---------------------------------------------------------------------------
# Tab: Memory
# ---------------------------------------------------------------------------

func _build_memory_tab() -> Control:
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 4)

	var header_row := HBoxContainer.new()
	var header_lbl := Label.new()
	header_lbl.text = "Project Memory Files"
	header_lbl.add_theme_font_size_override("font_size", 18)
	header_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(header_lbl)
	var refresh_btn := Button.new()
	refresh_btn.text = "⟳ Refresh"
	refresh_btn.flat = true
	refresh_btn.add_theme_font_size_override("font_size", 16)
	refresh_btn.pressed.connect(_refresh_memory_tab)
	header_row.add_child(refresh_btn)
	vb.add_child(header_row)
	vb.add_child(HSeparator.new())

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 120

	_memory_file_list = ItemList.new()
	_memory_file_list.add_theme_font_size_override("font_size", 16)
	_memory_file_list.custom_minimum_size.x = 100
	_memory_file_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_memory_file_list.item_selected.connect(_on_memory_file_selected)
	split.add_child(_memory_file_list)

	var content_scroll := ScrollContainer.new()
	content_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_memory_content = RichTextLabel.new()
	_memory_content.bbcode_enabled = true
	_memory_content.fit_content = true
	_memory_content.selection_enabled = true
	_memory_content.context_menu_enabled = true
	_memory_content.focus_mode = Control.FOCUS_CLICK
	_memory_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_memory_content.add_theme_font_size_override("font_size", 16)
	_memory_content.text = "[color=#555]Select a file to view its contents.[/color]"
	content_scroll.add_child(_memory_content)
	split.add_child(content_scroll)
	vb.add_child(split)

	call_deferred("_refresh_memory_tab")
	return vb


# ---------------------------------------------------------------------------
# Tab: Settings
# ---------------------------------------------------------------------------

func _build_settings_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 8)
	scroll.add_child(vb)

	# --- Machine settings ---
	vb.add_child(_section_header("Backend (machine-wide)"))

	vb.add_child(_settings_label("Backend directory"))
	_set_backend_dir = LineEdit.new()
	_set_backend_dir.text = state.backend_dir
	_set_backend_dir.placeholder_text = "Auto: addons/GoDotter/backend/ (bundled)"
	_set_backend_dir.add_theme_font_size_override("font_size", 16)
	_set_backend_dir.tooltip_text = "Leave blank to use the bundled backend inside addons/GoDotter/backend/"
	vb.add_child(_set_backend_dir)

	vb.add_child(_settings_label("Python executable (blank = auto)"))
	_set_python_path = LineEdit.new()
	_set_python_path.text = state.backend_python
	_set_python_path.placeholder_text = "Auto-detected from .venv"
	_set_python_path.add_theme_font_size_override("font_size", 16)
	vb.add_child(_set_python_path)

	_set_autostart = CheckBox.new()
	_set_autostart.text = "Auto-launch backend on Godot startup"
	_set_autostart.add_theme_font_size_override("font_size", 18)
	_set_autostart.button_pressed = state.autostart_backend
	vb.add_child(_set_autostart)

	vb.add_child(_settings_label("Provider API keys (machine-wide)"))
	_set_api_key_gemini = LineEdit.new()
	_set_api_key_gemini.secret = true
	_set_api_key_gemini.text = (
		state.get_provider_api_key("gemini")
		if state.has_method("get_provider_api_key")
		else state.api_key
	)
	_set_api_key_gemini.placeholder_text = "Gemini key (GEMINI_API_KEY / GOOGLE_API_KEY)"
	_set_api_key_gemini.add_theme_font_size_override("font_size", 16)
	vb.add_child(_set_api_key_gemini)

	_set_api_key_openai = LineEdit.new()
	_set_api_key_openai.secret = true
	_set_api_key_openai.text = (
		state.get_provider_api_key("openai")
		if state.has_method("get_provider_api_key")
		else ""
	)
	_set_api_key_openai.placeholder_text = "OpenAI key (optional for many local OpenAI-compatible servers)"
	_set_api_key_openai.add_theme_font_size_override("font_size", 16)
	vb.add_child(_set_api_key_openai)

	_set_api_key_claude = LineEdit.new()
	_set_api_key_claude.secret = true
	_set_api_key_claude.text = (
		state.get_provider_api_key("claude")
		if state.has_method("get_provider_api_key")
		else ""
	)
	_set_api_key_claude.placeholder_text = "Claude key (ANTHROPIC_API_KEY)"
	_set_api_key_claude.add_theme_font_size_override("font_size", 16)
	vb.add_child(_set_api_key_claude)

	_save_api_keys_btn = Button.new()
	_save_api_keys_btn.text = "Save API Keys"
	_save_api_keys_btn.add_theme_font_size_override("font_size", 15)
	_save_api_keys_btn.add_theme_color_override("font_color", Color(0.35, 0.85, 0.45))
	_save_api_keys_btn.tooltip_text = "Persist keys immediately and sync backend key files."
	_save_api_keys_btn.pressed.connect(_on_save_api_keys_only)
	vb.add_child(_save_api_keys_btn)

	var reset_setup_btn := Button.new()
	reset_setup_btn.text = "Re-run Setup Wizard"
	reset_setup_btn.add_theme_font_size_override("font_size", 16)
	reset_setup_btn.add_theme_color_override("font_color", Color(0.7, 0.5, 0.3))
	reset_setup_btn.pressed.connect(_on_reset_setup)
	vb.add_child(reset_setup_btn)

	vb.add_child(HSeparator.new())

	# --- Project settings ---
	vb.add_child(_section_header("AI (this project)"))

	vb.add_child(_settings_label("Backend URL"))
	_set_url = LineEdit.new()
	_set_url.text = state.settings.get("backend_url", "http://127.0.0.1:8765")
	_set_url.add_theme_font_size_override("font_size", 16)
	vb.add_child(_set_url)

	_ai_openai_base_title = _settings_label("OpenAI-compatible API base (this project)")
	vb.add_child(_ai_openai_base_title)
	_ai_openai_base_hint = Label.new()
	_ai_openai_base_hint.text = (
		"Official default is https://api.openai.com/v1 — use http://127.0.0.1:1234/v1 for LM Studio, "
		+ "or your provider’s OpenAI-style base URL. Leave empty to use OPENAI_BASE_URL from the environment."
	)
	_ai_openai_base_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ai_openai_base_hint.add_theme_font_size_override("font_size", 13)
	_ai_openai_base_hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	vb.add_child(_ai_openai_base_hint)
	_ai_openai_base_url = LineEdit.new()
	_ai_openai_base_url.add_theme_font_size_override("font_size", 16)
	_ai_openai_base_url.placeholder_text = "e.g. http://127.0.0.1:1234/v1 or https://api.openai.com/v1"
	var ai0: Dictionary = state.settings.get("ai_settings", {})
	_ai_openai_base_url.text = str(ai0.get("openai_base_url", "")) if typeof(ai0) == TYPE_DICTIONARY else ""
	vb.add_child(_ai_openai_base_url)

	vb.add_child(_settings_label("Gemini model"))
	_model_preset = OptionButton.new()
	_model_preset.add_theme_font_size_override("font_size", 16)
	for mid in MODEL_PRESETS:
		_model_preset.add_item(mid)
	_model_preset.add_item("Custom…")
	_model_preset.item_selected.connect(_on_model_preset_selected)
	vb.add_child(_model_preset)
	_model_custom = LineEdit.new()
	_model_custom.placeholder_text = "Custom model id (e.g. gemini-3.1-pro-preview)"
	_model_custom.add_theme_font_size_override("font_size", 16)
	_model_custom.visible = false
	vb.add_child(_model_custom)
	_apply_model_selection_from_settings()

	vb.add_child(_settings_label("Provider"))
	_ai_provider_option = OptionButton.new()
	_ai_provider_option.add_theme_font_size_override("font_size", 16)
	for p in ["gemini", "claude", "openai"]:
		_ai_provider_option.add_item(p)
	_ai_provider_option.item_selected.connect(_on_ai_provider_or_model_changed)
	vb.add_child(_ai_provider_option)

	vb.add_child(_settings_label("Model (provider specific)"))
	_ai_model_option = OptionButton.new()
	_ai_model_option.add_theme_font_size_override("font_size", 16)
	_ai_model_option.item_selected.connect(_on_ai_provider_or_model_changed)
	vb.add_child(_ai_model_option)

	vb.add_child(_settings_label("Preset"))
	_ai_preset_option = OptionButton.new()
	_ai_preset_option.add_theme_font_size_override("font_size", 16)
	for pr in AI_PRESET_NAMES:
		_ai_preset_option.add_item(pr)
	_ai_preset_option.item_selected.connect(_on_ai_preset_changed)
	vb.add_child(_ai_preset_option)

	vb.add_child(_settings_label("Temperature"))
	_ai_temperature_spin = SpinBox.new()
	_ai_temperature_spin.min_value = 0.0
	_ai_temperature_spin.max_value = 2.0
	_ai_temperature_spin.step = 0.05
	_ai_temperature_spin.add_theme_font_size_override("font_size", 16)
	vb.add_child(_ai_temperature_spin)

	vb.add_child(_settings_label("top_p (if supported)"))
	_ai_top_p_spin = SpinBox.new()
	_ai_top_p_spin.min_value = 0.0
	_ai_top_p_spin.max_value = 1.0
	_ai_top_p_spin.step = 0.05
	_ai_top_p_spin.add_theme_font_size_override("font_size", 16)
	vb.add_child(_ai_top_p_spin)

	vb.add_child(_settings_label("Reasoning effort (if supported)"))
	_ai_reasoning_effort_option = OptionButton.new()
	_ai_reasoning_effort_option.add_theme_font_size_override("font_size", 16)
	for e in ["minimal", "low", "medium", "high", "xhigh", "max"]:
		_ai_reasoning_effort_option.add_item(e)
	vb.add_child(_ai_reasoning_effort_option)

	vb.add_child(_settings_label("Thinking level (Gemini 3.1)"))
	_ai_thinking_level_option = OptionButton.new()
	_ai_thinking_level_option.add_theme_font_size_override("font_size", 16)
	for lv in ["LOW", "MEDIUM", "HIGH"]:
		_ai_thinking_level_option.add_item(lv)
	vb.add_child(_ai_thinking_level_option)

	vb.add_child(_settings_label("Thinking budget (Gemini 2.5)"))
	_ai_thinking_budget_spin = SpinBox.new()
	_ai_thinking_budget_spin.min_value = -1
	_ai_thinking_budget_spin.max_value = 32768
	_ai_thinking_budget_spin.step = 128
	_ai_thinking_budget_spin.add_theme_font_size_override("font_size", 16)
	vb.add_child(_ai_thinking_budget_spin)

	_ai_thinking_summary_check = CheckBox.new()
	_ai_thinking_summary_check.text = "Enable thinking summaries (if supported)"
	_ai_thinking_summary_check.add_theme_font_size_override("font_size", 16)
	vb.add_child(_ai_thinking_summary_check)

	_ai_streaming_check = CheckBox.new()
	_ai_streaming_check.text = "Enable streaming (if supported)"
	_ai_streaming_check.add_theme_font_size_override("font_size", 16)
	vb.add_child(_ai_streaming_check)

	vb.add_child(_settings_label("Timeout (seconds)"))
	_ai_timeout_spin = SpinBox.new()
	_ai_timeout_spin.min_value = 10
	_ai_timeout_spin.max_value = 300
	_ai_timeout_spin.step = 5
	_ai_timeout_spin.add_theme_font_size_override("font_size", 16)
	vb.add_child(_ai_timeout_spin)

	vb.add_child(_settings_label("Retries"))
	_ai_retries_spin = SpinBox.new()
	_ai_retries_spin.min_value = 0
	_ai_retries_spin.max_value = 6
	_ai_retries_spin.step = 1
	_ai_retries_spin.add_theme_font_size_override("font_size", 16)
	vb.add_child(_ai_retries_spin)

	var ai_btns := HBoxContainer.new()
	ai_btns.add_theme_constant_override("separation", 6)
	var reset_ai_btn := Button.new()
	reset_ai_btn.text = "Reset to recommended coding defaults"
	reset_ai_btn.add_theme_font_size_override("font_size", 14)
	reset_ai_btn.pressed.connect(_on_reset_ai_defaults_pressed)
	ai_btns.add_child(reset_ai_btn)
	var test_ai_btn := Button.new()
	test_ai_btn.text = "Test model settings"
	test_ai_btn.add_theme_font_size_override("font_size", 14)
	test_ai_btn.pressed.connect(_on_test_ai_settings_pressed)
	ai_btns.add_child(test_ai_btn)
	vb.add_child(ai_btns)

	_ai_settings_status = Label.new()
	_ai_settings_status.text = ""
	_ai_settings_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ai_settings_status.add_theme_font_size_override("font_size", 14)
	_ai_settings_status.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	vb.add_child(_ai_settings_status)

	vb.add_child(_settings_label("Max output tokens (completions)"))
	_set_max_output_tokens = SpinBox.new()
	_set_max_output_tokens.min_value = 1024
	_set_max_output_tokens.max_value = 131072
	_set_max_output_tokens.step = 1024
	_set_max_output_tokens.value = clampi(int(state.settings.get("max_output_tokens", 131072)), 1024, 131072)
	_set_max_output_tokens.add_theme_font_size_override("font_size", 16)
	_set_max_output_tokens.tooltip_text = (
		"Max tokens the model can generate per backend call (plans, code edits, log fixes, visual analysis). "
		+ "Default is set to the current safe maximum to avoid truncating large JSON/file-edit payloads. "
		+ "Gemini caps vary by model; allowed range 1024–131072."
	)
	vb.add_child(_set_max_output_tokens)

	vb.add_child(_settings_label("Max input tokens (context budget)"))
	_set_max_input_tokens = SpinBox.new()
	_set_max_input_tokens.min_value = 4096
	_set_max_input_tokens.max_value = 2000000
	_set_max_input_tokens.step = 4096
	_set_max_input_tokens.value = clampi(int(state.settings.get("max_input_tokens", 2000000)), 4096, 2000000)
	_set_max_input_tokens.add_theme_font_size_override("font_size", 16)
	_set_max_input_tokens.tooltip_text = (
		"Soft budget for how much project + editor context is packed into prompts (ranked files, live hints, file excerpts). "
		+ "Default is set to the current safe maximum for deeper planning and broader game-project context."
	)
	vb.add_child(_set_max_input_tokens)

	vb.add_child(_settings_label("Approval mode"))
	_set_approval_mode = OptionButton.new()
	_set_approval_mode.add_theme_font_size_override("font_size", 16)
	for mode in ["review", "assisted", "autopilot", "yolo"]:
		_set_approval_mode.add_item(mode)
	var current_mode: String = state.settings.get("approval_mode", "review")
	var mode_idx := ["review", "assisted", "autopilot", "yolo"].find(current_mode)
	_set_approval_mode.selected = max(0, mode_idx)
	vb.add_child(_set_approval_mode)

	_set_file_edits = CheckBox.new()
	_set_file_edits.text = "Allow AI to write files (Phase 4)"
	_set_file_edits.add_theme_font_size_override("font_size", 18)
	_set_file_edits.button_pressed = state.settings.get("enable_file_edits", false)
	vb.add_child(_set_file_edits)

	vb.add_child(HSeparator.new())
	vb.add_child(_section_header("Backend Capabilities (live)"))
	vb.add_child(_settings_label("Commands auto-disable when routes are missing."))
	_caps_status = RichTextLabel.new()
	_caps_status.bbcode_enabled = true
	_caps_status.fit_content = true
	_caps_status.selection_enabled = false
	_caps_status.focus_mode = Control.FOCUS_NONE
	_caps_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_caps_status.add_theme_font_size_override("font_size", 14)
	vb.add_child(_caps_status)
	call_deferred("_refresh_capabilities_status_text")

	vb.add_child(HSeparator.new())

	var save_btn := Button.new()
	save_btn.text = "Save Settings"
	save_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	save_btn.add_theme_font_size_override("font_size", 18)
	save_btn.pressed.connect(_on_save_settings)
	vb.add_child(save_btn)

	vb.add_child(
		_settings_label(
			"You can also set GEMINI_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY / OPENAI_BASE_URL before python main.py"
		)
	)
	_sync_ai_settings_controls_from_state()

	return scroll


func _settings_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	return lbl


func _section_header(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
	return lbl


func _refresh_capabilities_status_text() -> void:
	if _caps_status == null:
		return
	if _backend_caps.is_empty():
		_caps_status.text = (
			"[color=#888]Capability probe pending. Bring backend online to detect supported routes.[/color]"
		)
		return
	var rows: Array[String] = []
	var checks := {
		"/agent": "/agent/run",
		"/plan": "/agent/plan",
		"/do": "/agent/execute",
		"/audit": "/project/index",
		"/memory": "/memory",
		"/fixlogs": "/agent/fix_from_logs",
		"/neon": "/agent/visual_map",
	}
	for cmd in checks.keys():
		var route: String = str(checks[cmd])
		var ok: bool = bool(_backend_caps.get(route, false))
		var icon: String = "✓" if ok else "✕"
		var color: String = "#2ecc71" if ok else "#e67e22"
		rows.append("[color=%s]%s[/color] [b]%s[/b]  [color=#777](%s)[/color]" % [color, icon, cmd, route])
	_caps_status.text = "\n".join(rows)


func _on_model_preset_selected(_idx: int) -> void:
	_update_model_custom_visibility()


func _update_model_custom_visibility() -> void:
	if _model_preset == null or _model_custom == null:
		return
	var is_custom: bool = _model_preset.selected >= MODEL_PRESETS.size()
	_model_custom.visible = is_custom


func _apply_model_selection_from_settings() -> void:
	if _model_preset == null or _model_custom == null:
		return
	var cur: String = str(state.settings.get("model", MODEL_PRESETS[0]))
	var idx: int = MODEL_PRESETS.find(cur)
	if idx >= 0:
		_model_preset.select(idx)
		_model_custom.text = ""
	else:
		_model_preset.select(MODEL_PRESETS.size())
		_model_custom.text = cur
	_update_model_custom_visibility()


func _collect_model_for_save() -> String:
	if _model_preset == null:
		return str(state.settings.get("model", MODEL_PRESETS[0]))
	if _model_preset.selected >= MODEL_PRESETS.size():
		var t: String = _model_custom.text.strip_edges()
		return t if t != "" else MODEL_PRESETS[0]
	return MODEL_PRESETS[_model_preset.selected]


func _default_ai_settings_for(provider: String, model: String) -> Dictionary:
	var p: String = provider.to_lower()
	var models: Array[String] = _model_list_for_provider(p)
	var m: String = model.strip_edges()
	if not models.has(m):
		m = models[0]
	var fast := {
		"temperature": 0.2, "top_p": 0.9, "max_output_tokens": 32768,
		"thinking_level": "LOW", "thinking_summaries": false,
		"streaming": false, "timeout_sec": 90, "retries": 1
	}
	var balanced := {
		"temperature": 0.2, "top_p": 0.9, "max_output_tokens": 65536,
		"thinking_level": "MEDIUM", "thinking_summaries": false,
		"streaming": false, "timeout_sec": 120, "retries": 2
	}
	var deep := {
		"temperature": 0.2, "top_p": 0.9, "max_output_tokens": 131072,
		"thinking_level": "HIGH", "thinking_summaries": true,
		"streaming": false, "timeout_sec": 150, "retries": 2
	}
	var extreme := {
		"temperature": 0.2, "top_p": 0.9, "max_output_tokens": 131072,
		"thinking_level": "HIGH", "thinking_summaries": true,
		"streaming": false, "timeout_sec": 180, "retries": 3
	}
	if p == "gemini" and m.begins_with("gemini-2.5"):
		fast["thinking_budget"] = 0
		balanced["thinking_budget"] = -1
		deep["thinking_budget"] = 8192
		extreme["thinking_budget"] = 24576
		fast.erase("thinking_level")
		balanced.erase("thinking_level")
		deep.erase("thinking_level")
		extreme.erase("thinking_level")
	if p == "claude":
		fast["reasoning_effort"] = "low"
		balanced["reasoning_effort"] = "medium"
		deep["reasoning_effort"] = "high"
		extreme["reasoning_effort"] = "max"
		fast.erase("thinking_level"); balanced.erase("thinking_level"); deep.erase("thinking_level"); extreme.erase("thinking_level")
	if p == "openai":
		fast["reasoning_effort"] = "low"
		balanced["reasoning_effort"] = "medium"
		deep["reasoning_effort"] = "high"
		extreme["reasoning_effort"] = "xhigh"
		fast.erase("thinking_level"); balanced.erase("thinking_level"); deep.erase("thinking_level"); extreme.erase("thinking_level")
	return {
		"provider": p,
		"model": m,
		"preset": "Deep",
		"presets": {
			"Fast": fast,
			"Balanced": balanced,
			"Deep": deep,
			"Extreme": extreme,
		},
	}


func _model_list_for_provider(provider: String) -> Array[String]:
	match provider.to_lower():
		"gemini":
			return ["gemini-3.1-pro-preview", "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash"]
		"claude":
			return ["claude-3-7-sonnet"]
		"openai":
			return ["gpt-5"]
		_:
			return ["gemini-3.1-pro-preview"]


func _ensure_ai_settings_shape() -> Dictionary:
	var cur = state.settings.get("ai_settings", {})
	if typeof(cur) != TYPE_DICTIONARY:
		cur = {}
	var d: Dictionary = cur
	var provider: String = str(d.get("provider", "gemini")).to_lower()
	if not d.has("openai_base_url"):
		d["openai_base_url"] = ""
	var models: Array[String] = _model_list_for_provider(provider)
	var model: String = str(d.get("model", "gemini-3.1-pro-preview"))
	var custom_openai: bool = provider == "openai" and str(d.get("openai_base_url", "")).strip_edges() != ""
	if provider == "openai" and custom_openai and model.strip_edges() != "":
		pass
	elif model == "" or not models.has(model):
		model = models[0]
	var defs: Dictionary = _default_ai_settings_for(provider, model)
	for k in defs.keys():
		if not d.has(k):
			d[k] = defs[k]
	if typeof(d.get("presets", null)) != TYPE_DICTIONARY:
		d["presets"] = defs["presets"]
	for pr in AI_PRESET_NAMES:
		if not d["presets"].has(pr) or typeof(d["presets"][pr]) != TYPE_DICTIONARY:
			d["presets"][pr] = defs["presets"][pr]
	d["provider"] = provider
	d["model"] = model
	state.settings["ai_settings"] = d
	state.settings["model"] = model
	return d


func _sync_ai_settings_controls_from_state() -> void:
	if state == null:
		return
	var ai: Dictionary = _ensure_ai_settings_shape()
	var provider: String = str(ai.get("provider", "gemini")).to_lower()
	var model: String = str(ai.get("model", "gemini-3.1-pro-preview"))
	var preset: String = str(ai.get("preset", "Deep"))
	var presets: Dictionary = ai.get("presets", {})
	if _ai_provider_option:
		_ai_provider_option.set_block_signals(true)
		var p_idx := ["gemini", "claude", "openai"].find(provider)
		_ai_provider_option.selected = max(0, p_idx)
		_ai_provider_option.set_block_signals(false)
	if _ai_model_option:
		_ai_model_option.set_block_signals(true)
		_ai_model_option.clear()
		var models: Array[String] = _model_list_for_provider(provider)
		for m in models:
			_ai_model_option.add_item(m)
		var midx: int = models.find(model)
		if midx < 0 and model.strip_edges() != "":
			_ai_model_option.add_item(model)
			midx = _ai_model_option.item_count - 1
		if midx < 0:
			midx = 0
			model = _ai_model_option.get_item_text(0)
		_ai_model_option.selected = midx
		_ai_model_option.set_block_signals(false)
	if _ai_preset_option:
		_ai_preset_option.set_block_signals(true)
		var pr_idx: int = AI_PRESET_NAMES.find(preset)
		_ai_preset_option.selected = max(0, pr_idx)
		_ai_preset_option.set_block_signals(false)
	var active: Dictionary = presets.get(preset, {})
	if _ai_temperature_spin:
		_ai_temperature_spin.value = float(active.get("temperature", 0.2))
	if _ai_top_p_spin:
		_ai_top_p_spin.value = float(active.get("top_p", 0.9))
	if _ai_thinking_budget_spin:
		_ai_thinking_budget_spin.value = int(active.get("thinking_budget", -1))
	if _ai_timeout_spin:
		_ai_timeout_spin.value = int(active.get("timeout_sec", 120))
	if _ai_retries_spin:
		_ai_retries_spin.value = int(active.get("retries", 2))
	if _ai_streaming_check:
		_ai_streaming_check.button_pressed = bool(active.get("streaming", false))
	if _ai_thinking_summary_check:
		_ai_thinking_summary_check.button_pressed = bool(active.get("thinking_summaries", false))
	if _ai_reasoning_effort_option:
		var re_idx := ["minimal", "low", "medium", "high", "xhigh", "max"].find(str(active.get("reasoning_effort", "medium")))
		_ai_reasoning_effort_option.selected = max(0, re_idx)
	if _ai_thinking_level_option:
		var lv_idx := ["LOW", "MEDIUM", "HIGH"].find(str(active.get("thinking_level", "MEDIUM")).to_upper())
		_ai_thinking_level_option.selected = max(0, lv_idx)
	if _ai_openai_base_url:
		_ai_openai_base_url.text = str(ai.get("openai_base_url", ""))
	_apply_ai_control_visibility(provider, model)
	if _ai_settings_status:
		_ai_settings_status.text = "Provider: %s | Model: %s | Preset: %s" % [provider, model, preset]


func _apply_ai_control_visibility(provider: String, model: String) -> void:
	var p: String = provider.to_lower()
	var is_g31: bool = p == "gemini" and model == "gemini-3.1-pro-preview"
	var is_g25: bool = p == "gemini" and model.begins_with("gemini-2.5")
	if _ai_openai_base_title:
		_ai_openai_base_title.visible = (p == "openai")
	if _ai_openai_base_hint:
		_ai_openai_base_hint.visible = (p == "openai")
	if _ai_openai_base_url:
		_ai_openai_base_url.visible = (p == "openai")
	if _ai_top_p_spin:
		_ai_top_p_spin.editable = (p == "gemini" or p == "claude" or p == "openai")
		_ai_top_p_spin.visible = _ai_top_p_spin.editable
	if _ai_thinking_level_option:
		_ai_thinking_level_option.visible = is_g31
	if _ai_thinking_budget_spin:
		_ai_thinking_budget_spin.visible = is_g25
	if _ai_reasoning_effort_option:
		_ai_reasoning_effort_option.visible = (p == "claude" or p == "openai")
	if _ai_thinking_summary_check:
		_ai_thinking_summary_check.visible = true
		if is_g31:
			_ai_thinking_summary_check.text = "Thinking summaries (Gemini include_thoughts)"
		else:
			_ai_thinking_summary_check.text = "Thinking summaries on/off (if supported)"


func _save_current_controls_into_active_preset() -> void:
	if state == null:
		return
	var ai: Dictionary = _ensure_ai_settings_shape()
	var preset: String = str(ai.get("preset", "Deep"))
	var presets: Dictionary = ai.get("presets", {})
	var active: Dictionary = presets.get(preset, {})
	active["temperature"] = float(_ai_temperature_spin.value) if _ai_temperature_spin else 0.2
	active["top_p"] = float(_ai_top_p_spin.value) if _ai_top_p_spin else 0.9
	active["max_output_tokens"] = clampi(int(_set_max_output_tokens.value), 1024, 131072) if _set_max_output_tokens else 65536
	active["timeout_sec"] = clampi(int(_ai_timeout_spin.value), 10, 300) if _ai_timeout_spin else 120
	active["retries"] = clampi(int(_ai_retries_spin.value), 0, 6) if _ai_retries_spin else 2
	active["streaming"] = bool(_ai_streaming_check.button_pressed) if _ai_streaming_check else false
	active["thinking_summaries"] = bool(_ai_thinking_summary_check.button_pressed) if _ai_thinking_summary_check else false
	if _ai_reasoning_effort_option and _ai_reasoning_effort_option.visible:
		active["reasoning_effort"] = _ai_reasoning_effort_option.get_item_text(_ai_reasoning_effort_option.selected)
	else:
		active.erase("reasoning_effort")
	if _ai_thinking_level_option and _ai_thinking_level_option.visible:
		active["thinking_level"] = _ai_thinking_level_option.get_item_text(_ai_thinking_level_option.selected)
		active.erase("thinking_budget")
	if _ai_thinking_budget_spin and _ai_thinking_budget_spin.visible:
		active["thinking_budget"] = int(_ai_thinking_budget_spin.value)
		active.erase("thinking_level")
	presets[preset] = active
	ai["presets"] = presets
	if _ai_openai_base_url:
		ai["openai_base_url"] = _ai_openai_base_url.text.strip_edges()
	state.settings["ai_settings"] = ai
	state.settings["model"] = str(ai.get("model", state.settings.get("model", "gemini-3.1-pro-preview")))


func _on_ai_provider_or_model_changed(_idx: int) -> void:
	if state == null:
		return
	_save_current_controls_into_active_preset()
	var provider: String = "gemini"
	if _ai_provider_option:
		provider = _ai_provider_option.get_item_text(_ai_provider_option.selected).to_lower()
	var models: Array[String] = _model_list_for_provider(provider)
	var model: String = models[0]
	if _ai_model_option and _ai_model_option.item_count > 0:
		var sel: int = clampi(_ai_model_option.selected, 0, _ai_model_option.item_count - 1)
		model = _ai_model_option.get_item_text(sel)
	var kept_openai_base := ""
	var prev_ai: Dictionary = state.settings.get("ai_settings", {})
	if typeof(prev_ai) == TYPE_DICTIONARY:
		kept_openai_base = str(prev_ai.get("openai_base_url", "")).strip_edges()
	var ai: Dictionary = _default_ai_settings_for(provider, model)
	if kept_openai_base != "":
		ai["openai_base_url"] = kept_openai_base
	state.settings["ai_settings"] = ai
	state.settings["model"] = model
	_sync_ai_settings_controls_from_state()


func _on_ai_preset_changed(_idx: int) -> void:
	if state == null:
		return
	_save_current_controls_into_active_preset()
	var ai: Dictionary = _ensure_ai_settings_shape()
	var pr: String = "Deep"
	if _ai_preset_option:
		pr = _ai_preset_option.get_item_text(_ai_preset_option.selected)
	ai["preset"] = pr
	state.settings["ai_settings"] = ai
	_sync_ai_settings_controls_from_state()


func _on_reset_ai_defaults_pressed() -> void:
	if state == null:
		return
	var provider: String = "gemini"
	if _ai_provider_option:
		provider = _ai_provider_option.get_item_text(_ai_provider_option.selected).to_lower()
	var model: String = "gemini-3.1-pro-preview"
	if _ai_model_option:
		model = _ai_model_option.get_item_text(_ai_model_option.selected)
	state.settings["ai_settings"] = _default_ai_settings_for(provider, model)
	state.settings["model"] = model
	_sync_ai_settings_controls_from_state()
	_log_info("[color=#7fb3d3]AI settings reset to recommended coding defaults.[/color]")


func _on_test_ai_settings_pressed() -> void:
	if not await _await_backend_http_ready():
		_log_error("Backend offline — cannot test AI settings.")
		return
	_save_current_controls_into_active_preset()
	if agent_client and agent_client.has_method("request_ai_test"):
		_set_thinking(true, "AI Settings Test")
		agent_client.request_ai_test(_build_ai_context_bundle(), "Godot coding smoke test: detect null reference risk.")


func _sync_chat_model_bar_from_state() -> void:
	if _chat_model_option == null or state == null:
		return
	var cur: String = str(state.settings.get("model", MODEL_PRESETS[0]))
	var idx: int = MODEL_PRESETS.find(cur)
	_chat_model_option.set_block_signals(true)
	if idx >= 0:
		_chat_model_option.select(idx)
	else:
		_chat_model_option.select(MODEL_PRESETS.size())
	_chat_model_option.set_block_signals(false)


func _on_chat_model_bar_selected(idx: int) -> void:
	if state == null:
		return
	var ai_now: Dictionary = _ensure_ai_settings_shape()
	var provider_now: String = str(ai_now.get("provider", "gemini")).to_lower()
	if provider_now != "gemini":
		_log_info("Chat model quick-switch currently applies to Gemini presets only. Change non-Gemini model in Settings → AI.")
		_sync_chat_model_bar_from_state()
		return
	if idx >= 0 and idx < MODEL_PRESETS.size():
		var mid: String = MODEL_PRESETS[idx]
		if str(state.settings.get("model", "")) != mid:
			state.settings["model"] = mid
			var ai: Dictionary = _ensure_ai_settings_shape()
			ai["provider"] = "gemini"
			ai["model"] = mid
			state.settings["ai_settings"] = ai
			state.save_settings()
			_apply_model_selection_from_settings()
			_sync_ai_settings_controls_from_state()


func _sync_chat_plan_bar_from_state() -> void:
	if _chat_plan_option == null or state == null:
		return
	var chat_plan: String = str(state.settings.get("chat_plan_mode", "")).to_lower()
	var approval_mode: String = str(state.settings.get("approval_mode", "review")).to_lower()
	var require_approval: bool = (chat_plan == "require_approval") or (chat_plan == "" and approval_mode == "review")
	_chat_plan_option.set_block_signals(true)
	_chat_plan_option.select(0 if require_approval else 1)
	_chat_plan_option.set_block_signals(false)


func _chat_plan_requires_approval() -> bool:
	if _chat_plan_option == null:
		return true
	return _chat_plan_option.selected == 0


func _on_chat_plan_bar_selected(idx: int) -> void:
	if state == null:
		return
	var requires_approval: bool = (idx == 0)
	state.settings["chat_plan_mode"] = "require_approval" if requires_approval else "auto_run"
	state.settings["approval_mode"] = "review" if requires_approval else "autopilot"
	if not requires_approval and not bool(state.settings.get("enable_file_edits", false)):
		state.settings["enable_file_edits"] = true
		_log_info("Plan mode set to Auto-run: enabled file edits for immediate execution.")
	state.save_settings()
	_on_chat_mode_bar_changed(_chat_mode_option.selected if _chat_mode_option else 0)


func _on_chat_mode_bar_changed(_idx: int = 0) -> void:
	if _cmd_input == null or _chat_mode_option == null:
		return
	match _chat_mode_option.selected:
		0:
			if _chat_plan_requires_approval():
				_cmd_input.placeholder_text = "Goal for Full agent (plan only, then asks your approval)…"
			else:
				_cmd_input.placeholder_text = "Goal for Full agent (plan → validate → execute automatically)…"
		1:
			_cmd_input.placeholder_text = "Describe what to plan (no edits yet)…"
		2:
			_cmd_input.placeholder_text = "Optional note for execute (uses last plan)…"
		3, 4:
			_cmd_input.placeholder_text = "Press Enter — Scene / Node ignore this text"
		5, 6, 7:
			_cmd_input.placeholder_text = "Press Enter to run this mode…"
		8:
			_cmd_input.placeholder_text = "Optional question about the visual map…"
		9:
			_cmd_input.placeholder_text = "Press Enter for command help…"
		_:
			_cmd_input.placeholder_text = "Type a message…"


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

func _start_health_timer() -> void:
	if _health_timer:
		return
	_health_timer = Timer.new()
	_health_timer.wait_time = HEALTH_INTERVAL_OFFLINE
	_health_timer.autostart = true
	_health_timer.timeout.connect(trigger_health_check)
	add_child(_health_timer)
	_update_health_timer_interval()
	call_deferred("trigger_health_check")


func _update_health_timer_interval() -> void:
	if not _health_timer or state == null:
		return
	_health_timer.wait_time = (
		HEALTH_INTERVAL_ONLINE if state.backend_online else HEALTH_INTERVAL_OFFLINE
	)


func trigger_health_check() -> void:
	if state and state.has_method("sync_backend_api_key_file"):
		state.sync_backend_api_key_file()
	if agent_client:
		agent_client.check_health()


## Poll /health until the server responds (handles cold start right after OS.create_process).
func _await_backend_http_ready(max_wait_sec: float = 4.0) -> bool:
	if state == null:
		return false
	if state.backend_online:
		return true
	var deadline_ms: int = Time.get_ticks_msec() + int(max_wait_sec * 1000.0)
	var next_health_ms: int = Time.get_ticks_msec() + 300
	trigger_health_check()
	await get_tree().create_timer(0.2).timeout
	while Time.get_ticks_msec() < deadline_ms:
		if state.backend_online:
			return true
		var now: int = Time.get_ticks_msec()
		if now >= next_health_ms:
			trigger_health_check()
			next_health_ms = now + 900
		await get_tree().process_frame
	return state.backend_online


func _sync_backend_control_buttons() -> void:
	if _stop_btn == null:
		return
	var plugin: EditorPlugin = state.editor_plugin if state else null
	var tracked: bool = false
	if plugin != null and plugin.has_method("is_backend_process_tracked"):
		tracked = plugin.is_backend_process_tracked()
	_stop_btn.visible = tracked


# ---------------------------------------------------------------------------
# Command routing
# ---------------------------------------------------------------------------

func _on_command_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	var body: String = _resolve_chat_request_body(trimmed)
	if body == "" and trimmed.is_empty():
		return
	_cmd_input.text = ""
	var sent_images_log: Array = _snapshot_chat_images_for_log(_chat_attached_images)

	if trimmed.begins_with("/"):
		_log_user_input(trimmed, sent_images_log)
		var parsed: Dictionary = _parse_slash_command(trimmed)
		_route_command(str(parsed.get("cmd", "")), str(parsed.get("args", "")), true)
	else:
		var log_line: String = trimmed if trimmed != "" else "[attached image(s)]"
		_log_user_input(log_line, sent_images_log)
		_submit_chat_mode(body)
	# One-shot attachments (snapshot lives on queued tasks).
	_chat_attached_images = []
	_refresh_attachment_chrome()


func _resolve_chat_request_body(trimmed: String) -> String:
	var t := trimmed.strip_edges()
	if t != "":
		return t
	if not _chat_attached_images.is_empty():
		return (
			"(Attached image(s) with no text — infer intent from the images and project context.)"
		)
	return ""


func _on_attach_image_pressed() -> void:
	if _image_file_dialog:
		_image_file_dialog.popup_centered_ratio(0.8)


func _on_clear_attachments_pressed() -> void:
	_chat_attached_images = []
	_refresh_attachment_chrome()


func _on_chat_images_selected(paths: PackedStringArray) -> void:
	_chat_attached_images = []
	for p in paths:
		if _chat_attached_images.size() >= 4:
			break
		_append_chat_image_from_path(str(p))
	_refresh_attachment_chrome()


func _on_chat_image_files_dropped(paths: PackedStringArray) -> void:
	var filtered := PackedStringArray()
	for p in paths:
		var ext := String(p).get_extension().to_lower()
		if ext in ["png", "jpg", "jpeg", "webp", "bmp"]:
			filtered.append(p)
	if filtered.is_empty():
		return
	for p in filtered:
		if _chat_attached_images.size() >= 4:
			break
		_append_chat_image_from_path(str(p))
	_refresh_attachment_chrome()


func _on_chat_clipboard_image_pasted(image: Image) -> void:
	if image == null or image.get_width() < 1 or image.get_height() < 1:
		return
	if _chat_attached_images.size() >= 4:
		_log_warn("At most 4 chat images — remove one to add another.")
		return
	var buf: PackedByteArray = image.save_png_to_buffer()
	if buf.is_empty():
		return
	var prev := ImageTexture.create_from_image(image)
	var nm := "clipboard-%d.png" % Time.get_ticks_msec()
	_append_chat_image_record(nm, "image/png", Marshalls.raw_to_base64(buf), prev)
	_refresh_attachment_chrome()


func _mime_for_image_extension(ext: String) -> String:
	match ext.to_lower():
		"jpg", "jpeg":
			return "image/jpeg"
		"webp":
			return "image/webp"
		"bmp":
			return "image/bmp"
		_:
			return "image/png"


func _append_chat_image_from_path(path: String) -> void:
	var raw: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if raw.is_empty():
		return
	var ext: String = path.get_extension().to_lower()
	var mime: String = _mime_for_image_extension(ext)
	var preview: Texture2D = null
	var img_try := Image.new()
	if img_try.load(path) == OK:
		preview = ImageTexture.create_from_image(img_try)
	_append_chat_image_record(path.get_file(), mime, Marshalls.raw_to_base64(raw), preview)


func _append_chat_image_record(display_name: String, mime: String, b64: String, preview: Texture2D) -> void:
	if b64.strip_edges() == "":
		return
	var rec := {"name": display_name, "mime_type": mime, "base64": b64}
	if preview != null:
		rec["preview"] = preview
	_chat_attached_images.append(rec)


func _snapshot_chat_images_for_log(images: Array) -> Array:
	var out: Array = []
	for it in images:
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		out.append({
			"name": str(d.get("name", "image")),
			"mime_type": str(d.get("mime_type", "image/png")),
			"base64": str(d.get("base64", "")),
		})
	return out


func _refresh_attachment_chrome() -> void:
	_refresh_attachment_label()
	_rebuild_attachment_strip()


func _refresh_attachment_label() -> void:
	if _attachments_label == null or _clear_attachments_btn == null:
		return
	if _chat_attached_images.is_empty():
		_attachments_label.text = "No images attached (drop, paste Ctrl+V, or 📎)"
		_clear_attachments_btn.disabled = true
		return
	var names: Array[String] = []
	for item in _chat_attached_images:
		names.append(str(item.get("name", "image")))
	_attachments_label.text = "Attached: " + ", ".join(names)
	_clear_attachments_btn.disabled = false


func _rebuild_attachment_strip() -> void:
	if _chat_attachment_strip == null:
		return
	for c in _chat_attachment_strip.get_children():
		c.queue_free()
	if _chat_attached_images.is_empty():
		_chat_attachment_strip.visible = false
		return
	_chat_attachment_strip.visible = true
	for i in range(_chat_attached_images.size()):
		var item: Dictionary = _chat_attached_images[i]
		var cell := PanelContainer.new()
		cell.custom_minimum_size = Vector2(88, 88)
		var inner := MarginContainer.new()
		inner.add_theme_constant_override("margin_left", 4)
		inner.add_theme_constant_override("margin_top", 4)
		inner.add_theme_constant_override("margin_right", 4)
		inner.add_theme_constant_override("margin_bottom", 4)
		var layer := Control.new()
		layer.custom_minimum_size = Vector2(80, 80)
		layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		layer.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var tr := TextureRect.new()
		tr.custom_minimum_size = Vector2(80, 80)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var pv: Variant = item.get("preview", null)
		if pv is Texture2D:
			tr.texture = pv as Texture2D
		else:
			tr.texture = null
			tr.modulate = Color(0.35, 0.35, 0.38)
		layer.add_child(tr)
		var xb := Button.new()
		xb.text = "✕"
		xb.flat = false
		xb.tooltip_text = "Remove this image"
		xb.custom_minimum_size = Vector2(30, 30)
		xb.add_theme_font_size_override("font_size", 16)
		xb.position = Vector2(48, 2)
		xb.pressed.connect(_remove_chat_attachment_at.bind(i))
		layer.add_child(xb)
		inner.add_child(layer)
		cell.add_child(inner)
		_chat_attachment_strip.add_child(cell)


func _remove_chat_attachment_at(idx: int) -> void:
	if idx < 0 or idx >= _chat_attached_images.size():
		return
	_chat_attached_images.remove_at(idx)
	_refresh_attachment_chrome()


func _chat_sessions_dir() -> String:
	var root: String = ""
	if state != null:
		root = str(state.project_root).strip_edges()
	if root == "":
		root = ProjectSettings.globalize_path("res://")
	return root.path_join(".godot_forge")


func _chat_sessions_file() -> String:
	return _chat_sessions_dir().path_join("chat_sessions.json")


func _history_root_dir() -> String:
	return _chat_sessions_dir().path_join("history")


func _history_chat_dir() -> String:
	return _history_root_dir().path_join("chat")


func _history_plan_dir() -> String:
	return _history_root_dir().path_join("plans")


func _history_task_dir() -> String:
	return _history_root_dir().path_join("tasks")


func _safe_history_slug(raw: String, max_len: int = 48) -> String:
	var t: String = raw.strip_edges().to_lower()
	if t == "":
		return "untitled"
	var out := ""
	for i in range(t.length()):
		var ch: String = t.substr(i, 1)
		var keep := (
			(ch >= "a" and ch <= "z")
			or (ch >= "0" and ch <= "9")
			or ch == "-" or ch == "_"
		)
		if keep:
			out += ch
		elif ch == " ":
			out += "-"
	if out == "":
		out = "untitled"
	if out.length() > max_len:
		out = out.substr(0, max_len).rstrip("-_")
	return out


func _ensure_history_dirs() -> void:
	for p in [_history_root_dir(), _history_chat_dir(), _history_plan_dir(), _history_task_dir()]:
		DirAccess.make_dir_recursive_absolute(p)


func _write_text_file(path: String, content: String) -> bool:
	var dir_path: String = path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[GoDotter] Could not write history file: " + path)
		return false
	f.store_string(content)
	f.close()
	return true


func _unix_to_utc_text(ts: int) -> String:
	if ts <= 0:
		return "unknown"
	return Time.get_datetime_string_from_unix_time(ts, true)


func _history_markdown_header(title: String, meta: Dictionary) -> String:
	var lines: Array[String] = ["# " + title, ""]
	for k in meta.keys():
		lines.append("- **" + str(k) + "**: " + str(meta[k]))
	lines.append("")
	return "\n".join(lines)


func _history_export_chat_sessions_markdown() -> void:
	if not _chat_sessions_loaded:
		return
	_ensure_history_dirs()
	var index_lines: Array[String] = [
		"# Chat Sessions History",
		"",
		"- Generated by GoDotter session exporter.",
		"",
	]
	for session in _chat_sessions:
		if not (session is Dictionary):
			continue
		var s: Dictionary = session
		var sid: String = str(s.get("id", "")).strip_edges()
		var title: String = str(s.get("title", "New chat")).strip_edges()
		if sid == "":
			continue
		if title == "":
			title = "New chat"
		var created_at: int = int(s.get("created_at", 0))
		var updated_at: int = int(s.get("updated_at", 0))
		var slug: String = _safe_history_slug(title, 40)
		var fp: String = _history_chat_dir().path_join("%s_%s.md" % [sid, slug])
		var body := _history_markdown_header(
			title,
			{
				"session_id": sid,
				"created_utc": _unix_to_utc_text(created_at),
				"updated_utc": _unix_to_utc_text(updated_at),
			},
		)
		body += "## Transcript\n\n```text\n" + str(s.get("log_text", "")) + "\n```\n"
		_write_text_file(fp, body)
		index_lines.append("- [%s](chat/%s_%s.md) — updated %s" % [title, sid, slug, _unix_to_utc_text(updated_at)])
	_write_text_file(_history_root_dir().path_join("index.md"), "\n".join(index_lines) + "\n")


func _history_write_plan_snapshot(display: Dictionary) -> void:
	if state == null:
		return
	_ensure_history_dirs()
	var now: int = int(Time.get_unix_time_from_system())
	var sid: String = _chat_current_session_id if _chat_current_session_id != "" else "session"
	var sum: String = str(display.get("summary", "Plan")).strip_edges()
	var slug: String = _safe_history_slug(sum, 42)
	var fp: String = _history_plan_dir().path_join("plan_%d_%s_%s.md" % [now, sid, slug])
	var title: String = sum if sum != "" else "Plan snapshot"
	var steps: Array = display.get("steps", [])
	var risks: Array = display.get("risks", [])
	var val: Array = display.get("validation_plan", [])
	var txt := _history_markdown_header(
		title,
		{
			"captured_utc": _unix_to_utc_text(now),
			"session_id": sid,
			"provider": str(state.settings.get("ai_settings", {}).get("provider", "gemini")),
			"model": str(state.settings.get("model", "")),
		},
	)
	txt += "## Summary\n\n%s\n\n" % sum
	if not steps.is_empty():
		txt += "## Steps\n\n"
		for i in range(steps.size()):
			var st: Dictionary = steps[i] if steps[i] is Dictionary else {}
			txt += "%d. %s\n" % [i + 1, str(st.get("description", ""))]
		txt += "\n"
	if not risks.is_empty():
		txt += "## Risks\n\n"
		for r in risks:
			txt += "- %s\n" % str(r)
		txt += "\n"
	if not val.is_empty():
		txt += "## Validation Plan\n\n"
		for v in val:
			txt += "- %s\n" % str(v)
		txt += "\n"
	_write_text_file(fp, txt)


func _queued_command_for_task(task_id: String) -> Dictionary:
	if task_id == "":
		return {}
	if not _active_command_task.is_empty() and str(_active_command_task.get("task_id", "")) == task_id:
		return _active_command_task
	for q in _pending_command_tasks:
		if q is Dictionary and str((q as Dictionary).get("task_id", "")) == task_id:
			return q as Dictionary
	return {}


func _history_write_task_snapshot(task_id: String, phase: String, note: String = "") -> void:
	if task_id == "" or task_queue == null:
		return
	_ensure_history_dirs()
	var task: Dictionary = task_queue.get_task(task_id)
	if task.is_empty():
		return
	var cmd: Dictionary = _queued_command_for_task(task_id)
	var now: int = int(Time.get_unix_time_from_system())
	var title: String = str(task.get("title", task_id))
	var fp: String = _history_task_dir().path_join("%s.md" % task_id)
	var txt := _history_markdown_header(
		title,
		{
			"task_id": task_id,
			"status": str(task.get("status", "")),
			"phase": phase,
			"updated_utc": _unix_to_utc_text(now),
		},
	)
	txt += "## Request\n\n%s\n\n" % str(task.get("user_request", ""))
	if not cmd.is_empty():
		txt += "## Command\n\n- **cmd**: %s\n- **args**: %s\n\n" % [
			str(cmd.get("command", "")),
			str(cmd.get("args", "")),
		]
	if note.strip_edges() != "":
		txt += "## Notes\n\n- %s\n\n" % note.strip_edges()
	var plan: Variant = task.get("plan", {})
	if typeof(plan) == TYPE_DICTIONARY and not (plan as Dictionary).is_empty():
		txt += "## Plan (raw)\n\n```json\n%s\n```\n\n" % JSON.stringify(plan, "  ")
	var report: Variant = task.get("final_report", {})
	if typeof(report) == TYPE_DICTIONARY and not (report as Dictionary).is_empty():
		txt += "## Final Report (raw)\n\n```json\n%s\n```\n\n" % JSON.stringify(report, "  ")
	_write_text_file(fp, txt)

func _new_chat_session_dict(title: String = "New chat", log_text: String = "") -> Dictionary:
	var now: int = int(Time.get_unix_time_from_system())
	var session_id := "chat_%d_%d" % [now, Time.get_ticks_usec()]
	var t := title.strip_edges()
	if t == "":
		t = "New chat"
	return {
		"id": session_id,
		"title": t,
		"created_at": now,
		"updated_at": now,
		"log_text": log_text,
	}


func _sanitize_chat_session(raw: Dictionary) -> Dictionary:
	var now: int = int(Time.get_unix_time_from_system())
	var out: Dictionary = {}
	out["id"] = str(raw.get("id", "")).strip_edges()
	if str(out["id"]) == "":
		out["id"] = "chat_%d_%d" % [now, Time.get_ticks_usec()]
	out["title"] = str(raw.get("title", "New chat")).strip_edges()
	if str(out["title"]) == "":
		out["title"] = "New chat"
	var created_val: Variant = raw.get("created_at", now)
	var updated_val: Variant = raw.get("updated_at", now)
	out["created_at"] = int(created_val) if str(created_val).is_valid_int() else now
	out["updated_at"] = int(updated_val) if str(updated_val).is_valid_int() else int(out["created_at"])
	out["log_text"] = str(raw.get("log_text", ""))
	return out


func _sort_chat_sessions_recent() -> void:
	_chat_sessions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("updated_at", 0)) > int(b.get("updated_at", 0))
	)


func _find_chat_session_idx(session_id: String) -> int:
	for i in range(_chat_sessions.size()):
		var s: Dictionary = _chat_sessions[i]
		if str(s.get("id", "")) == session_id:
			return i
	return -1


func _current_chat_session() -> Dictionary:
	var idx: int = _find_chat_session_idx(_chat_current_session_id)
	if idx < 0:
		return {}
	return _chat_sessions[idx]


func _load_chat_sessions() -> void:
	if _chat_sessions_loaded:
		return
	_chat_sessions_loaded = true
	_chat_sessions = []
	var path: String = _chat_sessions_file()
	if FileAccess.file_exists(path):
		var content: String = FileAccess.get_file_as_string(path)
		var parsed: Variant = JSON.parse_string(content)
		if parsed is Array:
			for item in parsed:
				if item is Dictionary:
					_chat_sessions.append(_sanitize_chat_session(item as Dictionary))
	_sort_chat_sessions_recent()
	if _chat_sessions.is_empty():
		_chat_sessions.append(_new_chat_session_dict("New chat", _welcome_message()))
	if _chat_current_session_id == "" or _find_chat_session_idx(_chat_current_session_id) < 0:
		_chat_current_session_id = str((_chat_sessions[0] as Dictionary).get("id", ""))
	_refresh_chat_session_option()
	_apply_chat_session_by_id(_chat_current_session_id, false)
	_save_chat_sessions()
	_history_export_chat_sessions_markdown()


func _save_chat_sessions() -> void:
	if not _chat_sessions_loaded:
		return
	var dir_path: String = _chat_sessions_dir()
	var err := DirAccess.make_dir_recursive_absolute(dir_path)
	if err != OK:
		push_warning("[GoDotter] Could not create chat session dir: %s (err=%d)" % [dir_path, err])
		return
	var path: String = _chat_sessions_file()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[GoDotter] Could not write chat sessions file: " + path)
		return
	f.store_string(JSON.stringify(_chat_sessions))
	f.close()
	_history_export_chat_sessions_markdown()


func _refresh_chat_session_option() -> void:
	if _chat_session_option == null:
		return
	_chat_session_option.clear()
	var selected_idx := 0
	for i in range(_chat_sessions.size()):
		var session: Dictionary = _chat_sessions[i]
		var title: String = str(session.get("title", "New chat")).strip_edges()
		if title == "":
			title = "New chat"
		_chat_session_option.add_item(title)
		_chat_session_option.set_item_metadata(i, str(session.get("id", "")))
		if str(session.get("id", "")) == _chat_current_session_id:
			selected_idx = i
	if _chat_sessions.is_empty():
		_chat_new_session_btn.disabled = false
		_chat_rename_session_btn.disabled = true
		_chat_delete_session_btn.disabled = true
		return
	_chat_session_option.select(selected_idx)
	_chat_new_session_btn.disabled = false
	_chat_rename_session_btn.disabled = false
	_chat_delete_session_btn.disabled = _chat_sessions.size() <= 1


func _capture_current_chat_session_log() -> void:
	if not _chat_sessions_loaded:
		return
	if _chat_log == null or _chat_current_session_id == "":
		return
	var idx: int = _find_chat_session_idx(_chat_current_session_id)
	if idx < 0:
		return
	var session: Dictionary = _chat_sessions[idx]
	session["log_text"] = _chat_log.text
	session["updated_at"] = int(Time.get_unix_time_from_system())
	_chat_sessions[idx] = session


func _extract_first_user_line_title(text: String) -> String:
	var t := text.strip_edges()
	if t == "":
		return ""
	t = t.replace("\n", " ").replace("\t", " ")
	var compact := " ".join(t.split(" ", false)).strip_edges()
	if compact.length() > 52:
		compact = compact.substr(0, 52).strip_edges() + "…"
	return compact


func _sync_chat_session_log_after_append(user_line: String = "") -> void:
	if not _chat_sessions_loaded:
		return
	_capture_current_chat_session_log()
	var idx: int = _find_chat_session_idx(_chat_current_session_id)
	if idx >= 0 and user_line.strip_edges() != "":
		var session: Dictionary = _chat_sessions[idx]
		var current_title: String = str(session.get("title", ""))
		if current_title == "" or current_title == "New chat":
			var candidate: String = _extract_first_user_line_title(user_line)
			if candidate != "":
				session["title"] = candidate
				_chat_sessions[idx] = session
	_sort_chat_sessions_recent()
	_refresh_chat_session_option()
	_save_chat_sessions()


func _apply_chat_session_by_id(session_id: String, capture_before_switch: bool = true) -> void:
	if session_id == "":
		return
	if capture_before_switch:
		_capture_current_chat_session_log()
	var idx: int = _find_chat_session_idx(session_id)
	if idx < 0:
		return
	_chat_current_session_id = session_id
	var session: Dictionary = _chat_sessions[idx]
	if _chat_log:
		_chat_log.text = str(session.get("log_text", _welcome_message()))
		_reset_chat_reveal_state()
	_refresh_chat_session_option()


func _on_chat_session_selected(index: int) -> void:
	if _chat_session_option == null:
		return
	if index < 0 or index >= _chat_session_option.item_count:
		return
	var session_id := str(_chat_session_option.get_item_metadata(index))
	if session_id == "" or session_id == _chat_current_session_id:
		return
	_apply_chat_session_by_id(session_id, true)
	_save_chat_sessions()


func _on_chat_new_session_pressed() -> void:
	_capture_current_chat_session_log()
	var created := _new_chat_session_dict("New chat", _welcome_message())
	_chat_sessions.push_front(created)
	while _chat_sessions.size() > CHAT_SESSIONS_MAX:
		_chat_sessions.remove_at(_chat_sessions.size() - 1)
	_chat_current_session_id = str(created.get("id", ""))
	_refresh_chat_session_option()
	_apply_chat_session_by_id(_chat_current_session_id, false)
	_save_chat_sessions()
	_log_info("Started a new chat session.")


func _on_chat_rename_session_pressed() -> void:
	if _chat_session_rename_dialog == null or _chat_session_rename_edit == null:
		return
	var session: Dictionary = _current_chat_session()
	var current_title := str(session.get("title", "New chat"))
	_chat_session_rename_edit.text = current_title
	_chat_session_rename_dialog.popup_centered(Vector2(360, 120))
	_chat_session_rename_edit.grab_focus()
	_chat_session_rename_edit.select_all()


func _on_chat_rename_session_confirmed() -> void:
	var idx: int = _find_chat_session_idx(_chat_current_session_id)
	if idx < 0:
		return
	var name := ""
	if _chat_session_rename_edit != null:
		name = _chat_session_rename_edit.text.strip_edges()
	if name == "":
		name = "New chat"
	var session: Dictionary = _chat_sessions[idx]
	session["title"] = name
	session["updated_at"] = int(Time.get_unix_time_from_system())
	_chat_sessions[idx] = session
	_sort_chat_sessions_recent()
	_refresh_chat_session_option()
	_save_chat_sessions()
	_log_success("Session renamed.")


func _on_chat_delete_session_pressed() -> void:
	var idx: int = _find_chat_session_idx(_chat_current_session_id)
	if idx < 0:
		return
	if _chat_sessions.size() <= 1:
		_chat_sessions[0] = _new_chat_session_dict("New chat", _welcome_message())
		_chat_current_session_id = str((_chat_sessions[0] as Dictionary).get("id", ""))
		_apply_chat_session_by_id(_chat_current_session_id, false)
		_save_chat_sessions()
		_log_warn("Cannot delete the last session. Reset it instead.")
		return
	_chat_sessions.remove_at(idx)
	_sort_chat_sessions_recent()
	_chat_current_session_id = str((_chat_sessions[0] as Dictionary).get("id", ""))
	_apply_chat_session_by_id(_chat_current_session_id, false)
	_save_chat_sessions()
	_log_info("Session deleted.")


func _parse_slash_command(trimmed: String) -> Dictionary:
	var t := trimmed.strip_edges()
	if not t.begins_with("/"):
		return {"cmd": "", "args": ""}
	var sb: String = t.substr(1, t.length() - 1)
	var k := 0
	var cmd_chars := ""
	while k < sb.length():
		var c: String = sb.substr(k, 1)
		if c == " " or c == "\t":
			k += 1
			break
		if cmd_chars != "" and (c == "," or c == "." or c == ";" or c == ":" or c == "!" or c == "?"):
			k += 1
			break
		cmd_chars += c
		k += 1
	var cmd: String = ("/" + cmd_chars).to_lower()
	var args: String = sb.substr(k, sb.length() - k).strip_edges()
	return {"cmd": cmd, "args": args}


func _submit_chat_mode(body: String) -> void:
	if _chat_mode_option == null:
		return
	var idx: int = _chat_mode_option.selected
	match idx:
		0:
			_queue_command("/agent", body)
		1:
			_queue_command("/plan", body)
		2:
			_queue_command("/do", body)
		3:
			_cmd_scene()
		4:
			_cmd_node()
		5:
			_queue_command("/audit", "")
		6:
			_queue_command("/memory", "")
		7:
			_queue_command("/fixlogs", "")
		8:
			_queue_command("/neon", body)
		9:
			_log_info(_help_text())
		_:
			_queue_command("/plan", body)


func _route_command(cmd: String, args: String, already_echoed_user_line: bool = false) -> void:
	if not already_echoed_user_line:
		var display: String = cmd
		if args.strip_edges() != "":
			display += " " + args
		_log_user_input(display)
	if not _command_supported(cmd):
		return
	match cmd:
		"/agent":       _queue_command(cmd, args)
		"/plan":        _queue_command(cmd, args)
		"/do", "/fix":  _queue_command(cmd, args)
		"/queue":       _on_queue_status_requested()
		"/scene":       _cmd_scene()
		"/node":        _cmd_node()
		"/audit":       _queue_command(cmd, args)
		"/memory":      _queue_command(cmd, args)
		"/fixlogs":     _queue_command(cmd, args)
		"/visualmap", "/visualize", "/neon":  _queue_command(cmd, args)
		"/visual3d":    _on_review_3d_pressed()
		"/diff":
			_tabs.current_tab = TAB_DIFF
			_log_info("Switched to Diff tab.")
		"/settings":
			_tabs.current_tab = TAB_SETTINGS
		"/clear":
			if _chat_log:
				_chat_log.text = ""
				_reset_chat_reveal_state()
			_sync_chat_session_log_after_append()
		"/help":
			_log_info(_help_text())
		_:
			_log_info(
				"Unknown command [code]" + _esc(cmd) + "[/code]. Choose a [b]Mode[/b] above and type plain text, or try:\n"
				+ "  [b]/agent[/b] <request> — Full agent session (plan→validate→execute)\n"
				+ "  [b]/plan[/b] <request>  — create a plan only\n"
				+ "  [b]/do[/b] <request>    — plan + execute\n"
				+ "  [b]/neon[/b] <query>    — AI visual map\n"
				+ "  [b]/scene[/b] /node /audit /memory /fixlogs /diff /settings /clear /help"
			)


func _required_route_for_command(cmd: String) -> String:
	match cmd:
		"/agent":
			return "/agent/run"
		"/plan":
			return "/agent/plan"
		"/do", "/fix":
			return "/agent/execute"
		"/audit":
			return "/project/index"
		"/memory":
			return "/memory"
		"/fixlogs":
			return "/agent/fix_from_logs"
		"/visualmap", "/visualize", "/neon":
			return "/agent/visual_map"
		_:
			return ""


func _command_supported(cmd: String) -> bool:
	var route: String = _required_route_for_command(cmd)
	if route == "":
		return true
	if _backend_caps.is_empty():
		return true
	var ok: bool = bool(_backend_caps.get(route, false))
	if not ok:
		_log_warn(
			"Command %s is disabled because backend route %s is not available in this server build."
			% [cmd, route]
		)
	return ok


func _ensure_route_available(route: String, command_label: String) -> bool:
	if agent_client and agent_client.has_method("supports_route"):
		if not agent_client.supports_route(route):
			_log_warn("Command %s disabled: backend route %s is unavailable." % [command_label, route])
			return false
	return true


func _queue_command(cmd: String, args: String) -> void:
	if cmd == "":
		return
	var title := "Command " + cmd
	var user_request: String = args if args.strip_edges() != "" else cmd
	var task: Dictionary = task_queue.add_task(title, user_request, 1)
	task_queue.update_task(task["id"], {"command": cmd, "args": args})
	_history_write_task_snapshot(str(task.get("id", "")), "queued", "Task added to queue.")
	_pending_command_tasks.append({
		"task_id": task["id"],
		"command": cmd,
		"args": args,
		"chat_images": _chat_attached_images.duplicate(true),
	})
	var pos: int = _pending_command_tasks.size() + (0 if _active_command_task.is_empty() else 1)
	if _active_command_task.is_empty() and _pending_command_tasks.size() == 1:
		_log_info("[Queue] Starting " + cmd + "…")
	else:
		_log_info("[Queue] Added " + cmd + " (position " + str(pos) + ").")
	_refresh_queue_status_label()
	_try_start_next_command_task()


func _try_start_next_command_task() -> void:
	call_deferred("_try_start_next_command_task_async")


func _try_start_next_command_task_async() -> void:
	if not _active_command_task.is_empty():
		return
	if _pending_command_tasks.is_empty():
		return
	_active_command_task = _pending_command_tasks.pop_front()
	_refresh_queue_status_label()
	var task_id: String = str(_active_command_task.get("task_id", ""))
	task_queue.update_status(task_id, "gathering_context")
	_history_write_task_snapshot(task_id, "gathering_context", "Task became active.")
	_start_queue_watchdog()
	var cmd: String = str(_active_command_task.get("command", ""))
	var args: String = str(_active_command_task.get("args", ""))
	var started: bool = await _execute_queued_command(cmd, args)
	if not started:
		_finish_active_command_task(false, "Could not start " + cmd + ". Check preconditions.")


func _execute_queued_command(cmd: String, args: String) -> bool:
	match cmd:
		"/agent":
			return await _cmd_agent_run(args)
		"/plan":
			return await _cmd_plan(args)
		"/do", "/fix":
			return await _cmd_execute(args)
		"/audit":
			return await _cmd_audit()
		"/memory":
			return await _cmd_memory()
		"/fixlogs":
			return await _cmd_fixlogs(args)
		"/visualmap", "/visualize", "/neon":
			return _cmd_visualmap(args)
		_:
			return false


func _start_queue_watchdog() -> void:
	if _queue_watchdog == null:
		_queue_watchdog = Timer.new()
		_queue_watchdog.one_shot = true
		_queue_watchdog.wait_time = QUEUE_WATCHDOG_SEC
		_queue_watchdog.timeout.connect(_on_queue_watchdog_timeout)
		add_child(_queue_watchdog)
	_queue_watchdog.start()


func _stop_queue_watchdog() -> void:
	if _queue_watchdog:
		_queue_watchdog.stop()


func _on_queue_watchdog_timeout() -> void:
	if _active_command_task.is_empty():
		return
	_finish_active_command_task(false, "Task timed out. Moving to next queued item.")


func _finish_active_command_task(ok: bool, message: String = "") -> void:
	if _active_command_task.is_empty():
		return
	_stop_queue_watchdog()
	var task_id: String = str(_active_command_task.get("task_id", ""))
	task_queue.update_status(task_id, "complete" if ok else "failed")
	var cmd: String = str(_active_command_task.get("command", ""))
	if message != "":
		if ok:
			_log_success("[Queue] " + cmd + " done — " + message)
		else:
			_log_warn("[Queue] " + cmd + " failed — " + message)
	else:
		if ok:
			_log_success("[Queue] " + cmd + " done.")
		else:
			_log_warn("[Queue] " + cmd + " failed.")
	_history_write_task_snapshot(task_id, "complete" if ok else "failed", message)
	_active_command_task = {}
	_refresh_queue_status_label()
	call_deferred("_try_start_next_command_task")


func _active_command_expected_endpoint() -> String:
	if _active_command_task.is_empty():
		return ""
	return _required_route_for_command(str(_active_command_task.get("command", "")))


func _pending_count() -> int:
	return _pending_command_tasks.size() + (0 if _active_command_task.is_empty() else 1)


func _refresh_queue_status_label() -> void:
	if _queue_status_label == null:
		return
	var waiting: int = _pending_command_tasks.size()
	if _active_command_task.is_empty():
		if waiting <= 0:
			_queue_status_label.text = "Queue: idle"
			_queue_status_label.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
		else:
			_queue_status_label.text = "Queue: %d waiting" % waiting
			_queue_status_label.add_theme_color_override("font_color", Color(0.85, 0.7, 0.3))
		return
	var active_cmd: String = str(_active_command_task.get("command", "task"))
	_queue_status_label.text = "Queue: active %s, waiting %d" % [active_cmd, waiting]
	_queue_status_label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.95))


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

func _cmd_plan(request: String) -> bool:
	if state:
		state.sync_backend_api_key_file()
	if request.is_empty() and _active_queued_chat_images().is_empty():
		_log_info("Usage: type your goal in the box, or [b]/plan[/b] <your request>")
		return false
	if not await _await_backend_http_ready():
		_log_error("Backend offline — start it first (▶ button or Settings).")
		return false
	if not _ensure_route_available("/agent/plan", "/plan"):
		return false
	_log_info("Planning: [i]" + request + "[/i]")
	_set_thinking(true, "Architect")
	var context: Dictionary = _build_ai_context_bundle(_active_queued_chat_images())
	agent_client.request_plan(request, context)
	return true


func _cmd_execute(request: String) -> bool:
	if state:
		state.sync_backend_api_key_file()
	if not await _await_backend_http_ready():
		_log_error("Backend offline.")
		return false
	if not _ensure_route_available("/agent/execute", "/do"):
		return false
	if state.last_plan.is_empty() and request.is_empty() and _active_queued_chat_images().is_empty():
		_log_error("No plan and no request. Use [b]/plan[/b] first, or provide a request.")
		return false
	var req: String = request if request != "" else str(state.last_plan.get("summary", ""))
	_log_info("Executing: [i]" + req + "[/i]")
	_set_thinking(true, "Code")
	var context: Dictionary = _build_ai_context_bundle(_active_queued_chat_images())
	agent_client.request_execute(req, context, state.last_plan)
	return true


func _cmd_agent_run(request: String) -> bool:
	if state:
		state.sync_backend_api_key_file()
	if request.is_empty() and _active_queued_chat_images().is_empty():
		_log_info("Usage: describe the change — Full agent runs plan, validators, then execute if file edits are enabled in Settings.")
		return false
	if not await _await_backend_http_ready():
		_log_error("Backend offline — start it first (▶ or Settings).")
		return false
	if not _ensure_route_available("/agent/run", "/agent"):
		return false
	if not bool(state.settings.get("enable_file_edits", false)):
		_log_warn(
			"Full agent will [b]plan + validate only[/b] until you enable [b]Allow AI to write files[/b] in Settings."
		)
	_log_info("[b]Full agent[/b] started. (may take a few minutes)")
	_set_thinking(true, "Agent")
	var context: Dictionary = _build_ai_context_bundle(_active_queued_chat_images())
	var auto_execute: bool = not _chat_plan_requires_approval()
	if not auto_execute:
		_log_info("Plan mode: [b]Require approval[/b] — this run will stop after planning.")
	agent_client.request_agent_run(request, context, auto_execute)
	return true


func _on_agent_run_response(data: Dictionary) -> void:
	_set_thinking(false)
	if data.is_empty():
		return
	var phases: Array = data.get("phases", [])
	var execute_phase_ok: bool = false
	for ph in phases:
		if ph is Dictionary:
			var nm: String = str(ph.get("phase", "?"))
			var ok: bool = bool(ph.get("ok", false))
			var detail := ""
			if ph.has("errors"):
				detail = str(ph.get("errors", []))
			elif ph.has("reason"):
				detail = str(ph.get("reason", ""))
			elif ph.has("files_written"):
				detail = str(ph.get("files_written", []))
			var phase_ms: int = int(ph.get("ms", -1))
			if ok:
				_log_success("Phase [b]" + nm + "[/b] ✓" + ((" — " + detail) if detail != "" else ""))
			else:
				_log_warn("Phase [b]" + nm + "[/b]: " + (detail if detail != "" else "check response"))
			_push_thinking_trace(
				"Phase " + nm + ": " + ("ok" if ok else "needs attention"),
				("success" if ok else "warning"),
				phase_ms
			)
			if nm == "execute" and ok:
				execute_phase_ok = true
			if nm == "validate_plan" and ok:
				_rebuild_plan_task_checkboxes(1)
			elif nm == "execute" and ok:
				_rebuild_plan_task_checkboxes(_plan_steps_cache.size())
	if data.has("plan") and data.get("plan") != null:
		var wrap: Dictionary = {
			"ok": data.get("ok", false),
			"plan": data["plan"],
			"error": _clean_error_text(data.get("error", null)),
			"__agent_run_execute_done": execute_phase_ok,
		}
		state.plan_received.emit(wrap)
	var run_err: String = _clean_error_text(data.get("error", null))
	if not bool(data.get("ok", false)) and run_err != "":
		_log_error(run_err)


func _cmd_scene() -> void:
	if not editor_bridge:
		return
	var s: Dictionary = editor_bridge.get_current_scene_root_summary()
	if s.is_empty():
		_log_info("No scene open.")
		return
	_log_info(
		"[b]Scene:[/b] " + s.get("scene_path", "(unsaved)") + "\n"
		+ "Root: [b]" + s.get("root_node_name", "") + "[/b] (" + s.get("root_node_class", "") + ")\n"
		+ "Children: " + str(s.get("child_count", 0))
	)
	_tabs.current_tab = TAB_INSPECT
	_update_inspect_tab()


func _cmd_node() -> void:
	if not editor_bridge:
		return
	var s: Dictionary = editor_bridge.get_selected_node_deep_summary()
	if s.has("error"):
		_log_info(s.get("error", ""))
		return
	_log_info(_format_node_bbcode(s))
	_tabs.current_tab = TAB_NODE


func _cmd_audit() -> bool:
	if state:
		state.sync_backend_api_key_file()
	if not await _await_backend_http_ready():
		_log_error("Backend offline.")
		return false
	if not _ensure_route_available("/project/index", "/audit"):
		return false
	_log_info("Indexing project for audit…")
	agent_client.request_index(state.project_root)
	return true


func _cmd_memory() -> bool:
	if state:
		state.sync_backend_api_key_file()
	if not await _await_backend_http_ready():
		_log_error("Backend offline.")
		return false
	if not _ensure_route_available("/memory", "/memory"):
		return false
	_log_info("Loading project memory…")
	_tabs.current_tab = TAB_MEMORY
	_refresh_memory_tab()
	agent_client.get_memory()
	return true


func _cmd_fixlogs(run_id: String) -> bool:
	if state:
		state.sync_backend_api_key_file()
	if not await _await_backend_http_ready():
		_log_error("Backend offline.")
		return false
	if not _ensure_route_available("/agent/fix_from_logs", "/fixlogs"):
		return false
	_log_info("Aggregating logs for batch fix plan…")
	_set_thinking(true, "Debug")
	agent_client.request_fix_from_logs(
		run_id,
		log_collector.get_recent_log_for_fix() if log_collector and log_collector.has_method("get_recent_log_for_fix") else (log_collector.get_recent_log() if log_collector else "")
	)
	return true


func _cmd_visualmap(query: String) -> bool:
	if not _ensure_route_available("/agent/visual_map", "/neon"):
		return false
	if not debug_visualizer:
		_log_error("DebugVisualizer not initialized.")
		return false
	if EditorInterface.get_edited_scene_root() == null:
		_log_error("No scene open. Open a scene first.")
		return false
	debug_visualizer.set_meta("pending_query", query)
	_log_info("[color=#00ffff]Neon visualization starting…[/color]")
	_log_info("[color=#888]Colors restore automatically after capture.[/color]")
	debug_visualizer.visualize_and_capture("visualmap")
	return true


# ---------------------------------------------------------------------------
# Quick action callbacks
# ---------------------------------------------------------------------------

func _on_qa_index() -> void:
	if not await _await_backend_http_ready():
		_log_error("Backend offline.")
		return
	_log_info("Indexing project…")
	agent_client.request_index(state.project_root)


func _on_qa_visualize() -> void:
	_tabs.current_tab = 0
	_cmd_visualmap("")


func _on_qa_fixlogs() -> void:
	_cmd_fixlogs("")


func _on_visualize_scene_pressed() -> void:
	_tabs.current_tab = 0
	var q: String = _viz_query_input.text.strip_edges() if _viz_query_input else ""
	_cmd_visualmap(q)


func _on_review_3d_pressed() -> void:
	_log_info("[color=#e67e22]3D angle capture requires a running game scene. (Phase 6)[/color]")


func _on_plan_execute_pressed() -> void:
	_cancel_plan_auto_approve()
	if state.last_plan.is_empty():
		_log_error("No plan to execute.")
		return
	_tabs.current_tab = 0
	_cmd_execute("")


func _on_plan_reject_pressed() -> void:
	_cancel_plan_auto_approve()
	state.last_plan = {}
	_plan_text.text = "[color=#888]Plan rejected.[/color]"
	_plan_text.visible_characters = -1
	_plan_actions.visible = false
	_plan_steps_cache = []
	_plan_step_done = []
	_rebuild_plan_task_checkboxes()
	_log_info("Plan rejected.")


func _ensure_plan_auto_approve_timer() -> void:
	if _plan_auto_approve_timer:
		return
	_plan_auto_approve_timer = Timer.new()
	_plan_auto_approve_timer.one_shot = true
	_plan_auto_approve_timer.wait_time = float(_plan_auto_approve_sec)
	_plan_auto_approve_timer.timeout.connect(_on_plan_auto_approve_timeout)
	add_child(_plan_auto_approve_timer)


func _cancel_plan_auto_approve() -> void:
	if _plan_auto_approve_timer:
		_plan_auto_approve_timer.stop()


func _schedule_plan_auto_approve() -> void:
	_ensure_plan_auto_approve_timer()
	_plan_auto_approve_timer.wait_time = float(_plan_auto_approve_sec)
	_plan_auto_approve_timer.start()
	_log_info(
		"[color=#bdc3c7]Auto-run is enabled: this plan will auto-approve in %ds "
		+ "unless you click Reject first.[/color]" % _plan_auto_approve_sec
	)


func _on_plan_auto_approve_timeout() -> void:
	if _chat_plan_requires_approval():
		return
	if state == null or state.last_plan.is_empty():
		return
	if _plan_actions and not _plan_actions.visible:
		return
	_log_info("[color=#95a5a6]Auto-approving plan (Auto-run mode).[/color]")
	_on_plan_execute_pressed()


func _rebuild_plan_task_checkboxes(done_count: int = 0) -> void:
	if _plan_tasks_box == null:
		return
	for child in _plan_tasks_box.get_children():
		child.queue_free()
	_plan_task_checks.clear()
	if _plan_steps_cache.is_empty():
		_plan_step_done = []
		_plan_tasks_box.visible = false
		return
	_sync_plan_step_done_flags(done_count)
	var title := Label.new()
	title.text = "Mission Checklist"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(0.0, 0.92, 0.8))
	_plan_tasks_box.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Mark as you complete each step."
	subtitle.add_theme_font_size_override("font_size", 12)
	subtitle.add_theme_color_override("font_color", Color(0.52, 0.52, 0.52))
	_plan_tasks_box.add_child(subtitle)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	var done_all_btn := Button.new()
	done_all_btn.text = "Mark all done"
	done_all_btn.add_theme_font_size_override("font_size", 12)
	done_all_btn.pressed.connect(func():
		_set_all_checklist_items(true)
	)
	actions.add_child(done_all_btn)
	var reset_btn := Button.new()
	reset_btn.text = "Reset"
	reset_btn.add_theme_font_size_override("font_size", 12)
	reset_btn.pressed.connect(func():
		_set_all_checklist_items(false)
	)
	actions.add_child(reset_btn)
	_plan_tasks_box.add_child(actions)
	for i in range(_plan_steps_cache.size()):
		var step: Dictionary = _plan_steps_cache[i]
		var cb := CheckBox.new()
		cb.text = "%d. %s" % [i + 1, str(step.get("description", ""))]
		cb.add_theme_font_size_override("font_size", 14)
		cb.button_pressed = bool(_plan_step_done[i]) if i < _plan_step_done.size() else false
		cb.toggled.connect(_on_plan_task_toggled.bind(i))
		_plan_tasks_box.add_child(cb)
		_plan_task_checks.append(cb)
	_plan_tasks_box.visible = true
	_refresh_plan_progress_text()


func _on_plan_task_toggled(pressed: bool, idx: int) -> void:
	if _plan_task_checks.is_empty():
		return
	if idx >= 0 and idx < _plan_step_done.size():
		_plan_step_done[idx] = pressed
	_refresh_plan_progress_text()


func _set_all_checklist_items(done: bool) -> void:
	for i in range(_plan_step_done.size()):
		_plan_step_done[i] = done
	for i in range(_plan_task_checks.size()):
		var cb: CheckBox = _plan_task_checks[i]
		cb.set_block_signals(true)
		cb.button_pressed = done
		cb.set_block_signals(false)
	_refresh_plan_progress_text()


func _sync_plan_step_done_flags(done_count: int = 0) -> void:
	if _plan_step_done.size() != _plan_steps_cache.size():
		var next: Array = []
		for i in range(_plan_steps_cache.size()):
			var prev_done: bool = bool(_plan_step_done[i]) if i < _plan_step_done.size() else false
			next.append(prev_done)
		_plan_step_done = next
	if done_count > 0:
		for i in range(mini(done_count, _plan_step_done.size())):
			_plan_step_done[i] = true


func _refresh_plan_progress_text() -> void:
	if _plan_text == null:
		return
	var done := 0
	for i in range(_plan_step_done.size()):
		if bool(_plan_step_done[i]):
			done += 1
	var total := _plan_step_done.size()
	var pct: int = int(round(float(done) / maxf(1.0, float(total)) * 100.0))
	_plan_text.text = (
		"[color=#00ffd0][b]Progress:[/b] %d/%d (%d%%) checklist items marked.[/color]\n\n"
		% [done, total, pct]
		+ _format_plan_bbcode(_normalize_plan_payload({"plan": state.last_plan}))
	)


# ---------------------------------------------------------------------------
# Backend launch / stop (from top bar)
# ---------------------------------------------------------------------------

func _on_launch_backend_pressed() -> void:
	if state.backend_dir == "":
		_log_info("[color=#f39c12]Configure backend directory in Settings first.[/color]")
		_tabs.current_tab = TAB_SETTINGS
		return
	_flush_machine_settings_from_ui()
	state.save_machine_settings()
	_log_info("Launching backend…")
	var plugin: EditorPlugin = state.editor_plugin
	if plugin and plugin.has_method("try_launch_backend"):
		var result: Dictionary = plugin.try_launch_backend()
		if result.get("ok"):
			_log_info("[color=#2ecc71]" + result.get("message", "Backend starting") + "[/color]")
			call_deferred("trigger_health_check")
			call_deferred("_sync_backend_control_buttons")
		else:
			_log_error(result.get("error", "Launch failed"))
	else:
		_log_error("Cannot launch backend from here — open a terminal and run: python main.py")


func _on_stop_backend_pressed() -> void:
	var plugin: EditorPlugin = state.editor_plugin
	if plugin and plugin.has_method("_kill_backend"):
		plugin._kill_backend()
		_log_info("Backend stopped.")
		call_deferred("_sync_backend_control_buttons")
	else:
		_log_info("Backend was not launched by GoDotter — stop it manually.")


# ---------------------------------------------------------------------------
# Settings save
# ---------------------------------------------------------------------------

func _flush_machine_settings_from_ui() -> void:
	if _set_backend_dir:
		state.backend_dir = _set_backend_dir.text.strip_edges()
	if _set_python_path:
		state.backend_python = _set_python_path.text.strip_edges()
	if _set_autostart:
		state.autostart_backend = _set_autostart.button_pressed
	if state.has_method("set_provider_api_key"):
		if _set_api_key_gemini:
			state.set_provider_api_key("gemini", _set_api_key_gemini.text.strip_edges())
		if _set_api_key_openai:
			state.set_provider_api_key("openai", _set_api_key_openai.text.strip_edges())
		if _set_api_key_claude:
			state.set_provider_api_key("claude", _set_api_key_claude.text.strip_edges())
	elif _set_api_key_gemini:
		state.api_key = _set_api_key_gemini.text.strip_edges()


func _on_save_api_keys_only() -> void:
	var before_keys: String = _api_key_fingerprint_from_state()
	var had_running_backend: bool = state != null and int(state.backend_pid) > 0
	if _ai_openai_base_url and state:
		var ai: Dictionary = state.settings.get("ai_settings", {})
		if typeof(ai) != TYPE_DICTIONARY:
			ai = {}
		ai["openai_base_url"] = _ai_openai_base_url.text.strip_edges()
		state.settings["ai_settings"] = ai
		state.save_settings()
	_flush_machine_settings_from_ui()
	state.save_machine_settings()
	var keys_changed: bool = before_keys != _api_key_fingerprint_from_state()
	if keys_changed:
		_restart_backend_after_key_change(had_running_backend)
	_log_info("[color=#2ecc71]API keys saved.[/color]")


func _on_save_settings() -> void:
	var before_keys: String = _api_key_fingerprint_from_state()
	var had_running_backend: bool = state != null and int(state.backend_pid) > 0
	_flush_machine_settings_from_ui()
	state.save_machine_settings()

	# Project settings
	if _set_url:
		state.settings["backend_url"] = _set_url.text.strip_edges()
		state.backend_url = state.settings["backend_url"]
	state.settings["model"] = _collect_model_for_save()
	if _set_approval_mode:
		var modes := ["review", "assisted", "autopilot", "yolo"]
		state.settings["approval_mode"] = modes[_set_approval_mode.selected]
	if _set_file_edits:
		state.settings["enable_file_edits"] = _set_file_edits.button_pressed
	if _set_max_output_tokens:
		state.settings["max_output_tokens"] = clampi(int(_set_max_output_tokens.value), 1024, 131072)
	if _set_max_input_tokens:
		state.settings["max_input_tokens"] = clampi(int(_set_max_input_tokens.value), 4096, 2000000)
	_save_current_controls_into_active_preset()
	state.save_settings()
	var keys_changed: bool = before_keys != _api_key_fingerprint_from_state()
	if keys_changed:
		_restart_backend_after_key_change(had_running_backend)

	_log_info("[color=#2ecc71]Settings saved.[/color]")
	_sync_chat_model_bar_from_state()


func _restart_backend_after_key_change(backend_was_running: bool) -> void:
	if state == null:
		return
	if not backend_was_running:
		return
	var plugin: EditorPlugin = state.editor_plugin
	if plugin == null:
		return
	# Force key refresh path: stop current backend process then launch with new key files.
	if backend_was_running and plugin.has_method("_kill_backend"):
		plugin._kill_backend()
		state.backend_pid = -1
		_log_info("[color=#bdc3c7]Restarting backend to load updated API keys…[/color]")
	if plugin.has_method("try_launch_backend"):
		var result: Dictionary = plugin.try_launch_backend()
		if result.get("ok", false):
			_log_success("Backend restarted with updated API keys.")
			call_deferred("trigger_health_check")
			call_deferred("_sync_backend_control_buttons")
		else:
			_log_error("Backend restart failed: " + str(result.get("error", "Unknown error")))


func _api_key_fingerprint_from_state() -> String:
	if state == null:
		return ""
	var gemini: String = state.get_provider_api_key("gemini") if state.has_method("get_provider_api_key") else str(state.api_key)
	var openai: String = state.get_provider_api_key("openai") if state.has_method("get_provider_api_key") else ""
	var claude: String = state.get_provider_api_key("claude") if state.has_method("get_provider_api_key") else ""
	var openai_base := ""
	var ai_settings: Variant = state.settings.get("ai_settings", {})
	if typeof(ai_settings) == TYPE_DICTIONARY:
		openai_base = str((ai_settings as Dictionary).get("openai_base_url", "")).strip_edges()
	return gemini + "|" + openai + "|" + claude + "|" + openai_base


func _on_reset_setup() -> void:
	state.reset_wizard_completed()
	_setup_overlay.visible = true
	_main_content.visible = false


# ---------------------------------------------------------------------------
# Memory tab
# ---------------------------------------------------------------------------

func _refresh_memory_tab() -> void:
	if not _memory_file_list:
		return
	_memory_file_list.clear()
	if state == null:
		return
	var forge_root: String = str(state.project_root).path_join(".godot_forge")
	var md_entries: Array = []
	_collect_markdown_files_recursive(forge_root.path_join("memory"), "memory", md_entries)
	_collect_markdown_files_recursive(forge_root.path_join("history"), "history", md_entries)
	md_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("label", "")) < str(b.get("label", ""))
	)
	if md_entries.is_empty():
		if _memory_content:
			_memory_content.text = "[color=#555]No memory/history markdown yet. Run chat, plan, or tasks to generate history.[/color]"
		return
	for it in md_entries:
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		_memory_file_list.add_item(str(d.get("label", "notes.md")))
		_memory_file_list.set_item_metadata(_memory_file_list.item_count - 1, str(d.get("path", "")))


func _collect_markdown_files_recursive(root_dir: String, prefix: String, out_entries: Array) -> void:
	var dir := DirAccess.open(root_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var abs_path: String = root_dir.path_join(name)
		if dir.current_is_dir():
			_collect_markdown_files_recursive(abs_path, prefix.path_join(name), out_entries)
		elif name.ends_with(".md"):
			out_entries.append({
				"label": prefix.path_join(name),
				"path": abs_path,
			})
		name = dir.get_next()
	dir.list_dir_end()


func _on_memory_file_selected(index: int) -> void:
	var path: String = _memory_file_list.get_item_metadata(index)
	var content: String = FileAccess.get_file_as_string(path)
	if _memory_content:
		# Render markdown-ish as BBCode
		_memory_content.text = _md_to_bbcode(content)


func _md_to_bbcode(md: String) -> String:
	var out := ""
	for line in md.split("\n"):
		if line.begins_with("## "):
			out += "[b][color=#7fb3d3]" + line.substr(3) + "[/color][/b]\n"
		elif line.begins_with("# "):
			out += "[b][color=#f39c12]" + line.substr(2) + "[/color][/b]\n"
		elif line.begins_with("- ") or line.begins_with("* "):
			out += "  • " + line.substr(2) + "\n"
		elif line.begins_with("```"):
			out += "\n"
		else:
			out += line + "\n"
	return out


# ---------------------------------------------------------------------------
# Visualization callbacks
# ---------------------------------------------------------------------------

func _on_visualization_complete(screenshot_path: String, node_map: Array) -> void:
	_log_info("[color=#00ffff]Neon screenshot saved:[/color] " + screenshot_path.get_file())
	_log_info("[color=#888]%d nodes mapped.[/color]" % node_map.size())
	_run_visual_map_after_capture(screenshot_path, node_map)


func _run_visual_map_after_capture(screenshot_path: String, node_map: Array) -> void:
	if not await _await_backend_http_ready(8.0):
		_log_info("[color=#f39c12]Backend offline — screenshot saved but AI analysis skipped.[/color]")
		return

	var img_bytes := FileAccess.get_file_as_bytes(screenshot_path)
	if img_bytes.is_empty():
		_log_error("Could not read screenshot.")
		return
	var b64: String = Marshalls.raw_to_base64(img_bytes)
	var legend: Dictionary = debug_visualizer.get_color_legend()
	var query: String = debug_visualizer.get_meta("pending_query", "")

	_set_thinking(true, "Visual Map Agent")
	var root: Node = EditorInterface.get_edited_scene_root()
	var scene_path: String = root.scene_file_path if root else ""
	agent_client.request_visual_map(b64, node_map, legend, scene_path, query)


func _on_visualization_failed(reason: String) -> void:
	_set_thinking(false)
	_log_error("[Neon Viz] " + reason)


func _on_visual_map_response(data: Dictionary) -> void:
	_set_thinking(false)
	if not data.get("ok", false):
		_log_error("Visual map failed: " + str(data.get("error", "")))
		return
	var a: Dictionary = data.get("analysis", {})
	_log_success("[b]Scene Summary:[/b] " + a.get("scene_summary", ""))
	for f in a.get("spatial_findings", []):
		var sev: String = f.get("severity", "info")
		var msg: String = "  [%s] %s — %s" % [f.get("node_path", "?"), f.get("node_class", ""), f.get("finding", "")]
		match sev:
			"error":   _log_error(msg)
			"warning": _log_warn(msg)
			_:         _log_info(msg)
	for r in a.get("recommendations", []):
		_log_info("  → " + str(r))
	var qa: String = a.get("query_answer", "")
	if qa != "":
		_log_success("[b]Answer:[/b] " + qa)


func _on_execute_response(data: Dictionary) -> void:
	_set_thinking(false)
	if not data.get("ok", false):
		_push_thinking_trace("Execute failed.", "error")
		_log_error("Execute failed: " + str(data.get("error", "")))
		if not _active_command_task.is_empty():
			var tid_fail: String = str(_active_command_task.get("task_id", ""))
			if tid_fail != "":
				task_queue.update_task(tid_fail, {"final_report": data.get("final_report", {}), "error": str(data.get("error", ""))})
				_history_write_task_snapshot(tid_fail, "execute_failed", "Execute failed before file writes.")
		return
	_push_thinking_trace("Execute completed successfully.", "success")
	_rebuild_plan_task_checkboxes(_plan_steps_cache.size())
	var files: Array = data.get("files_written", [])
	_log_success("Wrote %d file(s)." % files.size())
	for f in files:
		_log_info("  • " + str(f))
	if data.has("git_checkpoint"):
		var gcs: String = str(data.get("git_checkpoint", ""))
		_log_info("Git checkpoint: " + gcs.substr(0, mini(8, gcs.length())))
	if not _active_command_task.is_empty():
		var tid_ok: String = str(_active_command_task.get("task_id", ""))
		if tid_ok != "":
			task_queue.update_task(tid_ok, {
				"files_modified": files.duplicate(),
				"final_report": data.get("final_report", {}),
			})
			_history_write_task_snapshot(tid_ok, "execute_done", "Execute wrote %d file(s)." % files.size())
			call_deferred("_refresh_memory_tab")
	# Switch to Diff tab if there are diffs
	if not data.get("diffs", []).is_empty():
		_tabs.current_tab = TAB_DIFF


# ---------------------------------------------------------------------------
# Diff callbacks
# ---------------------------------------------------------------------------

func _on_diff_approved(task_id: String) -> void:
	_log_success("Task [b]" + task_id + "[/b] approved.")


func _on_diff_file_reverted(task_id: String, path: String) -> void:
	_log_warn("Reverted: " + path)
	if state.backend_online:
		var base: String = (
			state.normalized_backend_http_base()
			if state.has_method("normalized_backend_http_base")
			else state.backend_url
		)
		agent_client._post(
			base.rstrip("/") + "/tools/revert_file",
			{"path": path, "task_id": task_id},
			func(_r, _c, _h, _b): pass
		)


# ---------------------------------------------------------------------------
# Setup wizard callbacks
# ---------------------------------------------------------------------------

func _on_setup_finished() -> void:
	_setup_overlay.visible = false
	_main_content.visible = true
	_log_info("[color=#00ffff]Setup complete! Backend: " + state.backend_url + "[/color]")
	trigger_health_check()


func _on_setup_launch_backend() -> void:
	var plugin: EditorPlugin = state.editor_plugin
	if plugin and plugin.has_method("try_launch_backend"):
		var result: Dictionary = plugin.try_launch_backend()
		if result.get("ok", false):
			_log_info("[color=#2ecc71]" + str(result.get("message", "Backend starting")) + "[/color]")
		else:
			_log_error(str(result.get("error", "Launch failed")))
		call_deferred("trigger_health_check")
		call_deferred("_sync_backend_control_buttons")


func _on_setup_state_changed(complete: bool) -> void:
	if complete:
		_setup_overlay.visible = false
		_main_content.visible = true


# ---------------------------------------------------------------------------
# Editor signal callbacks
# ---------------------------------------------------------------------------

func on_selection_changed() -> void:
	_update_inspect_tab()
	_update_context_bar()


func on_filesystem_changed() -> void:
	call_deferred("_refresh_memory_tab")


func on_scene_changed(_scene_root: Node) -> void:
	_update_context_bar()
	_update_inspect_tab()


func _update_context_bar() -> void:
	if not _ctx_scene_label or not editor_bridge:
		return
	var scene_summary: Dictionary = editor_bridge.get_current_scene_root_summary()
	if scene_summary.is_empty():
		_ctx_scene_label.text = "No scene"
		_ctx_node_label.text = ""
	else:
		var path: String = scene_summary.get("scene_path", "")
		_ctx_scene_label.text = path.get_file() if path != "" else "(unsaved)"
		_ctx_scene_label.tooltip_text = path

	var node_summary: Dictionary = editor_bridge.get_selected_node_deep_summary()
	if node_summary.has("error"):
		_ctx_node_label.text = ""
	else:
		_ctx_node_label.text = node_summary.get("name", "") + " (" + node_summary.get("class", "") + ")"

		# Show/hide 3D review button
		var review_3d: Node = _inspect_tab.get_node_or_null("InspectorVBox/Review3DBtn") if _inspect_tab else null
		if review_3d:
			review_3d.visible = node_summary.get("class", "") in [
				"Node3D", "MeshInstance3D", "CSGBox3D", "CSGSphere3D", "CSGCylinder3D",
				"CharacterBody3D", "RigidBody3D", "StaticBody3D",
			]

	# Update error counter
	var health: Dictionary = editor_bridge.get_filesystem_summary() if editor_bridge else {}
	var err_count: int = health.get("missing_scripts", 0) + health.get("missing_resources", 0)
	if _ctx_errors_label:
		if err_count > 0:
			_ctx_errors_label.text = "⚠ %d" % err_count
		else:
			_ctx_errors_label.text = ""


func _update_inspect_tab() -> void:
	if not editor_bridge:
		return
	if _inspect_scene_text:
		var scene_summary: Dictionary = editor_bridge.get_current_scene_root_summary()
		if scene_summary.is_empty():
			_inspect_scene_text.text = "[color=#555](no scene open)[/color]"
		else:
			var path: String = scene_summary.get("scene_path", "(unsaved)")
			var root_name: String = scene_summary.get("root_node_name", "")
			var root_class: String = scene_summary.get("root_node_class", "")
			var children: int = scene_summary.get("child_count", 0)
			_inspect_scene_text.text = (
				"[b]" + path.get_file() + "[/b]\n"
				+ "[color=#888]" + path + "[/color]\n"
				+ "Root: [b]" + root_name + "[/b] (" + root_class + ")  •  "
				+ str(children) + " children"
			)

	var node_summary: Dictionary = editor_bridge.get_selected_node_deep_summary()
	var node_text: String = (
		"[color=#555](no node selected)[/color]"
		if node_summary.has("error")
		else _format_node_bbcode(node_summary)
	)
	if _inspect_node_text:
		_inspect_node_text.text = node_text
	if _node_text:
		_node_text.text = node_text


# ---------------------------------------------------------------------------
# State callbacks
# ---------------------------------------------------------------------------

func _on_backend_status_changed(online: bool) -> void:
	if not _status_dot:
		return
	if online:
		if agent_client and agent_client.has_method("reset_health_warning_throttle"):
			agent_client.reset_health_warning_throttle()
		_chat_health_warn_suppress_until_ms = 0
		_status_dot.color = Color(0.2, 0.9, 0.4)
		_status_label.text = "ONLINE"
		_status_label.add_theme_color_override("font_color", Color(0.2, 0.9, 0.4))
		var ver: String = str(state.backend_version)
		var cfg_model: String = str(state.settings.get("model", "")).strip_edges()
		var eff: String = cfg_model if cfg_model != "" else str(state.backend_model)
		_backend_version_label.text = "v" + ver + " · " + eff if ver != "" else ""
		var selected_provider: String = str(state.settings.get("ai_settings", {}).get("provider", "gemini")).to_lower()
		var backend_keys_present: Dictionary = state.backend_api_keys_present if state.has_method("editor_any_api_key_configured") else {}
		var backend_provider_key: bool = bool(backend_keys_present.get(selected_provider, state.backend_gemini_key_present))
		var editor_key: bool = (
			state.editor_any_api_key_configured()
			if state.has_method("editor_any_api_key_configured")
			else state.editor_api_key_configured()
		)
		if backend_provider_key:
			_nagged_no_backend_api_key = false
			_nagged_restart_backend_for_key = false
		elif editor_key:
			if not _nagged_restart_backend_for_key:
				_log_info(
					"[color=#bdc3c7]%s key is saved in GoDotter. If tests still fail, press Stop then Launch backend "
					+ "(or restart Godot) so the server reloads the key file.[/color]"
					% selected_provider
				)
				_nagged_restart_backend_for_key = true
			_nagged_no_backend_api_key = false
		else:
			if not _nagged_no_backend_api_key:
				_log_warn(
					"Backend online but no %s key detected — add it in Settings or setup wizard, "
					+ "or set provider env vars before starting backend." % selected_provider
				)
				_nagged_no_backend_api_key = true
			_nagged_restart_backend_for_key = false
		var base_url: String = state.normalized_backend_http_base() if state and state.has_method("normalized_backend_http_base") else str(state.backend_url)
		var should_probe: bool = _backend_caps.is_empty() or _backend_caps_last_probe_url != base_url
		if should_probe and agent_client and agent_client.has_method("probe_backend_capabilities"):
			_backend_caps_last_probe_url = base_url
			agent_client.probe_backend_capabilities()
	else:
		_nagged_no_backend_api_key = false
		_nagged_restart_backend_for_key = false
		_status_dot.color = Color(0.6, 0.2, 0.2)
		_status_label.text = "OFFLINE"
		_status_label.add_theme_color_override("font_color", Color(0.6, 0.3, 0.3))
		_backend_version_label.text = ""
		_set_thinking(false)
		_backend_caps = {}
		_backend_caps_last_state = ""
		_backend_caps_last_probe_url = ""
		_apply_mode_capability_disables()
		_refresh_capabilities_status_text()

	_sync_backend_control_buttons()
	_update_health_timer_interval()


func _on_backend_capabilities_updated(capabilities: Dictionary) -> void:
	_backend_caps = capabilities.duplicate()
	_apply_mode_capability_disables()
	_refresh_capabilities_status_text()
	if _backend_caps.is_empty():
		return
	var required := [
		"/agent/plan",
		"/agent/run",
		"/agent/execute",
		"/project/index",
		"/memory",
		"/agent/fix_from_logs",
		"/agent/visual_map",
	]
	var missing: Array = []
	for r in required:
		if not bool(_backend_caps.get(r, false)):
			missing.append(r)
	var new_state: String = "ok" if missing.is_empty() else ("missing:" + ", ".join(missing))
	if new_state == _backend_caps_last_state:
		return
	_backend_caps_last_state = new_state
	if missing.is_empty():
		_log_success("Backend capability probe: all core command routes are available.")
	else:
		_log_warn("Backend capability probe: disabling unsupported routes: " + ", ".join(missing))
	if agent_client and agent_client.has_method("request_ai_capabilities"):
		agent_client.request_ai_capabilities()


func _on_ai_capabilities_response(data: Dictionary) -> void:
	if _ai_settings_status == null:
		return
	if data.is_empty() or not bool(data.get("ok", false)):
		_ai_settings_status.text = "AI capability registry unavailable from backend."
		return
	var reg: Dictionary = data.get("registry", {})
	var providers: Dictionary = reg.get("providers", {})
	_ai_settings_status.text = "AI registry loaded: providers = %s" % [", ".join(providers.keys())]


func _on_ai_test_response(data: Dictionary) -> void:
	_set_thinking(false)
	if data.is_empty():
		_log_error("AI settings test returned empty response.")
		return
	if not bool(data.get("ok", false)):
		_log_error("AI settings test failed: " + str(data.get("error", "")))
		return
	var provider: String = str(data.get("provider", ""))
	var model: String = str(data.get("model", ""))
	var latency: int = int(data.get("latency_ms", 0))
	var usage: Dictionary = data.get("token_usage", {})
	var mocked: bool = bool(data.get("mocked", false))
	_log_success("AI settings test passed: %s / %s in %d ms%s" % [provider, model, latency, " (mocked)" if mocked else ""])
	_log_info("Token usage: " + str(usage))


func _on_queue_status_requested() -> void:
	var queued: int = _pending_count()
	if queued == 0:
		_log_info("[Queue] No pending tasks.")
		return
	var active_cmd: String = str(_active_command_task.get("command", "")) if not _active_command_task.is_empty() else "(idle)"
	_log_info("[Queue] %d task(s) pending. Active: %s" % [queued, active_cmd])


func _apply_mode_capability_disables() -> void:
	if _chat_mode_option == null:
		return
	var mode_route := {
		0: "/agent/run",
		1: "/agent/plan",
		2: "/agent/execute",
		5: "/project/index",
		6: "/memory",
		7: "/agent/fix_from_logs",
		8: "/agent/visual_map",
	}
	for idx in range(CHAT_MODE_LABELS.size()):
		var route: String = str(mode_route.get(idx, ""))
		var disabled: bool = false
		if route != "" and not _backend_caps.is_empty():
			disabled = not bool(_backend_caps.get(route, false))
		_chat_mode_option.set_item_disabled(idx, disabled)
		if disabled and _chat_mode_option.selected == idx:
			var fallback_idx: int = 1 if not _chat_mode_option.is_item_disabled(1) else 9
			_chat_mode_option.select(fallback_idx)
			_on_chat_mode_bar_changed(fallback_idx)


func _on_state_settings_changed() -> void:
	if _set_url and state:
		_set_url.text = str(state.settings.get("backend_url", state.backend_url))
	if _ai_openai_base_url and state:
		var aio: Dictionary = state.settings.get("ai_settings", {})
		_ai_openai_base_url.text = str(aio.get("openai_base_url", "")) if typeof(aio) == TYPE_DICTIONARY else ""
	if state:
		if _set_api_key_gemini:
			_set_api_key_gemini.text = (
				state.get_provider_api_key("gemini")
				if state.has_method("get_provider_api_key")
				else state.api_key
			)
		if _set_api_key_openai and state.has_method("get_provider_api_key"):
			_set_api_key_openai.text = state.get_provider_api_key("openai")
		if _set_api_key_claude and state.has_method("get_provider_api_key"):
			_set_api_key_claude.text = state.get_provider_api_key("claude")
	_sync_token_settings_ui_from_state()
	_sync_ai_settings_controls_from_state()
	_sync_chat_plan_bar_from_state()


func _sync_token_settings_ui_from_state() -> void:
	if state == null:
		return
	if _set_max_output_tokens:
		_set_max_output_tokens.value = clampi(int(state.settings.get("max_output_tokens", 131072)), 1024, 131072)
	if _set_max_input_tokens:
		_set_max_input_tokens.value = clampi(int(state.settings.get("max_input_tokens", 2000000)), 4096, 2000000)


func _on_plan_received(plan: Dictionary) -> void:
	_set_thinking(false)
	_push_thinking_trace("Plan response received.", "success")
	_cancel_plan_auto_approve()
	var from_agent_run_execute_done: bool = bool(plan.get("__agent_run_execute_done", false))
	if _tabs and (_chat_plan_requires_approval() or not from_agent_run_execute_done):
		_tabs.current_tab = 1
	var display: Dictionary = _normalize_plan_payload(plan)
	if state and typeof(display) == TYPE_DICTIONARY and not display.has("error") and str(display.get("summary", "")) != "":
		state.last_plan = display
		if not _active_command_task.is_empty():
			var active_task_id: String = str(_active_command_task.get("task_id", ""))
			if active_task_id != "":
				task_queue.update_task(active_task_id, {"plan": display, "status": "planning"})
				_history_write_task_snapshot(active_task_id, "planning", "Plan received and attached to task.")
		_history_write_plan_snapshot(display)
		call_deferred("_refresh_memory_tab")
	_plan_steps_cache = display.get("steps", [])
	_plan_step_done = []
	_rebuild_plan_task_checkboxes(0)
	if _plan_text:
		_plan_text.text = _format_plan_bbcode(display)
		_start_plan_reveal_animation()
	if _plan_actions:
		_plan_actions.visible = not display.has("error") and str(display.get("summary", "")) != ""
	if not from_agent_run_execute_done and not _chat_plan_requires_approval():
		if not display.has("error") and str(display.get("summary", "")) != "":
			_schedule_plan_auto_approve()


func _on_log_message(level: String, message: String) -> void:
	match level:
		"error":   _log_error(message)
		"warning": _log_warn(message)
		"success": _log_success(message)
		_:         _log_info(message)


# ---------------------------------------------------------------------------
# Thinking indicator
# ---------------------------------------------------------------------------

func _set_thinking(active: bool, agent: String = "") -> void:
	_ensure_thinking_timer()
	_ensure_thinking_trace_timer()
	var was_thinking: bool = _is_thinking
	_is_thinking = active
	if active and not was_thinking:
		_thinking_active_endpoint = ""
		_thinking_http_started_ms = 0
		_thinking_session_started_ms = Time.get_ticks_msec()
		_thinking_spinner_idx = 0
		_thinking_spinner_pattern_idx = 0
		_thinking_spinner_pattern_loops = 0
		_reset_thinking_trace()
		_push_thinking_trace("Session started.")
		if not _active_command_task.is_empty():
			_push_thinking_trace("Queued command: " + str(_active_command_task.get("command", "")))
		_push_thinking_trace("Gathering editor/project context...")
	elif not active:
		_push_thinking_trace("Session complete.", "success")
		_thinking_trace_revealed_entries = _thinking_trace_entries.size()
		_thinking_trace_partial_chars = 0
		_render_thinking_trace()
		_thinking_session_started_ms = 0
	if _thinking_bar:
		_thinking_bar.visible = active
	_update_thinking_spinner_visual()
	if _thinking_trace_container:
		_thinking_trace_container.visible = active and _thinking_trace_visible
	if _thinking_toggle_btn:
		_thinking_toggle_btn.text = ("Hide details ▾" if _thinking_trace_visible else "Show details ▸")
		_thinking_toggle_btn.disabled = not active
	if _thinking_copy_btn:
		_thinking_copy_btn.disabled = _thinking_trace_entries.is_empty()
	if _thinking_label and active:
		_thinking_label.text = _compose_thinking_status_text()
	if _thinking_model_label:
		if active:
			var bits: PackedStringArray = PackedStringArray()
			if agent.strip_edges() != "":
				bits.append(agent.strip_edges())
			var m: String = ""
			if state:
				m = str(state.settings.get("model", "")).strip_edges()
			if m != "":
				bits.append(m)
			var line := ""
			for j in range(bits.size()):
				if j > 0:
					line += " · "
				line += bits[j]
			_thinking_model_label.text = line
		else:
			_thinking_model_label.text = ""
	if _send_btn:
		_send_btn.disabled = active
	if _thinking_timer:
		if active:
			_thinking_timer.start()
		else:
			_thinking_timer.stop()
			_thinking_active_endpoint = ""
			_thinking_http_started_ms = 0
	if _thinking_trace_timer:
		if active:
			_thinking_trace_timer.start()
		else:
			_thinking_trace_timer.stop()
	if not active and _thinking_label:
		_thinking_label.text = "GoDotter is idle."


func _ensure_thinking_timer() -> void:
	if _thinking_timer:
		return
	_thinking_timer = Timer.new()
	_thinking_timer.wait_time = 0.16
	_thinking_timer.one_shot = false
	_thinking_timer.autostart = false
	_thinking_timer.timeout.connect(_on_thinking_tick)
	add_child(_thinking_timer)


func _ensure_thinking_trace_timer() -> void:
	if _thinking_trace_timer:
		return
	_thinking_trace_timer = Timer.new()
	_thinking_trace_timer.wait_time = 0.025
	_thinking_trace_timer.one_shot = false
	_thinking_trace_timer.autostart = false
	_thinking_trace_timer.timeout.connect(_on_thinking_trace_tick)
	add_child(_thinking_trace_timer)


func _on_thinking_tick() -> void:
	if not _is_thinking or _thinking_label == null:
		return
	var path: Array = THINKING_SPINNER_PATTERNS[_thinking_spinner_pattern_idx]
	if path.is_empty():
		path = [0]
	_thinking_spinner_idx += 1
	if _thinking_spinner_idx >= path.size():
		_thinking_spinner_idx = 0
		_thinking_spinner_pattern_loops += 1
		var loops_target: int = int(THINKING_SPINNER_PATTERN_LOOPS[_thinking_spinner_pattern_idx])
		if _thinking_spinner_pattern_loops >= maxi(1, loops_target):
			_thinking_spinner_pattern_idx = (_thinking_spinner_pattern_idx + 1) % THINKING_SPINNER_PATTERNS.size()
			_thinking_spinner_pattern_loops = 0
	_update_thinking_spinner_visual()
	_thinking_label.text = _compose_thinking_status_text()


func _update_thinking_spinner_visual() -> void:
	if _thinking_spinner_cells.is_empty():
		return
	var path: Array = THINKING_SPINNER_PATTERNS[_thinking_spinner_pattern_idx]
	if path.is_empty():
		path = [0]
	var path_size: int = path.size()
	var path_idx: int = int(path[_thinking_spinner_idx % path_size])
	var prev_path_idx: int = int(path[(_thinking_spinner_idx - 1 + path_size) % path_size])
	for i in range(_thinking_spinner_cells.size()):
		var cell := _thinking_spinner_cells[i] as ColorRect
		if cell == null:
			continue
		if i == path_idx:
			cell.color = Color(0.93, 0.67, 0.32)
		elif i == prev_path_idx:
			cell.color = Color(0.65, 0.43, 0.22)
		else:
			cell.color = Color(0.19, 0.16, 0.15)


func _is_background_thinking_endpoint(endpoint: String) -> bool:
	if endpoint == "/health" or endpoint == "/openapi.json":
		return true
	return false


func _compose_thinking_status_text() -> String:
	if not _is_thinking:
		return "GoDotter is idle."
	var ep: String = _thinking_active_endpoint.strip_edges()
	if ep != "" and not _is_background_thinking_endpoint(ep):
		return _format_live_thinking_line()
	return _format_session_thinking_line()


func _format_session_thinking_line() -> String:
	var cmd: String = ""
	if not _active_command_task.is_empty():
		cmd = str(_active_command_task.get("command", "")).strip_edges()
	var route: String = _required_route_for_command(cmd) if cmd != "" else ""
	var stage: String = _endpoint_thinking_stage(route) if route != "" else "Preparing editor request"
	var elapsed_s: float = 0.0
	if _thinking_session_started_ms > 0:
		elapsed_s = float(Time.get_ticks_msec() - _thinking_session_started_ms) / 1000.0
	var tail := " (session %.1fs)" % elapsed_s
	if cmd != "" and route != "":
		return stage + " — " + cmd + " → " + route + tail
	if cmd != "":
		return stage + " — " + cmd + tail
	return stage + tail


func _on_agent_request_started(endpoint: String) -> void:
	if _is_background_thinking_endpoint(endpoint):
		return
	_thinking_active_endpoint = endpoint
	_thinking_http_started_ms = Time.get_ticks_msec()
	_push_thinking_trace("HTTP start → " + endpoint, "info")
	if _is_thinking and _thinking_label:
		_thinking_label.text = _compose_thinking_status_text()


func _on_agent_request_finished(endpoint: String, ok: bool, http_code: int) -> void:
	if _is_background_thinking_endpoint(endpoint):
		pass
	elif endpoint == _thinking_active_endpoint:
		_thinking_active_endpoint = ""
	var http_msg := "HTTP done ← %s (%s)" % [endpoint, ("ok" if ok else "failed")]
	if http_code >= 0:
		http_msg += " code=" + str(http_code)
	_push_thinking_trace(http_msg, ("success" if ok else "error"))
	if _is_thinking and _thinking_label and not _is_background_thinking_endpoint(endpoint):
		_thinking_label.text = _compose_thinking_status_text()
	var expected: String = _active_command_expected_endpoint()
	if expected != "" and endpoint == expected:
		var msg := "HTTP %d" % http_code if http_code >= 0 else "request error"
		_finish_active_command_task(ok, msg)


func _format_live_thinking_line() -> String:
	var ep: String = _thinking_active_endpoint.strip_edges()
	if ep == "" or _is_background_thinking_endpoint(ep):
		return _format_session_thinking_line()
	var stage: String = _endpoint_thinking_stage(ep)
	var elapsed_s: float = 0.0
	if _thinking_http_started_ms > 0:
		elapsed_s = float(Time.get_ticks_msec() - _thinking_http_started_ms) / 1000.0
	return stage + " — waiting on " + ep + " (" + ("%.1fs" % elapsed_s) + ")"


func _on_thinking_toggle_pressed() -> void:
	_thinking_trace_visible = not _thinking_trace_visible
	if _thinking_toggle_btn:
		_thinking_toggle_btn.text = ("Hide details ▾" if _thinking_trace_visible else "Show details ▸")
	if _thinking_trace_container:
		_thinking_trace_container.visible = _is_thinking and _thinking_trace_visible


func _on_trace_mode_toggle_pressed() -> void:
	_thinking_trace_compact = not _thinking_trace_compact
	if _thinking_trace_mode_btn:
		_thinking_trace_mode_btn.text = ("Compact" if _thinking_trace_compact else "Verbose")
	_render_thinking_trace()


func _on_trace_autoscroll_toggle_pressed() -> void:
	_thinking_trace_auto_scroll = not _thinking_trace_auto_scroll
	if _thinking_trace_autoscroll_btn:
		_thinking_trace_autoscroll_btn.text = "Auto-scroll: " + ("On" if _thinking_trace_auto_scroll else "Off")
	if _thinking_trace_auto_scroll:
		_scroll_thinking_trace_to_bottom()


func _on_clear_trace_pressed() -> void:
	_reset_thinking_trace()


func _reset_thinking_trace() -> void:
	_thinking_trace_entries = []
	_thinking_trace_revealed_entries = 0
	_thinking_trace_partial_chars = 0
	if _thinking_trace:
		_thinking_trace.text = ""
	if _thinking_copy_btn:
		_thinking_copy_btn.disabled = true


func _push_thinking_trace(line: String, severity: String = "info", phase_ms: int = -1) -> void:
	if line.strip_edges() == "":
		return
	var elapsed_s: float = 0.0
	if _thinking_session_started_ms > 0:
		elapsed_s = float(Time.get_ticks_msec() - _thinking_session_started_ms) / 1000.0
	_thinking_trace_entries.append({
		"text": line,
		"severity": severity.to_lower(),
		"elapsed_s": elapsed_s,
		"phase_ms": phase_ms,
	})
	# Keep trace bounded.
	if _thinking_trace_entries.size() > 220:
		_thinking_trace_entries = _thinking_trace_entries.slice(_thinking_trace_entries.size() - 200, _thinking_trace_entries.size())
		_thinking_trace_revealed_entries = clampi(_thinking_trace_revealed_entries, 0, _thinking_trace_entries.size())
		_thinking_trace_partial_chars = 0
	if _thinking_copy_btn:
		_thinking_copy_btn.disabled = _thinking_trace_entries.is_empty()
	_render_thinking_trace()


func _on_thinking_trace_tick() -> void:
	if not _is_thinking or _thinking_trace == null:
		return
	var count: int = _thinking_trace_entries.size()
	if count <= 0:
		return
	if _thinking_trace_revealed_entries < count:
		var cur: Dictionary = _thinking_trace_entries[_thinking_trace_revealed_entries]
		var txt: String = str(cur.get("text", ""))
		if _thinking_trace_partial_chars < txt.length():
			_thinking_trace_partial_chars = mini(txt.length(), _thinking_trace_partial_chars + 5)
		else:
			_thinking_trace_revealed_entries += 1
			_thinking_trace_partial_chars = 0
	_render_thinking_trace()


func _render_thinking_trace() -> void:
	if _thinking_trace == null:
		return
	var out := ""
	var reveal_count: int = mini(_thinking_trace_revealed_entries, _thinking_trace_entries.size())
	for i in range(reveal_count):
		var entry: Dictionary = _thinking_trace_entries[i]
		out += _format_thinking_trace_entry(entry, -1) + "\n"
	if _thinking_trace_revealed_entries < _thinking_trace_entries.size():
		var partial: Dictionary = _thinking_trace_entries[_thinking_trace_revealed_entries]
		out += _format_thinking_trace_entry(partial, _thinking_trace_partial_chars)
	_thinking_trace.text = out
	_scroll_thinking_trace_to_bottom()


func _format_thinking_trace_entry(entry: Dictionary, partial_chars: int = -1) -> String:
	var sev: String = str(entry.get("severity", "info")).to_lower()
	var color := "#8aa1b2"
	match sev:
		"success":
			color = "#2ecc71"
		"warning":
			color = "#f1c40f"
		"error":
			color = "#e74c3c"
		_:
			color = "#7fb3d3"
	var icon := "•"
	match sev:
		"success":
			icon = "✓"
		"warning":
			icon = "⚠"
		"error":
			icon = "✕"
		_:
			icon = "•"
	var elapsed_s: float = float(entry.get("elapsed_s", 0.0))
	var text: String = str(entry.get("text", ""))
	if partial_chars >= 0:
		text = text.substr(0, mini(text.length(), partial_chars))
	var phase_ms: int = int(entry.get("phase_ms", -1))
	var suffix := ""
	if phase_ms >= 0:
		suffix = " · phase %.2fs" % (float(phase_ms) / 1000.0)
	if _thinking_trace_compact:
		var compact_suffix := ""
		if phase_ms >= 0:
			compact_suffix = " (%.2fs)" % (float(phase_ms) / 1000.0)
		return "[color=%s]%s %s%s[/color]" % [color, icon, _esc(text), compact_suffix]
	return "[color=%s][%5.1fs] %s %s%s[/color]" % [color, elapsed_s, icon, _esc(text), suffix]


func _thinking_trace_plain_text() -> String:
	var out := ""
	for entry in _thinking_trace_entries:
		var elapsed_s: float = float((entry as Dictionary).get("elapsed_s", 0.0))
		var phase_ms: int = int((entry as Dictionary).get("phase_ms", -1))
		var suffix := ""
		if phase_ms >= 0:
			suffix = " (phase %.2fs)" % (float(phase_ms) / 1000.0)
		if _thinking_trace_compact:
			out += "%s%s\n" % [str((entry as Dictionary).get("text", "")), suffix]
		else:
			out += "[%5.1fs] %s%s\n" % [elapsed_s, str((entry as Dictionary).get("text", "")), suffix]
	return out


func _on_copy_trace_pressed() -> void:
	var text: String = _thinking_trace_plain_text().strip_edges()
	if text == "":
		return
	DisplayServer.clipboard_set(text)
	_log_success("Thinking trace copied to clipboard.")


func _scroll_thinking_trace_to_bottom() -> void:
	if not _thinking_trace_auto_scroll:
		return
	if _thinking_trace_scroll:
		_thinking_trace_scroll.set_deferred("scroll_vertical", 1000000000)


func _endpoint_thinking_stage(endpoint: String) -> String:
	match endpoint:
		"/agent/plan":
			return "Backend: planning (LLM)"
		"/agent/run":
			return "Backend: full agent run (LLM + validation)"
		"/agent/execute":
			return "Backend: execute / apply edits (LLM)"
		"/project/index":
			return "Backend: indexing project on disk"
		"/project/context":
			return "Backend: building ranked context bundle"
		"/agent/fix_from_logs":
			return "Backend: analyzing logs (LLM)"
		"/agent/visual_map":
			return "Backend: visual map analysis (LLM)"
		"/agent/visual_review_3d":
			return "Backend: 3D visual review (LLM)"
		"/memory":
			return "Backend: reading memory store"
		"/tools/write_file":
			return "Backend: writing file to project"
		_:
			return "Backend: HTTP " + endpoint


func _ensure_chat_reveal_timer() -> void:
	return


func _reset_chat_reveal_state() -> void:
	_chat_reveal_queue = []
	if _chat_reveal_timer:
		_chat_reveal_timer.stop()
	if _chat_log:
		_chat_log.visible_characters = -1


func _append_chat_line_with_reveal(bbcode_line: String) -> void:
	if _chat_log == null:
		return
	var keep_bottom: bool = _chat_scroll_is_near_bottom()
	_reset_chat_reveal_state()
	_chat_log.append_text(bbcode_line)
	if keep_bottom:
		_scroll_chat_log_to_bottom()


func _scroll_chat_log_to_bottom() -> void:
	if _chat_log == null:
		return
	var p: Node = _chat_log.get_parent()
	if p is ScrollContainer:
		(p as ScrollContainer).set_deferred("scroll_vertical", 1000000000)


func _chat_scroll_is_near_bottom() -> bool:
	if _chat_log == null:
		return true
	var p: Node = _chat_log.get_parent()
	if not (p is ScrollContainer):
		return true
	var sc: ScrollContainer = p as ScrollContainer
	var bar: VScrollBar = sc.get_v_scroll_bar()
	if bar == null:
		return true
	return (bar.value + bar.page) >= (bar.max_value - 24.0)


func _ensure_plan_reveal_timer() -> void:
	if _plan_reveal_timer:
		return
	_plan_reveal_timer = Timer.new()
	_plan_reveal_timer.wait_time = 0.02
	_plan_reveal_timer.one_shot = false
	_plan_reveal_timer.timeout.connect(_on_plan_reveal_tick)
	add_child(_plan_reveal_timer)


func _start_plan_reveal_animation() -> void:
	if _plan_text == null:
		return
	_ensure_plan_reveal_timer()
	_plan_reveal_target_chars = _plan_text.get_total_character_count()
	if _plan_reveal_target_chars <= 0:
		_plan_text.visible_characters = -1
		if _plan_reveal_timer:
			_plan_reveal_timer.stop()
		return
	_plan_text.visible_characters = 0
	if _plan_reveal_timer:
		_plan_reveal_timer.start()


func _on_plan_reveal_tick() -> void:
	if _plan_text == null:
		if _plan_reveal_timer:
			_plan_reveal_timer.stop()
		return
	var cur: int = maxi(0, _plan_text.visible_characters)
	var remaining: int = _plan_reveal_target_chars - cur
	if remaining <= 0:
		_plan_text.visible_characters = -1
		if _plan_reveal_timer:
			_plan_reveal_timer.stop()
		return
	var parsed: String = _plan_text.get_parsed_text()
	_plan_text.visible_characters = mini(
		_plan_reveal_target_chars,
		_next_reveal_word_index(parsed, cur, _plan_reveal_target_chars)
	)


# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

func _log_user_input(text: String, attachments: Array = []) -> void:
	if _chat_log:
		var line := "[color=#888]» [/color][color=#ccc]" + _esc(text) + "[/color]"
		line += _user_attachment_preview_bbcode(attachments)
		_append_chat_line_with_reveal(line + "\n")
	_sync_chat_session_log_after_append(text)


func _log_info(msg: String) -> void:
	if _chat_log:
		_append_chat_line_with_reveal("[color=#7fb3d3]" + msg + "[/color]\n")
	_sync_chat_session_log_after_append()


func _log_warn(msg: String) -> void:
	if msg.contains("Health check failed"):
		var now: int = Time.get_ticks_msec()
		if now < _chat_health_warn_suppress_until_ms:
			return
		_chat_health_warn_suppress_until_ms = now + 16000
	if _chat_log:
		_append_chat_line_with_reveal("[color=#f39c12]⚠ " + msg + "[/color]\n")
	_sync_chat_session_log_after_append()


func _log_error(msg: String) -> void:
	if _chat_log:
		_append_chat_line_with_reveal("[color=#e74c3c]✕ " + msg + "[/color]\n")
	_sync_chat_session_log_after_append()


func _log_success(msg: String) -> void:
	if _chat_log:
		_append_chat_line_with_reveal("[color=#2ecc71]" + msg + "[/color]\n")
	_sync_chat_session_log_after_append()


func _clean_error_text(value) -> String:
	if value == null:
		return ""
	var s: String = str(value).strip_edges()
	if s == "" or s == "<null>" or s.to_lower() == "null":
		return ""
	return s


func _esc(text: String) -> String:
	return text.replace("[", "&#91;").replace("]", "&#93;")


func _user_attachment_preview_bbcode(attachments: Array) -> String:
	if attachments.is_empty():
		return ""
	var lines: Array[String] = []
	lines.append("\n[color=#86a7c6]Attached image(s):[/color]")
	for i in range(attachments.size()):
		var item: Variant = attachments[i]
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var name: String = _esc(str(d.get("name", "image_%d" % (i + 1))))
		var image_bb: String = _attachment_bbcode_image_tag(d, i)
		if image_bb != "":
			lines.append("[color=#8f9aa3]-[/color] %s %s" % [name, image_bb])
		else:
			lines.append("[color=#8f9aa3]-[/color] %s" % name)
	return "\n" + "\n".join(lines)


func _attachment_bbcode_image_tag(item: Dictionary, idx: int) -> String:
	var b64: String = str(item.get("base64", "")).strip_edges()
	if b64 == "":
		return ""
	var raw: PackedByteArray = Marshalls.base64_to_raw(b64)
	if raw.is_empty():
		return ""
	var ext := "png"
	var mime: String = str(item.get("mime_type", "image/png")).to_lower()
	if mime == "image/jpeg":
		ext = "jpg"
	elif mime == "image/webp":
		ext = "webp"
	elif mime == "image/bmp":
		ext = "bmp"
	var dir_path := "user://.godotter/chat_inline"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var fp := "%s/%d_%d.%s" % [dir_path, Time.get_unix_time_from_system(), idx, ext]
	var f := FileAccess.open(fp, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(raw)
	f.close()
	# RichTextLabel [img] is the most compact thumbnail style available in chat text.
	return "[img=72x72]%s[/img]" % fp


# ---------------------------------------------------------------------------
# Emergency restore (called by GoDotter.gd on unload)
# ---------------------------------------------------------------------------

func emergency_restore() -> void:
	if debug_visualizer and debug_visualizer.has_method("emergency_restore"):
		debug_visualizer.emergency_restore()


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

func _welcome_message() -> String:
	return (
		"[color=#00ffcc][b]⬡ GoDotter[/b][/color]\n"
		+ "[color=#555]AI game dev assistant for Godot 4.[/color]\n\n"
		+ "[color=#888]Choose [b]Full agent[/b] for plan + validators + execute (when file edits are enabled), "
		+ "or [b]Plan[/b] / [b]Execute[/b] for manual steps. [b]Fix logs[/b] uses recent Output (F5 errors). Slash: [b]/agent[/b], [b]/plan[/b], [b]/help[/b].[/color]\n"
	)


func _help_text() -> String:
	return (
		"[b]Modes[/b] (dropdown): [b]Full agent[/b] (plan→validate→execute), Plan, Execute, …\n\n"
		+ "[b]Plan selector:[/b] [b]Require approval[/b] (stop after plan) or [b]Auto-run[/b] (execute automatically)\n\n"
		+ "[b]Slash commands:[/b]\n"
		+ "  [b]/agent[/b] <request>   — same as Full agent (Roo-style session)\n"
		+ "  [b]/plan[/b] <request>   — plan changes (no edits)\n"
		+ "  [b]/do[/b] <request>     — plan + execute\n"
		+ "  [b]/fix[/b] <request>    — debug + fix\n"
		+ "  [b]/scene[/b]             — describe current scene\n"
		+ "  [b]/node[/b]              — inspect selected node\n"
		+ "  [b]/audit[/b]             — index + health check\n"
		+ "  [b]/neon[/b] [query]     — AI visual map (neon colors)\n"
		+ "  [b]/visual3d[/b]          — 3D asset review\n"
		+ "  [b]/fixlogs[/b]           — batch fix from Output / debug session logs\n"
		+ "  [b]/memory[/b]            — view project memory\n"
		+ "  [b]/queue[/b]             — show queued tasks and active task\n"
		+ "  [b]/diff[/b]              — open Diff tab\n"
		+ "  [b]/settings[/b]          — open Settings tab\n"
		+ "  [b]/clear[/b]             — clear chat log"
	)


func _normalize_plan_payload(d: Dictionary) -> Dictionary:
	if d.is_empty():
		return {}
	var top_err := _clean_error_text(d.get("error", null))
	if top_err != "":
		return {"error": top_err}
	if d.has("plan") and typeof(d["plan"]) == TYPE_DICTIONARY:
		var inner: Dictionary = d["plan"]
		if not inner.is_empty():
			return inner
	return d


func _format_plan_bbcode(plan: Dictionary) -> String:
	var p := _normalize_plan_payload(plan)
	if p.has("error"):
		return "[color=#e74c3c][b]Error:[/b] " + _esc(str(p.get("error", ""))) + "[/color]"

	var out := "[b][color=#f39c12]" + _esc(p.get("summary", "(no summary)")) + "[/color][/b]\n\n"

	var files: Array = p.get("relevant_files", [])
	if not files.is_empty():
		out += "[color=#3498db][b]Files:[/b][/color] " + ", ".join(files) + "\n"

	var scenes: Array = p.get("relevant_scenes", [])
	if not scenes.is_empty():
		out += "[color=#3498db][b]Scenes:[/b][/color] " + ", ".join(scenes) + "\n"

	var steps: Array = p.get("steps", [])
	if not steps.is_empty():
		out += "\n[b]Steps:[/b]\n"
		for i in steps.size():
			var step: Dictionary = steps[i]
			out += ("  [color=#aaa]%d.[/color] " + _esc(str(step.get("description", "")))) % (i + 1) + "\n"

	var risks: Array = p.get("risks", [])
	if not risks.is_empty():
		out += "\n[color=#e74c3c][b]Risks:[/b][/color]\n"
		for r in risks:
			out += "  • " + _esc(str(r)) + "\n"

	var validation: Array = p.get("validation_plan", [])
	if not validation.is_empty():
		out += "\n[color=#2ecc71][b]Validation:[/b][/color]\n"
		for v in validation:
			out += "  ✓ " + _esc(str(v)) + "\n"

	if p.get("approval_required", true):
		out += "\n[color=#f39c12]Approval required. Click [b]Execute Plan[/b] above to proceed.[/color]"

	return out


func _format_node_bbcode(n: Dictionary) -> String:
	var out := "[b]" + _esc(n.get("name", "?")) + "[/b]  [color=#888](" + _esc(n.get("class", "")) + ")[/color]\n"
	if n.get("script", "") != "":
		out += "[color=#7fb3d3]Script:[/color] " + n.get("script", "") + "\n"
	if n.get("position") != null:
		var pos = n.get("position")
		out += "[color=#888]Pos:[/color] " + str(pos) + "\n"
	for prop in n.get("notable_properties", []):
		out += "  [color=#555]" + _esc(str(prop)) + "[/color]\n"
	return out
