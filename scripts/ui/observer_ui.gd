class_name ObserverUI
extends CanvasLayer
## Observer-only interface. Its CanvasLayer is outside every agent SubViewport.

signal run_toggled(running: bool)
signal step_requested
signal reset_requested
signal save_requested
signal load_requested
signal replay_requested
signal agent_selected(id: String)
signal view_toggled(first_person: bool)

const BG := Color("0d151e")
const PANEL := Color("15212c")
const EDGE := Color("2a3a47")
const TEXT := Color("dce8eb")
const MUTED := Color("91a8b7")
const ACCENT := Color("80dfc9")

var selected_agent: String = "ada"
var _running: bool = false
var _first_person: bool = false
var _world_view: Node
var _root: Control
var _run_button: Button
var _view_button: Button
var _tick_label: Label
var _status_label: Label
var _mode_badge_label: Label
var _ai_mode: String = "mock"
var _scene_label: Label
var _selected_label: Label
var _profile_label: Label
var _body_label: Label
var _inventory_label: Label
var _intent_label: Label
var _result_label: Label
var _memory_text: RichTextLabel
var _journal: RichTextLabel
var _camera_texture: TextureRect
var _agent_preview: TextureRect
var _hunger: ProgressBar
var _fatigue: ProgressBar
var _hunger_value: Label
var _fatigue_value: Label
var _agent_buttons: Dictionary = {}
var _last_events: String = ""

func setup(world_view: Node = null) -> void:
	_world_view = world_view
	_root = Control.new()
	_root.name = "ObserverDashboard"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var background := ColorRect.new()
	background.color = BG
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(background)
	var theme := Theme.new()
	theme.default_font_size = 15
	theme.set_color("font_color", "Label", TEXT)
	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", ACCENT)
	theme.set_stylebox("normal", "Button", _style(Color("20313e"), EDGE, 6, 12))
	theme.set_stylebox("hover", "Button", _style(Color("2d4352"), Color("66818f"), 6, 12))
	theme.set_stylebox("pressed", "Button", _style(Color("264c49"), ACCENT, 6, 12))
	theme.set_stylebox("focus", "Button", _style(Color(0, 0, 0, 0), ACCENT, 6, 12))
	theme.set_stylebox("disabled", "Button", _style(Color("17232d"), Color("23343e"), 6, 12))
	theme.set_color("font_disabled_color", "Button", Color("5d727e"))
	theme.set_color("default_color", "RichTextLabel", TEXT)
	theme.set_stylebox("background", "ProgressBar", _style(Color("263743"), Color("263743"), 3, 0))
	theme.set_stylebox("fill", "ProgressBar", _style(ACCENT, ACCENT, 3, 0))
	_root.theme = theme
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 15)
	_root.add_child(margin)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 13)
	margin.add_child(layout)
	_build_header(layout)
	_build_toolbar(layout)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	layout.add_child(body)
	_build_scene_panel(body)
	_build_inspector(body)
	_build_journal(layout)
	_build_footer(layout)
	set_running(false)
	if is_instance_valid(_world_view):
		set_camera_texture(_world_view.get_observer_texture())

func set_camera_texture(texture: Texture2D) -> void:
	if is_instance_valid(_camera_texture):
		_camera_texture.texture = texture

func set_running(running: bool) -> void:
	_running = running
	if is_instance_valid(_run_button):
		_run_button.text = "Pause" if running else "Run simulation"

func set_status(text: String) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = text

func set_ai_mode(mode: String) -> void:
	_ai_mode = mode
	if is_instance_valid(_mode_badge_label):
		_mode_badge_label.text = "MOCK AI  /  OFFLINE" if mode.to_lower() == "mock" else "REAL VLM  /  ROUTERAI"

func select_agent(id: String) -> void:
	selected_agent = id
	for agent_id in _agent_buttons:
		_agent_buttons[agent_id].button_pressed = agent_id == id
	if is_instance_valid(_world_view) and is_instance_valid(_agent_preview):
		_agent_preview.texture = _world_view.get_agent_texture(id)

func set_view_mode(value: bool) -> void:
	_first_person = value
	if is_instance_valid(_view_button):
		_view_button.text = "Observer view" if value else "Agent view"

func refresh(state: Dictionary, runtime_debug: Dictionary, events: Array) -> void:
	if not is_instance_valid(_root):
		return
	_tick_label.text = "STEP %03d   /   %s" % [int(state.get("tick", 0)), _time_text(int(state.get("elapsed_minutes", 0)))]
	var agents: Dictionary = state.get("agents", {})
	if not agents.has(selected_agent):
		return
	var agent: Dictionary = agents[selected_agent]
	var color := Color.from_string(str(agent.get("color", "80dfc9")), ACCENT)
	_selected_label.text = str(agent.get("name", selected_agent))
	_selected_label.add_theme_color_override("font_color", color.lightened(0.15))
	var profile: Dictionary = agent.get("profile", {})
	var traits: Array = profile.get("traits", [])
	_profile_label.text = str(profile.get("foundation", "")) + ("\n" + ", ".join(traits) if not traits.is_empty() else "")
	var needs: Dictionary = agent.get("needs", {})
	var hunger: float = float(needs.get("hunger", 0))
	var fatigue: float = float(needs.get("fatigue", 0))
	_hunger.value = hunger
	_fatigue.value = fatigue
	_hunger_value.text = "%d%%" % roundi(hunger)
	_fatigue_value.text = "%d%%" % roundi(fatigue)
	var body: Dictionary = agent.get("body", {})
	var limitations: Array[String] = []
	if body.get("blind", false):
		limitations.append("Blind")
	for limb in ["left_arm", "right_arm", "left_leg", "right_leg"]:
		if body.get(limb, "healthy") != "healthy":
			limitations.append(str(limb).replace("_", " ") + ": " + str(body[limb]))
	_body_label.text = "Healthy · sight available" if limitations.is_empty() else " · ".join(limitations)
	var inventory_names: Array[String] = []
	for item_id in agent.get("inventory", []):
		var item: Dictionary = state.get("items", {}).get(item_id, {})
		inventory_names.append(str(item.get("label", item_id)))
	_inventory_label.text = "Empty" if inventory_names.is_empty() else "\n".join(inventory_names)
	var action: Dictionary = agent.get("last_action", {})
	_intent_label.text = _action_text(action)
	var result: Dictionary = agent.get("last_result", {})
	_result_label.text = str(result.get("message", result.get("reason", "Waiting for the first step.")))
	_result_label.add_theme_color_override("font_color", ACCENT if bool(result.get("ok", true)) else Color("efb47d"))
	var debug: Dictionary = runtime_debug.get(selected_agent, {})
	var memory: Array = debug.get("memory", debug.get("recent", []))
	var memory_lines: Array[String] = []
	for entry in memory.slice(maxi(0, memory.size() - 5)):
		memory_lines.append(_memory_entry_text(entry))
	if memory_lines.is_empty():
		_memory_text.text = "No personal observations recorded yet."
	else:
		_memory_text.text = "\n\n".join(memory_lines)
	for id in _agent_buttons:
		var button: Button = _agent_buttons[id]
		button.button_pressed = id == selected_agent
	if is_instance_valid(_world_view):
		_agent_preview.texture = _world_view.get_agent_texture(selected_agent)
		set_camera_texture(_world_view.get_current_texture())
	_scene_label.text = (str(agent.get("name", "Agent")) + " / FIRST-PERSON") if _first_person else "CLOSED BLOCK / OBSERVER"
	_update_events(events)

func _build_header(parent: VBoxContainer) -> void:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 18)
	parent.add_child(header)
	var brand := _label("AI SIMS", 27, TEXT)
	header.add_child(brand)
	var divider := VSeparator.new()
	header.add_child(divider)
	var subtitle := _label("CLOSED BLOCK\nAutonomous agents · shared world", 13, MUTED)
	header.add_child(subtitle)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", _style(Color("163c37"), Color("2d675a"), 6, 11))
	header.add_child(badge)
	_mode_badge_label = _label("", 12, ACCENT)
	badge.add_child(_mode_badge_label)
	set_ai_mode(_ai_mode)
	header.add_child(_label("ENGINE 01\nVERTICAL SLICE", 11, MUTED))

func _build_toolbar(parent: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(PANEL, EDGE, 8, 11))
	parent.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)
	panel.add_child(row)
	_run_button = _button("Run simulation", row, func() -> void: run_toggled.emit(not _running))
	_run_button.custom_minimum_size.x = 145
	_button("Step  +1", row, func() -> void: step_requested.emit())
	_button("Reset", row, func() -> void: reset_requested.emit())
	row.add_child(VSeparator.new())
	_button("Save", row, func() -> void: save_requested.emit())
	_button("Load", row, func() -> void: load_requested.emit())
	_button("Replay", row, func() -> void: replay_requested.emit())
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_tick_label = _label("STEP 000   /   DAY 1 · 00:00", 14, ACCENT)
	row.add_child(_tick_label)

func _build_scene_panel(parent: HBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _style(PANEL, EDGE, 8, 14))
	parent.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 11)
	panel.add_child(column)
	var title_row := HBoxContainer.new()
	column.add_child(title_row)
	_scene_label = _label("CLOSED BLOCK / OBSERVER", 12, MUTED)
	_scene_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_scene_label)
	_view_button = _button("Agent view", title_row, _toggle_view)
	_view_button.custom_minimum_size.x = 120
	var view_back := PanelContainer.new()
	view_back.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view_back.add_theme_stylebox_override("panel", _style(Color("16232e"), Color("253745"), 6, 0))
	column.add_child(view_back)
	_camera_texture = TextureRect.new()
	_camera_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_camera_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_camera_texture.custom_minimum_size = Vector2(450, 280)
	_camera_texture.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_camera_texture.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view_back.add_child(_camera_texture)
	var selector_row := HBoxContainer.new()
	selector_row.add_theme_constant_override("separation", 10)
	column.add_child(selector_row)
	selector_row.add_child(_label("FOLLOW", 11, MUTED))
	for info in [["ada", "Ada", "e6ae55"], ["boris", "Boris", "65b6d6"], ["cora", "Cora", "c191cf"]]:
		var id: String = info[0]
		var button := _button(str(info[1]), selector_row, func() -> void: _select_agent(id))
		button.toggle_mode = true
		button.custom_minimum_size.x = 96
		button.add_theme_color_override("font_color", Color(str(info[2])))
		_agent_buttons[id] = button
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	selector_row.add_child(spacer)
	selector_row.add_child(_label("3 AGENTS · 3 CAMERAS", 11, MUTED))

func _build_inspector(parent: HBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 320
	panel.add_theme_stylebox_override("panel", _style(PANEL, EDGE, 8, 16))
	parent.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 8)
	scroll.add_child(column)
	column.add_child(_label("AGENT INSPECTOR", 11, MUTED))
	_selected_label = _label("Ada", 26, Color("e6ae55"))
	column.add_child(_selected_label)
	_profile_label = _label("", 13, TEXT)
	_profile_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_profile_label)
	column.add_child(HSeparator.new())
	_body_label = _label("Healthy · sight available", 12, MUTED)
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_body_label)
	var hunger_row := _need_row(column, "Hunger")
	_hunger = hunger_row.bar
	_hunger_value = hunger_row.value_label
	var fatigue_row := _need_row(column, "Fatigue")
	_fatigue = fatigue_row.bar
	_fatigue_value = fatigue_row.value_label
	column.add_child(_label("LIVE PERSONAL CAMERA", 11, MUTED))
	_agent_preview = TextureRect.new()
	_agent_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_agent_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_agent_preview.custom_minimum_size = Vector2(274, 156)
	column.add_child(_agent_preview)
	column.add_child(_label("INVENTORY", 11, MUTED))
	_inventory_label = _label("Empty", 13, TEXT)
	_inventory_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_inventory_label)
	column.add_child(_label("LATEST INTENT → RESULT", 11, MUTED))
	_intent_label = _label("Waiting for the first step", 13, TEXT)
	_intent_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_intent_label)
	_result_label = _label("", 13, ACCENT)
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_result_label)
	column.add_child(_label("PERSONAL MEMORY", 11, MUTED))
	_memory_text = RichTextLabel.new()
	_memory_text.fit_content = true
	_memory_text.scroll_active = false
	_memory_text.custom_minimum_size.y = 72
	_memory_text.add_theme_font_size_override("normal_font_size", 12)
	column.add_child(_memory_text)

func _build_journal(parent: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 172
	panel.add_theme_stylebox_override("panel", _style(PANEL, EDGE, 8, 13))
	parent.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	panel.add_child(column)
	var row := HBoxContainer.new()
	column.add_child(row)
	row.add_child(_label("WORLD EVENT JOURNAL", 11, MUTED))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(_label("Observer access · not sent to agents", 11, MUTED))
	_journal = RichTextLabel.new()
	_journal.bbcode_enabled = true
	_journal.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_journal.scroll_following = true
	_journal.selection_enabled = true
	_journal.add_theme_font_size_override("normal_font_size", 13)
	column.add_child(_journal)
	_journal.text = "[color=#91a8b7]World ready. Run the simulation or advance one step.[/color]"

func _build_footer(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	_status_label = _label("Paused · deterministic mock policies · no API requests", 12, ACCENT)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_status_label)
	row.add_child(_label("SPACE run/pause   N step   1–3 select   TAB view   R reset", 11, MUTED))

func _update_events(events: Array) -> void:
	var lines: Array[String] = []
	for event in events.slice(maxi(0, events.size() - 100)):
		if not event is Dictionary:
			continue
		var color: String = "91a8b7" if bool(event.get("ok", true)) else "efb47d"
		var actor: String = str(event.get("actor", "world")).capitalize()
		var message: String = str(event.get("message", "")).replace("[", "［").replace("]", "］")
		lines.append("[color=#627f91]%03d[/color]  [color=#%s]%-6s[/color]  %s" % [int(event.get("tick", 0)), color, actor, message])
	var value: String = "\n".join(lines)
	if value != _last_events:
		_last_events = value
		_journal.text = value if not value.is_empty() else "[color=#91a8b7]World ready. Run the simulation or advance one step.[/color]"

func _select_agent(id: String) -> void:
	select_agent(id)
	agent_selected.emit(id)

func _toggle_view() -> void:
	set_view_mode(not _first_person)
	view_toggled.emit(_first_person)

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_SPACE:
			run_toggled.emit(not _running)
		KEY_N:
			step_requested.emit()
		KEY_R:
			reset_requested.emit()
		KEY_1:
			_select_agent("ada")
		KEY_2:
			_select_agent("boris")
		KEY_3:
			_select_agent("cora")
		KEY_TAB:
			_toggle_view()
		_:
			return
	get_viewport().set_input_as_handled()

func _action_text(action: Dictionary) -> String:
	if action.is_empty():
		return "Waiting for the first step"
	var type: String = str(action.get("type", "wait"))
	match type:
		"speak":
			return "Speak: “%s”" % str(action.get("text", ""))
		"move":
			return "Move · forward %.1f / right %.1f" % [float(action.get("forward", 0)), float(action.get("right", 0))]
		"turn":
			return "Turn %.0f°" % float(action.get("degrees", 0))
		"give", "put":
			return "%s · inventory slot %d" % [type.capitalize(), int(action.get("slot", 0))]
	return type.capitalize()

func _memory_entry_text(entry: Variant) -> String:
	if entry is Dictionary:
		var tick: int = int(entry.get("tick", entry.get("observation", {}).get("tick", 0)))
		var observation: Dictionary = entry.get("observation", entry.get("context", entry))
		var result: Dictionary = observation.get("last_result", {})
		var message: String = str(result.get("message", result.get("reason", "Observed the surroundings.")))
		var heard: Array = observation.get("heard", [])
		if not heard.is_empty():
			message = "Heard: " + str(heard.back().get("text", ""))
		return "Step %03d · %s" % [tick, message]
	return str(entry).left(160)

func _time_text(minutes: int) -> String:
	var day: int = floori(float(minutes) / 1440.0) + 1
	var hour: int = floori(float(minutes % 1440) / 60.0)
	return "DAY %d · %02d:%02d" % [day, hour, minutes % 60]

func _need_row(parent: VBoxContainer, title: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)
	parent.add_child(row)
	var label := _label(title, 12, MUTED)
	label.custom_minimum_size.x = 57
	row.add_child(label)
	var bar := ProgressBar.new()
	bar.custom_minimum_size.y = 5
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.show_percentage = false
	bar.max_value = 100
	row.add_child(bar)
	var value_label := _label("0%", 12, TEXT)
	value_label.custom_minimum_size.x = 34
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)
	return {"bar": bar, "value_label": value_label}

func _button(title: String, parent: Container, callback: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.custom_minimum_size.y = 33
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label

func _style(background: Color, border: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = margin
	style.content_margin_bottom = margin
	return style
