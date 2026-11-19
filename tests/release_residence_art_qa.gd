extends SceneTree
## Matched, real-renderer takes for beta.2 and its replacement.
## The same fixture can run against either release PCK with --main-pack.

const Simulation = preload("res://scripts/game/session_simulation.gd")
const World = preload("res://scripts/release_world/world_view.gd")
const Spatial = preload("res://scripts/game/spatial_rules.gd")
const Seats = preload("res://scripts/game/residence_seats.gd")
const MIRA := "person_00"

var _simulation := Simulation.new()
var _world: Node3D
var _output: String
var _motion := false
var _frame_number := 0
var _failures: Array[String] = []
var _light_samples: Array[Dictionary] = []
var _capture_samples: Array[Dictionary] = []

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	_output = OS.get_environment("AISIMS_ART_QA_OUTPUT")
	_motion = "--record-motion" in OS.get_cmdline_user_args()
	if not _output.is_absolute_path() or DisplayServer.get_name() == "headless":
		printerr("Set absolute AISIMS_ART_QA_OUTPUT and use a real renderer")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_output)
	if _motion:
		DirAccess.make_dir_recursive_absolute(_output.path_join("motion"))
	root.borderless = true
	root.position = Vector2i(-4000, -2500)
	root.size = Vector2i(1920, 1080)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 30
	_simulation.reset("residence", 8, "episode", 42)
	var geometry: Dictionary = _simulation.state.geometry
	var chair: Dictionary = geometry.props.filter(func(prop): return prop.id == "common_reading_seat_0")[0]
	var anchor := Seats.anchor(chair, geometry)
	var approach: Vector2 = anchor.approach
	var facing := Spatial.point(chair) - approach
	var start := approach - facing.normalized() * 0.85
	var actor: Dictionary = _simulation.state.agents[MIRA]
	actor.position = [start.x, start.y]
	actor.heading = rad_to_deg(atan2(-facing.x, -facing.y))
	_world = World.new()
	root.add_child(_world)
	_world.setup(_simulation.snapshot())
	_world.set_display_size(Vector2i(1920, 1080))
	_world.set_quality("high")
	_world.select_agent(MIRA)
	shot(Vector3(approach.x, 0.9, approach.y - 0.25), 0.77, 22.0, 3.2)
	await capture("01-hall")
	var chair_ref := visible_reference(chair.id)
	if not check(not chair_ref.is_empty(), "Mira can see the reading chair"):
		finish()
		return
	if not await action({"type": "move_to", "target": chair_ref}):
		finish()
		return
	check(Spatial.point(actor).distance_to(approach) < 0.06, "walked to the chair through simulation")
	if not await action({"type": "interact", "target": chair_ref}):
		finish()
		return
	var seat: Vector2 = anchor.position
	shot(Vector3(seat.x, 0.83, seat.y), 0.71, 15.0, 2.3)
	for frame in 39:
		await step(0.025, frame % 2 == 0)
		if frame == 12:
			await capture("02-sitting-down")
	check(str(_world._players[MIRA].current_animation).begins_with("Sitting_Idle"), "settled on the chair")
	await capture("03-seated")
	if not await action({"type": "speak", "text": "Мама, я помогу. Возьмём овощи."}):
		finish()
		return
	shot(Vector3(seat.x, 1.07, seat.y + 0.07), 0.35, 9.0, 0.83)
	for frame in 42:
		await step(0.022, frame % 2 == 0)
		if frame == 15:
			await capture("04-dialogue")
	_world.prepare_capture(MIRA)
	await RenderingServer.frame_post_draw
	var eyes: Image = _world.capture_agent(MIRA)
	check(not eyes.is_empty() and eyes.save_png(_output.path_join("05-private.png")) == OK, "private frame written")
	shot(Vector3(seat.x, 0.86, seat.y), 0.71, 14.0, 2.3)
	await action({"type": "wait", "minutes": 0.04})
	var exit_frames := 0
	for frame in 32:
		await step(0.025, frame % 2 == 0)
		if str(_world._players[MIRA].current_animation).ends_with("Sitting_Exit"):
			exit_frames += 1
		if frame == 4:
			await capture("06-standing-up")
	if ProjectSettings.get_setting("application/config/version") == "0.3.0-beta.4":
		check(exit_frames > 4, "conversation followed by standing plays the supported exit transition")
	_world.frame_story_start()
	for point in [Vector2(7.4, -8.5), Vector2(14.5, -8.5), Vector2(16.2, -16.0), Vector2(17.6, -25.0), Vector2(22.9, -25.0), Vector2(25.4, -25.0)]:
		if not await walk_to(point):
			finish()
			return
		if point.x == 14.5:
			await capture("07-courtyard")
	await capture("08-shop")
	var kitchen: Array = geometry.zones.dining
	shot(Vector3(kitchen[0], 0.9, kitchen[1]), 0.56, 39.0, 10.9)
	await capture("09-kitchen")
	shot(Vector3(13.6, 1.2, -7.5), 0.47, 28.0, 13.5)
	var sun := _world._content.get_node("Sun") as DirectionalLight3D
	for time in [0.0, 240.0, 600.0]:
		var snapshot := _simulation.snapshot()
		snapshot.minute = time
		_world.sync_state(snapshot, true)
		_light_samples.append({"minute":time, "rotation":str(sun.rotation_degrees), "energy":sun.light_energy, "color":sun.light_color.to_html()})
		await capture("10-light-%03d" % int(time), time)
	if ProjectSettings.get_setting("application/config/version") != "0.3.0-beta.2":
		check(_light_samples[0].rotation != _light_samples[1].rotation and _light_samples[1].rotation != _light_samples[2].rotation,
			"morning, noon and evening have distinct solar positions")
		var morning := _simulation.snapshot()
		morning.minute = 0.0
		_world.sync_state(morning, true)
		check(str(sun.rotation_degrees) == _light_samples[0].rotation and sun.light_color.to_html() == _light_samples[0].color,
			"seeking to the same minute restores the same lighting")
		check_room_cutaway(geometry.rooms.size())
	finish()

func check_room_cutaway(room_count: int) -> void:
	var roofs: Array = _world._residence_roofs
	check(roofs.size() == room_count and roofs.all(func(roof): return not roof.details.is_empty()), "every canonical room has authored roof details")
	if roofs.is_empty() or roofs[0].details.is_empty():
		return
	var entry: Dictionary = roofs[0]
	var focus: Vector2 = entry.room.get_center()
	shot(Vector3(focus.x, 1.0, focus.y), 0.73, 28.0, 3.3)
	check(entry.mesh.layers == World.WALLS and entry.details.all(func(mesh): return mesh.layers == World.WALLS),
		"observer cuts roof fixtures while private eyes keep their wall layer")

func visible_reference(entity_id: String) -> String:
	_simulation.observe(MIRA)
	var refs := _simulation.capture_observation_refs(MIRA)
	for ref in refs:
		if ref != "_capture_token" and refs[ref].id == entity_id:
			return ref
	return ""

func walk_to(destination: Vector2) -> bool:
	var actor: Dictionary = _simulation.state.agents[MIRA]
	for leg in range(5):
		var offset := destination - Spatial.point(actor)
		if offset.length() < 0.15:
			return true
		var heading := deg_to_rad(float(actor.heading))
		var direction := offset.limit_length(3.8)
		var forward := direction.dot(Vector2(-sin(heading), -cos(heading)))
		var right := direction.dot(Vector2(cos(heading), -sin(heading)))
		if not await action({"type": "move", "forward": forward, "right": right}):
			return false
	return check(Spatial.point(actor).distance_to(destination) < 0.15, "walked to %s" % destination)

func action(intent: Dictionary) -> bool:
	if not check(_simulation.submit(MIRA, intent).ok, "submitted " + str(intent.type)):
		return false
	await step(0.025, false)
	var actor: Dictionary = _simulation.state.agents[MIRA]
	if not check(actor.last_result.ok, str(actor.last_result.message)):
		return false
	var number := 0
	while actor.busy.get("type") == "move_to" and number < 160:
		await step(0.025, number % 3 == 0)
		number += 1
	return check(number < 160 and actor.last_result.ok, "completed " + str(intent.type))

func shot(point: Vector3, yaw: float, elevation: float, zoom: float) -> void:
	_world.restore_camera({"focus": point, "yaw": yaw, "elevation": elevation, "zoom": zoom,
		"follow": false, "first_person": false, "user_camera": true, "perspective": true})

func step(minute: float, record: bool) -> void:
	_simulation.advance(minute)
	_world.sync_state(_simulation.state)
	await process_frame
	await RenderingServer.frame_post_draw
	if _motion and record:
		var name := "motion/frame-%04d.jpg" % _frame_number
		var image: Image = _world.observer_texture().get_image()
		image.save_jpg(_output.path_join(name), 0.92)
		_sample_capture(name)
		_frame_number += 1

func capture(name: String, displayed_minute: float = -1.0) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	check(_world.observer_texture().get_image().save_png(_output.path_join(name + ".png")) == OK, "captured " + name)
	_sample_capture(name + ".png", displayed_minute)

func _sample_capture(file: String, displayed_minute: float = -1.0) -> void:
	var player: AnimationPlayer = _world._players[MIRA]
	var camera: Camera3D = _world.observer_camera
	var actor: Dictionary = _simulation.state.agents[MIRA]
	var minute := displayed_minute if displayed_minute >= 0.0 else float(_simulation.state.minute)
	_capture_samples.append({"file": file, "minute": minute, "camera": str(camera.global_transform),
		"projection": camera.projection, "fov": camera.fov, "orthographic_size": camera.size,
		"animation": player.current_animation, "clip_time": player.current_animation_position if player.is_playing() else 0.0,
		"position": actor.position.duplicate(), "appearance": actor.appearance.duplicate(), "inventory": actor.inventory.duplicate()})

func check(passed: bool, reason: String) -> bool:
	print("PASS " if passed else "FAIL ", reason)
	if not passed:
		_failures.append(reason)
	return passed

func finish() -> void:
	var arguments := OS.get_cmdline_args()
	var fixed_fps_index := arguments.find("--fixed-fps")
	var fixed_fps := int(arguments[fixed_fps_index + 1]) if fixed_fps_index >= 0 and fixed_fps_index < arguments.size() - 1 else 0
	var output := FileAccess.open(_output.path_join("report.json"), FileAccess.WRITE)
	output.store_string(JSON.stringify({"seed": 42, "renderer": RenderingServer.get_current_rendering_method(),
		"version": ProjectSettings.get_setting("application/config/version"), "motion_frames": _frame_number, "lighting": _light_samples,
		"resolution": [1920, 1080], "fixed_fps": fixed_fps,
		"captures": _capture_samples, "failures": _failures}, "\t"))
	quit(0 if _failures.is_empty() else 1)
