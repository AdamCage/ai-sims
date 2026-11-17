extends SceneTree
## A deterministic observer choreographs a successful shift using normal
## physical actions. The pilot's map is test-only; agents are not given it.
const Simulation = preload("res://scripts/game/session_simulation.gd")
const Spatial = preload("res://scripts/game/spatial_rules.gd")
var simulation
var known_cells:Dictionary
var routes:Dictionary={}
var actions:=0
var failed:=false

func _initialize()->void:
	for map_id in ["closed_block","residence","research_station"]:
		for count in [3,8,20]:
			var selected:=OS.get_cmdline_user_args()
			if not selected.is_empty() and selected[0]!="%s/%d"%[map_id,count]:continue
			if not play(map_id,count):
				printerr("Failed ",map_id,"/",count," at minute ",simulation.state.minute)
				quit(1)
				return
	quit(0)

func play(map_id:String,count:int)->bool:
	simulation=Simulation.new()
	simulation.reset(map_id,count,"episode",42)
	routes.clear()
	actions=0
	var geometry:Dictionary=simulation.state.geometry
	var bounds:Array=geometry.bounds
	known_cells={}
	for x in range(floori(float(bounds[0])/Spatial.CELL),ceili(float(bounds[1])/Spatial.CELL)+1):
		for z in range(floori(float(bounds[2])/Spatial.CELL),ceili(float(bounds[3])/Spatial.CELL)+1):
			known_cells["%d:%d"%[x,z]]=true
	var ids:Array=simulation.state.agents.keys()
	if map_id=="research_station":
		var board:Dictionary=geometry.props.filter(func(p):return p.id=="comms_notice")[0]
		var admin:String=ids[2]
		if not approach(admin,Spatial.point(board),board.id) or not targeted(admin,board.id,Spatial.point(board),{"type":"interact"}):return false
		var hungry:Array=ids.filter(func(id):return simulation.state.agents[id].needs.hunger>=70.0)
		var terminal:Dictionary=geometry.props.filter(func(p):return p.id=="supply_terminal")[0]
		if not hungry.is_empty() and not gather(hungry,Vector2(49.0,0.0)):return false
		for id in hungry:
			var parking:=Spatial.point(simulation.state.agents[id])
			if not approach(id,Spatial.point(terminal),terminal.id) or not act(id,{"type":"request_ration"}):return false
			if not act(id,{"type":"consume","slot":food_slot(id)}) or not travel({id:parking}):return false
		while simulation.state.minute<180.0:simulation.advance(10.0)
		var console:Dictionary=geometry.props.filter(func(p):return p.id=="network_console")[0]
		if not approach(admin,Spatial.point(console),console.id) or not targeted(admin,console.id,Spatial.point(console),{"type":"interact"}):return false
		if not simulation.state.network.online or not simulation.state.scenario_state.metrics.verified_sources.has(admin):return false
		while simulation.state.minute<480.0:simulation.advance(10.0)
		if not gather(ids,Spatial.point({"position":geometry.zones.evacuation}),true):return false
	else:
		var service:String="supply_terminal" if map_id=="closed_block" else "shop_counter"
		var counter:Dictionary=geometry.props.filter(func(p):return p.id==service)[0]
		var center:=Spatial.point(counter)
		var meeting:=Vector2(float(geometry.zones.supply[0]),float(geometry.zones.supply[1])) if map_id=="closed_block" else Vector2(float(geometry.zones.shop[0]),float(geometry.zones.shop[1]))
		meeting = Vector2(12.0,0.0) if map_id=="closed_block" else meeting+Vector2(-15.5,0.0)
		if not gather(ids,meeting):return false
		if map_id=="residence":
			# Financial assistance must lead to an actual purchase.
			for recipient in ids:
				if simulation.state.agents[recipient].tokens>=5:continue
				var donor:String=""
				for id in ids:
					if int(simulation.state.agents[id].tokens)>=5+5-int(simulation.state.agents[recipient].tokens):donor=id;break
				if donor=="" or not interact_near(donor,recipient,{"type":"transfer_tokens","tokens":5-int(simulation.state.agents[recipient].tokens)}):
					printerr("Could not fund ",recipient," from ",donor," balance ",simulation.state.agents[recipient].tokens)
					return false
		for id in ids:
			var parking:=Spatial.point(simulation.state.agents[id])
			if not approach(id,center,service):
				printerr("No route for ",id," to ",service)
				return false
			if map_id=="closed_block":
				if not act(id,{"type":"request_ration"}):return false
			else:
				if not targeted(id,service,center,{"type":"buy","kind":"ration"}):return false
			if not travel({id:parking}):return false
		if map_id=="closed_block":
			for pair in [[ids[0],ids[1]],[ids[1],ids[0]]]:
				var slot:=food_slot(pair[0])
				if slot<0 or not interact_near(pair[0],pair[1],{"type":"give","slot":slot}):return false
		for id in ids:
			if not act(id,{"type":"consume","slot":food_slot(id)}):return false
	while not simulation.state.scenario_state.completed:simulation.advance(minf(10.0,720.0-float(simulation.state.minute)))
	var story:Dictionary=simulation.state.scenario_state
	print("EPISODE ",map_id,"/",count," outcome=",story.outcome.id," actions=",actions," alive=",story.metrics.alive," assembled=",story.metrics.assembled)
	return story.outcome.kind=="success" and int(story.metrics.interventions)==0

func food_slot(id:String)->int:
	var inventory:Array=simulation.state.agents[id].inventory
	for slot in inventory.size():
		if simulation.state.items[inventory[slot]].kind=="ration":return slot
	return -1

func gather(ids:Array,center:Vector2,assembly:bool=false)->bool:
	var targets:Dictionary={}
	var geometry:Dictionary=simulation.state.geometry
	var rows:Array=[7.5,4.5,1.5,-1.5,-4.5,-7.5] if assembly else [-5.25,-2.25,0.75,3.75,6.75,-6.75,8.25]
	var columns:Array=[-4.5,-1.5,1.5,4.5] if assembly else [-3.75,-1.5,0.75,3.0]
	for dz in rows:
		for dx in columns:
			if targets.size()==ids.size():return travel(targets)
			var point:=center+Vector2(dx,dz)
			if Spatial.walkable(point,geometry):targets[ids[targets.size()]]=point
	return targets.size()==ids.size() and travel(targets)

func approach(id:String,point:Vector2,target:String)->bool:
	var actor:Dictionary=simulation.state.agents[id]
	var probes:Array=[]
	for angle in range(0,360,30):
		var p:=point+1.28*Vector2.from_angle(deg_to_rad(angle))
		if Spatial.walkable(p,simulation.state.geometry,simulation.state.agents,id) and Spatial.clear_line(p,point,simulation.state.geometry,0.0,target,true):
			probes.append(p)
	probes.sort_custom(func(a,b):return Spatial.point(actor).distance_squared_to(a)<Spatial.point(actor).distance_squared_to(b))
	for p in probes:
		if travel({id:p},true):return true
	printerr("Approach failed ",id," from ",actor.position," probes ",probes," last ",actor.last_result," busy ",actor.busy)
	return false

func interact_near(id:String,target:String,action:Dictionary)->bool:
	var person:Vector2=Spatial.point(simulation.state.agents[target])
	var parking:Vector2=Spatial.point(simulation.state.agents[id])
	if not approach(id,person,target) or not targeted(id,target,person,action):return false
	return travel({id:parking})

func targeted(id:String,target:String,point:Vector2,action:Dictionary)->bool:
	var turn:=Spatial.bearing(simulation.state.agents[id],point)
	if not act(id,{"type":"turn","degrees":turn}):return false
	simulation.observe(id)
	for ref in simulation._refs[id]:
		if simulation._refs[id][ref].id==target:
			action["target"]=ref
			return act(id,action)
	printerr("Invisible interaction target ",target," from ",simulation.state.agents[id].position)
	return false

func act(id:String,action:Dictionary)->bool:
	var result:Dictionary=simulation.submit(id,action)
	if not result.ok:
		printerr("Submit ",id," ",action," ",result.reason)
		return false
	actions+=1
	simulation.advance(0.05)
	if not simulation.state.agents[id].last_result.ok:
		printerr("Execute ",id," ",action," ",simulation.state.agents[id].last_result.message)
		return false
	return true

func travel(targets:Dictionary,optional:bool=false)->bool:
	routes.clear()
	var geometry:Dictionary=simulation.state.geometry
	for iteration in 140:
		if simulation.state.scenario_state.completed:return false
		var pending:=0
		var requested:=0
		for id in targets:
			var actor:Dictionary=simulation.state.agents[id]
			var start:=Spatial.point(actor)
			var goal:Vector2=targets[id]
			if start.distance_to(goal)<0.12:continue
			pending+=1
			if not actor.busy.is_empty():requested+=1;continue
			var next:Vector2=goal
			if not Spatial.clear_line(start,goal,geometry,Spatial.RADIUS) or not Spatial.clear_bodies(start,goal,simulation.state.agents,id):
				var path:Array=routes.get(id,[])
				while not path.is_empty():
					var point:=Vector2(path[0][0],path[0][1])
					if start.distance_to(point)>0.12:break
					path.pop_front()
				var reroute:bool=path.is_empty() or not actor.last_result.get("ok",true)
				if not reroute:
					var p:=Vector2(path[0][0],path[0][1])
					reroute=not Spatial.clear_bodies(start,p,simulation.state.agents,id) or not Spatial.clear_line(start,p,geometry,Spatial.RADIUS)
				if reroute:
					var pilot:Dictionary=actor.duplicate(false)
					pilot.known_cells=known_cells
					path=Spatial.path(pilot,goal,geometry,simulation.state.agents)
					routes[id]=path
				if path.is_empty():continue
				var waypoint:=0
				while waypoint+1<path.size():
					var p:=Vector2(path[waypoint+1][0],path[waypoint+1][1])
					if not Spatial.clear_line(start,p,geometry,Spatial.RADIUS) or not Spatial.clear_bodies(start,p,simulation.state.agents,id):break
					waypoint+=1
				next=Vector2(path[waypoint][0],path[waypoint][1])
				if waypoint>0:path.assign(path.slice(waypoint))
			var delta:=(next-start).limit_length(4.85)
			if delta.length()<0.01:continue
			var heading:=deg_to_rad(float(actor.heading))
			var move:Dictionary={"type":"move","forward":delta.dot(Vector2(-sin(heading),-cos(heading))),"right":delta.dot(Vector2(cos(heading),-sin(heading)))}
			var reply:Dictionary=simulation.submit(id,move)
			if reply.ok:requested+=1;actions+=1
			else:printerr("Movement refused for ",id,": ",reply.reason)
		if pending==0:return true
		if requested==0:break
		simulation.advance(2.1 if targets.size()>1 else 1.1)
	if not optional:
		for id in targets:
			var actor:Dictionary=simulation.state.agents[id]
			if Spatial.point(actor).distance_to(targets[id])>0.12:printerr("Stopped ",id," at ",actor.position," goal ",targets[id]," last ",actor.last_result," next ",routes.get(id,[]).slice(0,3))
	return false
