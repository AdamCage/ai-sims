extends SceneTree
## Explicit paid acceptance smoke. Never run by ordinary/offline test runners.
const Sim=preload("res://scripts/game/session_simulation.gd")
const Runtime=preload("res://scripts/release_ai/agent_runtime.gd")
const World=preload("res://scripts/release_world/world_view.gd")
const Catalog=preload("res://scripts/release_ai/provider_catalog.gd")
const Ledger=preload("res://scripts/release_ai/usage_ledger.gd")
const Credentials=preload("res://scripts/release_storage/credential_store.gd")
var quote:Dictionary={}
var decision:Dictionary={}
var sim=Sim.new()
var runtime:Node
var world:Node3D
var ledger=Ledger.new()
var model:="~deepseek/deepseek-v4-flash-latest"
var provider_preference:=""
func _initialize()->void:
	run.call_deferred()
func run()->void:
	if not "--allow-paid" in OS.get_cmdline_user_args():printerr("Explicit --allow-paid is required");quit(2);return
	if DisplayServer.get_name()=="headless":printerr("Actual renderer required for visual acceptance");quit(2);return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS,true)
	DisplayServer.window_set_position(Vector2i(-5000,-5000))
	var key:String=Credentials.new().load_key()
	if key.is_empty():printerr("No local RouterAI credential configured");quit(2);return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test-output/live"))
	ledger.configure(1000.0,"user://release_usage_ledger.json",4)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--provider="):provider_preference=argument.trim_prefix("--provider=")
	var catalog=Catalog.new();root.add_child(catalog)
	catalog.quote_ready.connect(func(_tag,result):quote=result)
	var error:Error=catalog.request_quote(model,1,provider_preference)
	if error!=OK:printerr("Catalogue request could not start");quit(1);return
	var deadline:=Time.get_ticks_msec()+45000
	while quote.is_empty() and Time.get_ticks_msec()<deadline:await process_frame
	if not quote.get("ok",false):printerr("Catalogue verification failed: ",quote.get("error","timeout"));quit(1);return
	sim.reset("closed_block",3,"scarcity",17)
	world=World.new();root.add_child(world);world.setup(sim.snapshot())
	runtime=Runtime.new();root.add_child(runtime);runtime.configure("person_00",sim.state.agents.person_00.profile);runtime.reset(int(sim.state.run_id))
	var config:=quote.duplicate(true);config.merge({"enabled":true,"key":key,"model":model,"ledger":ledger},true);runtime.configure_provider(config);key=""
	runtime.decision_ready.connect(func(id,run_id,tick,action,diagnostic):decision={"id":id,"run_id":run_id,"tick":tick,"action":action,"diagnostic":diagnostic})
	for index in 30:await process_frame
	var observation:Dictionary=sim.observe("person_00")
	world.set_perception_candidates("person_00",sim.perception_candidates("person_00"));world.prepare_capture("person_00")
	await RenderingServer.frame_post_draw
	var image:Image=world.capture_agent("person_00")
	image.save_png("res://test-output/live/first_camera.png")
	var png:PackedByteArray=image.save_png_to_buffer()
	observation=world.enrich_observation("person_00",observation)
	var before:=Time.get_ticks_msec()
	runtime.request_decision(observation,png,int(sim.state.run_id))
	deadline=Time.get_ticks_msec()+90000
	while decision.is_empty() and Time.get_ticks_msec()<deadline:await process_frame
	var result:Dictionary={"ok":false,"quote":quote,"latency_ms":Time.get_ticks_msec()-before,"ledger":ledger.status(),"decision":decision,"actual_camera_bytes":png.size(),"engine":Engine.get_version_info().string}
	if not decision.is_empty() and bool(decision.diagnostic.get("ok",false)):
		result["submit"]=sim.submit("person_00",decision.action,int(sim.state.run_id));result["events"]=sim.advance(.2);result.ok=result.submit.ok
	var filename:="first_result"+("_"+provider_preference.validate_filename() if not provider_preference.is_empty() else "")+".json"
	var file:=FileAccess.open("res://test-output/live/"+filename,FileAccess.WRITE);file.store_string(JSON.stringify(result,"\t"));file.close()
	print("LIVE VLM ","PASS" if result.ok else "FAIL"," latency_ms=",result.latency_ms," action=",decision.get("action",{})," usage=",ledger.status())
	quit(0 if result.ok else 1)
