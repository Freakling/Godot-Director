extends Control
## Shop screen (GDD › Systems › Shop screen): shows the run and passes button presses to RunState.
## It holds no rules.

@onready var _status: Label = %Status
@onready var _buy: Button = %Buy
@onready var _sell: Button = %Sell
@onready var _next_day: Button = %NextDay


func _ready() -> void:
	RunState.changed.connect(_refresh)
	_buy.pressed.connect(_on_buy_pressed)
	_sell.pressed.connect(_on_sell_pressed)
	_next_day.pressed.connect(_on_next_day_pressed)
	_refresh()
	_buy.grab_focus()   # keyboard and controller players start on Buy


func _refresh() -> void:
	if RunState.is_over():
		var outcome: String = "won" if RunState.is_won() else "lost"
		_status.text = "The market has closed. You %s with %d gold." % [outcome, RunState.gold]
	else:
		_status.text = "Day %d · grain costs %d · gold %d · grain %d" % [
			RunState.day, RunState.price(), RunState.gold, RunState.grain]
	_sell.disabled = RunState.is_over() or RunState.grain == 0
	_next_day.disabled = RunState.is_over()


func _on_buy_pressed() -> void:
	RunState.buy()


func _on_sell_pressed() -> void:
	RunState.sell()


func _on_next_day_pressed() -> void:
	RunState.next_day()
