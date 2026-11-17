extends SceneTree
## Real-renderer alpha HUD checks; no main/runtime, credentials, HTTP or paid calls.
const Sim=preload("res://scripts/game/session_simulation.gd")
const World=preload("res://scripts/release_world/world_view.gd")
const UI=preload("res://scripts/release_ui/observer_ui.gd")
var failures:Array=[]
var commands:Array=[]
func _initialize()->void:run.call_deferred()
func check(ok:bool,caption:String)->void:
	print(("PASS " if ok else "FAIL ")+caption)
	if not ok:failures.append(caption)
func frames(count:int=4)->void:
	for frame in count:await process_frame
	await RenderingServer.frame_post_draw
func press_enter()->void:
	for pressed in [true,false]:
		var key:=InputEventKey.new();key.keycode=KEY_ENTER;key.pressed=pressed;root.push_input(key,true);await process_frame
	await frames(2)
func click(control:Control)->void:
	var point:=control.get_global_rect().get_center()
	var motion:=InputEventMouseMotion.new();motion.position=point;motion.global_position=point;root.push_input(motion,true);await process_frame
	for pressed in [true,false]:
		var mouse:=InputEventMouseButton.new();mouse.button_index=MOUSE_BUTTON_LEFT;mouse.pressed=pressed;mouse.position=point;mouse.global_position=point;root.push_input(mouse,true);await process_frame
	await frames(2)
func run()->void:
	root.size=Vector2i(1366,768)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test-output/alpha-ui"))
	var sim=Sim.new();sim.reset("closed_block",8,"episode",11)
	var state:Dictionary=sim.snapshot()
	var world=World.new();root.add_child(world);world.setup(state)
	var ui=UI.new();root.add_child(ui);ui.setup(world)
	ui.command.connect(func(name,payload):commands.append({"name":name,"payload":payload}))
	var info:Dictionary={"selected":"person_00","mode":"demo","connection":{"enabled":false},"settings":{"speed":1},"agent_statuses":{},"decision_states":{}}
	ui.refresh(state,{},info);ui.show_main_menu(false);ui.refresh(state,{},info);await frames(12)
	check(ui._action_text({"type":"follow_route"})=="Следует по маршруту","Russian inspector names route following in plain language")
	check(ui._chapter_popup.visible,"A new episode opens on its chapter introduction")
	check(ui._portrait_image.texture!=null,"Selected person has a rendered portrait on first refresh")
	check(ui._drawer.visible,"Selected activity card visible by default")
	check(ui._live_events.get_child_count()>0,"Persistent chronicle includes actual events")
	check(ui._count.value==8,"New story defaults to eight people")
	check(ui._scenario_choice.get_item_metadata(0)=="episode","Canonical episode is default")
	check(ui._problem.text==str(state.get("scenario_state",{}).get("current_problem","")),"Current problem reflects scenario state")
	ui._chapter_continue.pressed.emit();await frames()
	check(commands.any(func(entry):return entry.name=="run" and entry.payload.value==true),"Start observing begins simulation from the introduction")
	check(root.get_texture().get_image().get_size()==Vector2i(1366,768),"1366×768 fills the client with no imposed aspect ratio")
	root.get_texture().get_image().save_png("res://test-output/alpha-ui/hud_1366_ru.png")
	var first_event:Button=ui._live_events.get_child(0)
	first_event.pressed.emit();check(commands.any(func(entry):return entry.name=="focus_event"),"Chronicle event emits focus command")
	check(ui.selected_agent=="person_00","World events retain the selected person")
	ui._journal_panel.show()
	ui._event_search.text="impossible query 049201";ui._event_search.text_changed.emit(ui._event_search.text)
	check(ui._journal.text.is_empty(),"Search filters history")
	ui._event_search.clear();ui._event_search.text_changed.emit("")
	ui._journal_panel.show();await frames();root.get_texture().get_image().save_png("res://test-output/alpha-ui/chronicle_1366_ru.png");ui._journal_panel.hide()
	ui.show_main_menu(true);await frames();root.get_texture().get_image().save_png("res://test-output/alpha-ui/menu_1366_ru.png")
	ui.show_main_menu(false);ui._open_appearance();await frames(10);check(ui._appearance_popup.visible,"Appearance editor opens for selected person");root.get_texture().get_image().save_png("res://test-output/alpha-ui/editor_1366_ru.png");ui._appearance_popup.hide()
	ui._show_phone();await frames();root.get_texture().get_image().save_png("res://test-output/alpha-ui/phone_1366_ru.png");ui._phone_popup.hide()
	root.size=Vector2i(1920,1080);ui.set_language("en");await frames(14);ui.refresh(state,{},info);ui.show_main_menu(false);ui._chapter_popup.hide();await frames()
	root.get_texture().get_image().save_png("res://test-output/alpha-ui/hud_1920_en.png")
	check(root.get_texture().get_image().get_size()==Vector2i(1920,1080),"1920×1080 fills the client")
	check(ui._problem.text==state.scenario_state.current_problem_en,"English episode objective is localized")
	world.set_first_person(true);ui.refresh(state,{},info);await frames()
	check(ui._central.texture==world.human_viewport.get_texture() and ui._central.texture.get_width()>640,"Human eye camera renders at HUD resolution")
	root.get_texture().get_image().save_png("res://test-output/alpha-ui/pov_1920_en.png")
	world.set_first_person(false)
	for map_id in ["residence","research_station"]:
		sim.reset(map_id,8,"episode",11);state=sim.snapshot();world.setup(state);ui.refresh(state,{},info);await frames(12)
		check(ui._chapter_popup.visible and ui._chapter_text.text.contains(state.scenario_state.description_en),"Replaced episode presents its own chapter "+map_id)
		var map_index:int=ui.MAP_IDS.find(map_id)
		check(ui._live_events.get_child(-1).text.contains(ui.MAP_EN[map_index]),"Replaced episode resets its chronicle "+map_id)
		ui._chapter_popup.hide();await frames()
		root.get_texture().get_image().save_png("res://test-output/alpha-ui/"+map_id+"_1920_en.png")
	check(ui._central.size.x>500 and ui._central.size.y>300,"World canvas remains usable at desktop sizes")
	check(ui._drawer.get_global_rect().end.x<=root.size.x,"Inspector fits viewport")
	var events:Array=[]
	for i in 94:events.append({"seq":i,"type":"speak","message":"History marker %03d"%i,"actor":"person_00"})
	events[83].merge({"place":{"id":"dining","label":"Кухня и столовая"},"position":[11.25,4.5],"cause":0})
	info["chronicle_events"]=events;info["slots"]=[{"slot":3,"exists":true}];info["decision_states"]={"person_00":{"state":"error","reason":"Test timeout"}};info.connection={"mode":"real_vlm","has_key":false,"pause_reason":"Test pause"};info.mode="real_vlm"
	ui.refresh(state,{},info);ui._journal_panel.show();await frames()
	check(ui._journal_rows.get_child_count()==40 and ui._older_events.disabled==false,"Full chronicle renders 40 filtered matches per page")
	ui._older_events.pressed.emit();ui._older_events.pressed.emit();await frames()
	check(ui._journal.text.contains("History marker 000") and ui._older_events.disabled,"Oldest historical events remain reachable")
	ui._event_search.text="marker 083";ui._event_search.text_changed.emit(ui._event_search.text);await frames()
	check(ui._journal_page==0 and ui._journal_rows.get_child_count()==1,"Search scans the entire archive and resets pagination")
	ui._journal_rows.get_child(0).grab_focus();await press_enter()
	check(ui._journal_selection.visible and ui._selection_details.text.contains("Kitchen and dining room") and ui._selection_details.text.contains("History marker 000") and ui._show_event_place.has_focus(),"Keyboard selection exposes event place and earlier cause above the results")
	await click(ui._show_event_place)
	check(not ui._journal_panel.visible and commands[-1].name=="focus_event" and commands[-1].payload.position==[11.25,4.5],"Clicking Show location reveals the recorded event coordinates")
	ui._journal_panel.show();await frames();await click(ui._journal_rows.get_child(0))
	check(ui._journal_selection.visible and ui._selected_event.seq==83,"Click selects the same historical event without hovering")
	root.get_texture().get_image().save_png("res://test-output/alpha-ui/chronicle_detail_1920_en.png")
	await press_enter();check(not ui._journal_panel.visible and commands[-1].name=="focus_event" and commands[-1].payload.seq==83,"Enter opens the recorded place and closes the chronicle")
	check(ui._retry_decision.visible and ui._mode.text.contains("required") and ui._status.text=="Test pause","AI failures and disconnected credentials are visible")
	ui._retry_decision.pressed.emit();check(commands.any(func(entry):return entry.name=="retry_agent" and entry.payload.id=="person_00"),"Retry targets only the selected person")
	ui.show_main_menu(true);check(ui._continue_save.visible,"Startup menu offers a saved story when the autosave exists")
	ui._continue_save.pressed.emit();check(commands.any(func(entry):return entry.name=="load" and entry.payload.slot==3),"Continue saved story loads the autosave")
	FileAccess.open("res://test-output/alpha-ui/report.json",FileAccess.WRITE).store_string(JSON.stringify({"failures":failures,"paid_api_calls":0},"  "))
	print("ALPHA_UI failures=",failures.size());quit(1 if not failures.is_empty() else 0)
