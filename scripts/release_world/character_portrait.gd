extends Node
## Isolated editor stage. Preview changes never affect gameplay perception.
const Cloth=preload("res://scripts/release_world/clothing.gdshader")
const Face=preload("res://scripts/release_world/face_modifier.gd")
var viewport: SubViewport
var camera: Camera3D
var stage: Node3D
var model: Node3D
var pose: Node3D
var _sex: int=-1
var _yaw:=0.15
var _distance:=3.0
var _drag:=false
var _data: Dictionary={}
var _materials: Dictionary={}
var _headshot:=false

func _ready() -> void:
	viewport=SubViewport.new();viewport.size=Vector2i(256,256) if _headshot else Vector2i(400,540);viewport.own_world_3d=true;viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED;viewport.transparent_bg=false;add_child(viewport)
	stage=Node3D.new();viewport.add_child(stage)
	var envn:=WorldEnvironment.new();var env:=Environment.new();env.background_mode=Environment.BG_COLOR;env.background_color=Color("b8d1c2") if _headshot else Color("294451");env.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;env.ambient_light_color=Color("e0e8e0");env.ambient_light_energy=0.8;env.tonemap_mode=Environment.TONE_MAPPER_ACES;envn.environment=env;stage.add_child(envn)
	var key:=DirectionalLight3D.new();key.rotation_degrees=Vector3(-35,-35,0);key.light_energy=0.95;key.light_color=Color("ffe7cf");stage.add_child(key)
	var fill:=DirectionalLight3D.new();fill.rotation_degrees=Vector3(-20,145,0);fill.light_energy=0.4;fill.light_color=Color("a8d2db");stage.add_child(fill)
	var pedestal:=MeshInstance3D.new();var mesh:=CylinderMesh.new();mesh.top_radius=0.58;mesh.bottom_radius=0.66;mesh.height=0.08;pedestal.mesh=mesh;pedestal.position.y=-0.045;var mat:=StandardMaterial3D.new();mat.albedo_color=Color("446669");mat.roughness=0.8;pedestal.material_override=mat;stage.add_child(pedestal)
	pose=Node3D.new();stage.add_child(pose)
	camera=Camera3D.new();camera.fov=42;camera.near=0.08;camera.far=10;viewport.add_child(camera);camera.current=true;_update_camera()

func update_appearance(data: Dictionary) -> Texture2D:
	_data=data.duplicate(true)
	var appearance:Dictionary=_data.get("appearance",{})
	var face:int=int(appearance.get("face",0));var sex:int=posmod(face,2)
	if model==null or _sex!=sex:
		if is_instance_valid(model):model.free()
		var path:String="res://assets/release/characters/human_"+("female" if sex else "male")+".glb"
		if ResourceLoader.exists(path):model=load(path).instantiate();pose.add_child(model);model.rotation.y=PI;_sex=sex
		if model!=null:
			for player in model.find_children("*","AnimationPlayer",true,false):
				var idle:String="Idle_Loop" if player.has_animation("Idle_Loop") else "Idle"
				if player.has_animation(idle):player.get_animation(idle).loop_mode=Animation.LOOP_LINEAR;player.play(idle,0);player.advance(0.3)
				if _headshot:player.pause()
	if model==null:return null
	pose.scale=Vector3(float(appearance.get("build",1)),float(appearance.get("height",1)),float(appearance.get("build",1)))
	var tint:=Color.from_string(str(_data.get("color","83bfa9")),Color("83bfa9"))
	for mesh in model.find_children("*","MeshInstance3D",true,false):
		var name:String=str(mesh.name).to_lower()
		if name.begins_with("hair_"):
			mesh.visible=int(name.trim_prefix("hair_").split(".")[0].split("_")[0])==posmod(int(appearance.get("hair",0)),6)
			var hair:=StandardMaterial3D.new();hair.albedo_color=Color.from_string(str(appearance.get("hair_color","4e3b32")),Color("4e3b32"));hair.roughness=0.8;mesh.material_override=hair
		elif mesh.mesh!=null:
			if name.begins_with("clothing_shirt_"):
				mesh.visible=int(name.trim_prefix("clothing_shirt_").split(".")[0])==posmod(int(appearance.get("outfit",0)),4)
			elif name.begins_with("clothing_shoes_"):
				mesh.visible=int(name.trim_prefix("clothing_shoes_").split(".")[0])==posmod(int(appearance.get("shoes",0)),2)
			for surface in mesh.mesh.get_surface_count():
				var source:Material=mesh.mesh.surface_get_material(surface)
				if not source is StandardMaterial3D:continue
				var mat:StandardMaterial3D=source.duplicate();var mat_name:String=mat.resource_name.to_lower()
				if mat_name.contains("shirt"):
					var cloth:=ShaderMaterial.new();cloth.shader=Cloth;cloth.set_shader_parameter("cloth_color",tint);cloth.set_shader_parameter("accent_color",Color("e7dfc8"));cloth.set_shader_parameter("outfit",0);cloth.set_shader_parameter("fabric_map",load("res://assets/release/textures/fabric_color.png"));cloth.set_shader_parameter("normal_map",load("res://assets/release/textures/fabric_normal.png"));mesh.set_surface_override_material(surface,cloth);continue
				elif mat_name.contains("hair"):mat.albedo_color=Color.from_string(str(appearance.get("hair_color","4e3b32")),Color("4e3b32"))
				elif mat_name.contains("trouser"):mat.albedo_color=[Color("3d4c5b"),Color("ad9d7b"),Color("273439"),tint.darkened(0.4)][posmod(int(appearance.get("outfit",0)),4)]
				elif mat_name.contains("shoe"):mat.albedo_color=Color("64554a") if int(appearance.get("shoes",0))%2 else Color("303940")
				elif mat_name.contains("skin") or mat_name.contains("superhero"):
					var skin:=Color.from_string(str(appearance.get("skin","dfb89e")),Color("dfb89e"));mat.albedo_color=Color(skin.r/0.96,skin.g/0.74,skin.b/0.58,1.0)
				mesh.set_surface_override_material(surface,mat)
	for skeleton in model.find_children("*","Skeleton3D",true,false):
		var modifier:Node=skeleton.get_node_or_null("EditorFaceShape")
		if modifier==null:modifier=Face.new();modifier.name="EditorFaceShape";skeleton.add_child(modifier)
		modifier.variant=posmod(int(face/2),3)
	_update_camera();viewport.render_target_update_mode=SubViewport.UPDATE_ONCE if _headshot else SubViewport.UPDATE_ALWAYS
	return viewport.get_texture()

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
	var target:=Vector3(0,(1.64 if _headshot else 0.95)*height,0)
	var distance:float=.72 if _headshot else _distance
	camera.fov=32 if _headshot else 42
	camera.position=target+Vector3(sin(_yaw)*distance,0.035 if _headshot else 0.08,-cos(_yaw)*distance)
	camera.look_at(target,Vector3.UP)

func set_headshot(value:bool)->void:
	_headshot=value
	if is_instance_valid(viewport):viewport.size=Vector2i(256,256) if value else Vector2i(400,540)
	_update_camera()
