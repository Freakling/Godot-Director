extends SceneTree
## Selftest of tools/dev_menu_base.gd. selftest.sh copies it into a game that has the base and runs
## it with the real flag on the command line:
##     godot --headless --path . --script tools/selftest_dev_menu.gd -- --dev-menu
## It prints "PASS <what>" or "FAIL <what>: <detail>" per check, then "DONE".

var _done: bool = false


## A system to register: debug hooks, a public method, an @export value, a hidden one.
class Stub extends Node:
	@export var gold: int = 5
	var secret: int = 99
	var total: int = 0
	var text_seen: String = ""
	var rolled: bool = false

	func debug_add(amount: int) -> void:
		total += amount

	func debug_reset() -> void:
		total = 0

	func debug_say(words: String, loud: bool) -> String:
		text_seen = words
		return words.to_upper() if loud else words

	func debug_vector(_where: Vector2) -> void:
		pass

	func debug_inspect() -> Dictionary:
		return {"total": total, "next roll": 4}

	func bump() -> int:
		total += 1
		return total

	func _private_thing() -> void:
		pass


## A play log stand-in: a tail and a log_event, nothing written.
class FakeLog extends Node:
	var lines: PackedStringArray = ["12:00:00 T1 [run] started"]
	var events: Array[Dictionary] = []

	func tail(count: int = 50) -> PackedStringArray:
		return lines.slice(maxi(0, lines.size() - count))

	func log_event(category: String, event: String, text: String, data: Dictionary = {}) -> void:
		events.append({"cat": category, "event": event, "text": text, "data": data})


## The menu as a game's seed sets it up. `release` stands in for a release build.
class TestMenu extends "res://tools/dev_menu_base.gd":
	var release: bool = false
	var flags: PackedStringArray = PackedStringArray()
	var game_setting: bool = false

	func _is_debug_build() -> bool:
		return not release

	func _command_line() -> PackedStringArray:
		return flags

	func setting_enabled() -> bool:
		return game_setting


## The base as it is, only the build type stood in: it reads the real command line.
class RealFlagMenu extends "res://tools/dev_menu_base.gd":
	func _is_debug_build() -> bool:
		return false


func _initialize() -> void:
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	if _done:
		return
	_done = true
	_run()
	print("DONE")
	quit(0)


func _check(condition: bool, what: String, detail: String = "") -> void:
	if condition:
		print("PASS " + what)
	else:
		print("FAIL %s: %s" % [what, detail])


func _key(code: Key, pressed: bool = true, echo: bool = false) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	event.echo = echo
	return event


func _menu(fake_log: Object = null) -> TestMenu:
	var menu: TestMenu = TestMenu.new()
	menu.log_source = fake_log
	root.add_child(menu)
	return menu


func _find(node: Node, node_name: String) -> Node:
	return node.find_child(node_name, true, false)


func _run() -> void:
	_run_build_and_toggle()
	_run_actions()
	_run_inspector()
	_run_log()
	_run_logged_actions()
	_run_registry()
	_run_enabling()


func _run_build_and_toggle() -> void:
	var menu: TestMenu = _menu()
	_check(menu.is_available() and not menu.is_open() and menu.get_child_count() == 0,
		"in a debug build the menu is available, closed, and has built nothing yet", str(menu.get_child_count()))
	var stub: Stub = Stub.new()
	root.add_child(stub)
	menu.register_system("Stub", stub, ["bump"])
	_check(menu.get_child_count() == 0 and menu.systems() == PackedStringArray(["Stub"]),
		"registering a system builds no overlay while the menu is closed")
	menu._input(_key(KEY_F12))
	_check(menu.is_open() and menu.visible, "F12 opens it")
	var tabs: TabContainer = _find(menu, "Tabs") as TabContainer
	var titles: PackedStringArray = PackedStringArray()
	for index: int in tabs.get_tab_count():
		titles.append(tabs.get_tab_title(index))
	_check(titles == PackedStringArray(["Stub", "Log"]), "one tab per registered system, then the Log tab", str(titles))
	menu._input(_key(KEY_F12, true, true))
	_check(menu.is_open(), "a held key (echo) doesn't close it")
	menu._input(_key(KEY_F11))
	menu._input(_key(KEY_F12, false))
	_check(menu.is_open(), "another key, and the key's release, do nothing")
	menu._input(_key(KEY_F12))
	_check(not menu.is_open() and not menu.visible, "F12 closes it again")
	menu.toggle_key = KEY_F10
	menu._input(_key(KEY_F12))
	menu._input(_key(KEY_F10))
	_check(menu.is_open(), "the toggle key is configurable")
	(_find(menu, "Close") as Button).pressed.emit()
	_check(not menu.is_open(), "the Close button closes it")
	menu.queue_free()
	stub.queue_free()


func _run_actions() -> void:
	var menu: TestMenu = _menu()
	var stub: Stub = Stub.new()
	root.add_child(stub)
	menu.register_system("Stub", stub, ["bump", "_private_thing", "nope"])
	var methods: PackedStringArray = PackedStringArray()
	var supported: Dictionary = {}
	for action: Dictionary in menu.actions_of("Stub"):
		methods.append(str(action["method"]))
		supported[str(action["method"])] = action["supported"]
	_check(methods == PackedStringArray(["bump", "debug_add", "debug_reset", "debug_say", "debug_vector"]),
		"the actions are the named public methods, then every debug_* hook (not debug_inspect, not private ones)", str(methods))
	_check(supported["debug_say"] and not supported["debug_vector"],
		"an argument of an unsupported type is flagged, int, String and bool are supported")
	menu.open()
	var page: Node = _find(menu, "Stub")
	var buttons: PackedStringArray = PackedStringArray()
	for method: String in methods:
		var button: Button = _find(page, method) as Button
		if button != null:
			buttons.append(button.text)
	_check(buttons == PackedStringArray(["Bump", "Add", "Reset", "Say", "Vector"]), "a button per action, named after it", str(buttons))
	_check(_find(page, "debug_vector") != null and (_find(page, "debug_vector") as Button).disabled, "the unsupported action still shows, disabled")
	(_find(page, "bump") as Button).pressed.emit()
	_check(stub.total == 1 and menu.last_result == "1", "pressing a button calls the public method and shows what it returned", menu.last_result)
	((_find(page, "Row_debug_add").find_child("amount", true, false)) as SpinBox).value = 5
	(_find(page, "debug_add") as Button).pressed.emit()
	_check(stub.total == 6, "an int argument is taken from its field", str(stub.total))
	((_find(page, "Row_debug_say").find_child("words", true, false)) as LineEdit).text = "hello"
	((_find(page, "Row_debug_say").find_child("loud", true, false)) as CheckBox).button_pressed = true
	(_find(page, "debug_say") as Button).pressed.emit()
	_check(stub.text_seen == "hello" and menu.last_result == "HELLO", "a String and a bool argument are taken from their fields", menu.last_result)
	(_find(page, "debug_reset") as Button).pressed.emit()
	_check(stub.total == 0 and menu.last_result == "done", "an action that returns nothing says done", menu.last_result)
	_check(menu.run_action("Stub", "debug_add", [1, 2]) == null and menu.last_result.begins_with("not run"),
		"a call with the wrong number of arguments isn't made", menu.last_result)
	_check(menu.run_action("Stub", "_private_thing") == null and menu.run_action("Stub", "queue_free") == null and is_instance_valid(stub),
		"a method that isn't an action (private, or an engine method) can't be run through the menu")
	menu.queue_free()
	stub.queue_free()


func _run_inspector() -> void:
	var menu: TestMenu = _menu()
	var stub: Stub = Stub.new()
	root.add_child(stub)
	menu.register_system("Stub", stub, ["bump"])
	var values: Dictionary = menu.inspect("Stub")
	_check(values.get("total") == 0 and values.get("next roll") == 4 and values.get("gold") == 5,
		"the inspector lists debug_inspect()'s values and the @export values", str(values))
	_check(not values.has("secret") and not values.has("rolled"), "a plain variable isn't listed", str(values))
	menu.register_system("Stub", stub, [], false)
	_check(not menu.inspect("Stub").has("gold") and menu.inspect("Stub").has("next roll"), "include_exports=false leaves the @export values out")
	menu.register_system("Stub", stub, ["bump"])
	menu.open()
	var label: Label = _find(menu, "Inspector") as Label
	_check("total: 0" in label.text and "next roll: 4" in label.text and "gold: 5" in label.text, "the inspector shows them while open", label.text)
	stub.total = 42
	menu._process(1.0)
	_check("total: 42" in label.text, "it refreshes while the menu is open", label.text)
	menu.close()
	stub.total = 7
	_check("total: 42" in label.text and not menu.is_processing(), "and stops refreshing when it's closed", label.text)
	_check(menu.inspect_all_text().begins_with("[Stub]\n") and "total: 7" in menu.inspect_all_text(),
		"inspect_all_text() gives the same values as text, for a test or a tool")
	stub.free()
	menu.open()
	_check("freed" in (_find(menu, "Inspector") as Label).text and menu.actions_of("Stub").is_empty(),
		"a freed system's tab says so, with no actions, and nothing breaks")
	menu.queue_free()


func _run_log() -> void:
	var fake: FakeLog = FakeLog.new()
	root.add_child(fake)
	var menu: TestMenu = _menu(fake)
	menu.open()
	var view: RichTextLabel = _find(menu, "Log") as RichTextLabel
	_check("T1 [run] started" in view.text, "the Log tab shows the play log's tail", view.text)
	fake.lines.append("12:00:05 T2 [trade] bought grain")
	menu._process(1.0)
	_check("bought grain" in view.text, "and keeps up while open", view.text)
	menu.log_lines = 1
	menu.refresh()
	_check("bought grain" in view.text and not "started" in view.text, "log_lines limits how many lines it shows", view.text)
	menu.queue_free()
	var bare: TestMenu = _menu()
	bare.log_source_path = ^"/root/NoSuchLog"
	bare.open()
	_check("no play log" in (_find(bare, "Log") as RichTextLabel).text, "with no play log it says so", (_find(bare, "Log") as RichTextLabel).text)
	bare.queue_free()
	var real: Node = root.get_node_or_null("PlayLog")
	if real != null:
		real.call("log_event", "selftest", "selftest.devmenu", "a line for the dev menu")
		var from_autoload: TestMenu = _menu()
		from_autoload.open()
		_check("a line for the dev menu" in (_find(from_autoload, "Log") as RichTextLabel).text,
			"by default the Log tab reads the PlayLog autoload's tail", (_find(from_autoload, "Log") as RichTextLabel).text)
		from_autoload.queue_free()
	fake.queue_free()


func _run_logged_actions() -> void:
	var fake: FakeLog = FakeLog.new()
	root.add_child(fake)
	var menu: TestMenu = _menu(fake)
	var stub: Stub = Stub.new()
	root.add_child(stub)
	menu.register_system("Stub", stub)
	menu.run_action("Stub", "debug_add", [3])
	menu.run_action("Stub", "debug_say", ["private words", false])
	_check(fake.events.size() == 2 and fake.events[0]["event"] == "devmenu.action"
		and fake.events[0]["data"] == {"system": "Stub", "action": "debug_add", "args": [3]},
		"an action is logged as devmenu.action with its system, name and numeric arguments", str(fake.events))
	_check(fake.events[1]["data"]["args"] == ["<text>", false] and not "private words" in str(fake.events[1]),
		"typed text is never logged", str(fake.events[1]))
	menu.queue_free()
	stub.queue_free()
	fake.queue_free()


func _run_registry() -> void:
	var menu: TestMenu = _menu()
	var one: Stub = Stub.new()
	var two: Stub = Stub.new()
	root.add_child(one)
	root.add_child(two)
	menu.register_system("One", one)
	menu.register_system("Two", two)
	menu.open()
	menu.register_system("One", two)
	_check(menu.systems() == PackedStringArray(["Two", "One"]), "registering a name again replaces it", str(menu.systems()))
	var tabs: TabContainer = _find(menu, "Tabs") as TabContainer
	_check(tabs.get_tab_count() == 3, "and leaves one tab per system (the open menu rebuilt them)", str(tabs.get_tab_count()))
	menu.unregister_system("Two")
	_check(menu.systems() == PackedStringArray(["One"]) and tabs.get_tab_count() == 2, "unregistering removes the tab")
	menu.queue_free()
	one.queue_free()
	two.queue_free()


func _run_enabling() -> void:
	# A release build: only the setting and the flag can turn it on.
	var release: TestMenu = _menu()
	release.release = true
	var stub: Stub = Stub.new()
	root.add_child(stub)
	release.register_system("Stub", stub)
	_check(not release.is_available(), "in a release build, in_game alone leaves the menu unavailable")
	release.open()
	release._input(_key(KEY_F12))
	_check(not release.is_open() and not release.visible and release.get_child_count() == 0,
		"it stays absent: open() and the key do nothing and no node is built")
	release.enabled_by = PackedStringArray(["setting", "flag"])
	_check(not release.is_available(), "with the setting and the flag allowed but neither set, a release build has none")
	ProjectSettings.set_setting("debug/dev_menu", true)
	_check(release.is_available(), "the project setting debug/dev_menu turns it on in a release build")
	release._input(_key(KEY_F12))
	_check(release.is_open() and release.get_child_count() > 0, "and then the key opens it")
	release.close()
	ProjectSettings.set_setting("debug/dev_menu", false)
	_check(not release.is_available(), "the setting off turns it off again")
	release.game_setting = true
	_check(release.is_available(), "the game's own Settings (setting_enabled()) turn it on too")
	release.game_setting = false
	release.flags = PackedStringArray(["--dev-menu"])
	_check(release.is_available(), "the --dev-menu flag turns it on in a release build")
	release.enabled_by = PackedStringArray(["setting"])
	_check(not release.is_available(), "a flag that wasn't chosen does nothing")
	# The director's choice limits a debug build too.
	var debug: TestMenu = _menu()
	debug.enabled_by = PackedStringArray(["flag"])
	_check(not debug.is_available(), "a debug build with only the flag allowed is unavailable until the flag is given")
	debug.flags = PackedStringArray(["--dev-menu"])
	_check(debug.is_available(), "and available with it")
	debug.enabled_by = PackedStringArray()
	_check(not debug.is_available(), "with no way chosen it is never available")
	# The real command line: this script was started with `-- --dev-menu`.
	var real: RealFlagMenu = RealFlagMenu.new()
	real.enabled_by = PackedStringArray(["flag"])
	root.add_child(real)
	_check(OS.get_cmdline_user_args().has("--dev-menu") and real.is_available(),
		"the real command line's `-- --dev-menu` enables a release build", str(OS.get_cmdline_user_args()))
	real.enabled_by = PackedStringArray(["in_game"])
	_check(not real.is_available(), "and does nothing when the flag isn't the chosen way")
	real.queue_free()
	debug.queue_free()
	release.queue_free()
	stub.queue_free()
