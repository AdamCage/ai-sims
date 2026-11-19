extends Node
## Isolated editor stage. Preview changes never affect gameplay perception.
const Art=preload("res://scripts/release_world/art_direction.gd")
const Face=preload("res://scripts/release_world/face_modifier.gd")
const Finish=preload("res://scripts/release_world/character_finish.gd")
const EDITOR_SIZE := Vector2i(480, 640)
const HEADSHOT_SIZE := Vector2i(320, 320)

var viewport: SubViewport
var camera: Camera3D
var stage: Node3D
var model: Node3D
var pose: Node3D
var _environment: Environment
var _platform: MeshInstance3D
var _sex: int=-1
var _yaw:=0.15
var _distance:=3.0
var _drag:=false
var _data: Dictionary={}
var _headshot:=false
var _skeleton: Skeleton3D
var _idle: AnimationPlayer
var _head := -1
var _face: SkeletonModifier3D
var _preview_time := 0.0

func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = HEADSHOT_SIZE if _headshot else EDITOR_SIZE
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.msaa_3d = Viewport.MSAA_2X
	add_child(viewport)
	stage = Node3D.new()
	viewport.add_child(stage)

	var backdrop := WorldEnvironment.new()
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_COLOR
	_environment.background_color = Color("667b73") if _headshot else Color("293734")
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.ambient_light_color = Color("deebe2")
	_environment.ambient_light_energy = .34
	_environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	backdrop.environment = _environment
	stage.add_child(backdrop)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-36, -144, 0)
	key.light_energy = .72
	key.light_color = Color("fff1d9")
	stage.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-16, 139, 0)
	fill.light_energy = .23
	fill.light_color = Color("a6c6d3")
	stage.add_child(fill)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-48, 20, 0)
	rim.light_energy = .45
	rim.light_color = Color("dce6ee")
	stage.add_child(rim)

	_platform = MeshInstance3D.new()
	var platform := CylinderMesh.new()
	platform.top_radius = .59
	platform.bottom_radius = .64
	platform.height = .085
	platform.radial_segments = 48
	_platform.mesh = platform
	_platform.position.y = -.045
	_platform.visible = not _headshot
	var finish := StandardMaterial3D.new()
	finish.albedo_color = Color("556863")
	finish.roughness = .83
	_platform.material_override = finish
	stage.add_child(_platform)

	pose = Node3D.new()
	stage.add_child(pose)
	camera = Camera3D.new()
	camera.near = .08
	camera.far = 10
	viewport.add_child(camera)
	camera.current = true
	_update_camera()

func update_appearance(data: Dictionary) -> Texture2D:
	_data=data.duplicate(true)
	var appearance:Dictionary=_data.get("appearance",{})
	var face:int=int(appearance.get("face",0));var sex:int=posmod(face,2)
	if model==null or _sex!=sex:
		if is_instance_valid(model):model.free()
		model = null
		_idle = null
		_face = null
		_skeleton = null
		_head = -1
		var path:String="res://assets/release/characters/human_"+("female" if sex else "male")+".glb"
		if ResourceLoader.exists(path):model=load(path).instantiate();pose.add_child(model);model.rotation.y=PI;_sex=sex
		if model!=null:
			var face_pose := Face.new()
			face_pose.name = "EditorFaceShape"
			if face_pose.bind_model(model, "studio"):
				_face = face_pose
			else:
				face_pose.free()
			var players := model.find_children("*", "AnimationPlayer", true, false)
			if not players.is_empty():
				_idle = players[0] as AnimationPlayer
				var idle := "Idle_Loop" if _idle.has_animation("Idle_Loop") else "Idle"
				if _idle.has_animation(idle):
					_idle.get_animation(idle).loop_mode = Animation.LOOP_LINEAR
					_idle.play(idle, 0)
					_idle.advance(0.3)
					if _headshot:
						_idle.pause()
			var skeletons := model.find_children("*", "Skeleton3D", true, false)
			if not skeletons.is_empty():
				_skeleton = skeletons[0] as Skeleton3D
				_head = _skeleton.find_bone("Head")
	if model==null:return null
	pose.scale=Vector3(float(appearance.get("build",1)),float(appearance.get("height",1)),float(appearance.get("build",1)))
	var tint:=Color.from_string(str(_data.get("color","83bfa9")),Color("83bfa9"))
	var outfit := posmod(int(appearance.get("outfit", 0)), 4)
	Finish.apply(model.find_children("*", "MeshInstance3D", true, false), appearance, tint, Art.clothing_material(tint, outfit))
	if is_instance_valid(_face):
		_face.set_face_variant(posmod(int(face/2),3))
		_face.present(0.45 if _headshot else _preview_time, true, true)
	_update_camera();viewport.render_target_update_mode=SubViewport.UPDATE_ONCE if _headshot else SubViewport.UPDATE_ALWAYS
	return viewport.get_texture()

func preview_conversation(source: SkeletonModifier3D, clock: float) -> void:
	if _headshot or not is_instance_valid(_face):
		return
	_preview_time = clock
	_face.copy_context(source)
	_face.present(_preview_time, true, true)

func _process(delta: float) -> void:
	if _headshot or not is_instance_valid(_face) or viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED:
		return
	_preview_time += delta
	_face.present(_preview_time, true)

func suspend() -> void:
	if is_instance_valid(viewport):viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
	if is_instance_valid(model):model.process_mode=Node.PROCESS_MODE_DISABLED

func resume() -> void:
	if is_instance_valid(model):model.process_mode=Node.PROCESS_MODE_INHERIT
	if is_instance_valid(viewport):viewport.render_target_update_mode=SubViewport.UPDATE_ONCE if _headshot else SubViewport.UPDATE_ALWAYS

func handle_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index==MOUSE_BUTTON_LEFT or event.button_index==MOUSE_BUTTON_RIGHT:_drag=event.pressed
		elif event.button_index==MOUSE_BUTTON_WHEEL_UP and event.pressed:_distance=maxf(1.8,_distance*0.9);_update_camera()
		elif event.button_index==MOUSE_BUTTON_WHEEL_DOWN and event.pressed:_distance=minf(4.5,_distance*1.1);_update_camera()
	elif event is InputEventMouseMotion and _drag:_yaw-=event.relative.x*0.012;_update_camera()

func _update_camera() -> void:
	if not is_instance_valid(camera):return
	var height:float=float(_data.get("appearance",{}).get("height",1))
	var target:=Vector3(0,(1.59 if _headshot else 0.95)*height,0)
	if _headshot and is_instance_valid(_skeleton) and _head >= 0:
		target = _skeleton.to_global(_skeleton.get_bone_global_pose(_head).origin) + Vector3.UP * 0.07 * height
	var distance:float=.87 * height if _headshot else _distance
	camera.fov=32 if _headshot else 42
	camera.position=target+Vector3(sin(_yaw)*distance,0.035 if _headshot else 0.08,-cos(_yaw)*distance)
	camera.look_at(target,Vector3.UP)

func set_headshot(value:bool)->void:
	_headshot=value
	if is_instance_valid(viewport):
		viewport.size = HEADSHOT_SIZE if value else EDITOR_SIZE
		_environment.background_color = Color("667b73") if value else Color("293734")
		_platform.visible = not value
	if is_instance_valid(_idle):
		if value:
			_idle.pause()
		else:
			_idle.play()
	_update_camera()
