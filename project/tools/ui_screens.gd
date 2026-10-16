extends "res://tools/ui_catalog.gd"
## The screen catalog · project-owned: edit freely.
##
## Every screen the game has, and how to put it on screen in a representative state, for
## `bash tools/ui_capture.sh`. Add or update an entry whenever you add or change a view. The entry
## format, and reset(), open_view(), wait_frames() and focus_default(), are in tools/ui_catalog.gd.
## A setup builds its state through the game's public APIs and debug hooks, never player data, then
## returns the node to show, or opens the screen through the game's own navigation and returns null.
##
## Example:
##	{"id": "hero_room", "title": "Hero room", "scene": "res://scenes/shell/HeroRoomView.tscn",
##		"states": {"default": _hero_room, "exhausted": _hero_room_exhausted}},


func screens() -> Array[Dictionary]:
	# Until the game lists its screens: the main scene, as it opens.
	var main_scene: String = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene.is_empty():
		return []
	return [
		{"id": "main", "title": "Main scene", "scene": main_scene},
	]
