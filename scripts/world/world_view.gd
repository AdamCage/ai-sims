class_name WorldView
extends Node3D
## A single rendered world, shared by the observer and isolated eye-level cameras.
## No rendering operation can change the authoritative simulation state.

const WORLD_LAYER: int = 1
const WALL_LAYER: int = 2
const DEBUG_LAYER: int = 1 << 19
const BODY_LAYERS: Dictionary = {"ada": 4, "boris": 8, "cora": 16}
const ALL_BODIES: int = 4 | 8 | 16

var observer_viewport: SubViewport
var observer_camera: Camera3D
var agent_viewports: Dictionary = {}
var agent_cameras: Dictionary = {}
var agent_nodes: Dictionary = {}
var agent_pose_nodes: Dictionary = {}
var item_nodes: Dictionary = {}
var door_nodes: Dictionary = {}
var selected_agent: String = "ada"
var first_person: bool = false
var _content: Node3D
var _selection_ring: MeshInstance3D
var _last_state: Dictionary = {}

func setup(state: Dictionary) -> void:
	if is_instance_valid(_content):
		_content.free()
	for child in get_children():
		if child is SubViewport:
			child.free()
	agent_viewports.clear()
	agent_cameras.clear()
	agent_nodes.clear()
	agent_pose_nodes.clear()
	item_nodes.clear()
	door_nodes.clear()
	_content = Node3D.new()
	_content.name = "RenderedWorld"
	add_child(_content)
	_build_environment()
	_build_floor()
	_build_geometry(state.get("geometry", {}))
	_build_observer()
	for agent_id in state.get("agents", {}):
		_build_agent(str(agent_id), state.agents[agent_id])
	_build_selection_ring()
	sync_state(state)

func sync_state(state: Dictionary) -> void:
	_last_state = state.duplicate(true)
	for agent_id in state.get("agents", {}):
		var agent: Dictionary = state.agents[agent_id]
		if not agent_nodes.has(agent_id):
			_build_agent(str(agent_id), agent)
		var body: Node3D = agent_nodes[agent_id]
		var point: Array = agent.get("position", [0, 0])
		body.position = Vector3(float(point[0]), 0.0, float(point[1]))
		body.rotation.y = deg_to_rad(float(agent.get("heading", 0)))
		var camera: Camera3D = agent_cameras[agent_id]
		var eye_height: float = 1.55
		var limbs: Dictionary = agent.get("body", {})
		var crawling: bool = limbs.get("left_leg", "healthy") == "broken" and limbs.get("right_leg", "healthy") == "broken"
		var pose: Node3D = agent_pose_nodes[agent_id]
		pose.rotation.x = deg_to_rad(-70.0) if crawling else 0.0
		pose.position = Vector3(0, 0.13, 0.4) if crawling else Vector3.ZERO
		pose.scale = Vector3.ONE * 0.8 if crawling else Vector3.ONE
		if crawling:
			eye_height = 0.55
		camera.position = Vector3(body.position.x, eye_height, body.position.z)
		# A modest downward eye angle keeps nearby floor objects in the image.
		camera.rotation = Vector3(deg_to_rad(-15.0), body.rotation.y, 0.0)
	for item_id in state.get("items", {}):
		var item: Dictionary = state.items[item_id]
		if not item_nodes.has(item_id):
			_build_item(str(item_id), item)
		var node: Node3D = item_nodes[item_id]
		var holder: String = str(item.get("holder", ""))
		node.visible = holder.is_empty()
		var point: Array = item.get("position", [0, 0])
		node.position = Vector3(float(point[0]), 0.0, float(point[1]))
	for item_id in item_nodes.keys():
		if not state.get("items", {}).has(item_id):
			item_nodes[item_id].visible = false
	for door in state.get("geometry", {}).get("doors", []):
		if door_nodes.has(str(door.get("id", ""))):
			door_nodes[str(door.id)].visible = not bool(door.get("open", false))
	_update_selection()

func capture_agent(agent_id: String) -> Image:
	if not agent_viewports.has(agent_id):
		return Image.new()
	var viewport: SubViewport = agent_viewports[agent_id]
	return viewport.get_texture().get_image()

func get_agent_texture(agent_id: String) -> Texture2D:
	if agent_viewports.has(agent_id):
		return agent_viewports[agent_id].get_texture()
	return null

func get_observer_texture() -> Texture2D:
	return observer_viewport.get_texture() if is_instance_valid(observer_viewport) else null

func get_current_texture() -> Texture2D:
	return get_agent_texture(selected_agent) if first_person else get_observer_texture()

func select_agent(id: String) -> void:
	if agent_nodes.has(id):
		selected_agent = id
		_update_selection()

func set_view_mode(value: bool) -> void:
	first_person = value

func _build_environment() -> void:
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("16232e")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("b6d3df")
	environment.ambient_light_energy = 0.68
	environment_node.environment = environment
	_content.add_child(environment_node)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-62, -28, 0)
	sun.light_color = Color("fff1da")
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	_content.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-48, 145, 0)
	fill.light_color = Color("9bbede")
	fill.light_energy = 0.45
	_content.add_child(fill)

func _build_floor() -> void:
	_box(_content, Vector3(18.3, 0.32, 12.3), Vector3(0, -0.19, 0), Color("15212b"))
	_box(_content, Vector3(10.9, 0.08, 11.8), Vector3(-3.5, 0.0, 0), Color("43525b"))
	_box(_content, Vector3(6.8, 0.08, 5.8), Vector3(5.5, 0.0, -3), Color("3e6263"))
	_box(_content, Vector3(6.8, 0.08, 5.8), Vector3(5.5, 0.0, 3), Color("655b50"))
	# Tile seams are material geometry, not informational overlays.
	for x in range(-8, 10, 2):
		_box(_content, Vector3(0.018, 0.005, 11.8), Vector3(float(x), 0.045, 0), Color("3c4b53"))
	for z in range(-4, 6, 2):
		_box(_content, Vector3(17.8, 0.005, 0.018), Vector3(0, 0.045, float(z)), Color("3c4b53"))
	_room_label("COMMON ROOM", Vector3(-3.5, 0.085, 4.7), Color("c2d1d6"))
	_room_label("STORAGE", Vector3(5.5, 0.085, -5.1), Color("a8d9cb"))
	_room_label("SIDE ROOM", Vector3(5.5, 0.085, 4.8), Color("d6c0a6"))

func _build_geometry(geometry: Dictionary) -> void:
	for wall in geometry.get("walls", []):
		var center: Array = wall.get("center", [0, 0])
		var size: Array = wall.get("size", [0.2, 1])
		var height: float = float(wall.get("height", 2.8))
		var point := Vector3(float(center[0]), height * 0.5, float(center[1]))
		_box(_content, Vector3(float(size[0]), height, float(size[1])), point, Color("a6b6b6"), WALL_LAYER)
		_box(_content, Vector3(float(size[0]) + 0.04, 0.18, float(size[1]) + 0.04), Vector3(point.x, 0.09, point.z), Color("92a6aa"))
	for door in geometry.get("doors", []):
		var center: Array = door.get("center", [0, 0])
		var size: Array = door.get("size", [0.2, 1.8])
		var height: float = float(door.get("height", 2.8))
		var panel := Node3D.new()
		_content.add_child(panel)
		panel.position = Vector3(float(center[0]), 0, float(center[1]))
		_box(panel, Vector3(float(size[0]), height, float(size[1])), Vector3(0, height * 0.5, 0), Color("ba945c"), WALL_LAYER)
		_box(panel, Vector3(0.06, 0.13, 0.2), Vector3(-float(size[0]) * 0.5 - 0.025, 1.15, 0.55), Color("f5dda2"), WALL_LAYER)
		door_nodes[str(door.get("id", ""))] = panel
		_box(_content, Vector3(float(size[0]) + 0.1, 0.06, float(size[1])), Vector3(float(center[0]), 0.075, float(center[1])), Color("bf9a61"))

func _build_observer() -> void:
	observer_viewport = _viewport("ObserverViewport", Vector2i(1200, 500))
	observer_camera = Camera3D.new()
	observer_camera.name = "ObserverCamera"
	observer_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	observer_camera.size = 10.0
	observer_camera.cull_mask = WORLD_LAYER | ALL_BODIES | DEBUG_LAYER
	observer_viewport.add_child(observer_camera)
	observer_camera.position = Vector3(4.0, 16.0, 30.0)
	observer_camera.look_at(Vector3(0, 0, 0), Vector3.UP)
	observer_camera.current = true

func _build_agent(agent_id: String, data: Dictionary) -> void:
	var agent_root := Node3D.new()
	agent_root.name = "Body_" + agent_id
	_content.add_child(agent_root)
	agent_nodes[agent_id] = agent_root
	var root := Node3D.new()
	root.name = "Appearance"
	agent_root.add_child(root)
	agent_pose_nodes[agent_id] = root
	var layer: int = int(BODY_LAYERS.get(agent_id, 4))
	var clothing := Color.from_string(str(data.get("color", "e6ae55")), Color("e6ae55"))
	var skin := Color("d5ad8e")
	if agent_id == "boris":
		skin = Color("a87658")
	elif agent_id == "cora":
		skin = Color("ecc4a7")
	# Real mesh variation: coat, hairstyle, shoulders and accessory differ.
	var torso := CapsuleMesh.new()
	torso.radius = 0.25 if agent_id != "boris" else 0.3
	torso.height = 0.8
	_mesh(root, torso, Vector3(0, 0.94, 0), clothing, layer)
	for side in [-1.0, 1.0]:
		var leg := CapsuleMesh.new()
		leg.radius = 0.105
		leg.height = 0.65
		_mesh(root, leg, Vector3(side * 0.13, 0.37, 0), Color("26323e"), layer)
		_box(root, Vector3(0.2, 0.12, 0.32), Vector3(side * 0.13, 0.1, -0.05), Color("17232b"), layer)
		var arm := CapsuleMesh.new()
		arm.radius = 0.085
		arm.height = 0.6
		_mesh(root, arm, Vector3(side * 0.33, 0.93, 0), clothing.darkened(0.08), layer)
		var hand := SphereMesh.new()
		hand.radius = 0.085
		hand.height = 0.17
		_mesh(root, hand, Vector3(side * 0.33, 0.64, -0.015), skin, layer)
	var head := SphereMesh.new()
	head.radius = 0.205
	head.height = 0.42
	_mesh(root, head, Vector3(0, 1.51, 0), skin, layer)
	if agent_id == "ada":
		_box(root, Vector3(0.39, 0.16, 0.37), Vector3(0, 1.67, 0.025), Color("553c32"), layer)
		_box(root, Vector3(0.13, 0.38, 0.16), Vector3(0, 1.49, 0.2), Color("553c32"), layer)
	elif agent_id == "boris":
		_box(root, Vector3(0.43, 0.13, 0.4), Vector3(0, 1.69, 0), Color("27313c"), layer)
		_box(root, Vector3(0.44, 0.045, 0.16), Vector3(0, 1.65, -0.2), clothing, layer)
	else:
		var hair := SphereMesh.new()
		hair.radius = 0.22
		hair.height = 0.28
		_mesh(root, hair, Vector3(0, 1.66, 0.03), Color("a35c3e"), layer)
		_box(root, Vector3(0.48, 0.08, 0.34), Vector3(0, 1.22, 0), Color("e2d3b8"), layer)
	# A small nose and chest stripe make heading readable in real pixels.
	_box(root, Vector3(0.08, 0.09, 0.08), Vector3(0, 1.51, -0.205), skin, layer)
	_box(root, Vector3(0.045, 0.53, 0.025), Vector3(0, 0.96, -0.25), clothing.lightened(0.45), layer)
	var label := Label3D.new()
	label.text = str(data.get("name", agent_id))
	label.position = Vector3(0, 2.05, 0)
	label.font_size = 42
	label.pixel_size = 0.009
	label.modulate = clothing.lightened(0.2)
	label.outline_modulate = Color("15212b")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.layers = DEBUG_LAYER
	agent_root.add_child(label)
	var viewport := _viewport("Eyes_" + agent_id, Vector2i(512, 320))
	agent_viewports[agent_id] = viewport
	var camera := Camera3D.new()
	camera.name = "Camera_" + agent_id
	camera.fov = 80.0
	camera.near = 0.07
	camera.far = 30.0
	camera.cull_mask = WORLD_LAYER | WALL_LAYER | (ALL_BODIES & ~layer)
	viewport.add_child(camera)
	camera.current = true
	agent_cameras[agent_id] = camera

func _build_item(item_id: String, data: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Item_" + item_id
	_content.add_child(root)
	item_nodes[item_id] = root
	var kind: String = str(data.get("kind", "ration"))
	var color := Color("e9ac53") if kind == "ration" else Color("80bccc")
	_box(root, Vector3(0.42, 0.28, 0.34), Vector3(0, 0.2, 0), color)
	_box(root, Vector3(0.44, 0.06, 0.35), Vector3(0, 0.22, 0), color.lightened(0.35))
	_box(root, Vector3(0.17, 0.01, 0.19), Vector3(0, 0.345, 0), Color("f5e8ce"))
	var label := Label3D.new()
	label.text = str(data.get("label", "Item"))
	label.position = Vector3(0, 0.75, 0)
	label.font_size = 27
	label.pixel_size = 0.008
	label.modulate = color.lightened(0.3)
	label.outline_modulate = Color("18222d")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.layers = DEBUG_LAYER
	root.add_child(label)

func _build_selection_ring() -> void:
	_selection_ring = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.46
	ring.outer_radius = 0.5
	ring.rings = 32
	ring.ring_segments = 12
	_selection_ring.mesh = ring
	_selection_ring.material_override = _material(Color("83ead1"))
	_selection_ring.layers = DEBUG_LAYER
	_content.add_child(_selection_ring)

func _update_selection() -> void:
	if is_instance_valid(_selection_ring) and agent_nodes.has(selected_agent):
		_selection_ring.position = agent_nodes[selected_agent].position + Vector3(0, 0.075, 0)

func _viewport(view_name: String, size: Vector2i) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = view_name
	viewport.size = size
	viewport.world_3d = get_world_3d()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = false
	viewport.msaa_3d = Viewport.MSAA_2X
	add_child(viewport)
	return viewport

func _room_label(text: String, point: Vector3, color: Color) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = point
	label.rotation_degrees.x = -90
	label.font_size = 52
	label.pixel_size = 0.011
	label.modulate = color
	label.outline_modulate = color.darkened(0.5)
	label.layers = DEBUG_LAYER
	_content.add_child(label)

func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.88
	return material

func _mesh(parent: Node3D, mesh: Mesh, point: Vector3, color: Color, layer: int = WORLD_LAYER) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = point
	instance.material_override = _material(color)
	instance.layers = layer
	parent.add_child(instance)
	return instance

func _box(parent: Node3D, size: Vector3, point: Vector3, color: Color, layer: int = WORLD_LAYER) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _mesh(parent, mesh, point, color, layer)
