extends SceneTree
const Repository=preload("res://scripts/release_storage/session_repository.gd")
const Simulation=preload("res://scripts/game/session_simulation.gd")
var failures:=0
func check(value:bool,label:String)->void:
	if not value:failures+=1;printerr("FAIL ",label)
	else:print("PASS ",label)
func _initialize()->void:
	var sim=Simulation.new()
	sim.reset("residence",8,"episode",12)
	var repo=Repository.new()
	repo.save_root="user://release_test_profile/replay_beta"
	repo.session_root=repo.save_root
	repo.begin(sim.snapshot())
	var frames:Array=[sim.snapshot()]
	for index in 8:
		var cursor:int=sim.state.event_cursor
		sim.advance(1.0)
		var events:=Array(sim.state.events).filter(func(e):return int(e.seq)>=cursor)
		repo.record(sim.snapshot(),events)
		frames.append(sim.snapshot())
	check(repo.save_slot(1,{"world":sim.export_state()})==OK,"save portable replay")
	var saved:Dictionary=repo.load_slot(1).data
	var loaded=Simulation.new()
	check(loaded.import_state(saved.world),"valid saved world")
	var fresh=Repository.new()
	fresh.save_root=repo.save_root;fresh.session_root=repo.session_root
	check(fresh.resume_from_slot(loaded.snapshot(),saved.replay),"restore archived transitions and checkpoint indexes")
	if fresh.sequence>0:
		for index in [0,2,5,8]:
			check(fresh.reconstruct(index)==JSON.parse_string(JSON.stringify(frames[index])),"exact frame %s"%index)
		var broken:Dictionary=saved.replay.duplicate(true);broken.sequence=999999
		var previous:String=fresh.session_path
		check(not fresh.resume_from_slot(loaded.snapshot(),broken) and previous==fresh.session_path,"damaged replay preserves active journal")
		loaded.advance(0.5);fresh.record(loaded.snapshot())
		check(fresh.sequence>8,"resume appends to old timeline")
		check(fresh.save_slot(2,{"world":loaded.export_state()})==OK,"continued branch remains portable")
	print("BETA REPLAY FAILURES: ",failures)
	quit(1 if failures else 0)
