extends "res://tools/play_log_base.gd"
## The play log · project-owned: edit freely.
##
## The PlayLog autoload, registered first under [autoload] in project.godot. tools/play_log_base.gd
## writes the files and the built-in lines; this file fills the hooks. RunState logs each trade and
## day, and starts the log's run; the shop screen names its view and its progress button (Next Day).


## Market Day has no settings yet.
func _session_extras() -> Dictionary:
	return {}


func _build_snapshot() -> Dictionary:
	return {"day": RunState.day, "gold": RunState.gold, "grain": RunState.grain, "price": RunState.price(),
		"can_buy": RunState.can_buy()}


func progress_block_reason() -> String:
	return "the market has closed" if RunState.is_over() else ""


## Market Day has no install id.
func _install_id() -> String:
	return ""
