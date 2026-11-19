extends Control
## A north-up observer floor plan, with separately cached geometry and live markers.

signal person_selected(id: String)
signal location_selected(position: Vector2)

const PAPER := Color("eee6d4")
const AMBER := Color("e4b775")
const SAGE := Color("97beaa")
const MAP_INK := Color("0d1513")
const HIT_RADIUS := 13.0
const MAP_PALETTES := {
	"teal": [Color("15231f"), Color("293b33"), Color("526559"), Color("678072")],
	"warm": [Color("28261e"), Color("3e3b2d"), Color("70674d"), Color("8d805d")],
	"blue": [Color("172129"), Color("293943"), Color("526571"), Color("6a8292")],
}

var expanded := false
var _bounds := Rect2()
var _plan := Rect2()
var _rooms: Array = []
var _districts: Array = []
var _walls: Array = []
var _landmarks: Array = []
var _colors: Array = MAP_PALETTES.teal
var _titles: Dictionary = {}
var _people: Dictionary = {}
var _positions: Dictionary = {}
var _camera: Dictionary = {}
var _selected := ""
var _marker_layer: Control
var _choices: PopupMenu
var _choice_ids: Array[String] = []


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	_marker_layer = Control.new()
	_marker_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_marker_layer)
	_marker_layer.draw.connect(_draw_markers)
	_choices = PopupMenu.new()
	add_child(_choices)
	_choices.id_pressed.connect(_choose_person)
	resized.connect(_layout_plan)
	_layout_plan()


func set_geometry(geometry: Dictionary, titles: Dictionary) -> void:
	var bounds: Array = geometry.get("bounds", [])
	_bounds = Rect2()
	if bounds.size() == 4:
		_bounds = Rect2(
			float(bounds[0]), float(bounds[2]),
			float(bounds[1]) - float(bounds[0]), float(bounds[3]) - float(bounds[2])
		)
	_rooms = geometry.get("rooms", [])
	_districts = geometry.get("districts", [])
	_walls = geometry.get("walls", [])
	_landmarks = geometry.get("landmarks", [])
	_colors = MAP_PALETTES.get(str(geometry.get("palette", "")), MAP_PALETTES.teal)
	_titles = titles
	_layout_plan()


func set_people(people: Dictionary, selected: String) -> void:
	_people = people
	_selected = selected
	if is_instance_valid(_marker_layer):
		_marker_layer.queue_redraw()


func update_positions(positions: Dictionary, camera: Dictionary) -> void:
	if _positions == positions and _camera == camera:
		return
	_positions = positions
	_camera = camera
	if is_instance_valid(_marker_layer):
		_marker_layer.queue_redraw()


func world_to_map(point: Vector2) -> Vector2:
	if not _bounds.has_area() or not _plan.has_area():
		return Vector2.ZERO
	return _plan.position + (point - _bounds.position) / _bounds.size * _plan.size


func map_to_world(point: Vector2) -> Vector2:
	if not _bounds.has_area() or not _plan.has_area():
		return Vector2.ZERO
	return _bounds.position + (point - _plan.position) / _plan.size * _bounds.size


func _layout_plan() -> void:
	_plan = Rect2()
	if _bounds.has_area():
		var available := (size - Vector2(32, 28)).max(Vector2.ZERO)
		var ratio := minf(available.x / _bounds.size.x, available.y / _bounds.size.y)
		var fitted := _bounds.size * ratio
		_plan = Rect2((size - fitted) * 0.5, fitted)
	queue_redraw()
	if is_instance_valid(_marker_layer):
		_marker_layer.queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), MAP_INK)
	if not _plan.has_area():
		return
	draw_rect(_plan, _colors[0])
	draw_rect(_plan, _colors[2], false, 1.0)
	for district: Dictionary in _districts:
		var district_rect := _world_rect(district).intersection(_plan)
		if district_rect.has_area():
			draw_rect(district_rect, Color(_colors[1], 0.35))
	var font := get_theme_default_font()
	for room: Dictionary in _rooms:
		var outline := _world_rect(room)
		draw_rect(outline, _colors[1])
		draw_rect(outline, _colors[2], false, 1.0)
		if expanded:
			var title := str(_titles.get(room.get("id", ""), room.get("label", "")))
			var is_landmark := _landmarks.any(func(landmark): return landmark.get("center", []) == room.get("center", []))
			_draw_room_name(font, outline, title, is_landmark)
	for wall: Dictionary in _walls:
		var edge := _world_rect(wall)
		var thickness := edge.size.max(Vector2(1.0, 1.0))
		draw_rect(Rect2(edge.get_center() - thickness * 0.5, thickness), _colors[3])
	for landmark: Dictionary in _landmarks:
		var p := world_to_map(_point(landmark.get("center", [])))
		_draw_landmark(p, str(landmark.get("kind", "")))
	draw_string(font, Vector2(size.x - 22.0, 21.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AMBER)


func _draw_room_name(font: Font, outline: Rect2, title: String, is_landmark: bool) -> void:
	var limit := outline.size.x - 7.0
	if limit <= 0.0 or outline.size.y < 18.0:
		return
	var center := outline.get_center() + Vector2(0.0, -12.0 if is_landmark and outline.size.y > 34.0 else 4.0)
	for font_size in [13, 12, 11]:
		if _line_width(font, title, font_size) <= limit:
			_center_line(font, center, title, font_size)
			return
	if outline.size.y < 34.0:
		return
	var words := title.split(" ", false)
	for split_at in range(1, words.size()):
		var first := " ".join(words.slice(0, split_at))
		var second := " ".join(words.slice(split_at))
		if maxf(_line_width(font, first, 11), _line_width(font, second, 11)) <= limit:
			_center_line(font, center - Vector2(0.0, 7.0), first, 11)
			_center_line(font, center + Vector2(0.0, 6.0), second, 11)
			return


func _line_width(font: Font, caption: String, font_size: int) -> float:
	return font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


func _center_line(font: Font, point: Vector2, caption: String, font_size: int) -> void:
	draw_string(font, point - Vector2(_line_width(font, caption, font_size) * 0.5, 0.0), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, PAPER)


func _draw_landmark(point: Vector2, kind: String) -> void:
	var radius := 5.5 if expanded else 3.7
	var tint := AMBER.darkened(0.21)
	var dx := Vector2(radius, 0)
	var dy := Vector2(0, radius)
	match kind:
		"medical":
			draw_line(point - dx, point + dx, tint, 1.5, true)
			draw_line(point - dy, point + dy, tint, 1.5, true)
		"comms":
			for ring in [radius * 0.54, radius]:
				draw_arc(point, ring, -2.48, -0.66, 6, tint, 1.1, true)
			draw_circle(point, 1.0, tint, true, -1.0, true)
		"arrival":
			draw_polyline(PackedVector2Array([point - dx + dy, point - dy, point + dx + dy]), tint, 1.2, true)
		"supply":
			draw_rect(Rect2(point - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), tint, false, 1.1)
		_:
			draw_circle(point, radius, tint, false, 1.2, true)


func _draw_markers() -> void:
	if not _plan.has_area() or not is_instance_valid(_marker_layer):
		return
	var layer := _marker_layer
	var footprint: PackedVector2Array = _camera.get("footprint", PackedVector2Array())
	if footprint.size() > 2:
		var points := PackedVector2Array()
		for point in footprint:
			var pixel := world_to_map(point)
			points.append(pixel.clamp(_plan.position, _plan.end))
		points.append(points[0])
		layer.draw_polyline(points, Color(SAGE, 0.48), 1.2, true)
	var camera_position: Variant = _camera.get("position")
	if camera_position is Vector2 and _bounds.has_point(camera_position):
		var origin := world_to_map(camera_position)
		var heading := float(_camera.get("heading", 0.0))
		var tip := origin + Vector2(-sin(heading), -cos(heading)) * 12.0
		layer.draw_line(origin, tip, SAGE, 1.6, true)
	for id in _people:
		if id != _selected:
			_draw_person(str(id), false)
	if _people.has(_selected):
		_draw_person(_selected, true)


func _draw_person(id: String, selected: bool) -> void:
	var person: Dictionary = _people[id]
	var pixel := world_to_map(_person_position(id))
	if not _plan.grow(1.0).has_point(pixel):
		return
	var alive := bool(person.get("alive", true))
	var tint := AMBER if selected else SAGE if alive else Color("a2a59e")
	var radius := 6.0 if selected else 3.7
	_marker_layer.draw_circle(pixel, radius + 2.0, MAP_INK, true, -1.0, true)
	if alive:
		_marker_layer.draw_circle(pixel, radius, tint, true, -1.0, true)
	else:
		_marker_layer.draw_line(pixel - Vector2.ONE * radius, pixel + Vector2.ONE * radius, tint, 1.7, true)
		_marker_layer.draw_line(pixel + Vector2(-radius, radius), pixel + Vector2(radius, -radius), tint, 1.7, true)
	if not selected:
		return
	_marker_layer.draw_arc(pixel, 9.5, 0.0, TAU, 24, tint, 1.4, true)
	var font := get_theme_default_font()
	var name_text := str(person.get("name", id))
	var width := minf(font.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x, size.x - 24.0)
	var left := clampf(pixel.x + 12, 4.0, maxf(4.0, size.x - width - 12.0))
	var top := clampf(pixel.y - 11, 2.0, maxf(2.0, size.y - 24.0))
	_marker_layer.draw_rect(Rect2(left, top, width + 9.0, 21.0), Color(MAP_INK, 0.92))
	_marker_layer.draw_string(font, Vector2(left + 4.0, top + 15.0), name_text, HORIZONTAL_ALIGNMENT_LEFT, width, 13, PAPER)


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var candidates := _hit_people(event.position)
	if candidates.size() == 1:
		person_selected.emit(candidates[0])
	elif candidates.size() > 1:
		_choice_ids = candidates
		_choices.clear()
		for index in candidates.size():
			_choices.add_item(str(_people[candidates[index]].get("name", candidates[index])), index)
		_choices.position = Vector2i(get_screen_transform() * event.position)
		_choices.reset_size()
		_choices.popup()
	elif _plan.has_point(event.position):
		location_selected.emit(map_to_world(event.position))
	accept_event()


func _get_tooltip(at_position: Vector2) -> String:
	var names := PackedStringArray()
	for id in _hit_people(at_position):
		names.append(str(_people[id].get("name", id)))
	if not names.is_empty():
		return "\n".join(names)
	if _plan.has_point(at_position):
		for room: Dictionary in _rooms:
			if _world_rect(room).has_point(at_position):
				return str(_titles.get(room.get("id", ""), room.get("label", "")))
	return ""


func _choose_person(index: int) -> void:
	if index >= 0 and index < _choice_ids.size() and _people.has(_choice_ids[index]):
		person_selected.emit(_choice_ids[index])


func _hit_people(pixel: Vector2) -> Array[String]:
	var candidates: Array[String] = []
	if not _plan.grow(HIT_RADIUS).has_point(pixel):
		return candidates
	for id in _people:
		if world_to_map(_person_position(str(id))).distance_to(pixel) <= HIT_RADIUS:
			candidates.append(str(id))
	candidates.sort()
	if _selected in candidates:
		candidates.erase(_selected)
		candidates.push_front(_selected)
	return candidates


func _person_position(id: String) -> Vector2:
	var point: Variant = _positions.get(id)
	return point if point is Vector2 else _point(_people[id].get("position", []))


func _world_rect(entry: Dictionary) -> Rect2:
	var center := _point(entry.get("center", []))
	var extent := _point(entry.get("size", [])) * 0.5
	var start := world_to_map(center - extent)
	return Rect2(start, world_to_map(center + extent) - start)


func _point(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1])) if value.size() == 2 else Vector2.ZERO
