extends SceneTree
## Run with --headless --script res://tests/release_navigation_qa.gd -- --test-profile.

const Main = preload("res://scripts/release_main.gd")
const ObserverMap = preload("res://scripts/release_ui/observer_minimap.gd")
const Repository = preload("res://scripts/release_storage/session_repository.gd")
const ResidenceSeats = preload("res://scripts/game/residence_seats.gd")
const Simulation = preload("res://scripts/game/session_simulation.gd")
const Spatial = preload("res://scripts/game/spatial_rules.gd")

var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(condition: bool, description: String) -> void:
	print("PASS " if condition else "FAIL ",description)
	if not condition:failures+=1

func run() -> void:
	var game = Main.new()
	root.add_child(game)
	await process_frame
	game.repository.save_root=game.repository.session_root.path_join("navigation_"+str(Time.get_ticks_usec()))
	game.ui.show_main_menu(false)
	var map := ObserverMap.new()
	root.add_child(map)
	map.size=Vector2(300,180)
	for id in ["closed_block","residence","research_station"]:
		await game.new_session({"map_id":id,"count":20,"scenario":"sandbox","seed":83})
		map.set_geometry(game.simulation.state.geometry,{})
		var original: Vector2 = game.world.display_agent_positions()["person_03"]
		check(map.map_to_world(map.world_to_map(original)).distance_to(original)<0.001,"floor plan round trip on "+id)
		game._on_command("select",{"id":"person_03"})
		check(game.selected=="person_03" and not game.world.follow_selected,"selection centers independently of follow on "+id)
		game._on_command("view",{"first_person":true})
		game._on_command("select",{"id":"person_07"})
		check(game.selected=="person_07" and game.world.first_person,"selection preserves eye mode on "+id)
		game._on_command("focus_location",{"position":[original.x,original.y]})
		check(not game.world.first_person and not game.world.follow_selected,"map location switches to observer on "+id)
		game._on_command("follow",{})
		check(game.world.follow_selected,"explicit follow on "+id)
		game._on_command("fit_map",{})
		check(not game.world.follow_selected and game.world.camera_map_state().footprint.size()==4,"map overview restores camera footprint on "+id)
		game._on_command("fit_map",{})
		check(game.world.follow_selected and not game.world.camera_map_state().overview,"leaving overview restores following on "+id)
	await game.new_session({"map_id":"residence","count":8,"scenario":"episode","seed":83})
	var opening: Dictionary = game.world.snapshot_camera()
	check(opening.perspective and opening.follow and game.world.observer_camera.projection==Camera3D.PROJECTION_PERSPECTIVE,"residence opens at resident scale")
	var opening_footprint: PackedVector2Array = game.world.camera_map_state().footprint
	check(opening_footprint.size()==4 and opening_footprint[0].is_finite() and opening_footprint[0].distance_to(opening_footprint[1])>0.1,"perspective corners project onto the floor")
	check_observer_cutaway(game.world)
	game.world.restore_camera(opening)
	game._on_command("fit_map",{})
	check(game.world.observer_camera.projection==Camera3D.PROJECTION_ORTHOGONAL and game.world.camera_map_state().overview,"temporary overview uses an orthographic projection")
	game._on_command("fit_map",{})
	check(game.world.snapshot_camera()==opening,"temporary overview restores the perspective camera exactly")
	game._on_command("view",{"first_person":true})
	game._on_command("fit_map",{})
	game._on_command("fit_map",{})
	check(game.world.first_person and not game.world.camera_map_state().overview,"temporary overview returns to the private view")
	game._on_command("view",{"first_person":false})
	game._on_command("select",{"id":"person_07"})
	map.queue_free()
	game.world.set_display_size(Vector2i(3840,2160))
	check(game.world.observer_viewport.size==Vector2i(3840,2160),"native 4K observer buffer")
	game.world.set_render_scale(0.75)
	check(game.world.observer_viewport.size==Vector2i(2880,1620) and game.world.human_viewport.size==Vector2i(2880,1620),"3D scale applies only to public buffers")
	check(game.world.agent_viewports["person_00"].size==Vector2i(640,360),"private capture keeps its own size")
	var person: Dictionary = game.simulation.state.agents.person_00
	check(str(game.world._animation_keys.get("person_00","")).begins_with("Idle"),"imported idle clip plays")
	game.world._animate("person_00",person,1.65)
	var player: AnimationPlayer = game.world._players.person_00
	check(str(player.current_animation).begins_with("Walk") and player.speed_scale>1.0,"imported walk cadence tracks movement")
	var resting := person.duplicate(true)
	resting.busy = {"type": "rest"}
	game.world._animate("person_00",resting,0.0)
	check(str(player.current_animation).begins_with("Idle"),"rest in place keeps the standing pose grounded")
	check(game.world._held_markers.person_00.get_parent() is BoneAttachment3D,"held items use an animated hand attachment")
	await check_chronicle(game)
	check_seated_rest()
	game.queue_free()
	await process_frame
	quit(1 if failures else 0)

func check_seated_rest() -> void:
	var simulation := Simulation.new()
	simulation.reset("residence", 8, "sandbox", 83)
	var geometry: Dictionary = simulation.state.geometry
	var prop: Dictionary
	for candidate: Dictionary in geometry.props:
		var anchor := ResidenceSeats.anchor(candidate, geometry)
		if not anchor.is_empty():
			check(Spatial.walkable(anchor.approach, geometry), "clear floor at " + str(candidate.id))
		if candidate.id == "common_reading_seat_0":
			prop = candidate
	var chair := ResidenceSeats.anchor(prop, geometry)
	check(not chair.is_empty(), "reading chair has a fitted seat anchor")
	if chair.is_empty():
		return
	var id := "person_00"
	var resident: Dictionary = simulation.state.agents[id]
	var approach: Vector2 = chair.approach
	var direction := Spatial.point(prop) - approach
	var initial := approach - direction.normalized() * 0.45
	resident.position = [initial.x, initial.y]
	resident.heading = rad_to_deg(atan2(-direction.x, -direction.y))
	check(Spatial.walkable(approach, geometry, simulation.state.agents, id), "seat approach remains walkable")
	check(ResidenceSeats.anchor(prop, {"palette": "blue"}).is_empty(), "other maps use their original chair behavior")
	var target := prop_reference(simulation, id, prop.id)
	check(not target.is_empty(), "resident can see chair from its approach")
	if target.is_empty():
		return
	simulation.submit(id, {"type": "interact", "target": target})
	simulation.advance(0.1)
	check(not resident.last_result.ok and not resident.busy.has("seat"), "an out-of-position resident cannot reserve the chair")
	check(simulation.submit(id, {"type": "move_to", "target": target}).ok, "chair route uses the normal intent path")
	simulation.advance(0.5)
	check(Spatial.point(resident).is_equal_approx(approach), "chair route ends at the fitted approach")
	check(simulation.submit(id, {"type": "interact", "target": target}).ok, "chair interaction uses the normal intent path")
	simulation.advance(0.1)
	check(resident.busy.get("seat_positioned", false), "chair interaction seats the resident")
	check(Spatial.sight_origin(resident, geometry).is_equal_approx(chair.position), "seated sight originates at the chair")
	check(Spatial.point(resident).is_equal_approx(approach), "seated resident keeps a clear route origin")
	var second: Dictionary = simulation.state.agents.person_01
	var waiting := approach - direction.normalized() * 0.63 + direction.normalized().orthogonal() * 0.45
	var look := Spatial.point(prop) - waiting
	second.position = [waiting.x, waiting.y]
	second.heading = rad_to_deg(atan2(-look.x, -look.y))
	var second_target := prop_reference(simulation, second.id, prop.id)
	check(not second_target.is_empty(), "another resident can see an occupied chair")
	if not second_target.is_empty():
		simulation.submit(second.id, {"type": "interact", "target": second_target})
		simulation.advance(0.1)
		check(not second.last_result.ok and not second.busy.has("seat") and resident.busy.seat == prop.id, "a second resident cannot claim the same seat")
	var saved := simulation.export_state()
	var restored := Simulation.new()
	check(restored.import_state(saved), "a seated resident survives save and load")
	saved.world.agents[id].busy.erase("seat_positioned")
	check(restored.import_state(saved), "older chair rest snapshots still load")
	check(ResidenceSeats.occupied(restored.state.agents[id], restored.state.geometry).is_empty(), "older snapshots keep their original standing position")
	simulation.advance(11.0)
	check(ResidenceSeats.occupied(resident, geometry).is_empty(), "completed rest releases the seat")
	check(Spatial.sight_origin(resident, geometry).is_equal_approx(approach), "standing restores the regular sight origin")

func prop_reference(simulation: RefCounted, actor_id: String, prop_id: String) -> String:
	simulation.observe(actor_id)
	var references: Dictionary = simulation.capture_observation_refs(actor_id)
	for key: String in references:
		if key != "_capture_token" and references[key].id == prop_id:
			return key
	return ""

func check_observer_cutaway(world: Node3D) -> void:
	var canopy: Dictionary = world._residence_canopies[0]
	var bounds: AABB = canopy.bounds
	var normal: Vector2 = canopy.normal
	var center := bounds.get_center()
	var outward := Vector3(normal.x,0.0,normal.y)
	world.follow_selected = false
	world._yaw = atan2(-normal.x,-normal.y)
	world._focus = center + outward * 2.0 - Vector3.UP * 1.1
	world.observer_camera.global_position = center - outward * 2.0 + Vector3.UP * 1.1
	world._update_facades()
	check(canopy.meshes.all(func(mesh): return mesh.layers == world.WALLS),"entrance canopy clears observer sight without disappearing from resident cameras")
	var side := Vector3(-normal.y,0.0,normal.x) * 5.0
	world._focus += side
	world.observer_camera.global_position += side
	world._update_facades()
	check(canopy.meshes.all(func(mesh): return mesh.layers == (world.WALLS | world.CUTAWAY)),"unobstructed entrance canopy returns to the observer view")

func check_chronicle(game: Node) -> void:
	var start: int = game.simulation.state.event_cursor
	for batch in 22:
		for row in 25:
			game.simulation._event("person_00","look",row!=0,"Journal fixture %d/%d"%[batch,row],{})
		game._record()
	var event_sequence := start+9
	var frame: int = game.repository.frame_for_event(event_sequence)
	check(game.simulation.state.events.size()==500 and game._chronicle.size()>500 and frame==1,"old events are indexed beyond the simulation tail")
	game._on_command("replay_event",{"seq":event_sequence})
	check(game._reviewing and game._replay_paused and game._replay_cursor==frame,"opening a record seeks to a paused historical frame")
	check(game._replay_events.any(func(event):return int(event.seq)==event_sequence) and game._replay_events.size()<game._chronicle.size(),"historical event prefix excludes future events")
	await game.load_slot(2)
	check(game._reviewing and game._replay_cursor==frame,"missing save leaves historical view intact")
	game._on_command("replay_event",{"seq":0})
	check(game._reviewing and game._replay_cursor==0,"opening another record during replay seeks again")
	game._on_command("replay_seek",{"frame":0})
	check(not game._replay_events.any(func(event):return int(event.seq)==event_sequence),"backward seek shrinks the displayed event prefix")
	game._on_command("replay_exit",{})
	check(not game._reviewing and not game.running and game.selected=="person_07","return to current paused session and selection")
	var stored: Dictionary = {"world":game.simulation.export_state()}
	check(game.repository.save_slot(1,stored)==OK,"archive saves the expanded history")
	var portable: Dictionary = game.repository.load_slot(1).data.replay
	var restored := Repository.new()
	restored.session_root=game.repository.session_root
	check(restored.resume_from_slot(game.simulation.snapshot(),portable) and restored.frame_for_event(event_sequence)==frame,"portable archive rebuilds the event-to-frame index")
	var legacy := Repository.new()
	legacy.session_root=game.repository.session_root
	check(legacy.resume_from_slot(game.simulation.snapshot(),{}) and legacy.frame_for_event(start+80)==-1,"a legacy event tail has no fabricated historical frame")
