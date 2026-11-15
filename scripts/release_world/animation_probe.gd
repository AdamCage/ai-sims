extends SceneTree
const Maps=preload("res://scripts/game/map_catalog.gd")
const World=preload("res://scripts/release_world/world_view.gd")
const UI=preload("res://scripts/release_ui/observer_ui.gd")
func _initialize()->void:_run.call_deferred()
func _run()->void:
	var state:Dictionary=Maps.create("closed_block",3,"scarcity",1)
	var world=World.new();root.add_child(world);world.setup(state)
	for mesh in world._models.person_00.find_children("*","MeshInstance3D",true,false):
		if str(mesh.name).to_lower().contains("hair"):print("HAIR PROBE ",mesh.name," visible=",mesh.visible," bounds=",mesh.get_aabb())
	var ui=UI.new();root.add_child(ui);ui.setup(world);ui.show_main_menu(false);ui.refresh(state,{},{})
	for phase in 6:
		await create_timer(0.4).timeout
		if phase==2:ui._open_appearance()
		var player:AnimationPlayer=world._players.person_00
		var skeletons=world._models.person_00.find_children("*","Skeleton3D",true,false)
		var bones:Array=[]
		if not skeletons.is_empty():
			var skeleton:Skeleton3D=skeletons[0]
			for index in skeleton.get_bone_count():
				if skeleton.get_bone_name(index).to_lower().contains("upperarm") or skeleton.get_bone_name(index).to_lower().contains("arm_l"):bones.append([skeleton.get_bone_name(index),str(skeleton.get_bone_pose_rotation(index))])
		print("PROBE ",phase," key=",world._animation_keys.get("person_00")," playing=",player.is_playing()," clip=",player.current_animation," at=",player.current_animation_position," bones=",bones," treepaused=",paused)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test-output/release-ui/probe.png")
	quit()
