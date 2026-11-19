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
const DISPLAY_BODY := 64
const DISTANT_BODY := 128
const OVERLAY := 1 << 19
const EYES_SIZE := Vector2i(640, 360)
const WEB_CLOSE_RESIDENTS := 5
const SEATED_EYE_RISE := .77
const SEATED_FLOOR_HEIGHT := .045
const PortraitStage = preload("res://scripts/release_world/character_portrait.gd")
const CharacterFinish = preload("res://scripts/release_world/character_finish.gd")
const FaceShape = preload("res://scripts/release_world/face_modifier.gd")
const SeatedHandContact = preload("res://scripts/release_world/seated_hand_contact.gd")
const SeatedFootLevel = preload("res://scripts/release_world/seated_foot_level.gd")
const WardrobeDeformation = preload("res://scripts/release_world/wardrobe_deformation.gd")
const Art = preload("res://scripts/release_world/art_direction.gd")
const ResidenceScenery = preload("res://scripts/release_world/residence_scenery.gd")
const ResidenceSeats = preload("res://scripts/game/residence_seats.gd")
const ResidenceLighting = preload("res://scripts/release_world/residence_lighting.gd")

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
var _open_containers: Dictionary = {}
var _targets: Dictionary = {}
var _players: Dictionary = {}
var _models: Dictionary = {}
var _model_faces: Dictionary = {}
var _faces: Dictionary = {}
var _face_minute := -1.0
var _face_clock := 0.0
var _face_clock_limit := 0.0
var _animation_keys: Dictionary = {}
var _animation_choices: Dictionary = {}
var _clip_names: Dictionary = {}
var _meshes: Dictionary = {}
var _appearances: Dictionary = {}
var _held_markers: Dictionary = {}
var _seat_motion: Dictionary = {}
var _seat_leg_solvers: Dictionary = {}
var _capture_actor := ""
var _capture_frame := -100
var _focus := Vector3.ZERO
var _focus_goal := Vector3.ZERO
var _centering := false
var _yaw := 0.0
var _elevation := 35.0
var _zoom := 21.0
var _perspective := false
var _overview_return: Dictionary = {}
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
var _render_scale := 1.0
var _overview_zoom := 140.0
var _hud_portrait: Node
var _portrait_cache: Dictionary = {}
var _portrait_pending := ""
var _labels: Array = []
var _label_timer := 0.0
var _facades: Array = []
var _residence_roofs: Array[Dictionary] = []
var _residence_canopies: Array = []
var _residence_lighting: RefCounted
var _last_facade_yaw := INF
var _notice_boards: Dictionary = {}
var _material_cache: Dictionary = {}
var _box_meshes: Dictionary = {}
var _visual_event_cursor := -1
var _action_feedback: Dictionary = {}
var _speech_bubbles: Dictionary = {}
var _proxy_group: Node3D
var _proxies: Array[MultiMesh] = []
var _use_proxies := false
var _proxy_timer := 0.0
var _near_observer: Dictionary = {}

func setup(state: Dictionary) -> void:
	_grounding_generation+=1
	_grounding_badges.clear()
	_facades.clear();_last_facade_yaw=INF;_labels.clear();_notice_boards.clear();_portrait_pending="";_material_cache.clear();_action_feedback.clear();_speech_bubbles.clear();_visual_event_cursor=-1
	_residence_roofs.clear()
	_residence_canopies.clear()
	_residence_lighting = null
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
	_faces.clear()
	_face_minute = -1.0
	_face_clock = 0.0
	_face_clock_limit = 0.0
	_animation_keys.clear()
	_animation_choices.clear()
	_clip_names.clear()
	_meshes.clear()
	_appearances.clear()
	_held_markers.clear()
	_seat_motion.clear()
	_seat_leg_solvers.clear()
	_targets.clear()
	_capture_actor = ""
	_proxies.clear()
	_proxy_group=null
	_use_proxies=false
	_near_observer.clear()
	_proxy_timer=0.0
	_centering = false
	follow_selected = false
	_perspective = false
	_overview_return.clear()
	_drag = 0
	_manifest = _load_manifest()
	_user_camera=false
	_state = {}
	_content = Node3D.new()
	_content.name = "LivingWorld"
	add_child(_content)
	var geometry: Dictionary = state.get("geometry", {})
	_environment(str(geometry.get("palette", "teal")))
	_build_map(geometry)
	if _residence_lighting != null:
		_residence_lighting.bind_fixtures(_content.get_node_or_null("ResidenceScenery") as Node3D)
	_build_observer(state.get("geometry", {}))
	for id in state.get("agents", {}):
		_build_agent(str(id), state.agents[id])
	if selected_agent.is_empty() or not agent_nodes.has(selected_agent):
		selected_agent = str(state.get("agents", {}).keys()[0]) if not state.get("agents", {}).is_empty() else ""
	_selection = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.37
	ring.outer_radius = 0.39
	ring.rings = 36
	ring.ring_segments = 10
	_selection.mesh = ring
	var highlight := StandardMaterial3D.new()
	highlight.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	highlight.albedo_color = Color("c9a76d")
	_selection.material_override = highlight
	_selection.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_selection.layers = OVERLAY
	_content.add_child(_selection)
	_build_screen()
	select_agent(selected_agent)
	sync_state(state, true)
	set_quality(_quality)
	_update_observer_lod()

func sync_state(state: Dictionary, immediate: bool = false) -> void:
	# Only retain values used between simulation updates.
	var agents := {}
	var held_items := {}
	var geometry: Dictionary = state.get("geometry", {})
	for id in state.get("items", {}):
		var holder := str(state.items[id].get("holder", ""))
		if not holder.is_empty():
			held_items[id] = holder
	_state = {"agents": agents, "items": held_items}
	if _residence_lighting != null:
		_residence_lighting.apply(float(state.get("minute", 0.0)))
	_sync_action_feedback(state)
	_open_containers.clear()
	for prop in state.get("geometry", {}).get("props", []):
		if prop.get("storage", false) and prop.get("open", false) and not prop.get("locked", false):
			_open_containers[str(prop.get("id", ""))] = true
	for id in state.get("agents", {}):
		var data: Dictionary = state.agents[id]
		if not agent_nodes.has(id):
			_build_agent(str(id), data)
		var inventory: Array = data.get("inventory", []).slice(0, 1)
		agents[id] = {
			"appearance": {"height": data.get("appearance", {}).get("height", 1.0)},
			"outfit": int(data.get("appearance", {}).get("outfit", 0)),
			"shoe_type": int(data.get("appearance", {}).get("shoes", 0)),
			"color": data.get("color", "83988b"), "skin": data.get("appearance", {}).get("skin", "d9b497"),
			"body": {"left_leg": data.get("body", {}).get("left_leg", "healthy"), "right_leg": data.get("body", {}).get("right_leg", "healthy")},
			"busy": {"type": data.get("busy", {}).get("type", "")},
			"seat": ResidenceSeats.occupied(data, geometry),
			"alive": data.get("alive", true), "sleeping": data.get("sleeping", false),
			"unconscious": data.get("unconscious", false), "carried_by": data.get("carried_by", ""),
			"inventory": inventory,
			"held_phone": not inventory.is_empty() and state.get("items", {}).get(inventory[0], {}).get("kind") == "phone",
		}
		var pos: Array = data.get("position", [0, 0])
		var lift: float=float(data.get("surface_height",0.0))+(0.8 if not str(data.get("carried_by","")).is_empty() else 0.0)
		_targets[id] = {"position": Vector3(float(pos[0]), lift, float(pos[1])), "heading":deg_to_rad(float(data.get("heading", 0)))}
		if immediate:
			agent_nodes[id].position = _targets[id].position
			agent_nodes[id].rotation.y = _targets[id].heading
		_apply_appearance(str(id), data.get("appearance", {}), str(data.get("color", "83bfa9")))
		_apply_pose(str(id), data, immediate)
		_sync_camera(str(id), true)
	_sync_face_context(state, immediate)
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
			var is_open := bool(door.get("open", false))
			if pivot.has_meta("slide_offset"):
				var closed_position: Vector3 = pivot.get_meta("closed_position")
				var slide_offset: Vector3 = pivot.get_meta("slide_offset")
				pivot.position = closed_position + slide_offset if is_open else closed_position
			else:
				pivot.rotation.y = deg_to_rad(90.0) if is_open else 0.0
	for prop in state.get("geometry",{}).get("props",[]):
		if storage_doors.has(str(prop.get("id",""))):storage_doors[str(prop.id)].rotation.y=deg_to_rad(-105) if prop.get("open",false) else 0.0
		if _notice_boards.has(str(prop.get("id",""))):
			var paper:Label3D=_notice_boards[str(prop.id)]
			paper.text=str(prop.get("label",""))+"\n\n"+str(prop.get("document",prop.get("text","")))
	_update_selection()
	_sync_human_camera()
	_update_labels()
	if _use_proxies:_update_proxy_instances()

func _process(delta: float) -> void:
	_face_clock = minf(_face_clock + delta, _face_clock_limit)
	for id in _targets:
		if not agent_nodes.has(id):
			continue
		var body: Node3D = agent_nodes[id]
		var previous := body.position
		var blend := 1.0 - exp(-14.0 * delta)
		body.position = body.position.lerp(_targets[id].position, blend)
		body.rotation.y = lerp_angle(body.rotation.y, float(_targets[id].heading), blend)
		if _state.get("agents", {}).has(id):
			var speed := Vector2(body.position.x - previous.x, body.position.z - previous.z).length() / maxf(delta, 0.0001)
			_animate(str(id), _state.agents[id], speed)
			_update_wardrobe(str(id))
			_update_seat_pose(str(id))
			_present_face(str(id))
			var inventory: Array = _state.agents[id].get("inventory", [])
			if not inventory.is_empty() and item_nodes.has(inventory[0]):
				_set_held_pose(item_nodes[inventory[0]], str(id))
		if id == _capture_actor and Engine.get_frames_drawn() <= _capture_frame + 1:
			_sync_camera(str(id), true)
		elif first_person and id == selected_agent:
			_sync_camera(str(id), false)
	if follow_selected and agent_nodes.has(selected_agent):
		_focus_goal = _resident_focus()
	if follow_selected or _centering:
		var offset := _focus.distance_squared_to(_focus_goal)
		if offset > 0.0001:
			_focus = _focus.lerp(_focus_goal, 1.0 - exp(-9.0 * delta))
			_update_observer()
		elif _centering:
			_focus = _focus_goal
			_centering = false
			_update_observer()
	_update_selection()
	if first_person:
		_sync_human_camera()
	_label_timer -= delta
	if _label_timer <= 0.0:
		_label_timer = 0.09
		_update_labels()
	if _use_proxies and not first_person:
		_proxy_timer-=delta
		if _proxy_timer<=0.0:
			_proxy_timer=0.06
			_update_proxy_instances()

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
	var previous:=selected_agent
	selected_agent = id
	if not previous.is_empty() and agent_nodes.has(previous):
		_set_body_layer(previous, CAPTURE_BODY if previous==_capture_actor and Engine.get_frames_drawn()<=_capture_frame+1 else BODIES)
		if agent_viewports.has(previous):agent_viewports[previous].render_target_update_mode=SubViewport.UPDATE_DISABLED
	_set_body_layer(id, SELECTED_BODY)
	agent_cameras[id].cull_mask = WORLD | WALLS | BODIES | CAPTURE_BODY
	agent_viewports[id].render_target_update_mode = SubViewport.UPDATE_DISABLED
	if not _capture_actor.is_empty() and agent_cameras.has(_capture_actor):
		agent_cameras[_capture_actor].cull_mask=WORLD|WALLS|BODIES|(CAPTURE_BODY if _capture_actor==selected_agent else SELECTED_BODY)
	_sync_human_camera()
	_update_selection()
	if _use_proxies:_update_proxy_instances()

func set_first_person(value: bool) -> void:
	first_person = value
	_drag = 0
	if is_instance_valid(observer_viewport):observer_viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED if value else SubViewport.UPDATE_ALWAYS
	if is_instance_valid(human_viewport):human_viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS if value else SubViewport.UPDATE_DISABLED
	_sync_human_camera()

func set_quality(preset: String) -> void:
	_quality = preset
	var restrained := preset=="low" or (OS.has_feature("web") and preset=="medium")
	var mode: int = Viewport.MSAA_DISABLED if restrained else Viewport.MSAA_2X
	if is_instance_valid(observer_viewport):
		observer_viewport.msaa_3d = mode
	for viewport in agent_viewports.values():
		viewport.msaa_3d = Viewport.MSAA_DISABLED
	if is_instance_valid(human_viewport):human_viewport.msaa_3d=mode
	set_display_size(_display_size)
	for light in _content.find_children("*","DirectionalLight3D",true,false):
		if light.name=="Sun":light.shadow_enabled=not restrained
		elif light.name=="Fill":light.visible=not OS.has_feature("web") or preset=="high"
	if _residence_lighting != null:
		_residence_lighting.set_quality(preset)
	_update_observer_lod()

func set_render_scale(value: float) -> void:
	_render_scale=clampf(value,0.5,1.0)
	set_display_size(_display_size)

func set_display_size(value:Vector2i) -> void:
	_display_size=value.max(Vector2i(2,2))
	var pixels:=Vector2i(roundi(_display_size.x*_render_scale),roundi(_display_size.y*_render_scale)).max(Vector2i(2,2))
	if is_instance_valid(observer_viewport) and observer_viewport.size!=pixels:
		observer_viewport.size=pixels
		if not _user_camera:_fit_observer()
	if is_instance_valid(human_viewport) and human_viewport.size!=pixels:human_viewport.size=pixels

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

func focus_position(point: Array, smooth: bool = false) -> void:
	if point.size()<2:return
	_set_focus(Vector3(float(point[0]),0,float(point[1])),18.0,smooth)

func frame_story_start() -> void:
	if not agent_nodes.has(selected_agent):return
	_perspective = true
	_yaw = -0.72
	_elevation = 25.0
	_zoom = 5.5
	_focus = _resident_focus()
	_focus_goal = _focus
	_user_camera = true
	follow_selected = true
	_update_observer()

func toggle_overview() -> void:
	if not _overview_return.is_empty():
		restore_camera(_overview_return)
		return
	var previous := snapshot_camera()
	set_first_person(false)
	show_map()
	_overview_return = previous

func show_map() -> void:
	follow_selected=false;_centering=false;_user_camera=false
	_perspective = false
	_overview_return = {}
	_yaw=-0.48;_elevation=51.0
	if _fit_bounds.size()==4:_focus=Vector3((float(_fit_bounds[0])+float(_fit_bounds[1]))*0.5,0,(float(_fit_bounds[2])+float(_fit_bounds[3]))*0.5)
	_update_observer()
	_fit_observer()

func snapshot_camera() -> Dictionary:
	return {"focus":_focus,"yaw":_yaw,"elevation":_elevation,"zoom":_zoom,"follow":follow_selected,"first_person":first_person,"user_camera":_user_camera,"perspective":_perspective,"overview_return":_overview_return.duplicate(true)}

func restore_camera(saved: Dictionary) -> void:
	if saved.is_empty():return
	_focus=saved.focus;_yaw=saved.yaw;_elevation=saved.elevation;_zoom=saved.zoom
	_user_camera=saved.user_camera;follow_selected=saved.follow;_centering=false
	_perspective = bool(saved.get("perspective",false))
	_overview_return = saved.get("overview_return",{}).duplicate(true)
	set_first_person(bool(saved.first_person))
	_update_observer()

func display_agent_positions() -> Dictionary:
	var points := {}
	for id in agent_nodes:
		var position: Vector3 = agent_nodes[id].position
		points[id] = Vector2(position.x,position.z)
	return points

func camera_map_state() -> Dictionary:
	var camera:=human_camera if first_person else observer_camera
	if not is_instance_valid(camera):return {}
	var footprint:=PackedVector2Array()
	if not first_person:
		var size:=Vector2(observer_viewport.size)
		for corner in [Vector2.ZERO,Vector2(size.x,0),size,Vector2(0,size.y)]:
			var floor_point:=_screen_ground(corner)
			footprint.append(Vector2(floor_point.x,floor_point.z))
	var center:=camera.global_position if first_person else _focus
	return {"position":Vector2(center.x,center.z),"heading":camera.global_rotation.y,"footprint":footprint,"following":follow_selected,"overview":not _overview_return.is_empty()}

func reset_action_feedback() -> void:
	_action_feedback.clear()
	_visual_event_cursor=-1
	_label_timer=0.0

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

func handle_view_input(event: InputEvent, display: Vector2 = Vector2.ZERO) -> void:
	if first_person or display.x <= 0 or display.y <= 0:
		return
	var source_size := Vector2(observer_viewport.size)
	var scale := source_size / display
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var factor := minf(display.x / source_size.x, display.y / source_size.y)
			var offset := (display - source_size * factor) * 0.5
			if not Rect2(offset, source_size * factor).has_point(event.position):
				return
			var nearest := ""
			var closest := 24.0
			for id in agent_nodes:
				var body_point: Vector3 = agent_nodes[id].position + Vector3.UP
				if observer_camera.is_position_behind(body_point):
					continue
				var projection := observer_camera.unproject_position(body_point) * factor + offset
				var distance := projection.distance_to(event.position)
				if distance < closest:
					closest = distance
					nearest = str(id)
			if not nearest.is_empty():
				agent_picked.emit(nearest)
		elif event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and event.pressed:
			var point: Vector2 = event.position * scale
			var anchor := _screen_ground(point)
			var zoom_factor := 0.88 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 0.88
			_user_camera = true
			_zoom = clampf(_zoom * zoom_factor, 5.5, maxf(80.0, _overview_zoom * 1.08))
			_update_observer()
			if not follow_selected and not _centering:
				_focus = _clamp_focus(_focus + anchor - _screen_ground(point))
				_update_observer()
		elif event.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_drag = event.button_index if event.pressed else 0
	elif event is InputEventMouseMotion and _drag != 0:
		var mask := MOUSE_BUTTON_MASK_RIGHT if _drag == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_MIDDLE
		if not (event.button_mask & mask):
			_drag = 0
			return
		_user_camera = true
		if _drag == MOUSE_BUTTON_RIGHT:
			_yaw -= event.relative.x * 0.006
			_elevation = clampf(_elevation + event.relative.y * 0.15, 25.0 if _perspective else 32.0, 82.0)
		else:
			follow_selected = false
			_centering = false
			var current: Vector2 = event.position * scale
			var previous: Vector2 = current - event.relative * scale
			_focus = _clamp_focus(_focus + _screen_ground(previous) - _screen_ground(current))
		_update_observer()

func focus_agent() -> void:
	if agent_nodes.has(selected_agent):
		center_agent()
		follow_selected = true

func center_agent() -> void:
	if agent_nodes.has(selected_agent):
		_set_focus(_resident_focus(), 13.0, true)

func _resident_focus() -> Vector3:
	if _seat_motion.has(selected_agent):
		return agent_pose_nodes[selected_agent].global_position + Vector3.UP * 0.82
	return agent_nodes[selected_agent].position + Vector3.UP * 0.88

func _set_focus(point: Vector3, zoom_limit: float, smooth: bool) -> void:
	if not _overview_return.is_empty():
		restore_camera(_overview_return)
		set_first_person(false)
		smooth = false
	follow_selected = false
	_focus_goal = _clamp_focus(point)
	_centering = smooth
	_user_camera = true
	_zoom = minf(_zoom, zoom_limit)
	if not smooth:
		_focus = _focus_goal
	_update_observer()

func _clamp_focus(point: Vector3) -> Vector3:
	if _fit_bounds.size() != 4:
		return point
	var margin := minf(_zoom * 0.12, 8.0)
	var x := clampf(point.x, float(_fit_bounds[0]) - margin, float(_fit_bounds[1]) + margin)
	var z := clampf(point.z, float(_fit_bounds[2]) - margin, float(_fit_bounds[3]) + margin)
	return Vector3(x, point.y, z)

func _screen_ground(point: Vector2) -> Vector3:
	var start := observer_camera.project_ray_origin(point)
	var direction := observer_camera.project_ray_normal(point)
	if direction.y >= -0.001 or start.y <= 0.0:
		return Vector3(_focus.x,0.0,_focus.z)
	return start + direction * (-start.y / direction.y)

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
	var texture: Texture2D = _portrait.update_appearance(data)
	_portrait.preview_conversation(_faces.get(str(data.get("id", ""))), _face_clock)
	return texture

func suspend_character_preview() -> void:
	if is_instance_valid(_portrait):_portrait.suspend()

func handle_character_preview_input(event: InputEvent) -> void:
	if is_instance_valid(_portrait):_portrait.handle_input(event)

func _environment(palette_id: String) -> void:
	var palette := Art.palette(palette_id)
	var node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = palette.background
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = palette.ambient
	env.ambient_light_energy = palette.ambient_energy
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	var residence := palette_id == "warm"
	if residence:
		_residence_environment(env)
	node.environment = env
	_content.add_child(node)
	var sun := DirectionalLight3D.new()
	sun.name="Sun"
	sun.rotation_degrees = palette.sun_rotation
	sun.light_color = palette.key
	sun.light_energy = palette.key_energy
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 72
	sun.light_angular_distance = 1.7
	if residence:
		# Regular filtering keeps the contact shadows stable on skinned cloth.
		sun.light_angular_distance = 0.0
		sun.directional_shadow_max_distance = 96.0
	_content.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.name="Fill"
	fill.rotation_degrees = Vector3(-48, 145, 0)
	fill.light_color = palette.fill
	fill.light_energy = palette.fill_energy
	if residence:
		fill.rotation_degrees = Vector3(-32.0, 133.0, 0.0)
	_content.add_child(fill)
	if residence:
		_residence_lighting = ResidenceLighting.new()
		_residence_lighting.configure(env, sun, fill)

func _residence_environment(environment: Environment) -> void:
	var material := ProceduralSkyMaterial.new()
	material.sky_top_color = Color("6997b9")
	material.sky_horizon_color = Color("c7ced0")
	material.ground_horizon_color = Color("c0c7c9")
	material.ground_bottom_color = Color("505c5d")
	material.sky_curve = .16
	material.ground_curve = .11
	material.sun_angle_max = 14.0
	var sky := Sky.new()
	sky.sky_material = material
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	environment.sky = sky
	environment.background_mode = Environment.BG_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("dedbd4")
	environment.ambient_light_energy = .42
	environment.ambient_light_sky_contribution = .16
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.fog_enabled = true
	environment.fog_density = .0008
	environment.fog_light_color = Color("abbabe")
	environment.fog_sky_affect = 0.0
	if RenderingServer.get_current_rendering_method() == "forward_plus":
		environment.tonemap_mode = Environment.TONE_MAPPER_AGX
		environment.ssao_enabled = true
		environment.ssao_radius = 1.25
		environment.ssao_intensity = 1.45
		environment.ssil_radius = 1.3
		environment.ssil_intensity = 0.38
	else:
		environment.ambient_light_energy = .36

func _build_map(geometry: Dictionary) -> void:
	var bounds: Array = geometry.get("bounds", [-12,12,-9,9])
	var width: float = float(bounds[1])-float(bounds[0])
	var depth: float = float(bounds[3])-float(bounds[2])
	var center := Vector3((float(bounds[0])+float(bounds[1]))*0.5,0,(float(bounds[2])+float(bounds[3]))*0.5)
	var palette:String=str(geometry.get("palette","teal"))
	var residence := palette == "warm"
	if not residence:
		_box(_content, Vector3(width+0.7,0.45,depth+0.7), center+Vector3(0,-0.28,0), Color("343b48"))
	var art := Art.palette(palette)
	var palette_trim:Color=art.trim
	var dressing: Dictionary = ResidenceScenery.new().build(_content, geometry, WORLD, WALLS) if residence else {}
	var roof_details: Dictionary = dressing.get("roof_details", {})
	var room_facades: Dictionary = dressing.get("room_facades", {})
	var floor_mesh: MeshInstance3D = _box(_content, Vector3(width,0.12,depth),center+Vector3(0,-0.04,0),Color("c9c2ad"))
	floor_mesh.material_override = _surface_material(str(art.ground_surface),art.ground)
	if residence:
		floor_mesh.material_override = ResidenceScenery.surface("stone_setts", Color("b2aba3"), .44)
	var residence_wall: StandardMaterial3D
	if residence:
		residence_wall = ResidenceScenery.surface("lime_stucco", Color("d6bda3"), .95)
	for wall in geometry.get("walls", []):
		if dressing.get("walls_ready", false):
			continue
		var p: Array = wall.get("center",[0,0])
		var s: Array = wall.get("size",[0.2,1.0])
		var h: float = float(wall.get("height",3.0))
		var wall_mesh := _box(_content,Vector3(float(s[0]),h,float(s[1])),Vector3(float(p[0]),h*0.5,float(p[1])),Color("c9c5b7"),WALLS)
		wall_mesh.material_override = residence_wall if residence else _surface_material(str(art.wall_surface),art.wall)
		_box(_content,Vector3(float(s[0])+0.06,0.22,float(s[1])+0.06),Vector3(float(p[0]),0.11,float(p[1])),palette_trim.darkened(0.28),WORLD)
		_box(_content,Vector3(float(s[0])+0.07,0.08,float(s[1])+0.07),Vector3(float(p[0]),h-0.04,float(p[1])),palette_trim,WALLS)
		_shape_facade(wall_mesh,geometry.get("rooms",[]),Vector2(float(p[0]),float(p[1])),Vector2(float(s[0]),float(s[1])),h,palette_trim,palette)
	for door in geometry.get("doors", []):
		var p: Array = door.get("center",[0,0])
		var s: Array = door.get("size",[0.2,1.6])
		if residence:
			_build_residence_door(door,Vector2(float(p[0]),float(p[1])),Vector2(float(s[0]),float(s[1])))
			continue
		var pivot := Node3D.new()
		pivot.position = Vector3(float(p[0]),0,float(p[1]))
		_content.add_child(pivot)
		var panel := _box(pivot,Vector3(float(s[0]),2.65,float(s[1])),Vector3(0,1.325,0),Color("8c6951"),WALLS)
		var door_finish := "wood" if palette!="blue" else "enamel_panel"
		panel.material_override = _surface_material(door_finish,palette_trim.lightened(0.10),1.25)
		_box(pivot,Vector3(float(s[0])+0.04,0.28,float(s[1])*0.65),Vector3(0,1.6,0),Color("547e82"),WALLS)
		_box(pivot,Vector3(0.08,0.09,0.24),Vector3(-float(s[0])*0.6,1.05,float(s[1])*0.32),Color("d5c292"),WALLS)
		door_nodes[str(door.get("id", ""))] = pivot
		_box(_content,Vector3(float(s[0])+0.15,0.05,float(s[1])+0.1),Vector3(float(p[0]),0.04,float(p[1])),Color("caa969"))
	for prop in geometry.get("props", []):
		_build_prop(prop, palette)
	for room in geometry.get("rooms", []):
		var pos: Array = room.get("center",[0,0])
		var room_size: Array = room.get("size",[4,4])
		var room_name: String = str(room.get("label",room.get("name","")))
		var function:String=str(room.get("function",""))
		var base_material:=Art.room_surface(palette,function)
		var tint:Color=art.room_floor_tints.get(function,Color("c6c8bd"))
		var room_floor := _box(_content,Vector3(float(room_size[0])-0.25,0.018,float(room_size[1])-0.25),Vector3(float(pos[0]),0.035,float(pos[1])),Color.WHITE)
		room_floor.material_override = _surface_material(base_material,tint)
		if residence and function in ["common", "bedroom", "shop"]:
			var floor_finish := "courtyard_paver" if function == "shop" else "oak_planks"
			var floor_tone := Color("c0c5b9") if function == "shop" else Color("c8b69c")
			room_floor.material_override = ResidenceScenery.surface(floor_finish, floor_tone, .52)
		if function in ["common","bedroom"] and palette!="blue" and not dressing.get("rugs_ready", false):
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
		var room_id := str(room.get("id", ""))
		_build_ceiling(Vector2(float(pos[0]),float(pos[1])),Vector2(float(room_size[0]),float(room_size[1])),palette,roof_details.get(room_id, []),room_facades.get(room_id, []))
		_label(_content,room_name,Vector3(float(pos[0]),0.1,float(pos[1])),Color("e6e3cc"),0.010,true)
	_batch_architecture()
	if residence:
		for normal: Vector2 in dressing.facades:
			_facades.append({"normal": normal, "meshes": dressing.facades[normal]})
		_residence_canopies = dressing.canopies
	else:
		Art.decorate_site(_content,geometry,WORLD)

func _build_residence_door(door: Dictionary, at: Vector2, extent: Vector2) -> void:
	var along_x := extent.x > extent.y
	var across := Vector3.RIGHT if along_x else Vector3.BACK
	var depth := Vector3.BACK if along_x else Vector3.RIGHT
	var width := maxf(extent.x,extent.y)
	var height := float(door.get("height",2.8))
	var center := Vector3(at.x,0,at.y)
	var leaf := Node3D.new()
	leaf.position = center
	leaf.set_meta("closed_position",center)
	leaf.set_meta("slide_offset",across * (width + .025))
	_content.add_child(leaf)
	var frame_color := Color("51483c")
	var wood_color := Color("77654b")
	var panel := _box(leaf,across * width + depth * .087 + Vector3.UP * (height - .15),Vector3.UP * (height * .5 - .066),wood_color,WALLS)
	panel.material_override = _surface_material("wood",wood_color,.84)
	for side: float in [-1.0,1.0]:
		var face := side * depth
		_box(leaf,across * (width - .32) + depth * .018 + Vector3.UP * .64,Vector3.UP * (height - .77) + face * .049,Color("423f39"),WALLS)
		_box(leaf,across * (width - .44) + depth * .019 + Vector3.UP * .54,Vector3.UP * (height - .77) + face * .061,Color("687672"),WALLS)
		_box(leaf,across * .16 + depth * .07 + Vector3.UP * .025,across * (-width * .5 + .20) + Vector3.UP * 1.06 + face * .076,Color("b3a087"),WALLS)
		var jamb_size := across * .094 + depth * .22 + Vector3.UP * height
		_box(_content,jamb_size,center + across * (side * width * .5) + Vector3.UP * height * .5,frame_color,WALLS)
	var lintel := across * (width + .10) + depth * .22 + Vector3.UP * .15
	_box(_content,lintel,center + Vector3.UP * (height - .075),frame_color,WALLS)
	var threshold := across * (width + .10) + depth * .38 + Vector3.UP * .034
	_box(_content,threshold,center + Vector3.UP * .026,Color("a49177"),WORLD)
	door_nodes[str(door.id)] = leaf

func _batch_architecture() -> void:
	var facade_normals := {}
	for facade in _facades:
		for face in facade.meshes:
			facade_normals[face] = facade.normal
	var groups := {}
	for child in _content.get_children():
		var node := child as MeshInstance3D
		if node == null or not node.mesh is BoxMesh or node.has_meta("room_roof"):
			continue
		var normal: Vector2 = facade_normals.get(node,Vector2.ZERO)
		var section := Vector2i(floori(node.position.x/36.0),floori(node.position.z/36.0))
		var key := [node.material_override, node.layers, node.cast_shadow, normal, section]
		if not groups.has(key):groups[key]=[]
		groups[key].append(node)
	var shared_box := BoxMesh.new()
	for key in groups:
		var nodes: Array = groups[key]
		if nodes.size() < 3:
			continue
		var instances := MultiMesh.new()
		instances.transform_format=MultiMesh.TRANSFORM_3D
		instances.mesh=shared_box
		instances.instance_count=nodes.size()
		for index in nodes.size():
			var node: MeshInstance3D = nodes[index]
			var size: Vector3 = node.mesh.size
			instances.set_instance_transform(index,node.transform.scaled_local(size))
			node.free()
		var batch := MultiMeshInstance3D.new()
		batch.name="ArchitectureBatch"
		batch.layers=key[1]
		batch.cast_shadow=key[2]
		batch.material_override=key[0]
		batch.multimesh=instances
		_content.add_child(batch,true)
		if key[3] != Vector2.ZERO:_facades.append({"normal":key[3],"meshes":[batch]})
	for facade in _facades:
		facade.meshes=facade.meshes.filter(func(node):return is_instance_valid(node))

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
	var faces: Array = [wall]
	var length := maxf(size.x,size.y)
	var normal := Vector3(outward.x,0,outward.y)
	var tangent := Vector3.RIGHT if along_x else Vector3.BACK
	var base := Vector3(at.x,0,at.y) - normal * (minf(size.x,size.y)*0.5)
	var cap := Vector3(size.x+0.045,0.14,size.y+0.045)
	var band := _box(_content,cap,Vector3(at.x,h-0.14,at.y),accent.darkened(0.12),WALLS)
	band.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	faces.append(band)
	if length >= 3.0:
		match palette:
			"warm":
				var window_width := minf(1.82,length*0.38)
				var exterior := base + normal * minf(size.x,size.y)
				var surround := _facade_piece(exterior + Vector3.UP * .28,-normal,along_x,length,.56,.074,Color("a39b8d"))
				surround.material_override = _surface_material("concrete_slab",Color("a39b8d"),1.18)
				faces.append(surround)
				for side: float in [-1.0,1.0]:
					var center := base + tangent * (side*length*0.24) + Vector3.UP*(h*0.61)
					_window_trim(faces,center,normal,tangent,along_x,window_width,1.27,Color("4e4a40"),Color("75817a"))
					_residence_exterior_window(faces,center + normal * minf(size.x,size.y),normal,tangent,along_x,window_width)
			"blue":
				var panel_width := minf(3.45,length*0.59)
				var center := base + Vector3.UP*(h*0.59)
				faces.append(_facade_piece(center,normal,along_x,panel_width,1.08,0.044,accent.darkened(0.48)))
				faces.append(_facade_piece(center+Vector3.UP*0.31,normal,along_x,panel_width*0.92,0.032,0.069,Color("bd9c65")))
				faces.append(_facade_piece(center-Vector3.UP*0.29,normal,along_x,panel_width*0.93,0.095,0.068,Color("788a90")))
				for side: float in [-1.0,1.0]:
					var pillar := base + tangent*(side*length*0.39)+Vector3.UP*(h*0.50)
					faces.append(_facade_piece(pillar,normal,along_x,0.15,h*0.84,0.115,Color("556771")))
			_:
				var span := minf(length*0.63,4.4)
				var center := base+Vector3.UP*(h*0.70)
				_window_trim(faces,center,normal,tangent,along_x,span,0.80,accent.darkened(0.49),Color("789292"))
				faces.append(_facade_piece(base+Vector3.UP*0.91,normal,along_x,length,.12,.062,accent))
	if length >= 6.5 and not room_label.is_empty():
		var mount := base+tangent*(length*.37)+Vector3.UP*(h*.45)
		faces.append(_facade_piece(mount,normal,along_x,1.48,.38,.066,accent.darkened(.52)))
		var sign:=Label3D.new()
		sign.text=room_label;sign.layers=WALLS;sign.font_size=32;sign.pixel_size=.0035
		sign.width=345;sign.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
		sign.outline_size=0;sign.double_sided=false;sign.modulate=Color("efe6cb")
		sign.position=mount-normal*.072;sign.rotation.y=atan2(-normal.x,-normal.z)
		_content.add_child(sign);faces.append(sign)
	_facades.append({"normal":outward,"meshes":faces})

func _residence_exterior_window(faces: Array, center: Vector3, outward: Vector3,
		tangent: Vector3, along_x: bool, width: float) -> void:
	var recess := Color("44423d")
	var frame := Color("9b8c79")
	var normal := -outward
	faces.append(_facade_piece(center, normal, along_x, width + .22, 1.44, .051, frame))
	faces.append(_facade_piece(center, normal, along_x, width, 1.27, .062, recess))
	for side: float in [-1.0, 1.0]:
		var pane := center + tangent * side * width * .237 + Vector3.UP * .026
		var pane_color := Color("6f8075") if side < 0.0 else Color("768e86")
		var glass := _facade_piece(pane,normal,along_x,width*.43,1.105,.073,pane_color)
		var key := "residence_glass_" + pane_color.to_html()
		if not _material_cache.has(key):
			var material := _material(pane_color).duplicate() as StandardMaterial3D
			material.metallic = .17
			material.metallic_specular = .67
			material.roughness = .26
			_material_cache[key] = material
		glass.material_override = _material_cache[key]
		faces.append(glass)
	var crossbar := center - Vector3.UP * .12
	faces.append(_facade_piece(crossbar, normal, along_x, width, .052, .090, recess))
	faces.append(_facade_piece(center - Vector3.UP * .73, normal, along_x, width + .39, .10, .24, frame))
	faces.append(_facade_piece(center + Vector3.UP * .72, normal, along_x, width + .29, .11, .22, frame))

func _facade_piece(center: Vector3, normal: Vector3, along_x: bool, width: float, height: float, depth: float, color: Color) -> MeshInstance3D:
	var dimensions := Vector3(width,height,depth) if along_x else Vector3(depth,height,width)
	var piece := _box(_content,dimensions,center-normal*depth*.52,color,WALLS)
	piece.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return piece

func _window_trim(faces: Array, center: Vector3, normal: Vector3, tangent: Vector3, along_x: bool, width: float, height: float, frame: Color, glass: Color) -> void:
	faces.append(_facade_piece(center,normal,along_x,width,height,.055,frame))
	for side: float in [-1.0,1.0]:
		var pane := center+tangent*(side*width*.245)+Vector3.UP*.015
		faces.append(_facade_piece(pane,normal,along_x,width*.45,height*.80,.063,glass))
	faces.append(_facade_piece(center-Vector3.UP*(height*.52),normal,along_x,width*1.04,.07,.20,frame.lightened(.18)))

func _build_ceiling(at: Vector2, size: Vector2, palette: String, details: Array, facades: Array) -> void:
	var color := Color("777e80") if palette=="blue" else (Color("a39b86") if palette=="warm" else Color("8a9288"))
	var height := 3.05 if palette=="blue" else 3.0
	if palette == "warm":
		var roof := _box(_content,Vector3(size.x+.52,.24,size.y+.52),Vector3(at.x,2.81,at.y),Color("756758"),WALLS)
		roof.material_override = _surface_material("wall",Color("c6b8a6"),.76)
		roof.set_meta("room_roof",true)
		var bounds := roof.global_transform * roof.get_aabb()
		for mesh: GeometryInstance3D in details:
			bounds = bounds.merge(mesh.global_transform * mesh.get_aabb())
		var room := Rect2(at-size*.5,size)
		var volume := AABB(Vector3(room.position.x, 0.0, room.position.y), Vector3(room.size.x, bounds.end.y, room.size.y))
		_residence_roofs.append({"mesh":roof, "details":details, "room":room, "bounds":bounds,
			"volume":volume, "facades":facades, "visible":null})
		return
	var ceiling := _box(_content,Vector3(size.x+.09,.10,size.y+.09),Vector3(at.x,height,at.y),color,WALLS)
	ceiling.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ceiling.material_override=_surface_material("enamel_panel" if palette=="blue" else "wall",color)
	var fixture := _material(Color("dadaaa") if palette=="warm" else Color("b9cbd0")).duplicate() as StandardMaterial3D
	fixture.emission_enabled=true
	fixture.emission=fixture.albedo_color
	fixture.emission_energy_multiplier=.45
	for side: float in [-1.0,1.0]:
		var x := at.x+side*size.x*.23
		var mounting := Vector3(x,height-.078,at.y)
		var casing := _box(_content,Vector3(2.95,.10,.34),mounting,color.darkened(.45),WALLS)
		var diffuser := _box(_content,Vector3(2.76,.034,.265),mounting-Vector3.UP*.058,Color.WHITE,WALLS)
		casing.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		diffuser.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		diffuser.material_override=fixture

func _update_facades() -> void:
	var sight_target := _resident_focus() if follow_selected and agent_nodes.has(selected_agent) else _focus
	var focus_xz := Vector2(sight_target.x,sight_target.z)
	var camera_origin := observer_camera.global_position
	var direction := Vector2(sin(_yaw),cos(_yaw))
	var yaw_changed := not is_finite(_last_facade_yaw) or not is_equal_approx(_last_facade_yaw,_yaw)
	# The observer can cut away overhead obstructions. Private cameras always see them.
	for entry in _residence_roofs:
		var area: Rect2 = entry.room
		var roof: MeshInstance3D = entry.mesh
		var bounds: AABB = entry.bounds
		if not entry.facades.is_empty():
			bounds = entry.volume
		var visible_to_observer := _perspective and not area.grow(2.3).has_point(focus_xz) \
			and bounds.grow(.5).intersects_segment(camera_origin,sight_target) == null
		var layers := WALLS | CUTAWAY if visible_to_observer else WALLS
		if roof.layers != layers:roof.layers = layers
		for fixture: GeometryInstance3D in entry.details:
			if fixture.layers != layers:fixture.layers = layers
		if yaw_changed or entry.visible != visible_to_observer:
			entry.visible = visible_to_observer
			for facade: Dictionary in entry.facades:
				var wall_layers := WALLS | CUTAWAY if visible_to_observer or facade.normal.dot(direction) < -0.12 else WALLS
				for mesh: GeometryInstance3D in facade.meshes:
					if mesh.layers != wall_layers:
						mesh.layers = wall_layers
	for entry: Dictionary in _residence_canopies:
		var normal: Vector2 = entry.normal
		var bounds: AABB = entry.bounds
		var blocks_focus := _perspective and bounds.grow(.5).intersects_segment(camera_origin,sight_target) != null
		var layers := WALLS | CUTAWAY if normal.dot(direction) < -.12 and not blocks_focus else WALLS
		for mesh: GeometryInstance3D in entry.meshes:
			if mesh.layers != layers:mesh.layers = layers
	if not yaw_changed:return
	_last_facade_yaw=_yaw
	for facade in _facades:
		var layer:int=WALLS|CUTAWAY if facade.normal.dot(direction)<-0.12 else WALLS
		for mesh in facade.meshes:mesh.layers=layer

func _build_prop(prop: Dictionary, palette: String) -> void:
	var kind: String = str(prop.get("kind", "table"))
	var p: Array = prop.get("center",[0,0])
	var s: Array = prop.get("size",[1.0,1.0])
	var height: float = float(prop.get("height",0.8))
	var root := Node3D.new()
	root.name = "Prop_"+str(prop.get("id",kind))
	root.position = Vector3(float(p[0]),0,float(p[1]))
	root.rotation.y = deg_to_rad(float(prop.get("angle",0)))
	_content.add_child(root)
	if kind in ["terminal","shop"]:
		_service_signage(root, kind, Vector2(float(s[0]), float(s[1])), height, palette == "warm" and kind == "shop")
	var asset: Node3D
	if palette == "warm":
		asset = ResidenceScenery.replacement(kind, str(prop.get("id", "")))
	if asset == null:
		asset = _instantiate_asset(kind)
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
			for side: float in [-1.0,1.0]:
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

func _service_signage(parent: Node3D, kind: String, size: Vector2, height: float, compact: bool) -> void:
	# Printed plates live on the real device: no billboard, observer overlay or hidden state.
	for side in ([2] if compact else [0, 1, 2, 3]):
		var face:=Node3D.new();face.name="PrintedServicePlate_%d"%side
		face.rotation.y=float(side)*PI*0.5
		var side_width:float=size.x if side%2==0 else size.y
		var extent:float=size.y if side%2==0 else size.x
		var offset := extent * 0.5 + (0.013 if compact else 0.025)
		face.position=Vector3(sin(face.rotation.y)*offset,height*(0.56 if compact else 0.77),cos(face.rotation.y)*offset);parent.add_child(face)
		var width:float=minf(side_width*0.94,0.86 if compact else 1.15)
		_box(face,Vector3(width,0.24 if compact else 0.42,0.018 if compact else 0.035),Vector3.ZERO,Color("31443e") if compact else Color("1b343c"))
		var label:=Label3D.new();label.name="PrintedServiceName";label.text="ПАЙКИ\nRATIONS" if kind=="terminal" else "МАГАЗИН\nSHOP"
		label.position.z=0.021;label.font_size=48 if compact else 64;label.pixel_size=width/(430.0 if compact else 300.0);label.modulate=Color("f2dfaa");label.outline_size=0;label.layers=WORLD
		label.billboard=BaseMaterial3D.BILLBOARD_DISABLED;label.no_depth_test=false;label.double_sided=false;label.shaded=false;face.add_child(label)
		if kind=="terminal":
			# A static dispense hatch and illuminated physical push button identify the affordance.
			_box(face,Vector3(width*0.65,0.19,0.045),Vector3(0,-0.39,0.015),Color("17242b"))
			_box(face,Vector3(width*0.58,0.025,0.14),Vector3(0,-0.48,0.055),Color("84918b"))
			_box(face,Vector3(0.09,0.09,0.035),Vector3(width*0.35,-0.23,0.027),Color("c6a461"))

func _build_observer(geometry: Dictionary) -> void:
	var window_size: Vector2i=Vector2i(get_viewport().get_visible_rect().size)
	observer_viewport = _viewport("Observer",Vector2i(maxi(640,window_size.x),maxi(480,window_size.y)))
	observer_viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED if first_person else SubViewport.UPDATE_ALWAYS
	observer_camera=Camera3D.new()
	observer_camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	observer_camera.cull_mask=WORLD|CUTAWAY|DISPLAY_BODY|DISTANT_BODY|OVERLAY
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
	_yaw=-0.48;_elevation=51.0
	_update_observer()
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
	_overview_zoom=maxf(max_y-min_y,(max_x-min_x)/aspect)*1.10
	_zoom=_overview_zoom
	_update_observer()

func _update_observer() -> void:
	if not is_instance_valid(observer_camera): return
	var distance := 45.0
	if _perspective:
		var fov := 40.0
		if observer_camera.projection!=Camera3D.PROJECTION_PERSPECTIVE:
			observer_camera.set_perspective(fov,0.08,200.0)
		distance = _zoom * 0.5 / tan(deg_to_rad(fov * 0.5))
	else:
		if observer_camera.projection!=Camera3D.PROJECTION_ORTHOGONAL:
			observer_camera.set_orthogonal(_zoom,0.05,150.0)
		observer_camera.size = _zoom
	var e:=deg_to_rad(_elevation)
	observer_camera.position=_focus+Vector3(sin(_yaw)*cos(e),sin(e),cos(_yaw)*cos(e))*distance
	observer_camera.look_at(_focus,Vector3.UP)
	_update_facades()
	_update_observer_lod()

func _update_observer_lod() -> void:
	# Private eyes retain detailed actors on their own layers at every zoom.
	var population := agent_nodes.size()
	var use_proxies := OS.has_feature("web") and _quality != "high" and population > 0 and (_zoom > 38.0 or population > 8)
	if use_proxies==_use_proxies:return
	_use_proxies=use_proxies
	_near_observer.clear()
	if _use_proxies and not is_instance_valid(_proxy_group):_create_proxies()
	if is_instance_valid(_proxy_group):_proxy_group.visible=_use_proxies
	for id in agent_nodes:
		_restore_body_layer(str(id))
	if _use_proxies:_update_proxy_instances()

func _restore_body_layer(id: String) -> void:
	var layer := SELECTED_BODY if id == selected_agent else BODIES
	if id != selected_agent and id == _capture_actor and Engine.get_frames_drawn() <= _capture_frame + 1:
		layer = CAPTURE_BODY
	_set_body_layer(id, layer)

func _update_near_observer() -> void:
	var next: Dictionary = {}
	if _zoom <= 38.0:
		var candidates: Array[Dictionary] = []
		for id in agent_nodes:
			if id == selected_agent:continue
			var point: Vector3 = agent_nodes[id].position + Vector3.UP
			if not observer_camera.is_position_in_frustum(point):continue
			# Retain nearby rigs through small movements at the detail boundary.
			var distance := point.distance_squared_to(_focus) * (0.83 if _near_observer.has(id) else 1.0)
			candidates.append({"id": id, "distance": distance})
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance < b.distance)
		for index in mini(WEB_CLOSE_RESIDENTS, candidates.size()):
			next[candidates[index].id] = true
	var previous := _near_observer
	_near_observer = next
	for id in previous:
		if not next.has(id):_restore_body_layer(id)
	for id in next:
		if not previous.has(id):_restore_body_layer(id)

func _create_proxies() -> void:
	_proxy_group=Node3D.new()
	_proxy_group.name="DistantResidents"
	_content.add_child(_proxy_group)
	var material:=StandardMaterial3D.new()
	material.vertex_color_use_as_albedo=true
	material.roughness=.9
	var parts: Array[Vector3]=[Vector3(.21,.66,1),Vector3(.126,.265,1),Vector3(.078,.71,2),Vector3(.061,.54,2)]
	for part in parts:
		var shape:=CapsuleMesh.new()
		shape.radius=part.x;shape.height=part.y;shape.radial_segments=8;shape.rings=3
		shape.material=material
		var instances:=MultiMesh.new()
		instances.transform_format=MultiMesh.TRANSFORM_3D
		instances.use_colors=true
		instances.mesh=shape
		instances.instance_count=agent_nodes.size()*int(part.z)
		var proxy:=MultiMeshInstance3D.new()
		proxy.layers=DISTANT_BODY
		proxy.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		proxy.multimesh=instances
		_proxy_group.add_child(proxy)
		_proxies.append(instances)

func _update_proxy_instances() -> void:
	_update_near_observer()
	var index:=0
	var now:=Time.get_ticks_msec()*.012
	for id in agent_nodes:
		var node: Node3D=agent_nodes[id]
		var transform:=node.transform
		var data: Dictionary=_state.get("agents",{}).get(id,{})
		if id==selected_agent or _near_observer.has(id):transform.origin.y=-150.0
		elif not bool(data.get("alive",true)) or bool(data.get("sleeping",false)) or bool(data.get("unconscious",false)):
			transform.basis=transform.basis*Basis(Vector3.RIGHT,PI*.5)
			transform.origin.y+=.22
		var height:=float(data.get("appearance",{}).get("height",1.0))
		transform.basis=transform.basis.scaled(Vector3(1.0,height,1.0))
		var clothing:=Color.from_string(str(data.get("color","83988b")),Color("83988b"))
		var skin:=Color.from_string(str(data.get("skin","d9b497")),Color("d9b497"))
		_proxy_part(0,index,transform,Vector3(0,1.08,0),0.0,clothing)
		_proxy_part(1,index,transform,Vector3(0,1.53,0),0.0,skin)
		var walking: bool=_animation_choices.get(id,"") in ["Walk_Loop","Crawl_Loop"]
		var step:=sin(now+float(index)*1.9)*.28 if walking else 0.0
		for limb in 2:
			var side:=float(limb*2-1)
			_proxy_part(2,index*2+limb,transform,Vector3(side*.112,.41,0),step*side,Color("34494d"))
			_proxy_part(3,index*2+limb,transform,Vector3(side*.235,1.04,0),-step*side,clothing.darkened(.16))
		index+=1

func _proxy_part(part: int, index: int, transform: Transform3D, position: Vector3, pitch: float, color: Color) -> void:
	_proxies[part].set_instance_transform(index,transform*Transform3D(Basis(Vector3.RIGHT,pitch),position))
	_proxies[part].set_instance_color(index,color)

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
	_bind_held_marker(id, pose)
	_label(root,str(data.get("name",id)),Vector3(0,2.05,0),Color.from_string(str(data.get("color","eecf83")),Color.WHITE).lightened(0.25),0.0055)
	var viewport:=_viewport("Eyes_"+id,EYES_SIZE)
	viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
	agent_viewports[id]=viewport
	var camera:=Camera3D.new(); camera.fov=74; camera.near=0.045; camera.far=24
	viewport.add_child(camera); camera.current=true
	agent_cameras[id]=camera
	_targets[id]={"position":Vector3.ZERO,"heading":0.0}
	_animate(id,data,0.0)

func _fallback_human(parent: Node3D, color: String) -> void:
	var clothing:=Color.from_string(color,Color("83bfa9"))
	var torso:=CapsuleMesh.new(); torso.radius=0.24; torso.height=0.72
	_mesh(parent,torso,Vector3(0,1.0,0),clothing)
	for side: float in [-1.0,1.0]:
		var limb:=CapsuleMesh.new(); limb.radius=0.085; limb.height=0.7
		_mesh(parent,limb,Vector3(side*0.13,0.4,0),Color("344551"))
		_mesh(parent,limb,Vector3(side*0.32,1.02,0),clothing)
	var head:=SphereMesh.new(); head.radius=0.21; head.height=0.43
	_mesh(parent,head,Vector3(0,1.57,0),Color("e0bca0"))
	_box(parent,Vector3(0.4,0.13,0.36),Vector3(0,1.75,0.03),Color("59443b"))
	for side: float in [-1.0,1.0]:
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
			_models[id].free(); _players.erase(id); _animation_keys.erase(id); _animation_choices.erase(id); _clip_names.erase(id)
			_faces.erase(id)
			pose.add_child(replacement); _models[id]=replacement; _model_faces[id]=face
			_fit_asset(replacement,Vector3(0.8,1.78,0.55),true); replacement.rotation.y=PI
			var player:=_find_animation(replacement)
			if player!=null: _players[id]=player
			_bind_held_marker(id,pose)
			_meshes[id]=[]; _collect_meshes(pose,_meshes[id]); _set_body_layer(id,SELECTED_BODY if id==selected_agent else BODIES)
	var height: float=clampf(float(appearance.get("height",1.0)),0.8,1.25)
	var build: float=clampf(float(appearance.get("build",1.0)),0.75,1.3)
	pose.scale=Vector3(build,height,build)
	var clothing:=Color.from_string(color,Color("83bfa9"))
	CharacterFinish.apply(_meshes.get(id, []), appearance, clothing, _outfit_material(clothing, int(appearance.get("outfit", 0))))
	if _models.has(id) and not _faces.has(id):
		var modifier := FaceShape.new()
		modifier.name = "FaceShape"
		if modifier.bind_model(_models[id], id):
			_faces[id] = modifier
		else:
			modifier.free()
	if _faces.has(id):
		_faces[id].set_face_variant(posmod(int(int(appearance.get("face",0))/2),3))

func _apply_pose(id: String, data: Dictionary, immediate: bool) -> void:
	var body: Dictionary=data.get("body",{})
	var crawl: bool=body.get("left_leg")=="broken" and body.get("right_leg")=="broken"
	var prone: bool=not bool(data.get("alive",true)) or bool(data.get("sleeping",false)) or bool(data.get("unconscious",false))
	var pose: Node3D=agent_pose_nodes[id]
	if not _players.has(id):
		pose.rotation.x=deg_to_rad(-75) if crawl else 0.0
		pose.rotation.z=deg_to_rad(88) if prone else 0.0
		pose.position=Vector3(0,0.25,0.4) if crawl else (Vector3(0,0.27,0) if prone else Vector3.ZERO)
	elif immediate:
		var rendered: Dictionary = _state.agents[id]
		if _seat_motion.has(id) or not rendered.seat.is_empty():
			_clear_seat_pose(id)
			_animation_choices.erase(id)
			_animate(id, rendered, 0.0)
			_update_seat_pose(id)
		_update_wardrobe(id)

func _update_wardrobe(id: String) -> void:
	var player: AnimationPlayer = _players.get(id)
	if is_instance_valid(player):
		var phase := clampf(player.current_animation_position / maxf(player.current_animation_length, 0.001), 0.0, 1.0)
		WardrobeDeformation.apply(_models.get(id), str(player.current_animation), phase)

func _clear_seat_pose(id: String) -> void:
	_seat_motion.erase(id)
	var pose: Node3D = agent_pose_nodes[id]
	pose.position = Vector3.ZERO
	pose.rotation.y = 0.0
	var solver: Variant = _seat_leg_solvers.get(id)
	if is_instance_valid(solver):
		solver.active = false
		solver.get_parent().get_node("SeatFootLevel").active = false
		SeatedHandContact.clear(solver)

func _seat_leg_solver(id: String) -> TwoBoneIK3D:
	var existing: Variant = _seat_leg_solvers.get(id)
	if is_instance_valid(existing):return existing
	var model: Node3D = _models[id]
	var skeletons := model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():return null
	var skeleton := skeletons[0] as Skeleton3D
	var solver := TwoBoneIK3D.new()
	solver.name = "SeatFootContact"
	solver.active = false
	solver.setting_count = 2
	skeleton.add_child(solver)
	for index in range(2):
		var suffix := "l" if index == 0 else "r"
		var target := Node3D.new()
		target.name = "Foot_" + suffix
		solver.add_child(target)
		var pole := Node3D.new()
		pole.name = "Knee_" + suffix
		solver.add_child(pole)
		solver.set_root_bone_name(index,"thigh_" + suffix)
		solver.set_middle_bone_name(index,"calf_" + suffix)
		solver.set_end_bone_name(index,"foot_" + suffix)
		solver.set_use_virtual_end(index,false)
		solver.set_target_node(index,solver.get_path_to(target))
		solver.set_pole_node(index,solver.get_path_to(pole))
	var leveling := SeatedFootLevel.new()
	leveling.name = "SeatFootLevel"
	leveling.active = false
	skeleton.add_child(leveling)
	leveling.bind_model(model)
	_seat_leg_solvers[id] = solver
	return solver

func _update_seat_pose(id: String) -> void:
	if not _seat_motion.has(id):return
	if not _players.has(id):
		_clear_seat_pose(id)
		return
	var player: AnimationPlayer = _players[id]
	var clip := str(player.current_animation)
	var progress := clampf(player.current_animation_position / maxf(player.current_animation_length, .001),0.0,1.0)
	var amount := 1.0
	var entering := clip.ends_with("Sitting_Enter")
	var exiting := clip.ends_with("Sitting_Exit")
	if entering:
		amount = smoothstep(.20, .78, progress)
	elif exiting:
		amount = 1.0 - smoothstep(.20, .87, progress)
	elif _animation_choices.get(id, "") != "Sitting_Idle_Loop":
		_clear_seat_pose(id)
		return
	var seat: Dictionary = _seat_motion[id]
	var body: Node3D = agent_nodes[id]
	var pose: Node3D = agent_pose_nodes[id]
	var female := int(_model_faces.get(id,0)) == 1
	var yaw := deg_to_rad(float(seat.heading))
	# Measured seated contact points in the two imported rigs at height 1.0.
	var hip_depth := .354 if female else .357
	var hips := Vector3(-.003 * pose.scale.x, (.494 if female else .501) * pose.scale.y, hip_depth * pose.scale.z)
	var cushion := Vector3(seat.position.x, float(seat.height) + .005, seat.position.y)
	var seated_origin := cushion - Basis(Vector3.UP,yaw) * hips
	pose.position = body.to_local(seated_origin) * amount
	pose.rotation.y = wrapf(yaw - body.rotation.y,-PI,PI) * amount
	var solver := _seat_leg_solver(id)
	if solver == null:return
	var leveling := solver.get_parent().get_node("SeatFootLevel")
	var resident: Dictionary = _state.agents[id]
	for index in range(2):
		var suffix := "l" if index == 0 else "r"
		var foot := solver.get_node("Foot_" + suffix) as Node3D
		var knee := solver.get_node("Knee_" + suffix) as Node3D
		var lateral := (-.174 if female else -.178) if index == 0 else (.218 if female else .216)
		var stance := Vector3(lateral, 0.0, -.044 if female else -.052) * pose.scale
		var planted := 1.0
		if entering:
			planted = smoothstep(.02 + .14 * index, .16 + .14 * index, progress)
		elif exiting:
			planted = 1.0 - smoothstep(.70 + .14 * index, .84 + .14 * index, progress)
		var standing := body.to_global(stance)
		var seated := seated_origin + Basis(Vector3.UP, yaw) * stance
		foot.global_position = standing.lerp(seated, planted)
		foot.global_position.y = SEATED_FLOOR_HEIGHT + leveling.floor_offset(index, resident.shoe_type) + .025 * sin(planted * PI)
		knee.global_position = pose.to_global(Vector3(lateral,.53,-.39))
	solver.active = true
	leveling.active = true
	SeatedHandContact.update(solver, clip, progress, resident.held_phone, resident.outfit)

func _bind_held_marker(id: String, pose: Node3D) -> void:
	var previous: Variant = _held_markers.get(id)
	if is_instance_valid(previous):
		var parent: Node = previous.get_parent()
		if parent is BoneAttachment3D:
			parent.free()
		else:
			previous.free()
	var marker := Marker3D.new()
	_held_markers[id] = marker
	var model: Node3D = _models.get(id)
	if is_instance_valid(model):
		for node in model.find_children("*", "Skeleton3D", true, false):
			var skeleton := node as Skeleton3D
			var hand := skeleton.find_bone("hand_r")
			if hand < 0:
				continue
			var attachment := BoneAttachment3D.new()
			attachment.name = "RightGrip"
			attachment.bone_name = skeleton.get_bone_name(hand)
			skeleton.add_child(attachment)
			marker.position = Vector3(0.0, 0.046, 0.025)
			attachment.add_child(marker)
			skeleton.skeleton_updated.connect(_update_seated_phone.bind(id))
			return
	marker.position = Vector3(0.30, 1.04, -0.20)
	pose.add_child(marker)

func _animate(id: String, data: Dictionary, speed: float) -> void:
	if not _players.has(id):
		return
	var player: AnimationPlayer = _players[id]
	var body: Dictionary = data.get("body", {})
	var action := str(data.get("busy", {}).get("type", ""))
	var previous := str(_animation_choices.get(id, ""))
	var moving := speed > (0.065 if previous in ["Walk_Loop", "Crawl_Loop"] else 0.14)
	var seat: Dictionary = data.get("seat", {})
	var clip_name := "Idle_Loop"
	var speed_scale := 1.0
	if not bool(data.get("alive", true)):
		clip_name = "Death01"
	elif not str(data.get("carried_by", "")).is_empty() or bool(data.get("sleeping", false)) or bool(data.get("unconscious", false)):
		clip_name = "Sleep_Loop"
	elif body.get("left_leg") == "broken" and body.get("right_leg") == "broken":
		clip_name = "Crawl_Loop" if moving else "Crouch_Idle_Loop"
		speed_scale = clampf(speed / 0.72, 0.5, 1.6) if moving else 1.0
	elif not seat.is_empty():
		clip_name = "Sitting_Idle_Loop"
	elif moving:
		clip_name = "Walk_Loop"
		var injured: bool = body.get("left_leg", "healthy") != "healthy" or body.get("right_leg", "healthy") != "healthy"
		speed_scale = clampf(speed / (1.10 if injured else 1.52), 0.45, 1.85)
	elif action == "attack":
		clip_name = "Punch_Jab"
	elif action == "defend":
		clip_name = "Crouch_Idle_Loop"
	elif action == "rest":
		clip_name = "Idle_Loop"
	elif action == "treat":
		clip_name = "Fixing_Kneeling"
	elif action == "consume":
		clip_name = "Interact"
	elif _action_feedback.has(id) and int(_action_feedback[id].until) > Time.get_ticks_msec():
		match str(_action_feedback[id].type):
			"speak": clip_name = "Idle_Talking_Loop"
			"take", "give", "drop", "request_ration", "buy": clip_name = "PickUp_Table"
			_: clip_name = "Interact"
	if not _clip_names.has(id):
		var clips := {}
		for name in player.get_animation_list():
			clips[str(name).get_slice("/", str(name).get_slice_count("/") - 1)] = name
		_clip_names[id] = clips
	var clips: Dictionary = _clip_names[id]
	# The GLTF importer uses _Loop as an import hint and can remove it from the name.
	var clip: StringName = clips.get(clip_name, clips.get(clip_name.trim_suffix("_Loop"), clips.get("Idle", &"")))
	if clip.is_empty():
		return
	player.speed_scale = speed_scale
	if clip_name == "Sitting_Idle_Loop":
		_seat_motion[id] = seat
	if previous == clip_name:
		return
	_animation_choices[id] = clip_name
	_animation_keys[id] = clip
	var seated_exit: StringName = clips.get("Sitting_Exit", &"")
	var can_stand := clip_name not in ["Sleep_Loop", "Death01", "Crawl_Loop", "Crouch_Idle_Loop"]
	player.clear_queue()
	if not seated_exit.is_empty() and player.current_animation == seated_exit and can_stand and seat.is_empty():
		# A speech or movement cue can change the destination while the
		# resident is still rising. Keep the seat contacts through the exit.
		player.queue(clip)
		return
	var initial := previous.is_empty()
	if clip_name == "Sitting_Idle_Loop" and not initial and clips.has("Sitting_Enter"):
		player.play(clips["Sitting_Enter"], .12)
		player.queue(clip)
	elif previous == "Sitting_Idle_Loop" and can_stand and not seated_exit.is_empty():
		player.play(seated_exit, .10)
		player.queue(clip)
	else:
		player.play(clip, 0.0 if initial else 0.17)
	if initial:
		player.advance(0.15 if clip_name == "Idle_Loop" else 0.0)

func _sync_camera(id: String, authoritative: bool) -> void:
	if not agent_cameras.has(id) or not _state.get("agents",{}).has(id): return
	var data: Dictionary=_state.agents[id]
	var camera: Camera3D=agent_cameras[id]
	var seat: Dictionary = data.get("seat", {})
	if not seat.is_empty():
		camera.position = _displayed_eye_position(id)
		camera.rotation = Vector3(deg_to_rad(-24),deg_to_rad(float(seat.heading)),0)
		return
	var point: Vector3=_targets.get(id,{}).get("position",Vector3.ZERO) if authoritative else agent_nodes[id].position
	var heading: float=float(_targets.get(id,{}).get("heading",0.0)) if authoritative else agent_nodes[id].rotation.y
	var body: Dictionary=data.get("body",{})
	var height: float=1.57*float(data.get("appearance",{}).get("height",1.0))
	if body.get("left_leg")=="broken" and body.get("right_leg")=="broken": height=0.48
	if bool(data.get("sleeping",false)) or not bool(data.get("alive",true)) or bool(data.get("unconscious",false)): height=0.35
	camera.position=point+Vector3(0,height,0)
	# Keep floor objects within sight at the 1.05 m navigation approach point,
	# including tall avatars; otherwise food disappears below the image exactly
	# when the character is close enough to pick it up.
	camera.rotation=Vector3(deg_to_rad(-24),heading,0)

func _set_body_layer(id: String, layer: int) -> void:
	var visual_layer:=_resident_layers(id,layer)
	for mesh in _meshes.get(id,[]): mesh.layers=visual_layer
	# Held meshes follow the holder's visibility in EVERY eye camera, including
	# one-shot captures of an actor who is not selected by the observer.
	for item_id in _state.get("items",{}):
		if str(_state.items[item_id])==id and item_nodes.has(item_id):
			_set_item_layers(item_nodes[item_id],visual_layer)

func _resident_layers(id: String, layer: int) -> int:
	return layer if _use_proxies and id!=selected_agent and not _near_observer.has(id) else layer|DISPLAY_BODY

func _build_item(id: String, data: Dictionary) -> void:
	var root:=Node3D.new(); root.name="Item_"+id
	_content.add_child(root); item_nodes[id]=root
	var kind: String=str(data.get("kind","ration"))
	var asset: Node3D=_instantiate_asset(kind)
	if asset!=null:
		root.add_child(asset); _fit_asset(asset,Vector3(0.32,0.28,0.25)); return
	match kind:
		"phone":
			_box(root, Vector3(0.076, 0.012, 0.155), Vector3(0, 0.011, 0), Color("354954"))
			_box(root, Vector3(0.069, 0.002, 0.139), Vector3(0, 0.018, 0), Color("547d7b"))
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
	var container_visible := container.is_empty() or _open_containers.has(container)
	node.visible=int(item.get("quantity",1))>0 and container_visible
	if not holder.is_empty() and _held_markers.has(holder):
		var inventory: Array=_state.agents.get(holder,{}).get("inventory",[])
		node.visible=not inventory.is_empty() and str(inventory[0])==id
		_set_held_pose(node, holder)
		var resident_layer:=SELECTED_BODY if holder==selected_agent else (CAPTURE_BODY if holder==_capture_actor else BODIES)
		_set_item_layers(node,_resident_layers(holder,resident_layer))
	else:
		var p: Array=item.get("position",[0,0])
		node.position=Vector3(float(p[0]),float(item.get("surface_height",0)),float(p[1]))
		node.rotation=Vector3.ZERO
		_set_item_layers(node,WORLD)

func _set_held_pose(item: Node3D, holder: String) -> void:
	var marker: Marker3D = _held_markers[holder]
	if _seat_motion.has(holder) and _state.agents.get(holder, {}).get("held_phone", false):
		var grip := SeatedHandContact.phone_transform(marker)
		item.global_transform = Transform3D(grip.basis.orthonormalized(), grip.origin)
	else:
		item.global_position = marker.global_position
		item.global_rotation = agent_nodes[holder].global_rotation

func _update_seated_phone(holder: String) -> void:
	if not _seat_motion.has(holder):
		return
	var resident: Dictionary = _state.agents.get(holder, {})
	if not resident.get("held_phone", false):
		return
	var item: Node3D = item_nodes.get(resident.inventory[0])
	if is_instance_valid(item):
		_set_held_pose(item, holder)

func _set_item_layers(node: Node, layer: int) -> void:
	if node is VisualInstance3D: node.layers=layer
	for child in node.get_children(): _set_item_layers(child,layer)

func _update_selection() -> void:
	if is_instance_valid(_selection) and agent_nodes.has(selected_agent):
		_selection.position = agent_nodes[selected_agent].position + Vector3.UP * 0.062
		_selection.visible = not first_person and _zoom < 44.0

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
	var cache_key:=kind+"/"+tint.to_html()+"/"+str(repeats)
	if _material_cache.has(cache_key):return _material_cache[cache_key]
	var material:=StandardMaterial3D.new();material.albedo_color=tint.darkened(.16) if kind=="tile" else tint;material.roughness=.84
	material.metallic_specular=0.20 if kind=="tile" else 0.33
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
				elif field=="normal": material.normal_enabled=true; material.normal_texture=_texture_cache[path]; material.normal_scale=0.26
				elif field=="roughness": material.roughness_texture=_texture_cache[path]
	material.uv1_triplanar=true
	material.uv1_world_triplanar=true
	material.uv1_scale=Vector3.ONE*(0.32*repeats)
	material.texture_filter=BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return material

func _material(color: Color) -> StandardMaterial3D:
	var key:=color.to_html()
	if _material_cache.has(key):return _material_cache[key]
	var material:=StandardMaterial3D.new(); material.albedo_color=color; material.roughness=0.85
	_material_cache[key]=material
	return material

func _outfit_material(color: Color, outfit: int) -> ShaderMaterial:
	return Art.clothing_material(color,outfit)

func _box(parent: Node3D, size: Vector3, point: Vector3, color: Color, layer: int=WORLD) -> MeshInstance3D:
	if not _box_meshes.has(size):
		var box:=BoxMesh.new();box.size=size
		_box_meshes[size]=box
	return _mesh(parent,_box_meshes[size],point,color,layer)

func _mesh(parent: Node3D, mesh: Mesh, point: Vector3, color: Color, layer: int=WORLD) -> MeshInstance3D:
	var node:=MeshInstance3D.new(); node.mesh=mesh; node.position=point; node.layers=layer; node.material_override=_material(color)
	parent.add_child(node); return node

func _label(parent: Node3D, text: String, point: Vector3, color: Color, pixel: float=0.005, floor_label: bool=false) -> void:
	var label:=Label3D.new(); label.text=text; label.position=point; label.font_size=36; label.pixel_size=pixel; label.modulate=color; label.outline_modulate=Color("23313c"); label.layers=OVERLAY
	if floor_label: label.rotation_degrees.x=-90
	else:
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 32
		label.outline_size = 3
	parent.add_child(label)
	_labels.append({"node":label,"kind":"room" if floor_label else "actor","actor":str(parent.name).trim_prefix("Agent_")})

func _update_labels() -> void:
	if not is_instance_valid(observer_camera):
		return
	var occupied: Array[Rect2] = []
	var selected: Label3D = null
	for entry in _labels:
		var label: Label3D = entry.node
		label.visible = false
		if entry.kind == "actor" and entry.actor == selected_agent:
			selected = label
	for bubble in _speech_bubbles.values():
		bubble.visible = false
	if first_person:
		return
	var viewport_pixels := Vector2(observer_viewport.size)
	var scale := 1080.0 / viewport_pixels.y
	var screen := Rect2(Vector2.ZERO, viewport_pixels * scale)
	if is_instance_valid(selected) and _zoom < 44.0:
		_place_label(selected, scale, screen, Vector2(90, 22), occupied, 20.0)
	var chosen_bubble: Label3D = null
	var nearest := INF
	if _zoom < 25.0:
		var now := Time.get_ticks_msec()
		for id in _speech_bubbles:
			var feedback: Dictionary = _action_feedback.get(id, {})
			if str(feedback.get("type", "")) != "speak" or int(feedback.get("until", 0)) <= now:
				continue
			var bubble: Label3D = _speech_bubbles[id]
			var distance := 0.0 if id == selected_agent else bubble.global_position.distance_squared_to(_focus)
			if distance < nearest and screen.has_point(observer_camera.unproject_position(bubble.global_position) * scale):
				nearest = distance
				chosen_bubble = bubble
	if is_instance_valid(chosen_bubble):
		_place_label(chosen_bubble, scale, screen, Vector2(288, 40), occupied, 18.0)
	for entry in _labels:
		var label: Label3D = entry.node
		if entry.kind == "room" and _zoom >= 28.0:
			_place_label(label, scale, screen, Vector2(122, 21), occupied)
		elif entry.kind == "actor" and label != selected and _zoom < 25.0:
			_place_label(label, scale, screen, Vector2(75, 19), occupied, 17.0)

func _place_label(label: Label3D, scale: float, screen: Rect2, size: Vector2, occupied: Array[Rect2], height: float = 0.0) -> void:
	if observer_camera.is_position_behind(label.global_position):
		return
	var point := observer_camera.unproject_position(label.global_position) * scale
	var bounds := Rect2(point - size * 0.5, size)
	if not screen.encloses(bounds):
		return
	for used in occupied:
		if used.intersects(bounds):
			return
	if height > 0.0:
		var view_height := _zoom
		if _perspective:
			var depth := -observer_camera.to_local(label.global_position).z
			view_height = 2.0 * depth * tan(deg_to_rad(observer_camera.fov * 0.5))
		label.pixel_size = view_height * height / (1080.0 * label.font_size)
	occupied.append(bounds)
	label.visible = true

func _sync_face_context(state: Dictionary, immediate: bool) -> void:
	var minute := float(state.get("minute", 0.0))
	if immediate or not is_equal_approx(_face_minute, minute):
		_face_minute = minute
		_face_clock = minute * FaceShape.SECONDS_PER_MINUTE
		_face_clock_limit = _face_clock + (0.0 if immediate else 0.099)
	var speech: Dictionary = {}
	var looking_at: Dictionary = {}
	var hearing: Dictionary = {}
	var events: Array = state.get("events", [])
	for index in range(events.size() - 1, -1, -1):
		var event: Dictionary = events[index]
		if minute - float(event.get("minute", 0.0)) > FaceShape.SPEECH_WINDOW:
			break
		if event.get("type") != "speak" or not event.get("ok", false):
			continue
		var speaker := str(event.get("actor", ""))
		if not _targets.has(speaker) or speech.has(speaker):
			continue
		speech[speaker] = event
		var listeners: Variant = event.get("details", {}).get("listeners", [])
		if not listeners is Array:
			continue
		var closest := INF
		var source_position: Vector3 = _targets[speaker].position
		for id in listeners:
			if not _targets.has(id):
				continue
			if not hearing.has(id):
				hearing[id] = speaker
			var destination: Vector3 = _targets[id].position
			var distance := source_position.distance_squared_to(destination)
			if distance < closest and absf(_relative_facing(speaker, id)) < 1.15:
				looking_at[speaker] = id
				closest = distance
	for id in _faces:
		if not state.agents.has(id):
			continue
		var resident: Dictionary = state.agents[id]
		var event: Dictionary = speech.get(id, {})
		var listener := str(looking_at.get(id, hearing.get(id, "")))
		var gaze := Vector2.ZERO
		if _targets.has(listener):
			var yaw := _relative_facing(id, listener)
			if absf(yaw) < 1.15:
				var offset := _displayed_eye_position(listener) - _displayed_eye_position(id)
				gaze = Vector2(yaw, -atan2(offset.y, Vector2(offset.x, offset.z).length()))
		var stress := maxf(0.0, float(resident.get("pain", 0.0)) - 10.0) * 0.007
		var line := _speech_line(event, resident) if not event.is_empty() else ""
		_faces[id].set_context(int(event.get("seq", -1)), line, float(event.get("minute", 0.0)), hearing.has(id), gaze, stress)
		_present_face(id, immediate)

func _relative_facing(id: String, target: String) -> float:
	var offset: Vector3 = _targets[target].position - _targets[id].position
	return angle_difference(float(_targets[id].heading), atan2(-offset.x, -offset.z))

func _displayed_eye_position(id: String) -> Vector3:
	var data: Dictionary = _state.agents[id]
	var height := float(data.appearance.height)
	var seat: Dictionary = data.seat
	if not seat.is_empty():
		return Vector3(seat.position.x, float(seat.height) + SEATED_EYE_RISE * height, seat.position.y)
	return _targets[id].position + Vector3.UP * 1.57 * height

func _present_face(id: String, immediate: bool = false) -> void:
	if not _faces.has(id):
		return
	var data: Dictionary = _state.agents[id]
	_faces[id].present(_face_clock, data.alive and not data.sleeping and not data.unconscious, immediate)

func _speech_line(event: Dictionary, resident: Dictionary) -> String:
	var recorded: Variant = event.get("details", {}).get("text")
	if recorded is String:
		return recorded
	var last: Dictionary = resident.get("last_action", {})
	return str(last.get("text", "")) if last.get("type") == "speak" else ""

func _sync_action_feedback(state:Dictionary) -> void:
	var fresh:Array=[]
	var events:Array=state.get("events",[])
	for i in range(events.size()-1,-1,-1):
		var event:Dictionary=events[i]
		if int(event.get("seq",-1))<=_visual_event_cursor:break
		fresh.push_front(event)
	for event in fresh:
		_visual_event_cursor=maxi(_visual_event_cursor,int(event.get("seq",-1)))
		if float(state.get("minute",0.0))-float(event.get("minute",0.0))>0.45:continue
		var id:=str(event.get("actor",""))
		if not bool(event.get("ok",false)) or not agent_nodes.has(id):continue
		var kind:=str(event.get("type",""))
		if kind not in ["speak","take","give","drop","request_ration","buy","use_device","read_screen","treat","open","close"]:continue
		_action_feedback[id]={"type":kind,"until":Time.get_ticks_msec()+(4000 if kind=="speak" else 1800)}
		if kind=="speak":
			if not _speech_bubbles.has(id):
				var bubble:=Label3D.new();bubble.layers=OVERLAY;bubble.position=Vector3(0,2.48,0);bubble.font_size=24
				bubble.billboard=BaseMaterial3D.BILLBOARD_ENABLED;bubble.modulate=Color("fff4d6");bubble.outline_size=4;bubble.outline_modulate=Color("182d36")
				bubble.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;bubble.width=340
				agent_nodes[id].add_child(bubble);_speech_bubbles[id]=bubble
			var text := _speech_line(event, state.agents[id])
			_speech_bubbles[id].text=text.left(58)+("…" if text.length()>58 else "")
