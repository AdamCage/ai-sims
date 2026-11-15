extends SceneTree
## Offline camera check for physical service signage; no runtime/provider instance.
const Simulation=preload("res://scripts/game/session_simulation.gd")
const World=preload("res://scripts/release_world/world_view.gd")
const Spatial=preload("res://scripts/game/spatial_rules.gd")
func _initialize()->void:_run.call_deferred()
func _run()->void:
	var sim=Simulation.new();sim.reset("closed_block",3,"deception",17)
	var terminal:Array=sim.state.terminal.position
	var actor:Dictionary=sim.state.agents.person_00
	for degrees in range(0,360,15):
		var offset:Vector2=Vector2.from_angle(deg_to_rad(float(degrees)))*1.3
		var candidate:Vector2=Vector2(float(terminal[0]),float(terminal[1]))+offset
		if not Spatial.walkable(candidate,sim.state.geometry,sim.state.agents,"person_00"):continue
		if not Spatial.clear_line(candidate,Vector2(float(terminal[0]),float(terminal[1])),sim.state.geometry,0.0,"supply_terminal",true):continue
		actor.position=[candidate.x,candidate.y];actor.heading=rad_to_deg(atan2(offset.x,offset.y));actor.surface_height=0.0;break
	var world=World.new();root.add_child(world);world.setup(sim.snapshot());world.select_agent("person_00")
	for frame in 6:await process_frame
	world.prepare_capture("person_00");await RenderingServer.frame_post_draw
	world.capture_agent("person_00").save_png("res://test-output/release-ui/terminal_physical_sign.png")
	var labels:Array=world.find_children("PrintedServiceName","Label3D",true,false)
	var valid:bool=labels.size()>=4
	for label in labels:valid=valid and label.layers==1 and not label.no_depth_test and label.billboard==BaseMaterial3D.BILLBOARD_DISABLED
	print("PHYSICAL SERVICE SIGN ","PASS" if valid else "FAIL"," · ",labels.size()," depth-tested world plates; zero provider instances")
	quit(0 if valid else 1)
