extends SceneTree
## Offline UI-to-rules integration probe. No runtime/provider is instantiated.
const Simulation=preload("res://scripts/game/session_simulation.gd")
const World=preload("res://scripts/release_world/world_view.gd")
const UI=preload("res://scripts/release_ui/observer_ui.gd")
var sim=Simulation.new()
var world:Node3D
var ui:CanvasLayer
var selected:String="person_00"
var failures:Array=[]
var checks:=0
func _initialize()->void:
	if DisplayServer.get_name()=="headless" or "--test-profile" not in OS.get_cmdline_user_args():
		printerr("Phone flow requires real renderer and -- --test-profile");quit(2);return
	root.position=Vector2i(-3000,-1500);root.size=Vector2i(1440,940)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	_run.call_deferred()
func check(condition:bool,label:String)->void:
	checks+=1
	if not condition:failures.append(label);printerr("UI FAIL ",label)
	else:print("UI PASS ",label)
func _refresh()->void:
	world.sync_state(sim.snapshot(),true)
	ui.refresh(sim.snapshot(),{}, {"selected":selected,"observations":{selected:sim.observe(selected)},"device_screens":{selected:sim.device_screen(selected)},"mode":"demo"})
func _receive(name:String,payload:Dictionary)->void:
	match name:
		"select":selected=str(payload.id);world.select_agent(selected)
		"god":sim.intervene(str(payload.command),payload.args)
		"appearance":sim.intervene("appearance",payload)
		"intent":sim.observe(str(payload.id));sim.submit(str(payload.id),payload.action,int(sim.state.run_id));sim.advance(0.2)
	_refresh()
func _act(action:Dictionary)->void:ui._send_intent(action)
func _choose_photo(choice:OptionButton,slot:int,index:int)->bool:
	for item in choice.item_count:
		if choice.get_item_metadata(item)=={"slot":slot,"index":index}:choice.select(item);return true
	return false
func _photo_fixture(key:String,image_ref:String,minute:float)->void:
	sim.state.artifacts[key]={"id":key,"kind":"photo","creator":selected,"owner":selected,"created":minute,"image_ref":image_ref,"digital":true,"pending_capture":false}
func _run()->void:
	sim.reset("closed_block",3,"scarcity",1)
	world=World.new();root.add_child(world);world.setup(sim.snapshot())
	ui=UI.new();root.add_child(ui);ui.setup(world);ui.command.connect(_receive);ui.show_main_menu(false);_refresh()
	for frame in 4:await process_frame
	ui._open_god();ui._god_controls.health.value=40;ui._god_controls.tokens.value=23;ui._apply_god()
	check(sim.state.agents[selected].health==40,"God health editor uses actual health argument")
	check(sim.state.agents[selected].tokens==23,"God token editor uses actual token argument")
	ui._open_appearance();ui._appearance_controls.face.select(5);ui._appearance_controls.hair.select(3);ui._appearance_controls.outfit.select(2);ui._appearance_controls.skin.color=Color("80533e");ui._update_character_preview()
	check(sim.state.agents[selected].appearance.face==0,"Avatar preview leaves authorititative face unchanged")
	var preview_hair:Array=world._portrait.model.find_children("Hair*","MeshInstance3D",true,false).filter(func(mesh):return mesh.visible)
	check(preview_hair.size()==1 and str(preview_hair[0].name).begins_with("Hair_3"),"Avatar preview selects one real long hairstyle after imported suffix normalization")
	ui._apply_appearance()
	check(sim.state.agents[selected].appearance.face==5 and sim.state.agents[selected].appearance.outfit==2,"Apply commits actual selected appearance")
	var live_hair:Array=world._models[selected].find_children("Hair*","MeshInstance3D",true,false).filter(func(mesh):return mesh.visible)
	check(live_hair.size()==1 and str(live_hair[0].name).begins_with("Hair_3"),"Applied world model uses the same real hairstyle")
	sim._introduce("person_00","person_01");sim._introduce("person_01","person_00");_refresh()
	_act({"type":"use_device","slot":0,"app":"messages"})
	check(not ui._choice_ref(ui._contact).is_empty() and ui._contact.get_item_text(0)=="Boris","Phone contact has a human name and scoped metadata")
	_act({"type":"send_message","contact":ui._choice_ref(ui._contact),"text":"Проверка связи"})
	check(sim.state.network.messages.size()==1,"Phone send creates a real simulated message")
	ui._pick_person("person_01");_act({"type":"use_device","slot":0,"app":"messages"})
	var message_ref:String=ui._choice_ref(ui._message_id)
	check(not message_ref.is_empty(),"Recipient message chooser resolves delivered personal entry")
	_act({"type":"read_message","message":message_ref})
	check(sim.state.network.messages.values()[0].read_by.has("person_01"),"Phone read changes actual read receipt")
	_act({"type":"use_device","slot":0,"app":"network"})
	_act({"type":"replace_message","message":ui._choice_ref(ui._message_id),"text":"Изменённая версия"})
	check(sim.state.network.messages.values()[0].original_text=="Проверка связи" and sim.state.network.messages.values()[0].text=="Изменённая версия","Admin replacement preserves original and changes delivered revision")
	check(ui._trace_view.text.contains("Проверка связи") and ui._trace_view.text.contains("Изменённая версия"),"Observer version viewer displays both truths without raw IDs")
	_act({"type":"use_device","slot":0,"app":"messages"});ui._open_group();ui._group_name.text="Команда";ui._group_members.select(0)
	for button in ui._group_popup.find_children("*","Button",true,false):
		if button.text=="Создать группу":button.pressed.emit();break
	check(sim.state.network.groups.size()==1,"Group dialog creates an actual group")
	_act({"type":"use_device","slot":0,"app":"game"})
	var contact:String=""
	for entry in ui._available_contacts:
		if not entry.get("group",false):contact=str(entry.get("ref",entry.get("id","")));break
	_act({"type":"play_game","contact":contact})
	_act({"type":"play_game","contact":contact,"cell":0})
	check(sim.state.network.games.size()==1 and sim.state.network.games.values()[0].board[0]=="X","Tic-tac-toe creates a rules-backed game and real cell move")
	check(ui._game_buttons[0].text=="X","Phone board reflects actual game state")
	_act({"type":"use_device","slot":0,"app":"forum"});_act({"type":"create_topic","title":"Общий план","text":"Давайте делиться припасами."})
	check(sim.state.network.topics.size()==1 and ui._topic_id.get_item_text(0)=="Общий план","Forum topic selector uses its human title")
	_act({"type":"use_device","slot":0,"app":"votes"});_act({"type":"create_vote","title":"Общие запасы","options":["Делиться","Сохранить"],"minutes":60.0})
	check(sim.state.network.polls.size()==1 and ui._poll_options.get_child_count()>=2,"Poll renders real selectable options")
	_act({"type":"vote","poll":ui._choice_ref(ui._poll_id),"option":0})
	check(sim.state.network.polls.values()[0].votes.get("person_01",-1)==0,"Poll button intention records the actual account vote")
	# Offline identity fixtures: hashes distinguish photo content; no image files or provider.
	var earlier_hash:String="offline earlier digital photo fixture".sha256_text()
	var latest_hash:String="offline latest digital photo fixture".sha256_text()
	_photo_fixture("fixture_earlier",earlier_hash,6.0);_photo_fixture("fixture_latest",latest_hash,9.0)
	var phone:Dictionary=sim.state.items[sim.state.agents[selected].inventory[0]];phone.files=["fixture_earlier","fixture_latest"]
	var locked_camera:Dictionary=sim._new_item("camera","Закрытый фотоаппарат",sim.state.agents[selected].position,selected,selected);locked_camera.locked=true;locked_camera.files=["fixture_latest"]
	var physical:Dictionary=sim._new_item("photo","Бумажная фотография",sim.state.agents[selected].position,selected,selected);physical.artifact_id="fixture_earlier"
	_act({"type":"use_device","slot":0,"app":"gallery"})
	check(ui._photo_slot.item_count==3 and ui._attachment_photo.item_count==4,"Photo choices include both digital files and physical photo while excluding locked camera")
	var personal_before:int=sim.state.agents[selected].personal_results.size()
	check(_choose_photo(ui._photo_slot,0,0),"Gallery can select an earlier digital photo using scoped slot and index")
	check(sim.state.agents[selected].personal_results.size()==personal_before,"Selecting a gallery entry alone grants no viewed experience")
	ui._send_photo_action("view_photo")
	check(sim.state.agents[selected].personal_results[-1].image_ref==earlier_hash and sim.device_screen(selected).image_ref==earlier_hash,"View button authorizes the selected earlier photo rather than the latest file")
	ui._send_photo_action("copy_photo")
	var copy_id:String=phone.files[-1]
	check(sim.state.artifacts[copy_id].image_ref==earlier_hash and sim.state.artifacts[copy_id].source_artifact=="fixture_earlier","Copy button copies the selected digital file with its index")
	_act({"type":"use_device","slot":0,"app":"messages"});ui._contact.select(0);ui._device_text.text="Без фотографии";ui._attachment_photo.select(0);ui._send_device_message()
	check(sim.state.network.messages.values()[-1].attachment.is_empty(),"No attachment preserves normal text-only send")
	check(_choose_photo(ui._attachment_photo,0,0),"Message attachment picker selects the earlier digital photo")
	ui._device_text.text="Снимок к сообщению";ui._send_device_message()
	check(sim.state.network.messages.values()[-1].attachment=="fixture_earlier","Send button passes attachment slot and file index to the actual rules")
	ui._pick_person("person_00");_act({"type":"use_device","slot":0,"app":"messages"});ui._message_id.select(ui._message_id.item_count-1)
	_act({"type":"read_message","message":ui._choice_ref(ui._message_id)})
	check(sim.state.agents[selected].personal_results[-1].image_ref==earlier_hash,"Recipient reading the attachment receives the exact selected photo identity")
	ui._phone_popup.hide();ui._god_popup.hide();ui._appearance_popup.hide()
	await process_frame;await RenderingServer.frame_post_draw
	print("UI FLOW RESULT ",checks," checks; ",failures.size()," failures; zero provider instances")
	quit(0 if failures.is_empty() else 1)
