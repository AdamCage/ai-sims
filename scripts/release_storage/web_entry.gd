extends Node
## Browser main scene. Release templates need an actual scene entry point.
func _ready() -> void:
	if not preload("res://scripts/release_storage/web_bridge.gd").has_lease():
		push_error("This game is already running in another tab.")
		return
	if not ProjectSettings.load_resource_pack("/packs/shared.pck", false):
		push_error("Shared game content could not be mounted.")
		return
	if not ResourceLoader.exists("res://assets/release/characters/human_female.glb"):
		push_error("This version is missing the character pack.")
		return
	get_tree().change_scene_to_file.call_deferred("res://scenes/release.tscn")
