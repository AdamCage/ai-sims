extends RefCounted
## The portrait and world share the same material and appearance choices.

static func apply(meshes: Array, appearance: Dictionary, color: Color, shirt: ShaderMaterial) -> void:
	var outfit := posmod(int(appearance.get("outfit", 0)), 4)
	var shoes := posmod(int(appearance.get("shoes", 0)), 2)
	var hair := posmod(int(appearance.get("hair", 0)), 6)
	var hair_color := Color.from_string(str(appearance.get("hair_color", "4e3b32")), Color("4e3b32"))
	var skin := Color.from_string(str(appearance.get("skin", "dfb89e")), Color("dfb89e"))
	var trouser_color: Color = [Color("3d4c5b"), Color("ad9d7b"), Color("273439"), color.darkened(0.4)][outfit]
	var smooth_hair_edges := RenderingServer.get_current_rendering_method() == "forward_plus"
	for node in meshes:
		var mesh := node as MeshInstance3D
		if mesh == null or mesh.mesh == null:
			continue
		var name := str(mesh.name).to_lower()
		if name.begins_with("hair_"):
			mesh.visible = _variant(name, "hair_") == hair
		elif name.begins_with("clothing_shirt_"):
			mesh.visible = _variant(name, "clothing_shirt_") == outfit
		elif name.begins_with("clothing_shoes_"):
			mesh.visible = _variant(name, "clothing_shoes_") == shoes
		if not mesh.visible:
			continue
		for surface in mesh.mesh.get_surface_count():
			var source := mesh.mesh.surface_get_material(surface) as StandardMaterial3D
			if source == null:
				continue
			var kind := source.resource_name.to_lower()
			if kind.contains("shirt"):
				mesh.set_surface_override_material(surface, shirt)
				continue
			var material := source.duplicate() as StandardMaterial3D
			if name.begins_with("hair_") or name == "residentbrows":
				material.albedo_color = _tint(hair_color, Color("84644d"))
				if name.begins_with("hair_") and kind != "residentfringe":
					material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
					material.alpha_scissor_threshold = 0.27
					if smooth_hair_edges:
						material.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
						material.alpha_antialiasing_edge = 0.20
				else:
					material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				material.cull_mode = BaseMaterial3D.CULL_DISABLED
			elif kind.contains("trouser"):
				material.albedo_color = trouser_color
			elif kind.contains("shoe"):
				material.albedo_color = Color("64554a") if shoes == 1 else Color("303940")
			elif kind == "residentskin":
				material.albedo_color = _tint(skin, Color("e4b697"))
				material.metallic_specular = 0.29
				if smooth_hair_edges:
					material.subsurf_scatter_enabled = true
					material.subsurf_scatter_strength = 0.16
					material.subsurf_scatter_skin_mode = true
			elif kind == "residenteyes":
				material.metallic_specular = 0.43
				material.roughness = 0.245
				material.clearcoat_roughness = 0.19
			elif kind == "residentlashes":
				material.albedo_color.a = 0.76
				material.metallic_specular = 0.18
				mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			elif kind.contains("skin") or kind.contains("superhero") or kind.contains("basecharacter"):
				material.albedo_color = _tint(skin, Color("bd8e68")) if name == "hands" else _tint(skin, Color("f5bd94"))
			else:
				continue
			mesh.set_surface_override_material(surface, material)
		if name == "residentbrows":
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

static func _variant(name: String, prefix: String) -> int:
	return int(name.trim_prefix(prefix).get_slice(".", 0).get_slice("_", 0))

static func _tint(color: Color, reference: Color) -> Color:
	return Color(color.r / reference.r, color.g / reference.g, color.b / reference.b)
