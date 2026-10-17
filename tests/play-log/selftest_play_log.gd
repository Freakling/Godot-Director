extends SceneTree
## Selftest of tools/play_log_base.gd outside the check, where it writes files. selftest.sh copies it
## into a game that has the base and runs it:
##     godot --headless --path . --script tools/selftest_play_log.gd -- <empty folder>
## It prints "PASS <what>" or "FAIL <what>: <detail>" per check, then "DONE".

const LINE: String = "^\\d\\d:\\d\\d:\\d\\d T(-|\\d+) \\[[^\\]]+\\] .*$"
const KEYS: Array[String] = ["t", "turn", "cat", "event", "text", "data"]

var _root_dir: String = ""
var _done: bool = false


## A game's PlayLog, with the hooks filled and the tool-run rule off, since this is a tool run.
class TestLog extends "res://tools/play_log_base.gd":
	var blocked: String = ""

	func _is_tool_run() -> bool:
		return false

	func _session_extras() -> Dictionary:
		return {"settings": {"volume": 0.5, "api_token": "tok-s3cr3t-value", "language": "en", "secret_mode": true,
			"pin_secret": 4242, "steam_id": "7656119800000", "license_key": "LIC-9F2A-77"}, "failsafe": false}

	func _install_id() -> String:
		return "inst-0042-abcd"

	func _build_snapshot() -> Dictionary:
		return {"gold": 5}

	func progress_block_reason() -> String:
		return blocked


func _initialize() -> void:
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	if _done:
		return
	_done = true
	_root_dir = OS.get_cmdline_user_args()[0]
	_run()
	await _run_input()
	print("DONE")
	quit(0)


func _pass(what: String) -> void:
	print("PASS " + what)


func _check(condition: bool, what: String, detail: String = "") -> void:
	if condition:
		print("PASS " + what)
	else:
		print("FAIL %s: %s" % [what, detail])


func _dir(name: String) -> String:
	var path: String = _root_dir.path_join(name)
	DirAccess.make_dir_recursive_absolute(path)
	return path


func _files(dir: String) -> PackedStringArray:
	var names: PackedStringArray = DirAccess.get_files_at(dir)
	names.sort()
	return names


func _lines(path: String) -> PackedStringArray:
	return FileAccess.get_file_as_string(path).strip_edges(false, true).split("\n")


func _new_log(dir: String) -> TestLog:
	var log: TestLog = TestLog.new()
	log.log_dir = dir
	root.add_child(log)
	return log


func _events(lines: Array[Dictionary]) -> PackedStringArray:
	var events: PackedStringArray = PackedStringArray()
	for line: Dictionary in lines:
		events.append(str(line["event"]))
	return events


func _jsonl_events(path: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for text: String in _lines(path):
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			result.append(parsed)
	return result


func _run() -> void:
	var game_log: Node = root.get_node_or_null("PlayLog")
	_check(game_log != null and not bool(game_log.call("writes_files")),
		"a tool script run (--script) writes no play log", "the game's PlayLog would write files")
	# Known values to scrub, whatever machine this runs on.
	OS.set_environment("HOME", "/selftest/Home Dir")
	OS.set_environment("USERPROFILE", "C:\\SelfTest\\Home")
	OS.set_environment("USERNAME", "selftestuser")
	OS.set_environment("USER", "selftestuser")
	_run_files()
	_run_meta()
	_run_continue()
	_run_rejected_id()
	_run_boot()
	_run_keep()


func _run_files() -> void:
	var dir: String = _dir("main")
	var log: TestLog = _new_log(dir)
	log.log_event("boot", "boot.title", "title screen shown")
	_check(_files(dir).is_empty(), "holds the lines until the run is decided", str(_files(dir)))
	var id: String = log.begin_run()
	var text_path: String = dir.path_join("run-%s.log" % id)
	var json_path: String = dir.path_join("run-%s.jsonl" % id)
	_check(FileAccess.file_exists(text_path) and FileAccess.file_exists(json_path),
		"begin_run writes run-<datetime>.log and .jsonl", str(_files(dir)))
	_check(id.length() >= 15 and id.substr(8, 1) == "-", "the run id is the date and time", id)
	var text: String = FileAccess.get_file_as_string(text_path)
	_check(RegEx.create_from_string(" T- \\[boot\\] title screen shown\\n").search(text) != null,
		"keeps the startup lines, stamped T-, and flushes each line (read while the file is open)", text)
	log.set_turn(3)
	log.log_event("trade", "trade.buy", "bought grain", {"price": 9})
	var lines: PackedStringArray = _lines(text_path)
	_check(RegEx.create_from_string("^\\d\\d:\\d\\d:\\d\\d T3 \\[trade\\] bought grain$").search(lines[lines.size() - 1]) != null,
		"the text line is HH:MM:SS T<turn> [category] text", lines[lines.size() - 1])
	var line_pattern: RegEx = RegEx.create_from_string(LINE)
	var bad: PackedStringArray = PackedStringArray()
	for line: String in lines:
		if line_pattern.search(line) == null:
			bad.append(line)
	_check(bad.is_empty(), "every text line has that format, the session header too", "\n".join(bad))
	var entries: Array[Dictionary] = _jsonl_events(json_path)
	_check(entries.size() == lines.size(), "the .jsonl has one line per text line", "%d vs %d" % [entries.size(), lines.size()])
	var order_ok: bool = true
	var id_pattern: RegEx = RegEx.create_from_string("^[a-z][a-z0-9_]*(\\.[a-z0-9_]+)*$")
	for entry: Dictionary in entries:
		if entry.keys() != KEYS or id_pattern.search(str(entry["event"])) == null or not entry["data"] is Dictionary:
			order_ok = false
	_check(order_ok, "each JSONL line is {t, turn, cat, event, text, data} with a stable event id", JSON.stringify(entries))
	var last: Dictionary = entries[entries.size() - 1]
	_check(last["event"] == "trade.buy" and int(last["turn"]) == 3 and last["cat"] == "trade" and last["text"] == "bought grain"
		and int((last["data"] as Dictionary)["price"]) == 9, "the JSONL line carries the same values", JSON.stringify(last))
	var boot: Dictionary = entries[_events(entries).find("boot.title")] if _events(entries).has("boot.title") else {}
	_check(not boot.is_empty() and boot["turn"] == null, "a startup line's turn is null in the JSONL", JSON.stringify(boot))
	_check(text.contains("[session] ") and text.contains("Godot %s" % str(Engine.get_version_info()["string"]))
		and text.contains(" · debug · args: "), "the session header names the build, Godot, the OS, debug or release and the args", text)
	_check(text.contains("settings: volume=0.5") and text.contains("language=en") and not text.contains("api_token")
		and not text.contains("secret_mode") and not text.contains("steam_id") and not text.contains("license_key")
		and text.contains("failsafe: false"), "the header lists the settings, leaving out the secret ones (secret, token, _id, _key)", text)
	_check(text.contains("resources: data=1"), "the header counts the resources per data folder", text)

	log.log_event("save", "save.write", "saved C:/SelfTest/Home/saves/a.json, C:\\SelfTest\\Home\\b.json, /c/SelfTest/Home/c and /selftest/Home Dir/d for selftestuser (not selftestusers), install inst-0042-abcd, token tok-s3cr3t-value",
		{"path": "c:/selftest/home/x.json", "who": ["selftestuser"]})
	var log_text: String = FileAccess.get_file_as_string(text_path)
	var all_text: String = log_text + FileAccess.get_file_as_string(json_path)
	var leaks: PackedStringArray = PackedStringArray()
	for secret: String in ["SelfTest\\Home", "SelfTest/Home", "selftest/home", "Home Dir", "inst-0042-abcd", "tok-s3cr3t-value", " selftestuser "]:
		if all_text.containsn(secret):
			leaks.append(secret)
	_check(leaks.is_empty() and log_text.contains("saved ~/saves/a.json, ~\\b.json, ~/c and ~/d for")
		and all_text.contains("\"path\":\"~/x.json\""), "scrubs the home folder in every form, also in data",
		", ".join(leaks) + " " + log_text.right(400))
	log.log_event("misc", "misc.flags", "flags true false 14242, steam 7656119800000, license LIC-9F2A-77")
	var flags: PackedStringArray = _lines(text_path)
	_check(flags[flags.size() - 1].ends_with("flags true false 14242, steam <secret>, license <secret>"),
		"scrubs only the text values of secret settings: a boolean or numeric secret blanks nothing", flags[flags.size() - 1])
	_check(all_text.contains("for <user> (not selftestusers)") and all_text.contains("install <install-id>") and all_text.contains("token <secret>"),
		"scrubs the user name (whole words), the install id and the secret settings' values", all_text.right(600))

	push_error("selftest engine error")
	push_warning("selftest engine warning")
	log.flush_engine_log()
	entries = _jsonl_events(json_path)
	var engine_error: Dictionary = {}
	var engine_warning: Dictionary = {}
	for entry: Dictionary in entries:
		if entry["event"] == "engine.error" and str(entry["text"]).begins_with("selftest engine error"):
			engine_error = entry
		if entry["event"] == "engine.warning" and str(entry["text"]).begins_with("selftest engine warning"):
			engine_warning = entry
	var error_data: Dictionary = engine_error.get("data", {})
	_check(not engine_error.is_empty() and engine_error["cat"] == "engine error"
		and error_data.get("file", "") == "res://tools/selftest_play_log.gd" and int(error_data.get("line", 0)) > 0
		and error_data.get("function", "") == "_run_files", "catches an engine error through the Logger, with the top script frame", JSON.stringify(engine_error))
	_check(not engine_warning.is_empty() and engine_warning["cat"] == "engine warning", "and a warning", JSON.stringify(engine_warning))
	log.max_engine_repeats = 3
	for _index: int in 6:
		push_error("selftest repeated error")
	log.flush_engine_log()
	var repeats: PackedStringArray = PackedStringArray()
	for line: String in _lines(text_path):
		if line.contains("selftest repeated error"):
			repeats.append(line)
	_check(repeats.size() == 4 and repeats[3].contains("further repeats aren't logged"),
		"logs one engine error max_engine_repeats times, then says it keeps happening", "\n".join(repeats))

	log.start_capture()
	log.blocked = "a dialog is open"
	log.check_progress()
	log.check_progress()
	var button: Button = Button.new()
	button.disabled = true
	root.add_child(button)
	log.watch_progress_button(button)
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	button.gui_input.emit(click)
	log.blocked = ""
	log.check_progress()
	log.log_progress_press()
	log.log_view("shop")
	log.log_view("shop")
	var shell: Node = Node.new()
	shell.add_user_signal("view_changed", [{"name": "name", "type": TYPE_STRING}])
	log.watch_views(shell)
	shell.emit_signal("view_changed", "map")
	log.log_snapshot()
	button.queue_free()
	shell.free()
	log._process(0.0)
	log._process(0.0)
	log._process(1.0)
	var captured: Array[Dictionary] = log.stop_capture()
	var events: PackedStringArray = _events(captured)
	_check(events.count("progress.blocked") == 1 and events.count("progress.pressed_blocked") == 1 and events.count("progress.unblocked") == 1
		and events.count("progress.pressed") == 1, "logs the progress button's state once per change, and every press with what blocked it", str(events))
	_check(events.count("view.changed") == 2 and str(captured[events.rfind("view.changed")]["text"]) == "map",
		"logs view changes, also from a view_changed(name) signal", str(events))
	var snapshot: Dictionary = captured[events.find("snapshot")]["data"] if events.has("snapshot") else {}
	_check(int(snapshot.get("gold", -1)) == 5 and snapshot.has("orphan_nodes"), "logs the snapshot with the orphan-node count (debug build)", str(snapshot))
	_check(events.count("frame.hitch") == 1, "logs a frame over the hitch threshold", str(events))
	_check(not captured.is_empty() and captured[0].has("line") and str(captured[0]["line"]).contains("[progress] blocked: a dialog is open"),
		"start_capture records the lines in memory, with the text line", str(captured.slice(0, 1)))
	_check(log.tail(2).size() == 2 and log.tail(2)[1].contains("[hitch]"), "tail() returns the recent text lines", str(log.tail(2)))
	root.remove_child(log)
	lines = _lines(text_path)
	_check(lines[lines.size() - 1].ends_with("[session] session ended"), "a session that ends logs session.end", lines[lines.size() - 1])
	log.free()


func _run_meta() -> void:
	for meta: StringName in [&"godot_director_check", &"godot_director_capture"]:
		var dir: String = _dir("meta-" + str(meta))
		Engine.set_meta(meta, true)
		var log: TestLog = _new_log(dir)
		log.start_capture()
		var id: String = log.begin_run()
		log.log_event("trade", "trade.buy", "bought")
		var events: PackedStringArray = _events(log.stop_capture())
		root.remove_child(log)
		log.free()
		_check(_files(dir).is_empty() and not id.is_empty(), "writes nothing under %s" % meta, str(_files(dir)))
		_check(events.has("trade.buy") and events.has("session.start"), "start_capture still records under %s" % meta, str(events))
		Engine.remove_meta(meta)
	Engine.set_meta(&"godot_director_check", true)
	Engine.set_meta(&"godot_director_autoplay", true)
	var log2: TestLog = TestLog.new()
	_check(log2.writes_files(), "writes when autoplay asks for the log, also under the check")
	log2.free()
	Engine.remove_meta(&"godot_director_check")
	Engine.remove_meta(&"godot_director_autoplay")


func _run_continue() -> void:
	var dir: String = _dir("continue")
	var first: TestLog = _new_log(dir)
	var id: String = first.begin_run()
	first.log_event("trade", "trade.buy", "first session line")
	root.remove_child(first)
	first.free()
	var second: TestLog = _new_log(dir)
	second.log_event("boot", "boot.title", "throwaway boot line")
	push_error("selftest continue error")
	second.flush_engine_log()
	second.continue_run(id)
	second.log_event("trade", "trade.sell", "second session line")
	var text: String = FileAccess.get_file_as_string(dir.path_join("run-%s.log" % id))
	_check(_files(dir).size() == 2 and text.contains("first session line") and text.contains("second session line")
		and text.contains("[run] continued run " + id), "continue_run appends to that run's files", text)
	_check(not text.contains("throwaway boot line") and text.contains("selftest continue error"),
		"and drops the held lines, keeping engine errors", text)
	root.remove_child(second)
	second.free()


func _run_rejected_id() -> void:
	var dir: String = _dir("rejected")
	var log: TestLog = _new_log(dir)
	for bad_id: String in ["../../escaped", "", "20261017-0115"]:
		log.continue_run(bad_id)
	var names: PackedStringArray = _files(dir)
	var outside: bool = FileAccess.file_exists(_root_dir.path_join("escaped.log")) or FileAccess.file_exists(dir.path_join("run-.log"))
	var all_runs: bool = names.size() == 6
	for name: String in names:
		all_runs = all_runs and RegEx.create_from_string("^run-\\d{8}-\\d{6}(-\\d+)?\\.(log|jsonl)$").search(name) != null
	_check(not outside and all_runs and FileAccess.get_file_as_string(log.log_path()).contains("[run] the save's run id isn't one"),
		"continue_run refuses an id that isn't a run id (../.., empty) and starts new files", str(names))
	root.remove_child(log)
	log.free()


func _run_boot() -> void:
	var dir: String = _dir("boot")
	var kept_run: TestLog = _new_log(dir)
	kept_run.keep_files = 1
	var id: String = kept_run.begin_run()
	root.remove_child(kept_run)
	kept_run.free()
	for index: int in 4:
		var log: TestLog = _new_log(dir)
		log.keep_boot_files = 2
		log.keep_files = 1
		log.log_event("boot", "boot.title", "boot only %d" % index)
		root.remove_child(log)
		log.free()
	var names: PackedStringArray = _files(dir)
	var boots: int = 0
	for name: String in names:
		if name.begins_with("boot-") and name.ends_with(".log"):
			boots += 1
	_check(boots == 2 and names.has("run-%s.log" % id) and names.size() == 6,
		"a launch that ends before a run keeps its lines in a boot file, under keep_boot_files, and never prunes a run", str(names))
	var newest: String = ""
	for name: String in names:
		if name.begins_with("boot-") and name.ends_with(".log"):
			newest = name
	var text: String = FileAccess.get_file_as_string(dir.path_join(newest))
	_check(text.contains("T- [boot] boot only 3") and text.contains("[session] session ended") and not text.contains("[run] new run"),
		"the boot file has the header, the held lines and the end, and no run", text)


func _run_keep() -> void:
	var dir: String = _dir("keep")
	var log: TestLog = _new_log(dir)
	log.keep_files = 3
	var ids: PackedStringArray = PackedStringArray()
	log.set_turn(9)
	for index: int in 5:
		ids.append(log.begin_run())
	_check(log.turn == 0, "begin_run starts at turn 0", str(log.turn))
	var names: PackedStringArray = _files(dir)
	var newest: bool = true
	for id: String in ids.slice(2):
		newest = newest and names.has("run-%s.log" % id) and names.has("run-%s.jsonl" % id)
	_check(names.size() == 6 and newest, "keeps the newest keep_files runs, both files of each", str(names))
	root.remove_child(log)
	log.free()


## Input is polled once per frame, so these run over real frames.
func _run_input() -> void:
	var dir: String = _dir("input")
	var log: TestLog = _new_log(dir)
	log.begin_run()
	# A stick held past the deadzone for several frames: one press.
	log.start_capture()
	for frame: int in 6:
		var motion: InputEventJoypadMotion = InputEventJoypadMotion.new()
		motion.axis = JOY_AXIS_LEFT_X
		motion.axis_value = -0.9 if frame % 2 == 0 else -0.95
		Input.parse_input_event(motion)
		await process_frame
	var release: InputEventJoypadMotion = InputEventJoypadMotion.new()
	release.axis = JOY_AXIS_LEFT_X
	release.axis_value = 0.0
	Input.parse_input_event(release)
	await process_frame
	await process_frame
	var lefts: int = 0
	for line: Dictionary in log.stop_capture():
		if line["event"] == "input.action" and (line["data"] as Dictionary)["action"] == "ui_left":
			lefts += 1
	_check(lefts == 1, "a stick held past the deadzone logs its action once", "%d ui_left lines" % lefts)
	# An action a node handles (set_input_as_handled) is still logged.
	var handler: Node = HandlesAccept.new()
	root.add_child(handler)
	log.start_capture()
	await _press(&"ui_accept")
	var accepts: int = _count_action(log.stop_capture(), "ui_accept")
	_check(accepts == 1 and (handler as HandlesAccept).handled > 0, "an action a node handles is still logged, once",
		"%d ui_accept lines, handled %d" % [accepts, (handler as HandlesAccept).handled])
	handler.queue_free()
	# Nothing while a text field has focus.
	var field: LineEdit = LineEdit.new()
	root.add_child(field)
	field.grab_focus()
	await process_frame
	log.start_capture()
	await _press(&"ui_accept")
	_check(_count_action(log.stop_capture(), "ui_accept") == 0, "nothing is logged while a text field has focus")
	field.queue_free()
	root.remove_child(log)
	log.free()


func _press(action: StringName) -> void:
	var press: InputEventAction = InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	await process_frame
	var lift: InputEventAction = InputEventAction.new()
	lift.action = action
	lift.pressed = false
	Input.parse_input_event(lift)
	await process_frame


func _count_action(lines: Array[Dictionary], action: String) -> int:
	var count: int = 0
	for line: Dictionary in lines:
		if line["event"] == "input.action" and (line["data"] as Dictionary)["action"] == action:
			count += 1
	return count


## A node that takes ui_accept before anything after it in the tree sees it.
class HandlesAccept extends Node:
	var handled: int = 0

	func _input(event: InputEvent) -> void:
		if event.is_action_pressed("ui_accept"):
			handled += 1
			get_viewport().set_input_as_handled()
