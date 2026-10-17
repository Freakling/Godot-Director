extends CanvasLayer
## The dev menu base · framework-owned: replaced on upgrade.
##
## The project's DevMenu autoload, res://tools/dev_menu.gd, extends this file and registers its
## systems. Register it last under [autoload] in project.godot, DevMenu="*res://tools/dev_menu.gd",
## so the systems it registers exist when its _ready runs. Don't edit this file in a project.
##
## What it is. An overlay for the person or assistant working on the game: one tab per registered
## system, with its actions as buttons and an inspector for its values, and a Log tab with the play
## log's tail. It's the assistant's way to see hidden values, since it can't use the editor's Remote
## scene tree: the inspector's text is also available as inspect_text(), for a test or a tool.
##
## Registering a system: register_system("Run", RunState). The menu reads the node's public API:
## - Actions: every method named debug_* (debug_add_gold(amount: int)), and the public methods named
##   in the third argument (register_system("Run", RunState, ["buy", "next_day"])). A method's
##   required arguments of type int, float, String and bool get an input field; others are skipped.
## - Inspector: the Dictionary a debug_inspect() method returns (the values only code can see: the
##   roll a system holds, the price it would charge), then the node's @export values. Pass false as
##   the fourth argument to leave the @export values out. It refreshes while the menu is open.
## An action's call is logged to the play log as "devmenu.action", so a run that used it says so.
##
## How it is enabled, as the director chose (AGENTS.md › Project rules, `Dev menu:`); the seed sets
## enabled_by:
## - "in_game": the toggle key (F12) works in debug builds (or with the dev_tools feature).
## - "setting": the key works in any build when the project setting debug/dev_menu is true
##   (project.godot, [debug]) or the game's own Settings say so (setting_enabled() in the seed).
## - "flag": the key works in any build started with the command-line flag `-- --dev-menu`.
## When none applies, the menu is absent: no key, no nodes, nothing drawn. The overlay is built on
## the first open, so a game that never opens it pays nothing.

const SETTING: String = "debug/dev_menu"
const FLAG: String = "--dev-menu"
const MODE_IN_GAME: String = "in_game"
const MODE_SETTING: String = "setting"
const MODE_FLAG: String = "flag"
const DEV_TOOLS_FEATURE: String = "dev_tools"
const INSPECT_HOOK: String = "debug_inspect"
const HOOK_PREFIX: String = "debug_"
const LOG_TAB: String = "Log"
const MAX_VALUE_CHARS: int = 300
const SUPPORTED_ARGS: Array[int] = [TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_BOOL]

## The ways the menu is enabled: any of "in_game", "setting", "flag". The seed sets it.
var enabled_by: PackedStringArray = [MODE_IN_GAME]
## The key that opens and closes it.
var toggle_key: Key = KEY_F12
## Seconds between refreshes of the inspectors and the log while the menu is open.
var refresh_interval: float = 0.25
## How many of the play log's recent lines the Log tab shows.
var log_lines: int = 60
## Where the play log is looked up when log_source is empty.
var log_source_path: NodePath = ^"/root/PlayLog"
## The object whose tail(count) feeds the Log tab. Tests set it; by default the PlayLog autoload.
var log_source: Object = null
## What the last action returned, as text ("done" when it returned nothing).
var last_result: String = ""

var _systems: Array[Dictionary] = []
var _root: Control = null
var _tabs: TabContainer = null
var _pages: Dictionary = {}
var _log_view: RichTextLabel = null
var _dirty: bool = true
var _open: bool = false
var _elapsed: float = 0.0


# --- hooks the project fills --------------------------------------------------------------------

## True when the game's own Settings turn the dev menu on, for the "setting" mode.
func setting_enabled() -> bool:
	return false


## Whether this is a debug build. Tests override it to stand in for a release build.
func _is_debug_build() -> bool:
	return OS.is_debug_build() or OS.has_feature(DEV_TOOLS_FEATURE)


## The arguments after `--`, where `--dev-menu` is looked for. Tests override it.
func _command_line() -> PackedStringArray:
	return OS.get_cmdline_user_args()


# --- availability and state ---------------------------------------------------------------------

## True when one of the enabled_by modes applies right now. When false the menu does nothing.
func is_available() -> bool:
	if enabled_by.has(MODE_IN_GAME) and _is_debug_build():
		return true
	if enabled_by.has(MODE_SETTING) and (bool(ProjectSettings.get_setting(SETTING, false)) or setting_enabled()):
		return true
	return enabled_by.has(MODE_FLAG) and _command_line().has(FLAG)


func is_open() -> bool:
	return _open


## Opens the menu when it is available; builds the overlay on the first open.
func open() -> void:
	if not is_available():
		return
	_ensure_ui()
	_open = true
	visible = true
	set_process(true)
	refresh()


func close() -> void:
	_open = false
	visible = false
	set_process(false)


func toggle() -> void:
	if _open:
		close()
	else:
		open()


# --- registering systems ------------------------------------------------------------------------

## Adds a tab for `node` (replacing a tab of the same name). `public_actions` names public methods
## to show as actions besides the debug_* ones; `include_exports` adds the node's @export values to
## its inspector. The node can be freed later: its tab then says so.
func register_system(system_name: String, node: Object, public_actions: PackedStringArray = PackedStringArray(),
		include_exports: bool = true) -> void:
	unregister_system(system_name)
	_systems.append({"name": system_name, "node": node, "public": public_actions, "exports": include_exports})
	_dirty = true
	if _tabs != null:
		_rebuild()


func unregister_system(system_name: String) -> void:
	for index: int in _systems.size():
		if str(_systems[index]["name"]) == system_name:
			_systems.remove_at(index)
			_dirty = true
			if _tabs != null:
				_rebuild()
			return


## The registered systems' names, in the order they were registered.
func systems() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for entry: Dictionary in _systems:
		names.append(str(entry["name"]))
	return names


# --- what a system shows ------------------------------------------------------------------------

## A system's actions: {"method", "label", "args": [{"name", "type"}], "supported", "hook"}, the
## public ones first as registered, then the debug_* hooks by name. `supported` is false when a
## required argument has a type the menu has no field for.
func actions_of(system_name: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var entry: Dictionary = _entry(system_name)
	var node: Object = _live(entry)
	if node == null:
		return result
	var methods: Dictionary = {}
	for method: Dictionary in node.get_method_list():
		methods[str(method["name"])] = method
	var names: PackedStringArray = PackedStringArray()
	var public_names: PackedStringArray = entry["public"]
	for method_name: String in public_names:
		if methods.has(method_name) and not method_name.begins_with("_") and not names.has(method_name):
			names.append(method_name)
	var hooks: PackedStringArray = PackedStringArray()
	for method_name: String in methods:
		if method_name.begins_with(HOOK_PREFIX) and method_name != INSPECT_HOOK and not names.has(method_name):
			hooks.append(method_name)
	hooks.sort()
	names.append_array(hooks)
	for method_name: String in names:
		var method: Dictionary = methods[method_name]
		var all_args: Array = method["args"]
		var defaults: Array = method["default_args"]
		var args: Array[Dictionary] = []
		var supported: bool = true
		for index: int in maxi(0, all_args.size() - defaults.size()):
			var arg: Dictionary = all_args[index]
			args.append({"name": str(arg["name"]), "type": int(arg["type"])})
			supported = supported and SUPPORTED_ARGS.has(int(arg["type"]))
		var label: String = method_name.trim_prefix(HOOK_PREFIX).replace("_", " ").capitalize()
		result.append({"method": method_name, "label": label, "args": args, "supported": supported,
			"hook": method_name.begins_with(HOOK_PREFIX)})
	return result


## Calls an action of a system with `args` and returns what it returned (null for none, or when the
## action isn't one the menu shows). The call is logged to the play log as "devmenu.action".
func run_action(system_name: String, method: String, args: Array = []) -> Variant:
	var node: Object = _live(_entry(system_name))
	var found: bool = false
	var supported: bool = false
	var wanted: int = 0
	for action: Dictionary in actions_of(system_name):
		if str(action["method"]) == method:
			found = true
			supported = bool(action["supported"])
			wanted = (action["args"] as Array).size()
	if node == null or not found or not supported or args.size() != wanted:
		last_result = "not run: %s.%s isn't an action the dev menu shows with those arguments" % [system_name, method]
		return null
	var result: Variant = node.callv(method, args)
	last_result = "done" if result == null else str(result)
	_log_action(system_name, method, args)
	refresh()
	return result


## A system's inspector values: debug_inspect()'s Dictionary, then the @export values.
func inspect(system_name: String) -> Dictionary:
	var values: Dictionary = {}
	var entry: Dictionary = _entry(system_name)
	var node: Object = _live(entry)
	if node == null:
		return values
	if node.has_method(INSPECT_HOOK):
		var hidden: Variant = node.call(INSPECT_HOOK)
		if hidden is Dictionary:
			var source: Dictionary = hidden
			for key: Variant in source:
				values[str(key)] = source[key]
	if bool(entry["exports"]):
		var wanted: int = PROPERTY_USAGE_SCRIPT_VARIABLE | PROPERTY_USAGE_EDITOR
		for property: Dictionary in node.get_property_list():
			if (int(property["usage"]) & wanted) == wanted:
				var property_name: String = str(property["name"])
				if not values.has(property_name):
					values[property_name] = node.get(property_name)
	return values


## A system's inspector as text, one `name: value` line each.
func inspect_text(system_name: String) -> String:
	if _live(_entry(system_name)) == null:
		return "(this system was freed)"
	var lines: PackedStringArray = PackedStringArray()
	var values: Dictionary = inspect(system_name)
	for key: Variant in values:
		lines.append("%s: %s" % [key, _shorten(str(values[key]))])
	return "\n".join(lines) if not lines.is_empty() else "(no values: add a debug_inspect() method)"


## Every system's inspector, headed by its name. What an assistant reads instead of the Remote tree.
func inspect_all_text() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for system_name: String in systems():
		parts.append("[%s]\n%s" % [system_name, inspect_text(system_name)])
	return "\n\n".join(parts)


## The play log's recent lines as text, for the Log tab.
func log_text() -> String:
	var source: Object = _log_object()
	if source == null:
		return "(no play log: the PlayLog autoload isn't registered)"
	var lines: PackedStringArray = source.call("tail", log_lines)
	return "\n".join(lines) if not lines.is_empty() else "(nothing logged yet)"


## Updates the inspectors and the Log tab. Called while the menu is open, and after an action.
func refresh() -> void:
	if _tabs == null:
		return
	for system_name: Variant in _pages:
		var page: Dictionary = _pages[system_name]
		var inspector: Label = page["inspector"]
		var text: String = inspect_text(str(system_name))
		if inspector.text != text:
			inspector.text = text
		(page["result"] as Label).text = last_result
	var log_now: String = log_text()
	if _log_view.text != log_now:
		_log_view.text = log_now


# --- node ---------------------------------------------------------------------------------------

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	set_process(false)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= refresh_interval:
		_elapsed = 0.0
		refresh()


func _input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode != toggle_key and key.physical_keycode != toggle_key:
		return
	if not is_available():
		return
	toggle()
	if is_inside_tree():
		get_viewport().set_input_as_handled()


# --- overlay ------------------------------------------------------------------------------------

func _ensure_ui() -> void:
	if _root == null:
		layer = 100
		_root = Control.new()
		_root.name = "DevMenu"
		_root.set_anchors_preset(Control.PRESET_FULL_RECT)
		_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_root)
		var panel: PanelContainer = PanelContainer.new()
		panel.name = "Panel"
		panel.anchor_left = 0.4
		panel.anchor_right = 1.0
		panel.anchor_top = 0.0
		panel.anchor_bottom = 1.0
		_root.add_child(panel)
		var column: VBoxContainer = VBoxContainer.new()
		panel.add_child(column)
		var header: HBoxContainer = HBoxContainer.new()
		column.add_child(header)
		var title: Label = Label.new()
		title.text = "Dev menu (%s toggles)" % OS.get_keycode_string(toggle_key)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(title)
		var close_button: Button = Button.new()
		close_button.name = "Close"
		close_button.text = "Close"
		close_button.pressed.connect(close)
		header.add_child(close_button)
		_tabs = TabContainer.new()
		_tabs.name = "Tabs"
		_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
		column.add_child(_tabs)
		_dirty = true
	if _dirty:
		_rebuild()


## Builds one tab per system and the Log tab again.
func _rebuild() -> void:
	for child: Node in _tabs.get_children():
		_tabs.remove_child(child)
		child.queue_free()
	_pages = {}
	for entry: Dictionary in _systems:
		_add_system_tab(str(entry["name"]))
	_log_view = RichTextLabel.new()
	_log_view.name = LOG_TAB
	_log_view.scroll_following = true
	_log_view.selection_enabled = true
	_tabs.add_child(_log_view)
	_dirty = false
	refresh()


func _add_system_tab(system_name: String) -> void:
	var page: VBoxContainer = VBoxContainer.new()
	page.name = system_name.validate_node_name()
	_tabs.add_child(page)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, system_name)
	var actions: HFlowContainer = HFlowContainer.new()
	actions.name = "Actions"
	page.add_child(actions)
	for action: Dictionary in actions_of(system_name):
		actions.add_child(_action_row(system_name, action))
	var result: Label = Label.new()
	result.name = "Result"
	page.add_child(result)
	page.add_child(HSeparator.new())
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(scroll)
	var inspector: Label = Label.new()
	inspector.name = "Inspector"
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scroll.add_child(inspector)
	_pages[system_name] = {"page": page, "inspector": inspector, "result": result}


## One action: a field per required argument, then its button, named for the method.
func _action_row(system_name: String, action: Dictionary) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "Row_" + str(action["method"])
	var fields: Array[Control] = []
	for arg: Dictionary in action["args"]:
		var field: Control = _field_for(int(arg["type"]))
		if field != null:
			field.name = str(arg["name"]).validate_node_name()
			field.tooltip_text = str(arg["name"])
			row.add_child(field)
			fields.append(field)
	var button: Button = Button.new()
	button.name = str(action["method"])
	button.text = str(action["label"])
	button.disabled = not bool(action["supported"])
	button.pressed.connect(_on_action_pressed.bind(system_name, str(action["method"]), fields))
	row.add_child(button)
	return row


func _field_for(type: int) -> Control:
	if type == TYPE_INT or type == TYPE_FLOAT:
		var spin: SpinBox = SpinBox.new()
		spin.min_value = -1000000000.0
		spin.max_value = 1000000000.0
		spin.step = 1.0 if type == TYPE_INT else 0.01
		spin.custom_minimum_size = Vector2(90.0, 0.0)
		return spin
	if type == TYPE_STRING:
		var edit: LineEdit = LineEdit.new()
		edit.custom_minimum_size = Vector2(110.0, 0.0)
		return edit
	if type == TYPE_BOOL:
		return CheckBox.new()
	return null


func _on_action_pressed(system_name: String, method: String, fields: Array[Control]) -> void:
	var args: Array = []
	var index: int = 0
	for arg: Dictionary in _action_args(system_name, method):
		var field: Control = fields[index]
		index += 1
		match int(arg["type"]):
			TYPE_INT:
				args.append(int((field as SpinBox).value))
			TYPE_FLOAT:
				args.append((field as SpinBox).value)
			TYPE_STRING:
				args.append((field as LineEdit).text)
			TYPE_BOOL:
				args.append((field as CheckBox).button_pressed)
	run_action(system_name, method, args)


func _action_args(system_name: String, method: String) -> Array[Dictionary]:
	for action: Dictionary in actions_of(system_name):
		if str(action["method"]) == method:
			var args: Array[Dictionary] = []
			args.assign(action["args"])
			return args
	return []


# --- helpers ------------------------------------------------------------------------------------

func _entry(system_name: String) -> Dictionary:
	for entry: Dictionary in _systems:
		if str(entry["name"]) == system_name:
			return entry
	return {}


## The registered node, or null when it was freed (or the system is unknown).
func _live(entry: Dictionary) -> Object:
	if entry.is_empty():
		return null
	var node: Variant = entry["node"]
	return node if is_instance_valid(node) else null


func _log_object() -> Object:
	if log_source != null and is_instance_valid(log_source):
		return log_source if log_source.has_method("tail") else null
	if not is_inside_tree():
		return null
	var found: Node = get_node_or_null(log_source_path)
	return found if found != null and found.has_method("tail") else null


## Logs an action to the play log (numbers and booleans by value; typed text only as a length,
## since logs never hold what a person typed).
func _log_action(system_name: String, method: String, args: Array) -> void:
	var source: Object = _log_object()
	if source == null or not source.has_method("log_event"):
		return
	var shown: Array = []
	for value: Variant in args:
		shown.append(value if (value is int or value is float or value is bool) else "<text>")
	source.call("log_event", "devmenu", "devmenu.action", "dev menu: %s.%s(%s)" % [system_name, method,
		", ".join(PackedStringArray(shown.map(func(value: Variant) -> String: return str(value))))],
		{"system": system_name, "action": method, "args": shown})


func _shorten(text: String) -> String:
	var one_line: String = text.replace("\n", " ")
	return one_line if one_line.length() <= MAX_VALUE_CHARS else one_line.substr(0, MAX_VALUE_CHARS) + "..."
