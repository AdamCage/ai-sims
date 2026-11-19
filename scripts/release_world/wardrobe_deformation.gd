extends RefCounted
## Corrective shape weights follow the rendered clip, including paused seeks.

const META := &"wardrobe_shape_bindings"
const SHAPES := [&"ShoulderEase", &"SeatedSlack", &"CuffFlex"]

static func apply(model: Node3D, clip: String, phase: float) -> void:
	if not is_instance_valid(model):
		return
	if not model.has_meta(META):
		var bindings: Array[Dictionary] = []
		for node in model.find_children("Clothing_*", "MeshInstance3D", true, false):
			var mesh := node as MeshInstance3D
			var indices := PackedInt32Array()
			var has_shapes := false
			for shape in SHAPES:
				var index := mesh.find_blend_shape_by_name(shape)
				indices.append(index)
				has_shapes = has_shapes or index >= 0
			if has_shapes:
				bindings.append({"mesh": mesh, "indices": indices, "coat": mesh.name == &"Clothing_Shirt_3"})
		model.set_meta(META, bindings)
	var cached: Array = model.get_meta(META)
	if cached.is_empty():
		return
	var name := clip.get_file()
	var seated := 0.0
	if name == "Sitting_Enter":
		seated = smoothstep(.15, .74, phase)
	elif name == "Sitting_Exit":
		seated = 1.0 - smoothstep(.20, .85, phase)
	elif name.begins_with("Sitting_Idle"):
		seated = 1.0
	elif name.begins_with("Crouch") or name.begins_with("Fixing"):
		seated = .60
	var walk := name.begins_with("Walk") or name.begins_with("Jog")
	var shoulder := (.44 + absf(sin(phase * TAU)) * .24) if walk else .32
	var cuff := (.27 + absf(sin(phase * TAU)) * .35) if walk else .18
	var weights := [maxf(shoulder, seated * .83), seated, maxf(cuff, seated * .72)]
	var coat_gather := seated
	if name == "Sitting_Enter":
		coat_gather = smoothstep(.10, .55, phase)
	elif name == "Sitting_Exit":
		coat_gather = 1.0 - smoothstep(.43, .91, phase)
	for binding: Dictionary in cached:
		var mesh: MeshInstance3D = binding.mesh
		if not mesh.visible:
			continue
		for i in SHAPES.size():
			var index: int = binding.indices[i]
			var weight: float = coat_gather if i == 1 and binding.coat else weights[i]
			if index >= 0 and not is_equal_approx(mesh.get_blend_shape_value(index), weight):
				mesh.set_blend_shape_value(index, weight)
