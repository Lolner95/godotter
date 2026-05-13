@tool
extends Control

## GoDotter Forge Dock — the main plugin UI.
##
## Layout
##   ┌─ Top bar: logo · status · backend btn ──────────────────────┐
##   ├─ Context bar: current scene · selected node ────────────────┤
##   ├─ Tabs: [Chat] [Plan] [Inspect] [Diff] [Memory] [Settings] ──┤
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
const DiffPanelScript       := preload("res://addons/GoDotter/ui/DiffPanel.gd")
const SetupWizardScript     := preload("res://addons/GoDotter/ui/SetupWizard.gd")

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
var _cmd_input: LineEdit
var _send_btn: Button
var _thinking_bar: Control
var _thinking_label: Label
var _thinking_model_label: Label

## Chat bar: Cursor-style mode + model (mirrors Settings model into requests).
var _chat_mode_option: OptionButton
var _chat_model_option: OptionButton

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

# Plan tab internals
var _plan_text: RichTextLabel
var _plan_actions: Control

# Inspect tab internals
var _inspect_scene_text: RichTextLabel
var _inspect_node_text: RichTextLabel
var _viz_query_input: LineEdit

# Memory tab
var _memory_file_list: ItemList
var _memory_content: RichTextLabel

# Settings tab
var _set_backend_dir: LineEdit
var _set_python_path: LineEdit
var _set_api_key: LineEdit
var _set_url: LineEdit
var _model_preset: OptionButton
var _model_custom: LineEdit
var _set_autostart: CheckBox
var _set_file_edits: CheckBox
var _set_approval_mode: OptionButton

# Avoid duplicate "Health check failed" lines in the chat panel (Output is throttled in AgentClient).
var _chat_health_warn_suppress_until_ms: int = 0

# Health check timer
var _health_timer: Timer
const HEALTH_INTERVAL_ONLINE := 6.0
const HEALTH_INTERVAL_OFFLINE := 18.0

## Preset Gemini model ids (Custom… uses _model_custom).
const MODEL_PRESETS: Array[String] = [
	"gemini-2.5-pro",
	"gemini-2.5-flash",
	"gemini-2.5-flash-lite",
	"gemini-2.0-flash",
	"gemini-3.1-pro-preview",
]

# Thinking state
var _is_thinking := false

# Avoid spamming chat when health timer fires every few seconds
var _nagged_no_backend_api_key: bool = false
var _nagged_restart_backend_for_key: bool = false


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


func _build_ai_context_bundle() -> Dictionary:
	var context: Dictionary = editor_bridge.build_context_bundle() if editor_bridge else {}
	context["project_index"] = state.project_index
	context["project_root"] = state.project_root
	context["godotter"] = {
		"enable_file_edits": bool(state.settings.get("enable_file_edits", false)),
		"approval_mode": str(state.settings.get("approval_mode", "review")),
	}
	return context


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
	_tabs.tab_alignment = TabBar.ALIGNMENT_LEFT
	_tabs.add_theme_font_size_override("font_size", 18)

	_chat_tab = _build_chat_tab()
	_chat_tab.name = "Chat"
	_tabs.add_child(_chat_tab)

	_plan_tab = _build_plan_tab()
	_plan_tab.name = "Plan"
	_tabs.add_child(_plan_tab)

	_inspect_tab = _build_inspect_tab()
	_inspect_tab.name = "Inspect"
	_tabs.add_child(_inspect_tab)

	_diff_tab = DiffPanelScript.new()
	_diff_tab.name = "Diff"
	(_diff_tab as Node).call("setup", state, diff_manager)
	_diff_tab.connect("approve_requested", _on_diff_approved)
	_diff_tab.connect("revert_requested", _on_diff_file_reverted)
	_tabs.add_child(_diff_tab)

	_memory_tab = _build_memory_tab()
	_memory_tab.name = "Memory"
	_tabs.add_child(_memory_tab)

	_settings_tab = _build_settings_tab()
	_settings_tab.name = "Settings"
	_tabs.add_child(_settings_tab)

	return _tabs


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

	var qa_row2 := HBoxContainer.new()
	qa_row2.add_theme_constant_override("separation", 6)
	_qa_btn(qa_row2, "Scene",  Color(0.5, 0.8, 0.5), func(): _route_command("/scene", ""))
	_qa_btn(qa_row2, "Node",   Color(0.5, 0.8, 0.5), func(): _route_command("/node", ""))
	_qa_btn(qa_row2, "Index",  Color(0.7, 0.5, 0.9), func(): _route_command("/audit", ""))
	_qa_btn(qa_row2, "Memory", Color(0.7, 0.5, 0.9), func(): _route_command("/memory", ""))
	qa_vb.add_child(qa_row2)
	vb.add_child(qa_vb)

	vb.add_child(HSeparator.new())

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
	_thinking_bar.add_theme_constant_override("separation", 6)
	var thinking_dot := ColorRect.new()
	thinking_dot.custom_minimum_size = Vector2(8, 8)
	thinking_dot.color = Color(0.0, 1.0, 0.9)
	_thinking_bar.add_child(thinking_dot)
	_thinking_label = Label.new()
	_thinking_label.text = "GoDotter is thinking…"
	_thinking_label.add_theme_font_size_override("font_size", 16)
	_thinking_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_thinking_bar.add_child(_thinking_label)
	_thinking_model_label = Label.new()
	_thinking_model_label.add_theme_font_size_override("font_size", 16)
	_thinking_model_label.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
	_thinking_bar.add_child(_thinking_model_label)
	vb.add_child(_thinking_bar)

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
	_chat_mode_option.item_selected.connect(_on_chat_mode_bar_changed)
	call_deferred("_on_chat_mode_bar_changed", 0)
	vb.add_child(mode_bar)
	call_deferred("_sync_chat_model_bar_from_state")

	# Input row
	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 4)
	_cmd_input = LineEdit.new()
	_cmd_input.name = "CommandInput"
	_cmd_input.placeholder_text = "Describe what you want (Plan mode)…"
	_cmd_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cmd_input.add_theme_font_size_override("font_size", 18)
	_cmd_input.text_submitted.connect(_on_command_submitted)
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

	return vb


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

	vb.add_child(_settings_label("Provider API key (Gemini / Google AI Studio)"))
	_set_api_key = LineEdit.new()
	_set_api_key.secret = true
	_set_api_key.text = state.api_key
	_set_api_key.placeholder_text = "Paste key — stored in Editor Settings; synced for backend launch"
	_set_api_key.tooltip_text = (
		"Same as GEMINI_API_KEY or GOOGLE_API_KEY. The backend is Google Gemini only for now; "
		+ "this field is generic so we can add other providers later."
	)
	_set_api_key.add_theme_font_size_override("font_size", 16)
	vb.add_child(_set_api_key)

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

	var save_btn := Button.new()
	save_btn.text = "Save Settings"
	save_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	save_btn.add_theme_font_size_override("font_size", 18)
	save_btn.pressed.connect(_on_save_settings)
	vb.add_child(save_btn)

	vb.add_child(
		_settings_label(
			"You can also set GEMINI_API_KEY or GOOGLE_API_KEY in the shell before python main.py"
		)
	)

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
	if idx >= 0 and idx < MODEL_PRESETS.size():
		var mid: String = MODEL_PRESETS[idx]
		if str(state.settings.get("model", "")) != mid:
			state.settings["model"] = mid
			state.save_settings()
			_apply_model_selection_from_settings()


func _on_chat_mode_bar_changed(_idx: int = 0) -> void:
	if _cmd_input == null or _chat_mode_option == null:
		return
	match _chat_mode_option.selected:
		0:
			_cmd_input.placeholder_text = "Goal for Full agent (plan → validate → execute if enabled)…"
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
func _await_backend_http_ready(max_wait_sec: float = 10.0) -> bool:
	if state == null:
		return false
	if state.backend_online:
		return true
	var deadline_ms: int = Time.get_ticks_msec() + int(max_wait_sec * 1000.0)
	var next_health_ms: int = Time.get_ticks_msec() + 900
	trigger_health_check()
	await get_tree().create_timer(0.85).timeout
	while Time.get_ticks_msec() < deadline_ms:
		if state.backend_online:
			return true
		var now: int = Time.get_ticks_msec()
		if now >= next_health_ms:
			trigger_health_check()
			next_health_ms = now + 2200
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
	if trimmed.is_empty():
		return
	_cmd_input.text = ""

	if trimmed.begins_with("/"):
		_log_user_input(trimmed)
		var parsed: Dictionary = _parse_slash_command(trimmed)
		_route_command(str(parsed.get("cmd", "")), str(parsed.get("args", "")), true)
	else:
		_log_user_input(trimmed)
		_submit_chat_mode(trimmed)


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
			_cmd_agent_run(body)
		1:
			_cmd_plan(body)
		2:
			_cmd_execute(body)
		3:
			_cmd_scene()
		4:
			_cmd_node()
		5:
			_cmd_audit()
		6:
			_cmd_memory()
		7:
			_cmd_fixlogs("")
		8:
			_cmd_visualmap(body)
		9:
			_log_info(_help_text())
		_:
			_cmd_plan(body)


func _route_command(cmd: String, args: String, already_echoed_user_line: bool = false) -> void:
	if not already_echoed_user_line:
		var display: String = cmd
		if args.strip_edges() != "":
			display += " " + args
		_log_user_input(display)
	match cmd:
		"/plan":        _cmd_plan(args)
		"/do", "/fix":  _cmd_execute(args)
		"/scene":       _cmd_scene()
		"/node":        _cmd_node()
		"/audit":       _cmd_audit()
		"/memory":      _cmd_memory()
		"/fixlogs":     _cmd_fixlogs(args)
		"/visualmap", "/visualize", "/neon":  _cmd_visualmap(args)
		"/visual3d":    _on_review_3d_pressed()
		"/diff":
			_tabs.current_tab = 3
			_log_info("Switched to Diff tab.")
		"/settings":
			_tabs.current_tab = 5
		"/clear":
			if _chat_log:
				_chat_log.text = ""
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


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

func _cmd_plan(request: String) -> void:
	if state:
		state.sync_backend_api_key_file()
	if request.is_empty():
		_log_info("Usage: type your goal in the box, or [b]/plan[/b] <your request>")
		return
	if not await _await_backend_http_ready():
		_log_error("Backend offline — start it first (▶ button or Settings).")
		return
	_log_info("Planning: [i]" + request + "[/i]")
	_set_thinking(true, "Architect")
	var context: Dictionary = _build_ai_context_bundle()
	agent_client.request_plan(request, context)


func _cmd_execute(request: String) -> void:
	if state:
		state.sync_backend_api_key_file()
	if not await _await_backend_http_ready():
		_log_error("Backend offline.")
		return
	if state.last_plan.is_empty() and request.is_empty():
		_log_error("No plan and no request. Use [b]/plan[/b] first, or provide a request.")
		return
	var req: String = request if request != "" else str(state.last_plan.get("summary", ""))
	_log_info("Executing: [i]" + req + "[/i]")
	_set_thinking(true, "Code")
	var context: Dictionary = _build_ai_context_bundle()
	agent_client.request_execute(req, context, state.last_plan)


func _cmd_agent_run(request: String) -> void:
	if state:
		state.sync_backend_api_key_file()
	if request.is_empty():
		_log_info("Usage: describe the change — Full agent runs plan, validators, then execute if file edits are enabled in Settings.")
		return
	if not await _await_backend_http_ready():
		_log_error("Backend offline — start it first (▶ or Settings).")
		return
	if not bool(state.settings.get("enable_file_edits", false)):
		_log_warn(
			"Full agent will [b]plan + validate only[/b] until you enable [b]Allow AI to write files[/b] in Settings."
		)
	_log_info("[b]Full agent[/b]: [i]" + request + "[/i] (may take a few minutes)")
	_set_thinking(true, "Agent")
	var context: Dictionary = _build_ai_context_bundle()
	agent_client.request_agent_run(request, context)


func _on_agent_run_response(data: Dictionary) -> void:
	_set_thinking(false)
	if data.is_empty():
		return
	var phases: Array = data.get("phases", [])
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
			if ok:
				_log_success("Phase [b]" + nm + "[/b] ✓" + ((" — " + detail) if detail != "" else ""))
			else:
				_log_warn("Phase [b]" + nm + "[/b]: " + (detail if detail != "" else "check response"))
	if data.has("plan") and data.get("plan") != null:
		var wrap: Dictionary = {"ok": data.get("ok", false), "plan": data["plan"], "error": data.get("error", "")}
		state.plan_received.emit(wrap)
	if not bool(data.get("ok", false)) and str(data.get("error", "")) != "":
		_log_error(str(data.get("error", "")))


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
	_tabs.current_tab = 2
	_update_inspect_tab()


func _cmd_node() -> void:
	if not editor_bridge:
		return
	var s: Dictionary = editor_bridge.get_selected_node_deep_summary()
	if s.has("error"):
		_log_info(s.get("error", ""))
		return
	_log_info(_format_node_bbcode(s))
	_tabs.current_tab = 2


func _cmd_audit() -> void:
	if state:
		state.sync_backend_api_key_file()
	if not await _await_backend_http_ready():
		_log_error("Backend offline.")
		return
	_log_info("Indexing project for audit…")
	agent_client.request_index(state.project_root)


func _cmd_memory() -> void:
	if state:
		state.sync_backend_api_key_file()
	if not await _await_backend_http_ready():
		_log_error("Backend offline.")
		return
	_log_info("Loading project memory…")
	_tabs.current_tab = 4
	_refresh_memory_tab()
	agent_client.get_memory()


func _cmd_fixlogs(run_id: String) -> void:
	if state:
		state.sync_backend_api_key_file()
	if not await _await_backend_http_ready():
		_log_error("Backend offline.")
		return
	_log_info("Aggregating logs for batch fix plan…")
	_set_thinking(true, "Debug")
	agent_client.request_fix_from_logs(
		run_id,
		log_collector.get_recent_log() if log_collector else ""
	)


func _cmd_visualmap(query: String) -> void:
	if not debug_visualizer:
		_log_error("DebugVisualizer not initialized.")
		return
	if EditorInterface.get_edited_scene_root() == null:
		_log_error("No scene open. Open a scene first.")
		return
	debug_visualizer.set_meta("pending_query", query)
	_log_info("[color=#00ffff]Neon visualization starting…[/color]")
	_log_info("[color=#888]Colors restore automatically after capture.[/color]")
	debug_visualizer.visualize_and_capture("visualmap")


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
	if state.last_plan.is_empty():
		_log_error("No plan to execute.")
		return
	_tabs.current_tab = 0
	_cmd_execute("")


func _on_plan_reject_pressed() -> void:
	state.last_plan = {}
	_plan_text.text = "[color=#888]Plan rejected.[/color]"
	_plan_actions.visible = false
	_log_info("Plan rejected.")


# ---------------------------------------------------------------------------
# Backend launch / stop (from top bar)
# ---------------------------------------------------------------------------

func _on_launch_backend_pressed() -> void:
	if state.backend_dir == "":
		_log_info("[color=#f39c12]Configure backend directory in Settings first.[/color]")
		_tabs.current_tab = 5
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
	if _set_api_key:
		state.api_key = _set_api_key.text.strip_edges()


func _on_save_settings() -> void:
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
	state.save_settings()

	_log_info("[color=#2ecc71]Settings saved.[/color]")
	_sync_chat_model_bar_from_state()


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
	# state is typed Object — project_root must be explicit String for inference.
	var memory_dir: String = str(state.project_root).path_join(".godot_forge/memory")
	var dir := DirAccess.open(memory_dir)
	if dir == null:
		if _memory_content:
			_memory_content.text = "[color=#555]No memory files yet. Use Plan mode, /plan, or Index to create them.[/color]"
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".md"):
			_memory_file_list.add_item(fname)
			_memory_file_list.set_item_metadata(_memory_file_list.item_count - 1, memory_dir.path_join(fname))
		fname = dir.get_next()
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
		_log_error("Execute failed: " + str(data.get("error", "")))
		return
	var files: Array = data.get("files_written", [])
	_log_success("Wrote %d file(s)." % files.size())
	for f in files:
		_log_info("  • " + str(f))
	if data.has("git_checkpoint"):
		var gcs: String = str(data.get("git_checkpoint", ""))
		_log_info("Git checkpoint: " + gcs.substr(0, mini(8, gcs.length())))
	# Switch to Diff tab if there are diffs
	if not data.get("diffs", []).is_empty():
		_tabs.current_tab = 3


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
	if not _inspect_scene_text or not editor_bridge:
		return
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
	if node_summary.has("error"):
		_inspect_node_text.text = "[color=#555](no node selected)[/color]"
	else:
		_inspect_node_text.text = _format_node_bbcode(node_summary)


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
		var editor_key: bool = state.editor_api_key_configured()
		if state.backend_gemini_key_present:
			_nagged_no_backend_api_key = false
			_nagged_restart_backend_for_key = false
		elif editor_key:
			if not _nagged_restart_backend_for_key:
				_log_info(
					"[color=#bdc3c7]API key is saved in GoDotter. If tests still fail, press Stop then Launch backend "
					+ "(or restart Godot) so the server reloads the key file.[/color]"
				)
				_nagged_restart_backend_for_key = true
			_nagged_no_backend_api_key = false
		else:
			if not _nagged_no_backend_api_key:
				_log_warn(
					"Backend online but no API key detected — add it in Settings or the setup wizard, "
					+ "or set GEMINI_API_KEY before starting the backend."
				)
				_nagged_no_backend_api_key = true
			_nagged_restart_backend_for_key = false
	else:
		_nagged_no_backend_api_key = false
		_nagged_restart_backend_for_key = false
		_status_dot.color = Color(0.6, 0.2, 0.2)
		_status_label.text = "OFFLINE"
		_status_label.add_theme_color_override("font_color", Color(0.6, 0.3, 0.3))
		_backend_version_label.text = ""
		_set_thinking(false)

	_sync_backend_control_buttons()
	_update_health_timer_interval()


func _on_state_settings_changed() -> void:
	if _set_url and state:
		_set_url.text = str(state.settings.get("backend_url", state.backend_url))


func _on_plan_received(plan: Dictionary) -> void:
	_set_thinking(false)
	_tabs.current_tab = 1
	var display: Dictionary = _normalize_plan_payload(plan)
	if _plan_text:
		_plan_text.text = _format_plan_bbcode(display)
	if _plan_actions:
		_plan_actions.visible = not display.has("error") and str(display.get("summary", "")) != ""


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
	_is_thinking = active
	if _thinking_bar:
		_thinking_bar.visible = active
	if _thinking_label and active:
		_thinking_label.text = "GoDotter is thinking…"
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
	if not active and _is_thinking == false:
		pass


# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

func _log_user_input(text: String) -> void:
	if _chat_log:
		_chat_log.append_text("[color=#888]» [/color][color=#ccc]" + _esc(text) + "[/color]\n")


func _log_info(msg: String) -> void:
	if _chat_log:
		_chat_log.append_text("[color=#7fb3d3]" + msg + "[/color]\n")


func _log_warn(msg: String) -> void:
	if msg.contains("Health check failed"):
		var now: int = Time.get_ticks_msec()
		if now < _chat_health_warn_suppress_until_ms:
			return
		_chat_health_warn_suppress_until_ms = now + 16000
	if _chat_log:
		_chat_log.append_text("[color=#f39c12]⚠ " + msg + "[/color]\n")


func _log_error(msg: String) -> void:
	if _chat_log:
		_chat_log.append_text("[color=#e74c3c]✕ " + msg + "[/color]\n")


func _log_success(msg: String) -> void:
	if _chat_log:
		_chat_log.append_text("[color=#2ecc71]" + msg + "[/color]\n")


func _esc(text: String) -> String:
	return text.replace("[", "&#91;").replace("]", "&#93;")


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
		+ "or [b]Plan[/b] / [b]Execute[/b] for manual steps. Slash: [b]/agent[/b], [b]/plan[/b], [b]/help[/b].[/color]\n"
	)


func _help_text() -> String:
	return (
		"[b]Modes[/b] (dropdown): [b]Full agent[/b] (plan→validate→execute), Plan, Execute, …\n\n"
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
		+ "  [b]/fixlogs[/b]           — batch fix from run logs\n"
		+ "  [b]/memory[/b]            — view project memory\n"
		+ "  [b]/diff[/b]              — open Diff tab\n"
		+ "  [b]/settings[/b]          — open Settings tab\n"
		+ "  [b]/clear[/b]             — clear chat log"
	)


func _normalize_plan_payload(d: Dictionary) -> Dictionary:
	if d.is_empty():
		return {}
	var top_err := str(d.get("error", "")).strip_edges()
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
