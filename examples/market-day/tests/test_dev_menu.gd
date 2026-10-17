extends "res://tools/test_case.gd"
## The dev menu (AGENTS.md › Project rules: in game, F12, debug builds): the Run tab shows RunState's
## actions and hidden values, and an action changes the run and is logged.


func test_the_run_tab_has_the_actions_and_the_hidden_values() -> void:
	expect(DevMenu.systems().has("Run"), str(DevMenu.systems()))
	var methods: PackedStringArray = PackedStringArray()
	for action: Dictionary in DevMenu.actions_of("Run"):
		methods.append(str(action["method"]))
	for expected: String in ["buy", "sell", "next_day", "debug_add_gold"]:
		expect(methods.has(expected), "no %s action in %s" % [expected, methods])
	RunState.start_run(7)
	var values: Dictionary = DevMenu.inspect("Run")
	expect_eq(values["price today"], RunState.price())
	expect_eq(values["over"], false)


func test_an_action_changes_the_run_and_logs_a_line() -> void:
	RunState.start_run(7)
	var before: int = RunState.gold
	PlayLog.start_capture()
	DevMenu.run_action("Run", "debug_add_gold", [25])
	expect_eq(RunState.gold, before + 25, "gold after the dev menu's action")
	var paid: int = RunState.price()
	DevMenu.run_action("Run", "buy")
	expect_eq(RunState.grain, 1, "buy ran through the menu")
	expect_eq(RunState.gold, before + 25 - paid)
	var events: PackedStringArray = PackedStringArray()
	for line: Dictionary in PlayLog.stop_capture():
		events.append(str(line["event"]))
	expect(events.has("devmenu.action") and events.has("run.debug_gold"), str(events))
