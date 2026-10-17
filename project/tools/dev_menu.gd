extends "res://tools/dev_menu_base.gd"
## The dev menu · project-owned: edit freely.
##
## Only when the director wants a dev menu (AGENTS.md › Project rules, `Dev menu:`), register it
## last under [autoload] in project.godot, so the systems below exist when it starts:
##     DevMenu="*res://tools/dev_menu.gd"
## tools/dev_menu_base.gd builds the overlay: one tab per registered system, its actions as buttons,
## an inspector for its values, and a Log tab with the play log's tail. This file says how it is
## enabled and which systems it shows.
## - Actions: a system's `debug_*` methods (`func debug_add_gold(amount: int) -> void`) and the public
##   methods named in register_system's third argument.
## - Inspector: a `debug_inspect() -> Dictionary` on the system (the values only code can see, such
##   as a price it would charge or a roll it holds), then its @export values.
## The rules' "Agent-visible state": a value an assistant needs to judge a feature goes in a system's
## debug_inspect() and in PlayLog's snapshot.


func _init() -> void:
	## PLACEHOLDER: the director's answer. Any of "in_game" (the key works in debug builds),
	## "setting" (any build, when `debug/dev_menu=true` is under [debug] in project.godot or
	## setting_enabled() below is true) and "flag" (any build started with `-- --dev-menu`).
	enabled_by = [MODE_IN_GAME]
	toggle_key = KEY_F12


func _ready() -> void:
	super()
	## PLACEHOLDER: one tab per system, such as:
	##     register_system("Run", RunState, ["buy", "next_day"])
	## Register what the game owns: its autoloads and systems, each through its public methods and
	## its debug_* hooks.


## PLACEHOLDER: whether the game's own Settings turn the dev menu on, for the "setting" mode, such
## as `return Settings.dev_menu`.
func setting_enabled() -> bool:
	return false
