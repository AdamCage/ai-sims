extends SkeletonModifier3D
## Small shared-rig face-shape presets, applied after the motion animation.
var variant: int = 0
var _head := -1
func _process_modification() -> void:
	var skeleton:=get_skeleton()
	if skeleton==null:return
	if _head<0:
		for index in skeleton.get_bone_count():
			if skeleton.get_bone_name(index).to_lower() in ["head","mixamorig_head"]:_head=index;break
	if _head<0:return
	var shapes: Array[Vector3]=[Vector3(1.025,1.025,1.02),Vector3(1.09,0.98,1.04),Vector3(0.965,1.06,1.015)]
	skeleton.set_bone_pose_scale(_head,shapes[posmod(variant,3)])
