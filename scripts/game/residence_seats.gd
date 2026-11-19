extends RefCounted

const LOUNGE_CHAIRS := ["common_reading_seat_0", "common_reading_seat_1"]

static func anchor(prop: Dictionary, geometry: Dictionary) -> Dictionary:
	if geometry.get("palette") != "warm" or prop.get("kind") != "chair" or prop.get("id") not in LOUNGE_CHAIRS:
		return {}
	var center: Array = prop.center
	var dimensions: Array = prop.size
	var depth := float(dimensions[1])
	var height := float(prop.height)
	var heading := float(prop.get("angle",0.0))
	var origin := Vector2(float(center[0]),float(center[1]))
	# The fitted chair opens along +Z, with its cushion lower than the backrest.
	var front := Vector2.DOWN.rotated(-deg_to_rad(heading))
	return {
		"position": origin + front * (.12 * depth / .65),
		"approach": origin + front * (depth * .5 + .375),
		"height": .40 * height / .95,
		"heading": fposmod(heading + 180.0,360.0),
	}

static func occupied(actor: Dictionary, geometry: Dictionary) -> Dictionary:
	var busy: Dictionary = actor.get("busy",{})
	var positioned: Variant = busy.get("seat_positioned",false)
	if busy.get("type") != "rest" or not (positioned is bool and positioned):
		return {}
	if not actor.get("alive",true) or actor.get("sleeping",false) or actor.get("unconscious",false) or not str(actor.get("carried_by","")).is_empty():
		return {}
	var seat_id := str(busy.get("seat",""))
	if seat_id not in LOUNGE_CHAIRS or geometry.get("palette") != "warm":
		return {}
	for prop: Dictionary in geometry.get("props",[]):
		if prop.get("id") == seat_id:
			return anchor(prop,geometry)
	return {}
