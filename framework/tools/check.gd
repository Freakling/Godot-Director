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
##
## tools/check.sh may split the work for a parallel run (`--jobs N`): `-- --no-tests` does everything
## but the tests, and `-- --tests <k> <n>` runs only the k-th of n jobs (k from 1). By default each
## job takes a contiguous group of the sorted test files, in file order. With [tests] balance=true
## (opt-in) every job works out the same deal from .godot/godot-director/test-times.tsv (written by
## tools/check.sh on every run; per line a path, its whole time in seconds (lowered to the sum of
## its shards when a split run finished them all, never raised by one), the shard count of its last run and that run's longest
## shard in seconds; an older line of path and seconds reads as a whole time): units go out heaviest first, files with no time first of all, each to the
## job with the least time so far. Then a file whose whole time is over [tests] split_over seconds
## (default 0, off) becomes K shards, K = min(n, ceil(whole / split_over), its test count), its
## test_* methods dealt round-robin in the order listed here, unless a line `# gdir: no-split` is
## among its first ten lines; a shard weighs the stored longest shard when the stored count is K,
## else whole / K. A shard creates a fresh instance and calls before_each for each test, as a whole
## file does. Each file's or shard's time is printed as `GDIR-TIME: <ms> <path>`, a shard's also as
## `GDIR-SHARDS: <K> <path>`, and job 1 prints the deal as
## `GDIR-DEAL: <job> <seconds or ?> <path>[ shard <i>/<K>]`.

const CONFIG_PATH: String = "res://tools/check.cfg"
const TYPED_SETTING: String = "debug/gdscript/warnings/untyped_declaration"
const CHECK_META: StringName = &"godot_director_check"
const OLD_CHECK_META: StringName = &"claude4godot_check"   # deprecated: remove in 4.0
const TIMES_PATH: String = "res://.godot/godot-director/test-times.tsv"
const NO_SPLIT_MARKER: String = "# gdir: no-split"
const NO_SPLIT_LINES: int = 10
var _failures: PackedStringArray = PackedStringArray()
var _notes: PackedStringArray = PackedStringArray()
var _counts: Dictionary = {}
var _tests_passed: int = 0
var _screens_scanned: int = 0
var _frame: int = 0
var _reported: bool = false
var _run_tests_on: bool = true
var _run_rest_on: bool = true
var _group: int = 1
var _groups: int = 1

var _skip: PackedStringArray = PackedStringArray(["addons", "script_templates"])
var _screen_dirs: PackedStringArray = PackedStringArray()
var _screen_known: PackedStringArray = PackedStringArray()
var _screen_forbidden: PackedStringArray = PackedStringArray([
	"\\brandi\\s*\\(", "\\brandf\\s*\\(", "\\brandi_range\\s*\\(", "\\brandf_range\\s*\\(",
	"\\brandfn\\s*\\(", "\\bRandomNumberGenerator\\b", "\\.shuffle\\s*\\(", "\\.pick_random\\s*\\(",
])
var _allow_writes_to: PackedStringArray = PackedStringArray()
var _tests_dir: String = "tests"
var _balance: bool = false
var _split_over: float = 0.0
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
	_read_args()
	_read_config()
	var files: Array[String] = []
	_collect("res://", files)
	files.sort()
	if _run_rest_on:
		_load_all(files)
		_check_screens(files)
	if _run_tests_on:
		_run_tests(files)
	_report()


func _read_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--no-tests"):
		_run_tests_on = false
	var at: int = args.find("--tests")
	if at >= 0 and at + 2 < args.size():
		_run_rest_on = false
		_group = maxi(1, int(args[at + 1]))
		_groups = maxi(_group, int(args[at + 2]))


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
	_balance = str(config.get_value("tests", "balance", _balance)).to_lower() == "true"
	_split_over = maxf(0.0, str(config.get_value("tests", "split_over", _split_over)).to_float())
	# tools/check.sh reads these lines and ignores matching output (printed once, by the main run).
	if not _run_rest_on:
		return
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
	var test_files: Array[String] = []
	for path: String in files:
		if path.begins_with(tests_root) and path.get_file().begins_with("test_") and path.get_extension() == "gd":
			test_files.append(path)
	if _groups <= 1:
		for path: String in test_files:
			var started: int = Time.get_ticks_msec()
			_run_test_file(path)
			print("GDIR-TIME: %d %s" % [Time.get_ticks_msec() - started, path])
		return
	var units: Array[Dictionary] = _deal(test_files) if _balance else _file_order(test_files)
	var mine: Array[Dictionary] = []
	var expected_ms: float = 0.0
	for unit: Dictionary in units:
		if _group == 1:
			var known: bool = float(unit["ms"]) >= 0.0
			print("GDIR-DEAL: %d %s %s" % [int(unit["job"]), ("%.3f" % (float(unit["ms"]) / 1000.0)) if known else "?", _unit_name(unit)])
		if int(unit["job"]) == _group:
			mine.append(unit)
			expected_ms += float(unit["weight"])
	if not _balance:
		if not mine.is_empty():
			print("GDIR-GROUP: %s to %s (%d of %d test files)" % [mine[0]["path"], mine[-1]["path"], mine.size(), units.size()])
	else:
		print("GDIR-GROUP: %d of %d test units (about %.0f s by the last run)" % [mine.size(), units.size(), expected_ms / 1000.0])
	for unit: Dictionary in mine:
		var started: int = Time.get_ticks_msec()
		_run_test_file(str(unit["path"]), int(unit["shard"]), int(unit["shards"]))
		print("GDIR-TIME: %d %s" % [Time.get_ticks_msec() - started, unit["path"]])
		if int(unit["shards"]) > 1:
			print("GDIR-SHARDS: %d %s" % [int(unit["shards"]), unit["path"]])


## The default parallel split: contiguous groups of the test files in file order, whole files only.
func _file_order(test_files: Array[String]) -> Array[Dictionary]:
	var times: Dictionary = _read_times({})
	var units: Array[Dictionary] = []
	for job: int in range(1, _groups + 1):
		var first: int = floori(test_files.size() * (job - 1) / float(_groups))
		var last: int = floori(test_files.size() * job / float(_groups))
		for order: int in range(first, last):
			var ms: float = float(times.get(test_files[order], -1.0))
			units.append({
				"path": test_files[order], "order": order, "shard": 0, "shards": 1, "ms": ms,
				"weight": maxf(0.0, ms), "job": job,
			})
	return units


## The balanced run's work units in deal order, each with the job it goes to (from 1). The same
## inputs give the same deal in every process.
func _deal(test_files: Array[String]) -> Array[Dictionary]:
	var split_runs: Dictionary = {}
	var times: Dictionary = _read_times(split_runs)
	var known_total: float = 0.0
	var known_count: int = 0
	for path: String in test_files:
		if times.has(path):
			known_total += float(times[path])
			known_count += 1
	# A file with no time yet weighs the average of the others (1 s when none has one).
	var unknown_weight: float = known_total / known_count if known_count > 0 else 1000.0
	var units: Array[Dictionary] = []
	for order: int in test_files.size():
		var path: String = test_files[order]
		var ms: float = float(times.get(path, -1.0))
		var shards: int = 1
		if ms >= 0.0 and _split_over > 0.0 and ms > _split_over * 1000.0 and not _no_split(path):
			shards = mini(_groups, ceili(ms / (_split_over * 1000.0)))
			if shards > 1:
				var test_script: GDScript = ResourceLoader.load(path) as GDScript
				if test_script != null and test_script.can_instantiate():
					shards = mini(shards, _test_names(test_script).size())
				else:
					shards = 1
			shards = maxi(1, shards)
		var unit_ms: float = ms / shards if ms >= 0.0 else -1.0
		# A split run measured each shard of this count: its longest shard is the better guess.
		var last_split: Array = split_runs.get(path, [1, 0.0])
		if shards > 1 and int(last_split[0]) == shards:
			unit_ms = float(last_split[1])
		for shard: int in shards:
			units.append({
				"path": path, "order": order, "shard": shard, "shards": shards, "ms": unit_ms,
				"weight": maxf(1.0, unit_ms if ms >= 0.0 else unknown_weight),
			})
	units.sort_custom(_unit_before)
	var loads: Array[float] = []
	for job: int in _groups:
		loads.append(0.0)
	for unit: Dictionary in units:
		var least: int = 0
		for job: int in range(1, _groups):
			if loads[job] < loads[least]:
				least = job
		unit["job"] = least + 1
		loads[least] += float(unit["weight"])
	return units


## Files with no time first (in file order), then the longest first.
func _unit_before(a: Dictionary, b: Dictionary) -> bool:
	var a_known: bool = float(a["ms"]) >= 0.0
	var b_known: bool = float(b["ms"]) >= 0.0
	if a_known != b_known:
		return not a_known
	if a_known and float(a["ms"]) != float(b["ms"]):
		return float(a["ms"]) > float(b["ms"])
	if int(a["order"]) != int(b["order"]):
		return int(a["order"]) < int(b["order"])
	return int(a["shard"]) < int(b["shard"])


func _unit_name(unit: Dictionary) -> String:
	var shards: int = int(unit["shards"])
	return str(unit["path"]) + ("" if shards <= 1 else " shard %d/%d" % [int(unit["shard"]) + 1, shards])


## Each test file's whole time in milliseconds. split_runs gets [shards, longest shard ms] for a file
## whose last run was split. Lines are tab-separated: path, whole seconds, shards, longest shard
## seconds; an older line of only a path and seconds is a whole time.
func _read_times(split_runs: Dictionary) -> Dictionary:
	var times: Dictionary = {}
	if not FileAccess.file_exists(TIMES_PATH):
		return times
	for line: String in FileAccess.get_file_as_string(TIMES_PATH).split("\n"):
		var fields: PackedStringArray = line.strip_edges().split("\t")
		if fields.size() < 2 or not fields[1].is_valid_float():
			continue
		times[fields[0]] = maxf(0.0, fields[1].to_float() * 1000.0)
		if fields.size() >= 4 and fields[2].is_valid_int() and int(fields[2]) > 1 and fields[3].is_valid_float():
			split_runs[fields[0]] = [int(fields[2]), maxf(0.0, fields[3].to_float() * 1000.0)]
	return times


func _no_split(path: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	for index: int in NO_SPLIT_LINES:
		if file.eof_reached():
			break
		if file.get_line().strip_edges() == NO_SPLIT_MARKER:
			return true
	return false


func _test_names(test_script: GDScript) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for method: Dictionary in test_script.get_script_method_list():
		var method_name: String = str(method.get("name", ""))
		if method_name.begins_with("test_") and not names.has(method_name):
			names.append(method_name)
	return names


## Runs the file's test_* methods; with shards > 1, only every shards-th one from shard (from 0).
func _run_test_file(path: String, shard: int = 0, shards: int = 1) -> void:
	if _is_other_framework(path):
		_notes.append("%s belongs to another test framework; run it from tools/check.local.sh" % path)
		return
	var test_script: GDScript = ResourceLoader.load(path) as GDScript
	if test_script == null or not test_script.can_instantiate():
		_failures.append("%s: test script doesn't compile" % path)
		return
	var names: PackedStringArray = _test_names(test_script)
	for index: int in names.size():
		if index % shards == shard:
			_run_test(test_script, path, names[index])


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
	if not _run_rest_on:
		# One group of a parallel run: tools/check.sh adds its count to the main run's line.
		for note: String in _notes:
			print("GDIR-NOTE: " + note)
		print("GDIR-TESTS: %d" % _tests_passed)
		for failure: String in _failures:
			printerr("GDIR-FAIL: " + failure)
		_reported = true
		quit(0 if _failures.is_empty() else 1)
		return
	if int(ProjectSettings.get_setting(TYPED_SETTING, 0)) != 2:
		_notes.append("statically typed GDScript isn't enforced: set %s=2 in project.godot" % TYPED_SETTING)
	for note: String in _notes:
		print("GDIR-NOTE: " + note)
	# The main run of a parallel run leaves @TESTS@ for tools/check.sh to fill in with the groups' count.
	print("GDIR: loaded %s, %s, %s · %s passed · %s scanned" % [
		_count(int(_counts.get("gd", 0)), "script"),
		_count(int(_counts.get("tscn", 0)) + int(_counts.get("scn", 0)), "scene"),
		_count(int(_counts.get("tres", 0)) + int(_counts.get("res", 0)), "resource"),
		_count(_tests_passed, "test") if _run_tests_on else "@TESTS@",
		_count(_screens_scanned, "screen script"),
	])
	for failure: String in _failures:
		printerr("GDIR-FAIL: " + failure)
	_reported = true
	quit(0 if _failures.is_empty() else 1)


func _count(amount: int, noun: String) -> String:
	return "%d %s%s" % [amount, noun, "" if amount == 1 else "s"]
