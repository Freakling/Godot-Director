extends "res://tools/dev_menu_base.gd"
## The dev menu · project-owned: edit freely.
##
## The DevMenu autoload, registered last under [autoload] in project.godot. tools/dev_menu_base.gd
## builds the overlay. Market Day's director chose "in game": F12 in debug builds (AGENTS.md ›
## Project rules). One tab shows the run: Buy, Sell and Next Day, RunState's debug_* hooks, and what
## its debug_inspect() reports.


func _init() -> void:
	enabled_by = [MODE_IN_GAME]
	toggle_key = KEY_F12


func _ready() -> void:
	super()
	register_system("Run", RunState, ["buy", "sell", "next_day"])
