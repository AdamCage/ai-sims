extends RefCounted

const Simulation = preload("res://scripts/simulation/world_simulation.gd")
const Runtime = preload("res://scripts/ai/agent_runtime.gd")
var failures: Array = []

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func run() -> Array:
	failures = []
	var sim = Simulation.new()
	var runtimes: Dictionary = {}
	for id in sim.snapshot().agents:
		var runtime = Runtime.new()
		runtime.configure(id, sim.snapshot().agents[id].profile)
		runtime.reset(int(sim.snapshot().run_id))
		runtimes[id] = runtime
	var initial: Dictionary = sim.snapshot()
	var original_item_count: int = initial.items.size()
	var movement_seen := false
	var take_seen := false
	var speech_seen := false
	for tick in 40:
		var actions: Dictionary = {}
		for id in runtimes:
			var observation: Dictionary = sim.observe(id)
			observation["memory"] = runtimes[id].get_memory()
			runtimes[id].remember(observation)
			var action: Dictionary = runtimes[id].decide_mock(observation)
			var parsed: Dictionary = runtimes[id].parse_response(JSON.stringify(action))
			check(parsed.ok, "Mock returned invalid intention at tick %d for %s" % [tick, id])
			actions[id] = parsed.action
		var events: Array = sim.step(actions, int(sim.snapshot().run_id))
		for event in events:
			if event.ok:
				movement_seen = movement_seen or event.type == "move"
				take_seen = take_seen or event.type == "take"
				speech_seen = speech_seen or event.type == "speak"
		var current: Dictionary = sim.snapshot()
		check(current.items.size() == original_item_count, "Resource count changed during integrated mock run")
		for item_id in current.items:
			var owners := 0
			for agent in current.agents.values():
				owners += agent.inventory.count(item_id)
			check(owners <= 1, "Item duplicated across inventories: " + str(item_id))
			check(owners == (0 if current.items[item_id].holder == "" else 1), "Holder/inventory disagreement")
	check(int(sim.snapshot().tick) == 40, "40 rounds must advance exactly 40 ticks")
	check(movement_seen, "Integrated mock episode must physically move characters")
	check(take_seen, "Integrated mock episode must take an item")
	check(speech_seen, "Integrated mock episode must produce actual speech events")
	var current: Dictionary = sim.snapshot()
	var replayed: Dictionary = sim.replay_to()
	check(JSON.stringify(replayed) == JSON.stringify(current), "Replay must reproduce integrated final state exactly")
	# Observer reads are inert: examining all agents must never change another prompt.
	var before: Dictionary = sim.observe("boris")
	var full: Dictionary = sim.snapshot()
	full.agents.ada.profile.foundation = "OBSERVER_SECRET_SENTINEL"
	var after: Dictionary = sim.observe("boris")
	check(JSON.stringify(before) == JSON.stringify(after), "Observer snapshot must be detached from authoritative state")
	# A request queued before reset cannot commit a late round.
	var stale_run: int = int(sim.snapshot().run_id)
	sim.reset()
	sim.step({"ada":{"type":"move","forward":1.0,"right":0.0}}, stale_run)
	check(int(sim.snapshot().tick) == 0, "Stale integrated round advanced reset world")
	for runtime in runtimes.values():
		runtime.free()
	return failures
