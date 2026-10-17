extends SceneTree
## Godot Director project check · framework-owned: replaced on upgrade.
##
## Run it with `bash tools/check.sh`. That wrapper runs the import pass first and afterwards scans
## Godot's output for errors this script can't see (a parse error is printed, not returned).
## Configure it in res://tools/check.cfg; don't edit this file in a project.
##
## Steps: load every script, scene and resource (also the views a game only loads when they open,
## which a run of the main scene never parses) · screen scripts hold no game rules · tests.
## While it runs, Engine.has_meta("godot_director_check") is true, so autoloads (which run too)
## can skip reading and writing player data. The 2.x name, "claude4godot_check", is set too until
## 4.0, so games not yet migrated keep working; it is deprecated.

const CONFIG_PATH: String = "res://tools/check.cfg"
const TYPED_SETTING: String = "debug/gdscript/warnings/untyped_declaration"
const CHECK_META: StringName = &"godot_director_check"
const OLD_CHECK_META: StringName = &"claude4godot_check"   # deprecated: remove in 4.0
var _failures: PackedStringArray = PackedStringArray()
var _notes: PackedStringArray = PackedStringArray()
var _counts: Dictionary = {}
var _tests_passed: int = 0
var _screens_scanned: int = 0
var _frame: int = 0
var _reported: bool = false

var _skip: PackedStringArray = PackedStringArray(["addons", "script_templates"])
var _screen_dirs: PackedStringArray = PackedStringArray()
var _screen_known: PackedStringArray = PackedStringArray()
var _screen_forbidden: PackedStringArray = PackedStringArray([
	"\\brandi\\s*\\(", "\\brandf\\s*\\(", "\\brandi_range\\s*\\(", "\\brandf_range\\s*\\(",
	"\\brandfn\\s*\\(", "\\bRandomNumberGenerator\\b", "\\.shuffle\\s*\\(", "\\.pick_random\\s*\\(",
])
var _allow_writes_to: PackedStringArray = PackedStringArray()
var _tests_dir: String = "tests"
## Test suites for other frameworks are left to tools/check.local.sh.
var _other_test_bases: PackedStringArray = PackedStringArray([
	"extends GutTest", "extends \"res://addons/gut/test.gd\"", "extends GdUnitTestSuite",
])


func _init() -> void:
	# Before any autoload's _ready runs.
	Engine.set_meta(CHECK_META, true)
	Engine.set_meta(OLD_CHECK_META, true)


func _initialize() -> void:
	# This script is compiled before autoloads are registered, so the work starts on the first
	# frame. If it stops on a runtime error, the next frame reports that instead of hanging.
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	_frame += 1
	if _frame == 1:
		_run()
	elif not _reported:
		_reported = true
		printerr("GDIR-FAIL: tools/check.gd stopped early; see the error above")
		quit(1)


func _run() -> void:
	_read_config()
	var files: Array[String] = []
	_collect("res://", files)
	files.sort()
	_load_all(files)
	_check_screens(files)
	_run_tests(files)
	_report()


# --- configuration ------------------------------------------------------------------------------

func _read_config() -> void:
	var config: ConfigFile = ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		_notes.append("no tools/check.cfg: using defaults")
		_screen_dirs = _existing_dirs(PackedStringArray(["scripts/ui", "scripts/screens", "ui", "screens"]))
		return
	_skip = _strings(config.get_value("scan", "skip", Array(_skip)))
	_screen_dirs = _strings(config.get_value("screens", "dirs", []))
	_screen_known = _strings(config.get_value("screens", "known", []))
	_screen_forbidden.append_array(_strings(config.get_value("screens", "forbidden", [])))
	_allow_writes_to = _strings(config.get_value("screens", "allow_writes_to", []))
	_tests_dir = str(config.get_value("tests", "dir", _tests_dir)).trim_prefix("res://").trim_suffix("/")
	# tools/check.sh reads these lines and ignores matching output.
	for pattern: String in _strings(config.get_value("output", "ignore", [])):
		print("GDIR-IGNORE:" + pattern)


func _strings(value: Variant) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	if value is Array or value is PackedStringArray:
		for item: Variant in value:
			var text: String = str(item).strip_edges()
			if not text.is_empty():
				result.append(text)
	elif value is String and not str(value).is_empty():
		result.append(str(value))
	return result


func _existing_dirs(candidates: PackedStringArray) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	for candidate: String in candidates:
		if DirAccess.dir_exists_absolute("res://" + candidate):
			result.append(candidate)
	return result


# --- files --------------------------------------------------------------------------------------

func _collect(dir_path: String, out: Array[String]) -> void:
	if FileAccess.file_exists(dir_path.path_join(".gdignore")):
		return
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for sub: String in dir.get_directories():
		var sub_path: String = dir_path.path_join(sub)
		if sub.begins_with(".") or _in_dirs(sub_path + "/", _skip):
			continue
		_collect(sub_path, out)
	for file: String in dir.get_files():
		out.append(dir_path.path_join(file))


func _in_dirs(path: String, dirs: PackedStringArray) -> bool:
	var relative: String = path.trim_prefix("res://")
	for entry: String in dirs:
		var prefix: String = entry.trim_prefix("res://").trim_suffix("/") + "/"
		if relative.begins_with(prefix):
			return true
	return false


# --- 1. everything loads ------------------------------------------------------------------------

func _load_all(files: Array[String]) -> void:
	for path: String in files:
		var extension: String = path.get_extension().to_lower()
		if not (extension in ["gd", "tscn", "scn", "tres", "res"]):
			continue
		var resource: Resource = ResourceLoader.load(path)
		if resource == null:
			_failures.append("%s: failed to load" % path)
			continue
		_counts[extension] = int(_counts.get(extension, 0)) + 1
		var scene: PackedScene = resource as PackedScene
		if scene != null and not scene.can_instantiate():
			_failures.append("%s: scene can't be instantiated" % path)


# --- 2. screens hold no game rules --------------------------------------------------------------

func _check_screens(files: Array[String]) -> void:
	if _screen_dirs.is_empty():
		_notes.append("no screen folders set: the screens rule isn't checked (tools/check.cfg › [screens] dirs)")
		return
	var patterns: Array[RegEx] = []
	for source: String in _screen_forbidden:
		var regex: RegEx = RegEx.create_from_string(source)
		if regex == null or not regex.is_valid():
			_failures.append("tools/check.cfg: invalid pattern %s" % source)
			continue
		patterns.append(regex)
	for autoload: String in _autoload_names():
		if _allow_writes_to.has(autoload):
			continue
		# `Autoload.field = …`, `Autoload.field.x += …`, `Autoload.list[i] = …`, but not `==`, and not
		# a capitalised inner type or constant (`var s: Autoload.Store = …`).
		var write: String = "(?<![\\w.])%s\\.[a-z_]\\w*(\\.\\w+|\\[[^\\]]*\\])*\\s*[-+*/%%]?=(?!=)" % autoload
		patterns.append(RegEx.create_from_string(write))

	for path: String in files:
		if path.get_extension() != "gd" or not _in_dirs(path, _screen_dirs):
			continue
		_screens_scanned += 1
		var known: bool = _screen_known.has(path.trim_prefix("res://"))
		var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
		for index: int in lines.size():
			var code: String = _code_only(lines[index])
			for regex: RegEx in patterns:
				var found: RegExMatch = regex.search(code)
				if found == null:
					continue
				# `var x: Autoload.thing = …` declares a type; it doesn't write to the autoload.
				if code.substr(0, found.get_start()).strip_edges(false, true).ends_with(":"):
					continue
				var where: String = "%s:%d: screen script does `%s`" % [path, index + 1, found.get_string().strip_edges()]
				if known:
					_notes.append(where + " (known: listed in tools/check.cfg › [screens] known)")
				else:
					_failures.append(where + "; randomness and state changes belong in a system (tools/check.cfg › [screens])")


func _autoload_names() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for property: Dictionary in ProjectSettings.get_property_list():
		var key: String = str(property.get("name", ""))
		# A value starting with "*" means the autoload is registered as a global name.
		if key.begins_with("autoload/") and str(ProjectSettings.get_setting(key, "")).begins_with("*"):
			names.append(key.trim_prefix("autoload/"))
	return names


## The line with comments removed and string contents blanked, so text inside strings and
## comments never matches a pattern.
func _code_only(line: String) -> String:
	var result: String = ""
	var quote: String = ""
	var index: int = 0
	while index < line.length():
		var character: String = line[index]
		if quote.is_empty():
			if character == "#":
				break
			if character == "\"" or character == "'":
				quote = character
			result += character
		elif character == "\\":
			result += "  "
			index += 1
		elif character == quote:
			quote = ""
			result += character
		else:
			result += " "
		index += 1
	return result


# --- 3. tests -----------------------------------------------------------------------------------

func _run_tests(files: Array[String]) -> void:
	var tests_root: String = "res://%s/" % _tests_dir
	for path: String in files:
		var file_name: String = path.get_file()
		if not path.begins_with(tests_root) or not file_name.begins_with("test_") or path.get_extension() != "gd":
			continue
		if _is_other_framework(path):
			_notes.append("%s belongs to another test framework; run it from tools/check.local.sh" % path)
			continue
		var test_script: GDScript = ResourceLoader.load(path) as GDScript
		if test_script == null or not test_script.can_instantiate():
			_failures.append("%s: test script doesn't compile" % path)
			continue
		var names: PackedStringArray = PackedStringArray()
		for method: Dictionary in test_script.get_script_method_list():
			var method_name: String = str(method.get("name", ""))
			if method_name.begins_with("test_") and not names.has(method_name):
				names.append(method_name)
		for method_name: String in names:
			_run_test(test_script, path, method_name)


func _is_other_framework(path: String) -> bool:
	var source: String = FileAccess.get_file_as_string(path)
	for marker: String in _other_test_bases:
		if source.contains(marker):
			return true
	return false


## One fresh instance per test, so no state leaks from one test to the next.
func _run_test(test_script: GDScript, path: String, method_name: String) -> void:
	var instance: Object = test_script.new()
	if instance == null or not instance.has_method("_gdir_begin"):
		_failures.append("%s: a test file must start with extends \"res://tools/test_case.gd\" and need no _init arguments" % path)
		return
	# A runtime error inside a test prints SCRIPT ERROR after this line; check.sh fails on it.
	print("GDIR-TEST: %s::%s" % [path, method_name])
	instance.call("_gdir_begin")
	instance.call("before_each")
	var result: Variant = instance.call(method_name)
	var errors: PackedStringArray = instance.call("_gdir_end")
	if result is Object and (result as Object).get_class() == "GDScriptFunctionState":
		errors.append("tests must be synchronous (no await): its checks would run after the check ended")
	if errors.is_empty():
		_tests_passed += 1
	for message: String in errors:
		_failures.append("%s::%s: %s" % [path, method_name, message])


# --- report -------------------------------------------------------------------------------------

func _report() -> void:
	if int(ProjectSettings.get_setting(TYPED_SETTING, 0)) != 2:
		_notes.append("statically typed GDScript isn't enforced: set %s=2 in project.godot" % TYPED_SETTING)
	for note: String in _notes:
		print("GDIR-NOTE: " + note)
	print("GDIR: loaded %s, %s, %s · %s passed · %s scanned" % [
		_count(int(_counts.get("gd", 0)), "script"),
		_count(int(_counts.get("tscn", 0)) + int(_counts.get("scn", 0)), "scene"),
		_count(int(_counts.get("tres", 0)) + int(_counts.get("res", 0)), "resource"),
		_count(_tests_passed, "test"),
		_count(_screens_scanned, "screen script"),
	])
	for failure: String in _failures:
		printerr("GDIR-FAIL: " + failure)
	_reported = true
	quit(0 if _failures.is_empty() else 1)


func _count(amount: int, noun: String) -> String:
	return "%d %s%s" % [amount, noun, "" if amount == 1 else "s"]
