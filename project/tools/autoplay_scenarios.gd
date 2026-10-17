extends "res://tools/autoplay_catalog.gd"
## The autoplay scenarios · project-owned: edit freely.
##
## How `bash tools/autoplay.sh <scenario>` plays the game: a required smoke scenario, scripted ones
## (ordered actions with an expect after each) and strategy ones (random, greedy or end_turn). The
## scenario format and the thresholds (softlock_actions, step_seconds, orphan_turns...) are in
## tools/autoplay_catalog.gd; set a threshold in _init() to change it. Any item that touches the
## shell, a view, the turn loop or a save adds or updates a scenario step that walks the change.
##
## Examples:
##	{"id": "first_hire", "title": "Hire, then end five turns", "kind": "scripted", "actions": [
##		{"do": "hire_first", "expect": {"roster": 1}},
##		{"do": "end_turn", "repeat": 5, "expect": func(state: Dictionary) -> bool: return int(state["turn"]) == 6},
##	]},
##	{"id": "wander", "title": "Random play", "kind": "strategy", "strategy": "random", "steps": 200,
##		"weights": {"end_turn": 0.2}},


func scenarios() -> Array[Dictionary]:
	return [
		# Required: start a run, open every view tools/ui_screens.gd lists through the shell, and play
		# a few turns. PLACEHOLDER: the turns, and skip_views for a view a run can't reach from its start.
		{"id": "smoke", "title": "Start, open every view, play 3 turns", "kind": "smoke", "turns": 3},
	]
