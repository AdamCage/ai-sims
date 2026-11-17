extends SceneTree
## Independent real-renderer integration checks. Run ONLY with -- --test-profile.
## Uses temporary save/ledger paths; never reads a key or enables a provider.
const Main=preload("res://scripts/release_main.gd")
const Ledger=preload("res://scripts/release_ai/usage_ledger.gd")
var game:Node
var failures:Array=[]
var checks:=0
var test_root:=""

class FakeCatalog extends Node:
	var calls:Array=[]
	func request_quote(model:String,tag:int,preference:String="",minimum_validity:int=0)->Error:
		calls.append([model,tag,preference,minimum_validity]);return OK

func _initialize()->void:
	run.call_deferred()

func check(ok:bool,message:String)->void:
	checks+=1
	if not ok:failures.append(message);printerr("FAIL UI QA: ",message)
	else:print("PASS UI QA: ",message)

func frames(count:int=3)->void:
	for i in count:await process_frame
	await RenderingServer.frame_post_draw

func settle()->void:
	var deadline:=Time.get_ticks_msec()+12000
	while is_instance_valid(game) and (game.collecting or game.advancing or game._single_step) and Time.get_ticks_msec()<deadline:
		await process_frame
	check(not game.collecting and not game.advancing,"pending offline operation terminates")
	await frames(2)

func find_button(fragment:String)->Button:
	for node in game.ui._root.find_children("*","Button",true,false):
		if node is Button and fragment in node.text:
			if node.is_visible_in_tree() and node.get_window().visible:return node
	return null

func reveal(control:Control)->void:
	var parent:=control.get_parent()
	while parent!=null:
		if parent is ScrollContainer:
			parent.ensure_control_visible(control)
		parent=parent.get_parent()
	await frames(2)

func click_at(viewport:Viewport,point:Vector2)->void:
	var motion:=InputEventMouseMotion.new();motion.position=point;motion.global_position=point
	viewport.push_input(motion,true);await process_frame
	var press:=InputEventMouseButton.new();press.position=point;press.global_position=point;press.button_index=MOUSE_BUTTON_LEFT;press.pressed=true
	viewport.push_input(press,true);await process_frame
	var release:InputEventMouseButton=press.duplicate();release.pressed=false
	viewport.push_input(release,true);await frames(2)

func click(control:Control)->void:
	if control==null:check(false,"requested clickable control exists");return
	await reveal(control)
	var point:=control.get_global_rect().get_center()
	var viewport:Viewport=control.get_viewport()
	if viewport is Window and viewport!=root and viewport.is_embedded():
		point+=Vector2(viewport.position);viewport=root
	await click_at(viewport,point)

func key(code:Key)->void:
	var event:=InputEventKey.new();event.keycode=code;event.physical_keycode=code;event.pressed=true
	root.push_input(event,true);await process_frame
	event=event.duplicate();event.pressed=false;root.push_input(event,true);await frames(2)

func choose(control:OptionButton,index:int)->void:
	await click(control)
	var popup:PopupMenu=control.get_popup()
	var panel:StyleBox=popup.get_theme_stylebox("panel")
	var top:float=panel.get_content_margin(SIDE_TOP);var bottom:float=panel.get_content_margin(SIDE_BOTTOM)
	var item_height:float=(float(popup.size.y)-top-bottom)/float(control.item_count)
	var point:=Vector2(popup.position)+Vector2(float(popup.size.x)/2.0,top+(float(index)+.5)*item_height)
	await click_at(root,point)
	check(control.selected==index,"actual option selection reaches requested item")

func tab(index:int)->void:
	var bar:TabBar=game.ui._tabs.get_tab_bar()
	await click_at(bar.get_viewport(),bar.global_position+bar.get_tab_rect(index).get_center())

func menu_edge(button:MenuButton,last:bool=false)->void:
	await reveal(button)
	var start:=button.get_global_rect().get_center()
	var motion:=InputEventMouseMotion.new();motion.position=start;motion.global_position=start;root.push_input(motion,true)
	var press:=InputEventMouseButton.new();press.position=start;press.global_position=start;press.button_index=MOUSE_BUTTON_LEFT;press.pressed=true;root.push_input(press,true)
	await frames(2)
	var popup:PopupMenu=button.get_popup()
	var panel:StyleBox=popup.get_theme_stylebox("panel")
	var y:float=float(popup.size.y)-panel.get_content_margin(SIDE_BOTTOM)-12 if last else panel.get_content_margin(SIDE_TOP)+12
	var target:=Vector2(popup.position)+Vector2(float(popup.size.x)/2.0,y)
	motion=InputEventMouseMotion.new();motion.position=target;motion.global_position=target;root.push_input(motion,true);await process_frame
	var release:=InputEventMouseButton.new();release.position=target;release.global_position=target;release.button_index=MOUSE_BUTTON_LEFT;release.pressed=false;root.push_input(release,true);await frames(3)

func fixture_look(_payload:Dictionary,_role:String)->Dictionary:
	return {"ok":true,"text":JSON.stringify({"type":"look"})}

func single_hair(model:Node,index:int)->bool:
	var visible_count:=0;var matching:=false
	for mesh in model.find_children("*","MeshInstance3D",true,false):
		var name:String=str(mesh.name).to_lower()
		if name.begins_with("hair_") and mesh.visible:
			visible_count+=1;matching=name.begins_with("hair_"+str(index))
	return visible_count==1 and matching

func independent_dispatch_regression()->void:
	# The fixture executes the production request queue; no HTTP/key is enabled.
	game._set_running(false)
	var id:String=game.selected
	game.runtimes[id].configure_provider({"enabled":false,"fixture_response":Callable(self,"fixture_look"),"ledger":game.ledger,"media_directory":test_root.path_join("media")})
	game.world.sync_state(game.simulation.snapshot(),true);game.world.prepare_capture(id);await frames(2)
	var png:PackedByteArray=game.world.capture_agent(id).save_png_to_buffer()
	var original_mode:String=game.mode
	var original_quote:Dictionary=game._quote.duplicate(true)
	game.mode="real_vlm";game._quote={"expires_at":int(Time.get_unix_time_from_system())+900}
	for other in game.simulation.state.agents:
		game.simulation.state.agents[other].busy={} if other==id else {"type":"wait","remaining":30.0}
	for i in 4:check(game.ledger.reserve("qa_memory_block_"+str(i),.001,"memory").ok,"shared memory reservation occupies capacity")
	var previous:float=game.simulation.state.minute
	game.running=true;game._process(0.2);await frames(3)
	check(float(game.simulation.state.minute)>previous,"accepted activities continue during network capacity wait")
	check(int(game.runtimes[id].debug().fixture_requests)==0,"full ledger prevents a fifth request")
	game.running=false
	for i in 4:game.ledger.settle("qa_memory_block_"+str(i),0.0)
	game.single_step()
	var deadline:=Time.get_ticks_msec()+15000
	while game._single_step and Time.get_ticks_msec()<deadline:await process_frame
	check(int(game.runtimes[id].debug().fixture_requests)==1,"one manual step dispatches exactly one fixture for the available person")
	check(int(game.runtimes[id].debug().live_requests_started)==0,"request queue fixture performs zero network model calls")
	game.mode=original_mode;game._quote=original_quote
	game.runtimes[id].configure_provider(game._provider_config())

func queued_preflight_regression()->void:
	game._set_running(false)
	game._invalidate()
	game._next_decision.clear()
	for actor in game.simulation.state.agents.values():actor.busy={}
	var original_catalog:Node=game._catalog
	var original_mode:String=game.mode
	var original_quote:Dictionary=game._quote.duplicate(true)
	var fake:=FakeCatalog.new();game.add_child(fake);game._catalog=fake
	game.mode="real_vlm";game._quote={"expires_at":int(Time.get_unix_time_from_system())+100}
	for i in 4:game.ledger.reserve("qa_quote_memory_"+str(i),.001,"memory")
	var request_count:int=int(game.ledger.status().request_count)
	var frozen:Dictionary=game.simulation.snapshot()
	game.collect_decisions();game._process(25.0);await frames(2)
	check(game._quote_refresh_queued and fake.calls.is_empty() and not game._provider_pending,"expiring tariff queues free preflight while four memory reservations are active")
	check(game.simulation.snapshot()==frozen,"queued free preflight advances neither logical clock nor world")
	game.ledger.settle("qa_quote_memory_0",0.0);await frames(2)
	check(fake.calls.is_empty(),"free preflight waits until every outstanding shared request releases")
	for i in range(1,4):game.ledger.settle("qa_quote_memory_"+str(i),0.0)
	await frames(3)
	check(fake.calls.size()==1 and int(fake.calls[0][3])==420,"released queue requests one free quote with420-second minimum validity")
	check(int(game.ledger.status().request_count)==request_count and game.simulation.snapshot()==frozen,"free quote consumes no paid reservation and changes no world state")
	game._on_quote_ready(game._catalog_tag,{"ok":false,"error":"test offline"})
	await frames(3)
	check(not game._single_step and fake.calls.size()==1,"failed preflight cancels a manual step without retrying")
	# Cancellation of a queued refresh cannot reappear after later completions.
	game._provider_pending=false
	for i in 4:game.ledger.reserve("qa_cancel_quote_"+str(i),.001,"memory")
	game.collect_decisions();game._invalidate()
	for i in 4:game.ledger.settle("qa_cancel_quote_"+str(i),0.0)
	await frames(3)
	check(not game._quote_refresh_queued and fake.calls.size()==1,"generation invalidation cancels queued free quote before capacity returns")
	game._catalog=original_catalog;game.mode=original_mode;game._quote=original_quote;game._provider_pending=false;game._quote_refresh_queued=false
	fake.queue_free();await frames(2)

func isolate()->void:
	game.repository.save_root=test_root.path_join("saves")
	game.repository.session_root=test_root.path_join("sessions")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(test_root))
	game.ledger=Ledger.new();game.ledger.configure(1000.0,test_root.path_join("usage.json"),4)
	game._ledger_path=test_root.path_join("usage.json")
	for runtime in game.runtimes.values():runtime.configure_provider(game._provider_config())
	game.repository.begin(game.simulation.snapshot())

func run()->void:
	if "--test-profile" not in OS.get_cmdline_user_args() or DisplayServer.get_name()=="headless":
		printerr("UI QA requires a real renderer and -- --test-profile; no game instantiated")
		quit(2);return
	root.position=Vector2i(-2900,-1500);root.size=Vector2i(1440,940)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	test_root="user://release_ui_qa_"+str(Time.get_ticks_usec())
	game=Main.new();root.add_child(game);current_scene=game
	await frames(5);isolate()
	check(game.mode=="demo" and game._key.is_empty(),"test profile starts offline without loading credentials")
	if "--auto-run" in OS.get_cmdline_user_args():
		check(game.running,"CLI auto-run survives later map/population arguments")
	game._set_running(false);await settle()
	if "--auto-run" not in OS.get_cmdline_user_args():check(game.ui._menu_visible,"fresh startup exposes main menu")
	game.ui.show_main_menu(true);await frames(2)
	await click(find_button("Вернуться в мир"))
	check(not game.ui._menu_visible,"actual menu click returns to world")
	game._refresh(false);await frames(3)
	if game.ui._chapter_popup.visible:await click(game.ui._chapter_continue)
	else:await click(game.ui._run)
	check(game.running,"actual Continue button schedules simulation")
	await click(game.ui._run)
	check(not game.running,"actual Pause button stops simulation")
	var paused:float=float(game.simulation.state.minute)
	game._process(50.0);await frames(2)
	check(float(game.simulation.state.minute)==paused,"paused time remains frozen")
	await click(find_button("Шаг"));await settle()
	check(float(game.simulation.state.minute)>paused,"actual Step button advances authoritative time")
	await click(find_button("Вид"))
	check(game.world.first_person and game.ui._central.texture==game.world.human_viewport.get_texture() and game.ui._central.texture.get_width()>640,"visible Switch view control displays selected person's actual camera")
	await click(find_button("Вид"))
	check(not game.world.first_person and game.ui._central.texture==game.world.observer_texture(),"visible Switch view control returns to world observer camera")
	await click(find_button("Фокус"))
	check(game.world.follow_selected,"visible Follow control tracks selected person")
	check(game.ui._drawer.visible,"selected person inspector is visible alongside the world")
	await click(find_button("Образ"))
	check(game.ui._appearance_popup.visible,"actual Appearance button opens editor")
	check(game.ui._character_preview.texture!=null,"first editor open immediately shows genuine character preview")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test-output/release-ui-qa"))
	root.get_texture().get_image().save_png("res://test-output/release-ui-qa/editor_first_open.png")
	var before_hair:int=int(game.simulation.state.agents[game.selected].appearance.hair)
	if game.ui._appearance_controls.hair is OptionButton:await choose(game.ui._appearance_controls.hair,3)
	else:game.ui._appearance_controls.hair.value=3
	check(int(game.simulation.state.agents[game.selected].appearance.hair)==before_hair,"editor preview leaves authoritative appearance unchanged")
	check(single_hair(game.world._portrait.model,3),"editor shows exactly selected long-hair mesh with imported suffixes")
	await click(find_button("Применить образ"))
	check(int(game.simulation.state.agents[game.selected].appearance.hair)==3,"actual Apply appearance commits selected hairstyle")
	check(single_hair(game.world._models[game.selected],3),"world shows exactly selected long-hair mesh after Apply")
	# Real god form applies its complete payload, including runtime edits.
	await tab(game.ui._tabs.get_tab_count()-1)
	await click(find_button("Режим бога"))
	check(game.ui._god_popup.visible,"actual God mode button opens editable intervention form")
	game.ui._god_controls.health.value=93;game.ui._god_controls.hunger.value=34;game.ui._god_controls.fatigue.value=21;game.ui._god_controls.tokens.value=77
	game.ui._god_controls.goal.text="QA god form goal";game.ui._god_controls.foundation.text="QA god form foundation"
	await click(find_button("Применить вмешательство"));await settle()
	var edited:Dictionary=game.simulation.state.agents[game.selected]
	check(edited.health==93 and edited.needs.hunger==34 and edited.needs.fatigue==21 and edited.tokens==77,"actual God Apply commits health, needs and tokens")
	check(edited.profile.goal=="QA god form goal" and game.runtimes[game.selected].profile.goal==edited.profile.goal and game.runtimes[game.selected].profile.foundation=="QA god form foundation","actual God Apply synchronizes personal goal and foundation")
	await menu_edge(find_button("Сохранения") as MenuButton)
	var ui_saved:Dictionary=game.repository.load_slot(1)
	check(not ui_saved.is_empty(),"actual Saves menu writes selected save slot")
	if not ui_saved.is_empty():game.repository.save_slot(3,ui_saved.data)
	game.god_intervention("set_health",{"id":game.selected,"health":17.0})
	await menu_edge(find_button("Сохранения") as MenuButton,true);await settle()
	check(game.simulation.state.agents[game.selected].health==93.0,"actual Saves menu loads selected slot into authoritative world")
	# The restored chapter describes the saved situation before observation resumes.
	if game.ui._chapter_popup.visible:
		await click(game.ui._chapter_continue);await click(game.ui._run);await settle()
	# Exercise an app through its engine-gated launcher.
	await click(find_button("Телефон"))
	check(game.ui._phone_popup.visible,"actual Phone button opens personal device")
	await click(find_button("Форум"));await settle()
	check(game.simulation.state.agents[game.selected].device_app=="forum","actual app Open obtains engine-authorized forum session")
	game.ui._device_title.text="QA actual forum form";game.ui._device_text.text="QA forum body from genuine controls"
	await click(find_button("Создать тему"));await settle()
	var matching_topic:=false
	for topic in game.simulation.state.network.topics.values():
		if topic.title=="QA actual forum form" and not topic.posts.is_empty() and topic.posts[0].text=="QA forum body from genuine controls":matching_topic=true
	check(matching_topic,"actual New topic button commits forum content to authority")
	# Read acquisition must reach memory immediately, before any next decision.
	game._next_decision[game.selected]=float(game.simulation.state.minute)+1000.0
	var read_sequence:int=int(game.runtimes[game.selected].export_state().memory.sequence)
	var read_refs:Dictionary=game.simulation._refs.get(game.selected,{}).duplicate(true)
	await click(find_button("Читать экран"));await settle()
	var acquired_immediately:=false
	for record in game.runtimes[game.selected].memory_view().recent:
		if int(record.id)>read_sequence and record.source=="personal_experience" and "QA actual forum form" in str(record.get("personal_results",[])):acquired_immediately=true
	check(acquired_immediately,"actual Read screen immediately retains private content before next decision")
	check(game.simulation._refs.get(game.selected,{})==read_refs,"immediate private-memory delivery leaves visual target references unchanged")
	check(float(game._next_decision[game.selected])>float(game.simulation.state.minute)+900.0,"private acquisition does not force or schedule a model decision")
	game.ui._phone_popup.hide();await frames(2)
	# Public action target/schema path must also update the runtime's current goal.
	game._on_command("intent",{"id":game.selected,"action":{"type":"set_goal","text":"QA autonomous current goal"}})
	await settle()
	check(game.simulation.state.agents[game.selected].profile.goal=="QA autonomous current goal","ordinary intention changes engine current goal")
	check(game.runtimes[game.selected].profile.goal=="QA autonomous current goal","ordinary intention changes next model's current goal too")
	# God edits must update both layers and clear memory explicitly.
	game.god_intervention("set_profile",{"id":game.selected,"foundation":"QA explicit observer foundation"})
	check(game.runtimes[game.selected].profile.foundation==game.simulation.state.agents[game.selected].profile.foundation,"god foundation edit synchronizes engine/runtime")
	game.runtimes[game.selected].observe(game.simulation.observe(game.selected))
	check(not game.runtimes[game.selected].memory_view().recent.is_empty(),"personal experience exists before memory intervention")
	game.god_intervention("set_memory",{"id":game.selected,"text":"QA explicit new memory","clear":true})
	var memory:Dictionary=game.runtimes[game.selected].memory_view()
	check(memory.recent.is_empty() and memory.semantic=="QA explicit new memory","god memory edit clears prior history and sets new subjective content")
	var cleared_actor:Dictionary=game.simulation.state.agents[game.selected]
	check(cleared_actor.heard.is_empty() and cleared_actor.personal_results.is_empty(),"explicit memory clear removes old short notification tails too")
	game.runtimes[game.selected].observe(game.simulation.observe(game.selected))
	check("QA actual forum form" not in str(game.runtimes[game.selected].memory_view()),"next personal observation cannot resurrect content removed by god memory clear")
	# Captures must reference the pose after this exact execution step.
	game._on_command("intent",{"id":game.selected,"action":{"type":"take_photo","digital":true}})
	await settle()
	var photos:Array=game.simulation.state.artifacts.values()
	check(not photos.is_empty() and not str(photos[-1].image_ref).is_empty(),"main attaches genuine photo pixels to capture event")
	if not photos.is_empty():
		var artifact:Dictionary=photos[-1]
		check(artifact.source_pose.position==game.simulation.state.agents[game.selected].position,"photo records exact frozen actor position")
		check(not game.media.retrieve(str(artifact.image_ref)).is_empty(),"photo reference resolves to stored PNG")
	# Pause while capture waits for frame_post_draw must not orphan the artifact.
	game._on_command("intent",{"id":game.selected,"action":{"type":"take_photo","digital":true}})
	game._set_running(false)
	# Encoding is asynchronous and may span many uncapped render frames.
	# Wait for bounded completion, then demand an actual finalized image.
	await settle()
	photos=game.simulation.state.artifacts.values()
	check(not photos.is_empty() and not str(photos[-1].image_ref).is_empty(),"pause during capture still finalizes genuine PNG, never a blank final artifact")
	var recorded:Dictionary=game.repository.reconstruct(game.repository.sequence)
	check(not recorded.is_empty() and is_equal_approx(float(recorded.minute),float(game.simulation.state.minute)),"pause during capture still journals committed logical step")
	game.save_slot(1)
	var saved_minute:float=float(game.simulation.state.minute)
	game.god_intervention("needs",{"id":game.selected,"hunger":88.0})
	game.load_slot(1)
	check(is_equal_approx(float(game.simulation.state.minute),saved_minute),"main loads saved logical moment")
	check(float(game.simulation.state.agents[game.selected].needs.hunger)<88.0,"main load restores authority beyond inspector display")
	# A corrupt scheduling continuation must be rejected before the world commit.
	var envelope:Dictionary=game.repository.load_slot(1)
	var damaged:Dictionary=envelope.data.duplicate(true);damaged.next_decision={game.selected:[]}
	game.repository.save_slot(2,damaged)
	var before_load:Dictionary=game.simulation.snapshot()
	game.load_slot(2)
	check(game.simulation.snapshot()==before_load,"invalid scheduler continuation cannot partially load a session")
	await independent_dispatch_regression()
	await queued_preflight_regression()
	# A captured image may still be encoding after reset. Its completion belongs
	# to the previous world even when the replacement reuses the same actor IDs.
	game._on_command("intent",{"id":game.selected,"action":{"type":"take_photo","digital":true}})
	check(game.advancing,"photo capture exposes asynchronous window before PNG completion")
	var capture_run:int=int(game.simulation.state.run_id)
	game.new_session({"map_id":"residence","count":3,"scenario":"sandbox","seed":717})
	var replacement_snapshot:Dictionary=game.simulation.snapshot()
	await create_timer(.35).timeout;await frames(3)
	check(int(game.simulation.state.run_id)!=capture_run and game.simulation.snapshot()==replacement_snapshot and game.simulation.state.artifacts.is_empty(),"PNG completion from old run cannot attach photos or mutate replacement world")
	# Actual dialog starts a new 20-person map and invalidates old run replies.
	var previous_run:int=int(game.simulation.state.run_id)
	await click(find_button("Меню"))
	await click(find_button("Открыть историю"))
	check(game.ui._new_popup.visible,"actual New story button opens setup dialog")
	await choose(game.ui._map_choice,2);game.ui._count.value=20;game.ui._seed.value=991
	await click(find_button("Начать"));await settle()
	check(game.simulation.state.map_id=="research_station" and game.simulation.state.agents.size()==20,"actual Begin builds requested map and twenty authoritative agents")
	var reset_snapshot:Dictionary=game.simulation.snapshot()
	game._on_decision(game.selected,previous_run,0,{"type":"set_goal","text":"STALE OLD WORLD"},{})
	check(game.simulation.snapshot()==reset_snapshot,"old-generation decision cannot mutate UI-created replacement world")
	if game.ui._chapter_popup.visible:
		await click(game.ui._chapter_continue);await click(game.ui._run);await settle()
	await click(find_button("Повтор"));await frames(3)
	check(game._reviewing and not game.running,"actual Replay button enters offline journal playback")
	check(game.ui._debug.is_empty() and game.ui._info.decision_states.is_empty() and game.ui._info.observations.is_empty(),"replay does not expose future observations, memories or decisions")
	game._set_running(false)
	if game.ui._chapter_popup.visible:
		await click(game.ui._chapter_continue);await click(game.ui._run);await settle()
	await click(find_button("Опции"))
	check(game.ui._settings_popup.visible,"actual Settings button opens preferences")
	var settings_tabs:TabContainer=game.ui._settings_popup.find_children("*","TabContainer",true,false)[0]
	var settings_bar:TabBar=settings_tabs.get_tab_bar()
	await click_at(root,Vector2(game.ui._settings_popup.position)+settings_bar.global_position+settings_bar.get_tab_rect(1).get_center())
	await choose(game.ui._language_choice,1);await choose(game.ui._quality,0)
	game.ui._speed.value=2.0;game.ui._sfx.value=.35
	await click(find_button("Применить настройки"));await frames(6)
	check(game.ui.language=="en" and game.settings.language=="en","actual Settings Apply rebuilds interface in requested language")
	check(game.settings.quality=="low" and game.settings.speed==2.0 and is_equal_approx(float(game.settings.sfx_volume),.35),"actual Settings Apply commits quality, speed and sound preferences")
	game._set_running(false)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test-output/release-ui-qa"))
	await frames(3)
	root.get_texture().get_image().save_png("res://test-output/release-ui-qa/actual_controls.png")
	game.queue_free();await frames(3)
	# Inject an already-loaded English preference without touching user's settings.
	game=Main.new();game.settings.language="en";root.add_child(game);current_scene=game
	await frames(5);isolate();game._set_running(false)
	check(game.ui.language=="en","startup UI honors loaded language preference")
	var report:=FileAccess.open("res://test-output/release-ui-qa/report.json",FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks":checks,"failures":failures,"paid_api_calls":0},"\t"));report.close()
	print("INDEPENDENT UI QA: ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
