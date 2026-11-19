extends SceneTree
## Independent release pixels/performance. Real renderer, no HTTP or vault.
## Run: Godot --path . --script res://tests/release_visual_qa.gd -- --test-profile
## Timing gate: --performance-only --benchmark --require-60
## Restrict a run with --qa-map=closed_block or --qa-output=3840x2160.
const Simulation=preload("res://scripts/game/session_simulation.gd")
const Spatial=preload("res://scripts/game/spatial_rules.gd")
const World=preload("res://scripts/release_world/world_view.gd")
const Main=preload("res://scripts/release_main.gd")
const Ledger=preload("res://scripts/release_ai/usage_ledger.gd")
const OUTPUT="res://test-output/release-visual-qa"
const MAPS := ["closed_block", "residence", "research_station"]
const OUTPUTS := [Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]
const FRAME_BUDGET_MS := 1000.0 / 60.0
const POPULATION := 20
const SEED := 83
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

func output_pixels() -> Vector2i:
	# Canvas-item stretching changes the ViewportTexture size metadata. The
	# native client and captured image use the unscaled physical drawable.
	return DisplayServer.window_get_size(root.get_window_id())

func dimensions(size: Vector2i) -> Array[int]:
	return [size.x, size.y]

func output_name(size: Vector2i) -> String:
	return "%dx%d" % dimensions(size)

func percentile(sorted: PackedFloat64Array, fraction: float) -> float:
	return sorted[clampi(ceili(sorted.size() * fraction) - 1, 0, sorted.size() - 1)]

func measure(map_id: String, requested: Vector2i, config: Dictionary, iteration: int, running: bool) -> Dictionary:
	game._set_running(running)
	var warmup_end := Time.get_ticks_usec() + int(config.warmup * 1000000)
	while Time.get_ticks_usec() < warmup_end:
		await RenderingServer.frame_post_draw
	var start := Time.get_ticks_usec()
	var previous := start
	var end := start + int(config.seconds * 1000000)
	var first_tick := int(game.simulation.state.tick)
	var timings := PackedFloat64Array()
	var slow := 0
	var draw_calls := 0
	var draw_samples := 0
	while previous < end:
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		var frame_ms := (now - previous) / 1000.0
		timings.append(frame_ms)
		if frame_ms > FRAME_BUDGET_MS:
			slow += 1
		if timings.size() % 60 == 1:
			draw_calls += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
			draw_samples += 1
		previous = now
	var elapsed := (previous - start) / 1000000.0
	var ticks := int(game.simulation.state.tick) - first_tick
	game._set_running(false)
	timings.sort()
	return {
		"map": map_id, "iteration": iteration, "mode": "offline_demo_running" if running else "paused",
		"agents": config.population, "seed": SEED, "scenario": config.scenario, "quality": config.quality, "render_scale": config.scale,
		"requested_pixels": dimensions(requested), "root_pixels": dimensions(output_pixels()),
		"observer_pixels": dimensions(game.world.observer_viewport.size), "vsync": "disabled", "max_fps": Engine.max_fps,
		"warmup_seconds": config.warmup, "wall_seconds": elapsed, "frames": timings.size(),
		"average_fps": timings.size() / elapsed, "median_frame_ms": percentile(timings, 0.5),
		"p95_frame_ms": percentile(timings, 0.95), "p99_frame_ms": percentile(timings, 0.99),
		"frames_over_16_67ms_percent": 100.0 * slow / timings.size(), "ticks_advanced": ticks,
		"mean_draw_calls": float(draw_calls) / draw_samples,
		"video_memory_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),
	}

func check_output(size: Vector2i, scale: float) -> bool:
	var expected := Vector2i((Vector2(size) * scale).round())
	var description := "%s at %.0f%% world scale" % [output_name(size), scale * 100.0]
	var actual := output_pixels()
	var observer: Vector2i = game.world.observer_viewport.size
	var human: Vector2i = game.world.human_viewport.size
	var private_eye: Vector2i = game.world.agent_viewports.person_00.size
	check(actual == size, "client drawable %s requested, %s actual" % [output_name(size), output_name(actual)])
	check(observer == expected, "observer render target for %s is %s" % [description, output_name(observer)])
	check(human == expected, "first-person render target for %s is %s" % [description, output_name(human)])
	check(private_eye == Vector2i(640, 360), "private camera remains 640x360 at " + description)
	return actual == size and observer == expected and human == expected and private_eye == Vector2i(640, 360)

func save_hud_capture(name: String, size: Vector2i) -> void:
	var image := root.get_texture().get_image()
	check(image != null and image.get_size() == size, "captured pixels match " + name)
	if image != null and not image.is_empty():
		var colors := {}
		for y in range(20, image.get_height(), 55):
			for x in range(20, image.get_width(), 47):
				colors[image.get_pixel(x, y).to_rgba32()] = true
		check(colors.size() >= 20, "capture contains rendered content " + name)
		check(image.save_png(OUTPUT.path_join(name + ".png")) == OK, "saved screenshot " + name)

func output_qa(config: Dictionary, resolution_only: bool) -> void:
	game = Main.new()
	root.add_child(game)
	current_scene = game
	await frames(5)
	isolate_game()
	check(game.mode == "demo" and game._key.is_empty(), "benchmark uses isolated offline demo settings")
	for size: Vector2i in config.outputs:
		root.size = size
		await frames(5)
		for map_id: String in config.maps:
			for iteration in range(1, int(config.repeats) + 1):
				await game.new_session({"map_id": map_id, "count": config.population, "scenario": config.scenario, "seed": SEED})
				game._on_command("settings", {"quality": config.quality, "render_scale": config.scale, "speed": 1.0})
				game.ui.show_main_menu(false)
				if config.scenario == "sandbox":game.world.show_map()
				await frames(2)
				game.ui._chapter_popup.hide()
				await frames(5)
				if not check_output(size, config.scale):
					continue
				if resolution_only:
					var name := map_id + "_" + output_name(size)
					save_hud_capture(name + "_observer", size)
					game._on_command("view", {"first_person": true})
					await frames(4)
					check(game.world.human_viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "human view renders " + name)
					save_hud_capture(name + "_first_person", size)
					game._on_command("view", {"first_person": false})
					continue
				if config.paused:
					var paused := await measure(map_id, size, config, iteration, false)
					report.performance.append(paused)
					print("PERFORMANCE ", JSON.stringify(paused))
				var result := await measure(map_id, size, config, iteration, true)
				report.performance.append(result)
				print("PERFORMANCE ", JSON.stringify(result))
				check(result.ticks_advanced > 0, "measured active simulation for " + map_id + " at " + output_name(size))
				if config.require_60:
					var label := "%s %s pass %d" % [map_id, output_name(size), iteration]
					check(result.average_fps >= 60.0 and result.p95_frame_ms <= FRAME_BUDGET_MS,
						"average >=60 FPS and p95 <=16.67ms: " + label)
					check(result.p99_frame_ms <= 2.0 * FRAME_BUDGET_MS, "p99 <=33.33ms: " + label)
			var calls := 0
			for runtime in game.runtimes.values():
				calls += int(runtime.debug().live_requests_started)
			check(calls == 0, "zero provider requests for " + map_id)
	root.size = config.outputs[0]
	game._on_command("settings", {"render_scale": 0.75})
	await frames(6)
	check_output(config.outputs[0], 0.75)
	game.queue_free()
	await frames(3)

func qa_config(args: PackedStringArray) -> Dictionary:
	var long_test := "--benchmark" in args
	var config := {"maps": MAPS, "outputs": OUTPUTS, "quality": "medium", "scale": 1.0,
		"population": POPULATION, "scenario": "sandbox",
		"warmup": 10.0 if long_test else 2.5, "seconds": 60.0 if long_test else 8.0,
		"repeats": 3 if long_test else 1, "require_60": "--require-60" in args, "paused": "--include-paused" in args}
	for arg in args:
		if arg.begins_with("--qa-output="):
			var name := arg.get_slice("=", 1)
			config.outputs = OUTPUTS.filter(func(size): return output_name(size) == name)
		elif arg.begins_with("--qa-map="):
			var map_id := arg.get_slice("=", 1)
			config.maps = MAPS.filter(func(candidate): return candidate == map_id)
		elif arg.begins_with("--qa-quality="):
			config.quality = arg.get_slice("=", 1)
		elif arg.begins_with("--qa-scale="):
			config.scale = arg.get_slice("=", 1).to_float()
		elif arg.begins_with("--qa-agents="):
			config.population = arg.get_slice("=", 1).to_int()
		elif arg.begins_with("--qa-scenario="):
			config.scenario = arg.get_slice("=", 1)
	if config.maps.is_empty() or config.outputs.is_empty() or config.quality not in ["low", "medium", "high"] or config.scale < 0.5 or config.scale > 1.0 or config.population < 3 or config.population > 20 or config.scenario not in ["sandbox", "episode"]:
		return {}
	return config

func run()->void:
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name()=="headless" or "--test-profile" not in args:
		printerr("Real renderer plus -- --test-profile required; no game created");quit(2);return
	var config := qa_config(args)
	if config.is_empty():
		printerr("Use a supported --qa-map and --qa-output, --qa-quality=low|medium|high, and --qa-scale=0.5..1.0")
		quit(2)
		return
	var offscreen := "--onscreen" not in args
	root.borderless = true
	if offscreen:
		root.position = Vector2i(-4000, -2500)
	root.size = config.outputs[0]
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED);Engine.max_fps=0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	isolation="user://release_visual_qa_"+str(Time.get_ticks_usec())
	report["started_utc"]=Time.get_datetime_string_from_system(true)
	report["display_server"] = DisplayServer.get_name()
	report["renderer"] = RenderingServer.get_current_rendering_method()
	report["gpu"] = RenderingServer.get_video_adapter_name()
	report["graphics_api"] = RenderingServer.get_video_adapter_api_version()
	report["godot"] = Engine.get_version_info().string
	report["offscreen_window"] = offscreen
	report["display_pixels"] = dimensions(DisplayServer.screen_get_size())
	var resolution_only := "--resolution-only" in args
	if "--performance-only" not in args and not resolution_only:
		for map_id: String in config.maps:
			await pixel_map(map_id)
	if "--pixels-only" not in args:
		await output_qa(config, resolution_only)
	report["checks"]=checks;report["failures"]=failures
	var file_name := "report.json"
	if "--pixels-only" in args: file_name = "pixels_report.json"
	if "--performance-only" in args: file_name = "performance_report.json"
	if resolution_only: file_name = "resolution_report.json"
	var file:=FileAccess.open(OUTPUT.path_join(file_name),FileAccess.WRITE);file.store_string(JSON.stringify(report,"\t"));file.close()
	print("INDEPENDENT RELEASE VISUAL QA: ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
