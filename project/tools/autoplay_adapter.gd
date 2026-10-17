extends "res://tools/autoplay_adapter_base.gd"
## The autoplay adapter · project-owned: edit freely.
##
## How `bash tools/autoplay.sh` plays this game: tools/autoplay.gd talks to the game only through this
## file. The action format, and tree, views, play_log(), node(), unique() and wait_frames(), are in
## tools/autoplay_adapter_base.gd. Every player action appears in list_actions() while it's legal,
## with a ui route (rules.md › Every action is drivable). While start_run() below still calls super(),
## autoplay skips the run and says what to wire; the check passes meanwhile.
##
## Example actions:
##	{"id": "end_turn", "label": "End turn", "kind": "ui", "node": "%EndTurn", "progress": true}
##	{"id": "open_roster", "label": "Roster", "kind": "ui", "input": "open_roster", "opens": "roster"}
##	{"id": "close", "label": "Close", "kind": "ui", "node": "%Close", "back": true}
##	{"id": "hire_first", "label": "Hire the first applicant", "kind": "api"}


## PLACEHOLDER: start a new run with this seed, as New Game does (the run's RandomNumberGenerator
## takes the seed: rules.md › Seeded randomness), and wait until the player may act. Such as
## `node("/root/Run").call("start_run", run_seed)` or pressing %NewGame, then `await wait_frames(2)`.
## Replace the super() call with the real start: it is what marks this adapter as not filled in yet.
func start_run(run_seed: int) -> void:
	super(run_seed)


## PLACEHOLDER: load a run from a save file through the game's save API, as Continue does.
func load_save(_path: String) -> bool:
	return false


## PLACEHOLDER: write the current run to path through the game's save API, so a repro carries the
## state before the step that failed. Return false while the game has no saves.
func save_run(_path: String) -> bool:
	return false


## PLACEHOLDER: the player actions that are legal right now, in a stable order.
func list_actions() -> Array[Dictionary]:
	return []


## PLACEHOLDER: perform an api action through the game's systems; true when it was done.
func perform(_action: Dictionary) -> bool:
	return false


## PLACEHOLDER: a small summary of the run (resources, turn, what's queued); the play log's snapshot
## will do: `return play_log().call("_build_snapshot")`.
func state() -> Dictionary:
	return {}


## PLACEHOLDER: true once the run has ended.
func is_run_over() -> bool:
	return false
