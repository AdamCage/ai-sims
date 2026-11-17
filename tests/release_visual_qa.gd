extends SceneTree
## Independent release pixels/performance. Real renderer, no HTTP or vault.
## Run: Godot --path . --script res://tests/release_visual_qa.gd -- --test-profile
const Simulation=preload("res://scripts/game/session_simulation.gd")
const Spatial=preload("res://scripts/game/spatial_rules.gd")
const World=preload("res://scripts/release_world/world_view.gd")
const Main=preload("res://scripts/release_main.gd")
const Ledger=preload("res://scripts/release_ai/usage_ledger.gd")
const OUTPUT="res://test-output/release-visual-qa"
var checks:=0
var failures:Array=[]
var report:Dictionary={"kind":"release_real_pixels_and_performance","paid_api_calls":0,"maps":[],"performance":[]}
var world:Node3D
var game:Node
var isolation:=""

func _initialize()->void:run.call_deferred()

func check(ok:bool,message:String)->void:
	checks+=1
	if not ok:failures.append(message);printerr("FAIL VISUAL QA: ",message)
	else:print("PASS VISUAL QA: ",message)

func frames(count:int=3)->void:
	for i in count:await process_frame
	await RenderingServer.frame_post_draw

func capture(id:String)->Image:
	world.prepare_capture(id)
	await RenderingServer.frame_post_draw
	return world.capture_agent(id)

func digest(bytes:PackedByteArray)->String:
	var hash_context:=HashingContext.new();hash_context.start(HashingContext.HASH_SHA256);hash_context.update(bytes)
	return hash_context.finish().hex_encode()

func occlusion_pose(state:Dictionary)->Dictionary:
	for wall in state.geometry.walls:
		var centre:=Spatial.point(wall)
		var size:=Vector2(float(wall.size[0]),float(wall.size[1]))
		if maxf(size.x,size.y)<2.5 or float(wall.height)<2.3:continue
		var normal:=Vector2.RIGHT if size.x<size.y else Vector2.DOWN
		var along:=Vector2.DOWN if size.x<size.y else Vector2.RIGHT
		var thickness:=minf(size.x,size.y)
		var length:=maxf(size.x,size.y)
		for fraction in [-.25,0.0,.25]:
			for sign_value in [-1.0,1.0]:
				var anchor:=centre+along*length*float(fraction)
				var eye:=anchor+normal*(thickness*.5+1.5)*float(sign_value)
				var hidden:=anchor-normal*(thickness*.5+1.5)*float(sign_value)
				if not Spatial.walkable(eye,state.geometry,state.agents,"person_00") or not Spatial.walkable(hidden,state.geometry,state.agents,"person_00") or not Spatial.clear_line(hidden,hidden,state.geometry,.45):continue
				if Spatial.clear_line(eye,hidden,state.geometry,0.0,"",true):continue
				var crowded:=false
				for id in state.agents:
					if id!="person_00" and Spatial.point(state.agents[id]).distance_to(eye)<2.5:crowded=true;break
				if crowded:continue
				var direction:Vector2=(hidden-eye).normalized()
				var nearby_food:=eye+direction*1.05
				if not Spatial.walkable(nearby_food,state.geometry) or not Spatial.clear_line(eye,nearby_food,state.geometry,0.0,"",true):continue
				return {"eye":[eye.x,eye.y],"hidden":[hidden.x,hidden.y],"visible":[eye.x+direction.x*.8,eye.y+direction.y*.8],"heading":rad_to_deg(atan2(-direction.x,-direction.y)),"wall":wall.id}
	return {}

func probe_item(id:String,position:Array)->Dictionary:
	return {"id":id,"kind":"medkit","label":"QA controlled visibility probe","position":position,"holder":"","owner":"community","container":"","quantity":1,"surface_height":1.0}

func pixel_map(map_id:String)->void:
	var sim=Simulation.new();sim.reset(map_id,20,"sandbox",83)
	var state:Dictionary=sim.snapshot()
	world=World.new();root.add_child(world);world.setup(state);world.set_quality("medium")
	await frames(8);world.freeze_presentation(true);await frames(3)
	check(world.agent_viewports.size()==20,"twenty real camera viewports exist: "+map_id)
	var hashes:Array=[]
	for id in state.agents:
		var image:Image=await capture(id)
		check(not image.is_empty() and image.get_size()==Vector2i(640,360),"genuine640x360 individual pixels: "+map_id+"/"+id)
		hashes.append(digest(image.get_data()))
		if id in ["person_00","person_07","person_19"]:image.save_png(OUTPUT.path_join(map_id+"_"+id+".png"))
	var distinct:Dictionary={}
	for value in hashes:distinct[value]=true
	check(distinct.size()==20,"twenty viewpoints produce twenty different pixel hashes: "+map_id)
	var active:=0
	for viewport in world.agent_viewports.values():
		if viewport.render_target_update_mode==SubViewport.UPDATE_ALWAYS:active+=1
	check(active==0 and world.observer_viewport.render_target_update_mode==SubViewport.UPDATE_ALWAYS and world.human_viewport.render_target_update_mode==SubViewport.UPDATE_DISABLED,"observer renders while twenty capture viewports are dormant: "+map_id)
	world.set_first_person(true)
	await frames(2)
	check(world.human_viewport.render_target_update_mode==SubViewport.UPDATE_ALWAYS and world.observer_viewport.render_target_update_mode==SubViewport.UPDATE_DISABLED,"selected first-person view renders without drawing the observer scene: "+map_id)
	world.set_first_person(false)
	await frames(2)
	world.observer_texture().get_image().save_png(OUTPUT.path_join(map_id+"_observer.png"))
	var pose:=occlusion_pose(state)
	check(not pose.is_empty(),"real map supplies physical wall occlusion fixture: "+map_id)
	if not pose.is_empty():
		# Real service-factory signage must remain physically occluded. Removing
		# a whole hidden terminal catches accidental depth-free/billboard labels.
		state.geometry.props.append({"id":"qa_hidden_service","kind":"terminal","center":pose.hidden.duplicate(),"size":[.8,.8],"height":1.5,"angle":0.0,"blocking":true})
		world.setup(state);world.set_quality("medium");await frames(5);world.freeze_presentation(true)
		state.agents.person_00.position=pose.eye;state.agents.person_00.heading=pose.heading
		state.items.qa_hidden=probe_item("qa_hidden",pose.hidden)
		state.items.qa_visible=probe_item("qa_visible",pose.visible)
		world.sync_state(state,true);world.select_agent("person_00");await frames(3)
		var baseline:Image=await capture("person_00")
		baseline.save_png(OUTPUT.path_join(map_id+"_wall_occlusion.png"))
		var unchanged:Image=await capture("person_00")
		check(baseline.get_data()==unchanged.get_data(),"frozen pixel fixture is deterministic: "+map_id)
		var hidden_service:Node3D=world._content.get_node("Prop_qa_hidden_service")
		hidden_service.visible=false;await frames(2)
		var hidden_sign_removed:Image=await capture("person_00")
		check(baseline.get_data()==hidden_sign_removed.get_data(),"physical RATIONS nameplates behind a wall leak zero pixels: "+map_id)
		hidden_service.visible=true;await frames(2)
		state.items.erase("qa_hidden");world.sync_state(state,true);await frames(2)
		var hidden_removed:Image=await capture("person_00")
		check(baseline.get_data()==hidden_removed.get_data(),"removing object directly behind physical wall changes zero agent pixels: "+map_id)
		state.items.erase("qa_visible");world.sync_state(state,true);await frames(2)
		var visible_removed:Image=await capture("person_00")
		check(hidden_removed.get_data()!=visible_removed.get_data(),"removing visible object changes actual agent pixels: "+map_id)
		world.focus_position(pose.visible)
		await frames(2)
		var observer_before:PackedByteArray=world.observer_texture().get_image().get_data()
		# Keep the camera outside the box and the box in front of the wall;
		# otherwise back-face culling makes the negative control meaningless.
		var overlay:=MeshInstance3D.new();var cube:=BoxMesh.new();cube.size=Vector3(.8,.8,.8);overlay.mesh=cube
		overlay.layers=World.OVERLAY;overlay.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Observer labels draw over furniture and facades. Exercise that same
		# worst case so a wall cannot hide the fixture from the positive control.
		var material:=StandardMaterial3D.new();material.albedo_color=Color.MAGENTA;material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test=true;material.render_priority=100;overlay.material_override=material
		overlay.position=Vector3(float(pose.visible[0]),1.5,float(pose.visible[1]));world._content.add_child(overlay)
		await frames(3)
		var overlay_image:Image=await capture("person_00")
		check(overlay_image.get_data()==visible_removed.get_data(),"giant observer-only overlay changes zero personal camera pixels: "+map_id)
		check(observer_before!=world.observer_texture().get_image().get_data(),"observer overlay fixture genuinely appears in observer pixels: "+map_id)
		world.select_agent("person_01");await frames(2)
		# Refresh held-item layers exactly as the normal process loop would,
		# even though poses/animations remain frozen for byte comparison.
		world.sync_state(state,true)
		var selection_image:Image=await capture("person_00")
		overlay_image.save_png(OUTPUT.path_join(map_id+"_selection_before.png"));selection_image.save_png(OUTPUT.path_join(map_id+"_selection_after.png"))
		check(selection_image.get_data()==overlay_image.get_data(),"selection ring/names and capture-body layer never leak into agent pixels: "+map_id)
		world.agent_cameras.person_00.cull_mask|=World.OVERLAY
		world.agent_viewports.person_00.render_target_update_mode=SubViewport.UPDATE_ONCE
		await frames(2)
		check(world.capture_agent("person_00").get_data()!=selection_image.get_data(),"overlay negative control changes pixels when explicitly enabling its layer: "+map_id)
		overlay.free()
		# Tall characters must see reachable food at the navigation stopping
		# distance. A mathematically reachable ref outside the PNG cannot guide VLM.
		state.agents.person_00.appearance.height=1.2
		var forward:=Vector2(-sin(deg_to_rad(float(pose.heading))),-cos(deg_to_rad(float(pose.heading))))
		var floor_point:=Vector2(float(pose.eye[0]),float(pose.eye[1]))+forward*1.05
		state.items.qa_floor={"id":"qa_floor","kind":"ration","label":"QA nearby ration","position":[floor_point.x,floor_point.y],"holder":"","owner":"community","container":"","quantity":1,"surface_height":0.0}
		sim.state=state.duplicate(true)
		var observation:Dictionary=sim.observe("person_00")
		var food_ref:=""
		for ref in sim._refs.person_00:
			if sim._refs.person_00[ref].get("id")=="qa_floor":food_ref=str(ref)
		check(not food_ref.is_empty(),"engine perception supplies near-floor ration ref at1.05m: "+map_id)
		world.sync_state(sim.snapshot(),true);world.set_perception_candidates("person_00",sim.perception_candidates("person_00"));await frames(2)
		var floor_present:Image=await capture("person_00")
		var enriched:Dictionary=world.enrich_observation("person_00",observation)
		var projected:=false;var food_uv:Array=[]
		for target in enriched.targets:
			if target.ref==food_ref:projected=true;food_uv=target.uv
		check(projected,"max-height1.2 avatar retains nearby floor-food target inside actual image UV: "+map_id)
		var no_food:Dictionary=sim.snapshot();no_food.items.erase("qa_floor");world.sync_state(no_food,true);await frames(2)
		var floor_absent:Image=await capture("person_00")
		check(floor_present.get_data()!=floor_absent.get_data(),"near-floor ration actually contributes visible pixels for tallest avatar: "+map_id)
		floor_present.save_png(OUTPUT.path_join(map_id+"_tall_nearby_food.png"))
		var queued:Dictionary=sim.submit("person_00",{"type":"take","target":food_ref},int(sim.state.run_id));sim.advance(.01)
		check(queued.ok and sim.state.items.qa_floor.holder=="person_00" and sim.state.agents.person_00.inventory.has("qa_floor"),"VLM-visible near-food ref executes actual take through reach rules: "+map_id)
		pose["tall_avatar_food_uv"]=food_uv
		pose["baseline_hash"]=digest(baseline.get_data());pose["visible_removed_hash"]=digest(visible_removed.get_data())
	report.maps.append({"map":map_id,"agents":20,"camera_size":[640,360],"distinct_camera_hashes":distinct.size(),"always_active_eye_viewports":active,"occlusion_fixture":pose})
	world.queue_free();await frames(3)

func isolate_game()->void:
	game.repository.save_root=isolation.path_join("saves");game.repository.session_root=isolation.path_join("sessions")
	game.ledger.release_storage_lease()
	game.ledger=Ledger.new();game._ledger_path=isolation.path_join("usage.json")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(isolation))
	game.ledger.configure(1000.0,game._ledger_path,4)
	for runtime in game.runtimes.values():runtime.configure_provider(game._provider_config())
	game.repository.begin(game.simulation.snapshot())

func measure(map_id:String,running:bool,seconds:float)->Dictionary:
	game._set_running(running)
	var warmup:=Time.get_ticks_usec()+2500000
	while Time.get_ticks_usec()<warmup:await process_frame
	var timings:Array=[];var start:=Time.get_ticks_usec();var previous:=start
	while Time.get_ticks_usec()-start<seconds*1000000.0:
		await process_frame
		var now:=Time.get_ticks_usec();timings.append((now-previous)/1000.0);previous=now
	var elapsed:float=(Time.get_ticks_usec()-start)/1000000.0
	game._set_running(false)
	timings.sort()
	var slow:=0
	for timing in timings:
		if float(timing)>1000.0/60.0:slow+=1
	return {"map":map_id,"mode":"offline_demo_running" if running else "paused_presentation_with_animations","agents":20,"quality":"medium","root_pixels":[root.get_texture().get_width(),root.get_texture().get_height()],"observer_pixels":[game.world.observer_viewport.size.x,game.world.observer_viewport.size.y],"vsync":"disabled","max_fps":Engine.max_fps,"wall_seconds":elapsed,"frames":timings.size(),"average_fps":timings.size()/elapsed,"median_frame_ms":timings[timings.size()/2],"p95_frame_ms":timings[mini(timings.size()-1,floori(timings.size()*.95))],"p99_frame_ms":timings[mini(timings.size()-1,floori(timings.size()*.99))],"frames_over_16_67ms_percent":100.0*slow/timings.size(),"logical_minute_at_end":game.simulation.state.minute,"background_paid_acceptance_contention":true}

func performance_maps()->void:
	game=Main.new();root.add_child(game);current_scene=game;await frames(5);isolate_game()
	check(game.mode=="demo" and game._key.is_empty(),"performance benchmark is offline and never loads credentials")
	for map_id in ["closed_block","residence","research_station"]:
		game.new_session({"map_id":map_id,"count":20,"scenario":"sandbox","seed":83})
		game.settings.quality="medium";game.settings.speed=1.0;game.world.set_quality("medium");game.ui.show_main_menu(false)
		for running in [false,true]:
			var result:Dictionary=await measure(map_id,running,8.0)
			report.performance.append(result);print("PERFORMANCE ",JSON.stringify(result))
		check(game.world.observer_viewport.size==Vector2i(1920,1080),"benchmark actually renders observer at1080p: "+map_id)
		await frames(3);root.get_texture().get_image().save_png(OUTPUT.path_join(map_id+"_1080p_hud.png"))
	var calls:=0
	for runtime in game.runtimes.values():calls+=int(runtime.debug().live_requests_started)
	check(calls==0,"benchmark performed zero network model requests")
	game.queue_free();await frames(3)

func run()->void:
	if DisplayServer.get_name()=="headless" or "--test-profile" not in OS.get_cmdline_user_args():
		printerr("Real renderer plus -- --test-profile required; no game created");quit(2);return
	root.position=Vector2i(-4000,-2000);root.size=Vector2i(1920,1080);root.content_scale_size=Vector2i(1920,1080)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED);Engine.max_fps=0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	isolation="user://release_visual_qa_"+str(Time.get_ticks_usec())
	report["started_utc"]=Time.get_datetime_string_from_system(true)
	report["renderer"]=DisplayServer.get_name();report["gpu"]=RenderingServer.get_video_adapter_name();report["godot"]=Engine.get_version_info().string
	if "--performance-only" not in OS.get_cmdline_user_args():
		for map_id in ["closed_block","residence","research_station"]:await pixel_map(map_id)
	if "--pixels-only" not in OS.get_cmdline_user_args():await performance_maps()
	report["checks"]=checks;report["failures"]=failures
	var file_name:="pixels_report.json" if "--pixels-only" in OS.get_cmdline_user_args() else "report.json"
	if "--performance-only" in OS.get_cmdline_user_args():file_name="performance_report.json"
	var file:=FileAccess.open(OUTPUT.path_join(file_name),FileAccess.WRITE);file.store_string(JSON.stringify(report,"\t"));file.close()
	print("INDEPENDENT RELEASE VISUAL QA: ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
