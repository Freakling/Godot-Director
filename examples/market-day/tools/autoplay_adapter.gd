extends "res://tools/autoplay_adapter_base.gd"
## The autoplay adapter · project-owned: edit freely.
##
## How `bash tools/autoplay.sh` plays Market Day. The shop's buttons are ui actions, clicked through
## real input; next_day_fast does the same as Next Day through RunState, for speed. The action
## format and the helpers are in tools/autoplay_adapter_base.gd. Market Day has no saves yet, so
## save_run() and load_save() stay the base's, and a repro carries the seed and the actions only.


## A new market with this seed; the shop shows it at once.
func start_run(run_seed: int) -> void:
	RunState.start_run(run_seed)
	await wait_frames(1)


func list_actions() -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	if RunState.is_over():
		return actions
	if RunState.can_buy():
		actions.append({"id": "buy", "label": "Buy grain", "kind": "ui", "node": "%Buy"})
	if RunState.grain > 0:
		actions.append({"id": "sell", "label": "Sell grain", "kind": "ui", "node": "%Sell"})
	if progress_block_reason().is_empty():
		actions.append({"id": "next_day", "label": "Next day", "kind": "ui", "node": "%NextDay", "progress": true})
		actions.append({"id": "next_day_fast", "label": "Next day, through RunState", "kind": "api", "progress": true})
	return actions


func perform(action: Dictionary) -> bool:
	match str(action["id"]):
		"next_day_fast":
			RunState.next_day()
			return true
	return false


func state() -> Dictionary:
	return {"day": RunState.day, "gold": RunState.gold, "grain": RunState.grain, "over": RunState.is_over()}


func is_run_over() -> bool:
	return RunState.is_over()
