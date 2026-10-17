extends "res://tools/test_case.gd"
## The run's play log lines (GDD › Core Loop): each trade, each day and the end of the market log a
## line with a stable event id, read through PlayLog.start_capture().


func _events(lines: Array[Dictionary]) -> PackedStringArray:
	var events: PackedStringArray = PackedStringArray()
	for line: Dictionary in lines:
		events.append(str(line["event"]))
	return events


func test_a_run_logs_its_seed_trades_days_and_snapshots() -> void:
	PlayLog.start_capture()
	RunState.start_run(7)
	RunState.buy()
	RunState.sell()
	RunState.next_day()
	var lines: Array[Dictionary] = PlayLog.stop_capture()
	var events: PackedStringArray = _events(lines)
	for expected: String in ["run.new", "run.seed", "snapshot", "trade.buy", "trade.sell", "day.next"]:
		expect(events.has(expected), "no %s line in %s" % [expected, events])
	var snapshot: Dictionary = lines[events.rfind("snapshot")]
	expect_eq(snapshot["turn"], 2, "the second day's snapshot is stamped T2")
	expect_eq((snapshot["data"] as Dictionary)["day"], 2)


func test_the_end_of_the_market_blocks_the_next_day() -> void:
	RunState.start_run(7)
	for _day: int in 30:   # bounded: a broken RunState must fail the test, not hang the check
		if RunState.is_over():
			break
		RunState.next_day()
	PlayLog.start_capture()
	PlayLog.check_progress()
	PlayLog.log_progress_press()
	var events: PackedStringArray = _events(PlayLog.stop_capture())
	expect(events.has("progress.blocked"), str(events))
	expect(events.has("progress.pressed_blocked"), str(events))


func test_an_engine_error_is_logged_with_where_it_happened() -> void:
	PlayLog.flush_engine_log()   # earlier errors aren't this test's
	PlayLog.start_capture()
	print("GDIR-IGNORE:market day expected error")
	push_error("market day expected error")
	PlayLog.flush_engine_log()
	var lines: Array[Dictionary] = PlayLog.stop_capture()
	expect_eq(lines.size(), 1)
	if lines.size() == 1:
		expect_eq(lines[0]["event"], "engine.error")
		expect_eq((lines[0]["data"] as Dictionary)["file"], "res://tests/test_play_log.gd")
		expect(str(lines[0]["line"]).contains("[engine error] market day expected error"), str(lines[0]["line"]))


func test_nothing_is_written_under_the_check() -> void:
	expect_false(PlayLog.writes_files())
	expect_eq(PlayLog.log_path(), "")
