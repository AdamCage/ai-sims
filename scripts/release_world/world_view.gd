extends Node3D
## Presentation only. Geometry and positions originate in the authoritative session.

signal agent_picked(id: String)
signal portrait_ready(signature: String, texture: Texture2D)

const WORLD := 1
const WALLS := 2
const BODIES := 4
const CAPTURE_BODY := 8
const SELECTED_BODY := 16
const CUTAWAY := 32
const OVERLAY := 1 << 19
const EYES_SIZE := Vector2i(640, 360)
const OutfitShader = preload("res://scripts/release_world/clothing.gdshader")
const PortraitStage = preload("res://scripts/release_world/character_portrait.gd")
const FaceShape = preload("res://scripts/release_world/face_modifier.gd")

var observer_viewport: SubViewport
var observer_camera: Camera3D
var agent_viewports: Dictionary = {}
var agent_cameras: Dictionary = {}
var agent_nodes: Dictionary = {}
var agent_pose_nodes: Dictionary = {}
var item_nodes: Dictionary = {}
var door_nodes: Dictionary = {}
var storage_doors: Dictionary = {}
var selected_agent := ""
var first_person := false
var follow_selected := false
var _content: Node3D
var _state: Dictionary = {}
var _targets: Dictionary = {}
var _players: Dictionary = {}
var _models: Dictionary = {}
var _model_faces: Dictionary = {}
var _animation_keys: Dictionary = {}
var _animation_choices: Dictionary = {}
var _meshes: Dictionary = {}
var _appearances: Dictionary = {}
var _held_markers: Dictionary = {}
var _capture_actor := ""
var _capture_frame := -100
var _focus := Vector3.ZERO
var _yaw := 0.0
var _elevation := 35.0
var _zoom := 21.0
var _drag := 0
var _quality := "medium"
var _selection: MeshInstance3D
var _manifest: Dictionary = {}
var _texture_cache: Dictionary = {}
var _asset_cache: Dictionary = {}
var _screen_viewport: SubViewport
var _screen_label: RichTextLabel
var _screen_title: Label
var _fit_bounds: Array = []
var _user_camera := false
var _portrait: Node
var _grounding_viewport: SubViewport
var _grounding_background: TextureRect
var _grounding_badges: Array=[]
var _grounding_generation: int=0
var human_viewport: SubViewport
var human_camera: Camera3D
var _display_size := Vector2i(1440,940)
var _hud_portrait: Node
var _portrait_cache: Dictionary = {}
var _portrait_pending := ""
var _labels: Array = []
var _facades: Array = []
var _last_facade_yaw := INF
var _notice_boards: Dictionary = {}
var _material_cache: Dictionary = {}
var _visual_event_cursor := -1
var _action_feedback: Dictionary = {}
var _speech_bubbles: Dictionary = {}

func setup(state: Dictionary) -> void:
	_grounding_generation+=1
	_grounding_badges.clear()
	_facades.clear();_last_facade_yaw=INF;_labels.clear();_notice_boards.clear();_portrait_pending="";_material_cache.clear();_action_feedback.clear();_speech_bubbles.clear();_visual_event_cursor=-1
	for child in get_children():
		child.free()
	agent_viewports.clear()
	agent_cameras.clear()
	agent_nodes.clear()
	agent_pose_nodes.clear()
	item_nodes.clear()
	door_nodes.clear()
	storage_doors.clear()
	_players.clear()
	_models.clear()
	_model_faces.clear()
	_animation_keys.clear()
	_animation_choices.clear()
	_meshes.clear()
	_appearances.clear()
	_held_markers.clear()
	_capture_actor = ""
	_manifest = _load_manifest()
	_user_camera=false
	_state = state.duplicate(true)
	_content = Node3D.new()
	_content.name = "LivingWorld"
	add_child(_content)
	_environment()
	_build_map(state.get("geometry", {}))
	_build_observer(state.get("geometry", {}))
	for id in state.get("agents", {}):
		_build_agent(str(id), state.agents[id])
	if selected_agent.is_empty() or not agent_nodes.has(selected_agent):
		selected_agent = str(state.get("agents", {}).keys()[0]) if not state.get("agents", {}).is_empty() else ""
	_selection = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.38
	ring.outer_radius = 0.43
	ring.rings = 36
	ring.ring_segments = 10
	_selection.mesh = ring
	_selection.material_override = _material(Color("eecf83"))
	_selection.layers = OVERLAY
	_content.add_child(_selection)
	_build_screen()
	select_agent(selected_agent)
	sync_state(state, true)
	if agent_nodes.has(selected_agent):
		_focus=agent_nodes[selected_agent].position+Vector3.UP*0.7;_zoom=8.0;_user_camera=true;follow_selected=true;_update_observer()

func sync_state(state: Dictionary, immediate: bool = false) -> void:
	_state = state.duplicate(true)
	_sync_action_feedback(state)
	for id in state.get("agents", {}):
		var data: Dictionary = state.agents[id]
		if not agent_nodes.has(id):
			_build_agent(str(id), data)
		var pos: Array = data.get("position", [0, 0])
		var lift: float=float(data.get("surface_height",0.0))+(0.8 if not str(data.get("carried_by","")).is_empty() else 0.0)
		_targets[id] = {"position": Vector3(float(pos[0]), lift, float(pos[1])), "heading":deg_to_rad(float(data.get("heading", 0)))}
		if immediate:
			agent_nodes[id].position = _targets[id].position
			agent_nodes[id].rotation.y = _targets[id].heading
		_apply_appearance(str(id), data.get("appearance", {}), str(data.get("color", "83bfa9")))
		_apply_pose(str(id), data)
		_sync_camera(str(id), true)
	for id in state.get("items", {}):
		var item: Dictionary = state.items[id]
		if not item_nodes.has(id):
			_build_item(str(id), item)
		_sync_item(str(id), item)
	for id in item_nodes:
		if not state.get("items", {}).has(id):
			item_nodes[id].visible = false
	for door in state.get("geometry", {}).get("doors", []):
		if door_nodes.has(str(door.get("id", ""))):
			var pivot: Node3D = door_nodes[str(door.id)]
			pivot.rotation.y = deg_to_rad(90.0) if bool(door.get("open", false)) else 0.0
	for prop in state.get("geometry",{}).get("props",[]):
		if storage_doors.has(str(prop.get("id",""))):storage_doors[str(prop.id)].rotation.y=deg_to_rad(-105) if prop.get("open",false) else 0.0
		if _notice_boards.has(str(prop.get("id",""))):
			var paper:Label3D=_notice_boards[str(prop.id)]
			paper.text=str(prop.get("label",""))+"\n\n"+str(prop.get("document",prop.get("text","")))
	_update_selection()
	_sync_human_camera()
	_update_labels()

func _process(delta: float) -> void:
	for id in _targets:
		if not agent_nodes.has(id):
			continue
		var body: Node3D = agent_nodes[id]
		var distance: float = body.position.distance_to(_targets[id].position)
		body.position = body.position.lerp(_targets[id].position, minf(1.0, delta * 12.0))
		body.rotation.y = lerp_angle(body.rotation.y, float(_targets[id].heading), minf(1.0, delta * 12.0))
		if _state.get("agents", {}).has(id):
			_animate(str(id), _state.agents[id], distance > 0.015)
		_sync_camera(str(id), id==_capture_actor and Engine.get_frames_drawn()<=_capture_frame+1)
	for id in _state.get("items", {}):
		if item_nodes.has(id):
			_sync_item(str(id), _state.items[id])
	if follow_selected and agent_nodes.has(selected_agent):
		_focus = _focus.lerp(agent_nodes[selected_agent].position+Vector3.UP*.7, minf(1.0, delta * 6.0))
		_update_observer()
	_update_selection()
	_sync_human_camera()
	_update_labels()

func prepare_capture(id: String) -> void:
	# One extra eye viewport is requested per frame. Other eyes remain dormant.
	if not agent_viewports.has(id):
		return
	if not _capture_actor.is_empty() and _capture_actor != selected_agent:
		_set_body_layer(_capture_actor, BODIES)
	_capture_actor = id
	_capture_frame = Engine.get_frames_drawn()
	if id != selected_agent:
		_set_body_layer(id, CAPTURE_BODY)
	_sync_camera(id, true)
	var camera: Camera3D = agent_cameras[id]
	camera.cull_mask = WORLD | WALLS | BODIES | (CAPTURE_BODY if id == selected_agent else SELECTED_BODY)
	agent_viewports[id].render_target_update_mode = SubViewport.UPDATE_ONCE

func capture_agent(id: String) -> Image:
	if not agent_viewports.has(id):
		return Image.new()
	var result: Image=agent_viewports[id].get_texture().get_image()
	if id==_capture_actor: _capture_frame=-100
	return result

func grounding_image(image: Image, targets: Array) -> Image:
	# Derived AI helper only. Input pixels, photos and the 3D scene are never edited.
	if image==null or image.is_empty() or targets.is_empty():return null
	var validated:Array=[]
	var seen:Dictionary={}
	var pattern:=RegEx.create_from_string("^v[0-9]+$")
	for entry in targets.slice(0,64):
		if not entry is Dictionary:continue
		var ref:Variant=entry.get("ref",null)
		var uv:Variant=entry.get("uv",null)
		if not ref is String or pattern.search(ref)==null or seen.has(ref):continue
		if not uv is Array or uv.size()!=2:continue
		if not (uv[0] is float or uv[0] is int) or not (uv[1] is float or uv[1] is int):continue
		var u:float=float(uv[0]);var v:float=float(uv[1])
		if not is_finite(u) or not is_finite(v) or u<0.0 or u>1.0 or v<0.0 or v>1.0:continue
		validated.append({"ref":ref,"position":Vector2(u,v)*Vector2(EYES_SIZE)});seen[ref]=true
	if validated.is_empty():return null
	_grounding_generation+=1
	var generation:int=_grounding_generation
	if not is_instance_valid(_grounding_viewport):
		_grounding_viewport=SubViewport.new();_grounding_viewport.name="PrivateAIGroundingHelper";_grounding_viewport.size=EYES_SIZE;_grounding_viewport.disable_3d=true
		_grounding_viewport.gui_disable_input=true;_grounding_viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED;add_child(_grounding_viewport)
		_grounding_background=TextureRect.new();_grounding_background.size=Vector2(EYES_SIZE);_grounding_background.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
		_grounding_background.stretch_mode=TextureRect.STRETCH_SCALE;_grounding_background.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST;_grounding_viewport.add_child(_grounding_background)
	_grounding_background.texture=ImageTexture.create_from_image(image)
	for badge in _grounding_badges:badge.hide()
	for index in validated.size():
		var badge:Label
		if index<_grounding_badges.size():badge=_grounding_badges[index]
		else:
			badge=Label.new();badge.clip_text=true;badge.mouse_filter=Control.MOUSE_FILTER_IGNORE;badge.add_theme_font_size_override("font_size",16)
			badge.add_theme_color_override("font_color",Color("fff0ac"));badge.vertical_alignment=VERTICAL_ALIGNMENT_CENTER;badge.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
			var style:=StyleBoxFlat.new();style.bg_color=Color("14222a");style.border_color=Color("f2d78d");style.set_border_width_all(1);style.set_corner_radius_all(3)
			badge.add_theme_stylebox_override("normal",style);_grounding_viewport.add_child(badge);_grounding_badges.append(badge)
		var target:Dictionary=validated[index]
		var width:float=clampf(float(str(target.ref).length())*10.0+12.0,32.0,112.0)
		badge.text=target.ref;badge.size=Vector2(width,24)
		badge.position=Vector2(clampf(target.position.x+8.0,0.0,float(EYES_SIZE.x)-width),clampf(target.position.y-28.0,0.0,float(EYES_SIZE.y)-24.0));badge.show()
	_grounding_viewport.render_target_update_mode=SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	if generation!=_grounding_generation or not is_instance_valid(_grounding_viewport):return null
	return _grounding_viewport.get_texture().get_image()

func agent_texture(id: String) -> Texture2D:
	return agent_viewports[id].get_texture() if agent_viewports.has(id) else null

func observer_texture() -> Texture2D:
	return observer_viewport.get_texture() if is_instance_valid(observer_viewport) else null

func current_texture() -> Texture2D:
	return human_viewport.get_texture() if first_person and is_instance_valid(human_viewport) else observer_texture()

func select_agent(id: String) -> void:
	if not agent_nodes.has(id):
		return
	if not selected_agent.is_empty() and agent_nodes.has(selected_agent):
		_set_body_layer(selected_agent, CAPTURE_BODY if selected_agent==_capture_actor and Engine.get_frames_drawn()<=_capture_frame+1 else BODIES)
		if agent_viewports.has(selected_agent):
			agent_viewports[selected_agent].render_target_update_mode = SubViewport.UPDATE_DISABLED
	selected_agent = id
	_set_body_layer(id, SELECTED_BODY)
	agent_cameras[id].cull_mask = WORLD | WALLS | BODIES | CAPTURE_BODY
	agent_viewports[id].render_target_update_mode = SubViewport.UPDATE_DISABLED
	if not _capture_actor.is_empty() and agent_cameras.has(_capture_actor):
		agent_cameras[_capture_actor].cull_mask=WORLD|WALLS|BODIES|(CAPTURE_BODY if _capture_actor==selected_agent else SELECTED_BODY)
	_sync_human_camera()
	_update_selection()

func set_first_person(value: bool) -> void:
	first_person = value
	if is_instance_valid(observer_viewport):observer_viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED if value else SubViewport.UPDATE_ALWAYS
	if is_instance_valid(human_viewport):human_viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS if value else SubViewport.UPDATE_DISABLED
	_sync_human_camera()

func set_quality(preset: String) -> void:
	_quality = preset
	var mode: int = Viewport.MSAA_DISABLED if preset == "low" else Viewport.MSAA_2X
	if is_instance_valid(observer_viewport):
		observer_viewport.msaa_3d = mode
	for viewport in agent_viewports.values():
		viewport.msaa_3d = Viewport.MSAA_DISABLED
	if is_instance_valid(human_viewport):human_viewport.msaa_3d=mode
	set_display_size(_display_size)
	for light in _content.find_children("*","DirectionalLight3D",true,false):
		if light.name=="Sun":light.shadow_enabled=preset!="low"

func set_display_size(value:Vector2i) -> void:
	_display_size=Vector2i(maxi(320,value.x),maxi(240,value.y))
	var limit:Vector2i={"low":Vector2i(1280,720),"medium":Vector2i(1920,1080),"high":Vector2i(2560,1440)}.get(_quality,Vector2i(1920,1080))
	var factor:float=minf(1.0,minf(float(limit.x)/_display_size.x,float(limit.y)/_display_size.y))
	var pixels:=Vector2i(maxi(320,roundi(_display_size.x*factor)),maxi(240,roundi(_display_size.y*factor)))
	if is_instance_valid(observer_viewport):observer_viewport.size=pixels
	if is_instance_valid(human_viewport):human_viewport.size=pixels
	_update_observer()

func appearance_capabilities() -> Dictionary:
	return {"faces":6,"hairs":6,"outfits":4,"shoes":2}

func character_portrait(data:Dictionary) -> Texture2D:
	if DisplayServer.get_name()=="headless":return null
	var signature:=JSON.stringify(data.get("appearance",{}))+str(data.get("color",""))
	if _portrait_cache.has(signature):return _portrait_cache[signature]
	if _portrait_pending.is_empty():_render_portrait(data,signature)
	return null

func _render_portrait(data:Dictionary,signature:String) -> void:
	_portrait_pending=signature
	if not is_instance_valid(_hud_portrait):_hud_portrait=PortraitStage.new();_hud_portrait.name="HUDPortraitStage";add_child(_hud_portrait)
	if _hud_portrait.has_method("set_headshot"):_hud_portrait.set_headshot(true)
	_hud_portrait.resume();_hud_portrait.update_appearance(data)
	await RenderingServer.frame_post_draw
	if not is_instance_valid(_hud_portrait) or _portrait_pending!=signature:return
	var image:Image=_hud_portrait.viewport.get_texture().get_image()
	if image!=null and not image.is_empty():
		_portrait_cache[signature]=ImageTexture.create_from_image(image)
		portrait_ready.emit(signature,_portrait_cache[signature])
	_hud_portrait.suspend();_portrait_pending=""

func _sync_human_camera() -> void:
	if not is_instance_valid(human_camera) or not agent_cameras.has(selected_agent):return
	human_camera.transform=agent_cameras[selected_agent].transform
	human_camera.fov=agent_cameras[selected_agent].fov
	human_camera.cull_mask=WORLD|WALLS|BODIES|CAPTURE_BODY

func focus_position(point:Array) -> void:
	if point.size()<2:return
	_focus=Vector3(float(point[0]),0,float(point[1]));follow_selected=false;_user_camera=true;_zoom=minf(_zoom,18.0);_update_observer()

func show_map() -> void:
	follow_selected=false;_user_camera=true
	if _fit_bounds.size()==4:_focus=Vector3((float(_fit_bounds[0])+float(_fit_bounds[1]))*0.5,0,(float(_fit_bounds[2])+float(_fit_bounds[3]))*0.5)
	_fit_observer()

func freeze_presentation(value: bool) -> void:
	set_process(not value)
	for player in _players.values():
		if value: player.pause()
		elif not player.current_animation.is_empty(): player.play()

func set_perception_candidates(id: String, candidates: Array) -> void:
	_targets["candidates_" + id] = candidates.duplicate(true)

func enrich_observation(id: String, observation: Dictionary) -> Dictionary:
	var result: Dictionary = observation.duplicate(true)
	result["targets"] = []
	if not agent_cameras.has(id) or bool(result.get("self_state", {}).get("body", {}).get("blind", false)):
		result["mock_view"] = []
		return result
	_sync_camera(id, true)
	var camera: Camera3D = agent_cameras[id]
	var candidates: Array = _targets.get("candidates_" + id, [])
	if candidates.is_empty():
		var origin: Vector3 = _targets.get(id, {}).get("position", Vector3.ZERO)
		var heading: float = float(_targets.get(id, {}).get("heading", 0.0))
		for visible in result.get("mock_view", []):
			var angle: float = heading + deg_to_rad(float(visible.get("bearing", 0)))
			var point := origin + Vector3(-sin(angle), 0, -cos(angle)) * float(visible.get("distance", 0))
			candidates.append({"ref":str(visible.get("ref", "")),"position":[point.x,point.z],"height":1.0 if visible.get("kind") in ["agent","person"] else 0.35})
	var valid_refs: Array = []
	for candidate in candidates:
		var pos: Array = candidate.get("position", [0, 0])
		var point := Vector3(float(pos[0]), float(candidate.get("height", 0.5)), float(pos[1]))
		if camera.is_position_behind(point):
			continue
		var pixel: Vector2 = camera.unproject_position(point)
		var uv: Vector2 = pixel / Vector2(EYES_SIZE)
		if uv.x < 0 or uv.y < 0 or uv.x > 1 or uv.y > 1:
			continue
		var ref: String = str(candidate.get("ref", ""))
		valid_refs.append(ref)
		result.targets.append({"ref":ref,"uv":[snappedf(uv.x,0.001),snappedf(uv.y,0.001)]})
	var filtered: Array = []
	for visible in result.get("mock_view", []):
		if valid_refs.has(str(visible.get("ref", ""))):
			filtered.append(visible)
	result["mock_view"] = filtered
	return result

func handle_view_input(event: InputEvent, _size: Vector2 = Vector2.ZERO) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed and not first_person:
			var source_size:=Vector2(observer_viewport.size)
			var factor: float=minf(_size.x/source_size.x,_size.y/source_size.y) if _size.x>0 and _size.y>0 else 1.0
			var offset: Vector2=(_size-source_size*factor)*0.5
			var point: Vector2=(event.position-offset)/factor
			var nearest: String=""; var closest: float=40.0
			for id in agent_nodes:
				var body_point: Vector3=agent_nodes[id].position+Vector3(0,1.0,0)
				if observer_camera.is_position_behind(body_point):continue
				var distance: float=observer_camera.unproject_position(body_point).distance_to(point)
				if distance<closest:closest=distance;nearest=str(id)
			if not nearest.is_empty():agent_picked.emit(nearest)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_user_camera=true
			_zoom = maxf(7.0, _zoom * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_user_camera=true
			_zoom = minf(140.0, _zoom * 1.1)
		elif event.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_drag = event.button_index if event.pressed else 0
		_update_observer()
	elif event is InputEventMouseMotion and _drag != 0:
		_user_camera=true
		follow_selected = false
		if _drag == MOUSE_BUTTON_RIGHT:
			_yaw -= event.relative.x * 0.006
			_elevation = clampf(_elevation + event.relative.y * 0.15, 28, 82)
		else:
			var right := Vector3(cos(_yaw),0,-sin(_yaw))
			var back := Vector3(sin(_yaw),0,cos(_yaw))
			_focus += (-right * event.relative.x - back * event.relative.y) * _zoom * 0.0015
		_update_observer()

func focus_agent() -> void:
	if agent_nodes.has(selected_agent):
		_focus = agent_nodes[selected_agent].position
		_zoom=minf(_zoom,8.0);_user_camera=true
		follow_selected = true
		_update_observer()

func prepare_device_screen(title: String, body: String) -> void:
	if is_instance_valid(_screen_title):
		_screen_title.text = title
		_screen_label.text = body
		_screen_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func capture_device_screen() -> Image:
	return _screen_viewport.get_texture().get_image() if is_instance_valid(_screen_viewport) else Image.new()

func preview_character(data: Dictionary) -> Texture2D:
	if not is_instance_valid(_portrait):_portrait=PortraitStage.new();add_child(_portrait)
	_portrait.resume()
	return _portrait.update_appearance(data)

func suspend_character_preview() -> void:
	if is_instance_valid(_portrait):_portrait.suspend()

func handle_character_preview_input(event: InputEvent) -> void:
	if is_instance_valid(_portrait):_portrait.handle_input(event)

func _environment() -> void:
	var node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("293c47")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("dce5ed")
	env.ambient_light_energy = 0.36
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	node.environment = env
	_content.add_child(node)
	var sun := DirectionalLight3D.new()
	sun.name="Sun"
	sun.rotation_degrees = Vector3(-48, -32, 0)
	sun.light_color = Color("ffe5c2")
	sun.light_energy = 0.52
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 48
	_content.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-48, 145, 0)
	fill.light_color = Color("aac6e8")
	fill.light_energy = 0.1
	_content.add_child(fill)

func _build_map(geometry: Dictionary) -> void:
	var bounds: Array = geometry.get("bounds", [-12,12,-9,9])
	var width: float = float(bounds[1])-float(bounds[0])
	var depth: float = float(bounds[3])-float(bounds[2])
	var center := Vector3((float(bounds[0])+float(bounds[1]))*0.5,0,(float(bounds[2])+float(bounds[3]))*0.5)
	_box(_content, Vector3(width+0.7,0.45,depth+0.7), center+Vector3(0,-0.28,0), Color("343b48"))
	var palette:String=str(geometry.get("palette","teal"))
	var palette_ground:Color={"warm":Color("bfa88d"),"blue":Color("9aaaaf")}.get(palette,Color("9eaaa1"))
	var palette_trim:Color={"warm":Color("a06452"),"blue":Color("467286")}.get(palette,Color("47716e"))
	var floor_mesh: MeshInstance3D = _box(_content, Vector3(width,0.12,depth),center+Vector3(0,-0.04,0),Color("c9c2ad"))
	floor_mesh.material_override = _surface_material("floor",palette_ground)
	for wall in geometry.get("walls", []):
		var p: Array = wall.get("center",[0,0])
		var s: Array = wall.get("size",[0.2,1.0])
		var h: float = float(wall.get("height",3.0))
		var wall_mesh := _box(_content,Vector3(float(s[0]),h,float(s[1])),Vector3(float(p[0]),h*0.5,float(p[1])),Color("c9c5b7"),WALLS)
		wall_mesh.material_override = _surface_material("wall",Color("d4c8af") if palette=="warm" else Color("b9c6c9"))
		_box(_content,Vector3(float(s[0])+0.06,0.22,float(s[1])+0.06),Vector3(float(p[0]),0.11,float(p[1])),palette_trim.darkened(0.28),WORLD)
		_box(_content,Vector3(float(s[0])+0.07,0.08,float(s[1])+0.07),Vector3(float(p[0]),h-0.04,float(p[1])),palette_trim,WALLS)
		_shape_facade(wall_mesh,geometry.get("rooms",[]),Vector2(float(p[0]),float(p[1])),Vector2(float(s[0]),float(s[1])),h,palette_trim,palette)
	for door in geometry.get("doors", []):
		var p: Array = door.get("center",[0,0])
		var s: Array = door.get("size",[0.2,1.6])
		var pivot := Node3D.new()
		pivot.position = Vector3(float(p[0]),0,float(p[1]))
		_content.add_child(pivot)
		var panel := _box(pivot,Vector3(float(s[0]),2.65,float(s[1])),Vector3(0,1.325,0),Color("8c6951"),WALLS)
		panel.material_override = _surface_material("wood",Color("a17b56"),1.0)
		_box(pivot,Vector3(float(s[0])+0.04,0.28,float(s[1])*0.65),Vector3(0,1.6,0),Color("547e82"),WALLS)
		_box(pivot,Vector3(0.08,0.09,0.24),Vector3(-float(s[0])*0.6,1.05,float(s[1])*0.32),Color("d5c292"),WALLS)
		door_nodes[str(door.get("id", ""))] = pivot
		_box(_content,Vector3(float(s[0])+0.15,0.05,float(s[1])+0.1),Vector3(float(p[0]),0.04,float(p[1])),Color("caa969"))
	for prop in geometry.get("props", []):
		_build_prop(prop)
	for room in geometry.get("rooms", []):
		var pos: Array = room.get("center",[0,0])
		var room_size: Array = room.get("size",[4,4])
		var room_name: String = str(room.get("label",room.get("name","")))
		var function:String=str(room.get("function",""))
		var base_material:String="floor"
		if function in ["bedroom","common","shop"] or palette=="warm":base_material="wood"
		if function in ["medical","kitchen","lab"]:base_material="tile"
		if palette=="blue" and function in ["workshop","arrival","evacuation","comms"]:base_material="metal"
		if palette=="blue" and function in ["bedroom","common","supply"]:base_material="tile"
		var tint:Color={"bedroom":Color("dcc3a0"),"medical":Color("acbfc3"),"kitchen":Color("d2c4a4"),"lab":Color("a9bbc6"),"reserve":Color("b6b4ad"),"supply":Color("c3afa0")}.get(function,Color("bdc6ba"))
		var room_floor := _box(_content,Vector3(float(room_size[0])-0.25,0.018,float(room_size[1])-0.25),Vector3(float(pos[0]),0.035,float(pos[1])),Color.WHITE)
		room_floor.material_override = _surface_material(base_material,tint)
		if function in ["common","bedroom"]:
			var rug_width:=minf(float(room_size[0])*.64,5.0)
			var rug_depth:=minf(float(room_size[1])*.36,3.4)
			var rug_center:=Vector3(float(pos[0]),.05,float(pos[1])-.4)
			var rug:=_box(_content,Vector3(rug_width,.008,rug_depth),rug_center,Color.WHITE)
			var woven:Color={"teal":Color("53756b"),"warm":Color("a2644e"),"blue":Color("53677b")}.get(palette,Color("647566"))
			rug.material_override=_surface_material("fabric",woven)
			for side in [-1,1]:
				for stripe in [0.08,0.17]:
					var trim:=_box(_content,Vector3(.045,.004,rug_depth-.05),rug_center+Vector3(side*(rug_width*.5-stripe),.007,0),Color.WHITE)
					trim.material_override=_surface_material("fabric",Color("b6a180"))
		_label(_content,str(room.get("label",room.get("name",""))),Vector3(float(pos[0]),0.1,float(pos[1])),Color("dfe0c7"),0.009,true)

# Keep physical walls in each agent camera. The observer sees the far walls of
# each room, including their fixtures, and a low sill along the near side.
func _shape_facade(wall:MeshInstance3D, rooms:Array, at:Vector2, size:Vector2, h:float, accent:Color, palette:String) -> void:
	var along_x:=size.x>size.y
	var outward:=Vector2.ZERO
	var room_label:=""
	for room in rooms:
		var rc:Array=room.get("center",[]);var dims:Array=room.get("size",[])
		if rc.size()!=2 or dims.size()!=2:continue
		var delta:=at-Vector2(rc[0],rc[1]);var half:=Vector2(dims[0],dims[1])*.5
		if along_x and absf(absf(delta.y)-half.y)<.18 and absf(delta.x)<=half.x:
			outward=Vector2(0,signf(delta.y));room_label=str(room.get("label",""));break
		if not along_x and absf(absf(delta.x)-half.x)<.18 and absf(delta.y)<=half.y:
			outward=Vector2(signf(delta.x),0);room_label=str(room.get("label",""));break
	if outward==Vector2.ZERO:return
	var faces:Array=[wall]
	var length:float=maxf(size.x,size.y)
	var base:=Vector3(at.x,0,at.y)
	var normal:=Vector3(outward.x,0,outward.y)
	var tangent:=Vector3(1,0,0) if along_x else Vector3(0,0,1)
	var band:Vector3=Vector3(size.x+.024,.13,size.y+.024)
	faces.append(_box(_content,band,base+Vector3.UP*.91,accent,WALLS))
	# Flush panels and transoms stay within the building's collision footprint.
	if length>3.8:
		var span:=minf(length*.62,4.8)
		var frame_size:=Vector3(span,1.08,.055) if along_x else Vector3(.055,1.08,span)
		var centre:=base+Vector3.UP*(h*.65)-normal*.128
		faces.append(_box(_content,frame_size,centre,accent.darkened(.43),WALLS))
		var pane_size:=Vector3(span*.47,.91,.025) if along_x else Vector3(.025,.91,span*.47)
		for side in [-1,1]:faces.append(_box(_content,pane_size,centre-normal*.04+tangent*float(side)*span*.245,Color("819399") if palette!="warm" else Color("9bafad"),WALLS))
		var bar:=Vector3(span,.043,.034) if along_x else Vector3(.034,.043,span)
		faces.append(_box(_content,bar,centre-normal*.063+Vector3.UP*(.13 if palette=="warm" else .31),accent.darkened(.37),WALLS))
		if length>8.7:
			var plaque:=Vector3(1.38,.41,.044) if along_x else Vector3(.044,.41,1.38)
			var mount:=centre+tangent*(span*.5+.97)-normal*.03
			faces.append(_box(_content,plaque,mount,accent.darkened(.5),WALLS))
			var sign:=Label3D.new();sign.text=room_label;sign.layers=WALLS;sign.font_size=32;sign.pixel_size=.0035;sign.width=345;sign.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;sign.outline_size=0;sign.double_sided=false;sign.modulate=Color("efe6cb")
			sign.position=mount-normal*.033;sign.rotation.y=atan2(-normal.x,-normal.z);_content.add_child(sign);faces.append(sign)
	_facades.append({"normal":outward,"meshes":faces})

func _update_facades() -> void:
	if is_finite(_last_facade_yaw) and is_equal_approx(_last_facade_yaw,_yaw):return
	_last_facade_yaw=_yaw
	var direction:=Vector2(sin(_yaw),cos(_yaw))
	for facade in _facades:
		var layer:int=WALLS|CUTAWAY if facade.normal.dot(direction)<-0.12 else WALLS
		for mesh in facade.meshes:mesh.layers=layer

func _build_prop(prop: Dictionary) -> void:
	var kind: String = str(prop.get("kind", "table"))
	var p: Array = prop.get("center",[0,0])
	var s: Array = prop.get("size",[1.0,1.0])
	var height: float = float(prop.get("height",0.8))
	var root := Node3D.new()
	root.name = "Prop_"+str(prop.get("id",kind))
	root.position = Vector3(float(p[0]),0,float(p[1]))
	root.rotation.y = deg_to_rad(float(prop.get("angle",0)))
	_content.add_child(root)
	if kind in ["terminal","shop"]:_service_signage(root,kind,Vector2(float(s[0]),float(s[1])),height)
	var asset: Node3D = _instantiate_asset(kind)
	if asset != null:
		root.add_child(asset)
		_fit_asset(asset,Vector3(float(s[0]),height,float(s[1])))
		_dress_prop(asset)
		if kind in ["table","desk","counter"]:
			_table_details(root,kind,Vector2(float(s[0]),float(s[1])),height)
		if kind in ["wardrobe","cabinet"] and prop.get("storage",false):
			var hinge:=Node3D.new();hinge.position=Vector3(-float(s[0])*0.5,0,-float(s[1])*0.5-0.03);root.add_child(hinge)
			var panel:=_box(hinge,Vector3(float(s[0]),height,0.05),Vector3(float(s[0])*0.5,height*0.5,0),Color("8a7461"));panel.material_override=_surface_material("wood",Color("9c8770"),1.2)
			storage_doors[str(prop.get("id",""))]=hinge
		if kind=="noticeboard":
			var notice:=Label3D.new();notice.name="PrintedNotice";notice.layers=WORLD;notice.position=Vector3(0,height*.715,float(s[1])*.5+.008);notice.font_size=30;notice.pixel_size=.00053;notice.width=1120;notice.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;notice.double_sided=false;notice.outline_size=0;notice.modulate=Color("24363b");root.add_child(notice);_notice_boards[str(prop.id)]=notice
		if kind in ["console","labdesk"] and not str(_manifest.get("models",{}).get(kind,"")).contains("alpha_"):
			var screen:=_instantiate_asset("monitor")
			if screen!=null:root.add_child(screen);_fit_asset(screen,Vector3(minf(0.9,float(s[0])*0.6),0.55,0.22));screen.position+=Vector3(0,height,0)
		return
	var wood := _surface_material("wood",Color("9e7956"),1.0)
	var fabric := _surface_material("fabric",Color("547e85"),1.0)
	match kind:
		"bed", "bunk", "hospital_bed":
			_box(root,Vector3(float(s[0]),0.28,float(s[1])),Vector3(0,0.22,0),Color("586c70"))
			var mattress := _box(root,Vector3(float(s[0])*0.94,0.25,float(s[1])*0.93),Vector3(0,0.48,0),Color("ebe4cc"))
			mattress.material_override = fabric
			_box(root,Vector3(float(s[0])*0.8,0.16,float(s[1])*0.23),Vector3(0,0.66,-float(s[1])*0.3),Color("ece9dd"))
		"shelf", "locker", "cabinet":
			for side in [-1.0,1.0]:
				_box(root,Vector3(0.08,height,float(s[1])),Vector3(side*(float(s[0])*0.5-0.04),height*0.5,0),Color("63797b"))
			for level in range(4):
				var shelf := _box(root,Vector3(float(s[0]),0.07,float(s[1])),Vector3(0,0.15+float(level)*(height-0.22)/3,0),Color("b09972"))
				shelf.material_override = wood
			_box(root,Vector3(float(s[0]),height,0.04),Vector3(0,height*0.5,float(s[1])*0.5),Color("738480"))
		"terminal", "computer", "shop":
			_box(root,Vector3(float(s[0]),height*0.55,float(s[1])),Vector3(0,height*0.275,0),Color("586c73"))
			_box(root,Vector3(float(s[0])*0.92,height*0.4,0.13),Vector3(0,height*0.78,-float(s[1])*0.15),Color("293d43"))
			_box(root,Vector3(float(s[0])*0.75,height*0.27,0.015),Vector3(0,height*0.78,-float(s[1])*0.15-0.075),Color("8bd4b8"))
		"chair", "sofa":
			_box(root,Vector3(float(s[0]),0.18,float(s[1])*0.8),Vector3(0,0.5,0),Color("778e87")).material_override=fabric
			_box(root,Vector3(float(s[0]),height*0.65,0.17),Vector3(0,0.76,float(s[1])*0.35),Color("778e87")).material_override=fabric
			for x in [-0.35,0.35]:
				for z in [-0.3,0.3]:
					_box(root,Vector3(0.07,0.45,0.07),Vector3(x*float(s[0]),0.24,z*float(s[1])),Color("454f50"))
		"plant":
			var pot := CylinderMesh.new()
			pot.top_radius=0.27; pot.bottom_radius=0.18; pot.height=0.4
			_mesh(root,pot,Vector3(0,0.2,0),Color("b98662"))
			for branch in range(5):
				var leaf := SphereMesh.new(); leaf.radius=0.25; leaf.height=0.65
				var node := _mesh(root,leaf,Vector3(sin(branch*2.4)*0.2,0.65+branch*0.07,cos(branch*2.4)*0.2),Color("638b65"))
				node.rotation.z=sin(branch*2.4)*0.5
		_:
			var top := _box(root,Vector3(float(s[0]),0.12,float(s[1])),Vector3(0,height-0.06,0),Color("a88763"))
			top.material_override=wood
			for x in [-0.4,0.4]:
				for z in [-0.4,0.4]:
					_box(root,Vector3(0.09,height-0.1,0.09),Vector3(float(s[0])*x,(height-0.1)*0.5,float(s[1])*z),Color("697974"))

func _dress_prop(asset:Node3D) -> void:
	var finishes:Dictionary={"lightwood":["wood","c5ac92"],"oak":["wood","99856e"],"teal":["fabric","56847c"],"sage":["fabric","849e8a"],"metal":["metal","788b8e"],"navy":["metal","475d68"]}
	for mesh in asset.find_children("*","MeshInstance3D",true,false):
		if mesh.mesh==null:continue
		for index in mesh.mesh.get_surface_count():
			var source:Material=mesh.mesh.surface_get_material(index)
			if source==null:continue
			var name:String=source.resource_name.to_lower().trim_prefix("alpha_")
			if finishes.has(name):
				var finish:Array=finishes[name]
				mesh.set_surface_override_material(index,_surface_material(finish[0],Color(finish[1])))

func _table_details(root:Node3D, kind:String, footprint:Vector2, h:float) -> void:
	# Small fittings sit on the authoritative tabletop and share its physical footprint.
	var scale_factor:=minf(1.0,minf(footprint.x,footprint.y))
	var detail:=Node3D.new();root.add_child(detail);detail.position=Vector3(-footprint.x*.22,h+.005,-footprint.y*.12);detail.scale=Vector3.ONE*scale_factor
	var book:=_box(detail,Vector3(.31,.042,.22),Vector3(0,.022,0),Color("496966"));book.rotation.y=.13
	var paper:=_box(detail,Vector3(.27,.015,.18),Vector3(.023,.05,0),Color("dcceb1"));paper.rotation.y=.11
	var cup:=CylinderMesh.new();cup.radial_segments=16;cup.rings=1;cup.top_radius=.075;cup.bottom_radius=.057;cup.height=.12
	_mesh(detail,cup,Vector3(.34,.061,.12),Color("bd9275") if kind=="counter" else Color("d2c1a3"))
	var drink:=CylinderMesh.new();drink.radial_segments=16;drink.rings=1;drink.top_radius=.060;drink.bottom_radius=.060;drink.height=.004
	_mesh(detail,drink,Vector3(.34,.122,.12),Color("503d35"))

func _service_signage(parent: Node3D, kind: String, size: Vector2, height: float) -> void:
	# Printed plates live on the real device: no billboard, observer overlay or hidden state.
	for side in 4:
		var face:=Node3D.new();face.name="PrintedServicePlate_%d"%side
		face.rotation.y=float(side)*PI*0.5
		var side_width:float=size.x if side%2==0 else size.y
		var extent:float=size.y if side%2==0 else size.x
		face.position=Vector3(sin(face.rotation.y)*(extent*0.5+0.025),height*0.77,cos(face.rotation.y)*(extent*0.5+0.025));parent.add_child(face)
		var width:float=minf(side_width*0.94,1.15)
		_box(face,Vector3(width,0.42,0.035),Vector3.ZERO,Color("1b343c"))
		var label:=Label3D.new();label.name="PrintedServiceName";label.text="ПАЙКИ\nRATIONS" if kind=="terminal" else "МАГАЗИН\nSHOP"
		label.position.z=0.021;label.font_size=64;label.pixel_size=width/300.0;label.modulate=Color("f2dfaa");label.outline_size=0;label.layers=WORLD
		label.billboard=BaseMaterial3D.BILLBOARD_DISABLED;label.no_depth_test=false;label.double_sided=false;label.shaded=false;face.add_child(label)
		if kind=="terminal":
			# A static dispense hatch and illuminated physical push button identify the affordance.
			_box(face,Vector3(width*0.65,0.19,0.045),Vector3(0,-0.39,0.015),Color("17242b"))
			_box(face,Vector3(width*0.58,0.025,0.14),Vector3(0,-0.48,0.055),Color("84918b"))
			_box(face,Vector3(0.09,0.09,0.035),Vector3(width*0.35,-0.23,0.027),Color("c6a461"))

func _build_observer(geometry: Dictionary) -> void:
	var window_size: Vector2i=Vector2i(get_viewport().get_visible_rect().size)
	observer_viewport = _viewport("Observer",Vector2i(maxi(640,window_size.x),maxi(480,window_size.y)))
	observer_viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	observer_camera=Camera3D.new()
	observer_camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	observer_camera.cull_mask=WORLD|CUTAWAY|BODIES|CAPTURE_BODY|SELECTED_BODY|OVERLAY
	observer_camera.far=150
	observer_viewport.add_child(observer_camera)
	observer_camera.current=true
	human_viewport=_viewport("HumanFirstPerson",_display_size)
	human_camera=Camera3D.new();human_camera.near=0.045;human_camera.far=48;human_camera.fov=74
	human_viewport.add_child(human_camera);human_camera.current=true
	human_viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS if first_person else SubViewport.UPDATE_DISABLED
	var bounds: Array=geometry.get("bounds",[-12,12,-9,9])
	_fit_bounds=bounds.duplicate()
	_focus=Vector3((float(bounds[0])+float(bounds[1]))*0.5,0,(float(bounds[2])+float(bounds[3]))*0.5)
	_zoom=25.0
	_yaw=-0.48
	set_display_size(_display_size)
	_fit_observer()
	if not get_viewport().size_changed.is_connected(_resize_observer):get_viewport().size_changed.connect(_resize_observer)

func _resize_observer() -> void:
	if not is_instance_valid(observer_viewport):return
	set_display_size(_display_size)
	if not _user_camera:_fit_observer()

func _fit_observer() -> void:
	if _fit_bounds.size()!=4 or not is_instance_valid(observer_camera):return
	var min_x:float=INF;var max_x:float=-INF;var min_y:float=INF;var max_y:float=-INF
	for x in [_fit_bounds[0],_fit_bounds[1]]:
		for z in [_fit_bounds[2],_fit_bounds[3]]:
			for height in [0.0,2.3]:
				var delta:=Vector3(float(x),height,float(z))-_focus
				var horizontal:float=delta.dot(observer_camera.global_basis.x)
				var vertical:float=delta.dot(observer_camera.global_basis.y)
				min_x=minf(min_x,horizontal);max_x=maxf(max_x,horizontal);min_y=minf(min_y,vertical);max_y=maxf(max_y,vertical)
	var aspect:float=float(observer_viewport.size.x)/float(observer_viewport.size.y)
	_zoom=maxf(max_y-min_y,(max_x-min_x)/aspect)*1.16
	_update_observer()

func _update_observer() -> void:
	if not is_instance_valid(observer_camera): return
	_update_facades()
	observer_camera.size=_zoom
	var e:=deg_to_rad(_elevation)
	observer_camera.position=_focus+Vector3(sin(_yaw)*cos(e),sin(e),cos(_yaw)*cos(e))*45.0
	observer_camera.look_at(_focus,Vector3.UP)

func _build_agent(id: String, data: Dictionary) -> void:
	var root:=Node3D.new(); root.name="Agent_"+id
	_content.add_child(root); agent_nodes[id]=root
	var pose:=Node3D.new(); pose.name="Appearance"
	root.add_child(pose); agent_pose_nodes[id]=pose
	var face: int=int(data.get("appearance",{}).get("face",0))
	var model: Node3D=_instantiate_asset("human_female" if face%2 else "human_male")
	if model!=null:
		pose.add_child(model)
		_models[id]=model
		_fit_asset(model,Vector3(0.8,1.78,0.55),true)
		model.rotation.y=PI
		_model_faces[id]=face%2
		var player:=_find_animation(model)
		if player!=null: _players[id]=player
	else:
		_fallback_human(pose,str(data.get("color","83bfa9")))
	_meshes[id]=[]
	_collect_meshes(pose,_meshes[id])
	_set_body_layer(id,BODIES)
	var marker:=Marker3D.new(); marker.position=Vector3(0.34,1.02,-0.24)
	pose.add_child(marker); _held_markers[id]=marker
	_label(root,str(data.get("name",id)),Vector3(0,2.05,0),Color.from_string(str(data.get("color","eecf83")),Color.WHITE).lightened(0.25),0.0055)
	var viewport:=_viewport("Eyes_"+id,EYES_SIZE)
	viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
	agent_viewports[id]=viewport
	var camera:=Camera3D.new(); camera.fov=74; camera.near=0.045; camera.far=24
	viewport.add_child(camera); camera.current=true
	agent_cameras[id]=camera
	_targets[id]={"position":Vector3.ZERO,"heading":0.0}
	_animate(id,data,false)

func _fallback_human(parent: Node3D, color: String) -> void:
	var clothing:=Color.from_string(color,Color("83bfa9"))
	var torso:=CapsuleMesh.new(); torso.radius=0.24; torso.height=0.72
	_mesh(parent,torso,Vector3(0,1.0,0),clothing)
	for side in [-1.0,1.0]:
		var limb:=CapsuleMesh.new(); limb.radius=0.085; limb.height=0.7
		_mesh(parent,limb,Vector3(side*0.13,0.4,0),Color("344551"))
		_mesh(parent,limb,Vector3(side*0.32,1.02,0),clothing)
	var head:=SphereMesh.new(); head.radius=0.21; head.height=0.43
	_mesh(parent,head,Vector3(0,1.57,0),Color("e0bca0"))
	_box(parent,Vector3(0.4,0.13,0.36),Vector3(0,1.75,0.03),Color("59443b"))
	for side in [-1.0,1.0]:
		_box(parent,Vector3(0.035,0.055,0.02),Vector3(side*0.075,1.59,-0.2),Color("233342"))

func _apply_appearance(id: String, appearance: Dictionary, color: String) -> void:
	var signature:=JSON.stringify(appearance)+color
	if _appearances.get(id)==signature: return
	_appearances[id]=signature
	var pose: Node3D=agent_pose_nodes[id]
	var face: int=posmod(int(appearance.get("face",0)),2)
	if _models.has(id) and int(_model_faces.get(id,0))!=face:
		var replacement: Node3D=_instantiate_asset("human_female" if face else "human_male")
		if replacement!=null:
			_models[id].free(); _players.erase(id); _animation_keys.erase(id)
			pose.add_child(replacement); _models[id]=replacement; _model_faces[id]=face
			_fit_asset(replacement,Vector3(0.8,1.78,0.55),true); replacement.rotation.y=PI
			var player:=_find_animation(replacement)
			if player!=null: _players[id]=player
			_meshes[id]=[]; _collect_meshes(pose,_meshes[id]); _set_body_layer(id,SELECTED_BODY if id==selected_agent else BODIES)
	var height: float=clampf(float(appearance.get("height",1.0)),0.8,1.25)
	var build: float=clampf(float(appearance.get("build",1.0)),0.75,1.3)
	pose.scale=Vector3(build,height,build)
	var clothing:=Color.from_string(color,Color("83bfa9"))
	for mesh in _meshes.get(id,[]):
		var n: String=str(mesh.name).to_lower()
		if n.begins_with("hair_"):
			mesh.visible=int(n.trim_prefix("hair_").split(".")[0].split("_")[0])==posmod(int(appearance.get("hair",0)),6)
			mesh.material_override=_material(Color.from_string(str(appearance.get("hair_color","4e3b32")),Color("4e3b32")))
		elif mesh.mesh!=null:
			if n.begins_with("clothing_shirt_"):mesh.visible=int(n.trim_prefix("clothing_shirt_").split(".")[0])==posmod(int(appearance.get("outfit",0)),4)
			elif n.begins_with("clothing_shoes_"):mesh.visible=int(n.trim_prefix("clothing_shoes_").split(".")[0])==posmod(int(appearance.get("shoes",0)),2)
			for surface in mesh.mesh.get_surface_count():
				var original: Material=mesh.mesh.surface_get_material(surface)
				if original is StandardMaterial3D:
					var material: StandardMaterial3D=original.duplicate()
					var material_name: String=material.resource_name.to_lower()
					if material_name.contains("shirt"):
						mesh.set_surface_override_material(surface,_outfit_material(clothing,int(appearance.get("outfit",0))));continue
					elif material_name.contains("hair"):material.albedo_color=Color.from_string(str(appearance.get("hair_color","4e3b32")),Color("4e3b32"))
					elif material_name.contains("trouser"):
						material.albedo_color=[Color("3d4c5b"),Color("ad9d7b"),Color("273439"),clothing.darkened(0.4)][posmod(int(appearance.get("outfit",0)),4)]
					elif material_name.contains("shoe"):material.albedo_color=Color("64554a") if int(appearance.get("shoes",0))%2 else Color("303940")
					elif material_name.contains("skin") or material_name.contains("superhero") or material_name.contains("basecharacter"):
						var skin:=Color.from_string(str(appearance.get("skin","dfb89e")),Color("dfb89e"))
						material.albedo_color=Color(skin.r/0.96,skin.g/0.74,skin.b/0.58,1.0)
					mesh.set_surface_override_material(surface,material)
	if _models.has(id):
		for skeleton in _models[id].find_children("*","Skeleton3D",true,false):
			var modifier:Node=skeleton.get_node_or_null("FaceShape")
			if modifier==null:modifier=FaceShape.new();modifier.name="FaceShape";skeleton.add_child(modifier)
			modifier.variant=posmod(int(int(appearance.get("face",0))/2),3)

func _apply_pose(id: String, data: Dictionary) -> void:
	var body: Dictionary=data.get("body",{})
	var crawl: bool=body.get("left_leg")=="broken" and body.get("right_leg")=="broken"
	var prone: bool=not bool(data.get("alive",true)) or bool(data.get("sleeping",false)) or bool(data.get("unconscious",false))
	var pose: Node3D=agent_pose_nodes[id]
	if not _players.has(id):
		pose.rotation.x=deg_to_rad(-75) if crawl else 0.0
		pose.rotation.z=deg_to_rad(88) if prone else 0.0
		pose.position=Vector3(0,0.25,0.4) if crawl else (Vector3(0,0.27,0) if prone else Vector3.ZERO)

func _animate(id: String, data: Dictionary, moving: bool) -> void:
	if not _players.has(id): return
	var player: AnimationPlayer=_players[id]
	var keys: Array=["idle"]
	var body: Dictionary=data.get("body",{})
	var type: String=str(data.get("busy",{}).get("type",""))
	if not bool(data.get("alive",true)): keys=["death","dead","die"]
	elif bool(data.get("sleeping",false)) or bool(data.get("unconscious",false)): keys=["sleep","lying","death"]
	elif body.get("left_leg")=="broken" and body.get("right_leg")=="broken": keys=["crawl","crouch_fwd","crouch"]
	elif moving: keys=["limp","walk"] if body.get("left_leg","healthy")!="healthy" or body.get("right_leg","healthy")!="healthy" else ["walk","walking","run"]
	elif type in ["attack","defend"]: keys=[type,"punch","attack"]
	elif type in ["consume","eat"]: keys=["eat","interact","idle"]
	elif type in ["rest","sit"]: keys=["sit","sitting","idle"]
	elif _action_feedback.has(id) and int(_action_feedback[id].until)>Time.get_ticks_msec():
		var recent:String=str(_action_feedback[id].type)
		keys=["idle_talking","talk"] if recent=="speak" else (["pickup","interact"] if recent in ["take","give","drop","request_ration","buy"] else ["interact","idle"])
	elif not type.is_empty(): keys=[type,"interact","idle"]
	if _animation_choices.get(id,[])==keys:return
	_animation_choices[id]=keys
	var found: String=""
	for key in keys:
		for clip in player.get_animation_list():
			var leaf: String=str(clip).get_slice("/",str(clip).get_slice_count("/")-1).to_lower().trim_suffix("_loop")
			if leaf==str(key).to_lower().trim_suffix("_loop"):
				found=str(clip); break
		if not found.is_empty(): break
	if found.is_empty():
		for key in keys:
			for clip in player.get_animation_list():
				if str(clip).to_lower().contains(str(key)):
					found=str(clip); break
			if not found.is_empty(): break
	if not found.is_empty() and str(_animation_keys.get(id,""))!=found:
		var first_animation: bool=not _animation_keys.has(id)
		_animation_keys[id]=found
		var clip: Animation=player.get_animation(found)
		if keys[0] in ["idle","walk","limp","crawl","sit"] or found.to_lower().contains("idle") or found.to_lower().contains("walk") or found.to_lower().contains("crouch"):
			clip.loop_mode=Animation.LOOP_LINEAR
		player.play(found,0.0 if first_animation else 0.18)
		if first_animation:
			player.advance(0.25 if found.to_lower().contains("idle") else 0.0)
			for skeleton in _models.get(id,agent_pose_nodes[id]).find_children("*","Skeleton3D",true,false):
				if skeleton.has_method("force_update_all_bone_transforms"):skeleton.force_update_all_bone_transforms()

func _sync_camera(id: String, authoritative: bool) -> void:
	if not agent_cameras.has(id) or not _state.get("agents",{}).has(id): return
	var data: Dictionary=_state.agents[id]
	var point: Vector3=_targets.get(id,{}).get("position",Vector3.ZERO) if authoritative else agent_nodes[id].position
	var heading: float=float(_targets.get(id,{}).get("heading",0.0)) if authoritative else agent_nodes[id].rotation.y
	var body: Dictionary=data.get("body",{})
	var height: float=1.57*float(data.get("appearance",{}).get("height",1.0))
	if body.get("left_leg")=="broken" and body.get("right_leg")=="broken": height=0.48
	if bool(data.get("sleeping",false)) or not bool(data.get("alive",true)) or bool(data.get("unconscious",false)): height=0.35
	var camera: Camera3D=agent_cameras[id]
	camera.position=point+Vector3(0,height,0)
	# Keep floor objects within sight at the 1.05 m navigation approach point,
	# including tall avatars; otherwise food disappears below the image exactly
	# when the character is close enough to pick it up.
	camera.rotation=Vector3(deg_to_rad(-24),heading,0)

func _set_body_layer(id: String, layer: int) -> void:
	for mesh in _meshes.get(id,[]): mesh.layers=layer
	# Held meshes follow the holder's visibility in EVERY eye camera, including
	# one-shot captures of an actor who is not selected by the observer.
	for item_id in _state.get("items",{}):
		if str(_state.items[item_id].get("holder",""))==id and item_nodes.has(item_id):
			_set_item_layers(item_nodes[item_id],layer)

func _build_item(id: String, data: Dictionary) -> void:
	var root:=Node3D.new(); root.name="Item_"+id
	_content.add_child(root); item_nodes[id]=root
	var kind: String=str(data.get("kind","ration"))
	var asset: Node3D=_instantiate_asset(kind)
	if asset!=null:
		root.add_child(asset); _fit_asset(asset,Vector3(0.32,0.28,0.25)); return
	match kind:
		"phone":
			_box(root,Vector3(0.13,0.025,0.24),Vector3(0,0.035,0),Color("354954"))
			_box(root,Vector3(0.11,0.004,0.19),Vector3(0,0.051,0),Color("8bcac2"))
		"knife":
			_box(root,Vector3(0.045,0.035,0.13),Vector3(0,0.04,0.09),Color("6b4d3c"))
			_box(root,Vector3(0.055,0.012,0.25),Vector3(0,0.04,-0.08),Color("c4d3d6"))
		"camera":
			_box(root,Vector3(0.26,0.17,0.14),Vector3(0,0.12,0),Color("39464d"))
			var lens:=CylinderMesh.new(); lens.top_radius=0.06; lens.bottom_radius=0.06; lens.height=0.08
			var node:=_mesh(root,lens,Vector3(0,0.12,-0.1),Color("16232d")); node.rotation.x=PI/2
		"medkit":
			_box(root,Vector3(0.33,0.18,0.23),Vector3(0,0.13,0),Color("e6ddd0"))
			_box(root,Vector3(0.06,0.005,0.14),Vector3(0,0.225,0),Color("b85e57"))
			_box(root,Vector3(0.15,0.005,0.05),Vector3(0,0.227,0),Color("b85e57"))
		"mug", "water":
			var cup:=CylinderMesh.new(); cup.top_radius=0.09; cup.bottom_radius=0.075; cup.height=0.23
			_mesh(root,cup,Vector3(0,0.14,0),Color("9fc7cb"))
		"photo", "diary":
			_box(root,Vector3(0.24,0.035,0.3),Vector3(0,0.04,0),Color("e9dfc4") if kind=="photo" else Color("755647"))
		_:
			var box:=_box(root,Vector3(0.34,0.19,0.25),Vector3(0,0.12,0),Color("d3b06c"))
			box.material_override=_surface_material("fabric",Color("d3b06c"),1.0)
			_box(root,Vector3(0.21,0.004,0.13),Vector3(0,0.217,0),Color("f0e6c7"))

func _sync_item(id: String, item: Dictionary) -> void:
	var node: Node3D=item_nodes[id]
	var holder: String=str(item.get("holder",""))
	var container: String=str(item.get("container",""))
	var container_visible: bool=container.is_empty()
	if not container.is_empty() and container not in ["terminal","shop"]:
		for prop in _state.get("geometry",{}).get("props",[]):
			if str(prop.get("id",""))==container:container_visible=bool(prop.get("storage",false)) and bool(prop.get("open",false)) and not bool(prop.get("locked",false));break
	node.visible=int(item.get("quantity",1))>0 and container_visible
	if not holder.is_empty() and _held_markers.has(holder):
		var inventory: Array=_state.agents.get(holder,{}).get("inventory",[])
		node.visible=not inventory.is_empty() and str(inventory[0])==id
		node.global_position=_held_markers[holder].global_position
		node.global_rotation=agent_nodes[holder].global_rotation
		_set_item_layers(node, SELECTED_BODY if holder==selected_agent else (CAPTURE_BODY if holder==_capture_actor else BODIES))
	else:
		var p: Array=item.get("position",[0,0])
		node.position=Vector3(float(p[0]),float(item.get("surface_height",0)),float(p[1]))
		node.rotation=Vector3.ZERO
		_set_item_layers(node,WORLD)

func _set_item_layers(node: Node, layer: int) -> void:
	if node is VisualInstance3D: node.layers=layer
	for child in node.get_children(): _set_item_layers(child,layer)

func _update_selection() -> void:
	if is_instance_valid(_selection) and agent_nodes.has(selected_agent): _selection.position=agent_nodes[selected_agent].position+Vector3(0,0.06,0)

func _viewport(label: String, size: Vector2i) -> SubViewport:
	var viewport:=SubViewport.new(); viewport.name=label; viewport.size=size
	viewport.world_3d=get_world_3d(); viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
	viewport.transparent_bg=false; viewport.msaa_3d=Viewport.MSAA_DISABLED
	add_child(viewport); return viewport

func _build_screen() -> void:
	_screen_viewport=SubViewport.new(); _screen_viewport.name="PrivateDeviceScreen"; _screen_viewport.size=Vector2i(960,640)
	_screen_viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
	add_child(_screen_viewport)
	var bg:=ColorRect.new(); bg.color=Color("eff2e9"); bg.size=Vector2(960,640); _screen_viewport.add_child(bg)
	_screen_title=Label.new(); _screen_title.position=Vector2(40,25); _screen_title.size=Vector2(880,55); _screen_title.add_theme_font_size_override("font_size",30); _screen_title.add_theme_color_override("font_color",Color("233e42")); _screen_viewport.add_child(_screen_title)
	_screen_label=RichTextLabel.new(); _screen_label.position=Vector2(40,100); _screen_label.size=Vector2(880,500); _screen_label.add_theme_font_size_override("normal_font_size",23); _screen_label.add_theme_color_override("default_color",Color("253a41")); _screen_viewport.add_child(_screen_label)

func _load_manifest() -> Dictionary:
	for path in ["res://assets/release/asset_manifest.json","res://assets/release/manifest.json"]:
		if FileAccess.file_exists(path):
			var value=JSON.parse_string(FileAccess.get_file_as_string(path))
			if value is Dictionary: return value
	var models: Dictionary={"human_male":"res://assets/release/characters/human_male.glb","human_female":"res://assets/release/characters/human_female.glb"}
	var aliases: Dictionary={"bed":"bedSingle","bunk":"bedBunk","hospital_bed":"bedSingle","medicalbed":"bedSingle","table":"table","chair":"chair","shelf":"bookcaseOpen","locker":"bookcaseOpen","wardrobe":"bookcaseOpen","cabinet":"bookcaseOpen","plant":"pottedPlant","desk":"desk","sofa":"chairDesk","lamp":"lampRoundFloor","counter":"desk","fridge":"kitchenFridge","labdesk":"desk","console":"desk","rug":"rugRectangle","monitor":"computerScreen"}
	for kind in aliases: models[kind]="res://assets/release/props/"+str(aliases[kind])+".glb"
	var textures: Dictionary={}
	for kind in ["floor","wall","wood","fabric","metal","tile"]:
		textures[kind]={"albedo":"res://assets/release/textures/"+kind+"_color.png","normal":"res://assets/release/textures/"+kind+"_normal.png","roughness":"res://assets/release/textures/"+kind+"_roughness.png"}
	return {"models":models,"textures":textures}

func _instantiate_asset(kind: String) -> Node3D:
	var models: Dictionary=_manifest.get("models",{})
	var path: String=str(models.get(kind,""))
	if path.is_empty() and kind=="human":
		for candidate in ["res://assets/release/characters/human.glb","res://assets/release/human.glb"]:
			if ResourceLoader.exists(candidate): path=candidate; break
	if path.is_empty() or not ResourceLoader.exists(path): return null
	if not _asset_cache.has(path): _asset_cache[path]=load(path)
	var resource=_asset_cache[path]
	if resource is PackedScene:
		var node=resource.instantiate()
		if node is Node3D: return node
		if node!=null: node.free()
	return null

func _fit_asset(node: Node3D, size: Vector3, uniform: bool=false) -> void:
	var bounds:=_asset_bounds(node)
	if bounds.size.length()<0.01: return
	var scale_vec:=Vector3(size.x/maxf(bounds.size.x,0.01),size.y/maxf(bounds.size.y,0.01),size.z/maxf(bounds.size.z,0.01))
	if uniform: scale_vec=Vector3.ONE*(size.y/maxf(bounds.size.y,0.01))
	node.scale=scale_vec
	node.position=-Vector3(bounds.get_center().x,bounds.position.y,bounds.get_center().z)*scale_vec

func _asset_bounds(node: Node3D, parent_transform: Transform3D=Transform3D.IDENTITY) -> AABB:
	var transform: Transform3D=parent_transform*node.transform
	var result:=AABB(); var valid:=false
	if node is MeshInstance3D and node.mesh!=null: result=transform*node.get_aabb(); valid=true
	for child in node.get_children():
		if child is Node3D:
			var box:=_asset_bounds(child,transform)
			if box.size.length()>0.001: result=result.merge(box) if valid else box; valid=true
	return result

func _find_animation(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer: return node
	for child in node.get_children():
		var player:=_find_animation(child)
		if player!=null: return player
	return null

func _collect_meshes(node: Node, result: Array) -> void:
	if node is MeshInstance3D: result.append(node)
	for child in node.get_children(): _collect_meshes(child,result)

func _surface_material(kind: String, tint: Color, repeats: float=1.0) -> StandardMaterial3D:
	var cache_key:=kind+"/"+tint.to_html()
	if _material_cache.has(cache_key):return _material_cache[cache_key]
	var material:=StandardMaterial3D.new();material.albedo_color=tint;material.roughness=.84
	_material_cache[cache_key]=material
	var textures: Dictionary=_manifest.get("textures",{})
	var info: Variant=textures.get(kind,{})
	if info is String: info={"albedo":info}
	if info is Dictionary:
		for field in ["albedo","normal","roughness"]:
			var path: String=str(info.get(field,""))
			if not path.is_empty() and ResourceLoader.exists(path):
				if not _texture_cache.has(path): _texture_cache[path]=load(path)
				if field=="albedo": material.albedo_texture=_texture_cache[path]
				elif field=="normal": material.normal_enabled=true; material.normal_texture=_texture_cache[path]; material.normal_scale=0.45
				elif field=="roughness": material.roughness_texture=_texture_cache[path]
	material.uv1_triplanar=true
	material.uv1_scale=Vector3.ONE*.25
	material.texture_filter=BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return material

func _material(color: Color) -> StandardMaterial3D:
	var key:=color.to_html()
	if _material_cache.has(key):return _material_cache[key]
	var material:=StandardMaterial3D.new(); material.albedo_color=color; material.roughness=0.85
	_material_cache[key]=material
	return material

func _outfit_material(color: Color, outfit: int) -> ShaderMaterial:
	var material:=ShaderMaterial.new();material.shader=OutfitShader
	material.set_shader_parameter("cloth_color",color)
	material.set_shader_parameter("accent_color",Color("e7dfc8"))
	material.set_shader_parameter("outfit",0)
	for pair in [["fabric_map","res://assets/release/textures/fabric_color.png"],["normal_map","res://assets/release/textures/fabric_normal.png"]]:
		if ResourceLoader.exists(pair[1]):
			if not _texture_cache.has(pair[1]):_texture_cache[pair[1]]=load(pair[1])
			material.set_shader_parameter(pair[0],_texture_cache[pair[1]])
	return material

func _box(parent: Node3D, size: Vector3, point: Vector3, color: Color, layer: int=WORLD) -> MeshInstance3D:
	var box:=BoxMesh.new(); box.size=size
	return _mesh(parent,box,point,color,layer)

func _mesh(parent: Node3D, mesh: Mesh, point: Vector3, color: Color, layer: int=WORLD) -> MeshInstance3D:
	var node:=MeshInstance3D.new(); node.mesh=mesh; node.position=point; node.layers=layer; node.material_override=_material(color)
	parent.add_child(node); return node

func _label(parent: Node3D, text: String, point: Vector3, color: Color, pixel: float=0.005, floor_label: bool=false) -> void:
	var label:=Label3D.new(); label.text=text; label.position=point; label.font_size=36; label.pixel_size=pixel; label.modulate=color; label.outline_modulate=Color("23313c"); label.layers=OVERLAY
	if floor_label: label.rotation_degrees.x=-90
	else: label.billboard=BaseMaterial3D.BILLBOARD_ENABLED; label.no_depth_test=true
	parent.add_child(label)
	_labels.append({"node":label,"kind":"room" if floor_label else "actor","actor":str(parent.name).trim_prefix("Agent_")})

func _update_labels() -> void:
	if not is_instance_valid(observer_camera):return
	var occupied:Array=[]
	var sorted:Array=_labels.duplicate()
	sorted.sort_custom(func(a,b):return a.get("actor","")==selected_agent and b.get("actor","")!=selected_agent)
	for entry in sorted:
		var label:Label3D=entry.node
		if not is_instance_valid(label):continue
		label.visible=not first_person and (_zoom>=25.0 if entry.kind=="room" else _zoom<=28.0)
		if not label.visible or entry.kind=="room":continue
		label.pixel_size=0.008;label.font_size=32
		if observer_camera.is_position_behind(label.global_position):label.visible=false;continue
		var point:Vector2=observer_camera.unproject_position(label.global_position)
		var rect:=Rect2(point-Vector2(48,10),Vector2(96,22))
		for used in occupied:
			if rect.intersects(used):label.visible=false;break
		if label.visible:occupied.append(rect)
	for id in _speech_bubbles:
		var bubble:Label3D=_speech_bubbles[id]
		bubble.visible=not first_person and _zoom<22.0 and _action_feedback.has(id) and int(_action_feedback[id].until)>Time.get_ticks_msec() and str(_action_feedback[id].type)=="speak"

func _sync_action_feedback(state:Dictionary) -> void:
	var fresh:Array=[]
	var events:Array=state.get("events",[])
	for i in range(events.size()-1,-1,-1):
		var event:Dictionary=events[i]
		if int(event.get("seq",-1))<=_visual_event_cursor:break
		fresh.push_front(event)
	for event in fresh:
		_visual_event_cursor=maxi(_visual_event_cursor,int(event.get("seq",-1)))
		var id:=str(event.get("actor",""))
		if not bool(event.get("ok",false)) or not agent_nodes.has(id):continue
		var kind:=str(event.get("type",""))
		if kind not in ["speak","take","give","drop","request_ration","buy","use_device","read_screen","treat","open","close"]:continue
		_action_feedback[id]={"type":kind,"until":Time.get_ticks_msec()+(4000 if kind=="speak" else 1800)}
		if kind=="speak":
			if not _speech_bubbles.has(id):
				var bubble:=Label3D.new();bubble.layers=OVERLAY;bubble.position=Vector3(0,2.55,0);bubble.font_size=24;bubble.pixel_size=0.007
				bubble.billboard=BaseMaterial3D.BILLBOARD_ENABLED;bubble.no_depth_test=true;bubble.modulate=Color("fff4d6");bubble.outline_size=8;bubble.outline_modulate=Color("182d36")
				agent_nodes[id].add_child(bubble);_speech_bubbles[id]=bubble
			var text:=str(state.agents[id].get("last_action",{}).get("text",event.get("message","")))
			_speech_bubbles[id].text=text.left(58)+("…" if text.length()>58 else "")
