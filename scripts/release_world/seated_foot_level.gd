extends SkeletonModifier3D
## Level the soles after their ankle positions have been resolved by the leg IK.

var _feet := PackedInt32Array()
var _toes := PackedInt32Array()
var _ankle_offsets: Array[Vector2] = []

func bind_model(model: Node3D) -> void:
	var skeleton := get_skeleton()
	for suffix in ["l", "r"]:
		_feet.append(skeleton.find_bone("foot_" + suffix))
		_toes.append(skeleton.find_bone("ball_" + suffix))
	for variant in range(2):
		var rest_floor := Vector2(INF, INF)
		var shoe := model.find_child("Clothing_Shoes_%d" % variant, true, false) as MeshInstance3D
		if shoe != null and shoe.mesh != null:
			var to_skeleton := skeleton.global_transform.affine_inverse() * shoe.global_transform
			for surface in shoe.mesh.get_surface_count():
				var vertices: PackedVector3Array = shoe.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
				for vertex in vertices:
					var point := to_skeleton * vertex
					var side := 0 if point.x > 0.0 else 1
					rest_floor[side] = minf(rest_floor[side], point.y)
		var offsets := Vector2(.10, .10)
		for side in range(2):
			if _feet[side] >= 0 and is_finite(rest_floor[side]):
				offsets[side] = skeleton.get_bone_global_rest(_feet[side]).origin.y - rest_floor[side]
		_ankle_offsets.append(offsets)

func floor_offset(side: int, shoes: int) -> float:
	return _ankle_offsets[posmod(shoes, 2)][side] * get_skeleton().global_basis.y.length()

func _process_modification_with_delta(_delta: float) -> void:
	var skeleton := get_skeleton()
	for side in _feet.size():
		var foot := _feet[side]
		if foot < 0:
			continue
		var pose := skeleton.get_bone_global_pose(foot)
		pose.basis = skeleton.get_bone_global_rest(foot).basis
		var calf := skeleton.get_bone_global_pose(skeleton.get_bone_parent(foot))
		skeleton.set_bone_pose(foot, calf.affine_inverse() * pose)
		if _toes[side] >= 0:
			var toe_rest := skeleton.get_bone_rest(_toes[side]).basis
			skeleton.set_bone_pose_rotation(_toes[side], toe_rest.get_rotation_quaternion())
