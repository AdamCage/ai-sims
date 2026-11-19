extends SceneTree
## Checks the imported face contract and deterministic expression across seeks.

const Simulation = preload("res://scripts/game/session_simulation.gd")
const Face = preload("res://scripts/release_world/face_modifier.gd")
const World = preload("res://scripts/release_world/world_view.gd")

var _failed := 0

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	check(Face.articulation("Мама") == [&"Viseme_MBP", &"Viseme_A", &"Viseme_MBP", &"Viseme_A"], "Cyrillic vowel and lip closure")
	check(Face.articulation("fish") == [&"Viseme_FV", &"Viseme_I", &"Viseme_SZ"], "Latin articulation with consonant pair")
	check(Face.articulation(" ... ").is_empty(), "punctuation has no mouth pose")
	for rig in ["male", "female"]:
		var packed := load("res://assets/release/characters/human_" + rig + ".glb") as PackedScene
		var model := packed.instantiate() as Node3D
		root.add_child(model)
		var skin := model.find_child("ResidentSkin", true, false) as MeshInstance3D
		var skeleton := model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
		check(skeleton.find_bone("Eye_L") >= 0 and skeleton.find_bone("Eye_R") >= 0, rig + " has independent eye pivots")
		for key in Face.SPEECH_SHAPES + [&"Identity_1", &"Identity_2", &"Blink_L", &"Blink_R", &"Brow_Up", &"Brow_Down", &"Smile", &"Tension", &"Lids_Up", &"Lids_Down", &"Concern"]:
			check(skin != null and skin.find_blend_shape_by_name(key) >= 0, rig + " supplies " + str(key))
		var face := Face.new()
		check(face.bind_model(model, rig), rig + " binds the shared expression controller")
		var lids_up := skin.find_blend_shape_by_name(&"Lids_Up")
		var concern := skin.find_blend_shape_by_name(&"Concern")
		face.set_context(1, "We move", 24.0, false, Vector2(0.16, -0.18), 0.32)
		face.present(48.2, true, true)
		var gaze := skin.get_blend_shape_value(lids_up)
		var expression := skin.get_blend_shape_value(concern)
		check(gaze > 0.3 and expression > 0.1, rig + " tracks gaze and concern while speaking")
		face.present(49.0, false, true)
		check(is_zero_approx(skin.get_blend_shape_value(lids_up)), rig + " clears gaze when asleep")
		face.present(48.2, true, true)
		check(is_equal_approx(gaze, skin.get_blend_shape_value(lids_up))
			and is_equal_approx(expression, skin.get_blend_shape_value(concern)), rig + " restores gaze and expression after seeking")
		model.free()
	var sim := Simulation.new()
	sim.reset("residence", 8, "episode", 42)
	var before := sim.snapshot()
	check(sim.submit("person_00", {"type": "speak", "text": "Мааа"}).ok, "speech accepted by authoritative action path")
	var events := sim.advance(0.1)
	var dialogue := events.filter(func(entry): return entry.type == "speak")
	if dialogue.is_empty():
		check(false, "world journals the executed speech")
		quit(1)
		return
	var event: Dictionary = dialogue[0]
	check(event.details.get("text") == "Мааа" and event.details.get("listeners") is Array, "journal retains the real spoken line and hearing recipients")
	var during := sim.snapshot()
	# The face must use the recorded line even if a different action is already last.
	during.agents.person_00.last_action = {"type": "wait"}
	var world := World.new()
	root.add_child(world)
	world.setup(before)
	var mesh := world._models.person_00.find_child("ResidentSkin", true, false) as MeshInstance3D
	var shape := mesh.find_blend_shape_by_name(&"Viseme_A") if mesh != null else -1
	if shape >= 0:
		world.sync_state(during, true)
		var spoken := mesh.get_blend_shape_value(shape)
		check(spoken > 0.5, "displayed frame articulates previously spoken text")
		world.preview_character(during.agents.person_00)
		var studio_skin := world._portrait.model.find_child("ResidentSkin", true, false) as MeshInstance3D
		var studio_vowel := studio_skin.find_blend_shape_by_name(&"Viseme_A")
		check(is_equal_approx(spoken, studio_skin.get_blend_shape_value(studio_vowel)),
			"appearance studio previews the selected resident's spoken line at the displayed minute")
		world.sync_state(before, true)
		check(is_zero_approx(mesh.get_blend_shape_value(shape)), "seeking before the cue clears the mouth")
		world.sync_state(during, true)
		check(is_equal_approx(spoken, mesh.get_blend_shape_value(shape)), "same replay frame restores exactly the same mouth weight")
		var legacy := during.duplicate(true)
		for entry in legacy.events:
			if entry.seq == event.seq:
				entry.details.clear()
		world.sync_state(legacy, true)
		check(is_zero_approx(mesh.get_blend_shape_value(shape)), "legacy event with no recoverable text stays neutral")
		legacy.agents.person_00.last_action = {"type":"speak", "text":"Мааа"}
		world.sync_state(legacy, true)
		check(is_equal_approx(spoken, mesh.get_blend_shape_value(shape)), "legacy seek picks up recoverable text on the same cue")
	else:
		check(false, "world can bind the articulated head")
	world.queue_free()
	await process_frame
	quit(1 if _failed else 0)

func check(passed: bool, label: String) -> void:
	print("PASS " if passed else "FAIL ", label)
	if not passed:
		_failed += 1
