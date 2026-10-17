extends "res://tools/autoplay_catalog.gd"
## The autoplay scenarios · project-owned: edit freely.
##
## How `bash tools/autoplay.sh <scenario>` plays Market Day. The scenario format and the thresholds
## are in tools/autoplay_catalog.gd.


func scenarios() -> Array[Dictionary]:
	return [
		{"id": "smoke", "title": "Start, open the shop, trade for 3 days", "kind": "smoke", "turns": 3},
		{"id": "trade_week", "title": "Buy twice, sell once, then play out the market", "kind": "scripted", "actions": [
			{"do": "buy"},
			{"do": "buy", "expect": {"grain": 2}},
			{"do": "sell", "expect": {"grain": 1}},
			{"do": "next_day", "repeat": 3, "expect": {"day": 4}},
			{"do": "next_day_fast", "expect": {"day": 5}},
			{"do": "next_day", "expect": {"over": true}},
		]},
		{"id": "greedy_trader", "title": "Buy cheap, sell dear, until the market closes", "kind": "strategy",
			"strategy": "greedy", "steps": 40, "score": _trade_score},
	]


## Buy below the base price, sell above it, else move on to the next day (through the shop).
func _trade_score(action: Dictionary, state: Dictionary) -> float:
	var price: int = RunState.price()
	match str(action["id"]):
		"buy":
			return 2.0 if price < 10 and int(state["gold"]) >= price else 0.0
		"sell":
			return 2.0 if price > 10 else 0.0
		"next_day":
			return 1.0
	return -1.0
