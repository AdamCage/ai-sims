extends RefCounted
## Site palettes and non-interactive architectural details for the three maps.

const Cloth := preload("res://scripts/release_world/clothing.gdshader")
const FabricColor := preload("res://assets/release/textures/fabric_color.png")
const FabricNormal := preload("res://assets/release/textures/fabric_normal.png")

const PALETTES := {
	"teal": {
		"ground": Color("aaa99c"), "wall": Color("bbbeb0"), "trim": Color("527472"),
		"background": Color("242d2e"), "ambient": Color("d9e2df"),
		"key": Color("f4eee1"), "fill": Color("a5c5c4"),
		"ambient_energy": 0.37, "key_energy": 0.48, "fill_energy": 0.17,
		"sun_rotation": Vector3(-49, -30, 0),
		"ground_surface": "concrete_slab", "wall_surface": "wall",
		"room_floor_tints": {
			"bedroom": Color("c6b899"), "common": Color("c6b89d"), "kitchen": Color("c3ccc2"),
			"medical": Color("cbdbd5"), "arrival": Color("aeb1a7"), "supply": Color("bab9a6"),
		},
	},
	"warm": {
		"ground": Color("b0a693"), "wall": Color("cbb8a3"), "trim": Color("925f4c"),
		"background": Color("302a29"), "ambient": Color("e4dfd6"),
		"key": Color("ffead4"), "fill": Color("bdcfdb"),
		"ambient_energy": 0.35, "key_energy": 0.51, "fill_energy": 0.15,
		"sun_rotation": Vector3(-47, -57, 0),
		"ground_surface": "courtyard_pavers", "wall_surface": "painted_brick",
		"room_floor_tints": {
			"bedroom": Color("c7b49e"), "common": Color("c6b39a"), "shop": Color("b5ac99"),
			"kitchen": Color("dbd1bb"), "medical": Color("d1d8cb"), "lab": Color("d2d0bd"),
		},
	},
	"blue": {
		"ground": Color("a6afb0"), "wall": Color("b4c2c9"), "trim": Color("547889"),
		"background": Color("202a33"), "ambient": Color("d4e0ef"),
		"key": Color("e8eff9"), "fill": Color("f8dfc4"),
		"ambient_energy": 0.39, "key_energy": 0.49, "fill_energy": 0.14,
		"sun_rotation": Vector3(-44, -26, 0),
		"ground_surface": "compacted_gravel", "wall_surface": "enamel_panel",
		"room_floor_tints": {
			"bedroom": Color("c1c8bf"), "common": Color("c9ccc0"), "lab": Color("c1d3d8"),
			"medical": Color("d1dcd8"), "comms": Color("a5b6bf"), "arrival": Color("9dadb5"),
			"evacuation": Color("a8b6bb"), "supply": Color("b3bec2"), "workshop": Color("a9b8c0"),
		},
	},
}


static func palette(palette_id: String) -> Dictionary:
	return PALETTES.get(palette_id, PALETTES.teal)


static func room_surface(palette_id: String, room_function: String) -> String:
	if room_function in ["medical", "kitchen", "lab"]:
		return "tile"
	if palette_id == "blue":
		return "metal" if room_function in ["workshop", "arrival", "evacuation", "comms", "supply"] else "floor"
	if palette_id == "warm" and room_function == "shop":
		return "courtyard_pavers"
	if room_function in ["bedroom", "common"]:
		return "wood"
	if room_function == "workshop":
		return "metal"
	if room_function in ["arrival", "reserve", "supply"]:
		return "concrete_slab"
	return "floor"


static func character_tint(color: Color) -> Color:
	return color.lerp(Color("a9a598"), .12)


static func clothing_material(tint: Color, outfit: int) -> ShaderMaterial:
	var cloth := ShaderMaterial.new()
	cloth.shader = Cloth
	cloth.set_shader_parameter("cloth_color", character_tint(tint))
	cloth.set_shader_parameter("accent_color", Color("e2dfd1"))
	cloth.set_shader_parameter("outfit", posmod(outfit, 4))
	cloth.set_shader_parameter("fabric_map", FabricColor)
	cloth.set_shader_parameter("normal_map", FabricNormal)
	return cloth


static func decorate_site(content: Node3D, geometry: Dictionary, layer: int) -> void:
	var palette_id := str(geometry.get("palette", "teal"))
	var bounds: Array = geometry.get("bounds", [])
	if bounds.size() != 4:
		return
	var center := Vector2((float(bounds[0]) + float(bounds[1])) / 2.0,
		(float(bounds[2]) + float(bounds[3])) / 2.0)
	var size := Vector2(float(bounds[1]) - float(bounds[0]), float(bounds[3]) - float(bounds[2]))
	var batches: Dictionary = {}
	var styles: Dictionary = {}
	var doors: Array = geometry.get("doors", [])
	var rooms: Array = geometry.get("rooms", [])
	match palette_id:
		"warm":
			styles = _residence(batches, center, size, doors, rooms)
		"blue":
			styles = _station(batches, center, size, doors, rooms)
		_:
			styles = _closed_block(batches, center, size, doors, rooms)
	var site := Node3D.new()
	site.name = "SiteArchitecture"
	content.add_child(site)
	for role: String in batches:
		_add_batch(site, role, batches[role], styles[role], layer)


static func _closed_block(batches: Dictionary, center: Vector2, size: Vector2, doors: Array, rooms: Array) -> Dictionary:
	# Slabs under each long row and the faded path into the supply wing.
	for offset: float in [-0.19, 0.19]:
		var lane := center + Vector2(0.0, size.y * offset)
		_box(batches, "walk", Vector3(lane.x, .027, lane.y), Vector3(size.x * .95, .012, 1.35))
		for step in range(-3, 4):
			_box(batches, "route", Vector3(center.x + step * .29, .038, lane.y),
				Vector3(.15, .008, 1.35))
	for end: float in [-1.0, 1.0]:
		var x := center.x + end * (size.x * .5 - .11)
		for segment in range(1, 10):
			var z := center.y + (float(segment) / 10.0 - .5) * size.y
			_box(batches, "frame", Vector3(x, 1.52, z), Vector3(.20, 3.04, .34))
	for door: Dictionary in doors:
		_lamp(batches, door, 2.86, .96)
		if str(door.get("id", "")).begins_with("supply_"):
			_service_header(batches, door)
	for room: Dictionary in rooms:
		if room.get("function", "") == "supply":
			_ration_lane(batches, room)
	return {
		"walk": [Color("969b91")], "route": [Color("d6bb72")],
		"frame": [Color("4a5a53")], "light": [Color("e9c991"), .32],
		"lane": [Color("89948a")], "paint": [Color("bfb37b")], "header": [Color("426962")],
	}


static func _residence(batches: Dictionary, center: Vector2, size: Vector2, doors: Array, rooms: Array) -> Dictionary:
	# Brick promenades follow the gaps between the three rows of houses.
	for offset: float in [-0.167, 0.167]:
		var x := center.x + size.x * offset
		_box(batches, "walk", Vector3(x, .027, center.y), Vector3(3.1, .012, size.y * .95))
		for side: float in [-1.0, 1.0]:
			_box(batches, "edge", Vector3(x + side * 1.49, .034, center.y),
				Vector3(.12, .018, size.y * .95))
	for door: Dictionary in doors:
		var id := str(door.get("id", ""))
		if not (id.ends_with("_west") or id.ends_with("_east")):
			continue
		var center_xz := _point(door)
		var side := -1.0 if id.ends_with("_west") else 1.0
		if id.begins_with("bedroom_") or id.begins_with("common_"):
			_window_planter(batches, center_xz, side)
		if not (id.begins_with("shop_") or id.begins_with("dining_") or id.begins_with("common_")):
			continue
		var x := center_xz.x + side * .48
		for stripe in 7:
			var role := "canopy" if stripe % 2 == 0 else "canopy_stripe"
			var z := center_xz.y + (float(stripe) - 3.0) * .4
			_box(batches, role, Vector3(x, 2.75, z), Vector3(1.0, .067, .397))
			_box(batches, role, Vector3(x + side * .48, 2.68, z), Vector3(.044, .11, .397))
		for edge: float in [-1.0, 1.0]:
			_box(batches, "frame", Vector3(x, 2.68, center_xz.y + edge * 1.29), Vector3(.95, .042, .052))
	for room: Dictionary in rooms:
		if room.get("function", "") == "shop":
			_market_floor(batches, room)
	return {
		"walk": [Color("aa9a83")], "edge": [Color("d3c6ac")], "frame": [Color("444842")],
		"canopy": [Color("8d4e3d")], "canopy_stripe": [Color("d4bb8e")],
		"window_box": [Color("846958")], "foliage": [Color("547345")],
		"floor_inlay": [Color("9c5f49")],
	}


static func _station(batches: Dictionary, center: Vector2, size: Vector2, doors: Array, rooms: Array) -> Dictionary:
	# Hardstand and amber guidance connect the three separate modules.
	_box(batches, "walk", Vector3(center.x, .027, center.y), Vector3(size.x * .93, .012, 4.5))
	for side: float in [-1.0, 1.0]:
		_box(batches, "edge", Vector3(center.x, .038, center.y + side * 2.16),
			Vector3(size.x * .925, .009, .075))
		for marker in range(-7, 8):
			var x := center.x + float(marker) * size.x / 17.0
			_box(batches, "paint", Vector3(x, .041, center.y + side * 1.87),
				Vector3(size.x / 30.0, .007, .12))
	for room: Dictionary in rooms:
		var at := _point(room)
		var dimensions: Array = room.get("size", [0.0, 0.0])
		for x_sign: float in [-1.0, 1.0]:
			for z_sign: float in [-1.0, 1.0]:
				var x := at.x + x_sign * (float(dimensions[0]) * .5 - .08)
				var z := at.y + z_sign * (float(dimensions[1]) * .5 - .08)
				_box(batches, "frame", Vector3(x, 1.48, z), Vector3(.34, 2.96, .34))
				_box(batches, "brace", Vector3(x, .24, z), Vector3(.46, .48, .46))
		if room.get("function", "") in ["lab", "workshop", "comms"]:
			_instrument_bay(batches, room)
	for door: Dictionary in doors:
		_lamp(batches, door, 2.88, 1.12)
	return {
		"walk": [Color("727f86")], "edge": [Color("384752")],
		"frame": [Color("536875")], "brace": [Color("718a94")],
		"paint": [Color("ba9856")], "light": [Color("cce7eb"), .36],
		"bay_floor": [Color("778b92")], "duct": [Color("8d9fa7")],
	}


static func _service_header(batches: Dictionary, door: Dictionary) -> void:
	var at := _point(door)
	var dimensions: Array = door.get("size", [2.4, .2])
	var along_x := float(dimensions[0]) > float(dimensions[1])
	var span := Vector3(3.13, .26, .43) if along_x else Vector3(.43, .26, 3.13)
	_box(batches, "header", Vector3(at.x, 3.02, at.y), span)
	for side: float in [-1.0, 1.0]:
		var offset := Vector2(side * 1.44, 0.0) if along_x else Vector2(0.0, side * 1.44)
		var post := at + offset
		_box(batches, "header", Vector3(post.x, 1.51, post.y), Vector3(.19, 3.02, .27))


static func _ration_lane(batches: Dictionary, room: Dictionary) -> void:
	var at := _point(room)
	var dimensions: Array = room.get("size", [10.0, 8.0])
	var length := float(dimensions[1]) * .54
	var x := at.x + float(dimensions[0]) * .26
	_box(batches, "lane", Vector3(x, .049, at.y), Vector3(1.52, .009, length))
	for side: float in [-1.0, 1.0]:
		_box(batches, "paint", Vector3(x + side * .68, .055, at.y), Vector3(.048, .008, length))
	for position: float in [-.35, -.12, .12, .35]:
		var z := at.y + position * length
		_box(batches, "paint", Vector3(x, .055, z), Vector3(.88, .008, .092))


static func _window_planter(batches: Dictionary, at: Vector2, side: float) -> void:
	var x := at.x + side * .21
	var z := at.y + 2.45
	_box(batches, "window_box", Vector3(x, .91, z), Vector3(.34, .245, 1.28))
	for leaf in 7:
		var at_z := z + (float(leaf) - 3.0) * .15
		var height := .18 + float(posmod(leaf * 5, 4)) * .045
		_box(batches, "foliage", Vector3(x, 1.03 + height * .28, at_z), Vector3(.23, height, .24))


static func _market_floor(batches: Dictionary, room: Dictionary) -> void:
	var at := _point(room)
	var dimensions: Array = room.get("size", [14.0, 9.0])
	var width := float(dimensions[0]) * .78
	var z := at.y + float(dimensions[1]) * .35
	for stripe: float in [0.0, .19]:
		_box(batches, "floor_inlay", Vector3(at.x, .05, z + stripe), Vector3(width, .01, .093))
	for index in range(-4, 5):
		var x := at.x + float(index) * width / 10.0
		_box(batches, "floor_inlay", Vector3(x, .05, z + .095), Vector3(.066, .01, .14))


static func _instrument_bay(batches: Dictionary, room: Dictionary) -> void:
	var at := _point(room)
	var dimensions: Array = room.get("size", [10.0, 8.0])
	var width := float(dimensions[0]) * .56
	var depth := float(dimensions[1]) * .28
	var z := at.y - float(dimensions[1]) * .29
	_box(batches, "bay_floor", Vector3(at.x, .05, z), Vector3(width, .009, depth))
	_box(batches, "duct", Vector3(at.x, 2.61, z - depth * .29), Vector3(width, .25, .32))
	_box(batches, "light", Vector3(at.x, 2.476, z - depth * .29), Vector3(width * .77, .035, .15))
	for index in range(-6, 7):
		var x := at.x + float(index) * width / 13.5
		_box(batches, "paint", Vector3(x, .056, z + depth * .49), Vector3(.17, .008, .145))


static func _lamp(batches: Dictionary, door: Dictionary, height: float, width: float) -> void:
	var at := _point(door)
	var dimensions: Array = door.get("size", [0.2, 1.8])
	var long_x := float(dimensions[0]) > float(dimensions[1])
	var frame_size := Vector3(width, .15, .31) if long_x else Vector3(.31, .15, width)
	var strip_size := Vector3(width * .8, .048, .325) if long_x else Vector3(.325, .048, width * .8)
	_box(batches, "frame", Vector3(at.x, height, at.y), frame_size)
	_box(batches, "light", Vector3(at.x, height - .026, at.y), strip_size)


static func _point(entry: Dictionary) -> Vector2:
	var center: Array = entry.get("center", [0.0, 0.0])
	return Vector2(float(center[0]), float(center[1]))


static func _box(batches: Dictionary, role: String, center: Vector3, size: Vector3) -> void:
	if not batches.has(role):
		batches[role] = []
	batches[role].append(Transform3D(Basis.from_scale(size), center))


static func _add_batch(parent: Node3D, role: String, transforms: Array, style: Array, layer: int) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = style[0]
	material.roughness = .85
	material.metallic_specular = .26
	if style.size() > 1:
		material.emission_enabled = true
		material.emission = style[0]
		material.emission_energy_multiplier = float(style[1])
	var mesh: PrimitiveMesh
	if role == "foliage":
		var crown := SphereMesh.new()
		crown.radial_segments = 8
		crown.rings = 4
		mesh = crown
	else:
		mesh = BoxMesh.new()
	mesh.material = material
	var placements := MultiMesh.new()
	placements.transform_format = MultiMesh.TRANSFORM_3D
	placements.mesh = mesh
	placements.instance_count = transforms.size()
	for index in transforms.size():
		placements.set_instance_transform(index, transforms[index])
	var decorations := MultiMeshInstance3D.new()
	decorations.name = role.capitalize()
	decorations.layers = layer
	decorations.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	decorations.multimesh = placements
	parent.add_child(decorations)
