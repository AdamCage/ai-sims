extends SceneTree
## Offline privacy/pixel isolation check for derived VLM grounding handles.
const Simulation=preload("res://scripts/game/session_simulation.gd")
const World=preload("res://scripts/release_world/world_view.gd")
const Spatial=preload("res://scripts/game/spatial_rules.gd")
var checks:=0
var failures:=0
var async_results:Dictionary={}
func _async_helper(world:Node,image:Image,targets:Array,key:String)->void:
	async_results[key]=await world.grounding_image(image,targets)
func check(ok:bool,text:String)->void:
	checks+=1
	if not ok:failures+=1;printerr("GROUNDING FAIL ",text)
	else:print("GROUNDING PASS ",text)
func _initialize()->void:
	if DisplayServer.get_name()=="headless" or "--test-profile" not in OS.get_cmdline_user_args():
		printerr("Grounding QA requires real renderer and -- --test-profile");quit(2);return
	root.position=Vector2i(-3500,-2000);root.size=Vector2i(1440,940);DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test-output/release-ui"))
	_run.call_deferred()
func _run()->void:
	var sim=Simulation.new();sim.reset("closed_block",3,"deception",17)
	var terminal:Vector2=Spatial.point({"position":sim.state.terminal.position})
	var actor:Dictionary=sim.state.agents.person_00
	for degrees in range(0,360,15):
		var offset:Vector2=Vector2.from_angle(deg_to_rad(float(degrees)))*1.3;var candidate:Vector2=terminal+offset
		if not Spatial.walkable(candidate,sim.state.geometry,sim.state.agents,"person_00"):continue
		if not Spatial.clear_line(candidate,terminal,sim.state.geometry,0.0,"supply_terminal",true):continue
		actor.position=[candidate.x,candidate.y];actor.heading=rad_to_deg(atan2(offset.x,offset.y));break
	var world=World.new();root.add_child(world);world.setup(sim.snapshot());world.select_agent("person_00")
	for frame in 6:await process_frame
	world.freeze_presentation(true);world.prepare_capture("person_00");await RenderingServer.frame_post_draw
	var original:Image=world.capture_agent("person_00");var original_bytes:PackedByteArray=original.get_data()
	var observer_bytes:PackedByteArray=world.observer_texture().get_image().get_data()
	var observation:Dictionary=sim.observe("person_00")
	world.set_perception_candidates("person_00",sim.perception_candidates("person_00"))
	observation=world.enrich_observation("person_00",observation)
	original.save_png("res://test-output/release-ui/grounding_original.png")
	var helper:Image=await world.grounding_image(original,observation.targets)
	check(helper!=null and helper.get_size()==Vector2i(640,360),"helper renders from actual captured image")
	helper.save_png("res://test-output/release-ui/grounding_helper.png")
	check(original.get_data()==original_bytes,"input camera CPU pixels remain exact")
	world.prepare_capture("person_00");await RenderingServer.frame_post_draw
	check(world.capture_agent("person_00").get_data()==original_bytes,"actual camera remains unchanged after helper")
	check(world.observer_texture().get_image().get_data()==observer_bytes,"observer render remains unchanged after helper")
	var changed:int=0;var outside:int=0
	for y in 360:
		for x in 640:
			if helper.get_pixel(x,y)==original.get_pixel(x,y):continue
			changed+=1
			var in_badge:bool=false
			for badge in world._grounding_badges:
				if badge.visible and Rect2(badge.position,badge.size).grow(1).has_point(Vector2(x,y)):in_badge=true;break
			if not in_badge:outside+=1
	check(changed>0 and outside==0,"only small target badge regions change pixels (%d changes; %d outside)"%[changed,outside])
	check(await world.grounding_image(original,[])==null,"empty targets produce no helper")
	check(await world.grounding_image(original,[{"ref":"terminal secret stock","uv":[0.5,0.5]},{"ref":"v0","uv":[NAN,0.5]},{"ref":"v1","uv":[1.5,0.5]},{"ref":"v2","uv":["0.5",0.5]}])==null,"arbitrary text and invalid coordinates are rejected")
	var many:Array=[]
	for index in 70:many.append({"ref":"v%d"%index,"uv":[0.5,0.5],"kind":"NEVER SHOWN","name":"NEVER SHOWN"})
	await world.grounding_image(original,many)
	var visible:int=0;var only_refs:bool=true
	for badge in world._grounding_badges:
		if badge.visible:visible+=1;only_refs=only_refs and RegEx.create_from_string("^v[0-9]+$").search(badge.text)!=null
	check(visible==64 and only_refs,"at most64 badges contain only validated temporary refs")
	_async_helper.call_deferred(world,original,[{"ref":"v10","uv":[0.2,0.2]}],"old")
	_async_helper.call_deferred(world,original,[{"ref":"v11","uv":[0.8,0.8]}],"new")
	for frame in 3:await process_frame
	check(async_results.has("old") and async_results.old==null and async_results.get("new") is Image,"overlapping calls reject stale pooled viewport results")
	_async_helper.call_deferred(world,original,[{"ref":"v12","uv":[0.4,0.4]}],"reset")
	await process_frame
	world.setup(sim.snapshot())
	for frame in 3:await process_frame
	# A reset may occur before or after that frame's render; the generation must advance.
	check(world._grounding_generation>3 and not is_instance_valid(world._grounding_viewport),"session setup invalidates and frees the pooled helper viewport")
	print("GROUNDING RESULT ",checks," checks; ",failures," failures; zero provider instances")
	quit(0 if failures==0 else 1)
