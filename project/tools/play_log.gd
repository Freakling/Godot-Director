extends "res://tools/play_log_base.gd"
## The play log · project-owned: edit freely.
##
## The PlayLog autoload, registered first under [autoload] in project.godot:
##     PlayLog="*res://tools/play_log.gd"
## tools/play_log_base.gd writes the files (user://logs/play/run-<datetime>.log and .jsonl), the
## session header, engine errors, input actions, focus, hitches and the progress button's state, and
## scrubs every line. This file fills the hooks. Then wire the game to it:
## - a new run: `var id: String = PlayLog.begin_run()`, and keep the id in the run save; a loaded
##   save: `PlayLog.continue_run(id)`. Until one of them, lines are held and stamped T-.
## - each turn: `PlayLog.set_turn(turn)`, and `PlayLog.log_snapshot()` wherever the player may act.
## - every player action and every turn step's outcome: one line with a stable event id, from the
##   system that does it, such as `PlayLog.log_event("gold", "gold.spent", "hired Ada: -40", {"amount": 40})`.
## - the shell: `PlayLog.watch_views(self)` for its view_changed(name) signal, and
##   `PlayLog.watch_progress_button(%EndTurn)`.
## A test asserts on the lines through PlayLog.start_capture() and stop_capture().


func _init() -> void:
	keep_files = 20   ## PLACEHOLDER: how many runs' logs to keep
	hitch_threshold_ms = 250   ## PLACEHOLDER: a frame slower than this is logged as a hitch


## PLACEHOLDER: what the session header adds, such as {"settings": Settings.to_dict(),
## "failsafe": false}. Settings named like a secret (token, password, install_id...) are left out.
func _session_extras() -> Dictionary:
	return {}


## PLACEHOLDER: the state at a point the player may act: resources, what is queued, available and
## blocking. Plain data, kept small.
func _build_snapshot() -> Dictionary:
	return {}


## PLACEHOLDER: why the player can't continue right now (End Turn, Next Day), or "" when they can.
func progress_block_reason() -> String:
	return ""


## PLACEHOLDER: the game's install id, if it has one (a per-install UUID in its settings, say), so the
## base scrubs it from every line.
func _install_id() -> String:
	return ""
