extends "res://tools/ui_catalog.gd"
## The screen catalog · project-owned: edit freely.
##
## Every screen the game has, and how to put it on screen in a representative state, for
## `bash tools/ui_capture.sh`. Add or update an entry whenever you add or change a view. The entry
## format, and reset(), open_view(), wait_frames() and focus_default(), are in tools/ui_catalog.gd.
## A setup builds its state through the game's public APIs and debug hooks, never player data, then
## returns the node to show, or opens the screen through the game's own navigation and returns null.

const SHOP_SCREEN: String = "res://scenes/shop_screen.tscn"


func screens() -> Array[Dictionary]:
	return [
		{"id": "shop", "title": "Shop screen", "scene": SHOP_SCREEN,
			"states": {"default": _shop, "closed": _shop_closed}},
	]


## Every capture starts the same run: a fixed seed gives the same prices.
func reset() -> void:
	RunState.start_run(1)


func _shop() -> Node:
	return open_view(SHOP_SCREEN)


## The market has closed: the last day has passed.
func _shop_closed() -> Node:
	while not RunState.is_over():
		RunState.next_day()
	return open_view(SHOP_SCREEN)
