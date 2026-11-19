extends SkeletonModifier3D
## Pose from the displayed clock and dialogue, independent of save and replay state.

const SECONDS_PER_MINUTE := 2.0
const SPEECH_WINDOW := 1.55
const ARTICULATION_BEAT := 0.108
const VIS_EMPHASIS := 0.74
const SPEECH_SHAPES := [&"Jaw_Open", &"Viseme_A", &"Viseme_E", &"Viseme_I", &"Viseme_O", &"Viseme_U", &"Viseme_MBP", &"Viseme_FV", &"Viseme_SZ"]

var _bindings: Dictionary = {}
var _weights: Dictionary = {}
var _head := -1
var _eyes: PackedInt32Array
var _eye_yaw := 0.0
var _eye_pitch := 0.0
var _variant := -1
var _phase := 0.0
var _cue := -1
var _line := ""
var _tokens: Array[StringName] = []
var _speech_start := 0.0
var _listening := false
var _strain := 0.0
var _look_yaw := 0.0
var _look_pitch := 0.0
var _next_update := -INF
var _last_clock := -INF

func bind_model(model: Node3D, seed_value: String) -> bool:
	var skeletons := model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		return false
	var skeleton := skeletons[0] as Skeleton3D
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.mesh == null:
			continue
		for index in mesh.get_blend_shape_count():
			var name: StringName = mesh.mesh.get_blend_shape_name(index)
			if not _bindings.has(name):
				_bindings[name] = []
			_bindings[name].append([mesh, index])
	for index in skeleton.get_bone_count():
		match str(skeleton.get_bone_name(index)).to_lower():
			"head", "mixamorig_head": _head = index
			"eye_l", "eye_r": _eyes.append(index)
	_phase = float(posmod(seed_value.hash(), 1777)) * 0.0031
	skeleton.add_child(self)
	return true

func set_face_variant(variant: int) -> void:
	_variant = posmod(variant, 3)
	_set_weight(&"Identity_1", 1.0 if _variant == 1 else 0.0)
	_set_weight(&"Identity_2", 1.0 if _variant == 2 else 0.0)

func set_context(cue: int, line: String, started: float, listening: bool, look: Vector2, strain: float) -> void:
	if cue != _cue or line != _line:
		_cue = cue
		_line = line
		_tokens.clear()
		if cue >= 0:
			_tokens = articulation(line)
	_speech_start = started * SECONDS_PER_MINUTE
	_listening = listening
	_look_yaw = clampf(look.x, -0.32, 0.32)
	_look_pitch = clampf(look.y, -0.20, 0.20)
	_strain = clampf(strain, 0.0, 0.40)

func copy_context(source: SkeletonModifier3D) -> void:
	if source == null:
		set_context(-1, "", 0.0, false, Vector2.ZERO, 0.0)
		return
	set_context(source._cue, source._line, source._speech_start / SECONDS_PER_MINUTE, source._listening,
		Vector2(source._look_yaw, source._look_pitch), source._strain)

func present(clock: float, awake: bool, immediate: bool = false) -> void:
	if _bindings.is_empty():
		return
	if not immediate and clock >= _last_clock and clock < _next_update:
		return
	_last_clock = clock
	_next_update = clock + 0.025
	var cycle := 3.4 + fposmod(_phase, 1.5)
	var time := fposmod(clock + _phase, cycle)
	var blink := smoothstep(0.02, 0.067, time) * (1.0 - smoothstep(0.083, 0.172, time)) if awake else 1.0
	var talk := clock - _speech_start
	var speaking := awake and _cue >= 0 and talk >= 0.0 and talk < _tokens.size() * ARTICULATION_BEAT
	# Short gaze shifts alternate with a held fixation. Both use the displayed
	# clock, so changing the playback speed or seeking does not change the pose.
	var fixation := (clock + _phase) * 0.83
	var glance := lerpf(sin(floorf(fixation) * 2.4), sin((floorf(fixation) + 1.0) * 2.4),
		smoothstep(0.0, 0.075, fposmod(fixation, 1.0)))
	_eye_yaw = (_look_yaw + glance * (0.022 if _listening or speaking else 0.067)) if awake else 0.0
	_eye_pitch = (_look_pitch + glance * 0.015) if awake else 0.0
	_set_weight(&"Blink_L", blink)
	_set_weight(&"Blink_R", blink)
	var open_lids := 1.0 - blink
	_set_weight(&"Lids_Up", clampf(-_eye_pitch * 2.7, 0.0, 0.56) * open_lids)
	_set_weight(&"Lids_Down", clampf(_eye_pitch * 2.7, 0.0, 0.56) * open_lids)
	var emphasis := smoothstep(0.0, 0.15, talk) * (1.0 - smoothstep(0.25, 0.64, talk)) if speaking else 0.0
	var attentive := 0.11 if _listening and awake else 0.0
	_set_weight(&"Brow_Up", maxf(attentive, emphasis * 0.31))
	_set_weight(&"Brow_Down", _strain * 0.72 if awake else 0.0)
	_set_weight(&"Concern", _strain * (0.52 if speaking else 0.82) if awake else 0.0)
	_set_weight(&"Tension", _strain * 0.48 if awake and not speaking else 0.0)
	_set_weight(&"Smile", 0.12 if awake and _listening and not speaking and _strain < 0.12 else 0.0)
	_present_mouth(talk if speaking else -1.0)

func _present_mouth(time: float) -> void:
	var first: StringName
	var second: StringName
	var amount := 0.0
	var strength := 0.0
	if time >= 0.0:
		var step := time / ARTICULATION_BEAT
		var index := floori(step)
		first = _tokens[index]
		if index + 1 < _tokens.size():
			second = _tokens[index + 1]
		amount = smoothstep(0.56 if first == &"Viseme_MBP" else 0.36, 1.0, step - index)
		strength = VIS_EMPHASIS * smoothstep(0.0, 0.06, time)
	for key in SPEECH_SHAPES:
		var weight := (1.0 - amount if key == first else 0.0) + (amount if key == second else 0.0)
		_set_weight(key, weight * strength * (0.34 if key == &"Jaw_Open" else 1.0))

func _set_weight(key: StringName, value: float) -> void:
	if not _bindings.has(key) or is_equal_approx(float(_weights.get(key, -1.0)), value):
		return
	_weights[key] = value
	for binding: Array in _bindings[key]:
		var mesh: MeshInstance3D = binding[0]
		mesh.set_blend_shape_value(int(binding[1]), value)

func _process_modification() -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	# Legacy models still display all three identity variants while a new model loads.
	if _head >= 0 and _variant >= 0 and not _bindings.has(&"Identity_1"):
		var shapes: Array[Vector3] = [Vector3(1.025, 1.025, 1.02), Vector3(1.09, 0.98, 1.04), Vector3(0.965, 1.06, 1.015)]
		skeleton.set_bone_pose_scale(_head, shapes[_variant])
	if is_zero_approx(_eye_yaw) and is_zero_approx(_eye_pitch):
		return
	for index in _eyes:
		var parent := skeleton.get_bone_parent(index)
		var basis := skeleton.get_bone_global_pose(parent).basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
		var pan := Quaternion(basis.inverse() * Vector3.UP, _eye_yaw)
		var tilt := Quaternion(basis.inverse() * Vector3.RIGHT, _eye_pitch)
		skeleton.set_bone_pose_rotation(index, pan * tilt * skeleton.get_bone_pose_rotation(index))

static func articulation(text: String) -> Array[StringName]:
	var result: Array[StringName] = []
	var line := text.to_lower()
	var index := 0
	while index < line.length() and result.size() < 28:
		var pair := line.substr(index, 2)
		if pair in ["sh", "ch", "zh", "ts"]:
			result.append(&"Viseme_SZ")
			index += 2
			continue
		var glyph := line.substr(index, 1)
		var key := &"Jaw_Open"
		if "aая".contains(glyph): key = &"Viseme_A"
		elif "eеэ".contains(glyph): key = &"Viseme_E"
		elif "iyиый".contains(glyph): key = &"Viseme_I"
		elif "oоё".contains(glyph): key = &"Viseme_O"
		elif "uwую".contains(glyph): key = &"Viseme_U"
		elif "mbpмбп".contains(glyph): key = &"Viseme_MBP"
		elif "fvфв".contains(glyph): key = &"Viseme_FV"
		elif "szсзшщжчц".contains(glyph): key = &"Viseme_SZ"
		elif " .,!?…:;—-\n\r\tьъ".contains(glyph): key = &""
		if not result.is_empty() or not key.is_empty():
			result.append(key)
		index += 1
	return result
