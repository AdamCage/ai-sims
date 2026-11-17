extends CanvasLayer
## Player-facing menus and observer tools. No UI node is inside an agent viewport.

signal command(name: String, payload: Dictionary)

const Catalog = preload("res://scripts/game/action_catalog.gd")
const Spatial = preload("res://scripts/game/spatial_rules.gd")
const INK := Color("142330")
const CREAM := Color("f4efdf")
const CORAL := Color("ee947f")
const SAGE := Color("9fcbb5")
const MUTED := Color("b1c1c8")
const TEXT := Color("f4efdf")
const GOLD := Color("e1bd78")
const GREEN := Color("8ac4b0")
const MAP_IDS := ["closed_block","residence","research_station"]
const MAP_RU := ["Закрытый блок","Жилой комплекс","Исследовательская станция"]
const MAP_EN := ["Closed Block","Residence","Research Station"]

var language := "ru"
var selected_agent := ""
var _world: Node
var _root: Control
var _state: Dictionary = {}
var _debug: Dictionary = {}
var _info: Dictionary = {}
var _running := false
var _first_person := false
var _menu_visible := true
var _rebuilding := false
var _agent_buttons: Dictionary = {}
var _agent_rows: VBoxContainer
var _central: TextureRect
var _eye_preview: TextureRect
var _status: Label
var _time: Label
var _mode: Label
var _connection_status: Label
var _run: Button
var _name: Label
var _life_text: RichTextLabel
var _relations: RichTextLabel
var _memory: RichTextLabel
var _device: RichTextLabel
var _truth: RichTextLabel
var _journal: RichTextLabel
var _health: ProgressBar
var _hunger: ProgressBar
var _fatigue: ProgressBar
var _tabs: TabContainer
var _menu: PanelContainer
var _new_popup: PopupPanel
var _settings_popup: PopupPanel
var _appearance_popup: PopupPanel
var _god_popup: PopupPanel
var _help_popup: PopupPanel
var _map_choice: OptionButton
var _scenario_choice: OptionButton
var _count: SpinBox
var _seed: SpinBox
var _slot: OptionButton
var _target: OptionButton
var _inventory_slot: OptionButton
var _speech: LineEdit
var _app: OptionButton
var _contact: OptionButton
var _message_id: OptionButton
var _topic_id: OptionButton
var _poll_id: OptionButton
var _page_id: OptionButton
var _device_text: TextEdit
var _device_title: LineEdit
var _game_grid: GridContainer
var _game_buttons: Array = []
var _game_state: Label
var _message_cards: VBoxContainer
var _offer_choice: OptionButton
var _device_panels: Dictionary = {}
var _screen_data: Dictionary = {}
var _screen_signature := ""
var _poll_options: VBoxContainer
var _api_key: LineEdit
var _model: LineEdit
var _budget: SpinBox
var _live: CheckButton
var _quality: OptionButton
var _language_choice: OptionButton
var _speed: SpinBox
var _sfx: SpinBox
var _gallery_image: TextureRect
var _last_gallery_ref := ""
var _appearance_controls: Dictionary = {}
var _god_controls: Dictionary = {}
var _event_filter: OptionButton
var _last_journal_signature := ""
var _drawer: Control
var _roster_panel: Control
var _journal_panel: Control
var _roster_toggle: Button
var _journal_toggle: Button
var _person_card: Button
var _toast: Label
var _phone_popup: PopupPanel
var _hud_controls: Array = []
var _device_slot: OptionButton
var _photo_slot: OptionButton
var _attachment_photo: OptionButton
var _photo_target: OptionButton
var _photo_actions: Array=[]
var _photo_actor: String=""
var _modal_backdrop: ColorRect
var _preset_choice: OptionButton
var _trace_message: OptionButton
var _trace_view: RichTextLabel
var _character_preview: TextureRect
var _group_popup: PopupPanel
var _group_name: LineEdit
var _group_members: ItemList
var _group_note: Label
var _available_contacts: Array=[]
var _pending_app_choice: String=""
var _device_actor: String=""
var _scenario_title: Label
var _problem: Label
var _phase_label: Label
var _activity: Label
var _intent: Label
var _obstacle: Label
var _portrait_image: TextureRect
var _activity_progress: ProgressBar
var _journal_rows: VBoxContainer
var _event_search: LineEdit
var _live_events: VBoxContainer
var _event_lookup: Dictionary={}
const JOURNAL_PAGE_SIZE:=40
var _journal_page:=0
var _older_events:Button
var _newer_events:Button
var _page_number:Label
var _journal_selection:HBoxContainer
var _selection_details:Label
var _show_event_place:Button
var _selected_event:Dictionary={}
var _event_group:ButtonGroup
var _district_choice: OptionButton
var _district_signature: String=""
var _chapter_popup: PopupPanel
var _chapter_title: Label
var _chapter_text: RichTextLabel
var _chapter_continue: Button
var _intervention_box: VBoxContainer
var _seen_chapter: String=""
var _replacing_run:=-1
var _debrief_key: String=""
var _last_status: String=""
var _map_cards: Array=[]
var _story_description: Label
var _portrait_signature: String=""
var _phone_apps: Array=[]
var _effective_speed: Label
var _phone_app_heading: Label
var _web_connect_button: Button
var _detail_popup: PopupPanel
var _card_activity: Dictionary={}
var _continue_save:Button
var _retry_decision:Button


func setup(world: Node) -> void:
	_world=world
	get_viewport().gui_embed_subwindows=true
	if is_instance_valid(_root): _root.queue_free()
	_agent_buttons.clear()
	_screen_signature=""; _last_journal_signature="";_portrait_signature="";_district_signature=""
	_root=Control.new(); _root.name="PlayerInterface"; _root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	_root.theme=_theme()
	_build_immersive_hud()
	_modal_backdrop=ColorRect.new();_modal_backdrop.color=Color(0.02,0.04,0.05,0.48);_modal_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);_root.add_child(_modal_backdrop);_modal_backdrop.hide()
	_build_new_dialog(); _build_settings_dialog(); _build_appearance_dialog(); _build_god_dialog(); _build_help_dialog(); _build_phone_dialog(); _build_group_dialog(); _build_chapter_dialog(); _build_map_dialog(); _build_main_menu()
	if is_instance_valid(_world) and _world.has_signal("agent_picked") and not _world.agent_picked.is_connected(_pick_person): _world.agent_picked.connect(_pick_person)
	if _world.has_signal("portrait_ready") and not _world.portrait_ready.is_connected(_portrait_ready):_world.portrait_ready.connect(_portrait_ready)
	set_running(_running)
	show_main_menu(_menu_visible)
	if not _state.is_empty(): refresh(_state,_debug,_info)

func refresh(state: Dictionary, debug: Dictionary, session_info: Dictionary) -> void:
	var previous_run:int=int(_state.get("run_id",-1))
	_state=state
	_debug=debug
	_info=session_info
	if not is_instance_valid(_root): return
	if previous_run>=0 and previous_run!=int(state.get("run_id",previous_run)):
		for child in _root.get_children():
			if child is PopupPanel and child.visible:child.hide()
		if is_instance_valid(_world):_world.suspend_character_preview()
		_screen_signature="";_last_gallery_ref="";_last_journal_signature="";_seen_chapter="";_debrief_key="";_journal_page=0
		_selected_event={};_journal_selection.hide()
	var agents: Dictionary=state.get("agents",{})
	if agents.has(str(session_info.get("selected",""))): selected_agent=str(session_info.selected)
	if selected_agent.is_empty() or not agents.has(selected_agent): selected_agent=str(agents.keys()[0]) if not agents.is_empty() else ""
	if _agent_buttons.size()!=agents.size(): _rebuild_roster(agents)
	var minute: float=float(state.get("minute",0))+float(state.get("scenario_state",{}).get("display_start_minute",state.get("display_start_minute",0)))
	_time.text=_t("ДЕНЬ %d  ·  %02d:%02d","DAY %d  ·  %02d:%02d") % [int(minute/1440.0)+1,int(fmod(minute,1440.0)/60.0),int(fmod(minute,60.0))]
	for id in _agent_buttons:
		if not agents.has(id): continue
		var a: Dictionary=agents[id]
		_agent_buttons[id].text=str(a.get("name",id))+"\n"+_t("Здоровье %d · голод %d","Health %d · hunger %d") % [roundi(float(a.get("health",100))),roundi(float(a.get("needs",{}).get("hunger",0)))]
		_agent_buttons[id].button_pressed=id==selected_agent
	_roster_toggle.text=_t("Люди\n%d","People\n%d")%agents.size()
	if agents.has(selected_agent): _refresh_person(agents[selected_agent])
	if is_instance_valid(_world):
		_first_person=bool(_world.first_person)
		_central.texture=_world.current_texture()
		_eye_preview.texture=_world.agent_texture(selected_agent)
	_refresh_journal(state.get("events",[]))
	set_connection_state(session_info.get("connection",{}))
	_continue_save.visible=session_info.get("slots",[]).any(func(slot):return int(slot.get("slot",0))==3 and bool(slot.get("exists",false)))
	_refresh_alpha_state()
	_refresh_chapter()

func set_status(text: String) -> void:
	_last_status=text
	if is_instance_valid(_status): _status.text=text
	if is_instance_valid(_connection_status) and is_instance_valid(_settings_popup) and _settings_popup.visible: _connection_status.text=text

func set_running(value: bool) -> void:
	_running=value
	if is_instance_valid(_run): _run.text=_t("Пауза","Pause") if value else _t("Продолжить","Continue")

func set_connection_state(info: Dictionary) -> void:
	if not is_instance_valid(_mode): return
	var live: bool=bool(info.get("enabled",false)) or (info.get("mode","")=="real_vlm" and info.get("has_key",false))
	var cost: float=float(info.get("spent_rub",info.get("budget",{}).get("spent_rub",info.get("spent",0))))
	_mode.text=("RouterAI · %.2f RUB" % cost) if live else _t("Демонстрация · без сети","Demo · offline")
	_mode.add_theme_color_override("font_color",GREEN if live else GOLD)
	if is_instance_valid(_connection_status):
		var budget_info: Dictionary=info.get("budget",{})
		_connection_status.text=(_t("Подключено · израсходовано %.2f руб. · осталось %.2f руб.","Connected · spent %.2f RUB · remaining %.2f RUB")%[cost,float(budget_info.get("remaining_rub",0))]) if live else _t("Реальные AI-вызовы выключены.","Real AI requests are disabled.")

func show_main_menu(value: bool=true) -> void:
	_menu_visible=value
	if is_instance_valid(_menu): _menu.visible=value
	for control in _hud_controls:
		if is_instance_valid(control): control.visible=not value
	if value:
		if is_instance_valid(_drawer): _drawer.hide()
		if is_instance_valid(_roster_panel): _roster_panel.hide()
		if is_instance_valid(_journal_panel): _journal_panel.hide()

func select_agent(id: String) -> void:
	if not _state.is_empty() and not _state.get("agents",{}).has(id):return
	selected_agent=id
	if is_instance_valid(_world): _world.select_agent(id)

func _pick_person(id: String) -> void:
	select_agent(id); command.emit("select",{"id":id}); _drawer.show(); _roster_panel.hide()

func _show_phone() -> void:
	_phone_popup.popup_centered_clamped(Vector2i(760,800),0.92)

func _build_immersive_hud() -> void:
	_hud_controls.clear()
	var background:=ColorRect.new(); background.color=INK; background.mouse_filter=Control.MOUSE_FILTER_IGNORE; background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); _root.add_child(background)
	_central=TextureRect.new(); _central.name="WorldCanvas"; _central.expand_mode=TextureRect.EXPAND_IGNORE_SIZE; _central.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_place(_central,0,0,1,1,Vector4(88,132,-382,-182)); _root.add_child(_central)
	_central.gui_input.connect(func(event): if is_instance_valid(_world): _world.handle_view_input(event,_central.size))
	_central.resized.connect(_resize_canvas)
	_resize_canvas.call_deferred()
	var top:=PanelContainer.new(); top.name="SituationHeader"; _place(top,0,0,1,0,Vector4(16,14,-16,120)); top.add_theme_stylebox_override("panel",_style(Color("1d3342"),Color("385262"),20,16)); _root.add_child(top); _hud_controls.append(top)
	var header:=VBoxContainer.new(); header.add_theme_constant_override("separation",9); top.add_child(header)
	var row:=HBoxContainer.new(); row.add_theme_constant_override("separation",18); header.add_child(row)
	_label(row,"AI SIMS",24,CREAM)
	_scenario_title=_label(row,_t("Жизни под наблюдением","Lives under observation"),18,SAGE); _scenario_title.size_flags_horizontal=Control.SIZE_EXPAND_FILL; _scenario_title.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
	_time=_label(row,"08:00",16,TEXT)
	_mode=_label(row,"",14,SAGE)
	_button(row,_t("Меню","Menu"),func():show_main_menu(true))
	var situation:=HBoxContainer.new(); situation.add_theme_constant_override("separation",18); header.add_child(situation)
	_phase_label=_label(situation,_t("ГЛАВА 1 / 3","CHAPTER 1 / 3"),14,CORAL)
	_phase_label.mouse_filter=Control.MOUSE_FILTER_STOP
	_phase_label.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
	_phase_label.tooltip_text=_t("Открыть главу и вмешательства","Open chapter and interventions")
	_phase_label.gui_input.connect(func(event):
		var story:Dictionary=_state.get("scenario_state",{})
		if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and event.pressed and not story.is_empty():_show_chapter(story,bool(story.get("completed",false))))
	_problem=_label(situation,_t("Выберите историю и узнайте её участников.","Choose a story and meet its people."),15,TEXT); _problem.size_flags_horizontal=Control.SIZE_EXPAND_FILL; _problem.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
	var rail:=VBoxContainer.new(); rail.name="NavigationRail"; rail.add_theme_constant_override("separation",10); _place(rail,0,0,0,1,Vector4(16,134,80,-182)); _root.add_child(rail); _hud_controls.append(rail)
	_roster_toggle=_button(rail,_t("Люди","People"),func():_roster_panel.visible=not _roster_panel.visible); _roster_toggle.tooltip_text=_t("Участники истории","Story participants")
	_button(rail,_t("Карта","Map"),_show_map_navigation)
	_button(rail,_t("Вид","View"),_toggle_view).tooltip_text=_t("V · Общий вид / глазами персонажа","V · Observer / person's eyes")
	_button(rail,_t("Фокус","Focus"),func():if is_instance_valid(_world):_world.focus_agent()).tooltip_text=_t("F · Следить за выбранным","F · Follow selected person")
	_button(rail,_t("Мир","World"),_open_god)
	var rail_space:=Control.new(); rail_space.size_flags_vertical=Control.SIZE_EXPAND_FILL; rail.add_child(rail_space)
	_button(rail,"?",func():_help_popup.popup_centered_clamped(Vector2i(800,680),0.92))
	_button(rail,_t("Опции","Options"),show_settings)
	_roster_panel=HBoxContainer.new(); _roster_panel.name="PeopleDrawer"; _place(_roster_panel,0,0,0,1,Vector4(88,134,344,-182)); _root.add_child(_roster_panel); _build_roster(_roster_panel); _roster_panel.hide()
	_drawer=HBoxContainer.new(); _drawer.name="SelectedPerson"; _place(_drawer,1,0,1,1,Vector4(-370,134,-16,-182)); _root.add_child(_drawer); _build_inspector(_drawer); _hud_controls.append(_drawer)
	var transport:=PanelContainer.new(); transport.name="LiveChronicle"; _place(transport,0,1,1,1,Vector4(16,-170,-16,-14)); transport.add_theme_stylebox_override("panel",_style(Color("1d3342"),Color("385262"),18,12)); _root.add_child(transport); _hud_controls.append(transport)
	var bottom:=VBoxContainer.new(); bottom.add_theme_constant_override("separation",8); transport.add_child(bottom)
	var controls:=HBoxContainer.new(); controls.add_theme_constant_override("separation",8); bottom.add_child(controls)
	_run=_button(controls,"",func():command.emit("run",{"value":not _running})); _run.custom_minimum_size.x=146; _run.add_theme_stylebox_override("normal",_style(SAGE,SAGE,10,10)); _run.add_theme_color_override("font_color",INK)
	_button(controls,_t("Шаг","Step"),func():command.emit("step",{})).tooltip_text="N"
	var speed:=OptionButton.new(); controls.add_child(speed)
	for value in [0.5,1.0,2.0]:speed.add_item("%.1f×"%value);speed.set_item_metadata(speed.item_count-1,value)
	speed.select(1);speed.item_selected.connect(func(index):command.emit("settings",{"speed":float(speed.get_item_metadata(index))}))
	_effective_speed=_label(controls,"",14,MUTED); _effective_speed.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	_status=_label(controls,"",14,CREAM);_status.size_flags_horizontal=Control.SIZE_EXPAND_FILL;_status.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
	_slot=OptionButton.new();_slot.hide();controls.add_child(_slot)
	for index in 3:_slot.add_item(str(index+1),index)
	var saves:=MenuButton.new();saves.text=_t("Сохранения","Saves");controls.add_child(saves)
	for index in 3:saves.get_popup().add_item(_t("Сохранить · слот %d","Save · slot %d")%(index+1),index+1)
	saves.get_popup().add_separator()
	for index in 3:saves.get_popup().add_item(_t("Загрузить · слот %d","Load · slot %d")%(index+1),index+11)
	if OS.has_feature("web"):
		saves.get_popup().add_separator();saves.get_popup().add_item(_t("Экспорт резервной копии","Export backup"),30);saves.get_popup().add_item(_t("Импорт резервной копии","Import backup"),31)
	saves.get_popup().id_pressed.connect(func(id):
		if id==30:command.emit("export_backup",{})
		elif id==31:command.emit("import_backup",{})
		else:command.emit("save" if id<10 else "load",{"slot":id if id<10 else id-10}))
	_button(controls,_t("Повтор","Replay"),func():command.emit("replay",{}))
	_journal_toggle=_button(controls,_t("Вся хроника","Full chronicle"),func():_journal_panel.visible=not _journal_panel.visible)
	_live_events=VBoxContainer.new(); _live_events.name="RecentEvents"; _live_events.add_theme_constant_override("separation",2);bottom.add_child(_live_events)
	_journal_panel=VBoxContainer.new();_journal_panel.name="ChronicleDrawer";_place(_journal_panel,0,0,1,1,Vector4(88,134,-382,-182));_root.add_child(_journal_panel);_build_journal(_journal_panel);_journal_panel.hide()
	_journal_panel.visibility_changed.connect(func():
		if _journal_panel.is_visible_in_tree():_set_journal_page(0))
	_toast=Label.new();_toast.hide();_root.add_child(_toast)

func _build_phone_dialog() -> void:
	var content:=_dialog(_t("Личный телефон","Personal phone"));_phone_popup=content.popup
	_phone_app_heading=_wrapped_label(content.box,_t("Приложения, разговоры и личные воспоминания.","Apps, conversations and personal memories."),16,SAGE)
	_build_device_tab(content.box)

func _place(control: Control, left: float, top: float, right: float, bottom: float, offsets: Vector4) -> void:
	control.anchor_left=left; control.anchor_top=top; control.anchor_right=right; control.anchor_bottom=bottom
	control.offset_left=offsets.x; control.offset_top=offsets.y; control.offset_right=offsets.z; control.offset_bottom=offsets.w

func set_first_person(value: bool) -> void:
	_first_person=value
	if is_instance_valid(_world): _world.set_first_person(value)
	if is_instance_valid(_central) and is_instance_valid(_world): _central.texture=_world.current_texture()

func set_language(value: String) -> void:
	if value in ["ru","en"] and value!=language:
		language=value
		setup.call_deferred(_world)

func show_settings() -> void:
	_live.button_pressed=_info.get("mode","")=="real_vlm"
	_model.text=str(_info.get("settings",{}).get("model",_model.text))
	_budget.value=float(_info.get("settings",{}).get("budget",_budget.value))
	_speed.value=float(_info.get("settings",{}).get("speed",_speed.value))
	_sfx.value=float(_info.get("settings",{}).get("sfx_volume",0.5))
	_settings_popup.popup_centered_clamped(Vector2i(740,700),0.92)

func show_new_session() -> void:
	_new_popup.popup_centered_clamped(Vector2i(1000,730),0.92)

func _build_header(parent: VBoxContainer) -> void:
	var panel:=_panel(parent,Color("1b2a33"))
	var row:=HBoxContainer.new(); row.add_theme_constant_override("separation",12); panel.add_child(row)
	_label(row,"AI SIMS",26,TEXT)
	var name:=_label(row,_t("ЖИЗНИ ПОД НАБЛЮДЕНИЕМ","LIVES UNDER OBSERVATION"),11,MUTED); name.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	_mode=_label(row,_t("Демонстрация · без сети","Demo · offline"),13,GOLD)
	_time=_label(row,"",15,TEXT)
	_button(row,_t("Новая сессия","New session"),show_new_session)
	_button(row,_t("Настройки","Settings"),show_settings)
	_button(row,"?",func(): _help_popup.popup_centered(Vector2i(820,650)))
	_button(row,"☰",func(): show_main_menu(not _menu_visible))

func _build_roster(parent: HBoxContainer) -> void:
	var panel:=_panel(parent,Color("182730")); panel.custom_minimum_size.x=256
	var layout:=VBoxContainer.new(); layout.add_theme_constant_override("separation",10); panel.add_child(layout)
	_label(layout,_t("УЧАСТНИКИ ИСТОРИИ","STORY PARTICIPANTS"),14,SAGE)
	var scroll:=ScrollContainer.new(); scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL; scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED; layout.add_child(scroll)
	_agent_rows=VBoxContainer.new(); _agent_rows.size_flags_horizontal=Control.SIZE_EXPAND_FILL; _agent_rows.add_theme_constant_override("separation",7); scroll.add_child(_agent_rows)
	_button(layout,_t("Создать образ","Character editor"),_open_appearance)

func _build_world(parent: HBoxContainer) -> void:
	var layout:=VBoxContainer.new(); layout.size_flags_horizontal=Control.SIZE_EXPAND_FILL; layout.add_theme_constant_override("separation",8); parent.add_child(layout)
	var panel:=_panel(layout,Color("202e37")); panel.size_flags_vertical=Control.SIZE_EXPAND_FILL
	var inner:=VBoxContainer.new(); inner.add_theme_constant_override("separation",8); panel.add_child(inner)
	var top:=HBoxContainer.new(); inner.add_child(top)
	_label(top,_t("ОБЗОР МИРА","WORLD VIEW"),12,MUTED).size_flags_horizontal=Control.SIZE_EXPAND_FILL
	_button(top,_t("Следить","Follow"),func(): if is_instance_valid(_world): _world.focus_agent())
	_button(top,_t("Сменить вид","Switch view"),_toggle_view)
	_central=TextureRect.new(); _central.expand_mode=TextureRect.EXPAND_IGNORE_SIZE; _central.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED; _central.size_flags_horizontal=Control.SIZE_EXPAND_FILL; _central.size_flags_vertical=Control.SIZE_EXPAND_FILL; _central.custom_minimum_size=Vector2(400,300)
	inner.add_child(_central)
	_central.gui_input.connect(func(event): if is_instance_valid(_world): _world.handle_view_input(event,_central.size))
	_label(inner,_t("Колесо — масштаб · ПКМ — поворот · СКМ — перемещение","Wheel zoom · Right drag orbit · Middle drag pan"),11,MUTED)
	var controls:=HBoxContainer.new(); controls.add_theme_constant_override("separation",7); layout.add_child(controls)
	_run=_button(controls,"",func(): command.emit("run",{"value":not _running}))
	_button(controls,_t("Шаг","Step"),func(): command.emit("step",{}))
	var spacer:=Control.new(); spacer.size_flags_horizontal=Control.SIZE_EXPAND_FILL; controls.add_child(spacer)
	_slot=OptionButton.new(); controls.add_child(_slot)
	for index in 3: _slot.add_item(_t("Слот %d","Slot %d") % (index+1),index)
	_button(controls,_t("Сохранить","Save"),func(): command.emit("save",{"slot":_slot.selected+1}))
	_button(controls,_t("Загрузить","Load"),func(): command.emit("load",{"slot":_slot.selected+1}))
	_button(controls,_t("История","Replay"),func(): command.emit("replay",{}))

func _build_inspector(parent: HBoxContainer) -> void:
	var panel:=_panel(parent,Color("1d3342")); panel.custom_minimum_size.x=354; panel.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	var layout:=VBoxContainer.new(); layout.add_theme_constant_override("separation",9); panel.add_child(layout)
	var title:=HBoxContainer.new();layout.add_child(title)
	_name=_label(title,"",23,CREAM);_name.size_flags_horizontal=Control.SIZE_EXPAND_FILL;_name.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
	_button(title,_t("Образ","Style"),_open_appearance)
	var summary:=HBoxContainer.new();summary.add_theme_constant_override("separation",12);layout.add_child(summary)
	var portrait_panel:=_panel(summary,Color("304b55"));portrait_panel.custom_minimum_size=Vector2(96,120);portrait_panel.size_flags_vertical=Control.SIZE_SHRINK_BEGIN
	_portrait_image=TextureRect.new();_portrait_image.name="CharacterPortrait";_portrait_image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;_portrait_image.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_COVERED;portrait_panel.add_child(_portrait_image)
	var activity_box:=VBoxContainer.new();activity_box.size_flags_horizontal=Control.SIZE_EXPAND_FILL;summary.add_child(activity_box)
	_label(activity_box,_t("ПРЯМО СЕЙЧАС","RIGHT NOW"),14,SAGE)
	_activity=_wrapped_label(activity_box,"",16,CREAM)
	_intent=_wrapped_label(activity_box,"",14,MUTED)
	_intent.max_lines_visible=3;_intent.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
	_obstacle=_wrapped_label(layout,"",14,CORAL)
	_retry_decision=_button(layout,_t("Запросить новое решение","Request a new decision"),func():command.emit("retry_agent",{"id":selected_agent}));_retry_decision.hide()
	_activity_progress=ProgressBar.new();_activity_progress.custom_minimum_size.y=6;_activity_progress.show_percentage=false;layout.add_child(_activity_progress)
	var shortcuts:=HBoxContainer.new();layout.add_child(shortcuts)
	_button(shortcuts,_t("Телефон","Phone"),_show_phone).size_flags_horizontal=Control.SIZE_EXPAND_FILL
	_button(shortcuts,_t("Найти на карте","Find on map"),func():if is_instance_valid(_world):_world.focus_agent()).size_flags_horizontal=Control.SIZE_EXPAND_FILL
	_tabs=TabContainer.new();_tabs.size_flags_vertical=Control.SIZE_EXPAND_FILL;_tabs.add_theme_font_size_override("font_size",14);layout.add_child(_tabs)
	var life:=_tab(_t("Жизнь","Life"))
	_eye_preview=TextureRect.new(); _eye_preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE; _eye_preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED; _eye_preview.custom_minimum_size=Vector2(290,150); life.add_child(_eye_preview);_eye_preview.hide()
	_health=_bar(life,_t("Здоровье","Health"),Color("8fc8ad"))
	_hunger=_bar(life,_t("Голод","Hunger"),Color("d9b979"))
	_fatigue=_bar(life,_t("Усталость","Fatigue"),Color("a7add4"))
	_life_text=_rich(life,240)
	_button(life,_t("Личный телефон","Personal phone"),_show_phone)
	var actions_box:=VBoxContainer.new(); actions_box.add_theme_constant_override("separation",8)
	_button(life,_t("Поручить действие","Direct an action"),func():actions_box.visible=not actions_box.visible)
	life.add_child(actions_box); actions_box.hide()
	var quick:=GridContainer.new(); quick.columns=3; actions_box.add_child(quick)
	for entry in [["Осмотр","Look",{"type":"look"}],["Отдых","Rest",{"type":"rest","minutes":30.0}],["Сон","Sleep",{"type":"sleep","minutes":120.0}],["Проснуться","Wake",{"type":"wake"}],["Паёк","Ration",{"type":"request_ration"}],["Защита","Defend",{"type":"defend"}]]:
		var intention: Dictionary=entry[2]
		_button(quick,_t(entry[0],entry[1]),func(): _send_intent(intention))
	_label(actions_box,_t("Вещь в инвентаре","Inventory item"),12,MUTED)
	var inv:=HBoxContainer.new(); actions_box.add_child(inv)
	_inventory_slot=OptionButton.new(); _inventory_slot.size_flags_horizontal=Control.SIZE_EXPAND_FILL; inv.add_child(_inventory_slot)
	_button(inv,_t("Съесть","Consume"),func(): _send_intent({"type":"consume","slot":_slot_index()}))
	_button(inv,_t("Положить","Put down"),func(): _send_intent({"type":"put","slot":_slot_index()}))
	_label(actions_box,_t("Видимая цель персонажа","Character's perceived target"),12,MUTED)
	_target=OptionButton.new(); _target.size_flags_horizontal=Control.SIZE_EXPAND_FILL; actions_box.add_child(_target)
	var target_actions:=GridContainer.new(); target_actions.columns=3; actions_box.add_child(target_actions)
	for entry in [["Подойти","Go to","move_to"],["Взять","Take","take"],["Открыть","Open","open"],["Закрыть","Close","close"],["Помочь","Help","help"],["Атака","Attack","attack"]]:
		var kind: String=entry[2]
		_button(target_actions,_t(entry[0],entry[1]),func(): _send_target_intent(kind))
	_speech=LineEdit.new(); _speech.placeholder_text=_t("Сказать вслух…","Say something…"); actions_box.add_child(_speech)
	_speech.text_submitted.connect(func(_value): _speak())
	_button(actions_box,_t("Произнести","Speak"),_speak)
	var people:=_tab(_t("Люди","People")); _relations=_rich(people,350)
	_button(people,_t("Передать выбранную вещь","Give selected item"),func(): _send_target_intent("give",{"slot":_slot_index()}))
	_button(people,_t("Обменять на 2 жетона","Offer item for 2 tokens"),func(): _send_target_intent("offer",{"slot":_slot_index(),"request_tokens":2}))
	_offer_choice=OptionButton.new(); people.add_child(_offer_choice)
	_button(people,_t("Принять / подтвердить предложение","Accept / confirm offer"),func(): _send_intent({"type":"accept_offer","offer":_choice_ref(_offer_choice)}))
	_button(people,_t("Заявить об исполнении обещания","Claim promise fulfilled"),func(): _send_intent({"type":"fulfil_promise","offer":_choice_ref(_offer_choice)}))
	var memory:=_tab(_t("Память","Memory")); _memory=_rich(memory,440)
	_button(memory,_t("Сделать снимок","Take photo"),func(): _send_intent({"type":"take_photo","digital":true}))
	var diary:=LineEdit.new(); diary.placeholder_text=_t("Короткая запись в дневник","Short diary entry"); memory.add_child(diary)
	_button(memory,_t("Записать","Write diary"),func(): if not diary.text.strip_edges().is_empty(): _send_intent({"type":"write_diary","text":diary.text.strip_edges()}))
	var truth:=_tab(_t("Мир","World")); _truth=_rich(truth,380)
	_label(truth,_t("Версии сообщений · только наблюдателю","Message versions · observer only"),13,GOLD)
	_trace_message=OptionButton.new();truth.add_child(_trace_message);_trace_message.item_selected.connect(func(_index):_refresh_message_trace())
	_trace_view=_rich(truth,180)
	_button(truth,_t("Режим бога","God mode"),_open_god)
	_button(truth,_t("Восстановить здоровье","Restore health"),func(): _god("set_health",{"id":selected_agent,"health":100.0}))
	_button(truth,_t("Добавить паёк рядом","Spawn ration nearby"),func(): _god("spawn_item",{"kind":"ration","id":selected_agent}))

func _build_device_tab(parent: VBoxContainer) -> void:
	var device: VBoxContainer=parent
	_device_slot=OptionButton.new(); device.add_child(_device_slot)
	var row:=HBoxContainer.new();device.add_child(row)
	_app=OptionButton.new();_app.hide();row.add_child(_app)
	_phone_apps.clear()
	var app_grid:=GridContainer.new();app_grid.columns=3;app_grid.add_theme_constant_override("h_separation",8);app_grid.add_theme_constant_override("v_separation",8);device.add_child(app_grid)
	for pair in [["messages","Сообщения","Messages"],["gallery","Фотографии","Photos"],["forum","Форум","Forum"],["votes","Голосования","Polls"],["pages","Страницы","Pages"],["game","Игра","Game"],["network","Сеть","Network"]]:
		var app_id:String=str(pair[0]);var app_index:int=_app.item_count
		_app.add_item(_t(pair[1],pair[2]));_app.set_item_metadata(app_index,app_id)
		var app_button:=_button(app_grid,_t(pair[1],pair[2]),func():
			_app.select(app_index);_pending_app_choice=app_id;_show_device_panel()
			_send_intent({"type":"use_device","slot":_device_slot_index(),"app":app_id}))
		app_button.toggle_mode=true;app_button.size_flags_horizontal=Control.SIZE_EXPAND_FILL;app_button.set_meta("app_id",app_id);_phone_apps.append(app_button)
	var login:=HBoxContainer.new(); device.add_child(login)
	_button(login,_t("Войти","Log in"),func(): _send_intent({"type":"login","slot":_device_slot_index()}))
	_button(login,_t("Выйти","Log out"),func(): _send_intent({"type":"logout","slot":_device_slot_index()}))
	_button(login,_t("Читать экран","Read screen"),func(): _send_intent({"type":"read_screen"}))
	_device=_rich(device,85)
	_label(device,_t("Собеседник","Contact"),12,MUTED)
	_contact=OptionButton.new(); device.add_child(_contact)
	_device_title=LineEdit.new(); _device_title.placeholder_text=_t("Тема / заголовок","Subject / title"); device.add_child(_device_title)
	_device_text=TextEdit.new(); _device_text.placeholder_text=_t("Текст сообщения, темы или страницы","Message, topic or page text"); _device_text.custom_minimum_size.y=90; device.add_child(_device_text)
	_device_panels.clear()
	var messages:=VBoxContainer.new(); device.add_child(messages); _device_panels.messages=messages
	_label(messages,_t("Вложение","Attachment"),12,MUTED)
	_attachment_photo=OptionButton.new();messages.add_child(_attachment_photo)
	_button(messages,_t("Отправить сообщение","Send message"),_send_device_message)
	var groups:=HBoxContainer.new();messages.add_child(groups)
	_button(groups,_t("Создать группу","Create group"),_open_group)
	_button(groups,_t("Покинуть группу","Leave group"),func():
		for contact in _available_contacts:
			if str(contact.get("ref",contact.get("id","")))==_choice_ref(_contact) and contact.get("group",false):_send_intent({"type":"leave_group","group":_choice_ref(_contact)});return
		set_status(_t("Сначала выберите группу среди контактов.","Choose a group in your contacts first.")))
	_message_cards=VBoxContainer.new(); _message_cards.add_theme_constant_override("separation",7); messages.add_child(_message_cards)
	_message_id=OptionButton.new(); messages.add_child(_message_id)
	var message_actions:=HBoxContainer.new(); messages.add_child(message_actions)
	_button(message_actions,_t("Прочитать","Read"),func(): _send_intent({"type":"read_message","message":_choice_ref(_message_id)}))
	_button(message_actions,_t("Удалить","Delete"),func(): _send_intent({"type":"delete_message","message":_choice_ref(_message_id)}))
	_button(message_actions,_t("Подменить","Replace"),func(): _send_intent({"type":"replace_message","message":_choice_ref(_message_id),"text":_device_text.text}))
	var forum:=VBoxContainer.new(); device.add_child(forum); _device_panels.forum=forum
	_topic_id=OptionButton.new(); forum.add_child(_topic_id)
	_button(forum,_t("Создать тему","New topic"),func(): _send_intent({"type":"create_topic","title":_device_title.text,"text":_device_text.text}))
	_button(forum,_t("Ответить в выбранной теме","Reply to selected topic"),func(): _send_intent({"type":"reply","topic":_choice_ref(_topic_id),"text":_device_text.text}))
	var polls:=VBoxContainer.new(); device.add_child(polls); _device_panels.votes=polls
	_poll_id=OptionButton.new(); polls.add_child(_poll_id)
	_button(polls,_t("Создать голосование «За / против»","Create Yes / No poll"),func(): _send_intent({"type":"create_vote","title":_device_title.text,"options":[_t("За","Yes"),_t("Против","No")],"minutes":60.0}))
	_poll_options=VBoxContainer.new(); polls.add_child(_poll_options)
	_poll_id.item_selected.connect(func(_index): _refresh_poll_options())
	var pages:=VBoxContainer.new(); device.add_child(pages); _device_panels.pages=pages
	_page_id=OptionButton.new(); pages.add_child(_page_id)
	_button(pages,_t("Читать выбранную страницу","Read selected page"),func(): _send_intent({"type":"read_page","page":_choice_ref(_page_id)}))
	_button(pages,_t("Опубликовать страницу","Publish page"),func(): _send_intent({"type":"publish_page","page":_device_title.text.to_snake_case(),"title":_device_title.text,"text":_device_text.text}))
	var network:=VBoxContainer.new(); device.add_child(network); _device_panels.network=network
	_button(network,_t("Восстановить связь","Reconnect network"),func(): _send_intent({"type":"set_network","online":true}))
	_button(network,_t("Отключить связь","Disconnect network"),func(): _send_intent({"type":"set_network","online":false}))
	_button(network,_t("Задерживать сообщения на час","Delay messages for an hour"),func(): _send_intent({"type":"set_network","online":true,"delay":60.0}))
	var game:=VBoxContainer.new(); device.add_child(game); _device_panels.game=game
	_button(game,_t("Предложить игру собеседнику","Invite selected contact"),func(): _send_intent({"type":"play_game","contact":_choice_ref(_contact)}))
	_game_state=_label(game,_t("Выберите собеседника и начните игру.","Choose a contact and start a game."),13,MUTED)
	_game_grid=GridContainer.new(); _game_grid.columns=3; _game_grid.add_theme_constant_override("h_separation",5); _game_grid.add_theme_constant_override("v_separation",5); game.add_child(_game_grid); _game_buttons.clear()
	for index in 9:
		var cell: int=index
		var button:=_button(_game_grid,"·",func(): _send_intent({"type":"play_game","contact":_choice_ref(_contact),"cell":cell})); button.custom_minimum_size=Vector2(72,64); button.add_theme_font_size_override("font_size",30); _game_buttons.append(button)
	var gallery:=VBoxContainer.new(); device.add_child(gallery); _device_panels.gallery=gallery
	_photo_slot=OptionButton.new(); gallery.add_child(_photo_slot)
	_gallery_image=TextureRect.new(); _gallery_image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE; _gallery_image.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED; _gallery_image.custom_minimum_size=Vector2(300,180); gallery.add_child(_gallery_image)
	_button(gallery,_t("Снять цифровое фото","Take digital photo"),func(): _send_intent({"type":"take_photo","digital":true}))
	_photo_actions.clear()
	_photo_actions.append(_button(gallery,_t("Рассмотреть выбранное фото","View selected photo"),func():_send_photo_action("view_photo")))
	_photo_actions.append(_button(gallery,_t("Скопировать выбранное фото","Copy selected photo"),func():_send_photo_action("copy_photo")))
	_label(gallery,_t("Кому показать","Show to"),12,MUTED)
	_photo_target=OptionButton.new();gallery.add_child(_photo_target)
	_photo_actions.append(_button(gallery,_t("Показать выбранное фото","Show selected photo"),func():_send_photo_action("show_photo")))
	_app.item_selected.connect(func(_index):_pending_app_choice=str(_app.get_selected_metadata()); _show_device_panel())
	_show_device_panel()

func _build_journal(parent: VBoxContainer) -> void:
	var panel:=_panel(parent,Color("1d3342"));panel.size_flags_vertical=Control.SIZE_EXPAND_FILL
	var layout:=VBoxContainer.new();layout.add_theme_constant_override("separation",10);panel.add_child(layout)
	var top:=HBoxContainer.new();layout.add_child(top)
	_label(top,_t("Хроника истории","Story chronicle"),22,CREAM).size_flags_horizontal=Control.SIZE_EXPAND_FILL
	_button(top,"×",func():_journal_panel.hide())
	var filter_row:=HBoxContainer.new();layout.add_child(filter_row)
	_event_filter=OptionButton.new();filter_row.add_child(_event_filter)
	for text in [_t("Важные события","Important events"),_t("Все действия","All actions"),_t("Выбранный герой","Selected person"),_t("Общение и связь","Social & network")]:_event_filter.add_item(text)
	_event_filter.item_selected.connect(func(_index):_set_journal_page(0))
	_event_search=LineEdit.new();_event_search.placeholder_text=_t("Найти имя или событие…","Find a name or event…");_event_search.size_flags_horizontal=Control.SIZE_EXPAND_FILL;filter_row.add_child(_event_search)
	_event_search.text_changed.connect(func(_text):_set_journal_page(0))
	_journal_selection=HBoxContainer.new();_journal_selection.add_theme_constant_override("separation",12);layout.add_child(_journal_selection)
	_selection_details=_wrapped_label(_journal_selection,"",14,CREAM);_selection_details.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	_show_event_place=_button(_journal_selection,_t("Показать место","Show location"),func():
		var event:=_selected_event
		_journal_panel.hide()
		_journal_toggle.grab_focus()
		_focus_event(event))
	_journal_selection.hide();_event_group=ButtonGroup.new()
	var scroll:=ScrollContainer.new();scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL;scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;layout.add_child(scroll)
	_journal_rows=VBoxContainer.new();_journal_rows.size_flags_horizontal=Control.SIZE_EXPAND_FILL;_journal_rows.add_theme_constant_override("separation",6);scroll.add_child(_journal_rows)
	_journal=_rich(layout,0);_journal.hide()
	var pages:=HBoxContainer.new();layout.add_child(pages)
	_newer_events=_button(pages,_t("Позже","Newer"),func():_set_journal_page(_journal_page-1))
	_older_events=_button(pages,_t("Раньше","Older"),func():_set_journal_page(_journal_page+1))
	_page_number=_label(pages,"",14,MUTED);_page_number.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	_button(pages,_t("Скачать отчёт","Download report"),func():command.emit("download_report",{}))

func _build_main_menu() -> void:
	_menu=PanelContainer.new();_menu.name="MainMenu";_menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);_menu.add_theme_stylebox_override("panel",_style(INK,INK,0,0));_root.add_child(_menu)
	var margin:=MarginContainer.new();_menu.add_child(margin)
	for side in ["left","right"]:margin.add_theme_constant_override("margin_"+side,52)
	for side in ["top","bottom"]:margin.add_theme_constant_override("margin_"+side,28)
	var layout:=VBoxContainer.new();layout.add_theme_constant_override("separation",16);margin.add_child(layout)
	var header:=HBoxContainer.new();layout.add_child(header)
	_label(header,"AI Sims",46,CREAM).size_flags_horizontal=Control.SIZE_EXPAND_FILL
	_button(header,_t("Как играть","How to play"),func():_help_popup.popup_centered_clamped(Vector2i(800,680),0.92))
	_button(header,_t("Настройки","Settings"),show_settings)
	_continue_save=_button(header,_t("Продолжить сохранённую историю","Continue saved story"),func():show_main_menu(false);command.emit("load",{"slot":3}));_accent_button(_continue_save);_continue_save.hide()
	_button(header,_t("Вернуться в мир","Return to world"),func():show_main_menu(false))
	var divider:=HSeparator.new();layout.add_child(divider)
	_label(layout,_t("Выберите историю","Choose a story"),32,CREAM)
	_wrapped_label(layout,_t("Следите за людьми, читайте их переписку и меняйте условия одного дня.","Follow people, read their conversations and change the conditions of their day."),18,MUTED)
	var cards:=HBoxContainer.new();cards.add_theme_constant_override("separation",18);cards.size_flags_vertical=Control.SIZE_EXPAND_FILL;layout.add_child(cards)
	var art_path:="res://assets/release/ui/story_locations.png"
	var art:Texture2D=load(art_path) if ResourceLoader.exists(art_path) else null
	for index in 3:
		var map_index:int=index
		var panel:=_panel(cards,[Color("3e3938"),Color("2c3e39"),Color("263948")][index]);panel.size_flags_horizontal=Control.SIZE_EXPAND_FILL
		var content:=VBoxContainer.new();content.add_theme_constant_override("separation",12);panel.add_child(content)
		if art:
			var atlas:=AtlasTexture.new();atlas.atlas=art;var slice:=art.get_width()/3.0;atlas.region=Rect2(slice*index,0,slice,art.get_height());atlas.filter_clip=true
			var illustration:=TextureRect.new();illustration.texture=atlas;illustration.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;illustration.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_COVERED;illustration.custom_minimum_size.y=110;illustration.size_flags_vertical=Control.SIZE_EXPAND_FILL;content.add_child(illustration)
		_label(content,MAP_RU[index] if language=="ru" else MAP_EN[index],23,CREAM)
		var description:=_wrapped_label(content,_map_description(index),17,MUTED);description.custom_minimum_size.y=84
		var choose:=_button(content,_t("Открыть историю","Open story"),func():_map_choice.select(map_index);_update_story_cards();show_new_session());_accent_button(choose)
	_wrapped_label(layout,_t("Начните без подключения или добавьте личный RouterAI в настройках.","Start offline or connect your own RouterAI account in Settings."),15,MUTED)

func _build_new_dialog() -> void:
	var content:=_dialog(_t("Новая история","New story"));_new_popup=content.popup
	var box:VBoxContainer=content.box
	_label(box,_t("01  Выберите место","01  Choose a place"),16,SAGE)
	_map_choice=OptionButton.new();box.add_child(_map_choice)
	for index in 3:_map_choice.add_item(MAP_RU[index] if language=="ru" else MAP_EN[index]);_map_choice.set_item_metadata(index,MAP_IDS[index])
	_map_choice.item_selected.connect(func(_index):_update_story_cards())
	_story_description=_wrapped_label(box,"",17,CREAM);_story_description.custom_minimum_size.y=68
	_label(box,_t("02  Как начнётся ваш день","02  How your day begins"),16,SAGE)
	_scenario_choice=OptionButton.new();box.add_child(_scenario_choice)
	for pair in [["episode","Сюжетный эпизод · 08:00–20:00","Story episode · 08:00–20:00"],["sandbox","Свободная песочница","Open sandbox"]]:_scenario_choice.add_item(_t(pair[1],pair[2]));_scenario_choice.set_item_metadata(_scenario_choice.item_count-1,pair[0])
	_wrapped_label(box,_t("Один день, три главы и общий кризис. Участники действуют на основе собственного опыта; вам доступна вся истина мира.","One day, three chapters and a shared crisis. People act on their own experience; you can inspect the world's full truth."),15,MUTED)
	var settings_row:=HBoxContainer.new();settings_row.add_theme_constant_override("separation",24);box.add_child(settings_row)
	_label(settings_row,_t("Участников","People"),15,TEXT);_count=_spin(settings_row,3,20,8,1)
	_label(settings_row,_t("Вариант истории","Story seed"),15,TEXT);_seed=_spin(settings_row,1,999999,1,1)
	_wrapped_label(box,_t("По умолчанию — 8 участников. Можно выбрать от 3 до 20. Режим AI и бюджет настраиваются отдельно.","Eight people by default; choose between 3 and 20. AI mode and budget are configured separately."),14,MUTED)
	var begin:=_button(box,_t("Начать этот день","Begin this day"),func():
		_replacing_run=int(_state.get("run_id",-1));_seen_chapter="";_debrief_key="";_new_popup.hide();show_main_menu(false)
		command.emit("new_session",{"map_id":str(_map_choice.get_selected_metadata()),"count":int(_count.value),"scenario":str(_scenario_choice.get_selected_metadata()),"seed":int(_seed.value)}))
	_accent_button(begin);_update_story_cards()

func _build_settings_dialog() -> void:
	var content:=_dialog(_t("Настройки","Settings")); _settings_popup=content.popup
	var box: VBoxContainer=content.box
	var tabs:=TabContainer.new();tabs.custom_minimum_size=Vector2(590,490);box.add_child(tabs)
	var ai:=VBoxContainer.new();ai.name="AI";ai.add_theme_constant_override("separation",17);tabs.add_child(ai)
	_label(ai,_t("Самостоятельные персонажи","Autonomous characters"),21,GOLD)
	var note:=_label(ai,_t("Подключите личный аккаунт RouterAI.\nВы выбираете, сколько потратить на историю.","Connect your personal RouterAI account.\nYou choose how much to spend on a story."),16,TEXT);note.custom_minimum_size.x=560
	_web_connect_button=_button(ai,_t("Подключить аккаунт в браузере","Connect account in browser"),func():command.emit("web_connect",{}));_web_connect_button.visible=OS.has_feature("web")
	_live=CheckButton.new(); _live.text=_t("Включить AI","Enable AI"); ai.add_child(_live)
	_label(ai,_t("Личный API-ключ","Personal API key"),13,MUTED)
	_api_key=LineEdit.new(); _api_key.secret=true; _api_key.placeholder_text=_t("Личный ключ · не передавайте его другим","Personal key · keep it private");_api_key.custom_minimum_size.y=42; ai.add_child(_api_key)
	_model=LineEdit.new(); _model.text="~deepseek/deepseek-v4-flash-latest";ai.add_child(_model);_model.hide()
	var advanced:=Button.new();advanced.text=_t("Выбрать другую модель","Choose another model");advanced.flat=true;advanced.alignment=HORIZONTAL_ALIGNMENT_LEFT;advanced.pressed.connect(func():_model.visible=not _model.visible);ai.add_child(advanced)
	var budget_row:=HBoxContainer.new(); ai.add_child(budget_row); _label(budget_row,_t("Предел расходов, руб.","Spending limit, RUB"),15,TEXT).size_flags_horizontal=Control.SIZE_EXPAND_FILL; _budget=_spin(budget_row,0.1,1000,100,1)
	var connect:=_button(ai,_t("Применить подключение","Apply connection"),func():
		command.emit("provider",{"enabled":_live.button_pressed,"key":_api_key.text.strip_edges(),"model":_model.text.strip_edges(),"budget":float(_budget.value)})
		_api_key.clear())
	connect.custom_minimum_size.y=46;connect.add_theme_stylebox_override("normal",_style(Color("3a6e65"),GREEN,7,12))
	_connection_status=_label(ai,_t("Реальные AI-вызовы выключены.","Real AI requests are disabled."),13,GREEN)
	var game:=VBoxContainer.new();game.name=_t("Игра","Game");game.add_theme_constant_override("separation",18);tabs.add_child(game)
	_label(game,_t("Изображение и звук","Presentation & sound"),21,GOLD)
	_label(game,_t("Качество изображения","Visual quality"),13,MUTED)
	_quality=OptionButton.new(); game.add_child(_quality)
	for pair in [["low","Низкое","Low"],["medium","Среднее","Medium"],["high","Высокое","High"]]: _quality.add_item(_t(pair[1],pair[2])); _quality.set_item_metadata(_quality.item_count-1,pair[0])
	_quality.select(1)
	_label(game,_t("Язык","Language"),13,MUTED)
	_language_choice=OptionButton.new(); game.add_child(_language_choice); _language_choice.add_item("Русский"); _language_choice.add_item("English"); _language_choice.select(0 if language=="ru" else 1)
	var speed_row:=HBoxContainer.new(); game.add_child(speed_row); _label(speed_row,_t("Скорость времени","Time speed"),15,TEXT).size_flags_horizontal=Control.SIZE_EXPAND_FILL; _speed=_spin(speed_row,0.25,20,1,0.25)
	var sound_row:=HBoxContainer.new(); game.add_child(sound_row); _label(sound_row,_t("Громкость эффектов","Effects volume"),15,TEXT).size_flags_horizontal=Control.SIZE_EXPAND_FILL; _sfx=_spin(sound_row,0,1,0.5,0.05)
	_button(game,_t("Применить настройки","Apply settings"),_apply_settings).custom_minimum_size.y=46

func _build_appearance_dialog() -> void:
	var content:=_dialog(_t("Редактор персонажа","Character editor")); _appearance_popup=content.popup
	var row_layout:=HBoxContainer.new();row_layout.add_theme_constant_override("separation",24);content.box.add_child(row_layout)
	var preview_box:=VBoxContainer.new();preview_box.size_flags_vertical=Control.SIZE_EXPAND_FILL;row_layout.add_child(preview_box)
	_character_preview=TextureRect.new();_character_preview.custom_minimum_size=Vector2(300,430);_character_preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;_character_preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED;preview_box.add_child(_character_preview)
	_character_preview.gui_input.connect(func(event):if is_instance_valid(_world):_world.handle_character_preview_input(event))
	_label(preview_box,_t("Перетащите, чтобы повернуть.\nКолесо — приблизить.","Drag to rotate.\nWheel to zoom."),12,MUTED)
	var box:=VBoxContainer.new();box.custom_minimum_size.x=480;box.add_theme_constant_override("separation",8);row_layout.add_child(box)
	_label(box,_t("Образ выбранного персонажа","Selected character appearance"),18,GOLD)
	_preset_choice=OptionButton.new();box.add_child(_preset_choice);_preset_choice.item_selected.connect(_load_appearance_preset)
	_appearance_controls.clear()
	for spec in [["height","Рост, см","Height, cm",155,195,1],["build","Телосложение","Build",0,100,1]]:
		var row:=HBoxContainer.new(); box.add_child(row); _label(row,_t(spec[1],spec[2]),15,TEXT).size_flags_horizontal=Control.SIZE_EXPAND_FILL
		_appearance_controls[spec[0]]=_spin(row,float(spec[3]),float(spec[4]),1,float(spec[5]))
	var choices:Dictionary={"face":[_t("Классический A","Classic A"),_t("Классический B","Classic B"),_t("Округлый A","Round A"),_t("Округлый B","Round B"),_t("Узкий A","Narrow A"),_t("Узкий B","Narrow B")],"hair":[_t("Пробор","Parted"),_t("Пучок","Bun"),_t("Очень короткая","Cropped"),_t("Длинная","Long"),_t("Каре","Bob"),_t("Собранная","Tied back")],"outfit":[_t("Повседневный","Casual"),_t("Худи","Hoodie"),_t("Рабочий","Workwear"),_t("Служебный","Service") ],"shoes":[_t("Кроссовки","Sneakers"),_t("Ботинки","Boots")]}
	for field in ["face","hair","outfit","shoes"]:
		var row:=HBoxContainer.new();box.add_child(row);_label(row,{"face":_t("Лицо и основа тела","Face & body base"),"hair":_t("Причёска","Hairstyle"),"outfit":_t("Комплект одежды","Outfit"),"shoes":_t("Обувь","Shoes")}[field],15,TEXT).size_flags_horizontal=Control.SIZE_EXPAND_FILL
		var choice:=OptionButton.new();choice.custom_minimum_size.x=185;row.add_child(choice)
		for value in choices[field]:choice.add_item(str(value))
		_appearance_controls[field]=choice
	for spec in [["skin","Оттенок кожи","Skin tone","dfb89e"],["hair_color","Цвет волос","Hair color","4e3b32"],["color","Цвет одежды","Clothing color","83bfa9"]]:
		var row:=HBoxContainer.new(); box.add_child(row); _label(row,_t(spec[1],spec[2]),15,TEXT).size_flags_horizontal=Control.SIZE_EXPAND_FILL
		var picker:=ColorPickerButton.new(); picker.color=Color(spec[3]); picker.custom_minimum_size=Vector2(90,44); row.add_child(picker); _appearance_controls[spec[0]]=picker
	var preset:=LineEdit.new(); preset.placeholder_text=_t("Название сохраняемого образа (необязательно)","Appearance preset name (optional)"); box.add_child(preset); _appearance_controls.preset_name=preset
	var note:=_label(box,_t("Предпросмотр не меняет мир. Применённый образ видят и персонажи.","Preview does not change the world. Applied appearance is visible to the characters."),14,MUTED); note.custom_minimum_size.x=480; note.size.x=480; note.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	var presets:=HBoxContainer.new();box.add_child(presets)
	_button(presets,_t("Случайный образ","Randomize"),_randomize_appearance)
	_button(presets,_t("Сбросить","Reset"),func():_open_appearance())
	var footer:=HBoxContainer.new();box.add_child(footer)
	var spacer:=Control.new();spacer.size_flags_horizontal=Control.SIZE_EXPAND_FILL;footer.add_child(spacer)
	_button(footer,_t("Отмена","Cancel"),func():_appearance_popup.hide())
	var apply:=_button(footer,_t("Применить образ","Apply appearance"),_apply_appearance);apply.add_theme_stylebox_override("normal",_style(GOLD,GOLD,7,12));apply.add_theme_color_override("font_color",INK)
	for field in ["height","build"]:_appearance_controls[field].value_changed.connect(func(_value):_update_character_preview())
	for field in ["face","hair","outfit","shoes"]:_appearance_controls[field].item_selected.connect(func(_index):_update_character_preview())
	for field in ["skin","hair_color","color"]:_appearance_controls[field].color_changed.connect(func(_value):_update_character_preview())

func _build_god_dialog() -> void:
	var content:=_dialog(_t("Режим бога","God mode")); _god_popup=content.popup
	var box: VBoxContainer=content.box
	_label(box,_t("Изменить выбранного персонажа","Edit selected person"),18,GOLD)
	_god_controls.clear()
	for spec in [["health","Здоровье","Health",0,100],["hunger","Голод","Hunger",0,100],["fatigue","Усталость","Fatigue",0,100],["tokens","Жетоны","Tokens",0,10000]]:
		var row:=HBoxContainer.new(); box.add_child(row); _label(row,_t(spec[1],spec[2]),14,TEXT).size_flags_horizontal=Control.SIZE_EXPAND_FILL; _god_controls[spec[0]]=_spin(row,spec[3],spec[4],0,1)
	var blind:=CheckButton.new(); blind.text=_t("Слепота","Blindness"); box.add_child(blind); _god_controls.blind=blind
	for limb in ["left_arm","right_arm","left_leg","right_leg"]:
		var row:=HBoxContainer.new(); box.add_child(row); _label(row,_limb_name(limb),14,TEXT).size_flags_horizontal=Control.SIZE_EXPAND_FILL
		var choice:=OptionButton.new(); row.add_child(choice)
		for pair in [["healthy","Здорова","Healthy"],["injured","Повреждена","Injured"],["broken","Сломана","Broken"]]: choice.add_item(_t(pair[1],pair[2])); choice.set_item_metadata(choice.item_count-1,pair[0])
		_god_controls[limb]=choice
	var goal:=LineEdit.new(); goal.placeholder_text=_t("Текущая цель","Current goal"); box.add_child(goal); _god_controls.goal=goal
	var foundation:=TextEdit.new(); foundation.custom_minimum_size.y=80; foundation.placeholder_text=_t("Устойчивый фундамент личности","Stable personality foundation"); box.add_child(foundation); _god_controls.foundation=foundation
	_label(box,_t("Полномочия","Permissions"),13,MUTED)
	var role_choices:Dictionary={}
	for pair in [["network_admin","Управление сетью и страницами","Network & page administration"],["terminal_admin","Управление терминалом","Terminal administration"]]:
		var role:=CheckButton.new();role.text=_t(pair[1],pair[2]);box.add_child(role);role_choices[pair[0]]=role
	_god_controls.roles=role_choices
	_button(box,_t("Применить вмешательство","Apply intervention"),_apply_god)
	var row:=HBoxContainer.new(); box.add_child(row)
	_button(row,_t("Добавить нож","Spawn knife"),func(): _god("spawn_item",{"kind":"knife","id":selected_agent}))
	_button(row,_t("Добавить аптечку","Spawn medkit"),func(): _god("spawn_item",{"kind":"medkit","id":selected_agent}))
	_button(row,_t("Стереть память","Clear memory"),func(): _god("set_memory",{"id":selected_agent,"text":"","clear":true}))
	_label(box,_t("Личная память","Personal memory"),18,GOLD)
	var memory_text:=TextEdit.new(); memory_text.custom_minimum_size.y=75; memory_text.placeholder_text=_t("Новая субъективная запись","New subjective memory entry"); box.add_child(memory_text)
	_button(box,_t("Добавить запись вмешательством","Add memory intervention"),func(): _god("set_memory",{"id":selected_agent,"text":memory_text.text,"clear":false}))
	_label(box,_t("Условия мира","World conditions"),18,GOLD)
	var stock_row:=HBoxContainer.new(); box.add_child(stock_row); _label(stock_row,_t("Запас терминала","Terminal stock"),14,TEXT).size_flags_horizontal=Control.SIZE_EXPAND_FILL; var stock:=_spin(stock_row,0,10000,20,1)
	var limit_row:=HBoxContainer.new(); box.add_child(limit_row); _label(limit_row,_t("Пайков в сутки","Daily allowance"),14,TEXT).size_flags_horizontal=Control.SIZE_EXPAND_FILL; var limit:=_spin(limit_row,0,100,1,1)
	_button(box,_t("Изменить распределение","Change distribution"),func(): _god("set_terminal",{"stock":int(stock.value),"daily_limit":int(limit.value)}))
	var network_row:=HBoxContainer.new(); box.add_child(network_row)
	_button(network_row,_t("Включить связь","Connect network"),func(): _god("set_network",{"online":true,"delay":0.0}))
	_button(network_row,_t("Отключить связь","Disconnect network"),func(): _god("set_network",{"online":false}))
	var announcement:=LineEdit.new(); announcement.placeholder_text=_t("Объявление всем персонажам","Announcement to all people"); box.add_child(announcement)
	_button(box,_t("Объявить","Announce"),func(): _god("announce",{"text":announcement.text}))
	var door_choice:=OptionButton.new(); box.add_child(door_choice); _god_controls.door=door_choice
	var door_row:=HBoxContainer.new(); box.add_child(door_row)
	_button(door_row,_t("Открыть дверь","Open door"),func(): _god("door",{"target":_choice_ref(door_choice),"open":true,"locked":false}))
	_button(door_row,_t("Закрыть и запереть","Close and lock"),func(): _god("door",{"target":_choice_ref(door_choice),"open":false,"locked":true}))
	var room_choice:=OptionButton.new(); box.add_child(room_choice); _god_controls.room=room_choice
	_button(box,_t("Переместить в выбранную комнату","Teleport to selected room"),func():
		var position: Variant=room_choice.get_selected_metadata()
		if position is Array: _god("teleport",{"id":selected_agent,"position":position}))
	_label(box,_t("Каждое изменение записывается в историю мира.","Every change is recorded in world history."),12,MUTED)

func _build_help_dialog() -> void:
	var content:=_dialog(_t("Добро пожаловать в AI Sims","Welcome to AI Sims")); _help_popup=content.popup
	var box: VBoxContainer=content.box
	var help:=_rich(box,460)
	help.text=_t("Вы наблюдаете за людьми, которые действуют по собственному опыту.\n\n1. Создайте историю: карта, сценарий и от 3 до 20 персонажей.\n2. Подключите личный RouterAI или изучите механику в обозначенной демонстрации.\n3. Нажмите «Продолжить». Выбирайте людей слева и изучайте их жизнь, отношения и память.\n4. Переключитесь на личный вид: персонаж видит только свой кадр. Наблюдатель видит всю истину.\n5. Режим бога позволяет менять условия и людей. Вмешательства остаются в журнале.\n6. Сохраните историю и продолжите позже. Replay показывает записанное прошлое без новых решений AI.\n\nПробел — пауза. N — шаг. V — личный/общий вид. F — следить за выбранным. Колесо — масштаб, правая кнопка — вращение, средняя — перемещение камеры.\n\nДефицит заставляет договариваться. Сообщения могут быть подменены. Чужая уверенность не делает сведения истинными.","Observe people who act from their own experience.\n\n1. Create a story: choose a map, scenario and 3–20 people.\n2. Connect your RouterAI account, or learn the mechanics in the labelled demo.\n3. Continue the simulation. Select people and inspect life, relationships and memory.\n4. Switch to eye view: a person sees only their own image. The observer can inspect the full truth.\n5. God mode changes conditions and people; interventions remain in history.\n6. Save and continue later. Replay shows recorded history without new AI decisions.\n\nSpace pause. N step. V eye/observer view. F follow. Wheel zoom, right drag orbit, middle drag pan.\n\nScarcity creates reasons to cooperate. Messages can be altered. Confidence does not make a report true.")

func _build_group_dialog() -> void:
	var content:=_dialog(_t("Новая группа","New group"));_group_popup=content.popup
	var box:VBoxContainer=content.box
	_group_name=LineEdit.new();_group_name.placeholder_text=_t("Название группы","Group name");box.add_child(_group_name)
	_label(box,_t("Пригласить знакомых","Invite known contacts"),15,GOLD)
	_group_members=ItemList.new();_group_members.select_mode=ItemList.SELECT_MULTI;_group_members.custom_minimum_size=Vector2(430,260);box.add_child(_group_members)
	_group_note=_label(box,_t("Выберите участников из личных контактов.","Choose participants from personal contacts."),13,MUTED)
	_button(box,_t("Создать группу","Create group"),func():
		var refs:Array=[]
		for index in _group_members.get_selected_items():refs.append(str(_group_members.get_item_metadata(index)))
		if refs.is_empty() or _group_name.text.strip_edges().is_empty():_group_note.text=_t("Введите название и выберите хотя бы одного собеседника.","Enter a name and choose at least one contact.");return
		_send_intent({"type":"create_group","title":_group_name.text.strip_edges(),"members":refs});_group_popup.hide())

func _open_group() -> void:
	_group_members.clear()
	for contact in _available_contacts:
		if not contact.get("group",false):_group_members.add_item(str(contact.get("name",_t("Собеседник","Contact"))));_group_members.set_item_metadata(_group_members.item_count-1,str(contact.get("ref",contact.get("id",""))))
	_group_popup.popup_centered_clamped(Vector2i(490,465))

func _refresh_person(agent: Dictionary) -> void:
	_name.text=str(agent.get("name",selected_agent))
	_name.add_theme_color_override("font_color",CREAM)
	_health.value=float(agent.get("health",100)); _hunger.value=float(agent.get("needs",{}).get("hunger",0)); _fatigue.value=float(agent.get("needs",{}).get("fatigue",0))
	var body: Dictionary=agent.get("body",{})
	var condition: String=_t("В сознании","Conscious")
	if not agent.get("alive",true): condition=_t("Погиб","Dead")
	elif agent.get("sleeping",false): condition=_t("Спит","Sleeping")
	elif agent.get("unconscious",false): condition=_t("Без сознания","Unconscious")
	var lines: Array[String]=[condition+_t(" · боль %d"," · pain %d")%roundi(float(agent.get("pain",0))),_t("Жетоны: ","Tokens: ")+str(agent.get("tokens",0)),"",_t("Инвентарь","Inventory")]
	for index in agent.get("inventory",[]).size():
		var item: Dictionary=_state.get("items",{}).get(agent.inventory[index],{})
		lines.append("• "+_item_name(item))
	if agent.get("inventory",[]).is_empty(): lines.append(_t("Пусто","Empty"))
	for limb in ["left_arm","right_arm","left_leg","right_leg"]:
		if body.get(limb,"healthy")!="healthy": lines.append(_limb_name(limb)+": "+(_t("сломана","broken") if body.get(limb)=="broken" else _t("повреждена","injured")))
	if body.get("blind",false): lines.append(_t("Зрение недоступно","Vision unavailable"))
	var previous_action:=_action_text(agent.get("last_action",{}))
	if not previous_action.is_empty():lines.append("\n"+_t("Последнее действие: ","Last action: ")+previous_action)
	lines.append(str(agent.get("last_result",{}).get("message",agent.get("last_result",{}).get("reason",""))))
	_life_text.text="\n".join(lines)
	var previous_slot: int=_slot_index()
	_inventory_slot.clear()
	var previous_device: int=_device_slot_index();_device_slot.clear()
	for index in agent.get("inventory",[]).size():
		var item: Dictionary=_state.get("items",{}).get(agent.inventory[index],{})
		_inventory_slot.add_item(_item_name(item)); _inventory_slot.set_item_metadata(_inventory_slot.item_count-1,index)
		if index==previous_slot: _inventory_slot.select(index)
		if item.get("kind")=="phone":
			_device_slot.add_item(_item_name(item));_device_slot.set_item_metadata(_device_slot.item_count-1,index)
			if index==previous_device:_device_slot.select(_device_slot.item_count-1)
	if _inventory_slot.item_count==0: _inventory_slot.add_item(_t("Пусто","Empty")); _inventory_slot.set_item_metadata(0,0)
	if _device_slot.item_count==0:_device_slot.add_item(_t("Нет доступного телефона","No accessible phone"));_device_slot.set_item_metadata(0,0)
	_refresh_photo_choices(agent)
	var relations: Array[String]=[_t("Отношения и обязательства","Relationships & commitments"),""]
	for other in agent.get("relations",{}):
		var name: String=str(_state.get("agents",{}).get(other,{}).get("name",other))
		var relationship: Dictionary=agent.relations[other]
		relations.append(name+_t(" · доверие %d"," · trust %d")%roundi(float(relationship.get("trust",0))))
		for experience in relationship.get("experience",[]).slice(-3):
			if experience is Dictionary: relations.append("  "+str(experience.get("text","")))
	var offers: Array=[]
	for local_ref in agent.get("offer_refs",{}):
		var offer: Dictionary=_state.get("economy",{}).get("offers",{}).get(agent.offer_refs[local_ref],{})
		if offer.is_empty(): continue
		var source_name: String=str(_state.agents.get(offer.get("from",""),{}).get("name",_t("Собеседник","Contact")))
		var recipient_name: String=str(_state.agents.get(offer.get("to",""),{}).get("name",_t("Собеседник","Contact")))
		var statuses: Dictionary={"proposed":_t("предложено","proposed"),"accepted":_t("принято","accepted"),"completed":_t("обмен завершён","exchange complete"),"claimed":_t("ожидает подтверждения","awaiting confirmation"),"fulfilled":_t("исполнено","fulfilled"),"expired":_t("срок истёк","expired")}
		var caption: String=source_name+" / "+recipient_name+": "+str(statuses.get(str(offer.get("status","")),_t("соглашение","agreement")))
		relations.append(caption)
		var item_name: String=str(_state.get("items",{}).get(offer.get("item",""),{}).get("label",""))
		if not item_name.is_empty(): relations.append("  "+item_name+_t(" за %d жетонов"," for %d tokens")%int(offer.get("request_tokens",0)))
		if not str(offer.get("promise","")).is_empty(): relations.append("  "+str(offer.promise))
		offers.append({"ref":str(local_ref),"name":caption})
	_populate_choice(_offer_choice,offers,"name",_t("Нет личных предложений","No personal offers"))
	_relations.text="\n\n".join(relations)
	var debug: Dictionary=_debug.get(selected_agent,{})
	var memory: Variant=debug.get("memory",debug.get("memory_view",{}))
	_memory.text=_format_memory(memory)
	var observation: Dictionary=_info.get("observations",{}).get(selected_agent,debug.get("observation",debug.get("last_observation",{})))
	_refresh_targets(observation)
	var screen: Variant=_info.get("device_screens",{}).get(selected_agent,{})
	if screen is Dictionary and not screen.is_empty():
		_refresh_device_data(screen,observation)
		_device.text=_screen_summary(screen)
	elif not observation.get("personal_results",[]).is_empty():
		var results: Array[String]=[]
		for result in observation.personal_results.slice(-5): results.append(_memory_entry_text(result))
		_device.text="\n\n".join(results)
		_refresh_device_data({},observation)
	else: _device.text=_t("Откройте доступное устройство из инвентаря и прочитайте экран. Непрочитанное не становится знанием персонажа.","Open an accessible inventory device, then read its screen. Unread content does not become personal knowledge.")
	if screen is Dictionary and screen.is_empty(): _refresh_device_data({},observation)
	var map_index: int=MAP_IDS.find(str(_state.get("map_id","")))
	var map_name: String=(MAP_RU[map_index] if language=="ru" else MAP_EN[map_index]) if map_index>=0 else _t("Неизвестная карта","Unknown map")
	var terminal: Dictionary=_state.get("terminal",{})
	var network: Dictionary=_state.get("network",{})
	var role_names:Array[String]=[]
	for role in agent.get("roles",[]):role_names.append({"network_admin":_t("Администратор связи","Network administrator"),"terminal_admin":_t("Администратор терминала","Terminal administrator")}.get(str(role),_t("Особые полномочия","Special permissions")))
	var truth_lines: Array[String]=[_t("Истина доступна наблюдателю","Observer's full truth"),"",_t("Карта: ","Map: ")+map_name,_t("Живых персонажей: %d из %d","Living people: %d of %d")%[_state.get("agents",{}).values().filter(func(person):return person.get("alive",true)).size(),_state.get("agents",{}).size()],_t("Роли выбранного: ","Selected roles: ")+", ".join(role_names),"",_t("ОБЩИЕ РЕСУРСЫ","SHARED RESOURCES"),_t("Пайков в терминале: %d","Terminal rations: %d")%int(terminal.get("stock",0)),_t("Личный лимит в сутки: %d","Daily personal allowance: %d")%int(terminal.get("daily_limit",1)),_t("Выдано устройств: %d","Equipment on loan: %d")%terminal.get("loans",{}).size(),"",_t("СВЯЗЬ","COMMUNICATIONS"),_t("Работает","Online") if network.get("online",true) else _t("Отключена","Offline"),_t("Задержка: %d мин","Delay: %d min")%int(network.get("delay",0)),_t("Сообщений: %d · тем: %d","Messages: %d · topics: %d")%[network.get("messages",{}).size(),network.get("topics",{}).size()],"",_t("ЦЕЛИ ИСТОРИИ","STORY OBJECTIVES")]
	for objective in _state.get("objectives",[]): truth_lines.append(("✓ " if objective.get("complete",false) else "○ ")+str(objective.get("title","")))
	_truth.text="\n".join(truth_lines)
	var messages:Array=[]
	for key in network.get("messages",{}):
		var message:Dictionary=network.messages[key]
		var sender:String=str(_state.agents.get(message.get("sender",""),{}).get("name",_t("Отправитель","Sender")))
		var recipient:String=str(_state.agents.get(message.get("recipient",""),{}).get("name",_t("Получатель","Recipient")))
		messages.append({"ref":str(key),"name":sender+" / "+recipient+" · "+_message_status(str(message.get("status","")))})
	_populate_choice(_trace_message,messages,"name",_t("Сообщений пока нет","No messages yet"));_refresh_message_trace()

func _refresh_targets(observation: Dictionary) -> void:
	var previous: String=str(_target.get_selected_metadata()) if _target.item_count>0 else ""
	_target.clear()
	for target in observation.get("mock_view",[]):
		var ref: String=str(target.get("ref",""))
		_target.add_item(str(target.get("label",target.get("kind",_t("Видимый объект","Visible object"))))+_t(" · %.1f м"," · %.1f m")%float(target.get("distance",0)))
		_target.set_item_metadata(_target.item_count-1,ref)
		if ref==previous: _target.select(_target.item_count-1)
	if _target.item_count==0:
		for target in observation.get("targets",[]):
			_target.add_item(_t("Объект в поле зрения %d","Visible object %d")%(_target.item_count+1)); _target.set_item_metadata(_target.item_count-1,str(target.get("ref","")))
	if _target.item_count==0: _target.add_item(_t("Нет доступной цели","No perceived target")); _target.set_item_metadata(0,"")
	var viewers:Array=[]
	for target in observation.get("mock_view",[]):
		if target.get("kind","")=="agent":viewers.append({"ref":str(target.get("ref","")),"name":str(target.get("label",_t("Человек","Person")))+_t(" · %.1f м"," · %.1f m")%float(target.get("distance",0))})
	_populate_choice(_photo_target,viewers,"name",_t("Рядом никого не видно","No person in sight"))

func _set_journal_page(page:int) -> void:
	_selected_event={};_journal_selection.hide()
	_journal_page=maxi(0,page);_last_journal_signature="";_refresh_journal(_state.get("events",[]))

func _refresh_journal(events: Array) -> void:
	if not is_instance_valid(_event_filter):return
	var open:bool=_journal_panel.is_visible_in_tree()
	var history:Array=_info.get("chronicle_events",events)
	var signature:String="%s/%s/%s/%s/%s/%s/%s/%s/%s"%[_state.get("run_id",0),_state.get("map_id",""),history.size(),history[-1].get("seq",-1) if not history.is_empty() else -1,_event_filter.selected,selected_agent,_event_search.text,_journal_page,open]
	if signature==_last_journal_signature:return
	_last_journal_signature=signature
	_event_lookup.clear()
	var grouped:Array=[]
	var noise:Array=["wait","look","move","move_to","tick","route_progress"]
	for raw in (history if open else events.slice(maxi(0,events.size()-80))):
		if not raw is Dictionary:continue
		var event:Dictionary=raw
		_event_lookup[str(event.get("seq",0))]=event
		var type:String=str(event.get("type",""));var actor:String=str(event.get("actor",""))
		if not grouped.is_empty() and type in noise and type==str(grouped[-1].event.get("type","")) and actor==str(grouped[-1].event.get("actor","")) and bool(event.get("ok",true)):
			grouped[-1].count+=1;grouped[-1].event=event
		else:grouped.append({"event":event,"count":1})
	for child in _live_events.get_children():child.queue_free()
	var important:Array=grouped.filter(func(entry):return not str(entry.event.get("type","")) in noise or not bool(entry.event.get("ok",true)))
	if important.is_empty():important=grouped
	var recent:Array=important.slice(maxi(0,important.size()-2));recent.reverse()
	for entry in recent:_event_button(_live_events,entry.event,int(entry.count))
	if recent.is_empty():_wrapped_label(_live_events,_t("День ещё не начался. Продолжите историю, чтобы увидеть решения и последствия.","The day is yet to begin. Continue to see choices and consequences."),14,MUTED)
	for child in _journal_rows.get_children():child.queue_free()
	if not open:
		_journal.text="";return
	var lines:Array[String]=[];var search:String=_event_search.text.strip_edges().to_lower()
	var matched:=0
	grouped.reverse()
	for entry in grouped:
		var event:Dictionary=entry.event;var type:String=str(event.get("type",""));var actor:String=str(event.get("actor",""))
		if _event_filter.selected==0 and type in noise and bool(event.get("ok",true)):continue
		if _event_filter.selected==2 and actor!=selected_agent:continue
		if _event_filter.selected==3 and not type in ["speak","message","send_message","receive_message","network","set_network","reply","create_topic","create_vote","vote"]:continue
		var line:String=_event_caption(event,int(entry.count))
		if not search.is_empty() and not search in line.to_lower():continue
		if matched>=_journal_page*JOURNAL_PAGE_SIZE and lines.size()<JOURNAL_PAGE_SIZE:
			lines.append(line);_event_button(_journal_rows,event,int(entry.count))
		matched+=1
	_journal.text="\n".join(lines)
	_newer_events.disabled=_journal_page==0
	_older_events.disabled=(_journal_page+1)*JOURNAL_PAGE_SIZE>=matched
	_page_number.text="%d / %d"%[_journal_page+1,maxi(1,ceili(float(matched)/JOURNAL_PAGE_SIZE))]
	if lines.is_empty():_wrapped_label(_journal_rows,_t("Нет событий по этому фильтру.","No events match this filter."),15,MUTED)

func _rebuild_roster(agents: Dictionary) -> void:
	for child in _agent_rows.get_children(): child.queue_free()
	_agent_buttons.clear()
	for key in agents:
		var id: String=str(key)
		var button:=_button(_agent_rows,str(agents[id].get("name",id)),func():_pick_person(id))
		button.toggle_mode=true; button.alignment=HORIZONTAL_ALIGNMENT_LEFT; button.custom_minimum_size.y=55; button.add_theme_font_size_override("font_size",14)
		button.add_theme_color_override("font_color",Color.from_string(str(agents[id].get("color","e8ede7")),TEXT).lightened(0.2))
		_agent_buttons[id]=button

func _send_intent(action: Dictionary) -> void:
	if selected_agent.is_empty(): return
	var validated: Dictionary=Catalog.validate(action)
	if not validated.ok: set_status(str(validated.error)); return
	command.emit("intent",{"id":selected_agent,"action":validated.action})

func _photo_selection(choice: OptionButton) -> Dictionary:
	if not is_instance_valid(choice) or choice.selected<0 or choice.is_item_disabled(choice.selected):return {}
	var value:Variant=choice.get_selected_metadata()
	return value.duplicate() if value is Dictionary and value.has("slot") else {}

func _refresh_photo_choices(agent: Dictionary) -> void:
	var same_person:bool=_photo_actor==selected_agent
	var previous:Dictionary=_photo_selection(_photo_slot) if same_person else {}
	var previous_attachment:Dictionary=_photo_selection(_attachment_photo) if same_person else {}
	_photo_actor=selected_agent
	var entries:Array=[]
	for slot in agent.get("inventory",[]).size():
		var item:Dictionary=_state.get("items",{}).get(agent.inventory[slot],{})
		var files:Array=[]
		if item.get("kind","")=="photo":files=[str(item.get("artifact_id",""))]
		elif item.get("kind","") in ["phone","camera"] and not item.get("locked",false):files=item.get("files",[])
		for file_index in files.size():
			var artifact:Dictionary=_state.get("artifacts",{}).get(files[file_index],{})
			if artifact.is_empty() or artifact.get("kind","")!="photo":continue
			var minute:float=float(artifact.get("created",0))
			var label:String=(str(item.get("label",_t("Фотография","Photo"))) if item.get("kind")=="photo" else str(item.get("label",_t("Устройство","Device")))+_t(" · снимок %d"," · photo %d")%(file_index+1))
			label+=_t(" · день %d, %02d:%02d"," · day %d, %02d:%02d")%[int(minute/1440)+1,int(fmod(minute,1440)/60),int(fmod(minute,60))]
			var ready:bool=not str(artifact.get("image_ref","")).is_empty()
			if not ready:label+=_t(" · обработка"," · processing")
			entries.append({"label":label,"choice":{"slot":slot,"index":file_index if item.get("kind")!="photo" else -1},"ready":ready})
	_photo_slot.clear();_attachment_photo.clear()
	_attachment_photo.add_item(_t("Без вложения","No attachment"));_attachment_photo.set_item_metadata(0,{})
	var first_ready:int=-1
	for entry in entries:
		var index:int=_photo_slot.item_count
		_photo_slot.add_item(entry.label);_photo_slot.set_item_metadata(index,entry.choice);_photo_slot.set_item_disabled(index,not entry.ready)
		_attachment_photo.add_item(entry.label);_attachment_photo.set_item_metadata(index+1,entry.choice);_attachment_photo.set_item_disabled(index+1,not entry.ready)
		if entry.ready:
			if first_ready<0:first_ready=index
			if entry.choice==previous:first_ready=index
			if entry.choice==previous_attachment:_attachment_photo.select(index+1)
	if entries.is_empty():_photo_slot.add_item(_t("Нет доступных фотографий","No accessible photos"));_photo_slot.set_item_metadata(0,{});_photo_slot.set_item_disabled(0,true)
	if first_ready>=0:_photo_slot.select(first_ready)
	for button in _photo_actions:button.disabled=first_ready<0

func _send_photo_action(type: String) -> void:
	var selected:Dictionary=_photo_selection(_photo_slot)
	if selected.is_empty():set_status(_t("Выберите готовую доступную фотографию.","Choose an accessible finished photo."));return
	var action:Dictionary={"type":type};action.merge(selected)
	if type=="show_photo":
		var viewer:String=_choice_ref(_photo_target)
		if viewer.is_empty():set_status(_t("Сначала выберите человека рядом.","Choose a nearby person first."));return
		action.target=viewer
	_send_intent(action)

func _send_device_message() -> void:
	var action:Dictionary={"type":"send_message","contact":_choice_ref(_contact),"text":_device_text.text}
	var photo:Dictionary=_photo_selection(_attachment_photo)
	if not photo.is_empty():action.attachment=int(photo.slot);action.attachment_index=int(photo.index)
	_send_intent(action)

func _send_target_intent(type: String, extra: Dictionary={}) -> void:
	var ref: String=str(_target.get_selected_metadata()) if _target.item_count>0 else ""
	if ref.is_empty(): set_status(_t("Персонаж не воспринимает доступной цели.","No accessible target in this person's perception.")); return
	var action: Dictionary={"type":type,"target":ref}; action.merge(extra,true); _send_intent(action)

func _speak() -> void:
	if _speech.text.strip_edges().is_empty(): return
	_send_intent({"type":"speak","text":_speech.text.strip_edges()}); _speech.clear()

func _toggle_view() -> void:
	set_first_person(not _first_person); command.emit("view",{"first_person":_first_person})

func _slot_index() -> int:
	return int(_inventory_slot.get_selected_metadata()) if is_instance_valid(_inventory_slot) and _inventory_slot.item_count>0 else 0

func _device_slot_index() -> int:
	return int(_device_slot.get_selected_metadata()) if is_instance_valid(_device_slot) and _device_slot.item_count>0 else 0

func _choice_ref(choice: OptionButton) -> String:
	return str(choice.get_selected_metadata()) if is_instance_valid(choice) and choice.item_count>0 else ""

func _populate_choice(choice: OptionButton, entries: Array, label_key: String, empty_label: String) -> void:
	var previous: String=_choice_ref(choice)
	choice.clear()
	for entry in entries:
		if not entry is Dictionary: continue
		var ref: String=str(entry.get("ref",entry.get("id","")))
		choice.add_item(str(entry.get(label_key,_t("Запись","Entry")))); choice.set_item_metadata(choice.item_count-1,ref)
		if ref==previous: choice.select(choice.item_count-1)
	if choice.item_count==0: choice.add_item(empty_label); choice.set_item_metadata(0,"")

func _show_device_panel() -> void:
	var app: String=str(_app.get_selected_metadata())
	for button in _phone_apps:button.set_pressed_no_signal(str(button.get_meta("app_id",""))==app)
	if is_instance_valid(_phone_app_heading):_phone_app_heading.text=_t("Личный телефон · ","Personal phone · ")+_app.get_item_text(_app.selected)
	for key in _device_panels: _device_panels[key].visible=str(key)==app
	_contact.visible=app in ["messages","game"]
	_device_title.visible=app in ["forum","votes","pages"]
	_device_text.visible=app in ["messages","forum","pages","network"]

func _refresh_device_data(screen: Dictionary, observation: Dictionary) -> void:
	if _device_actor!=selected_agent:_device_actor=selected_agent;_pending_app_choice=""
	var signature: String=selected_agent+JSON.stringify(screen)+JSON.stringify(observation.get("contacts",[]))+language
	if signature==_screen_signature: return
	_screen_signature=signature
	_screen_data=screen.duplicate(true)
	var actual_app:String=str(screen.get("app",""))
	if actual_app==_pending_app_choice:_pending_app_choice=""
	if _pending_app_choice.is_empty():
		for index in _app.item_count:
			if str(_app.get_item_metadata(index))==actual_app:_app.select(index);break
	_available_contacts=screen.get("contacts",observation.get("contacts",[])).duplicate(true)
	_populate_choice(_contact,_available_contacts,"name",_t("Нет знакомых контактов","No known contacts"))
	var messages: Array=screen.get("messages",[])
	var message_choices: Array=[]
	for child in _message_cards.get_children(): child.queue_free()
	for message in messages:
		var author: String=str(message.get("author",_t("Собеседник","Contact")))
		var status: String=str(message.get("status",""))
		var caption: String=author+" · "+_message_status(status)
		message_choices.append({"ref":str(message.get("ref",message.get("id",""))),"title":caption})
		var card:=_panel(_message_cards,Color("233a41"))
		var body:=VBoxContainer.new(); body.add_theme_constant_override("separation",4); card.add_child(body)
		_label(body,caption,12,GOLD)
		var text: String=str(message.get("text",""))
		if text.is_empty(): text=_t("Непрочитанное сообщение","Unread message")
		var label:=_label(body,text,13,TEXT); label.custom_minimum_size.x=290; label.size.x=290; label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
		var ref: String=str(message.get("ref",message.get("id","")))
		_button(body,_t("Прочитать","Read"),func(): _send_intent({"type":"read_message","message":ref}))
	_populate_choice(_message_id,message_choices,"title",_t("Нет доступных сообщений","No accessible messages"))
	_populate_choice(_topic_id,screen.get("topics",[]),"title",_t("Нет доступных тем","No accessible topics"))
	_populate_choice(_poll_id,screen.get("polls",[]),"title",_t("Нет активных голосований","No active polls"))
	_populate_choice(_page_id,screen.get("pages",[]),"title",_t("Нет доступных страниц","No accessible pages"))
	_refresh_poll_options()
	var game: Dictionary=screen.get("game",{})
	var cells: Array=game.get("cells",game.get("board",[]))
	for index in _game_buttons.size():
		var value: String=str(cells[index]) if cells.size()>index else ""
		_game_buttons[index].text="·" if value in ["","0","-","null","."] else value
		_game_buttons[index].disabled=bool(game.get("finished",false)) or not value in ["","0","-","null","."]
	if game.is_empty(): _game_state.text=_t("Пригласите знакомого собеседника.","Invite a known contact.")
	elif game.get("finished",false): _game_state.text=_t("Игра окончена: ","Game over: ")+str(game.get("winner",_t("ничья","draw")))
	else: _game_state.text=_t("Ход: ","Turn: ")+str(game.get("turn",""))+"\n"+_t("Соперник: ","Opponent: ")+str(game.get("opponent",""))
	var image_ref: String=str(screen.get("image_ref",""))
	if image_ref!=_last_gallery_ref:
		_last_gallery_ref=image_ref; _gallery_image.texture=null
		if image_ref.length()==64 and RegEx.create_from_string("^[0-9a-f]{64}$").search(image_ref)!=null:
			var path: String="user://ai_media/"+image_ref+".png"
			if FileAccess.file_exists(path):
				var image:=Image.new()
				if image.load(path)==OK: _gallery_image.texture=ImageTexture.create_from_image(image)
	_show_device_panel()

func _refresh_poll_options() -> void:
	if not is_instance_valid(_poll_options): return
	for child in _poll_options.get_children(): child.queue_free()
	var ref: String=_choice_ref(_poll_id)
	for poll in _screen_data.get("polls",[]):
		if str(poll.get("ref",poll.get("id","")))!=ref: continue
		var options: Array=poll.get("options",[])
		var counts: Array=poll.get("votes",[])
		for index in options.size():
			var option_index: int=index
			var label: String=str(options[index])+(" · %d"%int(counts[index]) if counts.size()>index else "")
			var button:=_button(_poll_options,label,func(): _send_intent({"type":"vote","poll":ref,"option":option_index}))
			button.disabled=bool(poll.get("closed",false))
		if poll.get("closed",false):
			var result: int=int(poll.get("result",-1)); _label(_poll_options,_t("Итог: ","Result: ")+(str(options[result]) if result>=0 and result<options.size() else _t("нет большинства","no majority")),13,GOLD)

func _screen_summary(screen: Dictionary) -> String:
	if not _pending_app_choice.is_empty() and str(screen.get("app",""))!=_pending_app_choice:return _t("Нажмите «Открыть», чтобы переключить приложение на телефоне персонажа.","Press Open to change the application on this person's phone.")
	var title: String=str(screen.get("title",_t("Личный экран","Personal screen")))
	var lines: Array[String]=[title]
	if screen.has("account_name"): lines.append(_t("Аккаунт: ","Account: ")+str(screen.account_name))
	var app: String=str(screen.get("app",""))
	match app:
		"contacts":
			for contact in screen.get("contacts",[]): lines.append(str(contact.get("name","")))
		"messages","network": lines.append(_t("Доступных сообщений: %d","Accessible messages: %d")%screen.get("messages",[]).size())
		"forum":
			for topic in screen.get("topics",[]):
				if str(topic.get("ref",topic.get("id","")))==_choice_ref(_topic_id):
					lines.append(str(topic.get("title",""))); lines.append(str(topic.get("text","")))
					for post in topic.get("replies",[]): lines.append(str(post.get("author",""))+": "+str(post.get("text","")))
		"votes": lines.append(_t("Выберите голосование и вариант ниже.","Choose a poll and option below."))
		"pages":
			for page in screen.get("pages",[]):
				if str(page.get("ref",page.get("id","")))==_choice_ref(_page_id): lines.append(str(page.get("title",""))); lines.append(str(page.get("text","")))
		"game": lines.append(_t("Играйте на поле ниже.","Use the board below."))
		"gallery": lines.append(_t("Личные фотографии","Personal photographs") if not str(screen.get("image_ref","")).is_empty() else _t("Галерея пуста.","The gallery is empty."))
	if not screen.has("account_name"): lines.append(str(screen.get("text","")))
	return "\n\n".join(lines)

func _message_status(value: String) -> String:
	var statuses: Dictionary={"queued":_t("в очереди","queued"),"created":_t("создано","created"),"delivered":_t("доставлено","delivered"),"read":_t("прочитано","read"),"deleted":_t("удалено","deleted"),"pending":_t("ожидает отправки","pending")}
	return str(statuses.get(value,value))

func _god(name: String, args: Dictionary) -> void:
	if name=="spawn_item" and not args.has("position") and _state.get("agents",{}).has(str(args.get("id",selected_agent))):
		var person: Dictionary=_state.agents[str(args.get("id",selected_agent))]
		var point:=Vector2(float(person.position[0]),float(person.position[1]))
		for offset in [0.0,45.0,-45.0,90.0,-90.0,180.0]:
			var angle: float=deg_to_rad(float(person.get("heading",0))+offset)
			var candidate: Vector2=point+Vector2(-sin(angle),-cos(angle))*1.15
			if Spatial.walkable(candidate,_state.get("geometry",{}),_state.get("agents",{}),str(person.get("id",""))):
				args["position"]=[candidate.x,candidate.y]; break
	command.emit("god",{"command":name,"args":args})

func _open_appearance() -> void:
	if not _state.get("agents",{}).has(selected_agent): return
	var agent: Dictionary=_state.agents[selected_agent]
	var appearance: Dictionary=agent.get("appearance",{})
	for key in ["face","hair","outfit","shoes"]:_appearance_controls[key].select(clampi(int(appearance.get(key,0)),0,_appearance_controls[key].item_count-1))
	_appearance_controls.height.value=float(appearance.get("height",1))*178.0
	_appearance_controls.build.value=(float(appearance.get("build",1))-.85)/.35*100.0
	for key in ["skin","hair_color"]: _appearance_controls[key].color=Color.from_string(str(appearance.get(key,"dfb89e" if key=="skin" else "4e3b32")),Color.WHITE)
	_appearance_controls.color.color=Color.from_string(str(agent.get("color","83bfa9")),GREEN)
	_preset_choice.clear();_preset_choice.add_item(_t("Сохранённые образы…","Saved appearances…"));_preset_choice.set_item_metadata(0,"")
	for preset_name in _info.get("appearance_presets",{}):_preset_choice.add_item(str(preset_name));_preset_choice.set_item_metadata(_preset_choice.item_count-1,str(preset_name))
	_refresh_appearance_capabilities()
	_appearance_popup.popup_centered_clamped(Vector2i(960,850),0.92)
	_update_character_preview()

func _load_appearance_preset(index:int) -> void:
	var key:String=str(_preset_choice.get_item_metadata(index))
	var preset:Variant=_info.get("appearance_presets",{}).get(key,{})
	if not preset is Dictionary or preset.is_empty():return
	for field in ["face","hair","outfit","shoes"]:
		if preset.has(field):_appearance_controls[field].select(clampi(int(preset[field]),0,_appearance_controls[field].item_count-1))
	if preset.has("height"):_appearance_controls.height.value=float(preset.height)*178.0
	if preset.has("build"):_appearance_controls.build.value=(float(preset.build)-.85)/.35*100.0
	for field in ["skin","hair_color","color"]:
		if preset.has(field):_appearance_controls[field].color=Color.from_string(str(preset[field]),Color.WHITE)
	_appearance_controls.preset_name.text=key

func _apply_appearance() -> void:
	var values:Dictionary=_appearance_values()
	command.emit("appearance",values); _appearance_popup.hide()

func _appearance_values() -> Dictionary:
	var values: Dictionary={"id":selected_agent}
	for key in ["face","hair","outfit","shoes"]: values[key]=int(_appearance_controls[key].selected)
	values.height=float(_appearance_controls.height.value)/178.0
	values.build=.85+float(_appearance_controls.build.value)/100.0*.35
	for key in ["skin","hair_color","color"]: values[key]=_appearance_controls[key].color.to_html(false)
	values["preset_name"]=_appearance_controls.preset_name.text.strip_edges()
	return values

func _update_character_preview() -> void:
	if not is_instance_valid(_appearance_popup) or not _appearance_popup.visible or not _state.get("agents",{}).has(selected_agent) or not is_instance_valid(_world):return
	var data:Dictionary=_state.agents[selected_agent].duplicate(true)
	var values:Dictionary=_appearance_values()
	for key in ["face","hair","outfit","shoes","height","build","skin","hair_color"]:data.appearance[key]=values[key]
	data.color=values.color
	_character_preview.texture=_world.preview_character(data)

func _open_god() -> void:
	if not _state.get("agents",{}).has(selected_agent): return
	var agent: Dictionary=_state.agents[selected_agent]
	_god_controls.health.value=float(agent.get("health",100)); _god_controls.hunger.value=float(agent.get("needs",{}).get("hunger",0)); _god_controls.fatigue.value=float(agent.get("needs",{}).get("fatigue",0)); _god_controls.tokens.value=float(agent.get("tokens",0)); _god_controls.blind.button_pressed=bool(agent.get("body",{}).get("blind",false))
	for limb in ["left_arm","right_arm","left_leg","right_leg"]:
		var current: String=str(agent.get("body",{}).get(limb,"healthy")); _god_controls[limb].select(["healthy","injured","broken"].find(current))
	_god_controls.goal.text=str(agent.get("profile",{}).get("goal","")); _god_controls.foundation.text=str(agent.get("profile",{}).get("foundation",""))
	for role in _god_controls.roles:_god_controls.roles[role].button_pressed=agent.get("roles",[]).has(role)
	var doors: Array=[]
	for index in _state.get("geometry",{}).get("doors",[]).size(): doors.append({"ref":str(_state.geometry.doors[index].id),"name":_t("Дверь %d","Door %d")%(index+1)})
	_populate_choice(_god_controls.door,doors,"name",_t("Нет дверей","No doors"))
	_god_controls.room.clear()
	for room in _state.get("geometry",{}).get("rooms",[]): _god_controls.room.add_item(str(room.get("label",room.get("name",_t("Комната","Room"))))); _god_controls.room.set_item_metadata(_god_controls.room.item_count-1,room.get("center",[0,0]))
	_god_popup.popup_centered(Vector2i(780,840))

func _apply_god() -> void:
	_god("set_health",{"id":selected_agent,"health":float(_god_controls.health.value)})
	_god("set_needs",{"id":selected_agent,"hunger":float(_god_controls.hunger.value),"fatigue":float(_god_controls.fatigue.value)})
	_god("set_tokens",{"id":selected_agent,"tokens":int(_god_controls.tokens.value)})
	var body: Dictionary={"blind":_god_controls.blind.button_pressed}
	for limb in ["left_arm","right_arm","left_leg","right_leg"]: body[limb]=str(_god_controls[limb].get_selected_metadata())
	_god("set_body",{"id":selected_agent,"body":body})
	_god("set_goal",{"id":selected_agent,"goal":_god_controls.goal.text})
	_god("set_profile",{"id":selected_agent,"foundation":_god_controls.foundation.text})
	var roles: Array=[]
	for role in _god_controls.roles:
		if _god_controls.roles[role].button_pressed:roles.append(str(role))
	_god("set_role",{"id":selected_agent,"roles":roles})
	_god_popup.hide()

func _apply_settings() -> void:
	var next_language: String="ru" if _language_choice.selected==0 else "en"
	var payload: Dictionary={"language":next_language,"quality":str(_quality.get_selected_metadata()),"speed":float(_speed.value),"sfx_volume":float(_sfx.value)}
	command.emit("settings",payload)
	_settings_popup.hide()
	if next_language!=language:
		language=next_language
		setup.call_deferred(_world)

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	var focus: Control=_root.get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return
	match event.keycode:
		KEY_SPACE: command.emit("run",{"value":not _running})
		KEY_N: command.emit("step",{})
		KEY_V: _toggle_view()
		KEY_F: if is_instance_valid(_world): _world.focus_agent()
		KEY_ESCAPE:
			for child in _root.get_children():
				if child is PopupPanel and child.visible:child.hide();get_viewport().set_input_as_handled();return
			if _journal_panel.visible:_journal_panel.hide()
			elif _roster_panel.visible:_roster_panel.hide()
			else:show_main_menu(not _menu_visible)
		_: return
	get_viewport().set_input_as_handled()

func _format_memory(value: Variant) -> String:
	if value is Dictionary:
		var lines: Array[String]=[]
		for pair in [["summary","Общее воспоминание","Overall memory"],["semantic","Долговременная память","Long-term memory"],["episodic","Эпизоды","Episodes"],["episodes","Эпизоды","Episodes"],["recent","Недавний опыт","Recent experience"],["entries","Личный опыт","Personal experience"]]:
			var key: String=pair[0]
			if not value.has(key): continue
			var section: Array[String]=[]
			if value[key] is Array:
				for entry in value[key].slice(-8): section.append(_memory_entry_text(entry))
			else: section.append(_memory_entry_text(value[key]))
			if not section.is_empty(): lines.append(_t(pair[1],pair[2])+"\n"+"\n\n".join(section))
		return "\n\n".join(lines) if not lines.is_empty() else _t("Личный опыт ещё не накоплен.","No personal experience yet.")
	if value is Array:
		var lines: Array[String]=[]
		for entry in value.slice(maxi(0,value.size()-8)):
			lines.append(_memory_entry_text(entry))
		return "\n\n".join(lines)
	return str(value)

func _memory_entry_text(value: Variant) -> String:
	if value is String: return value
	if not value is Dictionary: return ""
	var lines: Array[String]=[]
	var minute: float=float(value.get("minute",value.get("time",0)))
	if value.has("minute") or value.has("time"): lines.append(_t("День %d, %02d:%02d","Day %d, %02d:%02d")%[int(minute/1440)+1,int(fmod(minute,1440.0)/60.0),int(fmod(minute,60.0))])
	for key in ["text","summary","description","content"]:
		if value.get(key) is String and not str(value[key]).is_empty(): lines.append(str(value[key]))
	var result: Dictionary=value.get("last_result",{}) if value.get("last_result",{}) is Dictionary else {}
	if not result.is_empty(): lines.append(str(result.get("message",result.get("reason",""))))
	for heard in value.get("heard",[]):
		if heard is Dictionary: lines.append(_t("Услышано от ","Heard from ")+str(heard.get("speaker",""))+": "+str(heard.get("text","")))
	for personal in value.get("personal_results",[]):
		if personal is Dictionary and personal.get("text") is String: lines.append(str(personal.text))
	if not str(value.get("image_ref",value.get("image_png_base64",""))).is_empty(): lines.append(_t("Сохранён личный зрительный кадр.","A personal visual observation was recorded."))
	return "\n".join(lines) if not lines.is_empty() else _t("Личное наблюдение","Personal observation")

func _action_text(action: Dictionary) -> String:
	var type: String=str(action.get("type",""))
	var names: Dictionary={"follow_route":_t("Следует по маршруту","Follows a route"),"read_notice":_t("Читает объявление","Reads a notice"),"wait":_t("Ждёт","Waits"),"look":_t("Осматривается","Looks around"),"move":_t("Идёт","Walks"),"move_to":_t("Направляется к цели","Moves toward a target"),"consume":_t("Ест","Eats"),"rest":_t("Отдыхает","Rests"),"sleep":_t("Спит","Sleeps"),"take":_t("Берёт предмет","Takes an item"),"give":_t("Передаёт предмет","Gives an item"),"speak":_t("Говорит","Speaks"),"attack":_t("Атакует","Attacks"),"treat":_t("Оказывает помощь","Treats injuries")}
	return str(names.get(type,type))+(": "+str(action.text) if action.has("text") else "")

func _limb_name(limb: String) -> String:
	var names: Dictionary={"left_arm":_t("Левая рука","Left arm"),"right_arm":_t("Правая рука","Right arm"),"left_leg":_t("Левая нога","Left leg"),"right_leg":_t("Правая нога","Right leg")}
	return str(names.get(limb,limb))

func _t(ru: String, en: String) -> String:
	return ru if language=="ru" else en

func _tab(title: String) -> VBoxContainer:
	var scroll:=ScrollContainer.new(); scroll.name=title; scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED; _tabs.add_child(scroll)
	var box:=VBoxContainer.new(); box.size_flags_horizontal=Control.SIZE_EXPAND_FILL; box.add_theme_constant_override("separation",9); scroll.add_child(box)
	return box

func _dialog(title: String) -> Dictionary:
	var popup:=PopupPanel.new(); popup.exclusive=false; popup.add_theme_stylebox_override("panel",_style(Color("1d3342"),Color("587080"),20,22)); _root.add_child(popup)
	popup.about_to_popup.connect(_before_popup)
	popup.popup_hide.connect(func():_after_popup.call_deferred())
	var scroll:=ScrollContainer.new(); scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED; popup.add_child(scroll)
	var box:=VBoxContainer.new(); box.size_flags_horizontal=Control.SIZE_EXPAND_FILL; box.add_theme_constant_override("separation",13); scroll.add_child(box)
	var header:=HBoxContainer.new(); box.add_child(header); _label(header,title,25,CREAM).size_flags_horizontal=Control.SIZE_EXPAND_FILL; _button(header,"×",func(): popup.hide())
	return {"popup":popup,"box":box}

func _before_popup() -> void:
	if is_instance_valid(_menu):_menu.hide()
	if is_instance_valid(_modal_backdrop):_modal_backdrop.show()

func _after_popup() -> void:
	if is_instance_valid(_appearance_popup) and not _appearance_popup.visible and is_instance_valid(_world):_world.suspend_character_preview()
	for child in _root.get_children():
		if child is PopupPanel and child.visible:return
	if is_instance_valid(_modal_backdrop):_modal_backdrop.hide()
	if _menu_visible and is_instance_valid(_menu):_menu.show()

func _refresh_message_trace() -> void:
	if not is_instance_valid(_trace_message) or not is_instance_valid(_trace_view):return
	var message:Dictionary=_state.get("network",{}).get("messages",{}).get(_choice_ref(_trace_message),{})
	if message.is_empty():_trace_view.text="";return
	var lines:Array[String]=[_t("Исходное сообщение","Original message"),str(message.get("original_text","")),"",_t("Текущая доставляемая версия","Current delivered version"),str(message.get("text","")),"",_t("Редакций: %d","Revisions: %d")%int(message.get("revision",0))]
	for revision in message.get("revisions",[]):
		var actor:String=str(_state.get("agents",{}).get(revision.get("operator",""),{}).get("name",_t("Администратор","Administrator")))
		lines.append(actor+_t(" · день %d"," · day %d")%(int(float(revision.get("minute",0))/1440)+1)+": "+str(revision.get("text","")))
	_trace_view.text="\n".join(lines)

func _panel(parent: Node, color: Color) -> PanelContainer:
	var panel:=PanelContainer.new(); panel.add_theme_stylebox_override("panel",_style(color,Color("385262"),14,12)); parent.add_child(panel); return panel

func _label(parent: Node, text: String, font_size: int=15, color: Color=TEXT) -> Label:
	var label:=Label.new(); label.text=text; label.add_theme_font_size_override("font_size",maxi(14,font_size)); label.add_theme_color_override("font_color",color); parent.add_child(label); return label

func _button(parent: Node, text: String, callback: Callable) -> Button:
	var button:=Button.new(); button.text=text; button.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND; button.pressed.connect(callback); button.custom_minimum_size.y=44; parent.add_child(button); return button

func _rich(parent: Node, height: float=150) -> RichTextLabel:
	var rich:=RichTextLabel.new(); rich.custom_minimum_size.y=height; rich.size_flags_horizontal=Control.SIZE_EXPAND_FILL; rich.selection_enabled=true; rich.add_theme_font_size_override("normal_font_size",14); parent.add_child(rich); return rich

func _spin(parent: Node, minimum: float, maximum: float, value: float, step: float) -> SpinBox:
	var spin:=SpinBox.new(); spin.min_value=minimum; spin.max_value=maximum; spin.step=step; spin.value=value; spin.custom_minimum_size.x=100; parent.add_child(spin); return spin

func _bar(parent: Node, title: String, color: Color) -> ProgressBar:
	var row:=HBoxContainer.new(); parent.add_child(row); _label(row,title,14,MUTED).custom_minimum_size.x=85
	var bar:=ProgressBar.new(); bar.max_value=100; bar.show_percentage=true; bar.custom_minimum_size=Vector2(120,18); bar.size_flags_horizontal=Control.SIZE_EXPAND_FILL; bar.add_theme_stylebox_override("fill",_style(color,color,4,0)); row.add_child(bar); return bar

func _style(color: Color, edge: Color, corner: int=8, padding: int=10) -> StyleBoxFlat:
	var style:=StyleBoxFlat.new(); style.bg_color=color; style.border_color=edge; style.set_border_width_all(1); style.set_corner_radius_all(corner); style.content_margin_left=padding; style.content_margin_right=padding; style.content_margin_top=padding; style.content_margin_bottom=padding; return style

func _theme() -> Theme:
	var theme:=Theme.new();theme.default_font_size=14
	for type in ["Label","Button","OptionButton","MenuButton","CheckButton","LineEdit","TextEdit","TabBar","PopupMenu"]:theme.set_color("font_color",type,CREAM)
	theme.set_color("default_color","RichTextLabel",CREAM)
	for type in ["Button","OptionButton","MenuButton"]:
		theme.set_stylebox("normal",type,_style(Color("2b4655"),Color("4b6570"),10,10));theme.set_stylebox("hover",type,_style(Color("3a5c67"),SAGE,10,10));theme.set_stylebox("pressed",type,_style(Color("47675f"),SAGE,10,10));theme.set_stylebox("focus",type,_style(Color(0,0,0,0),GOLD,10,10));theme.set_color("font_hover_color",type,Color.WHITE);theme.set_color("font_pressed_color",type,CREAM);theme.set_constant("outline_size",type,0)
	for type in ["LineEdit","TextEdit"]:
		theme.set_stylebox("normal",type,_style(Color("122936"),Color("526d78"),9,12));theme.set_stylebox("focus",type,_style(Color("183442"),SAGE,9,12));theme.set_color("font_placeholder_color",type,MUTED)
	theme.set_stylebox("panel","PopupMenu",_style(Color("203b4a"),Color("587080"),10,10));theme.set_constant("v_separation","PopupMenu",14)
	theme.set_stylebox("panel","TabContainer",_style(Color("1d3342"),Color("1d3342"),0,3))
	for type in ["TabContainer","TabBar"]:
		theme.set_stylebox("tab_selected",type,_style(Color("3c5a60"),SAGE,7,9));theme.set_stylebox("tab_unselected",type,_style(Color("253f4d"),Color("253f4d"),7,9));theme.set_color("font_selected_color",type,CREAM);theme.set_color("font_unselected_color",type,MUTED)
	theme.set_stylebox("background","ProgressBar",_style(Color("314c58"),Color("314c58"),4,0));theme.set_stylebox("fill","ProgressBar",_style(SAGE,SAGE,4,0))
	theme.set_constant("minimum_grab_thickness","VScrollBar",8)
	return theme

func _wrapped_label(parent:Node,text:String,font_size:int=15,color:Color=TEXT)->Label:
	var label:=_label(parent,text,font_size,color);label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;label.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	return label

func _accent_button(button:Button)->void:
	button.add_theme_stylebox_override("normal",_style(SAGE,SAGE,10,12));button.add_theme_stylebox_override("hover",_style(CREAM,CREAM,10,12));button.add_theme_color_override("font_color",INK);button.add_theme_color_override("font_hover_color",INK);button.add_theme_font_size_override("font_size",17)

func _map_description(index:int)->String:
	return [
		_t("Поставка задерживается. Хватит ли запасов до вечера, и кто откроет резерв?","The delivery is late. Will the rations last until evening, and who will open the reserve?"),
		_t("В лавке дорожает еда. Трое соседей остались без денег и зависят от решений остальных.","Food prices are rising. Neighbours without money depend on what the others decide."),
		_t("Приближается шторм. Два сообщения указывают разные места сбора, а одному участнику нужна помощь.","A storm is coming. Two messages name different assembly points, and one person needs help.")
	][clampi(index,0,2)]

func _update_story_cards()->void:
	if is_instance_valid(_story_description):_story_description.text=_map_description(_map_choice.selected)

func _event_caption(event:Dictionary,count:int=1)->String:
	var minute:float=float(event.get("minute",0))+float(_state.get("scenario_state",{}).get("display_start_minute",_state.get("display_start_minute",0)))
	var actor:String=str(event.get("actor",""));var person:String=str(_state.get("agents",{}).get(actor,{}).get("name",_t("Мир","World")))
	var message:String=str(event.get("message_en",event.get("message",""))) if language=="en" else str(event.get("message",event.get("type","")))
	message=message.replace("\n"," ")
	if language=="en" and event.get("type","")=="session_started":
		var index:int=maxi(0,MAP_IDS.find(str(_state.get("map_id","closed_block"))))
		message="New session in %s with %d residents."%[MAP_EN[index],_state.get("agents",{}).size()]
	return "%02d:%02d  ·  %s  ·  %s%s"%[int(fmod(minute,1440.0)/60.0),int(fmod(minute,60.0)),person,message,("  ×%d"%count) if count>1 else ""]

func _event_context(event:Dictionary)->String:
	var location:String=_place_name(event.get("place",{}))
	if location.is_empty():location=_t("Не указано","Unspecified")
	var cause:Variant=event.get("cause")
	var reason:String=_t("Не зафиксирована","Unrecorded")
	if (cause is int or cause is float) and _event_lookup.has(str(int(cause))):
		reason=_event_caption(_event_lookup[str(int(cause))],1)
	return _t("Где · %s   /   Причина · %s","Where · %s   /   Cause · %s")%[location,reason]

func _event_position(event:Dictionary)->Array:
	var point:Variant=event.get("position",event.get("details",{}).get("position",[]))
	if point is Array and point.size()==2:return point
	var place_id:String=str(event.get("place",{}).get("id",""))
	for room in _state.get("geometry",{}).get("rooms",[]):
		if not place_id.is_empty() and str(room.get("id",""))==place_id:return room.get("center",[])
	return []

func _focus_event(event:Dictionary)->void:
	var payload:Dictionary={"seq":int(event.get("seq",0)),"actor":str(event.get("actor",""))}
	var position:=_event_position(event)
	if not position.is_empty():payload.position=position
	if _first_person and not position.is_empty():_toggle_view()
	if _state.get("agents",{}).has(payload.actor):_pick_person(str(payload.actor))
	command.emit("focus_event",payload)

func _event_button(parent:Node,event:Dictionary,count:int)->Button:
	var full_chronicle:bool=parent==_journal_rows
	var button:=_button(parent,_event_caption(event,count),func():
		if full_chronicle:
			_selected_event=event
			_selection_details.text=_event_context(event)
			_show_event_place.disabled=_event_position(event).is_empty()
			_journal_selection.show()
			if not _show_event_place.disabled:_show_event_place.grab_focus()
		else:_focus_event(event))
	button.alignment=HORIZONTAL_ALIGNMENT_LEFT;button.clip_text=true;button.tooltip_text=_event_caption(event,count)+"\n"+_event_context(event);button.size_flags_horizontal=Control.SIZE_EXPAND_FILL;button.custom_minimum_size.y=36
	if full_chronicle:
		button.toggle_mode=true;button.button_group=_event_group
		button.button_pressed=not _selected_event.is_empty() and event.seq==_selected_event.seq
	button.add_theme_stylebox_override("normal",_style(Color("263e4b"),Color("263e4b"),7,8))
	if not bool(event.get("ok",true)):button.add_theme_color_override("font_color",CORAL)
	return button

func _refresh_alpha_state()->void:
	var scenario:Dictionary=_state.get("scenario_state",{})
	var map_index:int=MAP_IDS.find(str(_state.get("map_id","closed_block")));map_index=maxi(0,map_index)
	_scenario_title.text=_story_value(scenario,"title",MAP_RU[map_index] if language=="ru" else MAP_EN[map_index])
	_phase_label.text=_t("ГЛАВА %d / 3","CHAPTER %d / 3")%int(scenario.get("phase",1)) if not scenario.is_empty() else _t("ПЕСОЧНИЦА","SANDBOX")
	_problem.text=_story_value(scenario,"current_problem",_t("Наблюдайте за людьми и их решениями.","Observe people and their choices."));_problem.tooltip_text=_problem.text
	var actor:Dictionary=_state.get("agents",{}).get(selected_agent,{})
	var activity:Dictionary=actor.get("activity_status",{}).duplicate(true)
	var runtime_status:Variant=_info.get("agent_statuses",{}).get(selected_agent,{})
	if runtime_status is Dictionary:activity.merge(runtime_status,true)
	_card_activity=activity
	var action_value:Variant=activity.get("activity",actor.get("last_action",{}))
	var action:String=_action_text(action_value) if action_value is Dictionary else _activity_name(str(action_value))
	if action.is_empty():action=_t("Наблюдает за миром","Observing the world")
	var target:String=str(activity.get("target",""))
	_activity.text=action+(" · "+target if not target.is_empty() else "")
	var location:String=_place_name(activity.get("place",{}))
	if not location.is_empty():_activity.text+=" · "+location
	var intent_value:Variant=activity.get("declared_intent",activity.get("intent",{}))
	var intention:String=_action_text(intent_value) if intent_value is Dictionary else str(intent_value)
	_intent.text=(_t("Намерение: ","Intention: ")+intention) if not intention.is_empty() else (_t("Личная цель: ","Personal goal: ")+_profile_goal(str(actor.get("profile",{}).get("goal",_t("Не задана","Not set")))))
	_intent.tooltip_text=_t("Заявленное намерение или заданная цель. Это не скрытые рассуждения модели.","Declared intention or configured goal. This is not hidden model reasoning.")
	var blocked:String=str(activity.get("blocked_reason",""))
	var ai_state:String=str(activity.get("ai_state",activity.get("decision_state","")))
	var real_mode:bool=_info.get("mode","")=="real_vlm" or _info.get("connection",{}).get("enabled",false)
	_obstacle.text=(_t("Препятствие: ","Blocked: ")+blocked) if not blocked.is_empty() else (_t("Ожидает решения AI","Waiting for an AI decision") if real_mode and ai_state in ["waiting","queued","requesting","thinking","pending"] else "")
	_obstacle.visible=not _obstacle.text.is_empty()
	var progress:float=float(activity.get("progress",-1));_activity_progress.visible=progress>=0;_activity_progress.value=progress*100.0 if progress<=1.0 else progress
	var signature:String=selected_agent+JSON.stringify(actor.get("appearance",{}))+str(actor.get("color",""))
	if signature!=_portrait_signature and is_instance_valid(_world) and _world.has_method("character_portrait"):
		var portrait:Texture2D=_world.character_portrait(actor)
		_portrait_image.texture=portrait
		if portrait!=null:_portrait_signature=signature
	var connection:Dictionary=_info.get("connection",{});var enabled:bool=bool(connection.get("enabled",false)) or _info.get("mode","")=="real_vlm"
	var waiting:bool=bool(connection.get("waiting",false)) or bool(_info.get("waiting",false))
	var states:Variant=_info.get("decision_states",{})
	_retry_decision.visible=ai_state=="error"
	if states is Dictionary:
		var decision:Variant=states.get(selected_agent,{})
		if decision is Dictionary and str(decision.get("state",""))=="error":_retry_decision.show()
		for value in states.values():
			var state_name:String=str(value.get("state","")) if value is Dictionary else str(value)
			if state_name in ["waiting","queued","requesting","pending","thinking"]:waiting=true
	var error_text:String=str(connection.get("error",connection.get("last_error","")))
	var pause_reason:String=str(connection.get("pause_reason","")).strip_edges()
	_status.tooltip_text=""
	if not pause_reason.is_empty():_status.text=pause_reason;_status.tooltip_text=pause_reason;_status.add_theme_color_override("font_color",CORAL)
	elif not error_text.is_empty():_status.text=_t("Ошибка подключения · откройте настройки","Connection error · open settings");_status.tooltip_text=error_text;_status.add_theme_color_override("font_color",CORAL)
	elif not _running:_status.text=_t("Пауза · время остановлено","Paused · time is stopped");_status.add_theme_color_override("font_color",CREAM)
	elif waiting and real_mode:_status.text=_t("Ожидание AI · решения готовятся","Waiting for AI · decisions are pending");_status.add_theme_color_override("font_color",GOLD)
	else:_status.text=_t("История развивается","The story is unfolding");_status.add_theme_color_override("font_color",SAGE)
	var missing_key:bool=enabled and not bool(connection.get("enabled",false)) and not bool(connection.get("has_key",false))
	_mode.text=_t("RouterAI · требуется подключение","RouterAI · connection required") if missing_key else (_t("RouterAI · подключено","RouterAI · connected") if enabled else _t("ДЕМО · без AI","DEMO · no AI"))
	_mode.add_theme_color_override("font_color",SAGE if enabled and not missing_key else CORAL)
	var effective:float=float(_info.get("effective_speed",_info.get("settings",{}).get("speed",1)))
	_effective_speed.text=_t("Темп %.1f×","Pace %.1f×")%effective
	_refresh_districts()

const PLACES_EN={
 "Северная спальня": "North dormitory",
 "Кухня и столовая": "Kitchen and dining room",
 "Медпункт": "Infirmary",
 "Погрузочный шлюз": "Loading bay",
 "Выдача пайков": "Rations desk",
 "Резерв блока": "Block reserves",
 "Комната связи": "Communications room",
 "Южная спальня": "South dormitory",
 "Общий зал": "Common room",
 "Мастерская": "Workshop",
 "Обменный пункт": "Exchange",
 "Архив блока": "Block archives",
 "Дом у часов": "Clock House",
 "Дом с садом": "Garden House",
 "Почтовая": "Post office",
 "Общая кладовая": "Community stores",
 "Общественная кухня": "Communal kitchen",
 "Зал собраний": "Assembly hall",
 "Аптечный пункт": "Pharmacy",
 "Доска связи": "Noticeboard",
 "Продуктовая лавка": "Grocery",
 "Пункт оборудования": "Equipment desk",
 "Читальный зал": "Reading room",
 "Спальные каюты": "Sleeping quarters",
 "Камбуз": "Galley",
 "Комната отдыха": "Recreation room",
 "Медицинский блок": "Medical bay",
 "Лаборатория": "Laboratory",
 "Архив наблюдений": "Observation archive",
 "Наблюдательная": "Observation deck",
 "Узел связи": "Comms hub",
 "Склад экспедиции": "Expedition stores",
 "Северный шлюз": "North airlock",
 "Южный сборный пункт": "South muster point",
 "Жилое крыло": "Residential wing",
 "Общий двор": "Courtyard",
 "Снабжение и связь": "Supply and comms",
 "Жилые дворы": "Residential courts",
 "Общественный проспект": "Civic avenue",
 "Торговая улица": "Market street",
 "Жилой модуль": "Habitat module",
 "Исследовательский модуль": "Research module",
 "Связь и эвакуация": "Comms and evacuation",
 "Двор и переходы": "Courtyard and passages"
}
const GOALS_EN={
 "Познакомиться с людьми, узнать их нужды и предложить взаимопомощь.": "Meet people, learn what they need and offer mutual support.",
 "Лично проверить правила выдачи и помочь распределить ограниченные запасы.": "Check the ration rules in person and help share limited supplies.",
 "Найти узел связи, проверить важные сведения и поддерживать доступную связь.": "Find the comms hub, verify important news and keep channels open.",
 "Найти медицинские средства, осмотреть нуждающихся и предложить помощь.": "Find medical supplies, examine those in need and offer help.",
 "Изучить местные документы, сравнивать независимые источники и сохранять находки.": "Read local documents, compare independent sources and keep a record.",
 "Знакомиться лично, передавать проверенные новости и помогать договариваться.": "Meet people, share verified news and help them reach agreements.",
 "Проверить ассортимент магазина, искать честные сделки и беречь собственные средства.": "Check the shop, find fair trades and look after personal funds.",
 "Осмотреть новое место, найти пищу, познакомиться и попросить помощь при необходимости.": "Explore the new place, find food, meet others and ask for help when needed."
}

func _item_name(item:Dictionary)->String:
	var label:String=str(item.get("label",_t("Предмет","Item")))
	var english:Dictionary={"Телефон":"Phone","Личный дневник":"Personal diary","Паёк":"Ration","Аптечка":"First-aid kit","Шина":"Splint","Фотоаппарат":"Camera","Нож":"Knife","Запас общего резерва":"Community reserve ration"}
	return str(english.get(label,label)) if language=="en" else label

func _place_name(place:Dictionary)->String:
	var label:String=str(place.get("label",place.get("id","")))
	return str(PLACES_EN.get(label,label)) if language=="en" else label

func _profile_goal(goal:String)->String:
	if language=="ru":return goal
	var station_duty:=" До конца смены найти действующее место сбора, проверить объявление лично и добраться туда; при необходимости просить помощь."
	if goal.ends_with(station_duty):
		return str(GOALS_EN.get(goal.trim_suffix(station_duty),goal.trim_suffix(station_duty)))+" Verify the assembly notice in person and reach the correct muster point by the end of the shift. Ask for help if needed."
	return str(GOALS_EN.get(goal,goal))

func _story_value(record:Dictionary, field:String, fallback:String="") -> String:
	return str(record.get(field+"_en",record.get(field,fallback))) if language=="en" else str(record.get(field,fallback))

func _resize_canvas() -> void:
	if is_instance_valid(_central) and is_instance_valid(_world) and _world.has_method("set_display_size"):
		_world.set_display_size(Vector2i(_central.size*_central.get_screen_transform().get_scale()))

func _portrait_ready(signature:String, texture:Texture2D) -> void:
	var actor:Dictionary=_state.get("agents",{}).get(selected_agent,{})
	if signature==JSON.stringify(actor.get("appearance",{}))+str(actor.get("color","")) and is_instance_valid(_portrait_image):
		_portrait_image.texture=texture
		_portrait_signature=selected_agent+signature

func _activity_name(value:String)->String:
	var names:Dictionary={"idle":_t("Осматривается","Looking around"),"moving":_t("Идёт к цели","Walking to a destination"),"walking":_t("Идёт","Walking"),"waiting":_t("Ждёт","Waiting"),"sleeping":_t("Спит","Sleeping"),"resting":_t("Отдыхает","Resting"),"eating":_t("Ест","Eating"),"talking":_t("Разговаривает","Talking"),"unconscious":_t("Без сознания","Unconscious"),"dead":_t("Погиб","Dead")}
	return str(names.get(value,_action_text({"type":value})))

func _build_map_dialog()->void:
	var content:=_dialog(_t("Карта и места","Map & places"));_detail_popup=content.popup
	_wrapped_label(content.box,_t("Выберите район, чтобы переместить камеру. Полная карта доступна наблюдателю.","Choose a district to move the camera. The full map is available to the observer."),15,MUTED)
	_district_choice=OptionButton.new();content.box.add_child(_district_choice)
	var focus:=_button(content.box,_t("Показать на карте","Show on map"),func():
		if _district_choice.item_count>0:command.emit("focus_event",{"seq":-1,"actor":"","position":_district_choice.get_selected_metadata()});_detail_popup.hide())
	_accent_button(focus)
	_button(content.box,_t("Следить за выбранным героем","Follow selected person"),func():if is_instance_valid(_world):_world.focus_agent();_detail_popup.hide())

func _refresh_districts()->void:
	var geometry:Dictionary=_state.get("geometry",{});var entries:Array=geometry.get("districts",[]).duplicate(true)
	entries.append_array(geometry.get("landmarks",[]))
	if entries.is_empty():entries=geometry.get("rooms",[])
	var signature:String=JSON.stringify(entries)
	if signature==_district_signature:return
	_district_signature=signature;_district_choice.clear()
	for entry in entries:
		_district_choice.add_item(_place_name(entry));_district_choice.set_item_metadata(_district_choice.item_count-1,entry.get("center",[0,0]))

func _show_map_navigation()->void:
	_refresh_districts();_detail_popup.popup_centered_clamped(Vector2i(620,370),0.9)

func _build_chapter_dialog()->void:
	var content:=_dialog(_t("Ваша история","Your story"));_chapter_popup=content.popup
	_chapter_title=_wrapped_label(content.box,"",28,CREAM)
	_chapter_text=_rich(content.box,170);_chapter_text.fit_content=true;_chapter_text.scroll_active=false
	_intervention_box=VBoxContainer.new();_intervention_box.add_theme_constant_override("separation",8);content.box.add_child(_intervention_box)
	_chapter_continue=_button(content.box,_t("Продолжить наблюдение","Continue observing"),func():
		_chapter_popup.hide()
		if not _running and not bool(_state.get("scenario_state",{}).get("completed",false)):command.emit("run",{"value":true}))
	_accent_button(_chapter_continue)

func _refresh_chapter()->void:
	if _menu_visible or _info.get("replaying",false) or not is_instance_valid(_chapter_popup):return
	if _replacing_run==int(_state.get("run_id",0)):return
	_replacing_run=-1
	var scenario:Dictionary=_state.get("scenario_state",{})
	if scenario.is_empty():return
	var key:String=str(_state.get("run_id",0))+":"+str(scenario.get("phase",1))
	var done:bool=bool(scenario.get("completed",false))
	if done and _debrief_key!=str(_state.get("run_id",0)):
		_debrief_key=str(_state.get("run_id",0));_present_chapter(int(_state.get("run_id",0)),int(scenario.get("phase",1)),true)
	elif not done and key!=_seen_chapter:
		_seen_chapter=key;_present_chapter(int(_state.get("run_id",0)),int(scenario.get("phase",1)),false)

func _present_chapter(run:int,phase:int,done:bool) -> void:
	# Let the originating popup release window focus before opening its successor.
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(_chapter_popup) or _menu_visible or _info.get("replaying",false) or run!=int(_state.get("run_id",0)):return
	var story:Dictionary=_state.get("scenario_state",{})
	if not story.is_empty() and phase==int(story.get("phase",1)) and done==bool(story.get("completed",false)):_show_chapter(story,done)

func _show_chapter(scenario:Dictionary,debrief:bool)->void:
	for child in _intervention_box.get_children():child.queue_free()
	if debrief:
		_chapter_title.text=_story_value(scenario.get("outcome",{}),"title",_t("День завершён","The day is complete"))
		var lines:Array[String]=[]
		for line in scenario.get("debrief_en" if language=="en" and scenario.has("debrief_en") else "debrief",[]):lines.append(str(line))
		_chapter_text.text="\n\n".join(lines)
		_button(_intervention_box,_t("Скачать отчёт","Download report"),func():command.emit("download_report",{}))
		_button(_intervention_box,_t("Продолжить в песочнице","Continue in sandbox"),func():command.emit("continue_sandbox",{});_chapter_popup.hide())
		_chapter_continue.text=_t("Вернуться в мир","Return to the world")
	else:
		_chapter_title.text=_t("Глава %d · ","Chapter %d · ")%int(scenario.get("phase",1))+_story_value(scenario,"phase_title")
		_chapter_text.text=_story_value(scenario,"description")+"\n\n"+_story_value(scenario,"current_problem")
		for intervention in scenario.get("interventions",[]):
			if bool(intervention.get("used",false)):continue
			var choice:Dictionary=intervention
			var message:LineEdit
			if choice.id=="announcement":
				message=LineEdit.new();message.max_length=280;message.placeholder_text=_t("Текст публичного объявления","Public announcement text");_intervention_box.add_child(message)
			var button:=_button(_intervention_box,_story_value(choice,"title"),func():
				var payload:Dictionary={"id":choice.id}
				if message!=null:payload.text=message.text.strip_edges()
				command.emit("scenario_intervention",payload);_chapter_popup.hide())
			if message!=null:
				button.disabled=true
				message.text_changed.connect(func(value):button.disabled=value.strip_edges().is_empty())
			button.tooltip_text=_story_value(choice,"description")
		_chapter_continue.text=_t("Начать наблюдение","Start observing") if int(scenario.get("phase",1))==1 else _t("Продолжить наблюдение","Continue observing")
	_chapter_popup.popup_centered_clamped(Vector2i(760,680),0.9)

func _refresh_appearance_capabilities()->void:
	var capabilities:Dictionary={"faces":6,"hairs":4,"outfits":4,"shoes":0}
	if is_instance_valid(_world) and _world.has_method("appearance_capabilities"):capabilities.merge(_world.appearance_capabilities(),true)
	for pair in [["face","faces"],["hair","hairs"],["outfit","outfits"],["shoes","shoes"]]:
		var choice:OptionButton=_appearance_controls[pair[0]];var count:int=int(capabilities.get(pair[1],0))
		for index in choice.item_count:choice.set_item_disabled(index,index>=count)
		choice.disabled=count<=0
		if choice.selected>=count and count>0:choice.select(0)
		choice.tooltip_text=_t("Доступно вариантов: %d","Available options: %d")%count

func _randomize_appearance()->void:
	_refresh_appearance_capabilities()
	for field in ["face","hair","outfit","shoes"]:
		var choice:OptionButton=_appearance_controls[field];var available:Array=[]
		for index in choice.item_count:
			if not choice.is_item_disabled(index):available.append(index)
		if not available.is_empty():choice.select(available.pick_random())
	_appearance_controls.height.value=randi_range(155,195)
	_appearance_controls.build.value=[20,50,80].pick_random()
	_appearance_controls.skin.color=Color(["f0d4bd","e1b994","c99372","a96d50","81523f","573b32","d8b4a2","c5a883"].pick_random())
	_appearance_controls.hair_color.color=Color(["27252a","49382f","79513b","b18552","d1b671","863e35","b4a8a1","424b62"].pick_random())
	_appearance_controls.color.color=Color(["9fcbb5","ee947f","e1bd78","82aabc","aca3cb","e6ddc7","608c84","bb7885"].pick_random())
	_update_character_preview()
