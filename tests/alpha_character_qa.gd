extends SceneTree
const Stage=preload("res://scripts/release_world/character_portrait.gd")
var failures:Array=[]
func _initialize()->void:run.call_deferred()
func frames(count:int=5)->void:
	for frame in count:await process_frame
	await RenderingServer.frame_post_draw
func check(ok:bool,text:String)->void:
	print(("PASS " if ok else "FAIL ")+text)
	if not ok:failures.append(text)
func run()->void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test-output/alpha-characters"))
	for face in [0,1]:
		for outfit in 4:
			var stage=Stage.new();root.add_child(stage)
			var data:Dictionary={"color":["9fcbb5","ca927c","618ba5","e6e2d8"][outfit],"appearance":{"face":face,"hair":outfit+2,"shoes":outfit%2,"outfit":outfit,"height":1,"build":1,"skin":"dfb89e","hair_color":"49382f"}}
			stage.update_appearance(data);await frames(8)
			var garments:Array=stage.model.find_children("Clothing_Shirt_*","MeshInstance3D",true,false).filter(func(mesh):return mesh.visible)
			check(garments.size()==1,"One selected garment body="+str(face)+" outfit="+str(outfit))
			var hairs:Array=stage.model.find_children("Hair_*","MeshInstance3D",true,false).filter(func(mesh):return mesh.visible)
			check(hairs.size()==1,"One selected hairstyle index="+str(outfit+2))
			stage.viewport.get_texture().get_image().save_png("res://test-output/alpha-characters/body_%d_outfit_%d.png"%[face,outfit])
			if outfit==0:
				stage.set_headshot(true);stage.update_appearance(data);await frames();stage.viewport.get_texture().get_image().save_png("res://test-output/alpha-characters/portrait_%d.png"%face)
			stage.queue_free();await process_frame
	print("ALPHA_CHARACTERS failures=",failures.size());quit(1 if not failures.is_empty() else 0)
