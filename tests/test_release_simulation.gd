extends RefCounted
const Simulation=preload("res://scripts/game/session_simulation.gd")
const Spatial=preload("res://scripts/game/spatial_rules.gd")
const Catalog=preload("res://scripts/game/action_catalog.gd")
var failures:Array=[]
var checks:=0

func check(value:bool,label:String)->void:
	checks+=1
	if not value:failures.append("Release simulation: "+label)

func run()->Array:
	failures=[];checks=0
	_test_maps_and_persistence()
	_test_physical_actions()
	_test_combat_and_body()
	_test_economy()
	_test_network()
	_test_artifacts()
	_test_release_regressions()
	_test_navigation_and_service_access()
	_test_rescue_and_trade_lifecycle()
	_test_shared_device_reuse()
	_test_food_journey_through_door()
	_test_god_physical_consistency()
	_test_personal_experience_delivery()
	_test_repeated_arrived_target_feedback()
	_test_indexed_photo_flows()
	print("Release simulation: ",checks," checks; ",failures.size()," failures")
	return failures

func _test_repeated_arrived_target_feedback()->void:
	var sim=_fresh()
	sim.state.geometry={"bounds":[-8.0,8.0,-8.0,8.0],"walls":[],"doors":[],"props":[]}
	var actor:Dictionary=sim.state.agents.person_00
	actor.position=[-4.0,0.0];actor.heading=-90.0
	sim.state.agents.person_01.position=[5.0,5.0];sim.state.agents.person_02.position=[-5.0,5.0]
	var food:Dictionary=sim._new_item("ration","visible ration",[0.0,0.0])
	var inventory_count:int=actor.inventory.size()
	check(_act(sim,"person_00",{"type":"move_to","target":_ref(sim,"person_00",food.id)},.1).ok,"first approach to distant visible target starts real movement")
	for step in 16:
		if actor.busy.is_empty():break
		sim.advance(.25)
	check(actor.busy.is_empty() and Spatial.point(actor).distance_to(Spatial.point(food))<1.1,"first approach arrives beside target")
	var arrived:Array=actor.position.duplicate()
	var repeated:Dictionary=_act(sim,"person_00",{"type":"move_to","target":_ref(sim,"person_00",food.id)},.1)
	check(not repeated.ok and str(repeated.message).contains("Перемещение не выполняет взаимодействие"),"repeated zero-distance approach explains separate interaction is required")
	check(actor.position==arrived and actor.busy.is_empty(),"rejected arrived-target no-op leaves position and movement unchanged")
	check(food.holder.is_empty() and int(food.quantity)==1 and actor.inventory.size()==inventory_count,"approach feedback neither takes nor consumes target resource")
	check(_act(sim,"person_00",{"type":"move","forward":0.03,"right":0.0},.1).ok and actor.position!=arrived,"legitimate short relative movement remains allowed")

func _test_indexed_photo_flows()->void:
	var sim=_fresh()
	var hashes:Array=["a".repeat(64),"b".repeat(64)]
	for digest in hashes:
		check(_act(sim,"person_00",{"type":"take_photo","digital":true}).ok,"digital album photo created")
		var artifact_id:String=sim.state.items.phone_00.files[-1]
		check(sim.attach_photo("person_00",artifact_id,digest),"fixture frame attached to indexed album entry")
	check(_act(sim,"person_00",{"type":"view_photo","slot":0,"index":0}).ok,"first photo can be viewed after a newer one exists")
	check(sim.state.agents.person_00.personal_results[-1].image_ref==hashes[0],"indexed view grants the chosen exact image")
	_act(sim,"person_00",{"type":"use_device","slot":0,"app":"gallery"})
	check(sim.device_screen("person_00").image_ref==hashes[0],"gallery shows the explicitly selected older photograph")
	check(_act(sim,"person_00",{"type":"copy_photo","slot":0,"index":0}).ok,"selected older digital photo can be copied")
	check(sim.state.artifacts[sim.state.items.phone_00.files[-1]].image_ref==hashes[0],"copy preserves the chosen image rather than latest-original substitution")
	check(_act(sim,"person_00",{"type":"show_photo","slot":0,"index":1,"target":_ref(sim,"person_00","person_01")}).ok,"selected second image shown to reachable viewer")
	check(sim.state.agents.person_01.personal_results[-1].image_ref==hashes[1],"viewer receives selected image only")
	sim._introduce("person_00","person_01")
	_act(sim,"person_00",{"type":"use_device","slot":0,"app":"messages"})
	check(_act(sim,"person_00",{"type":"send_message","contact":"c0","text":"old photo","attachment":0,"attachment_index":0}).ok,"message attaches chosen older album entry")
	var message:Dictionary=sim.state.network.messages.values()[-1]
	check(sim.state.artifacts[message.attachment].image_ref==hashes[0],"attachment references exact selected image")
	check(not _act(sim,"person_00",{"type":"copy_photo","slot":0,"index":999}).ok,"invalid album index fails without selecting another image")
	check(not Catalog.validate({"type":"send_message","contact":"c0","text":"x","attachment_index":0}).ok,"attachment index requires its own inventory device")
	var restored=Simulation.new()
	check(restored.import_state(sim.export_state()),"selected gallery state and indexed attachments reload")

func _test_personal_experience_delivery()->void:
	var sim=Simulation.new();sim.reset("closed_block",20,"sandbox",3)
	sim.state.geometry={"bounds":[-10.0,10.0,-10.0,10.0],"walls":[],"doors":[],"props":[]}
	for index in 20:
		var id:="person_%02d"%index
		sim.state.agents[id].position=[float(index%5)-2.0,float(index/5)-2.0]
	var delivered:Array=[]
	sim.personal_experience.connect(func(actor_id:String,experience:Dictionary):
		if actor_id!="person_00":return
		delivered.append(experience.duplicate(true))
		# A receiver owns its delivered copy, never the world's immutable tail.
		if not experience.heard.is_empty():experience.heard[0].text="signal_receiver_mutation"
		if not experience.personal_results.is_empty():experience.personal_results[0].nested.proof="signal_receiver_mutation")
	for index in range(1,20):
		check(sim.submit("person_%02d"%index,{"type":"speak","text":"speech_%02d"%index}).ok,"burst speaker submits own utterance "+str(index))
	sim.advance(.1)
	var listener:Dictionary=sim.state.agents.person_00
	check(delivered.size()==19,"all19 simultaneous speech experiences emitted before observer tail trimming")
	check(listener.heard.size()==12,"speech observer tail remains bounded independently of memory delivery")
	var spoken:Array=[]
	var stamps_valid:=true
	for experience in delivered:
		spoken.append(experience.heard[0].text)
		stamps_valid=stamps_valid and experience.keys().size()==4 and int(experience.tick)==1 and is_equal_approx(float(experience.minute),0.0) and experience.personal_results.is_empty()
	check(spoken[0]=="speech_01" and spoken[-1]=="speech_19" and spoken.size()==19,"signal preserves first through last speech, including entries discarded from short tail")
	check(stamps_valid,"speech signal contains only correctly stamped personal experience channels")
	check(not JSON.stringify(listener.heard).contains("signal_receiver_mutation"),"signal receiver cannot rewrite authoritative heard experience")
	for index in 25:
		var source:Dictionary={"channel":"diary","text":"entry_%02d"%index,"source":"read_physical_artifact","nested":{"proof":"original_%02d"%index}}
		sim._personal("person_00",source)
		source.text="source_mutation";source.nested.proof="source_mutation"
	check(delivered.size()==44,"all25 private results emitted despite20-entry observer tail")
	check(listener.personal_results.size()==20,"private result observer tail remains bounded")
	var results:Array=delivered.slice(19)
	check(results[0].personal_results[0].text=="entry_00" and results[-1].personal_results[0].text=="entry_24","private delivery retains results beyond observer tail capacity")
	check(results[0].personal_results[0].nested.proof=="original_00" and results[-1].personal_results[0].nested.proof=="original_24","private delivery owns nested copies of caller inputs")
	check(not JSON.stringify(listener.personal_results).contains("mutation"),"caller and signal mutations cannot rewrite authoritative private result tail")
	check(results[0].heard.is_empty() and int(results[0].tick)==1 and is_equal_approx(float(results[0].minute),.1),"private result delivery has its own post-step time and no fabricated speech")
	var other_heard:int=sim.state.agents.person_01.heard.size()
	check(sim.intervene("memory",{"id":"person_00","text":"","clear":true}).ok,"explicit god memory clear succeeds")
	check(listener.heard.is_empty() and listener.personal_results.is_empty(),"explicit memory clear removes both retained source buffers")
	check(bool(listener.memory_override.clear) and int(listener.memory_override.version)==1,"memory clear records explicit versioned intervention")
	check(sim.state.agents.person_01.heard.size()==other_heard,"one person's memory clear does not erase another person's heard experience")
	sim._personal("person_00",{"channel":"diary","text":"new_after_clear","source":"read_physical_artifact","nested":{"proof":"new"}})
	check(listener.personal_results.size()==1 and listener.personal_results[0].text=="new_after_clear" and delivered.size()==45,"new post-clear experience is delivered once without restoring cleared buffers")

func _test_navigation_and_service_access()->void:
	var sim=_fresh()
	sim.state.geometry={"bounds":[-8.0,8.0,-8.0,8.0],"walls":[],"doors":[],"props":[]}
	var actor:Dictionary=sim.state.agents.person_00
	actor.position=[-4.0,0.0];actor.heading=-90.0
	sim.state.agents.person_01.position=[0.0,0.0];sim.state.agents.person_02.position=[5.0,5.0]
	for x in range(-10,11):
		for z in range(-10,11):actor.known_cells["%d:%d"%[x,z]]=true
	check(not Spatial.clear_bodies(Vector2(-4,0),Vector2(4,0),sim.state.agents,"person_00"),"swept body test blocks tunnelling through a person")
	check(Spatial.clear_bodies(Vector2(-4,1),Vector2(4,1),sim.state.agents,"person_00"),"swept body test permits a route beside a person")
	var route:Array=Spatial.path(actor,Vector2(4,0),sim.state.geometry,sim.state.agents)
	check(route.size()>1,"navigation goes around a stationary person instead of choosing blocked straight line")
	check(sim._begin_travel("person_00",Vector2(4,0),"").ok,"crowd detour becomes a sustained plan")
	var prior:=Spatial.point(actor)
	for step in 12:
		sim.advance(0.5)
		check(Spatial.clear_bodies(prior,Spatial.point(actor),sim.state.agents,"person_00"),"each detour segment preserves body collision "+str(step))
		prior=Spatial.point(actor)
	check(actor.busy.is_empty() and Spatial.point(actor).distance_to(Vector2(4,0))<0.01,"detour arrives without repeated plan interruption")
	# A previously clear route may be occupied after it has started. A large step
	# must not tunnel through the new occupant or discard a recoverable route.
	actor.position=[-4.0,-3.0];sim.state.agents.person_01.position=[0.0,0.0]
	check(sim._begin_travel("person_00",Vector2(4,-3),"").ok,"initial clear corridor accepts plan")
	sim.state.agents.person_01.position=[-2.0,-3.0]
	prior=Spatial.point(actor);sim.advance(1.0)
	check(Spatial.clear_bodies(prior,Spatial.point(actor),sim.state.agents,"person_00"),"new blocker cannot be crossed by large logical step")
	check(not actor.busy.is_empty(),"new dynamic obstacle replans before abandoning movement")
	for step in 15:sim.advance(.5)
	check(actor.busy.is_empty() and Spatial.point(actor).distance_to(Vector2(4,-3))<.01,"replanned dynamic detour reaches original destination")
	# Terminal/shop proximity does not make a wall transparent to transactions.
	actor.position=[0.0,0.0];actor.heading=-90.0;actor.busy={}
	sim.state.agents.person_01.position=[5.0,0.0]
	sim.state.geometry.props=[{"id":"terminal_access","kind":"terminal","center":[1.5,0.0],"size":[.5,.5],"height":1.5},{"id":"shop_access","kind":"shop","center":[1.5,-1.0],"size":[.5,.5],"height":1.0}]
	sim.state.terminal.position=[1.5,0.0]
	sim.state.geometry.walls=[{"id":"barrier","center":[.75,0.0],"size":[.1,4.0],"height":2.8}]
	var stock:int=int(sim.state.terminal.stock)
	check(not _act(sim,"person_00",{"type":"request_ration"}).ok and int(sim.state.terminal.stock)==stock,"terminal refuses through-wall ration issue")
	var ration:Dictionary=_give(sim,"person_00","ration")
	var tokens:int=int(actor.tokens)
	check(not _act(sim,"person_00",{"type":"sell","slot":actor.inventory.find(ration.id)}).ok and int(actor.tokens)==tokens,"shop refuses through-wall sale")
	sim.state.geometry.walls=[]
	check(_act(sim,"person_00",{"type":"request_ration"}).ok,"accessible terminal issues ration normally")

func _test_rescue_and_trade_lifecycle()->void:
	var sim=_fresh()
	sim.state.geometry={"bounds":[-8.0,8.0,-8.0,8.0],"walls":[],"doors":[],"props":[]}
	var carrier:Dictionary=sim.state.agents.person_00
	var passenger:Dictionary=sim.state.agents.person_01
	var third:Dictionary=sim.state.agents.person_02
	carrier.position=[0.0,0.0];carrier.heading=-90.0
	passenger.position=[1.0,0.0];passenger.body.left_leg="broken"
	third.position=[1.0,1.0];third.body.left_leg="broken"
	check(_act(sim,"person_00",{"type":"carry","target":_ref(sim,"person_00","person_01")}).ok,"rescue picks up one injured person")
	check(not _ref(sim,"person_00","person_02").is_empty(),"own passenger does not occlude all carrier perception")
	check(not _act(sim,"person_00",{"type":"carry","target":_ref(sim,"person_00","person_02")}).ok,"carrier cannot overwrite an existing passenger")
	check(carrier.carrying==passenger.id and passenger.carried_by==carrier.id and third.carried_by.is_empty(),"rejected second carry preserves reciprocal rescue links")
	var hunger:float=float(passenger.needs.hunger)
	sim.advance(10.0)
	check(float(passenger.needs.hunger)>hunger,"carrying does not freeze passenger bodily needs")
	sim._die("person_00","fixture")
	check(passenger.carried_by.is_empty() and passenger.busy.is_empty(),"carrier death releases passenger from permanent carried state")
	check(Simulation.new().import_state(sim.export_state()),"rescue state after carrier death remains loadable")
	sim=_fresh();carrier=sim.state.agents.person_00;passenger=sim.state.agents.person_01
	carrier.body.left_arm="broken";carrier.body.right_arm="broken"
	var total_tokens:int=int(carrier.tokens)+int(passenger.tokens)
	check(not _act(sim,"person_00",{"type":"transfer_tokens","target":_ref(sim,"person_00","person_01"),"tokens":2}).ok,"both broken hands prevent physical token transfer")
	check(int(carrier.tokens)+int(passenger.tokens)==total_tokens,"rejected token transfer preserves money")
	carrier.body.left_arm="healthy";carrier.body.right_arm="healthy"
	check(_act(sim,"person_00",{"type":"offer","target":_ref(sim,"person_00","person_01"),"tokens":2}).ok,"known reachable counterparty receives proposal")
	var offer_ref:String=passenger.offer_refs.keys()[0]
	sim.state.geometry.walls.append({"id":"trade_barrier","center":[-2.5,1.0],"size":[.1,1.0],"height":2.8})
	check(not _act(sim,"person_01",{"type":"accept_offer","offer":offer_ref}).ok,"previous proposal cannot teleport its exchange through a new wall")
	sim.state.geometry.walls=[];sim._die("person_00","fixture")
	check(not _act(sim,"person_01",{"type":"accept_offer","offer":offer_ref}).ok,"dead counterparty cannot perform pending physical trade")
	check(int(carrier.tokens)+int(passenger.tokens)==total_tokens,"failed trades conserve token balance")
	sim=_fresh();passenger=sim.state.agents.person_01
	passenger.sleeping=true;passenger.busy={"type":"sleep","remaining":60.0}
	var heard:int=passenger.heard.size()
	_act(sim,"person_00",{"type":"speak","text":"No subconscious information injection."})
	check(passenger.heard.size()==heard,"sleeping listener does not receive conscious speech experience")

func _test_shared_device_reuse()->void:
	var sim=_fresh()
	sim.state.geometry={"bounds":[-8.0,8.0,-8.0,8.0],"walls":[],"doors":[],"props":[{"id":"terminal_access","kind":"terminal","center":[0.0,0.0],"size":[.5,.5],"height":1.5}]}
	sim.state.terminal.position=[0.0,0.0]
	sim.state.agents.person_00.position=[-1.0,0.0];sim.state.agents.person_01.position=[-1.0,1.0];sim.state.agents.person_02.position=[4.0,4.0]
	check(_act(sim,"person_00",{"type":"join_queue","kind":"phone"}).ok,"first borrower gets shared phone")
	var key:String=sim.state.terminal.loans.keys()[0]
	var first:Dictionary=sim.state.agents.person_00
	var slot:int=first.inventory.find(key)
	check(_act(sim,"person_00",{"type":"login","slot":slot}).ok,"first borrower logs into own account")
	check(_act(sim,"person_00",{"type":"logout","slot":slot}).ok,"first borrower deliberately logs out")
	check(_act(sim,"person_00",{"type":"return_device","slot":slot}).ok,"logged-out shared phone can be returned")
	check(_act(sim,"person_01",{"type":"join_queue","kind":"phone"}).ok,"next borrower gets returned shared phone")
	var second:Dictionary=sim.state.agents.person_01
	slot=second.inventory.find(key)
	check(slot>=0,"next borrower actually receives same physical device")
	check(_act(sim,"person_01",{"type":"login","slot":slot}).ok,"next borrower can open own account on common equipment")
	check(sim.state.items[key].account==second.id and sim.state.items[key].session_owner==second.id,"shared-device login does not impersonate earlier account")
	# A personally owned locked phone still protects its owner's account.
	var personal:Dictionary=sim.state.items.phone_00
	first.inventory.erase(personal.id);second.inventory.append(personal.id);personal.holder=second.id;personal.locked=true;personal.session_owner=""
	check(not _act(sim,"person_01",{"type":"login","slot":second.inventory.find(personal.id)}).ok,"common-device reuse rule does not unlock stolen personal phones")
	sim.state.terminal.queues.camera=["person_00","person_02"]
	sim._die("person_00","fixture")
	sim.state.agents.person_02.position=[1.0,0.0]
	sim.advance(.1)
	check(not sim.state.terminal.queues.camera.has("person_00"),"dead queue head does not permanently block living borrowers")
	var issued:=false
	for loan in sim.state.terminal.loans.values():
		if loan.actor=="person_02" and loan.kind=="camera":issued=true
	check(issued,"next living FIFO participant receives available device")

func _test_food_journey_through_door()->void:
	var sim=_fresh()
	sim.state.geometry={"bounds":[-7.0,7.0,-6.0,6.0],"walls":[{"id":"partition_top","center":[0.0,-3.45],"size":[.2,5.1],"height":2.8},{"id":"partition_bottom","center":[0.0,3.45],"size":[.2,5.1],"height":2.8}],"doors":[{"id":"food_door","center":[0.0,0.0],"size":[.2,1.8],"height":2.8,"open":false,"locked":false}],"props":[]}
	var actor:Dictionary=sim.state.agents.person_00
	actor.position=[-3.0,0.0];actor.heading=-90.0;actor.known_cells={}
	sim.state.agents.person_01.position=[4.0,4.0];sim.state.agents.person_02.position=[-4.0,4.0]
	var food:Dictionary=sim._new_item("ration","food",[3.0,0.0])
	check(_ref(sim,"person_00",food.id).is_empty(),"closed door conceals food in next room")
	var door_ref:=_ref(sim,"person_00","food_door")
	check(not door_ref.is_empty(),"closed door itself can be perceived")
	check(_act(sim,"person_00",{"type":"move_to","target":door_ref},.1).ok,"person can approach a closed door")
	for step in 10:
		if actor.busy.is_empty():break
		sim.advance(.25)
	check(_act(sim,"person_00",{"type":"open","target":_ref(sim,"person_00","food_door")}).ok,"closed door opens within actual reach")
	var food_ref:=_ref(sim,"person_00",food.id)
	check(not food_ref.is_empty(),"opening door makes newly exposed food personally visible")
	check(_act(sim,"person_00",{"type":"move_to","target":food_ref},.1).ok,"person can plan across newly opened doorway to food")
	for step in 20:
		if actor.busy.is_empty():break
		sim.advance(.25)
	check(float(actor.position[0])>0.0,"sustained route physically enters the other room")
	check(_act(sim,"person_00",{"type":"take","target":_ref(sim,"person_00",food.id)}).ok,"arrived actor can take real food without distance deadlock")
	actor.needs.hunger=80.0
	check(_act(sim,"person_00",{"type":"consume","slot":actor.inventory.find(food.id)}).ok and float(actor.needs.hunger)<41.0,"door journey ends with actual resource consumption")

func _test_god_physical_consistency()->void:
	var sim=_fresh()
	sim.state.geometry={"bounds":[-8.0,8.0,-8.0,8.0],"walls":[],"doors":[],"props":[{"id":"safe_bed","kind":"bed","center":[0.0,0.0],"size":[1.2,2.2],"height":.65}]}
	var actor:Dictionary=sim.state.agents.person_00
	actor.position=[0.0,0.0];actor.sleeping=true;actor.busy={"type":"sleep","remaining":60.0,"bed":"safe_bed"};actor.surface_height=.65
	sim.state.agents.person_01.position=[4.0,4.0];sim.state.agents.person_02.position=[-4.0,4.0]
	check(sim.intervene("body",{"id":"person_00","health":60.0}).ok,"god can edit body of sleeping bed occupant")
	check(actor.sleeping and actor.busy.get("bed","")=="safe_bed" and Simulation.new().import_state(sim.export_state()),"body edit preserves real bed association and loadable pose")
	check(sim.intervene("goal",{"id":"person_00","goal":"A new goal after waking."}).ok and actor.busy.get("bed","")=="safe_bed","god goal edit does not strand sleeper inside bed collider")
	check(sim.intervene("body",{"id":"person_00","sleeping":false}).ok and not actor.sleeping and Spatial.walkable(Spatial.point(actor),sim.state.geometry,sim.state.agents,"person_00"),"explicit god wake exits bed to safe floor")
	check(Simulation.new().import_state(sim.export_state()),"woken body state remains loadable")
	check(sim.intervene("body",{"id":"person_00","health":0.0}).ok,"god can explicitly kill body")
	var corpse:Vector2=Spatial.point(actor)
	check(sim.intervene("teleport",{"id":"person_01","position":[corpse.x,corpse.y]}).ok,"living person may occupy dead body's floor space")
	check(sim.intervene("body",{"id":"person_00","health":100.0}).ok,"god can revive displaced body")
	check(Spatial.walkable(Spatial.point(actor),sim.state.geometry,sim.state.agents,"person_00") and Simulation.new().import_state(sim.export_state()),"revival picks safe nearby floor instead of overlapping a living body")
	sim.state.geometry.props=[]
	sim.state.geometry.doors=[{"id":"god_door","center":[0.0,0.0],"size":[.2,1.8],"height":2.8,"open":true,"locked":false}]
	actor.position=[0.0,0.0]
	check(not sim.intervene("door",{"target":"god_door","open":false}).ok and sim.state.geometry.doors[0].open,"god door close cannot solidify through an occupied doorway")
	sim.state.geometry.doors=[]
	actor.position=[0.0,0.0];actor.heading=-90.0
	var passenger:Dictionary=sim.state.agents.person_02
	passenger.position=[1.0,0.0];passenger.body.left_leg="broken"
	sim.state.agents.person_01.position=[4.0,4.0]
	check(_act(sim,"person_00",{"type":"carry","target":_ref(sim,"person_00","person_02")}).ok,"carry setup for explicit teleport")
	check(sim.intervene("teleport",{"id":"person_00","position":[-3.0,-3.0]}).ok and passenger.position==actor.position,"carrier teleport immediately carries passenger to same authority position")
	check(sim.intervene("teleport",{"id":"person_02","position":[2.0,2.0]}).ok and passenger.carried_by.is_empty() and actor.carrying.is_empty(),"passenger teleport atomically releases both carry links")
	check(Simulation.new().import_state(sim.export_state()),"teleported rescue links and poses remain loadable")

func _fresh():
	var sim=Simulation.new()
	sim.reset("closed_block",3,"sandbox",1)
	sim.state.agents.person_00.position=[-3.0,1.0];sim.state.agents.person_00.heading=-90.0
	sim.state.agents.person_01.position=[-2.0,1.0];sim.state.agents.person_01.heading=90.0
	sim.state.agents.person_02.position=[3.0,2.0]
	return sim

func _ref(sim,id:String,target:String)->String:
	sim.observe(id)
	for ref in sim._refs[id]:
		if sim._refs[id][ref].id==target:return ref
	return ""

func _act(sim,id:String,action:Dictionary,minutes:float=0.1)->Dictionary:
	var accepted:Dictionary=sim.submit(id,action,int(sim.state.run_id))
	if not accepted.ok:return accepted
	sim.advance(minutes)
	return sim.state.agents[id].last_result

func _give(sim,id:String,kind:String)->Dictionary:
	return sim._new_item(kind,kind,sim.state.agents[id].position,id,id)

func _test_maps_and_persistence()->void:
	for map_id in ["closed_block","residence","research_station"]:
		var sim=Simulation.new();sim.reset(map_id,20,"scarcity",3)
		check(sim.state.agents.size()==20,"20 generic agents on "+map_id)
		for id in sim.state.agents:check(Spatial.walkable(Spatial.point(sim.state.agents[id]),sim.state.geometry,sim.state.agents,id),"valid initial body "+map_id+"/"+id)
		var archive:Dictionary=sim.export_state()
		var loaded=Simulation.new()
		check(loaded.import_state(archive),"valid release save loads "+map_id)
		var before:Dictionary=loaded.snapshot()
		archive.world.agents.person_00.body=[]
		check(not loaded.import_state(archive),"nested corrupt body rejected")
		check(loaded.snapshot()==before,"corrupt load transactional")
	check(not Catalog.validate({"type":"move_to","target":"v0","world_id":"secret"}).ok,"strict action rejects extra data")
	check(not Catalog.validate({"type":"move","forward":INF,"right":0}).ok,"nonfinite rejected")

func _test_physical_actions()->void:
	var sim=_fresh()
	var ration:Dictionary=sim._new_item("ration","ration",[-2.5,1.0])
	var first:=_ref(sim,"person_00",ration.id)
	var second:=_ref(sim,"person_01",ration.id)
	check(not first.is_empty() and not second.is_empty(),"contenders individually perceive same ration")
	sim.submit("person_01",{"type":"take","target":second});sim.submit("person_00",{"type":"take","target":first});sim.advance(0.1)
	check(sim.state.items[ration.id].holder=="person_00","stable priority ignores submission arrival order")
	check(sim.state.agents.person_00.inventory.count(ration.id)+sim.state.agents.person_01.inventory.count(ration.id)==1,"contested item unique")
	var actor:Dictionary=sim.state.agents.person_00
	actor.needs.hunger=75.0
	check(_act(sim,"person_00",{"type":"consume","slot":actor.inventory.find(ration.id)}).ok,"eat succeeds")
	check(actor.needs.hunger<40.0 and not sim.state.items.has(ration.id),"food consumed and hunger reduced")
	var old_run:=int(sim.state.run_id);sim.reset()
	check(not sim.submit("person_00",{"type":"wait"},old_run).ok,"old run cannot submit")
	sim=_fresh()
	var start:Array=sim.state.agents.person_00.position.duplicate()
	check(_act(sim,"person_00",{"type":"move","forward":0.0,"right":-1.0},0.2).ok,"relative plan accepted")
	check(sim.state.agents.person_00.position!=start,"logical plan moves authoritative body")
	sim.state.agents.person_00.body.blind=true
	check(sim.observe("person_00").targets.is_empty() and sim.observe("person_00").mock_view.is_empty(),"blind has no fresh targets")

func _test_combat_and_body()->void:
	var sim=_fresh();_give(sim,"person_00","knife")
	for hit in 5:
		var target:=_ref(sim,"person_00","person_01")
		check(_act(sim,"person_00",{"type":"attack","target":target},1.0).ok,"ordinary hit "+str(hit))
		check(is_equal_approx(float(sim.state.agents.person_01.health),maxf(0.0,100.0-float(hit+1)*20.0)),"exact ordinary damage")
	check(not sim.state.agents.person_01.alive,"fifth successful hit kills healthy awake victim")
	sim=_fresh();_give(sim,"person_00","knife");sim.state.agents.person_01.heading=-90.0
	check(_act(sim,"person_00",{"type":"attack","target":_ref(sim,"person_00","person_01")},1.0).ok,"awake rear hit possible")
	check(sim.state.agents.person_01.health==80.0,"awake rear attack is never instant kill")
	for helpless in ["sleeping","unconscious"]:
		sim=_fresh();_give(sim,"person_00","knife");sim.state.agents.person_01[helpless]=true
		check(_act(sim,"person_00",{"type":"attack","target":_ref(sim,"person_00","person_01")},0.1).ok,"helpless strike succeeds")
		check(not sim.state.agents.person_01.alive,"helpless strike kills in one")
	sim=_fresh();var actor:Dictionary=sim.state.agents.person_00
	actor.body.left_arm="broken";actor.body.right_arm="broken"
	var prior:Array=actor.position.duplicate();actor.body.left_leg="broken";actor.body.right_leg="broken"
	check(not _act(sim,"person_00",{"type":"move","forward":1.0,"right":0.0}).ok,"four broken limbs block movement")
	check(actor.position==prior and actor.inventory.is_empty(),"cannot hold items with two broken arms")
	sim=_fresh();actor=sim.state.agents.person_00;actor.health=40.0;var kit:=_give(sim,"person_00","medkit")
	check(_act(sim,"person_00",{"type":"treat","slot":actor.inventory.find(kit.id)}).ok and actor.health==60.0,"real medkit restores20 health")
	check(not sim.state.items.has(kit.id),"medkit actually consumed")
	var foundation:String=actor.profile.foundation
	check(sim.apply_memory_traits("person_00",["patient"]),"memory role secondary update accepted")
	check(actor.profile.foundation==foundation,"memory traits cannot change foundation")
	check(_act(sim,"person_00",{"type":"set_goal","text":"Найти аптечку"}).ok and actor.profile.goal=="Найти аптечку","agent can revise own current goal")

func _test_economy()->void:
	var sim=_fresh();var p:Array=sim.state.terminal.position
	sim.state.agents.person_00.position=[float(p[0])-1.0,float(p[1])];sim.state.agents.person_00.heading=-90.0
	var initial_stock:=int(sim.state.terminal.stock)
	check(_act(sim,"person_00",{"type":"request_ration"}).ok,"terminal issues personal ration")
	check(not _act(sim,"person_00",{"type":"request_ration"}).ok,"terminal blocks repeated daily ration")
	check(int(sim.state.terminal.stock)==initial_stock-1,"terminal stock decremented once")
	check(_act(sim,"person_00",{"type":"join_queue","kind":"camera"}).ok,"equipment queue works")
	check(sim.state.terminal.loans.size()==1,"real equipment loan recorded")
	check(not _act(sim,"person_00",{"type":"join_queue","kind":"phone"}).ok,"second loan blocked")
	var loan_key:String=sim.state.terminal.loans.keys()[0]
	check(_act(sim,"person_00",{"type":"return_device","slot":sim.state.agents.person_00.inventory.find(loan_key)}).ok,"physical loan return succeeds")
	check(sim.state.items[loan_key].container=="terminal" and sim.state.terminal.loans.is_empty(),"returned device back in real store")
	sim=_fresh();var item:=_give(sim,"person_00","ration")
	check(_act(sim,"person_00",{"type":"offer","target":_ref(sim,"person_00","person_01"),"slot":sim.state.agents.person_00.inventory.find(item.id),"request_tokens":3}).ok,"offer creation")
	var before_tokens:=int(sim.state.agents.person_00.tokens)+int(sim.state.agents.person_01.tokens)
	check(_act(sim,"person_01",{"type":"accept_offer","offer":"o0"}).ok,"atomic exchange")
	check(sim.state.items[item.id].holder=="person_01","trade moves actual item")
	check(int(sim.state.agents.person_00.tokens)+int(sim.state.agents.person_01.tokens)==before_tokens,"trade does not mint tokens")

func _open(sim,id:String,app:String)->void:
	_act(sim,id,{"type":"use_device","slot":0,"app":app})
	sim.device_screen(id)

func _test_network()->void:
	var sim=_fresh()
	_act(sim,"person_00",{"type":"interact","target":_ref(sim,"person_00","person_01")})
	_open(sim,"person_00","messages");_open(sim,"person_01","messages")
	check(_act(sim,"person_00",{"type":"send_message","contact":"c0","text":"Личный оригинал"}).ok,"send to known contact")
	var recipient:Dictionary=sim.state.agents.person_01
	check(not JSON.stringify(recipient.personal_results).contains("Личный оригинал"),"delivery is not reading")
	sim.device_screen("person_01")
	check(_act(sim,"person_01",{"type":"read_message","message":"m0"}).ok,"explicit read succeeds")
	var past:Array=recipient.personal_results.duplicate(true)
	_open(sim,"person_01","network")
	check(_act(sim,"person_01",{"type":"replace_message","message":"m0","text":"Подменённая версия"}).ok,"scoped admin replacement")
	check(JSON.stringify(past).contains("Личный оригинал") and not JSON.stringify(past).contains("Подменённая версия"),"old read experience immutable")
	check(_act(sim,"person_01",{"type":"read_message","message":"m0"}).ok,"new read sees new revision")
	check(JSON.stringify(recipient.personal_results).contains("Подменённая версия"),"new delivered content enters new personal experience")
	check(_act(sim,"person_01",{"type":"set_network","online":false}).ok,"network can be disabled")
	check(_act(sim,"person_01",{"type":"set_network","online":true}).ok,"authorized offline control can reenable")
	_open(sim,"person_00","forum")
	check(_act(sim,"person_00",{"type":"create_topic","title":"Правила","text":"Как делить пайки?"}).ok,"forum topic real")
	_open(sim,"person_01","forum")
	check(_act(sim,"person_01",{"type":"reply","topic":"t0","text":"По очереди."}).ok,"forum reply real")
	check(sim.state.network.topics.values()[0].posts.size()==2,"forum retains posts")
	_open(sim,"person_00","votes")
	check(_act(sim,"person_00",{"type":"create_vote","title":"Порядок","options":["Очередь","Случайно"],"minutes":1.0}).ok,"poll creation")
	sim.device_screen("person_00")
	check(_act(sim,"person_00",{"type":"vote","poll":"p0","option":0}).ok,"poll vote")
	_act(sim,"person_00",{"type":"vote","poll":"p0","option":0})
	check(sim.state.network.polls.values()[0].votes.size()==1,"one vote per account")
	sim.advance(2.0)
	check(sim.state.network.polls.values()[0].closed and int(sim.state.network.polls.values()[0].result)==0,"poll closes to actual majority")
	_open(sim,"person_00","pages")
	check(_act(sim,"person_00",{"type":"read_page","page":"page0"}).ok,"internal page read")
	_open(sim,"person_00","game");_open(sim,"person_01","game")
	check(_act(sim,"person_00",{"type":"play_game","contact":"c0","cell":0}).ok,"game first move")
	check(not _act(sim,"person_00",{"type":"play_game","cell":1}).ok,"cannot move twice")
	check(_act(sim,"person_01",{"type":"play_game","cell":3}).ok,"opponent turn")
	_act(sim,"person_00",{"type":"play_game","cell":1});_act(sim,"person_01",{"type":"play_game","cell":4});_act(sim,"person_00",{"type":"play_game","cell":2})
	check(sim.state.network.games.values()[0].finished,"game actually reaches win")
	world_group_test(sim)
	recipient.body.blind=true
	check(sim.device_screen("person_01").is_empty(),"blind cannot get device screen")
	check(not _act(sim,"person_01",{"type":"read_message","message":"m0"}).ok,"blind cannot bypass via read tool")

func world_group_test(sim)->void:
	sim._introduce("person_00","person_02")
	_open(sim,"person_00","messages")
	check(_act(sim,"person_00",{"type":"create_group","title":"Общие планы","members":["c0","c1"]}).ok,"group created onlyfrom known contacts")
	check(sim.state.network.groups.size()==1 and sim.state.network.groups.values()[0].members.size()==3,"explicit group membership")
	var count:int=sim.state.network.messages.size()
	check(_act(sim,"person_00",{"type":"send_message","contact":"g0","text":"Встретимся у терминала."}).ok,"group send")
	check(sim.state.network.messages.size()==count+2,"group fanout creates one deliveryperothermember")
	check(not JSON.stringify(sim.state.agents.person_02.personal_results).contains("Встретимся у терминала."),"group delivery doesnot force reading")
	_open(sim,"person_02","messages")
	check(_act(sim,"person_02",{"type":"read_message","message":"m0"}).ok,"groupmember explicitlyreads owncopy")
	check(_act(sim,"person_02",{"type":"leave_group","group":"g0"}).ok,"member canleave group")
	check(not _act(sim,"person_02",{"type":"send_message","contact":"g0","text":"После выхода"}).ok,"former member cannotpost througholdgroupref")
	var restored=Simulation.new()
	check(restored.import_state(sim.export_state()),"groupservice state persists withscopedrefs")

func _test_artifacts()->void:
	var sim=_fresh()
	check(_act(sim,"person_00",{"type":"write_diary","text":"Видел общий терминал."}).ok,"voluntary diary write")
	check(_act(sim,"person_00",{"type":"read_diary","slot":1}).ok,"physical diary read")
	check(_act(sim,"person_00",{"type":"take_photo","digital":false}).ok,"physical photo capture request")
	var artifact_id:String=sim.state.artifacts.keys()[0]
	check(sim.attach_photo("person_00",artifact_id,"test_fixture_hash"),"renderer attaches original frame reference")
	var photo_slot:int=sim.state.agents.person_00.inventory.size()-1
	check(_act(sim,"person_00",{"type":"view_photo","slot":photo_slot}).ok,"own physical photo can be viewed")
	check(_act(sim,"person_00",{"type":"copy_photo","slot":photo_slot}).ok,"photo copy")
	check(_act(sim,"person_00",{"type":"show_photo","slot":photo_slot,"target":_ref(sim,"person_00","person_01")}).ok,"photo shown to reachable person")
	var personal:String=JSON.stringify(sim.state.agents.person_01.personal_results)
	check(personal.contains("test_fixture_hash") and personal.contains("shown_artifact"),"shown photo grants image with correct source")
	_act(sim,"person_00",{"type":"destroy","slot":photo_slot})
	check(sim.state.artifacts.size()==2 and JSON.stringify(sim.state.agents.person_01.personal_results).contains("test_fixture_hash"),"destroying instance does not erase copy/memory")

func _test_release_regressions()->void:
	var sim=_fresh()
	var pristine:Dictionary=sim.export_state()
	for mutation in ["messages","queues","health","quantity","plan"]:
		var corrupt:Dictionary=pristine.duplicate(true)
		match mutation:
			"messages":corrupt.world.network.messages=[]
			"queues":corrupt.world.terminal.queues=[]
			"health":corrupt.world.agents.person_00.health=101.0
			"quantity":corrupt.world.items.values()[0].quantity=0
			"plan":corrupt.world.agents.person_00.busy={"type":"move_to","path":[[NAN,1.0]],"mode":"walk"}
		check(not sim.import_state(corrupt),"typed nested corrupt state rejected: "+mutation)
		check(sim.export_state()==pristine,"corrupt load preserves world: "+mutation)
	sim.state.agents.person_00.body.left_leg="injured";sim.state.agents.person_00.healing={"left_leg":float(sim.state.minute)+0.2};sim.state.agents.person_00.busy={}
	sim.advance(0.3)
	check(sim.state.agents.person_00.body.left_leg=="healthy","idle actor heals at logical deadline")
	# Container ownership, visibility and physical possession remain separate.
	sim=_fresh();sim.state.geometry.walls=[];sim.state.geometry.doors=[];sim.state.geometry.bounds=[-20.0,20.0,-20.0,20.0]
	sim.state.geometry.props=[{"id":"cabinet","kind":"wardrobe","center":[0.0,0.0],"size":[1.5,1.0],"height":1.8,"storage":true,"open":false,"locked":false,"blocking":true}]
	sim.state.agents.person_00.position=[0.0,1.3];sim.state.agents.person_00.heading=0.0
	sim.state.agents.person_01.position=[4.0,4.0];sim.state.agents.person_02.position=[-4.0,4.0]
	var ration:=_give(sim,"person_00","ration")
	check(_act(sim,"person_00",{"type":"open","target":_ref(sim,"person_00","cabinet")}).ok,"container opens through rules")
	check(_act(sim,"person_00",{"type":"put","slot":sim.state.agents.person_00.inventory.find(ration.id),"target":_ref(sim,"person_00","cabinet")}).ok,"item really placed in container")
	check(sim.state.items[ration.id].container=="cabinet" and sim.state.items[ration.id].holder=="","container and holder distinct")
	check(_act(sim,"person_00",{"type":"close","target":_ref(sim,"person_00","cabinet")}).ok,"container closes")
	check(_ref(sim,"person_00",ration.id).is_empty(),"closed container contents not enumerated")
	_act(sim,"person_00",{"type":"open","target":_ref(sim,"person_00","cabinet")})
	check(_act(sim,"person_00",{"type":"take","target":_ref(sim,"person_00",ration.id)}).ok,"open container permits actual retrieval")
	check(sim.state.items[ration.id].holder=="person_00" and sim.state.items[ration.id].container=="","retrieval clears container atomically")
	# Sleeping on a bed has a real occupied surface and safe exit, not a floor-only caption.
	sim.state.geometry.props=[{"id":"bed","kind":"bed","center":[0.0,0.0],"size":[1.2,2.2],"height":0.65,"blocking":true}]
	sim.state.agents.person_00.position=[1.4,0.0];sim.state.agents.person_00.heading=90.0
	check(_act(sim,"person_00",{"type":"interact","target":_ref(sim,"person_00","bed")}).ok,"bed can be occupied")
	check(sim.state.agents.person_00.sleeping and sim.state.agents.person_00.busy.bed=="bed","bed sleep lifecycle tracked")
	var restored=Simulation.new()
	check(restored.import_state(sim.export_state()),"valid occupied bed state reloads")
	_act(sim,"person_00",{"type":"sleep","minutes":5.0})
	check(sim.state.agents.person_00.busy.get("bed","")=="bed","continued sleep preserves bed capability")
	check(_act(sim,"person_00",{"type":"wake"}).ok,"safe bed exit")
	check(Spatial.walkable(Spatial.point(sim.state.agents.person_00),sim.state.geometry,sim.state.agents,"person_00"),"woken body physically valid")
	var counts:Array=[]
	for map_id in ["closed_block","residence","research_station"]:
		sim.reset(map_id,20,"scarcity",1);counts.append(sim.state.geometry.doors.size())
	check(counts==[12,8,6],"three authored map topologies differ")
	sim.reset("closed_block",3,"last_ration",1)
	check(int(sim.state.terminal.stock)==0 and int(sim.state.economy.shop_stock.ration)==0,"last-ration scenario closes alternative food sources")
	sim.reset("closed_block",3,"deception",1)
	check(sim.state.network.messages.size()==1 and sim.state.network.messages.values()[0].original_text!=sim.state.network.messages.values()[0].text,"deception has independently preserved original and delivered content")
	check(not JSON.stringify(sim.observe("person_00")).contains("Терминал выдаёт один паёк"),"unread original notification does not leak into recipient")
