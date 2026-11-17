extends SceneTree
## Deliberate paid, real-renderer acceptance. Ordinary suites never invoke this.
## Uses the SAME monotonic account ledger as the game; no key in argv or output.
const Game=preload("res://scripts/release_main.gd")
const Credentials=preload("res://scripts/release_storage/credential_store.gd")
const Repository=preload("res://scripts/release_storage/session_repository.gd")
const Ledger=preload("res://scripts/release_ai/usage_ledger.gd")
var game:Node
var report:Dictionary={"kind":"real_vlm_wall_clock_acceptance","completed":false,"maps":[],"failures":[],"started_utc":"","wall_seconds":0.0}
var started:int
var map_seconds:=1200
var party_size:=20
func _initialize()->void:run.call_deferred()
func run()->void:
	if not "--allow-paid" in OS.get_cmdline_user_args() or not "--test-profile" in OS.get_cmdline_user_args():
		printerr("Requires explicit --allow-paid and --test-profile");quit(2);return
	if DisplayServer.get_name()=="headless":printerr("Actual renderer required");quit(2);return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--agents="):party_size=clampi(int(argument.trim_prefix("--agents=")),3,20)
		if argument.begins_with("--map-seconds="):map_seconds=clampi(int(argument.trim_prefix("--map-seconds=")),30,3600)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DisplayServer.window_set_position(Vector2i(-5000,-5000));Engine.max_fps=30
	var key:String=Credentials.new().load_key()
	if key.is_empty():printerr("Local RouterAI credential missing");quit(2);return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test-output/live"))
	started=Time.get_ticks_msec();report.started_utc=Time.get_datetime_string_from_system(true)
	game=Game.new();root.add_child(game)
	game.ledger.release_storage_lease()
	game.ledger=Ledger.new()
	game._ledger_path="user://release_usage_ledger.json"
	game.settings.speed=1.0
	game.configure_provider({"enabled":true,"key":key,"remember":false,"budget":1000.0});key=""
	var preflight_deadline:=Time.get_ticks_msec()+60000
	while game._provider_pending and Time.get_ticks_msec()<preflight_deadline:await process_frame
	if game._quote.is_empty():report.failures.append("Provider preflight failed");finish();return
	report["provider"]=game._quote.get("provider_only",[])
	report["initial_ledger"]=game.ledger.status()
	for map_id in ["closed_block","residence","research_station"]:
		game.new_session({"map_id":map_id,"count":party_size,"scenario":"episode","seed":17})
		game.ui.show_main_menu(false)
		var entry:Dictionary={"map_id":map_id,"agents":party_size,"wall_seconds":0.0,"game_minutes":0.0,"round_ticks":0,"calls":0,"actions":{},"successful_actions":{},"errors":[],"clock_advanced_while_waiting":false,"moved_agents":0}
		var positions:Dictionary={}
		for id in game.simulation.state.agents:positions[id]=game.simulation.state.agents[id].position.duplicate()
		var map_start:=Time.get_ticks_msec();var cursor:=int(game.simulation.state.event_cursor)
		var last_flush:=0
		game._set_running(true)
		while Time.get_ticks_msec()-map_start<map_seconds*1000:
			await create_timer(0.5).timeout
			for packet in game._pending_decisions.values():
				if packet.get("phase")=="request" and float(game.simulation.state.minute)>float(packet.minute):
					entry.clock_advanced_while_waiting=true
			for event in game.simulation.state.events:
				if int(event.seq)<cursor:continue
				cursor=int(event.seq)+1
				var action:String=str(event.type)
				entry.actions[action]=int(entry.actions.get(action,0))+1
				if bool(event.get("ok",false)):entry.successful_actions[action]=int(entry.successful_actions.get(action,0))+1
			entry.wall_seconds=(Time.get_ticks_msec()-map_start)/1000.0
			entry.game_minutes=float(game.simulation.state.minute);entry.round_ticks=int(game.simulation.state.tick)
			entry.calls=0
			for runtime in game.runtimes.values():entry.calls+=int(runtime.debug().live_requests_started)
			if not game.running and not game.collecting and not game.advancing:
				var safe_errors:Array=[]
				for runtime in game.runtimes.values():
					var error:String=str(runtime.debug().last_error)
					if not error.is_empty():safe_errors.append(error.left(300))
				entry.errors.append({"at_wall_seconds":entry.wall_seconds,"errors":safe_errors})
				report.failures.append("Live AI paused: "+map_id);break
			if Time.get_ticks_msec()-last_flush>10000:
				last_flush=Time.get_ticks_msec();report["current_map"]=entry.duplicate(true);write_report()
		# Drain already-authorized requests, preserving their receipts and committed actions.
		game.running=false
		var drain_deadline:=Time.get_ticks_msec()+100000
		while (game.collecting or game.advancing) and Time.get_ticks_msec()<drain_deadline:await process_frame
		game._set_running(false)
		entry.wall_seconds=(Time.get_ticks_msec()-map_start)/1000.0
		for id in positions:
			if positions[id]!=game.simulation.state.agents[id].position:entry.moved_agents+=1
		entry["ledger"]=game.ledger.status()
		if entry.calls==0 or entry.moved_agents==0 or entry.successful_actions.is_empty():
			report.failures.append("No evidence of live play and movement: "+map_id)
		entry["blocked_agents"]=game._blocked_ai.size()
		game.save_slot(2,true)
		entry["save_loadable"]=not game.repository.load_slot(2).is_empty()
		var restored:Dictionary=game.repository.reconstruct(game.repository.sequence)
		entry["journal_restores_tick"]=int(restored.get("tick",-1))==int(game.simulation.state.tick)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://test-output/live/acceptance_"+map_id+".png")
		if not entry.journal_restores_tick or not entry.save_loadable:report.failures.append("Persistence failed: "+map_id)
		report.maps.append(entry);report.erase("current_map");write_report()
		print("LIVE MAP ",map_id," seconds=",entry.wall_seconds," calls=",entry.calls," ticks=",entry.round_ticks," moved=",entry.moved_agents," errors=",entry.errors.size())
		if not report.failures.is_empty():break
	finish()
func write_report()->void:
	report.wall_seconds=(Time.get_ticks_msec()-started)/1000.0
	if is_instance_valid(game):report["ledger"]=game.ledger.status()
	Repository.atomic_write("res://test-output/live/beta_acceptance.json",JSON.stringify(report,"\t"))
func finish()->void:
	report.completed=report.maps.size()==3 and report.failures.is_empty()
	report["one_hour_wall_clock"]=Time.get_ticks_msec()-started>=3600000
	write_report();print("LIVE ACCEPTANCE completed=",report.completed," wall_seconds=",report.wall_seconds," usage=",report.get("ledger",{}))
	quit(0 if report.completed else 1)
