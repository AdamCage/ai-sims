extends RefCounted
const Simulation=preload("res://scripts/game/session_simulation.gd")
const Spatial=preload("res://scripts/game/spatial_rules.gd")
var failures:Array=[]
var checks:int=0

func check(value:bool,label:String)->void:
	checks+=1
	if not value:failures.append("Alpha simulation: "+label)

func run()->Array:
	for map_id in ["closed_block","residence","research_station"]:
		for count in [3,8,20]:_test_episode(map_id,count)
	_test_frozen_observations()
	_test_stage_sources_and_interventions()
	_test_printed_routes()
	print("Alpha simulation: ",checks," checks; ",failures.size()," failures")
	return failures

func _test_episode(map_id:String,count:int)->void:
	var sim=Simulation.new();sim.reset(map_id,count,"episode",42)
	var label:String=map_id+"/"+str(count)
	check(sim.state.has("scenario_state") and int(sim.state.scenario_state.phase)==1,label+" has an authored default episode")
	check(sim.state.geometry.districts.size()>=3 and sim.state.geometry.rooms.size()>=12 and sim.state.geometry.landmarks.size()>=5,label+" has districts, functional destinations and orientation points")
	for actor in sim.state.agents.values():
		check(Spatial.walkable(Spatial.point(actor),sim.state.geometry,sim.state.agents,str(actor.id)),label+" valid body "+str(actor.id))
		check(sim.state.items[actor.inventory[0]].holder==actor.id,label+" owns physical personal phone")
	if count==8:
		if map_id=="research_station":
			var station=Simulation.new()
			station.reset(map_id,count,"episode",42)
			while station.state.minute<480.0:station.advance(60)
			_test_destinations(station,label)
		else:_test_destinations(sim,label)
	var restored=Simulation.new()
	check(restored.import_state(sim.export_state()),label+" episode saves with physical resources and private experience")
	# Build an explicit successful history using executed food transfers. These are
	# outcome fixtures, not a claim that autonomous models always choose success.
	_open_fixture(sim)
	for actor in sim.state.agents.values():
		actor.needs.hunger=20.0;actor.needs.fatigue=10.0
	if map_id=="closed_block":
		for recipient in ["person_01","person_02"]:_gift(sim,recipient)
	elif map_id=="residence":
		for recipient in sim.state.scenario_state.initial_poor:_gift(sim,str(recipient))
	else:
		var zone:Array=sim.state.geometry.zones.evacuation
		for index in count:sim.state.agents.values()[index].position=[float(zone[0])+float(index%5)-2.0,float(zone[1])+float(index/5)-2.0]
	sim.state.minute=719.9;sim.advance(0.1)
	check(sim.state.scenario_state.completed and sim.state.scenario_state.outcome.kind=="success",label+" explicit successful history receives a substantive ending")
	check(sim.state.scenario_state.debrief.size()>=3,label+" ending explains measured consequences")
	check(Simulation.new().import_state(sim.export_state()),label+" completed story reloads")
	var partial=Simulation.new();partial.reset(map_id,count,"episode",42)
	partial.state.minute=719.9
	for actor in partial.state.agents.values():actor.needs.hunger=20.0;actor.needs.fatigue=10.0
	if map_id!="research_station":partial.state.agents.person_00.needs.hunger=90.0
	partial.advance(0.1)
	check(partial.state.scenario_state.outcome.kind=="partial",label+" missing help or assembly produces a partial ending")
	check(partial.intervene("continue_sandbox",{}).ok,label+" can continue a completed shift")
	check(partial.state.completed_episode.completed and partial.state.scenario=="sandbox" and not partial.state.has("scenario_state"),label+" continuation retains the result without restarting the episode")
	check(Simulation.new().import_state(partial.export_state()),label+" continued sandbox reloads")
	var failed=Simulation.new();failed.reset(map_id,count,"episode",42)
	failed._die("person_00","Outcome fixture")
	failed.state.minute=719.9;failed.advance(0.1)
	check(failed.state.scenario_state.outcome.kind=="failure",label+" losses cannot be reported as success")

func _test_destinations(sim:Object,label:String)->void:
	var probe:Dictionary=sim.state.agents.person_00.duplicate(true)
	probe.position=sim.state.geometry.zones.spawn.duplicate();probe.known_cells={}
	var bounds:Array=sim.state.geometry.bounds
	for x in range(floori(float(bounds[0])/Spatial.CELL),ceili(float(bounds[1])/Spatial.CELL)+1):
		for z in range(floori(float(bounds[2])/Spatial.CELL),ceili(float(bounds[3])/Spatial.CELL)+1):probe.known_cells["%d:%d"%[x,z]]=true
	for room in sim.state.geometry.rooms:
		check(Spatial.walkable(Vector2(room.center[0],room.center[1]),sim.state.geometry),label+" usable room centre "+str(room.id))
		var route:Array=Spatial.path(probe,Vector2(room.center[0],room.center[1]),sim.state.geometry,{})
		check(not route.is_empty(),label+" connected destination "+str(room.id))

func _open_fixture(sim:Object)->void:
	sim.state.geometry.walls=[];sim.state.geometry.doors=[];sim.state.geometry.props=[]
	for index in sim.state.agents.size():sim.state.agents.values()[index].position=[-20.0+index*1.2,8.0]

func _gift(sim:Object,recipient:String)->void:
	var sender:Dictionary=sim.state.agents.person_00;var receiver:Dictionary=sim.state.agents[recipient]
	sender.position=[0.0,0.0];sender.heading=-90.0;receiver.position=[1.0,0.0]
	var food:Dictionary=sim._new_item("ration","Fixture ration",sender.position,"person_00","person_00")
	var ref:String=_ref(sim,"person_00",recipient)
	check(not ref.is_empty(),"gift target is personally visible")
	check(sim.submit("person_00",{"type":"give","slot":sender.inventory.find(food.id),"target":ref}).ok,"food gift is accepted")
	sim.advance(0.1)
	check(receiver.inventory.has(food.id),"food physically reaches its recipient")
	var gift_seq:int=sim.state.events[-1].seq
	check(sim.submit(recipient,{"type":"consume","slot":receiver.inventory.find(food.id)}).ok,"recipient eats the donated ration")
	sim.advance(0.1)
	check(sim.state.events.any(func(ev):return ev.type=="consume" and ev.cause==gift_seq),"meal identifies the causal gift in the journal")
	receiver.position=[-20.0+int(recipient.trim_prefix("person_"))*1.2,8.0]

func _ref(sim:Object,id:String,target:String)->String:
	sim.observe(id)
	for key in sim._refs.get(id,{}):
		if sim._refs[id][key].id==target:return str(key)
	return ""

func _test_frozen_observations()->void:
	var sim=Simulation.new();sim.reset("closed_block",3,"sandbox",1)
	sim.state.geometry={"bounds":[-20.0,20.0,-20.0,20.0],"walls":[],"doors":[],"props":[]}
	var actor:Dictionary=sim.state.agents.person_00
	actor.position=[-4.0,0.0];actor.heading=-90.0
	sim.state.agents.person_01.position=[0.0,0.0];sim.state.agents.person_02.position=[8.0,8.0]
	var target:String=_ref(sim,"person_00","person_01")
	var refs:Dictionary=sim.capture_observation_refs("person_00")
	var minute:float=sim.state.minute
	sim.state.agents.person_01.position=[0.0,6.0]
	sim.observe("person_00")
	var tampered:Dictionary=refs.duplicate(true);tampered[target]={"category":"agent","id":"person_02","position":[8.0,8.0]}
	check(sim.submit_observed("person_00",{"type":"move_to","target":target},tampered,int(sim.state.run_id),minute).ok,"capture authority ignores caller mutation of target bindings")
	sim.advance(0.1)
	check(actor.busy.target=="person_01","old ref is never reinterpreted after another observation")
	var endpoint:Array=actor.busy.path[-1]
	check(Vector2(endpoint[0],endpoint[1]).distance_to(Vector2.ZERO)<1.2,"mobile target route ends at last seen position")
	check(not sim.submit_observed("person_02",{"type":"look"},refs,int(sim.state.run_id),minute).ok,"another actor cannot use a capture")
	check(not sim.submit_observed("person_00",{"type":"move_to","target":"person_02"},refs,int(sim.state.run_id),minute).ok,"world ids cannot become visual targets")
	sim.restrict_observation_refs("person_00",refs,[])
	check(not sim.submit_observed("person_00",{"type":"move_to","target":target},refs,int(sim.state.run_id),minute).ok,"refs outside the rendered image are removed from the authoritative capture")
	actor.service_refs={"messages":{"m0":"previous"}}
	sim.observe("person_00");var service_refs:Dictionary=sim.capture_observation_refs("person_00")
	actor.service_refs.messages.m0="new_private_message"
	check(not sim.submit_observed("person_00",{"type":"read_message","message":"m0"},service_refs,int(sim.state.run_id),float(sim.state.minute)).ok,"changed service refs cannot reveal an unobserved new message")
	sim.state.minute=31.0
	check(not sim.submit_observed("person_00",{"type":"look"},refs,int(sim.state.run_id),minute).ok,"old observation expires")
	var old_run:int=sim.state.run_id;sim.reset("residence",3,"episode",1)
	check(not sim.submit_observed("person_00",{"type":"look"},refs,old_run,minute).ok,"reset invalidates outstanding observations")
	var observation:Dictionary=sim.observe("person_00")
	check(not observation.has("scenario_state") and not observation.has("geometry") and not observation.has("events"),"observer story, map and global event graph never enter private observation")
	var damaged:Dictionary=sim.export_state()
	damaged.world.scenario_state.metrics.funded={"missing_person":1}
	check(not Simulation.new().import_state(damaged),"malformed story metrics cannot reach a live session")
	var invalid_place:Dictionary=sim.export_state()
	invalid_place.world.geometry.rooms[0].center={}
	check(not Simulation.new().import_state(invalid_place),"corrupted room geometry is rejected before presentation")
	var experience:Array=sim.state.agents.person_00.personal_results.duplicate(true)
	sim.snapshot();sim.observer_status("person_00")
	check(experience==sim.state.agents.person_00.personal_results,"observer inspection grants no personal knowledge")

func _test_printed_routes()->void:
	var sim:=Simulation.new()
	sim.reset("research_station",3,"sandbox",52)
	var board:={"id":"chart","kind":"noticeboard","center":[-5.0,-1.0],"size":[0.8,0.2],"height":1.7,"label":"Холл","document":"План этажа"}
	var barrier:={"id":"gate","center":[0.0,0.0],"size":[0.2,2.8],"height":2.8,"open":false,"locked":true}
	sim.state.geometry={"bounds":[-10.0,10.0,-6.0,6.0],"walls":[],"props":[board],"doors":[barrier],"rooms":[{"id":"hall","label":"Холл","center":[-5.0,0.0],"size":[10.0,12.0]},{"id":"exit","label":"Сборный пункт","center":[5.0,0.0],"size":[10.0,12.0]}]}
	for sign_value in [-1.0,1.0]:sim.state.geometry.walls.append({"id":"partition"+str(sign_value),"center":[0.0,3.7*sign_value],"size":[0.2,4.6],"height":2.8})
	for i in 3:sim.state.agents.values()[i].position=[-5.0 if i==0 else 7.0,float(i)*1.5];sim.state.agents.values()[i].heading=0
	var reader:Dictionary=sim.state.agents.person_00
	var peer:Dictionary=sim.state.agents.person_01
	var board_ref:=_ref(sim,reader.id,board.id)
	var before:=sim.capture_observation_refs(reader.id)
	var peer_view:=sim.observe(peer.id)
	var peer_capture:=sim.capture_observation_refs(peer.id)
	check(not peer_view.mock_view.any(func(v):return v.kind=="noticeboard"),"closed partition hides the printed floor plan")
	var follow:={"type":"follow_route","route":"r1"}
	check(not sim.submit_observed(reader.id,follow,before,sim.state.run_id,sim.state.minute).ok,"looking at a floor plan grants no route without reading")
	check(sim.submit_observed(reader.id,{"type":"interact","target":board_ref},before,sim.state.run_id,sim.state.minute).ok,"reader interacts with the personally visible physical floor plan")
	sim.advance(0.1)
	var chart:Array=reader.personal_results.filter(func(row):return row.channel=="floor_plan")
	check(chart.size()==1 and chart[0].entries.size()==2 and chart[0].entries[1].keys().size()==2,"public plan gives local labels and opaque refs only")
	check(not sim.submit_observed(peer.id,follow,peer_capture,sim.state.run_id,0.0).ok,"another resident behind the partition cannot use the reader's map")
	check(not sim.submit_observed(reader.id,follow,before,sim.state.run_id,0.0).ok,"pre-reading observation cannot use a later map acquisition")
	sim.observe(reader.id)
	var now:=sim.capture_observation_refs(reader.id)
	check(sim.submit_observed(reader.id,follow,now,sim.state.run_id,sim.state.minute).ok,"a freshly observed personally read route is accepted")
	for tick in 20:sim.advance(0.5)
	check(float(reader.position[0])<0.0 and not reader.last_result.ok,"printed route physically stops at an unexpectedly locked passage")
	var station:=Simulation.new()
	station.reset("research_station",3,"episode",52)
	var archive:Array=station.state.geometry.zones.arrival
	for i in 3:station.state.agents.values()[i].position=[archive[0]+i,archive[1]]
	station.state.minute=719.9;station.advance(0.1)
	check(station.state.scenario_state.metrics.assembled==0 and station.state.scenario_state.outcome.id=="separated","occupying the obsolete northern rendezvous does not complete evacuation")

func _test_stage_sources_and_interventions()->void:
	for map_id in ["closed_block","residence","research_station"]:
		var sim=Simulation.new();sim.reset(map_id,8,"episode",1)
		var goal:String=sim.state.agents.person_00.profile.goal
		for index in 5:check(sim.intervene("episode_intervention",{"intervention":"announcement","text":"Источник — наблюдатель. Проверьте местные правила."}).ok,"observer announcements are not limited to three points")
		check(goal==sim.state.agents.person_00.profile.goal,"announcements do not force thoughts or goals")
		sim.state.minute=179.9;sim.advance(0.1)
		check(int(sim.state.scenario_state.phase)==2,"crisis begins on world time "+map_id)
		var event_count:int=sim.state.events.filter(func(e):return e.type=="story_event" and e.details.get("source")=="external_crisis").size()
		sim.advance(0.1)
		check(sim.state.events.filter(func(e):return e.type=="story_event" and e.details.get("source")=="external_crisis").size()==event_count,"external crisis fires exactly once "+map_id)
		if map_id=="research_station":check(not sim.state.network.online,"storm changes actual service availability")
		elif map_id=="residence":check(int(sim.state.economy.prices.ration)==5,"crisis changes actual finite economy")
		check(sim.intervene("episode_intervention",{"intervention":"reserve"}).ok,"physical reserve intervention "+map_id)
		check(sim.intervene("episode_intervention",{"intervention":"policy"}).ok,"external policy intervention "+map_id)
		check(sim.state.events[-1].has("participants") and sim.state.events[-1].has("place") and sim.state.events[-1].has("cause"),"events contain focusable causal presentation data")
	var alias=Simulation.new();alias.reset("closed_block",3,"network",1)
	check(alias.state.scenario=="deception" and alias.state.network.messages.has("scenario_notice"),"legacy menu communication alias reaches actual deception scenario")
	alias.reset("closed_block",3,"survival",1)
	check(alias.state.scenario=="last_ration" and int(alias.state.terminal.stock)==0,"legacy survival alias reaches actual last ration")
