extends Node
## The current run (GDD › Core Loop): day, gold and grain. It holds the state, applies Market's
## rules and emits `changed`. Screens read it and call its methods. Each trade and day logs a line
## to PlayLog, so a test or a review can follow the run.

signal changed

const CONFIG_PATH: String = "res://data/market_config.tres"

var day: int = 1
var gold: int = 0
var grain: int = 0

var _market: Market


func _ready() -> void:
	start_run(randi())


func start_run(run_seed: int) -> void:
	var config: MarketConfig = load(CONFIG_PATH) as MarketConfig
	_market = Market.new(config, run_seed)
	day = 1
	gold = config.starting_gold
	grain = 0
	PlayLog.begin_run()
	PlayLog.log_event("run", "run.seed", "seed %d" % run_seed, {"seed": run_seed})
	_start_day()
	changed.emit()


func price() -> int:
	return _market.price_for_day(day)


func can_buy() -> bool:
	return not is_over() and _market.can_buy(gold, day)


func buy() -> bool:
	if not can_buy():
		return false
	var paid: int = price()
	gold -= paid
	grain += 1
	PlayLog.log_event("trade", "trade.buy", "bought grain for %d: gold %d, grain %d" % [paid, gold, grain],
		{"price": paid, "gold": gold, "grain": grain})
	changed.emit()
	return true


func sell() -> bool:
	if is_over() or not _market.can_sell(grain):
		return false
	var earned: int = price()
	gold += earned
	grain -= 1
	PlayLog.log_event("trade", "trade.sell", "sold grain for %d: gold %d, grain %d" % [earned, gold, grain],
		{"price": earned, "gold": gold, "grain": grain})
	changed.emit()
	return true


func next_day() -> void:
	if is_over():
		return
	day += 1
	PlayLog.log_event("day", "day.next", "day %d" % day, {"day": day})
	if is_over():
		PlayLog.log_event("run", "run.over", "won" if is_won() else "lost", {"won": is_won(), "gold": gold})
	else:
		_start_day()
	changed.emit()


func is_over() -> bool:
	return _market.is_over(day)


func is_won() -> bool:
	return _market.is_won(gold)


## The point the player may act: the log gets the turn and a snapshot.
func _start_day() -> void:
	PlayLog.set_turn(day)
	PlayLog.log_snapshot()
