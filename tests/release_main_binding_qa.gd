extends SceneTree
## Actual production Main collector, fixture transport only. No HTTP or vault.
const Main=preload("res://scripts/release_main.gd")
const Ledger=preload("res://scripts/release_ai/usage_ledger.gd")
const Spatial=preload("res://scripts/game/spatial_rules.gd")
const Media=preload("res://scripts/release_ai/media_archive.gd")
const OUTPUT="res://test-output/release-binding-qa"
var game:Node
var checks:=0
var failures:Array=[]
var packets:Array=[]
var bindings:Array=[]
var observed_refs:Dictionary={}
var initial_refs:Dictionary={}
var actor:="person_00"

func _initialize()->void:run.call_deferred()
func check(ok:bool,label:String)->void:
	checks+=1
	if not ok:failures.append(label);printerr("FAIL BINDING: ",label)
	else:print("PASS BINDING: ",label)
func frames(count:int=3)->void:
	for i in count:await process_frame
	await RenderingServer.frame_post_draw
func fixture(payload:Dictionary,role:String)->Dictionary:
	if role!="action":return {"ok":false,"error":"No unexpected fixture role allowed"}
	packets.append(payload.duplicate(true))
	observed_refs=game.simulation._refs.get(actor,{}).duplicate(true)
	return {"ok":true,"text":JSON.stringify({"type":"look"})}

func run()->void:
	if DisplayServer.get_name()=="headless" or "--test-profile" not in OS.get_cmdline_user_args():printerr("Real renderer and -- --test-profile required");quit(2);return
	root.position=Vector2i(-3500,-2000);root.size=Vector2i(1440,940);DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	game=Main.new();root.add_child(game);await frames(4);game._set_running(false)
	var isolation:="user://release_binding_qa_"+str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(isolation))
	game.ledger.release_storage_lease();game.ledger=Ledger.new();game._ledger_path=isolation.path_join("usage.json");game.ledger.configure(1000.0,game._ledger_path,4)
	game.repository.save_root=isolation.path_join("saves");game.repository.session_root=isolation.path_join("sessions")
	game.new_session({"map_id":"closed_block","count":3,"scenario":"deception","seed":17})
	var terminal:=Spatial.point({"position":game.simulation.state.terminal.position})
	var geometry:Dictionary=game.simulation.state.geometry
	var placed:=false
	for degrees in range(0,360,15):
		var offset:=Vector2.from_angle(deg_to_rad(float(degrees)))*1.3
		var candidate:=terminal+offset
		if not Spatial.walkable(candidate,geometry,game.simulation.state.agents,actor):continue
		var terminal_id:=""
		for prop in geometry.props:
			if prop.kind=="terminal":terminal_id=str(prop.id);break
		if not Spatial.clear_line(candidate,terminal,geometry,0.0,terminal_id,true):continue
		game.simulation.state.agents[actor].position=[candidate.x,candidate.y];game.simulation.state.agents[actor].heading=rad_to_deg(atan2(offset.x,offset.y));placed=true;break
	check(placed,"identical deception fixture places actor1.3m beside terminal")
	for id in game.runtimes:
		game.simulation.state.agents[id].busy={} if id==actor else {"type":"wait","remaining":720.0}
		game.runtimes[id].configure_provider({"enabled":false,"ledger":game.ledger,"fixture_response":Callable(self,"fixture"),"model":"test/offline-binding"})
	game.mode="real_vlm";game._quote={"expires_at":int(Time.get_unix_time_from_system())+900}
	game.world.sync_state(game.simulation.snapshot(),true);game.world.select_agent(actor);game.ui.show_main_menu(false)
	game.simulation.observe(actor);initial_refs=game.simulation._refs[actor].duplicate(true)
	var before_minute:float=float(game.simulation.state.minute)
	game.collect_decisions()
	var deadline:=Time.get_ticks_msec()+20000
	while (game.collecting or game.advancing) and Time.get_ticks_msec()<deadline:await process_frame
	check(not game.collecting and not game.advancing,"actual collector and fixture decision terminate")
	check(packets.size()==1 and int(game.runtimes[actor].debug().fixture_requests)==1,"exactly one production action call reaches fixture transport")
	check(observed_refs==initial_refs,"render plus both PNG encoding awaits preserve original current target refs")
	check(game._key.is_empty() and int(game.runtimes[actor].debug().live_requests_started)==0,"no credentials loaded or network model request started")
	var observation:Dictionary=game._observations.get(actor,{})
	check(observation.get("grounding_png") is PackedByteArray and not observation.grounding_png.is_empty(),"production collector supplies nonempty grounding PNG")
	var round_png:PackedByteArray=PackedByteArray()
	if not packets.is_empty():
		var content:Array=packets[0].messages[1].content
		var images:Array=[]
		for item in content:
			if item.get("type")=="image_url":images.append(Marshalls.base64_to_raw(str(item.image_url.url).get_slice(",",1)))
		check(images.size()==2,"actual model payload contains original and labelled current helper exactly")
		if images.size()>=2:
			round_png=images[0];var original:=Image.new();var helper:=Image.new()
			check(original.load_png_from_buffer(images[0])==OK and helper.load_png_from_buffer(images[1])==OK,"both actual outgoing images decode as real PNG")
			original.save_png(OUTPUT.path_join("actual_original.png"));helper.save_png(OUTPUT.path_join("actual_helper.png"))
			check(original.get_data()!=helper.get_data(),"outgoing helper really contains visible target marks")
			check(images[1]==observation.grounding_png,"payload helper is exactly collector-generated helper bytes")
		check(str(observation.get("grounding_source_hash",""))==Media.digest_bytes(round_png),"helper source hash binds exact original outgoing PNG")
	var maps_ok:=true;var terminal_ref:="";var camera:Camera3D=game.world.agent_cameras[actor]
	for target in observation.get("targets",[]):
		if not initial_refs.has(target.ref):maps_ok=false;continue
		var link:Dictionary=initial_refs[target.ref]
		var position:Array=link.position
		var entity:Dictionary={}
		if link.category=="prop":
			for prop in geometry.props:
				if prop.id==link.id:entity=prop;break
		elif link.category=="door":
			for door in geometry.doors:
				if door.id==link.id:entity=door;break
		elif link.category=="agent":entity=game.simulation.state.agents[link.id]
		elif link.category=="item":entity=game.simulation.state.items[link.id]
		var height:float=1.3 if link.category=="agent" else (float(entity.get("height",.7))*.6 if link.category in ["door","prop"] else .25+float(entity.get("surface_height",0)))
		var expected:Vector2=camera.unproject_position(Vector3(float(position[0]),height,float(position[1])))/Vector2(640,360)
		maps_ok=maps_ok and absf(expected.x-float(target.uv[0]))<.0011 and absf(expected.y-float(target.uv[1]))<.0011
		bindings.append({"ref":target.ref,"category":link.category,"observer_only_world_id":link.id,"uv":target.uv,"expected_uv":[expected.x,expected.y],"kind":entity.get("kind",link.category)})
		if entity.get("kind")=="terminal":terminal_ref=target.ref
	check(maps_ok,"every outgoing refUV matches exact authority candidate and actual camera projection")
	check(not terminal_ref.is_empty(),"terminal has an outgoing visible current ref")
	var fake_action:Dictionary={"type":"interact","target":terminal_ref}
	var queued:Dictionary=game.simulation.submit(actor,fake_action,int(game.simulation.state.run_id));game.simulation.advance(.01)
	check(queued.ok and game.simulation.state.agents[actor].personal_results.any(func(value):return value.get("channel")=="terminal" and value.get("source")=="read_terminal"),"actual terminal ref executes terminal rules rather than opening another object")
	var file:=FileAccess.open(OUTPUT.path_join("report.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks":checks,"failures":failures,"mode":"actual_main_fixture_no_HTTP_no_vault","bindings":bindings,"terminal_ref":terminal_ref,"source_hash":observation.get("grounding_source_hash",""),"fixture_calls":packets.size(),"logical_minute_before":before_minute,"paid_calls":0},"\t"));file.close()
	print("MAIN BINDING QA: ",checks," checks; ",failures.size()," failures; bindings=",JSON.stringify(bindings))
	quit(0 if failures.is_empty() else 1)
