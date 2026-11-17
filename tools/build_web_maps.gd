extends SceneTree
const Maps=preload("res://scripts/game/map_catalog.gd")
func _initialize() -> void:
	var args:=OS.get_cmdline_user_args()
	if args.is_empty():quit(1);return
	DirAccess.make_dir_recursive_absolute(args[0])
	for spec in Maps.catalog():
		var state:Dictionary=Maps.create(str(spec.id),20,"episode",42)
		var file:=FileAccess.open(str(args[0]).path_join(str(spec.id)+".json"),FileAccess.WRITE)
		if file==null:quit(1);return
		file.store_string(JSON.stringify({"map_id":spec.id,"geometry":state.geometry}))
		file.close()
	print("WEB MAPS: 3 authored geometry packs ready")
	quit()
