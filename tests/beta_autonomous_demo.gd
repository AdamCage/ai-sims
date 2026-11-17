extends SceneTree
## Eight independent offline policies. Only personal observations enter each decision.
const Simulation=preload("res://scripts/game/session_simulation.gd")
const Runtime=preload("res://scripts/release_ai/agent_runtime.gd")

func _initialize()->void:
	var failed:=false
	for map_id in ["closed_block","residence","research_station"]:
		var args:=OS.get_cmdline_user_args()
		if not args.is_empty() and args[0]!="all" and args[0]!=map_id:continue
		var seed_value:=42
		for arg in args:
			if arg.begins_with("--seed="):seed_value=int(arg.trim_prefix("--seed="))
		if not play(map_id,"--intervene" in args,seed_value,"en" if "--en" in args else "ru"):failed=true
	quit(1 if failed else 0)

func play(map_id:String,intervention:bool,seed_value:int,language:String)->bool:
	var simulation:=Simulation.new()
	simulation.reset(map_id,8,"episode",seed_value)
	var policies:Dictionary={}
	for actor in simulation.state.agents.values():
		var policy:=Runtime.new()
		policy.demo_language=language
		policy.configure(actor.id,actor.profile)
		policy.reset(simulation.state.run_id)
		policies[actor.id]=policy
	var localized:=true
	var kinds:Dictionary={}
	var refused:Dictionary={}
	var first_actions:Array=[]
	var first_rooms:Dictionary={}
	var private_state_saved:=true
	while not simulation.state.scenario_state.completed:
		for id in policies:
			var actor:Dictionary=simulation.state.agents[id]
			if not actor.alive or actor.unconscious or actor.sleeping or not actor.busy.is_empty():continue
			var observation:=simulation.observe(id)
			var refs:=simulation.capture_observation_refs(id)
			var plan:Dictionary=policies[id].decide_demo(observation)
			var accepted:=simulation.submit_observed(id,plan,refs,simulation.state.run_id,simulation.state.minute)
			if not accepted.ok:refused[accepted.reason]=int(refused.get(accepted.reason,0))+1
		for event in simulation.advance(3.0):
			if event.ok:
				if event.type=="speak":
					var line:String=str(simulation.state.agents[event.actor].last_action.text)
					var ru:=false
					for i in line.length():
						if line.unicode_at(i)>=0x410 and line.unicode_at(i)<=0x44f:ru=true;break
					if ru!=(language=="ru"):localized=false
				kinds[event.type]=int(kinds.get(event.type,0))+1
				if event.type=="plan_completed" and event.actor=="person_00":first_rooms[event.place.id]=true
				if event.type in ["give","help","read_screen","buy","request_ration","transfer_tokens","consume","interact","speak"] and first_actions.size()<8:first_actions.append("%s %s"%[event.actor,event.type])
			else:refused[event.message]=int(refused.get(event.message,0))+1
		if simulation.state.minute==360:
			for id in policies:
				var restored:=Runtime.new()
				restored.configure(id,simulation.state.agents[id].profile)
				if not restored.import_state(policies[id].export_state(),simulation.state.run_id):private_state_saved=false
				restored.free()
		if intervention and simulation.state.minute==240:
			for card in ["reserve","policy"]:simulation.intervene("episode_intervention",{"intervention":card})
	var story:Dictionary=simulation.state.scenario_state
	print("AUTONOMOUS ",map_id," ",JSON.stringify({"outcome":story.outcome.id,"localized":localized,"seed":seed_value,"midday_private_save":private_state_saved,"metrics":story.metrics,"actions":kinds,"blocked":refused,"first":first_actions,"visited_by_first":first_rooms.keys()}))
	for policy in policies.values():policy.free()
	return localized and private_state_saved and story.completed and kinds.get("follow_route",0)>0 and kinds.get("speak",0)>0 and story.metrics.food_consumed.size()>=4 and int(story.metrics.interventions)==(2 if intervention else 0)
