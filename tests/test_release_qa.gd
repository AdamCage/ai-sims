extends RefCounted
## Independent adversarial release checks. No renderer or paid provider calls.
const Simulation=preload("res://scripts/game/session_simulation.gd")
const Spatial=preload("res://scripts/game/spatial_rules.gd")
const Catalog=preload("res://scripts/game/action_catalog.gd")
const Memory=preload("res://scripts/release_ai/personal_memory.gd")
const Runtime=preload("res://scripts/release_ai/agent_runtime.gd")
const Repository=preload("res://scripts/release_storage/session_repository.gd")
var failures:Array=[]
var checks:=0

func check(ok:bool,message:String)->void:
	checks+=1
	if not ok:failures.append("Independent release QA: "+message)

func run()->Array:
	failures.clear();checks=0
	_test_maps()
	_test_combat()
	_test_resources_and_equipment()
	_test_messages_and_apps()
	_test_photographs()
	_test_healing_deadlines()
	_test_execution_body_and_rescue()
	_test_hostile_saved_state()
	print("Independent release QA: ",checks," checks; ",failures.size()," failures")
	return failures

func run_soak()->Array:
	# 24 SIMULATED hours per map, five-minute authoritative steps by default.
	# --soak-step=1 opts into one-minute observations/decisions. No provider.
	# This is deliberately not described as a 24-hour wall-clock endurance run.
	failures.clear();checks=0
	var reports:Array=[]
	var all_started:=Time.get_ticks_msec()
	var isolation:="user://release_qa_soak_"+str(Time.get_ticks_usec())
	var minutes_per_step:=5
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--soak-step="):minutes_per_step=clampi(int(argument.get_slice("=",1)),1,10)
	var total_steps:=1440/ minutes_per_step
	for map_id in ["closed_block","residence","research_station"]:
		var started:=Time.get_ticks_msec()
		var world=Simulation.new();world.reset(map_id,20,"sandbox",83)
		var actors:Dictionary={}
		for id in world.state.agents:
			var runtime=Runtime.new();runtime.configure(id,world.state.agents[id].profile)
			runtime.reset(int(world.state.run_id));actors[id]=runtime
		var delivery_counts:Dictionary={"delivered":0,"refused":0}
		var experience_hook:Callable=func(id:String,experience:Dictionary):
			delivery_counts.delivered+=1
			if not actors[id].observe_personal_event(experience,int(world.state.run_id)):delivery_counts.refused+=1
		world.personal_experience.connect(experience_hook)
		var repository=Repository.new()
		repository.session_root=isolation.path_join(map_id)
		repository.save_root=isolation.path_join("saves").path_join(map_id)
		repository.begin(world.snapshot())
		var peak_recent:=0;var peak_old:=0;var peak_episodes:=0;var peak_versions:=0
		var peak_events:=0;var network_calls:=0;var accepted:=0;var succeeded:=0
		var recent_window_valid:=true;var max_runtime_bytes:=0
		var first_invalid:="";var midpoint_bytes:=0
		var goal_foundations:Dictionary={}
		for id in actors:goal_foundations[id]=world.state.agents[id].profile.foundation
		for step in total_steps:
			for id in actors:
				var observation:Dictionary=world.observe(id)
				actors[id].observe(observation)
				if world.state.agents[id].alive and not world.state.agents[id].unconscious and not world.state.agents[id].sleeping and world.state.agents[id].busy.is_empty():
					var action:Dictionary=actors[id].decide_demo(observation)
					if world.submit(id,action,int(world.state.run_id)).ok:accepted+=1
			var events:Array=world.advance(float(minutes_per_step))
			for event in events:
				if event.get("ok",false):succeeded+=1
			repository.record(world.snapshot(),events)
			peak_events=maxi(peak_events,world.state.events.size())
			# Validate every hour and final state with independent import, including
			# physical positions, inventories, quantities, scoped apps and networks.
			if ((step+1)*minutes_per_step)%60==0:
				var staged=Simulation.new()
				if not staged.import_state(world.export_state()) and first_invalid.is_empty():first_invalid="hour "+str((step+1)*minutes_per_step/60)
				for id in actors:
					var memory:Dictionary=actors[id].memory_view()
					peak_recent=maxi(peak_recent,memory.recent.size());peak_old=maxi(peak_old,int(memory.pending_old_count))
					peak_episodes=maxi(peak_episodes,memory.episodes.size());peak_versions=maxi(peak_versions,memory.versions.size())
					if not memory.recent.is_empty():recent_window_valid=recent_window_valid and float(memory.recent[-1].minute)-float(memory.recent[0].minute)<=60.000001
			if step==total_steps/2-1:
				repository.flush();midpoint_bytes=_qa_file_size(repository.session_path.path_join("transitions.jsonl"))
		for id in actors:
			network_calls+=int(actors[id].debug().live_requests_started)
			check(actors[id].profile.foundation==goal_foundations[id],"24h soak foundation stays immutable: "+map_id+"/"+id)
			var exported:Dictionary=actors[id].export_state()
			max_runtime_bytes=maxi(max_runtime_bytes,JSON.stringify(exported).to_utf8_buffer().size())
			var copy=Runtime.new();copy.configure(id,actors[id].profile)
			check(copy.import_state(exported,int(world.state.run_id)),"24h soak subjective memory remains restorable: "+map_id+"/"+id)
			copy.free()
		repository.flush()
		var journal_bytes:=_qa_file_size(repository.session_path.path_join("transitions.jsonl"))
		var restored:Dictionary=repository.reconstruct(repository.sequence)
		var actual:Dictionary=world.snapshot()
		# Journals deliberately retain the recent event tail separately from diffs.
		var same_cursor:bool=restored.get("event_cursor")==actual.event_cursor
		restored.erase("events");actual.erase("events")
		check(is_equal_approx(float(world.state.minute),1440.0),"24h soak reaches full simulated day: "+map_id)
		check(first_invalid.is_empty(),"24h soak has valid hourly authoritative states: "+map_id+" "+first_invalid)
		check(world.state.agents.size()==20,"24h soak retains all 20 agent identities: "+map_id)
		check(peak_events<=500,"24h soak observer event tail stays bounded: "+map_id)
		check(peak_recent<=4096 and peak_old<8192 and recent_window_valid,"24h soak protected recent hour and consolidation backlog stay bounded: "+map_id)
		check(int(delivery_counts.delivered)>0,"24h soak exercises immediate personal-experience signal: "+map_id)
		check(int(delivery_counts.refused)==0,"24h soak retains every delivered heard/read experience without capacity loss: "+map_id)
		check(peak_episodes<=128 and peak_versions<=32,"24h soak subjective layers/version history stay bounded: "+map_id)
		check(network_calls==0,"24h offline soak makes zero paid/network model calls: "+map_id)
		var replay_difference:=_qa_difference(actual,restored)
		check(replay_difference.is_empty() and same_cursor,"24h soak journal reconstructs final authoritative world: "+map_id+" "+replay_difference)
		check(journal_bytes<1440*100000,"24h soak transition journal stays below 100KB per logical minute: "+map_id)
		check(midpoint_bytes>0 and journal_bytes-midpoint_bytes<midpoint_bytes*3,"24h soak journal growth remains linear rather than recursively copying history: "+map_id)
		var alive:=0
		for actor in world.state.agents.values():
			if actor.alive:alive+=1
		var session_bytes:=0
		for file_name in DirAccess.get_files_at(repository.session_path):session_bytes+=_qa_file_size(repository.session_path.path_join(file_name))
		reports.append({"map":map_id,"agents":20,"simulated_minutes":world.state.minute,"minutes_per_step":minutes_per_step,"wall_seconds":(Time.get_ticks_msec()-started)/1000.0,"alive_at_end":alive,"accepted_intents":accepted,"successful_events":succeeded,"personal_experiences_delivered":delivery_counts.delivered,"personal_experiences_refused":delivery_counts.refused,"max_recent_memory":peak_recent,"max_pending_old":peak_old,"max_episodes":peak_episodes,"max_versions":peak_versions,"max_runtime_serialized_bytes":max_runtime_bytes,"max_event_tail":peak_events,"journal_bytes":journal_bytes,"midpoint_journal_bytes":midpoint_bytes,"total_session_bytes":session_bytes,"checkpoints":repository.checkpoints.size(),"network_model_calls":network_calls,"session_path":ProjectSettings.globalize_path(repository.session_path)})
		print("SOAK MAP ",JSON.stringify(reports[-1]))
		world.personal_experience.disconnect(experience_hook)
		for runtime in actors.values():runtime.free()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test-output/release-ui-qa"))
	var report:=FileAccess.open("res://test-output/release-ui-qa/soak_report.json",FileAccess.WRITE)
	report.store_string(JSON.stringify({"kind":"offline_24_simulated_hours_per_map","wall_seconds":(Time.get_ticks_msec()-all_started)/1000.0,"maps":reports,"checks":checks,"failures":failures},"\t"));report.close()
	print("Independent 24 SIMULATED-hour soak: ",checks," checks; ",failures.size()," failures")
	return failures

func _qa_file_size(path:String)->int:
	var file:=FileAccess.open(path,FileAccess.READ)
	return file.get_length() if file!=null else 0

func run_gameplay_acceptance()->Array:
	# Separate from save/memory/state validity: demo agents must actually find
	# and consume existing food through the production rules, without god help.
	failures.clear();checks=0
	var reports:Array=[]
	for map_id in ["closed_block","residence","research_station"]:
		var world=Simulation.new();world.reset(map_id,20,"sandbox",83)
		var actors:Dictionary={}
		for id in world.state.agents:
			var runtime=Runtime.new();runtime.configure(id,world.state.agents[id].profile);runtime.reset(int(world.state.run_id));actors[id]=runtime
		var consumption:=0;var rations:=0;var door_openings:=0;var sleepers:=0;var turns:=0;var moves:=0
		for step in 288:
			for id in actors:
				var observation:Dictionary=world.observe(id)
				actors[id].observe(observation)
				var actor:Dictionary=world.state.agents[id]
				if actor.alive and not actor.unconscious and not actor.sleeping and actor.busy.is_empty():world.submit(id,actors[id].decide_demo(observation),int(world.state.run_id))
			for event in world.advance(5.0):
				if not event.ok:continue
				match str(event.type):
					"consume":consumption+=1
					"request_ration":rations+=1
					"open":door_openings+=1
					"sleep":sleepers+=1
					"turn":turns+=1
					"move","move_to":moves+=1
		check(consumption>0,"24h gameplay acceptance: twenty demo actors discover and consume existing supplies on "+map_id+" (actual consume events="+str(consumption)+")")
		var alive:=0
		for actor in world.state.agents.values():
			if actor.alive:alive+=1
		reports.append({"map":map_id,"agents":20,"simulated_minutes":world.state.minute,"minutes_per_step":5,"actual_consume_events":consumption,"ration_requests":rations,"door_openings":door_openings,"sleep_intentions":sleepers,"move_intentions":moves,"turn_intentions":turns,"alive_at_end":alive,"terminal_stock_at_end":world.state.terminal.stock,"shop_rations_at_end":world.state.economy.shop_stock.get("ration",0)})
		print("GAMEPLAY ACCEPTANCE ",JSON.stringify(reports[-1]))
		for runtime in actors.values():runtime.free()
	var report:=FileAccess.open("res://test-output/release-ui-qa/gameplay_report.json",FileAccess.WRITE)
	report.store_string(JSON.stringify({"kind":"offline_demo_24_simulated_hours_per_map","maps":reports,"checks":checks,"failures":failures},"\t"));report.close()
	return failures

func _qa_difference(expected:Variant,actual:Variant,path:String="world")->String:
	# JSON files restore numbers as doubles; type-sensitive dictionary equality
	# is not the semantic world contract. Compare numeric values recursively.
	if (expected is int or expected is float) and (actual is int or actual is float):
		return "" if is_equal_approx(float(expected),float(actual)) else path+" number "+str(expected)+" != "+str(actual)
	if expected is Dictionary and actual is Dictionary:
		if expected.size()!=actual.size():return path+" key count "+str(expected.size())+" != "+str(actual.size())
		for key in expected:
			if not actual.has(key):return path+" missing key "+str(key)
			var error:=_qa_difference(expected[key],actual[key],path+"."+str(key))
			if not error.is_empty():return error
		return ""
	if expected is Array and actual is Array:
		if expected.size()!=actual.size():return path+" length "+str(expected.size())+" != "+str(actual.size())
		for index in expected.size():
			var error:=_qa_difference(expected[index],actual[index],path+"["+str(index)+"]")
			if not error.is_empty():return error
		return ""
	return "" if expected==actual else path+" value "+str(expected).left(120)+" != "+str(actual).left(120)

func fixture():
	var world=Simulation.new();world.reset("closed_block",3,"sandbox",37)
	world.state.geometry.walls=[];world.state.geometry.doors=[];world.state.geometry.props=[];world.state.geometry.bounds=[-20.0,20.0,-20.0,20.0]
	world.state.agents.person_00.position=[0.0,1.0];world.state.agents.person_00.heading=0.0
	world.state.agents.person_01.position=[0.0,0.0];world.state.agents.person_01.heading=0.0
	world.state.agents.person_02.position=[4.0,4.0];world.state.agents.person_02.heading=0.0
	world.state.terminal.position=[0.0,0.0]
	return world

func act(world,id:String,action:Dictionary,minutes:float=.01)->Dictionary:
	var queued:Dictionary=world.submit(id,action,int(world.state.run_id))
	if not queued.ok:return {"ok":false,"message":queued.reason}
	world.advance(minutes)
	return world.state.agents[id].last_result.duplicate(true)

func ref_for(world,id:String,category:String,target:String)->String:
	world.observe(id)
	for ref in world._refs.get(id,{}):
		var link:Dictionary=world._refs[id][ref]
		if link.category==category and link.id==target:return str(ref)
	return ""

func spawn(world,id:String,kind:String)->String:
	var result:Dictionary=world.intervene("spawn_item",{"id":id,"kind":kind,"give":true})
	return str(result.get("details",{}).get("item",""))

func slot(world,id:String,item:String)->int:
	return world.state.agents[id].inventory.find(item)

func _test_maps()->void:
	for map_id in ["closed_block","residence","research_station"]:
		var world=Simulation.new();world.reset(map_id,20,"scarcity",13)
		check(world.state.agents.size()==20,"map supports twenty independent actors: "+map_id)
		var all_valid:=true
		for id in world.state.agents:
			all_valid=all_valid and Spatial.walkable(Spatial.point(world.state.agents[id]),world.state.geometry,world.state.agents,id)
		check(all_valid,"all twenty spawn bodies physically valid: "+map_id)
		var copy=Simulation.new()
		check(copy.import_state(world.export_state()),"map snapshot is restorable: "+map_id)

func _test_combat()->void:
	var world=fixture();spawn(world,"person_00","knife")
	for hit in range(1,6):
		var ref:=ref_for(world,"person_00","agent","person_01")
		check(not ref.is_empty(),"awake victim remains a visible target at hit%d"%hit)
		var result:=act(world,"person_00",{"type":"attack","target":ref},.9)
		check(result.ok,"ordinary hit%d is executed"%hit)
		check(is_equal_approx(float(world.state.agents.person_01.health),100.0-hit*20.0),"ordinary cold-weapon damage is exactly20 at hit%d"%hit)
		check(bool(world.state.agents.person_01.alive)==(hit<5),"awake rear attack requires fifth successful hit%d"%hit)
	for state_name in ["sleeping","unconscious"]:
		world=fixture();spawn(world,"person_00","knife");world.state.agents.person_01[state_name]=true
		var ref:=ref_for(world,"person_00","agent","person_01")
		act(world,"person_00",{"type":"attack","target":ref},.9)
		check(not world.state.agents.person_01.alive,"one hit kills only helpless state: "+state_name)
	world=fixture();spawn(world,"person_00","knife");world.state.agents.person_00.body.left_arm="broken";world.state.agents.person_00.body.right_arm="broken"
	var ref:=ref_for(world,"person_00","agent","person_01")
	check(not act(world,"person_00",{"type":"attack","target":ref}).ok,"both broken arms prevent armed attack")
	check(float(world.state.agents.person_01.health)==100.0,"failed body-guard attack changes no victim health")

func _test_resources_and_equipment()->void:
	var world=fixture();world.state.terminal.stock=1
	world.submit("person_01",{"type":"request_ration"});world.submit("person_00",{"type":"request_ration"});world.advance(.01)
	var count:=0
	for id in ["person_00","person_01"]:
		for item in world.state.agents[id].inventory:
			if world.state.items[item].kind=="ration":count+=1
	check(count==1 and int(world.state.terminal.stock)==0,"simultaneous ration requests conserve final stock")
	var winner:String="person_00" if world.state.agents.person_00.last_result.ok else "person_01"
	world.state.terminal.stock=1
	check(not act(world,winner,{"type":"request_ration"}).ok,"daily right cannot issue twice")
	world=fixture()
	var cameras:Array=[];var phones:Array=[]
	for item in world.state.items.values():
		if item.container=="terminal":
			if item.kind=="camera":cameras.append(item.id)
			if item.kind=="phone":phones.append(item.id)
			item.container="unavailable_fixture"
	check(act(world,"person_00",{"type":"join_queue","kind":"camera"}).ok,"actor joins camera queue while occupied")
	check(act(world,"person_00",{"type":"join_queue","kind":"phone"}).ok,"actor joins phone queue while occupied")
	if not cameras.is_empty() and not phones.is_empty():
		world.state.items[cameras[0]].container="terminal";world.state.items[phones[0]].container="terminal";world.advance(.01)
		var loans:=0
		for loan in world.state.terminal.loans.values():
			if loan.actor=="person_00":loans+=1
		check(loans==1,"automatic queue issuance rechecks existing common-equipment loan")
	else:check(false,"fixture found actual limited terminal equipment")
	check(Catalog.validate({"type":"buy","target":"v0","kind":"medkit"}).ok,"shop action can actually select non-ration stock")

func _test_messages_and_apps()->void:
	var world=fixture();world._introduce("person_00","person_01");world._introduce("person_01","person_00")
	act(world,"person_00",{"type":"use_device","slot":0,"app":"messages"})
	check(act(world,"person_00",{"type":"send_message","contact":"c0","text":"ORIGINAL_QA_MESSAGE"}).ok,"known-contact message is sent")
	var recipient_before:Dictionary=world.observe("person_01")
	check(not JSON.stringify(recipient_before.personal_results).contains("ORIGINAL_QA_MESSAGE"),"delivery alone does not put message body in experience")
	act(world,"person_01",{"type":"use_device","slot":0,"app":"messages"})
	var screen:Dictionary=world.device_screen("person_01")
	check(not str(screen.get("text","")).contains("ORIGINAL_QA_MESSAGE"),"unopened inbox shows envelope rather than body")
	check(act(world,"person_01",{"type":"read_message","message":"m0"}).ok,"scoped inbox message can be opened")
	var personal_before:Dictionary=world.observe("person_01")
	check(JSON.stringify(personal_before.personal_results).contains("ORIGINAL_QA_MESSAGE"),"explicit read creates received-message experience")
	check(act(world,"person_01",{"type":"replace_message","message":"m0","text":"ALTERED_QA_MESSAGE"}).ok,"authorized network account may replace server text")
	check(JSON.stringify(world.observe("person_01").personal_results).contains("ORIGINAL_QA_MESSAGE"),"replacement preserves already-read original experience")
	act(world,"person_01",{"type":"read_message","message":"m0"})
	check(JSON.stringify(world.observe("person_01").personal_results).contains("ALTERED_QA_MESSAGE"),"reread produces distinct changed experience")
	check(world.state.network.messages.values()[0].original_text=="ORIGINAL_QA_MESSAGE","observer trace keeps original text")
	world.state.agents.person_01.body.blind=true
	check(world.device_screen("person_01").is_empty(),"blindness blocks actual device screen")
	check(not act(world,"person_01",{"type":"read_message","message":"m0"}).ok,"blindness cannot bypass device through message API")
	world.state.agents.person_01.body.blind=false
	act(world,"person_00",{"type":"use_device","slot":0,"app":"forum"})
	check(act(world,"person_00",{"type":"create_topic","title":"QA Topic","text":"First post"}).ok,"forum topic really created")
	act(world,"person_01",{"type":"use_device","slot":0,"app":"forum"});world.device_screen("person_01")
	check(act(world,"person_01",{"type":"reply","topic":"t0","text":"Second post"}).ok,"scoped forum reply really appended")
	check(world.state.network.topics.values()[0].posts.size()==2,"forum persists both authors' posts")
	act(world,"person_00",{"type":"use_device","slot":0,"app":"votes"})
	act(world,"person_00",{"type":"create_vote","title":"Distribute supplies","options":["Equal","By need"],"minutes":2.0})
	world.device_screen("person_00");act(world,"person_00",{"type":"vote","poll":"p0","option":1})
	act(world,"person_01",{"type":"use_device","slot":0,"app":"votes"});world.device_screen("person_01");act(world,"person_01",{"type":"vote","poll":"p0","option":1})
	world.advance(3.0)
	var poll:Dictionary=world.state.network.polls.values()[0]
	check(poll.closed and int(poll.result)==1 and poll.advisory,"poll closes with a real advisory majority")
	act(world,"person_00",{"type":"use_device","slot":0,"app":"game"});act(world,"person_01",{"type":"use_device","slot":0,"app":"game"})
	check(act(world,"person_00",{"type":"play_game","contact":"c0"}).ok,"two-account game created")
	for move in [["person_00",0],["person_01",3],["person_00",1],["person_01",4],["person_00",2]]:
		check(act(world,str(move[0]),{"type":"play_game","cell":int(move[1])}).ok,"legal alternating game move accepted")
	var game:Dictionary=world.state.network.games.values()[0]
	check(game.finished and game.result==world.state.agents.person_00.name,"board rules produce winner after three in row")

func _test_photographs()->void:
	var world=fixture()
	var events:Array=[]
	world.submit("person_00",{"type":"take_photo","digital":true});events=world.advance(.2)
	check(world.state.artifacts.size()==1,"explicit photo action creates one artifact")
	var artifact:Dictionary=world.state.artifacts.values()[0]
	check(str(artifact.image_ref).is_empty(),"headless rules never fabricate image bytes/hash")
	check(events.any(func(e):return e.type=="photo_capture"),"photo capture event requests renderer at frozen execution state")
	var fake_hash:="a".repeat(64)
	check(world.attach_photo("person_00",artifact.id,fake_hash),"renderer attachment bridge accepts first media reference")
	check(not world.attach_photo("person_00",artifact.id,"b".repeat(64)),"original photo image cannot be overwritten")
	check(act(world,"person_00",{"type":"copy_photo","slot":0}).ok,"digital photo copy creates independent artifact")
	check(world.state.artifacts.size()==2,"copy is distinct from original instance")
	var ref:=ref_for(world,"person_00","agent","person_01")
	check(act(world,"person_00",{"type":"show_photo","slot":0,"target":ref}).ok,"photo shown without transferring phone")
	var experience:Dictionary=world.observe("person_01")
	check(Memory.has_image_grant(Memory.personal_context(experience),fake_hash),"shown photo grants actual image pixels to private runtime")
	var message_context:Dictionary=Memory.personal_context(experience)
	message_context.personal_results=[{"channel":"message","image_ref":fake_hash,"text":"Attachment","source":"received_message"}]
	check(Memory.has_image_grant(message_context,fake_hash),"read message attachment grants image to private runtime")
	check(Catalog.SCHEMAS.has("view_photo"),"gallery exposes explicit photo selection/view action")

func _test_healing_deadlines()->void:
	var world=fixture();var aid:=spawn(world,"person_00","splint")
	world.state.agents.person_00.body.left_leg="broken"
	check(act(world,"person_00",{"type":"treat","slot":slot(world,"person_00",aid),"limb":"left_leg"}).ok,"splint schedules actual recovery")
	world.advance(4.0)
	for step in 7:world.advance(60.0)
	check(world.state.agents.person_00.body.left_leg=="healthy","healing deadline applies even with no active plan")

func _test_hostile_saved_state()->void:
	var base=fixture();var before:Dictionary=base.snapshot()
	var mutations:Array=[
		["messages",[]], ["terminal_queues",[]], ["health",101.0], ["quantity",0]]
	for entry in mutations:
		var data:Dictionary=base.export_state()
		match str(entry[0]):
			"messages":data.world.network.messages=entry[1]
			"terminal_queues":data.world.terminal.queues=entry[1]
			"health":data.world.agents.person_00.health=entry[1]
			"quantity":data.world.items.phone_00.quantity=entry[1]
		check(not base.import_state(data),"hostile nested/range save rejected: "+str(entry[0]))
		# Compare without run_id because a buggy accepted import increments it.
		var after:Dictionary=base.snapshot();after.run_id=before.run_id
		check(after==before,"invalid import preserves live authority: "+str(entry[0]))
		base=fixture();before=base.snapshot()

func _test_execution_body_and_rescue()->void:
	var world=fixture()
	check(act(world,"person_00",{"type":"join_queue","kind":"camera"}).ok,"equipment issued before late injury fixture")
	var item_id:=""
	for item in world.state.agents.person_00.inventory:
		if world.state.terminal.loans.has(item):item_id=item;break
	if not item_id.is_empty():
		world.submit("person_00",{"type":"return_device","slot":slot(world,"person_00",item_id)})
		world.state.agents.person_00.body.left_arm="broken";world.state.agents.person_00.body.right_arm="broken"
		world.advance(.01)
		check(not world.state.agents.person_00.last_result.ok,"return device rechecks hands after queued intention")
		check(world.state.terminal.loans.has(item_id),"late hand injury cannot silently return held equipment")
	else:check(false,"issued real loan item available to fixture")
	world=fixture();world.state.agents.person_01.alive=false;world.state.agents.person_01.health=0.0;world.state.agents.person_01.busy={"type":"dead"}
	var ref:=ref_for(world,"person_00","agent","person_01")
	check(not act(world,"person_00",{"type":"help","target":ref}).ok,"medical support cannot claim success on a corpse")
	world=fixture();world.state.agents.person_01.body.left_leg="broken";world.state.agents.person_01.body.right_leg="broken"
	ref=ref_for(world,"person_00","agent","person_01")
	check(act(world,"person_00",{"type":"carry","target":ref}).ok,"rescuer actually starts carrying wounded actor")
	world.state.geometry.props.append({"id":"blocked_release_side","kind":"table","center":[.8,1.0],"size":[.5,.5],"height":.8,"blocking":true})
	act(world,"person_00",{"type":"release"})
	var actor:Dictionary=world.state.agents.person_01
	check(not str(actor.carried_by).is_empty() or Spatial.walkable(Spatial.point(actor),world.state.geometry,world.state.agents,"person_01"),"release selects a free side or preserves carrying instead of overlapping bodies")
