extends SceneTree
## Standalone visual QA of release presentation; does not call any model.
const Simulation=preload("res://scripts/game/session_simulation.gd")
const World=preload("res://scripts/release_world/world_view.gd")
const UI=preload("res://scripts/release_ui/observer_ui.gd")
var world: Node3D
var ui: CanvasLayer
func _initialize()->void:
	_run.call_deferred()
func _run()->void:
	var sim=Simulation.new();sim.reset("closed_block",7,"scarcity",1)
	var state: Dictionary=sim.snapshot()
	world=World.new();root.add_child(world);world.setup(state)
	ui=UI.new();root.add_child(ui);ui.setup(world);ui.show_main_menu(false);ui.refresh(state,{},{} )
	for index in 6:await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test-output/release-ui"))
	root.get_texture().get_image().save_png("res://test-output/release-ui/world.png")
	world.prepare_capture(world.selected_agent)
	await RenderingServer.frame_post_draw
	world.capture_agent(world.selected_agent).save_png("res://test-output/release-ui/eyes.png")
	ui.show_main_menu(true)
	for index in 5:await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test-output/release-ui/menu.png")
	ui.show_settings()
	for index in 5:await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test-output/release-ui/settings.png")
	ui._settings_popup.hide();ui.show_main_menu(false)
	world.freeze_presentation(true);world.prepare_capture(world.selected_agent)
	await RenderingServer.frame_post_draw
	var before_pixels:PackedByteArray=world.capture_agent(world.selected_agent).get_data()
	ui._open_appearance()
	for index in 5:await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test-output/release-ui/appearance.png")
	ui._appearance_controls.skin.color=Color("80533e")
	ui._appearance_controls.outfit.select(2)
	ui._appearance_controls.hair.select(3)
	ui._appearance_controls.face.select(5)
	ui._update_character_preview()
	for index in 8:await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test-output/release-ui/appearance_variant.png")
	world.prepare_capture(world.selected_agent)
	await RenderingServer.frame_post_draw
	print("PREVIEW_ISOLATION ","PASS" if before_pixels==world.capture_agent(world.selected_agent).get_data() and world._state.agents[world.selected_agent].appearance==state.agents[world.selected_agent].appearance else "FAIL")
	ui._appearance_popup.hide();world.suspend_character_preview()
	sim._introduce("person_00","person_01");sim._introduce("person_01","person_00")
	sim.observe("person_00");sim.submit("person_00",{"type":"use_device","slot":0,"app":"messages"},int(sim.state.run_id));sim.advance(0.2)
	var screen:Dictionary=sim.device_screen("person_00")
	if not screen.get("contacts",[]).is_empty():
		sim.submit("person_00",{"type":"send_message","contact":screen.contacts[0].ref,"text":"Встретимся в общей комнате. Нужно обсудить запасы."},int(sim.state.run_id));sim.advance(0.2)
	world.sync_state(sim.snapshot(),true);ui.refresh(sim.snapshot(),{}, {"selected":"person_00","observations":{"person_00":sim.observe("person_00")},"device_screens":{"person_00":sim.device_screen("person_00")}})
	ui._show_phone()
	for index in 5:await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test-output/release-ui/phone.png")
	print("RELEASE PRESENTATION PREVIEW COMPLETE")
	quit()
