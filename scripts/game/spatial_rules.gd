extends RefCounted
const RADIUS := 0.30
const CELL := 0.75
static var _occupancy:Dictionary={}

static func point(entity: Dictionary) -> Vector2:
	var p: Array = entity.get("position",entity.get("center",[0.0,0.0]))
	return Vector2(float(p[0]),float(p[1]))

static func bearing(agent: Dictionary,target: Vector2)->float:
	var delta := target-point(agent)
	return wrapf(rad_to_deg(atan2(-delta.x,-delta.y))-float(agent.heading),-180.0,180.0)

static func intersects(a: Vector2,b: Vector2,box: Dictionary,margin: float=0.0)->bool:
	var size: Array=box.get("size",[0.2,0.2])
	var raw_center:Array=box.get("center",box.get("position",[0.0,0.0]))
	var cx:=float(raw_center[0]);var cz:=float(raw_center[1])
	var hx:=float(size[0])*0.5+margin;var hz:=float(size[1])*0.5+margin
	if maxf(a.x,b.x)<cx-hx or minf(a.x,b.x)>cx+hx or maxf(a.y,b.y)<cz-hz or minf(a.y,b.y)>cz+hz:return false
	var center := Vector2(cx,cz)
	var half := Vector2(float(size[0]),float(size[1]))*0.5+Vector2.ONE*margin
	var low := center-half
	var high := center+half
	var delta := b-a
	var minimum := 0.0
	var maximum := 1.0
	for axis in 2:
		if absf(delta[axis])<0.000001:
			if a[axis]<low[axis] or a[axis]>high[axis]: return false
		else:
			var first := (low[axis]-a[axis])/delta[axis]
			var second := (high[axis]-a[axis])/delta[axis]
			minimum=maxf(minimum,minf(first,second))
			maximum=minf(maximum,maxf(first,second))
			if minimum>maximum:return false
	return true

static func clear_line(a: Vector2,b: Vector2,geometry: Dictionary,margin: float=0.0,ignore: String="",vision: bool=false)->bool:
	for wall in geometry.walls:
		if wall.get("id","")!=ignore and intersects(a,b,wall,margin):return false
	for door in geometry.doors:
		if door.get("id","")!=ignore and not door.get("open",false) and intersects(a,b,door,margin):return false
	for prop in geometry.get("props",[]):
		if prop.get("id","")==ignore or not prop.get("blocking",true):continue
		if vision and float(prop.get("height",0.0))<1.3:continue
		if intersects(a,b,prop,margin):return false
	return true

static func walkable(location: Vector2,geometry: Dictionary,agents: Dictionary={},ignore_actor: String="")->bool:
	var bounds: Array=geometry.bounds
	if location.x<float(bounds[0])+RADIUS or location.x>float(bounds[1])-RADIUS or location.y<float(bounds[2])+RADIUS or location.y>float(bounds[3])-RADIUS:return false
	if not clear_line(location,location,geometry,RADIUS):return false
	for id in agents:
		if id==ignore_actor or not agents[id].get("alive",true) or not str(agents[id].get("carried_by","")).is_empty():continue
		if point(agents[id]).distance_to(location)<RADIUS*2.0-0.001:return false
	return true

static func clear_bodies(a:Vector2,b:Vector2,agents:Dictionary,ignore_actor:String="")->bool:
	# Check the whole swept segment, including large logical steps. Endpoint-only
	# tests let a walker tunnel through somebody between two sampled positions.
	for id in agents:
		var other:Dictionary=agents[id]
		if id==ignore_actor or not other.get("alive",true) or not str(other.get("carried_by","")).is_empty():continue
		var position:=point(other)
		if position.x<minf(a.x,b.x)-RADIUS*2.0 or position.x>maxf(a.x,b.x)+RADIUS*2.0 or position.y<minf(a.y,b.y)-RADIUS*2.0 or position.y>maxf(a.y,b.y)+RADIUS*2.0:continue
		if Geometry2D.get_closest_point_to_segment(position,a,b).distance_to(position)<RADIUS*2.0-0.001:return false
	return true

static func visible(agent: Dictionary,location: Vector2,geometry: Dictionary,ignore: String="",max_distance: float=16.0)->bool:
	if agent.body.get("blind",false) or not agent.get("alive",true) or agent.get("sleeping",false) or agent.get("unconscious",false):return false
	return point(agent).distance_to(location)<=max_distance and absf(bearing(agent,location))<=53.0 and clear_line(point(agent),location,geometry,0.0,ignore,true)

static func cell_key(location: Vector2)->String:
	return "%d:%d" % [roundi(location.x/CELL),roundi(location.y/CELL)]

static func learn(agent: Dictionary,geometry: Dictionary)->void:
	if agent.body.blind or agent.sleeping or agent.unconscious:return
	var origin := point(agent)
	var stamp:="%s:%d:%d"%[cell_key(origin),roundi(float(agent.heading)/12.0),_geometry_key(geometry)]
	if str(agent.get("_learn_stamp",""))==stamp:return
	agent["_learn_stamp"]=stamp
	var known: Dictionary=agent.known_cells
	for x in range(floori((origin.x-10.0)/CELL),ceili((origin.x+10.0)/CELL)+1):
		for z in range(floori((origin.y-10.0)/CELL),ceili((origin.y+10.0)/CELL)+1):
			var location:=Vector2(x*CELL,z*CELL)
			var key:="%d:%d"%[x,z]
			if known.has(key):continue
			if visible(agent,location,geometry) and walkable(location,geometry):known[key]=true
	known[cell_key(origin)]=true

static func path(agent: Dictionary,destination: Vector2,geometry: Dictionary,agents: Dictionary,ignore_target: String="")->Array:
	var origin:=point(agent)
	var targets:Array=[destination]
	# Stop beside a target rather than trying to stand inside a door/person/table.
	if not walkable(destination,geometry,agents,str(agent.id)) or not ignore_target.is_empty():
		targets=[]
		for angle in range(0,360,30):
			var trial:=destination+Vector2.from_angle(deg_to_rad(float(angle)))*1.05
			if walkable(trial,geometry,agents,str(agent.id)) and clear_line(trial,destination,geometry,0.0,ignore_target,true):
				targets.append(trial)
		if targets.is_empty():return []
		targets.sort_custom(func(a,b):return origin.distance_squared_to(a)<origin.distance_squared_to(b))
	for target:Vector2 in targets:
		if clear_line(origin,target,geometry,RADIUS) and clear_bodies(origin,target,agents,str(agent.id)) and walkable(target,geometry,agents,str(agent.id)):
			return [[target.x,target.y]]
	var bounds:Array=geometry.bounds
	var low:=Vector2i(floori(float(bounds[0])/CELL),floori(float(bounds[2])/CELL))
	var high:=Vector2i(ceili(float(bounds[1])/CELL),ceili(float(bounds[3])/CELL))
	var grid:=AStarGrid2D.new()
	grid.region=Rect2i(low,high-low+Vector2i.ONE)
	grid.cell_size=Vector2.ONE*CELL
	grid.diagonal_mode=AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.update()
	# Static occupancy does not change every time a door opens. Door cells
	# are applied separately, keeping gameplay path requests inexpensive.
	var cache_key:=hash([geometry.bounds,geometry.walls,geometry.get("props",[])])
	if not _occupancy.has(cache_key):
		var solid:Dictionary={}
		var base_geometry:Dictionary=geometry.duplicate(false);base_geometry["doors"]=[]
		for cell_x in range(low.x,high.x+1):
			for cell_z in range(low.y,high.y+1):
				if not walkable(Vector2(cell_x*CELL,cell_z*CELL),base_geometry):solid["%d:%d"%[cell_x,cell_z]]=true
		if _occupancy.size()>=32:_occupancy.erase(_occupancy.keys()[0])
		_occupancy[cache_key]=solid
	var solids:Dictionary=_occupancy[cache_key]
	var doors_solid:Dictionary={}
	for door in geometry.doors:
		if door.open:continue
		var door_center:=point(door)
		var half:=Vector2(float(door.size[0]),float(door.size[1]))*0.5+Vector2.ONE*RADIUS
		for dx in range(floori((door_center.x-half.x)/CELL),ceili((door_center.x+half.x)/CELL)+1):
			for dz in range(floori((door_center.y-half.y)/CELL),ceili((door_center.y+half.y)/CELL)+1):
				var location:=Vector2(dx*CELL,dz*CELL)
				if intersects(location,location,door,RADIUS):doors_solid["%d:%d"%[dx,dz]]=true
	# Only local cells around occupants need changing; static geometry remains
	# cached. A route must actually go around people, not cancel on each contact.
	var bodies_solid:Dictionary={}
	var grid_body_radius:=RADIUS*2.0+CELL*0.4
	for id in agents:
		var other:Dictionary=agents[id]
		if id==agent.id or not other.get("alive",true) or not str(other.get("carried_by","")).is_empty():continue
		var center:=point(other)
		for dx in range(floori((center.x-grid_body_radius)/CELL),ceili((center.x+grid_body_radius)/CELL)+1):
			for dz in range(floori((center.y-grid_body_radius)/CELL),ceili((center.y+grid_body_radius)/CELL)+1):
				if center.distance_to(Vector2(dx*CELL,dz*CELL))<grid_body_radius:bodies_solid["%d:%d"%[dx,dz]]=true
	for x in range(low.x,high.x+1):
		for z in range(low.y,high.y+1):
			var key:="%d:%d"%[x,z]
			grid.set_point_solid(Vector2i(x,z),solids.has(key) or doors_solid.has(key) or bodies_solid.has(key) or not agent.known_cells.has(key))
	var start:=Vector2i(roundi(origin.x/CELL),roundi(origin.y/CELL))
	if not grid.region.has_point(start):return []
	grid.set_point_solid(start,false)
	for target:Vector2 in targets:
		var finish:=Vector2i(roundi(target.x/CELL),roundi(target.y/CELL))
		if not grid.region.has_point(finish) or grid.is_point_solid(finish):continue
		var raw:=grid.get_point_path(start,finish,false)
		var result:Array=[]
		var previous:=origin
		for index in range(1,raw.size()):
			var next:Vector2=raw[index]
			if not clear_line(previous,next,geometry,RADIUS) or not clear_bodies(previous,next,agents,str(agent.id)):result=[];break
			result.append([next.x,next.y]);previous=next
		if result.is_empty() and start!=finish:continue
		if not clear_line(previous,target,geometry,RADIUS) or not clear_bodies(previous,target,agents,str(agent.id)):continue
		result.append([target.x,target.y])
		return result
	return []

static func _geometry_key(geometry:Dictionary)->int:
	return hash([geometry.bounds,geometry.walls,geometry.doors,geometry.get("props",[])])
