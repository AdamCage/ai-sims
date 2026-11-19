extends RefCounted

const ASSETS := "res://assets/release/maps/residence/"
const ARCHITECTURE := "residence_architecture"
const GLAZING := preload("res://scripts/release_world/residence_glazing.gdshader")
const WINDOW_BAYS := ["facade_home", "facade_civic", "facade_shop"]
const SOLID_BAYS := ["facade_blind", "facade_brick_blind"]
const PROPS := {
	"plant": "potted_plant_01",
	"shelf": "wooden_display_shelves_01",
	"chair": "mid_century_lounge_chair",
	"table": "dining_table",
}

static var _module_catalog: Dictionary = {}

var _site: Node3D
var _world_layer: int
var _wall_layer: int
var _materials: Dictionary = {}
var _batches: Dictionary = {}
var _leaf_mesh: ArrayMesh
var _facade_normal := Vector2.ZERO
var _facade_room_id := ""
var _observer_facades: Dictionary = {}
var _observer_room_facades: Dictionary = {}
var _canopy_id := ""
var _observer_canopies: Dictionary = {}
var _room_roofs: Dictionary = {}


func build(parent: Node3D, geometry: Dictionary, world_layer: int, wall_layer: int) -> Dictionary:
	_world_layer = world_layer
	_wall_layer = wall_layer
	_site = Node3D.new()
	_site.name = "ResidenceScenery"
	parent.add_child(_site)
	var bounds: Array = geometry.bounds
	var center := Vector2((float(bounds[0]) + float(bounds[1])) * .5,
		(float(bounds[2]) + float(bounds[3])) * .5)
	var extent := Vector2(float(bounds[1]) - center.x, float(bounds[3]) - center.y)
	var modules := _architecture()
	var walls_ready := (WINDOW_BAYS + SOLID_BAYS).all(func(id): return modules.has(id))
	if walls_ready:
		_build_walls(geometry)
	_build_streets(center, extent)
	_build_neighbourhood(center, extent)
	_build_courtyard_lights(geometry.rooms)
	for room: Dictionary in geometry.rooms:
		_build_roof(room)
		_build_room(room)
	for prop: Dictionary in geometry.props:
		_build_activity_cluster(prop)
	for door: Dictionary in geometry.doors:
		_build_entry(door)
	_flush_batches()
	var room_facades := {}
	for id: String in _observer_room_facades:
		var groups: Array[Dictionary] = []
		for normal: Vector2 in _observer_room_facades[id]:
			groups.append({"normal": normal, "meshes": _observer_room_facades[id][normal]})
		room_facades[id] = groups
	return {"facades": _observer_facades, "canopies": _observer_canopies.values(),
		"walls_ready": walls_ready, "rugs_ready": modules.has("woven_hall"),
		"roof_details": _room_roofs, "room_facades": room_facades}


static func replacement(kind: String, prop_id: String) -> Node3D:
	# Change presentation at existing prop anchors, including previously saved worlds.
	var prefix := prop_id.get_slice("_", 0)
	var custom := {"sofa": "seamed_sofa", "shop": "grocer_counter", "counter": "kitchen_counter"}
	if prop_id == "common_reading_shelf":
		custom["shelf"] = "hall_archive"
	elif prefix == "shop":
		custom["shelf"] = "grocer_shelf"
		custom["crate"] = "market_produce_crates" if prop_id == "shop_side_stock" else "grocer_crates"
	elif prefix == "dining":
		custom["shelf"] = "kitchen_pantry"
		custom["sink"] = "kitchen_sink"
		custom["chair"] = "dining_chair"
	if custom.has(kind):
		var module: String = custom[kind]
		var mesh: Mesh = _architecture().get(module)
		if mesh != null:
			var root := Node3D.new()
			var furniture := MeshInstance3D.new()
			furniture.mesh = mesh
			root.add_child(furniture)
			return root
	if kind == "fridge" and prefix == "dining":
		return _refrigerator()
	var model: String = PROPS.get(kind, "")
	if kind in ["chair", "shelf"] and prefix not in ["common", "shop"]:
		return null
	if kind == "table" and prefix != "dining":
		return null
	return _load_model(model)


static func _refrigerator() -> Node3D:
	var cabinet := Node3D.new()
	var enamel := StandardMaterial3D.new()
	enamel.albedo_color = Color("b9beb0")
	enamel.roughness = .31
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color("6f7672")
	steel.roughness = .36
	steel.metallic = .54
	var seal := StandardMaterial3D.new()
	seal.albedo_color = Color("42433d")
	_fixture_box(cabinet,Vector3(0,.95,-.035),Vector3(.90,1.90,.80),enamel)
	_fixture_box(cabinet,Vector3(0,.99,.375),Vector3(.866,1.69,.05),seal)
	_fixture_box(cabinet,Vector3(0,.737,.415),Vector3(.854,1.167,.067),enamel)
	_fixture_box(cabinet,Vector3(0,1.584,.415),Vector3(.854,.493,.067),enamel)
	for center_y: float in [1.086,1.54]:
		_fixture_box(cabinet,Vector3(-.335,center_y,.465),Vector3(.042,.24,.055),steel)
	_fixture_box(cabinet,Vector3(0,.097,.378),Vector3(.81,.085,.051),steel)
	return cabinet


static func _fixture_box(parent: Node3D, at: Vector3, extent: Vector3, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = extent
	mesh.material = material
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.position = at
	parent.add_child(part)


static func surface(material_id: String, color: Color, repeat_per_metre: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = .83
	material.metallic_specular = .28
	var base := ASSETS + material_id
	material.albedo_texture = load(base + "_color.png")
	material.normal_texture = load(base + "_normal.png")
	material.normal_scale = .65
	material.normal_enabled = true
	if material_id in ["stone_setts", "courtyard_paver"]:
		material.roughness_texture = load(base + "_roughness.png")
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * repeat_per_metre
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return material


static func _architecture() -> Dictionary:
	if not _module_catalog.is_empty():return _module_catalog
	var library := _load_model(ARCHITECTURE)
	if library == null:return {}
	var finish := {}
	for instance: MeshInstance3D in library.find_children("*", "MeshInstance3D", true, false):
		var module := instance.mesh as ArrayMesh
		if module == null:continue
		var module_id := str(instance.get_parent().name)
		for index in module.get_surface_count():
			var source := module.surface_get_material(index) as StandardMaterial3D
			if source == null:continue
			var glazed := module_id in WINDOW_BAYS and source.resource_name in ["GlassBlue", "GlassGreen", "GlassWarm"]
			var key := "window/" + source.resource_name if glazed else source.resource_name
			if not finish.has(key):finish[key] = _architecture_finish(source, glazed)
			module.surface_set_material(index, finish[key])
		_module_catalog[module_id] = module
	library.free()
	return _module_catalog


static func _architecture_finish(source: StandardMaterial3D, glazed: bool) -> Material:
	if glazed:
		var glazing := ShaderMaterial.new()
		glazing.shader = GLAZING
		glazing.set_shader_parameter("tint", source.albedo_color)
		return glazing
	var result: StandardMaterial3D = source
	var id := source.resource_name
	match id:
		"Plaster", "WarmLime":
			result = surface("lime_stucco", source.albedo_color, .88)
		"Brick", "RoofTile":
			result = surface("brown_brick", source.albedo_color, .64)
		"Oak", "Walnut", "OakDark":
			result = surface("oak_planks", source.albedo_color, .78)
		"Sandstone", "PavementPale", "Basalt":
			result = surface("lime_stucco", source.albedo_color, .42)
			result.normal_scale = .25
		"Pavement", "PavementWarm", "PavementCool":
			result = surface("courtyard_paver", source.albedo_color, .61)
			result.normal_scale = .42
		"SlateRoof", "SlateRoofSoft", "ClayRoof", "ClayRoofDark":
			result = surface("courtyard_paver", source.albedo_color, .47)
			result.normal_scale = .20
		"Upholstery", "UpholsteryDark", "UpholsteryLight", "Cotton":
			result = source.duplicate() as StandardMaterial3D
			result.normal_texture = load("res://assets/release/textures/fabric_normal.png")
			result.normal_enabled = true
			result.normal_scale = .28
			result.uv1_triplanar = true
			result.uv1_world_triplanar = true
			result.uv1_scale = Vector3.ONE * 4.0
		"RugWeave":
			result = source.duplicate() as StandardMaterial3D
			result.albedo_texture = load(ASSETS + "woven_hall_color.png")
			result.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return result


func _install(id: String, at: Vector3, size: Vector3, yaw: float, layer: int, cast_shadow: bool) -> void:
	var mesh: Mesh = _architecture().get(id)
	if mesh == null:return
	var basis := Basis(Vector3.UP, yaw).scaled_local(size)
	_add_instance(mesh, Transform3D(basis, at), layer, cast_shadow)


func _build_roof(room: Dictionary) -> void:
	var purpose := str(room.get("function", ""))
	var product := "roof_zinc"
	if purpose in ["bedroom", "common", "arrival", "lab"]:product = "roof_clay"
	if purpose in ["medical", "reserve", "workshop", "supply"]:product = "roof_slate"
	var model: Mesh = _architecture().get(product)
	if model == null:return
	var at := _point(room)
	var roof := MeshInstance3D.new()
	roof.mesh = model
	roof.layers = _wall_layer
	roof.name = "RoofDetail_" + str(room.id)
	roof.set_meta("room_roof", true)
	roof.position = Vector3(at.x, 2.932, at.y)
	roof.scale = Vector3((float(room.size[0])+.52)/22.52,1.0,(float(room.size[1])+.52)/12.52)
	_site.add_child(roof)
	var meshes: Array[GeometryInstance3D] = [roof]
	_room_roofs[str(room.id)] = meshes


func _wall_room(wall: Dictionary, rooms: Array) -> Dictionary:
	var center := _point(wall)
	var span: Array = wall.size
	var along_x: bool = float(span[0]) > float(span[1])
	for room: Dictionary in rooms:
		var room_center := _point(room)
		var delta := center - room_center
		var half := Vector2(float(room.size[0]), float(room.size[1])) * .5
		if along_x and absf(absf(delta.y) - half.y) < .18 and absf(delta.x) <= half.x:
			return {"normal": Vector2(0, signf(delta.y)), "kind": room.get("function", ""), "room": str(room.id)}
		if not along_x and absf(absf(delta.x) - half.x) < .18 and absf(delta.y) <= half.y:
			return {"normal": Vector2(signf(delta.x), 0), "kind": room.get("function", ""), "room": str(room.id)}
	return {}


func _build_walls(geometry: Dictionary) -> void:
	var stop := _mat("window_opaque_backing", Color("62625a"))
	for wall: Dictionary in geometry.walls:
		var at := _point(wall)
		var dimensions := Vector2(float(wall.size[0]), float(wall.size[1]))
		var height := float(wall.get("height", 2.8))
		var context := _wall_room(wall, geometry.rooms)
		var outward: Vector2 = context.get("normal", Vector2.ZERO)
		var kind: String = context.get("kind", "")
		var tangent := Vector2.RIGHT if dimensions.x > dimensions.y else Vector2.DOWN
		var yaw := atan2(outward.x, outward.y) if outward != Vector2.ZERO else (0.0 if tangent == Vector2.RIGHT else PI * .5)
		var width := maxf(dimensions.x, dimensions.y)
		var depth := minf(dimensions.x, dimensions.y)
		var bays := maxi(1, roundi(width / 2.62))
		if context.is_empty():bays = maxi(1, roundi(width / 4.8))
		var bay_width := width / bays
		var product := "facade_home"
		if kind in ["shop", "workshop", "reserve", "supply"]:product = "facade_shop"
		elif kind in ["common", "kitchen", "medical", "comms", "lab"]:product = "facade_civic"
		var solid := "facade_brick_blind" if product == "facade_shop" else "facade_blind"
		if context.is_empty() and _architecture().has("perimeter_screen"):solid = "perimeter_screen"
		# Window reveals remain physically opaque, including the small bevel joints between modules.
		_facade_normal = outward
		_facade_room_id = str(context.get("room", ""))
		var backing := Vector3(dimensions.x, height, .009) if tangent == Vector2.RIGHT else Vector3(.009, height, dimensions.y)
		_box(Vector3(at.x, height * .5, at.y), backing, stop, _wall_layer)
		for index in bays:
			var offset := (index + .5) * bay_width - width * .5
			var location := at + tangent * offset
			var lined := outward == Vector2.UP and kind in ["common", "shop", "kitchen"]
			var has_window := not context.is_empty() and not lined and bay_width >= 2.0 \
				and posmod(index + floori(at.x * .39) + floori(at.y * .27), 5) != 0
			_install(product if has_window else solid, Vector3(location.x, 0.0, location.y),
				Vector3(bay_width / 2.6, height / 2.8, depth / .20), yaw, _wall_layer, true)
			if kind == "common" and outward == Vector2.DOWN and has_window:
				var inside := location - outward * (depth * .5 + .022)
				_install("hall_window_trim", Vector3(inside.x, 0, inside.y),
					Vector3(bay_width / 2.6, height / 2.8, .79), yaw + PI, _wall_layer, false)
			var corridor_face := absf(at.x) < 28.0 and outward.x != 0.0
			if corridor_face and has_window and posmod(index + floori(absf(at.y)), 2) == 1:
				var planter := location + outward * (depth * .5 + .052)
				var sill_height := .36 if product == "facade_shop" else .56
				_install("window_basket", Vector3(planter.x, sill_height, planter.y),
					Vector3(.92, 1.0, .59), yaw, _wall_layer, false)
				_window_greenery(Vector3(planter.x+outward.x*.062,sill_height+.25,planter.y),outward.x,float(index),_wall_layer)
			if outward != Vector2.ZERO and not has_window and posmod(index + floori(at.x + at.y), 3) == 0:
				var downspout := location + outward * (depth * .5 + .011) + tangent * (bay_width * .25)
				_install("rain_pipe", Vector3(downspout.x, 0, downspout.y),
					Vector3(1, height / 2.8, .74), yaw, _wall_layer, true)
	_facade_normal = Vector2.ZERO
	_facade_room_id = ""


func _build_streets(center: Vector2, extent: Vector2) -> void:
	var ground := _mat("earth", Color("b2a590"))
	var dark_paving := _pbr("stone_setts", Color("a5a69d"), .48)
	var walk := _pbr("stone_setts", Color("cec2a9"), .48)
	var asphalt := _mat("asphalt", Color("505354"))
	var curbs := _mat("curbs", Color("9b9388"))
	var road_mark := _mat("road_mark", Color("c8bd99"))
	_box(Vector3(center.x, -.15, center.y), Vector3(400, .18, 400), ground)
	for side: float in [-1.0, 1.0]:
		var px := center.x + side * (extent.x + 6.2)
		var pz := center.y + side * (extent.y + 6.2)
		_box(Vector3(px, -.056, center.y), Vector3(7.4, .09, extent.y * 2 + 20), asphalt)
		_box(Vector3(center.x, -.058, pz), Vector3(extent.x * 2 + 20, .09, 7.4), asphalt)
		for shift: float in [-4.7, 4.7]:
			_box(Vector3(px + shift, -.04, center.y), Vector3(1.9, .09, extent.y * 2 + 4), walk)
			_box(Vector3(center.x, -.04, pz + shift), Vector3(extent.x * 2 + 4, .09, 1.9), walk)
		for x_offset: float in [-3.63, 3.63]:
			_box(Vector3(px + x_offset, -.028, center.y), Vector3(.15, .10, extent.y * 2 + 4), curbs)
			_box(Vector3(center.x, -.028, pz + x_offset), Vector3(extent.x * 2 + 4, .10, .15), curbs)
		for stripe in range(-7, 8):
			_box(Vector3(px, -.005, center.y + stripe * 4.05), Vector3(.095, .014, 1.43), road_mark)
		for stripe in range(-10, 11):
			_box(Vector3(center.x + stripe * 4.05, -.005, pz), Vector3(1.43, .014, .095), road_mark)
	# Flush stone rows follow the two courtyards and meet the original thresholds.
	for offset: float in [-.33, .33]:
		var path_x := center.x + extent.x * offset
		if _architecture().has("paving_running_a"):
			var rows := floori(extent.y / 1.2)
			for row in rows:
				var z := center.y + (row + .5 - rows * .5) * 2.4
				for column in 4:
					var x := path_x + (column - 1.5) * 2.4
					var module := "paving_running_a" if posmod(row + column, 2) == 0 else "paving_running_b"
					if posmod(row + 2, 7) == 0:
						module = "paving_crossing" if column in [1, 2] else "paving_border"
					var heading := PI if posmod(row * 3 + column, 5) == 0 else 0.0
					_install(module, Vector3(x, .020,z), Vector3.ONE, heading, _world_layer, false)
			for side: float in [-1.0, 1.0]:
				_box(Vector3(path_x + side * 4.8, .032, center.y),
					Vector3(.062,.026, rows * 2.4),dark_paving)
			var inlay := _mat("court_bronze_inlay",Color("918776"),.72)
			for row in range(-2,3):
				var at := Vector3(path_x,.046,center.y+2.2+row*16.5)
				for edge: float in [-1.0,1.0]:
					_box(at+Vector3(0,0,edge*.29),Vector3(8.12,.003,.041),inlay)
					_box(at+Vector3(edge*3.94,.001,0),Vector3(.043,.004,.56),inlay)
		else:
			_box(Vector3(path_x, .024, center.y), Vector3(4.45, .015, extent.y * 1.96), walk)
	for index in range(-4, 5):
		var z := center.y + index * extent.y * .195
		for side: float in [-1.0, 1.0]:
			var x := center.x + extent.x * (.33 * side) + .43
			_install("court_grates", Vector3(x, .043, z), Vector3.ONE, 0.0, _world_layer, false)


func _build_neighbourhood(center: Vector2, extent: Vector2) -> void:
	var grass := _mat("green", Color("717952"))
	var trunk := _mat("bark", Color("554538"))
	var lamps := _mat("lamps", Color("383c36"), .56)
	var lamp_glass := _mat("lamp_glass", Color("f3d4a0"), .43)
	lamp_glass.emission_enabled = true
	lamp_glass.emission = Color("f8d4a0")
	lamp_glass.emission_energy_multiplier = .35
	var row_depth := 9.4
	for side: float in [-1.0, 1.0]:
		for index in range(-3, 4):
			var avenue_z := center.y + index * 10.0
			var court_x := center.x + side * (extent.x + 12.2)
			_box(Vector3(court_x, -.024, avenue_z), Vector3(1.95, .08, 3.1), grass)
			_tree(Vector3(court_x, .06, avenue_z), 4.2 + fposmod(float(index) * .67, 1.6), index + int(side) * 10, trunk)
		for index in range(-4, 5):
			var avenue_x := center.x + index * 10.0
			var court_z := center.y + side * (extent.y + 12.1)
			_box(Vector3(avenue_x, -.024, court_z), Vector3(3.1, .08, 1.9), grass)
			_tree(Vector3(avenue_x, .06, court_z), 3.8 + fposmod(float(index) * .47, 1.7), index - int(side) * 20, trunk)
		for index in range(-2, 3):
			var offset := float(index) * 16.0
			var avenue := "market" if index == int(side) else str(3 + posmod(index + int(side), 3))
			var street := "atelier" if index == 0 or index == -2 * int(side) else str(3 + posmod(index - int(side), 3))
			_neighbour(Vector2(center.x + offset, center.y + side * (extent.y + 20.0)),
				Vector2(13.0, row_depth), avenue, side, true)
			_neighbour(Vector2(center.x + side * (extent.x + 20.0), center.y + offset),
				Vector2(row_depth, 13.0), street, side, false)
		for index in range(-2, 3):
			var origin := Vector3(center.x + index * 16.0 + 3.0, 0,
				center.y + side * (extent.y + 10.15))
			_box(origin + Vector3.UP * 1.52, Vector3(.092, 3.04, .092), lamps)
			_box(origin + Vector3(.25, 3.01, 0), Vector3(.57, .067, .16), lamps)
			_box(origin + Vector3(.48, 2.965, 0), Vector3(.235, .037, .18), lamp_glass)
		var bench := _load_model("painted_wooden_bench")
		if bench != null:
			bench.position = Vector3(center.x - 8 * side, .045, center.y + side * (extent.y + 11.2))
			bench.rotation.y = PI if side > 0 else 0.0
			_site.add_child(bench)
			_set_model_layer(bench)


func _neighbour(at: Vector2, size: Vector2, style: String, side: float, front_x: bool) -> void:
	var module := "skyline_" + style
	if _architecture().has(module):
		var outward := Vector2(0, -side) if front_x else Vector2(-side, 0)
		var yaw := atan2(outward.x, outward.y)
		var scale := Vector3(size.x / 13.0, 1.0, size.y / 9.4) if front_x else Vector3(size.y / 13.0, 1.0, size.x / 9.4)
		_install(module, Vector3(at.x,0.0,at.y), scale, yaw, _world_layer, true)
		return
	var floors := maxi(3, style.to_int())
	var height := float(floors) * 2.65
	var plaster := _pbr("lime_stucco", Color("c4ab91") if floors == 4 else Color("a9a39a"), 1.05)
	var blank := _pbr("brown_brick", Color("baaa9b"), .45)
	var stone := _mat("stone", Color("a6a095"))
	var roofs := _mat("neighbour_roof", Color("565650"))
	var casing := _mat("neighbour_frame", Color("c4c1b3"))
	var glass := _mat("neighbour_glass", Color("576461"), .30)
	_box(Vector3(at.x, height * .5, at.y), Vector3(size.x, height, size.y), plaster)
	_box(Vector3(at.x, 1.05, at.y), Vector3(size.x + .08, 2.1, size.y + .08), blank)
	var roof_center := Vector3(at.x,height,at.y)
	_box(roof_center, Vector3(size.x + .49, .38, size.y + .49), roofs)
	if floors == 3:
		var roof_tile := _pbr("brown_brick",Color("73564b"),1.12)
		for slope: float in [-1.0,1.0]:
			var run := (size.y if front_x else size.x) * .5 + .31
			var board_size := Vector3(size.x+.62,.20,run/.955) if front_x else Vector3(run/.955,.20,size.y+.62)
			var offset := Vector3(0,run*.11+.44,slope*run*.5) if front_x else Vector3(slope*run*.5,run*.11+.44,0)
			var pitch := Vector3(slope*.30,0,0) if front_x else Vector3(0,0,-slope*.30)
			_box(roof_center+offset,board_size,roof_tile,_world_layer,pitch)
		_box(roof_center+Vector3(.8,1.10,1.1),Vector3(.71,1.77,.82),blank)
	else:
		_box(roof_center+Vector3(-size.x*.21,.38,size.y*.21),Vector3(1.76,.63,1.14),stone)
	for floor_index in range(1, floors):
		var y := floor_index * 2.65 + .22
		_box(Vector3(at.x, y - .84, at.y), Vector3(size.x + .12, .10, size.y + .12), stone)
		for window in range(-2, 3):
			var offset := window * 2.35
			var outward := Vector3(0, 0, -side) if front_x else Vector3(-side, 0, 0)
			var across := Vector3(offset, 0, 0) if front_x else Vector3(0, 0, offset)
			var width := size.y if front_x else size.x
			var origin := Vector3(at.x, y, at.y) + across + outward * (width * .5 + .012)
			var panel := Vector3(1.24, 1.62, .07) if front_x else Vector3(.07, 1.62, 1.24)
			_box(origin, panel, casing)
			_box(origin + outward * .043, panel * Vector3(.84, .88, .84), glass)
			if floors == 4 and window % 2 == 0:
				var balcony := Vector3(1.57,.12,.86) if front_x else Vector3(.86,.12,1.57)
				_box(origin - Vector3.UP *.84 + outward *.44, balcony, stone)
				var rail := Vector3(1.57,.057,.063) if front_x else Vector3(.063,.057,1.57)
				_box(origin - Vector3.UP*.22 + outward*.83,rail,roofs)
				for bar in range(-2,3):
					var baluster := Vector3(bar*.31,0,0) if front_x else Vector3(0,0,bar*.31)
					_box(origin+baluster-Vector3.UP*.51+outward*.83,Vector3(.032,.57,.032),roofs)


func _build_courtyard_lights(rooms: Array) -> void:
	var rows := {}
	for room: Dictionary in rooms:
		var id := str(room.id)
		rows[id] = room
	for pair: Array in [["common", "supply"], ["dining", "shop"], ["medical", "workshop"]]:
		if not rows.has(pair[0]) or not rows.has(pair[1]):
			continue
		var west: Dictionary = rows[pair[0]]
		var east: Dictionary = rows[pair[1]]
		var west_at := _point(west)
		var east_at := _point(east)
		var start := west_at.x + float(west.size[0]) * .5
		var end := east_at.x - float(east.size[0]) * .5
		if end <= start or not is_equal_approx(west_at.y, east_at.y):
			continue
		var at := Vector3((start + end) * .5, 2.816, west_at.y - 3.33)
		_install("court_light_span", at, Vector3((end - start) / 10.0, 1.0, 1.0), 0.0, _world_layer, false)


func _build_room(room: Dictionary) -> void:
	var kind := str(room.get("function", ""))
	_facade_room_id = str(room.id)
	var at := _point(room)
	var size: Array = room.size
	var spans := Vector2(float(size[0]), float(size[1]))
	if kind in ["common", "bedroom"]:
		var carpet := Vector3(at.x, .045, at.y - .4)
		var measure := Vector3.ONE if kind == "common" else Vector3(.74, 1, .73)
		_install("woven_hall", carpet, measure, 0.0, _world_layer, false)
	if kind not in ["shop", "common", "kitchen"]:
		_build_secondary_room(at, spans, kind)
		_facade_room_id = ""
		return
	var wood := _pbr("oak_planks", Color("ddd0ba"), .54)
	var iron := _mat("fixture_iron", Color("4b4640"), .50)
	var ceiling_glow := _mat("fixture_glow", Color("f7d7a1"), .58)
	ceiling_glow.emission_enabled = true
	ceiling_glow.emission = Color("f7c88a")
	ceiling_glow.emission_energy_multiplier = 1.15
	var brick := _pbr("brown_brick", Color("ccb19b"), .52)
	var north := at.y - spans.y * .5 + .12
	_build_room_floor(at, spans, kind)
	# Lining and fixtures attach to the existing architecture at overhead or wall height.
	_facade_normal = Vector2(0,-1)
	match kind:
		"common":
			var reed := _mat("reed", Color("99816a"))
			var frame := _mat("board_frame", Color("685442"))
			var linen := _mat("board_linen", Color("b3aa96"))
			var board_width := spans.x * .47
			_box(Vector3(at.x, 1.48, north), Vector3(board_width, 2.26, .06), wood, _wall_layer)
			for slat in range(-22, 23):
				_box(Vector3(at.x + slat * .19, 1.48, north + .034),
					Vector3(.092, 2.25, .037), reed, _wall_layer)
			var board := Vector3(at.x, 1.78, north + .069)
			_box(board, Vector3(3.27, 1.12, .065), frame, _wall_layer)
			_box(board + Vector3.BACK * .037, Vector3(3.15, 1.02, .018), linen, _wall_layer)
			_pin_paper(board + Vector3(-1.13, .10, .051), Vector2(.43, .61), Color("d8d0bc"), -.085,
				"ДВОР", "Зал собраний\nЛавка\nОбщая кухня")
			_pin_paper(board + Vector3(-.58, -.06, .051), Vector2(.47, .63), Color("aab0a3"), .055,
				"СОСЕДИ", "Вести квартала\nОбщий дом")
			_pin_paper(board + Vector3(.15, .09, .051), Vector2(.66, .70), Color("d8d0bc"), -.015,
				"НАШ КВАРТАЛ", "Дом у часов\nДом с садом\nОбщественный проспект")
			_pin_paper(board + Vector3(.93, -.06, .051), Vector2(.49, .62), Color("c1a585"), .072,
				"ЧИТАЛЬНЫЙ ЗАЛ", "Книги\nАрхив квартала")
			for side: float in [-1.0, 1.0]:
				var sconce := Vector3(at.x + side * 3.82, 2.12, north + .072)
				_box(sconce, Vector3(.17, .49, .054), iron, _wall_layer)
				_box(sconce + Vector3.BACK * .03, Vector3(.11, .37, .07), ceiling_glow, _wall_layer)
				_room_light(sconce + Vector3.BACK * .30, Color("f5c48a"), .45, 3.0)
				_wall_shelves(Vector3(at.x + side*8.55,.81,north+.055),2.6,wood,false)
				_install("hall_prints", Vector3(at.x + side * 5.95, 1.77, north + .031),
					Vector3.ONE, 0.0, _wall_layer, false)
		"shop":
			_box(Vector3(at.x, 1.41, north), Vector3(spans.x * .80, 2.62, .06), brick, _wall_layer)
			var trim := _mat("shop_rail", Color("5c6e62"))
			_box(Vector3(at.x, .53, north + .044), Vector3(spans.x * .8, .82, .075), trim, _wall_layer)
			var card := Vector3(at.x + 4.6, 1.74, north + .058)
			_wall_sign(card, "ХЛЕБ  ·  ОВОЩИ", .015, Vector2(2.70, .48), trim)
			_wall_sign(card + Vector3(-3.0, .28, 0), "Товары первой необходимости", .008, Vector2(2.35, .38), trim)
			if _architecture().has("market_bread"):
				var displays := ["market_bread", "market_tins", "market_bottles", "market_tins", "market_bread", "market_bottles"]
				for bay in 6:
					var x := at.x + (bay - 3.0) * 2.27
					_install(displays[bay], Vector3(x,.83 + .04*(bay%2),north+.061),
						Vector3(1.0,1.0-.065*(bay%3),1.0), 0.0, _wall_layer, false)
			else:
				_wall_shelves(Vector3(at.x-2.6,.74,north+.069),6.1,wood,true)
		"kitchen":
			for bay in range(-2, 3):
				_install("kitchen_tilecourses", Vector3(at.x + bay*3.4,.74,north+.019),
					Vector3.ONE, 0.0, _wall_layer, false)
			_install("kitchen_tools", Vector3(at.x - 3.61, 2.14, north+.095), Vector3.ONE, 0.0, _wall_layer, false)
			for x: float in [-5.93, 5.51]:
				_install("kitchen_wall_cupboard", Vector3(at.x + x, 1.64, north+.087),
					Vector3.ONE, 0.0, _wall_layer, true)
			for side: float in [-1.0,1.0]:
				_install("shop_wall_display", Vector3(at.x + side*1.38,.93,north+.065),
					Vector3(1.14, .83, 1.0), 0.0, _wall_layer, false)
			_wall_sign(Vector3(at.x + 4.7, 2.31, north + .045), "ОБЩАЯ КУХНЯ", .012, Vector2(1.91, .36), iron)
	_facade_normal = Vector2.ZERO
	var track := _mat("ceiling_track",Color("5b5e54"),.45)
	var main_rail_z := at.y - 1.65
	_box(Vector3(at.x, 2.764, main_rail_z),Vector3(spans.x+.04,.062,.075),track,_wall_layer)
	for side: float in [-1.0, 1.0]:
		var origin := Vector3(at.x + side * spans.x * .22, 2.69, main_rail_z)
		for spacing: float in [-.9, .9]:
			var pendant := origin + Vector3(spacing, .07, 0)
			_install("pendant", pendant, Vector3.ONE, 0.0, _wall_layer, false)
		var light_color := Color("ffdeb1") if kind == "common" else Color("fff1d5")
		_room_light(origin - Vector3.UP * .52, light_color, .57, 6.0)
	if kind == "kitchen":
		_dining_spine(at, spans, 2.0, track)
		for x: float in [-3.0,-1.36]:
			_install("pendant", Vector3(at.x+x, 2.76, at.y+2.0), Vector3(1.06, .95, 1.06), 0.0, _wall_layer, false)
		_room_light(Vector3(at.x-2.18,2.12,at.y+2.0), Color("f1e4cc"), .68, 4.9)
		_floor_trim(Vector3(at.x-6.92,.049,at.y-3.69),Vector2(5.4,3.3),"kitchen")
	elif kind == "shop":
		_dining_spine(at, spans, 2.0, track)
		var counter := at + Vector2(-7.7,2.0)
		for x: float in [-1.12,1.12]:
			_install("pendant", Vector3(counter.x+x,2.76,counter.y), Vector3.ONE, 0.0, _wall_layer, false)
		_room_light(Vector3(counter.x,2.13,counter.y), Color("f8e4bf"), .72, 4.9)
		_floor_trim(Vector3(at.x-6.52,.049,at.y+1.93),Vector2(7.9,4.8),"shop")
	_facade_room_id = ""


func _build_room_floor(at: Vector2, spans: Vector2, kind: String) -> void:
	# Thin finish layers sit above the common substrate with no new walkable obstacles.
	match kind:
		"common":
			var parquet := _pbr("oak_planks", Color("b7a48d"), .57)
			var step := Vector3(at.x, .047, at.y - spans.y * .335)
			_box(step, Vector3(spans.x - .24, .004, spans.y * .301), parquet)
			var wood_border := _mat("hall_parquet_transition", Color("695343"), .76)
			_box(step + Vector3(0, .004, spans.y * .151), Vector3(spans.x - .30, .003, .067), wood_border)
		"kitchen":
			var prep := _pbr("courtyard_paver", Color("89958d"), .72)
			var prep_at := Vector3(at.x, .047, at.y - spans.y * .319)
			_box(prep_at, Vector3(spans.x - .28, .004, spans.y * .339), prep)
			var border := _mat("kitchen_ceramic_transition", Color("686e61"), .69)
			_box(prep_at + Vector3(0, .004, spans.y * .170), Vector3(spans.x - .28, .004, .074), border)
			var wood := _pbr("oak_planks", Color("cbbda3"), .61)
			var dining_at := Vector3(at.x - spans.x * .10, .047, at.y + spans.y * .15)
			var dining_size := Vector2(spans.x * .38, spans.y * .39)
			_box(dining_at, Vector3(dining_size.x, .004, dining_size.y), wood)
			_floor_trim(dining_at + Vector3.UP * .004, dining_size, kind)
		"shop":
			var aisles := _pbr("courtyard_paver", Color("a1aa9d"), .79)
			var aisle_at := Vector3(at.x, .047, at.y - spans.y * .341)
			_box(aisle_at, Vector3(spans.x - .24, .004, spans.y * .299), aisles)
			var divider := _mat("shop_stone_transition", Color("64776b"), .74)
			_box(aisle_at + Vector3(0, .004, spans.y * .150), Vector3(spans.x - .26, .003, .099), divider)


func _dining_spine(at: Vector2, spans: Vector2, offset: float, material: Material) -> void:
	var rail_length := spans.x*.70
	var rail_x := at.x-spans.x*.151
	_box(Vector3(rail_x,2.765,at.y+offset),Vector3(rail_length,.069,.086),material,_wall_layer)
	var ties := spans.y*.5-offset
	for end: float in [-1.0,1.0]:
		var x := rail_x + end*(rail_length*.5-.02)
		_box(Vector3(x,2.765,at.y+offset+ties*.5),Vector3(.075,.069,ties+.04),material,_wall_layer)


func _floor_trim(at: Vector3, size: Vector2, kind: String) -> void:
	var border := _mat(kind+"_floor_border",Color("82796a") if kind == "kitchen" else Color("6a766d"),.72)
	var inner := _mat(kind+"_floor_slim",Color("c1b59d"),.81)
	for edge: float in [-1.0,1.0]:
		_box(at+Vector3(0,0,edge*size.y*.5),Vector3(size.x,.003,.108),border)
		_box(at+Vector3(edge*size.x*.5,0,0),Vector3(.108,.003,size.y),border)
		_box(at+Vector3(0,0,edge*(size.y*.5-.121)),Vector3(size.x-.212,.003,.032),inner)
		_box(at+Vector3(edge*(size.x*.5-.121),0,0),Vector3(.032,.003,size.y-.212),inner)


func _build_secondary_room(at: Vector2, spans: Vector2, kind: String) -> void:
	var wall := at.y - spans.y * .5 + .14
	_facade_normal = Vector2.UP
	var displays := {"bedroom": "library", "arrival": "tools", "reserve": "tools", "medical": "clinic",
		"comms": "library", "supply": "tools", "workshop": "tools", "lab": "library"}
	var display: String = displays.get(kind, "")
	if not display.is_empty():
		for offset: float in [.18, .27]:
			var mount := Vector3(at.x + spans.x * offset, 1.02, wall)
			_install("secondary_" + display, mount, Vector3.ONE, 0.0, _wall_layer, false)
	_facade_normal = Vector2.ZERO
	var track := _mat("ceiling_track",Color("5b5e54"),.45)
	var x := at.x + 4.0
	var length := spans.y * .5 - 2.25
	_box(Vector3(x,2.758,at.y-2.25-length*.5),Vector3(.058,.058,length+.02),track,_wall_layer)
	_install("pendant", Vector3(x, 2.74, at.y - 2.25), Vector3.ONE, 0.0, _wall_layer, false)


func _room_light(at: Vector3, color: Color, energy: float, reach: float) -> void:
	var light := OmniLight3D.new()
	light.position = at
	light.light_color = color
	light.light_energy = energy
	light.omni_range = reach
	light.omni_attenuation = 2.0
	light.distance_fade_enabled = true
	light.distance_fade_begin = 15.0
	light.distance_fade_length = 8.0
	_site.add_child(light)


func _pin_paper(at: Vector3, size: Vector2, tint: Color, angle: float, title: String, text: String) -> void:
	var paper := _mat("paper_" + tint.to_html(), tint)
	_box(at, Vector3(size.x, size.y, .008), paper, _wall_layer, Vector3(0, 0, angle))
	var brass := _mat("paper_tack", Color("91836c"), .37)
	var pin := Vector2(0.0, size.y*.431).rotated(angle)
	_box(at + Vector3(pin.x,pin.y,.007), Vector3(.024,.024,.014),brass,_wall_layer)
	_paper_print(at, title, size.y*.23, angle, .00138, 24)
	_paper_print(at, text, -size.y*.06, angle, .00102, 20)


func _paper_print(at: Vector3, line: String, height: float, angle: float, pitch: float, points: int) -> void:
	var offset := Vector2(0.0,height).rotated(angle)
	var label := Label3D.new()
	label.text = line
	label.position = at + Vector3(offset.x,offset.y,.006)
	label.rotation.z = angle
	label.font_size = points
	label.pixel_size = pitch
	label.modulate = Color("3e483f")
	label.outline_size = 0
	label.double_sided = false
	label.layers = _wall_layer
	_site.add_child(label)
	_track_facade(label,_facade_normal,_facade_room_id)


func _wall_sign(at: Vector3, text: String, letter_size: float, size: Vector2, plate: Material) -> void:
	_box(at, Vector3(size.x, size.y, .053), plate, _wall_layer)
	var sign := Label3D.new()
	sign.text = text
	sign.font_size = 23
	sign.pixel_size = letter_size * .35
	sign.position = at + Vector3.BACK * .032
	sign.modulate = Color("f1e6d2")
	sign.outline_size = 0
	sign.double_sided = false
	sign.layers = _wall_layer
	_site.add_child(sign)
	_track_facade(sign,_facade_normal,_facade_room_id)


func _wall_shelves(at: Vector3, width: float, shelf: StandardMaterial3D, groceries: bool) -> void:
	var painted_back := _mat("wall_shelf_back",Color("65574a"))
	var labels := _mat("wall_shelf_labels",Color("cfc2a0"))
	var palette := [Color("a89368"),Color("908b72"),Color("94705c"),Color("7a8d82"),Color("c0ab90"),Color("625b53")]
	var column_count := floori(width / .44)
	_box(at+Vector3.UP*.45,Vector3(width,.96,.035),painted_back,_wall_layer)
	for row in 3:
		var surface_at := at + Vector3.UP*(row*.32) + Vector3.BACK*.023
		_box(surface_at,Vector3(width,.044,.115),shelf,_wall_layer)
		for column in column_count:
			var variation := posmod(column*13+row*7,13)
			if variation in [3,7,10]:continue
			var color: Color = palette[posmod(variation+row*3,palette.size())]
			var box_mat := _mat("shelf_goods_"+color.to_html(),color)
			var height := .14+variation*.008
			var thickness := .055+float(variation%3)*.034
			var position := surface_at + Vector3((column-column_count*.5+.5)*.44,height*.5+.025,.019)
			var dimensions := Vector3(.24 if groceries else thickness,height,.060)
			_box(position,dimensions,box_mat,_wall_layer)
			if groceries:
				_box(position+Vector3.BACK*.032,Vector3(dimensions.x*.78,height*.40,.006),labels,_wall_layer)
			else:
				_box(position+Vector3(.10,-.02,0.0),Vector3(.057,height*.81,.054),labels,_wall_layer,Vector3(0,0,.12))


func _build_activity_cluster(prop: Dictionary) -> void:
	# Draw small scenes on existing collision footprints, never in the walking lanes.
	var id := str(prop.get("id",""))
	if id not in ["common_table","common_sofa","common_window_seat","shop_counter","dining_table","dining_counter"]:
		return
	var point := _point(prop)
	var size: Array = prop.size
	var height := float(prop.get("height",.8))
	var surface_at := Vector3(point.x,height,point.y)
	var porcelain := _mat("glazed_porcelain",Color("d4c8ad"),.27)
	var cast_iron := _mat("cookware_iron",Color("535555"),.41)
	var wood := _pbr("oak_planks",Color("ae9072"),.74)
	match id:
		"common_table":
			var agenda := surface_at + Vector3(float(size[0])*.28,.002,.10)
			_install("hall_agenda", agenda, Vector3.ONE, -.13, _world_layer, true)
			_crockery(surface_at+Vector3(.18,0,-.20),porcelain,true)
			_crockery(surface_at+Vector3(.65,0,-.19),porcelain,true)
			_runner(Vector3(point.x,.052,point.y+.41),Vector2(3.36,2.36),Color("738078"))
		"common_sofa", "common_window_seat":
			var blanket := _cloth("sofa_throw",Color("a68a68"))
			var edge := _mat("throw_border",Color("856c57"))
			var seat_edge := float(size[0])*.33
			var top := surface_at + Vector3(seat_edge,-height*.10,-.08)
			_box(top,Vector3(.43,.038,.43),blanket,_world_layer,Vector3(0,.05,-.12))
			_box(top+Vector3(.011,-.093,.219),Vector3(.40,.233,.034),blanket,_world_layer,Vector3(0,.035,-.06))
			_box(top+Vector3(.009,-.171,.24),Vector3(.40,.039,.012),edge)
			_runner(Vector3(point.x,.052,point.y-.23),Vector2(3.0,1.91),Color("7a7161"))
		"shop_counter":
			var shelf_top := surface_at if _architecture().has("grocer_counter") else surface_at - Vector3.UP*height*.376
			_produce_tray(shelf_top+Vector3(-float(size[0])*.31,0,.12),wood,Color("a65d42"))
			_produce_tray(shelf_top+Vector3(-float(size[0])*.10,0,.12),wood,Color("879055"))
			var bag := _mat("paper_sack",Color("ad9471"),.94)
			_box(shelf_top+Vector3(.30,.096,.21),Vector3(.169,.19,.149),bag,_world_layer,Vector3(0,.15,-.09))
			_box(shelf_top+Vector3(.48,.116,.18),Vector3(.178,.23,.139),bag,_world_layer,Vector3(0,-.23,.12))
			_install("counter_display", shelf_top+Vector3(-.23,0,-.20), Vector3.ONE, 0.0, _world_layer, false)
			var scale_origin := shelf_top + Vector3(float(size[0]) * .34, 0, -.19)
			var enamel := _mat("grocer_scale", Color("aca79a"), .42)
			_box(scale_origin + Vector3.UP * .04, Vector3(.39, .081, .31), cast_iron)
			_box(scale_origin + Vector3.UP * .143, Vector3(.245, .198, .15), enamel)
			_round_detail(scale_origin + Vector3.UP * .245, Vector3(.348, .044, .348), enamel)
			_runner(Vector3(point.x,.052,point.y+1.03),Vector2(float(size[0])+.20,1.09),Color("6e796c"))
		"dining_table":
			_install("dinner_service", surface_at, Vector3.ONE, 0.0, _world_layer, false)
			_runner(Vector3(point.x,.052,point.y),Vector2(3.74,2.65),Color("837569"))
		"dining_counter":
			_install("kitchen_range", surface_at - Vector3.RIGHT*.80, Vector3.ONE, 0.0, _world_layer, true)
			_install("kitchen_hood", surface_at + Vector3(-.80,1.23,-.17), Vector3.ONE, 0.0, _world_layer, true)
			var steel := _mat("hood_duct",Color("929b9c"),.43)
			_box(surface_at+Vector3(-.80,1.77,-.85),Vector3(.31,.22,1.12),steel)
			var pot := surface_at + Vector3(-1.02,.17,-.09)
			_round_detail(pot+Vector3.UP*.102,Vector3(.32,.206,.32),cast_iron)
			_round_detail(pot+Vector3.UP*.210,Vector3(.341,.028,.341),cast_iron)
			_round_detail(pot+Vector3.UP*.24,Vector3(.076,.053,.076),cast_iron)
			for side: float in [-1.0,1.0]:
				_box(pot+Vector3(side*.19,.139,0),Vector3(.12,.035,.075),cast_iron)
			var board := surface_at+Vector3(.88,.025,.02)
			_box(board,Vector3(.49,.052,.30),wood,_world_layer,Vector3(0,-.19,0))
			_crockery(board+Vector3(.04,.031,-.023),porcelain,false)
			_crockery(surface_at+Vector3(.42,0,-.20),porcelain,true)


func _produce_tray(at: Vector3, wood: StandardMaterial3D, tint: Color) -> void:
	_box(at+Vector3.UP*.029,Vector3(.55,.06,.28),wood)
	for side: float in [-1.0,1.0]:
		_box(at+Vector3(0,.066,side*.132),Vector3(.56,.083,.023),wood)
		_box(at+Vector3(side*.265,.064,0),Vector3(.024,.076,.26),wood)
	var produce := _mat("produce_"+tint.to_html(),tint,.64)
	var stalk := _mat("produce_stalk",Color("655844"))
	for index in 7:
		var position := at+Vector3((index%4-1.5)*.117,.102+sin(index*1.6)*.014,(-.061 if index < 4 else .046))
		var aspect := .090 + cos(index*2.7)*.014
		_rounded_produce(position,Vector3(.107,aspect,.108),produce)
		_round_detail(position+Vector3.UP*(aspect*.56),Vector3(.015,.024,.014),stalk)


func _crockery(at: Vector3, material: StandardMaterial3D, mug: bool) -> void:
	if not mug:
		_round_detail(at+Vector3.UP*.013,Vector3(.265,.028,.265),material)
		var inset := _mat("plate_center",Color("b5ab96"),.31)
		_round_detail(at+Vector3.UP*.026,Vector3(.207,.008,.207),inset)
		return
	_round_detail(at+Vector3.UP*.054,Vector3(.112,.106,.112),material)
	var tea := _mat("tea_color",Color("675146"),.23)
	_round_detail(at+Vector3.UP*.108,Vector3(.092,.004,.092),tea)
	_box(at+Vector3(.056,.052,0),Vector3(.027,.054,.021),material)


func _runner(at: Vector3, size: Vector2, tint: Color) -> void:
	var canvas := _cloth("runner_"+tint.to_html(),tint)
	var hem := _mat("runner_hem",Color("ac9b80"))
	_box(at,Vector3(size.x,.009,size.y),canvas)
	for side: float in [-1.0,1.0]:
		_box(at+Vector3(0,.005,side*(size.y*.5-.085)),Vector3(size.x-.16,.005,.034),hem)
		_box(at+Vector3(side*(size.x*.5-.086),.005,0),Vector3(.031,.005,size.y-.16),hem)


func _cloth(id: String, tint: Color) -> StandardMaterial3D:
	var material := _mat(id,tint,.95)
	material.albedo_texture = preload("res://assets/release/textures/fabric_color.png")
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * 1.1
	return material


func _round_detail(at: Vector3, extent: Vector3, material: Material) -> void:
	var key := ["cylinder",material]
	if not _materials.has(key):
		var mesh := CylinderMesh.new()
		mesh.radial_segments = 16
		mesh.rings = 1
		mesh.top_radius = .5
		mesh.bottom_radius = .43
		mesh.height = 1.0
		mesh.material = material
		_materials[key] = mesh
	_add_instance(_materials[key],Transform3D(Basis.IDENTITY.scaled(extent),at),_world_layer,false)


func _rounded_produce(at: Vector3, extent: Vector3, material: Material) -> void:
	var key := ["produce",material]
	if not _materials.has(key):
		var mesh := SphereMesh.new()
		mesh.radial_segments = 12
		mesh.rings = 6
		mesh.material = material
		_materials[key] = mesh
	_add_instance(_materials[key],Transform3D(Basis.IDENTITY.scaled(extent),at),_world_layer,false)


func _build_entry(door: Dictionary) -> void:
	var id := str(door.get("id", ""))
	var kind := id.get_slice("_", 0)
	if kind not in ["common", "dining", "shop"] or id.get_slice("_", 1) not in ["east", "west"]:
		return
	var at := _point(door)
	var sign_side := -1.0 if id.ends_with("_west") else 1.0
	_facade_normal = Vector2(sign_side,0)
	_facade_room_id = kind
	_canopy_id = id
	_observer_canopies[id] = {"normal": _facade_normal, "meshes": []}
	var frame := _mat("entry_frames", Color("403f37"), .44)
	var cloth := {
		"common": Color("46574a"),
		"dining": Color("a27149"),
		"shop": Color("864d42"),
	}
	var fabric := _mat(kind + "_canopy", cloth[kind], .87)
	var stripes := _mat("canopy_sand", Color("c9b69c"))
	var center := Vector3(at.x, 2.89, at.y)
	var model := "canopy_kitchen" if kind == "dining" else "canopy_" + kind
	if _architecture().has(model):
		_install(model, center, Vector3.ONE, sign_side * PI * .5, _world_layer, true)
	else:
		_box(center, Vector3(.29, .22, 3.72), frame)
		for index in 13:
			var z := at.y + (index - 6) * .263
			var material: StandardMaterial3D = stripes if kind == "shop" and index % 2 == 0 else fabric
			_box(Vector3(at.x + sign_side * .77, 2.79, z), Vector3(1.50, .047, .261),
				material, _world_layer, Vector3(0, 0, -sign_side * .14))
			_box(Vector3(at.x + sign_side * 1.52, 2.61, z), Vector3(.045, .19, .261), material)
		for side: float in [-1.0, 1.0]:
			_box(Vector3(at.x + sign_side * .76, 2.68, at.y + side * 1.62),
				Vector3(1.54, .056, .046), frame, _world_layer, Vector3(0, 0, -sign_side * .13))
	var letters := {"common": "ЗАЛ СОБРАНИЙ", "dining": "ОБЩАЯ КУХНЯ", "shop": "ЛАВКА"}
	var sign := Label3D.new()
	sign.position = center + Vector3(sign_side * .154, 0, 0)
	sign.rotation.y = sign_side * PI * .5
	sign.text = letters[kind]
	sign.modulate = Color("f0dfbb")
	sign.layers = _world_layer
	sign.font_size = 48
	sign.pixel_size = .004
	sign.outline_size = 0
	sign.double_sided = false
	_site.add_child(sign)
	_observer_canopies[id].meshes.append(sign)
	_canopy_id = ""
	var address := {"common": "06", "dining": "05", "shop": "09"}
	var plaque_at := Vector3(at.x + sign_side*.123,1.63,at.y + sign_side*1.61)
	var dark_bronze := _mat("address_plaque",Color("545852"),.43)
	_box(plaque_at,Vector3(.022,.32,.26),dark_bronze,_wall_layer)
	var number := Label3D.new()
	number.text = address[kind]
	number.position = plaque_at + Vector3.RIGHT * (.013*sign_side)
	number.rotation.y = sign_side * PI*.5
	number.font_size = 48
	number.pixel_size = .0034
	number.modulate = Color("e7d1a7")
	number.outline_size = 0
	number.double_sided = false
	number.layers = _wall_layer
	_site.add_child(number)
	_track_facade(number,_facade_normal,_facade_room_id)
	var terracotta := _mat("window_box",Color("8d6852"))
	for side: float in [-1.0, 1.0]:
		var sill := Vector3(at.x + sign_side*.18,1.16,at.y + side*2.64)
		_box(sill,Vector3(.18,.23,1.28),terracotta)
		_box(sill + Vector3.UP*.11,Vector3(.21,.043,1.31),terracotta)
		_window_greenery(sill + Vector3(sign_side*.075,.13,0),sign_side,side)
	_facade_normal = Vector2.ZERO
	_facade_room_id = ""


func _window_greenery(origin: Vector3, facing: float, variation: float, layer := 0) -> void:
	if _leaf_mesh == null:_leaf_mesh = _leaves()
	for index in 14:
		var lateral := (index%7-3)*.15
		var trailing := index >= 7
		var point := origin + Vector3(0,-.045 if trailing else .16,lateral)
		var rotation := Vector3(.13*sin(index*3.1),facing*PI*.5,.30*cos(index*2.3+variation))
		var scale := .32 + .09*sin(index*1.42)
		var basis := Basis.from_euler(rotation).scaled(Vector3.ONE*scale)
		_add_instance(_leaf_mesh,Transform3D(basis,point),_world_layer if layer == 0 else layer,false)


func _tree(base: Vector3, height: float, seed_value: int, bark: StandardMaterial3D) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 30001
	_branch(base, base + Vector3(0, height * .78, 0), height * .040, bark)
	if _leaf_mesh == null:
		_leaf_mesh = _leaves()
	for index in 15:
		var angle := float(index) * 2.399963 + rng.randf_range(-.17, .17)
		var ring := height * rng.randf_range(.12, .31) * (1.0 - index * .038)
		var tip := base + Vector3(cos(angle) * ring, height * (.57 + index * .030), sin(angle) * ring)
		if index < 8:
			_branch(base + Vector3.UP * height * (.31 + index * .034), tip,
				height * rng.randf_range(.009, .016), bark)
		for turn in 3:
			var scale := height * rng.randf_range(.20, .36)
			var basis := Basis.from_euler(Vector3(rng.randf_range(-.86, .86), angle + turn * 1.047,
				rng.randf_range(-.68, .68))).scaled(Vector3.ONE * scale)
			_add_instance(_leaf_mesh, Transform3D(basis, tip), _world_layer, true)


func _leaves() -> ArrayMesh:
	var material := _mat("leaf_cards", Color("e3ead0"))
	material.albedo_texture = load(ASSETS + "linden_leaf_cards.png")
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = .48
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.backlight_enabled = true
	material.backlight = Color(.16, .24, .07)
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var quad := QuadMesh.new()
	quad.material = material
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, quad.get_mesh_arrays())
	mesh.surface_set_material(0, material)
	return mesh


func _branch(root: Vector3, tip: Vector3, radius: float, bark: StandardMaterial3D) -> void:
	var mesh_key := "branch_mesh"
	if not _materials.has(mesh_key):
		var mesh := CylinderMesh.new()
		mesh.radial_segments = 6
		mesh.rings = 1
		mesh.height = 1.0
		mesh.bottom_radius = 1.0
		mesh.top_radius = .43
		mesh.material = bark
		_materials[mesh_key] = mesh
	var offset := tip - root
	var axis := offset.normalized()
	var cross_axis := axis.cross(Vector3.FORWARD).normalized()
	var basis := Basis(cross_axis, axis, cross_axis.cross(axis)).scaled_local(
		Vector3(radius, offset.length(), radius))
	_add_instance(_materials[mesh_key], Transform3D(basis, (root + tip) * .5), _world_layer, true)


func _pbr(id: String, color: Color, repeats: float) -> StandardMaterial3D:
	var key := id + color.to_html() + str(repeats)
	if not _materials.has(key):
		_materials[key] = surface(id, color, repeats)
	return _materials[key]


func _mat(id: String, color: Color, roughness := .82) -> StandardMaterial3D:
	if not _materials.has(id):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = roughness
		material.metallic_specular = .29
		_materials[id] = material
	return _materials[id]


func _box(at: Vector3, size: Vector3, material: Material, layer := 0,
		rotate := Vector3.ZERO) -> void:
	if not _materials.has(material):
		var mesh := BoxMesh.new()
		mesh.material = material
		_materials[material] = mesh
	var active_layer := _world_layer if layer == 0 else layer
	var cast_shadow := size.y > .17
	var basis := Basis.from_euler(rotate).scaled_local(size)
	_add_instance(_materials[material], Transform3D(basis, at), active_layer, cast_shadow)


func _add_instance(mesh: Mesh, transform: Transform3D, layer: int, cast_shadow: bool) -> void:
	var at := transform.origin
	var section := Vector2i(floori(at.x / 24.0), floori(at.z / 24.0))
	var room := _facade_room_id if _facade_normal != Vector2.ZERO else ""
	var key := [mesh, layer, cast_shadow, section, _facade_normal, _canopy_id, room]
	if not _batches.has(key):
		_batches[key] = []
	_batches[key].append(transform)
	if not _canopy_id.is_empty():
		var entry: Dictionary = _observer_canopies[_canopy_id]
		var extent := transform * mesh.get_aabb()
		if entry.has("bounds"):
			var previous: AABB = entry.bounds
			extent = previous.merge(extent)
		entry.bounds = extent


func _flush_batches() -> void:
	for key in _batches:
		var transforms: Array = _batches[key]
		var placements := MultiMesh.new()
		placements.transform_format = MultiMesh.TRANSFORM_3D
		placements.mesh = key[0]
		placements.instance_count = transforms.size()
		for index in transforms.size():
			placements.set_instance_transform(index, transforms[index])
		var batch := MultiMeshInstance3D.new()
		batch.multimesh = placements
		batch.layers = key[1]
		if not key[2]:
			batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_site.add_child(batch)
		if not str(key[5]).is_empty():
			_observer_canopies[key[5]].meshes.append(batch)
		elif key[4] != Vector2.ZERO:
			_track_facade(batch,key[4],key[6])


func _track_facade(mesh: GeometryInstance3D, normal: Vector2, room: String) -> void:
	if room.is_empty():
		if not _observer_facades.has(normal):_observer_facades[normal] = []
		_observer_facades[normal].append(mesh)
		return
	if not _observer_room_facades.has(room):_observer_room_facades[room] = {}
	var groups: Dictionary = _observer_room_facades[room]
	if not groups.has(normal):groups[normal] = []
	groups[normal].append(mesh)


static func _point(entry: Dictionary) -> Vector2:
	var value: Array = entry.center
	return Vector2(float(value[0]), float(value[1]))


static func _load_model(id: String) -> Node3D:
	if id.is_empty():
		return null
	var path := ASSETS + id + ".glb"
	if not ResourceLoader.exists(path):
		return null
	var scene := load(path) as PackedScene
	return scene.instantiate() as Node3D if scene != null else null


func _set_model_layer(node: Node3D) -> void:
	for mesh in node.find_children("*", "MeshInstance3D", true, false):
		mesh.layers = _world_layer
