extends SceneTree
## Exercises the real enter/idle/exit queue through simulation actions in both rigs.

const Simulation = preload("res://scripts/game/session_simulation.gd")
const World = preload("res://scripts/release_world/world_view.gd")
const Seats = preload("res://scripts/game/residence_seats.gd")
const RESIDENT := "person_00"
const CHAIR := "common_reading_seat_0"
const HANDS := [&"hand_l", &"hand_r"]
const TIME_STEP := 1.0 / 60.0

var _failures: Array[String] = []
var _scenes: Array[Dictionary] = []

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var cases := [
		{"face": 0, "height": .80, "build": 1.30, "outfit": 0, "phone": false},
		{"face": 1, "height": 1.25, "build": .75, "outfit": 1, "phone": true},
		{"face": 0, "height": 1.25, "build": .75, "outfit": 2, "phone": true},
		{"face": 1, "height": 1.25, "build": 1.30, "outfit": 3, "phone": false},
	]
	for profile: Dictionary in cases:
		await check_transition(profile)
	var report := {"cases": _scenes, "failures": _failures}
	print(JSON.stringify(report))
	quit(0 if _failures.is_empty() else 1)

func check_transition(profile: Dictionary) -> void:
	var sim := Simulation.new()
	sim.reset("residence", 3, "episode", 42)
	var geometry: Dictionary = sim.state.geometry
	var chair: Dictionary = geometry.props.filter(func(prop: Dictionary): return prop.id == CHAIR)[0]
	var seat := Seats.anchor(chair, geometry)
	var actor: Dictionary = sim.state.agents[RESIDENT]
	for id: String in sim.state.agents.keys():
		if id != RESIDENT:
			sim.state.agents.erase(id)
	actor.appearance.merge(profile, true)
	actor.appearance.erase("phone")
	actor.position = [seat.approach.x, seat.approach.y]
	actor.heading = fposmod(float(seat.heading) + 180.0, 360.0)
	actor.inventory = ["phone_00"] if profile.phone else []
	sim.state.items.phone_00.holder = RESIDENT if profile.phone else ""
	sim.observe(RESIDENT)
	var refs := sim.capture_observation_refs(RESIDENT)
	var ref := ""
	for key: String in refs:
		if key != "_capture_token" and refs[key].id == CHAIR:
			ref = key
			break
	if ref.is_empty():
		_failures.append("Resident could not see the chair from its approach")
		return
	var world := World.new()
	root.add_child(world)
	world.setup(sim.snapshot())
	world.freeze_presentation(true)
	var player: AnimationPlayer = world._players[RESIDENT]
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	world._animate(RESIDENT, world._state.agents[RESIDENT], 0.0)
	player.play()
	player.advance(0.0)
	if not sim.submit(RESIDENT, {"type": "interact", "target": ref}).ok:
		_failures.append("Simulation rejected interacting with the chair")
		world.free()
		return
	sim.advance(.01)
	world.sync_state(sim.snapshot())
	world._animate(RESIDENT, world._state.agents[RESIDENT], 0.0)
	var model: Node3D = world._models[RESIDENT]
	var skeleton := model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var clips: Array[String] = []
	var wrist_travel := 0.0
	var previous := PackedVector3Array()
	var phase_frames := 0
	for frame in 240:
		var clip := String(player.current_animation).get_file()
		if clips.is_empty() or clip != clips.back():
			clips.append(clip)
			phase_frames = 0
		if clip.begins_with("Sitting_Idle") and phase_frames == 28:
			sim.submit(RESIDENT, {"type": "wait", "minutes": .04})
			sim.advance(.05)
			world.sync_state(sim.snapshot())
			world._animate(RESIDENT, world._state.agents[RESIDENT], 0.0)
		player.advance(TIME_STEP)
		world._update_wardrobe(RESIDENT)
		world._update_seat_pose(RESIDENT)
		var hands := await rendered_hands(skeleton)
		if previous.size() == hands.size():
			for index in hands.size():
				wrist_travel = maxf(wrist_travel, previous[index].distance_to(hands[index]))
		previous = hands
		phase_frames += 1
		if clips.has("Sitting_Exit") and clip.begins_with("Idle") and phase_frames >= 10:
			break
	var result := profile.duplicate()
	result.merge({"clips": clips, "max_wrist_step_m": wrist_travel, "released": not world._seat_motion.has(RESIDENT)})
	_scenes.append(result)
	if not clips.has("Sitting_Enter") or not clips.any(func(clip: String): return clip.begins_with("Sitting_Idle")) or not clips.has("Sitting_Exit") or not result.released:
		_failures.append("Incomplete enter/idle/exit queue: %s" % str(result))
	if wrist_travel > .12:
		_failures.append("Wrist crossed more than 12 cm in one 60 Hz sample: %s" % str(result))
	world.free()

func rendered_hands(skeleton: Skeleton3D) -> PackedVector3Array:
	var points := PackedVector3Array()
	var capture := func() -> void:
		for name: StringName in HANDS:
			var pose := skeleton.get_bone_global_pose(skeleton.find_bone(name))
			points.append(skeleton.to_global(pose.origin))
	skeleton.skeleton_updated.connect(capture, CONNECT_ONE_SHOT)
	skeleton.force_update_all_bone_transforms()
	await process_frame
	await process_frame
	if points.is_empty():
		if skeleton.skeleton_updated.is_connected(capture):
			skeleton.skeleton_updated.disconnect(capture)
		capture.call()
	return points
