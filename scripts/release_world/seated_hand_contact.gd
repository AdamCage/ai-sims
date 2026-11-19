extends SkeletonModifier3D
## Runs after SeatFootContact so the wrists can follow the final thigh pose.

const MODIFIER_NAME := "SeatHandContact"
const FINGERS := ["index", "middle", "ring", "pinky", "thumb"]
const REST_CURL := [.15, .17, .08]
const REST_THUMB := [.10, .11, .06]
const GRIP_CURL := [.03, .63, .44]
const GRIP_PINKY := [.02, .35, .52]
const GRIP_THUMB := [.10, .27, .20]

var _chains: Array[Dictionary] = []
var _settle := 0.0
var _guide_weight := 1.0
var _transfer_lift := 0.0
var _lap_clearance := 0.0
var _holding_phone := false
var _outfit := 0
var device_clearance := 0.0

static func update(leg_solver: TwoBoneIK3D, clip: String, progress: float, held_phone: bool, outfit: int) -> void:
	if not is_instance_valid(leg_solver):
		return
	var skeleton := leg_solver.get_parent() as Skeleton3D
	if not is_instance_valid(skeleton):
		return
	var contact := skeleton.get_node_or_null(MODIFIER_NAME) as SkeletonModifier3D
	if contact == null:
		contact = load("res://scripts/release_world/seated_hand_contact.gd").new()
		contact.name = MODIFIER_NAME
		skeleton.add_child(contact)
	contact._holding_phone = held_phone
	contact._outfit = posmod(outfit, 4)
	var tilt := 0.0
	if clip.ends_with("Sitting_Enter"):
		contact._settle = smoothstep(.045, .32, progress)
		contact._guide_weight = smoothstep(0.0, .105, progress)
		contact._transfer_lift = 1.0 - smoothstep(.61, .99, progress)
		contact._lap_clearance = .046 * smoothstep(.09, .21, progress) * (1.0 - smoothstep(.42, .61, progress))
		tilt = smoothstep(.04, .15, progress) * (1.0 - smoothstep(.42, .64, progress))
	elif clip.ends_with("Sitting_Exit"):
		contact._settle = 1.0 - smoothstep(.10, .61, progress)
		# Keep the hand beside the rising thigh until the standing clip takes over.
		contact._guide_weight = 1.0
		contact._transfer_lift = smoothstep(.09, .39, progress)
		contact._lap_clearance = .036 * smoothstep(.44, .59, progress) * (1.0 - smoothstep(.79, .91, progress))
		tilt = smoothstep(.42, .62, progress) * (1.0 - smoothstep(.79, .91, progress))
	else:
		contact._settle = 1.0
		contact._guide_weight = 1.0
		contact._transfer_lift = 0.0
		contact._lap_clearance = 0.0
	var shape := skeleton.global_basis.y.length() / maxf(.01, skeleton.global_basis.x.length())
	var narrow := smoothstep(1.25, 1.65, shape)
	var broad := 1.0 - smoothstep(.62, .88, shape)
	contact.device_clearance = .016 * narrow * tilt + .0045 * broad
	contact.active = true

static func clear(leg_solver: TwoBoneIK3D) -> void:
	if not is_instance_valid(leg_solver):
		return
	var contact := leg_solver.get_parent().get_node_or_null(MODIFIER_NAME) as SkeletonModifier3D
	if is_instance_valid(contact):
		contact.active = false

static func phone_transform(marker: Marker3D) -> Transform3D:
	var raw := marker.get_parent() as Node3D
	if not is_instance_valid(raw):
		return marker.global_transform
	var skeleton := raw.get_parent() as Skeleton3D
	var relief := 0.0
	if is_instance_valid(skeleton):
		var correction := skeleton.get_node_or_null(MODIFIER_NAME) as SkeletonModifier3D
		if is_instance_valid(correction) and correction.active:
			relief = correction.device_clearance
	return grip_transform(raw.global_transform, relief)

static func grip_transform(hand: Transform3D, relief: float = 0.0) -> Transform3D:
	# The narrow edge runs towards the fingertips, which curl around that edge.
	# The device stays in front of the palm (-X on the right hand's rig).
	var grip := Basis(Vector3.UP, Vector3.LEFT, Vector3.BACK)
	grip *= Basis(Vector3.UP, -.4663) * Basis(Vector3.BACK, .4787) * Basis(Vector3.RIGHT, -.1200)
	var global_grip := hand * Transform3D(grip, Vector3(-.04475, .04991, .00847))
	var aligned := global_grip.basis.orthonormalized()
	return Transform3D(aligned, global_grip.origin + aligned.y * (relief - .0018))

func _process_modification_with_delta(_delta: float) -> void:
	var skeleton := get_skeleton()
	if not is_instance_valid(skeleton):
		return
	if _chains.is_empty():
		_bind(skeleton)
	for i in _chains.size():
		_place_hand(skeleton, _chains[i], i == 1 and _holding_phone)

func _bind(skeleton: Skeleton3D) -> void:
	for side in ["l", "r"]:
		var chain := {
			"upper": skeleton.find_bone("upperarm_" + side),
			"lower": skeleton.find_bone("lowerarm_" + side),
			"hand": skeleton.find_bone("hand_" + side),
			"thigh": skeleton.find_bone("thigh_" + side),
			"knee": skeleton.find_bone("calf_" + side),
			"side": 1.0 if side == "l" else -1.0,
			"digits": [],
			"relaxed": [],
		}
		for finger in FINGERS:
			var joints := PackedInt32Array()
			var rests: Array[Quaternion] = []
			for i in range(1, 4):
				var bone := skeleton.find_bone("%s_%02d_%s" % [finger, i, side])
				joints.append(bone)
				rests.append(skeleton.get_bone_rest(bone).basis.get_rotation_quaternion() if bone >= 0 else Quaternion.IDENTITY)
			chain.digits.append(joints)
			chain.relaxed.append(rests)
		var middle: int = chain.digits[1][0]
		chain["palm_length"] = skeleton.get_bone_rest(middle).origin.y if middle >= 0 else .10
		_chains.append(chain)

func _place_hand(skeleton: Skeleton3D, chain: Dictionary, phone: bool) -> void:
	if mini(mini(chain.upper, chain.lower), mini(chain.hand, mini(chain.thigh, chain.knee))) < 0:
		return
	var upper := skeleton.get_bone_global_pose(chain.upper)
	var lower := skeleton.get_bone_global_pose(chain.lower)
	var hand := skeleton.get_bone_global_pose(chain.hand)
	var hip := skeleton.get_bone_global_pose(chain.thigh).origin
	var knee := skeleton.get_bone_global_pose(chain.knee).origin
	var along := (knee - hip).normalized()
	var side: float = chain.side
	var forward := Vector3(along.x * .56, clampf(along.y * .62, -.25, .06), maxf(along.z, .18)).normalized()
	if phone:
		forward = (forward + Vector3.UP * .18).normalized()
	var palm_normal := Vector3.DOWN * side
	if phone:
		palm_normal = Vector3(-.66, -.75, 0.0)
	var resting := _hand_rotation(forward, palm_normal)
	var stage_direction := Vector3(.07 * side, -.96, .28).normalized()
	var guiding := _hand_rotation(stage_direction, Vector3.LEFT)
	var guide_weight := 1.0 if phone else _guide_weight
	guiding = hand.basis.get_rotation_quaternion().slerp(guiding, guide_weight)
	var wrist_rotation := guiding.slerp(resting, _settle)
	var fabric_ease := .004 if _outfit == 3 else .0
	# The same projection across a steep thigh intersects higher cloth near the
	# hip. Lift and spread the hands while the upper leg is still tilted.
	var leg_slope := absf(along.y)
	var support_lift := lerpf(.055, .145, _transfer_lift) * leg_slope
	var body_height := skeleton.global_basis.y.length()
	var long_arm_ease := .023 * smoothstep(1.05, 1.18, body_height) * smoothstep(.092, .115, chain.palm_length)
	var target := hip.lerp(knee, .44) + Vector3.UP * (.190 + fabric_ease + support_lift + long_arm_ease)
	# The wrist clears the front of the leaning torso before the digits reach
	# the thigh. The coat has a thicker front and needs slightly more reach.
	var lean := smoothstep(.12, .49, (upper.origin - hip).normalized().z)
	target.z += .042 + .070 * lean + (.016 if _outfit == 3 else 0.0)
	target.x += side * (.030 + .033 * leg_slope + .042 * lean)
	if phone:
		target += Vector3(.004, .056, .002)
	else:
		# Settle the free palm over the cloth after the loaded thigh is stable.
		target.y -= .020 * smoothstep(.91, 1.0, _settle) * (1.0 - _transfer_lift)
	# Keep both palms beside the hips while the knees first bend or straighten.
	# Transfer onto the moving thighs with a small lift over the cloth.
	var stage := hand.origin
	var edge := maxf(absf(hip.x) + .209, absf(knee.x) + .150)
	stage.x = side * maxf(absf(stage.x), edge)
	var transfer := sin(_settle * PI)
	var wrist := stage.lerp(target, _settle)
	var transfer_height := .040 + (1.0 - smoothstep(.79, .92, body_height)) * .063
	wrist += Vector3(.038 * side, transfer_height, .012) * transfer
	wrist.y += _lap_clearance

	var upper_size := upper.origin.distance_to(lower.origin)
	var lower_size := lower.origin.distance_to(hand.origin)
	if upper_size < .01 or lower_size < .01:
		return
	var line := wrist - upper.origin
	if line.length_squared() < .00001:
		return
	var direction := line.normalized()
	var distance := clampf(line.length(), absf(upper_size - lower_size) + .002, upper_size + lower_size - .002)
	wrist = upper.origin + direction * distance
	var pole := lower.origin - upper.origin + Vector3.RIGHT * side * (.045 if phone else .035)
	pole = (pole - direction * pole.dot(direction)).normalized()
	if pole.length_squared() < .01:
		pole = direction.cross(Vector3.FORWARD).normalized()
	var hinge_distance := (upper_size * upper_size - lower_size * lower_size + distance * distance) / (2.0 * distance)
	var elbow := upper.origin + direction * hinge_distance
	elbow += pole * sqrt(maxf(upper_size * upper_size - hinge_distance * hinge_distance, 0.0))

	var shoulder_rotation := Quaternion((lower.origin - upper.origin).normalized(), (elbow - upper.origin).normalized())
	var forearm_rotation := Quaternion((hand.origin - lower.origin).normalized(), (wrist - elbow).normalized())
	var upper_pose := Transform3D(Basis(shoulder_rotation) * upper.basis, upper.origin)
	var lower_pose := Transform3D(Basis(forearm_rotation) * lower.basis, elbow)
	var hand_pose := Transform3D(Basis(wrist_rotation).scaled_local(hand.basis.get_scale()), wrist)
	var shoulder_pose := skeleton.get_bone_global_pose(skeleton.get_bone_parent(chain.upper))
	skeleton.set_bone_pose(chain.upper, shoulder_pose.affine_inverse() * upper_pose)
	skeleton.set_bone_pose(chain.lower, upper_pose.affine_inverse() * lower_pose)
	skeleton.set_bone_pose(chain.hand, lower_pose.affine_inverse() * hand_pose)
	_pose_fingers(skeleton, chain.digits, chain.relaxed, phone, guide_weight)

func _hand_rotation(forward: Vector3, normal: Vector3) -> Quaternion:
	var x := (normal - forward * normal.dot(forward)).normalized()
	return Basis(x, forward, x.cross(forward)).orthonormalized().get_rotation_quaternion()

func _pose_fingers(skeleton: Skeleton3D, digits: Array, rests: Array, phone: bool, weight: float) -> void:
	for finger in digits.size():
		var angles := REST_CURL if finger != 4 else REST_THUMB
		if phone:
			angles = GRIP_CURL if finger != 4 else GRIP_THUMB
			if finger == 3:
				angles = GRIP_PINKY
		for joint in digits[finger].size():
			var index: int = digits[finger][joint]
			if index < 0:
				continue
			var relaxed: Quaternion = rests[finger][joint] * Quaternion(Vector3.RIGHT, angles[joint])
			var animated := skeleton.get_bone_pose_rotation(index)
			skeleton.set_bone_pose_rotation(index, animated.slerp(relaxed, weight))
	if phone:
		_support_phone(skeleton, digits)
	elif weight > 0.0:
		_tuck_thumb(skeleton, digits, weight)

func _support_phone(skeleton: Skeleton3D, digits: Array) -> void:
	var first_joint: int = digits[0][0]
	if first_joint < 0:
		return
	var hand := skeleton.get_bone_global_pose(skeleton.get_bone_parent(first_joint))
	var device := grip_transform(skeleton.global_transform * hand, device_clearance)
	var to_device := device.affine_inverse() * skeleton.global_transform
	var from_device := to_device.affine_inverse()
	for finger in range(4):
		var joints: PackedInt32Array = digits[finger]
		var tip := joints[2]
		if tip < 0:
			continue
		var tip_offset := Vector3.UP * (.014 if finger == 3 else .017)
		var point := to_device * (skeleton.get_bone_global_pose(tip) * tip_offset)
		# Flex the pads towards the back of the handset. Keep the joints on
		# their hinges and outside the screen and frame.
		var target := from_device * Vector3(clampf(point.x, -.033, .033), -.014, clampf(point.z, -.071, .071))
		for _pass in range(2):
			for joint in range(2, -1, -1):
				if joints[joint] >= 0:
					_flex_to_contact(skeleton, joints[joint], tip, tip_offset, target, .22 if joint == 0 else .32)

func _flex_to_contact(skeleton: Skeleton3D, joint: int, tip: int, offset: Vector3, target: Vector3, limit: float) -> void:
	var pose := skeleton.get_bone_global_pose(joint)
	var axis := pose.basis.x.normalized()
	var current := skeleton.get_bone_global_pose(tip) * offset - pose.origin
	var desired := target - pose.origin
	var from := current - axis * axis.dot(current)
	var to := desired - axis * axis.dot(desired)
	if from.length_squared() < .000001 or to.length_squared() < .000001:
		return
	var angle := atan2(axis.dot(from.cross(to)), from.dot(to))
	pose.basis = Basis(Quaternion(axis, clampf(angle, -limit, limit))) * pose.basis
	var parent := skeleton.get_bone_global_pose(skeleton.get_bone_parent(joint))
	skeleton.set_bone_pose(joint, parent.affine_inverse() * pose)

func _tuck_thumb(skeleton: Skeleton3D, digits: Array, weight: float) -> void:
	var thumb: int = digits[4][0]
	var joint: int = digits[4][1]
	var middle: int = digits[1][0]
	if mini(thumb, mini(joint, middle)) < 0:
		return
	var pose := skeleton.get_bone_global_pose(thumb)
	var direction := skeleton.get_bone_global_pose(joint).origin - pose.origin
	var towards_palm := skeleton.get_bone_global_pose(middle).origin - pose.origin
	if direction.length_squared() < .000001 or towards_palm.length_squared() < .000001:
		return
	var correction := Quaternion(direction.normalized(), towards_palm.normalized())
	pose.basis = Basis(Quaternion.IDENTITY.slerp(correction, .28 * weight)) * pose.basis
	var parent := skeleton.get_bone_global_pose(skeleton.get_bone_parent(thumb))
	skeleton.set_bone_pose(thumb, parent.affine_inverse() * pose)
