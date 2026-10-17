extends Node
## The play log base · framework-owned: replaced on upgrade.
##
## The project's PlayLog autoload, res://tools/play_log.gd, extends this file and fills the hooks
## below. Register it first under [autoload] in project.godot, PlayLog="*res://tools/play_log.gd",
## so the other autoloads can log from their _ready. It ships in every build, debug and release, so
## players' reports carry it. Don't edit this file in a project.
##
## One call, two sinks. log_event(category, event, text, data) writes one line to
## <log_dir>/run-<datetime>.log for people:
##     HH:MM:SS T<turn> [category] text
## and one to the .jsonl file beside it, which the tools read:
##     {"t": ms, "turn": n, "cat": "...", "event": "<stable_id>", "text": "...", "data": {...}}
## `event` is a stable id (lower case, dot-separated, such as "trade.buy") that tools match on; `text`
## is free to change. `t` is milliseconds since the game started. Each line is flushed as it's
## written, so a crash keeps everything logged up to it.
##
## A run's files. Until the game decides the run, lines are held and stamped T- (turn null in the
## JSONL). begin_run() starts a new pair of files with the held lines and returns the run id to keep
## in the run save; continue_run(id) appends to that run's files and drops the held lines (engine
## errors and warnings are kept), so a throwaway boot is never mistaken for turn 0. Each file starts
## its session with a header: build version, Godot version, OS, debug or release, the command line,
## _session_extras() (the settings, secrets left out) and a resource count per folder of data_dir.
## Only the newest keep_files runs are kept. A launch that ends before any run began keeps its lines
## in boot-<datetime>.log and .jsonl instead, the newest keep_boot_files of them, so it never pushes
## a real run out.
##
## What the project does: fill _session_extras(), _build_snapshot(), progress_block_reason() and
## _install_id(); call begin_run() or continue_run(); call set_turn() as turns pass and log_snapshot()
## at each point the player may act; give the shell's view_changed(name) signal to watch_views() (or
## call log_view()); give the main progress button (End Turn, Next Day) to watch_progress_button().
##
## Built in, for every game: engine errors and warnings (a Logger, Godot 4.5+, with the top script
## frame; call stacks need debug/settings/gdscript/always_track_call_stacks in release builds),
## InputMap actions pressed (by name, polled once per frame, never typed text), window and focus changes, frame
## hitches over hitch_threshold_ms, orphan-node counts at snapshots (debug builds), the progress
## button's blocked state whenever it changes, and every press with what blocked it. A run that
## starts without a view change gets the current view as its first view.changed line (_current_view()),
## so the log and its review always carry the first view.
##
## Privacy. Every line is scrubbed here: the OS user name, the home folder, the install id and the
## values of secret settings never reach the files. Nothing is sent anywhere.
##
## Nothing is written under the check or a capture (the godot_director_check and
## godot_director_capture metas), or when a tool script runs the project (--script), unless autoplay
## asks for the log (the godot_director_autoplay meta). start_capture() records into memory, also
## under the check, so tests can assert on the lines; tail() keeps the recent lines for a dev menu.

const CHECK_META: StringName = &"godot_director_check"
const CAPTURE_META: StringName = &"godot_director_capture"
## Autoplay sets it to keep the log on during its runs, which point user:// at their own folder.
const AUTOPLAY_META: StringName = &"godot_director_autoplay"
const EVENT_ID: String = "^[a-z][a-z0-9_]*(\\.[a-z0-9_]+)*$"
const MAX_HELD: int = 5000
const RUN_ID: String = "^\\d{8}-\\d{6}(-\\d+)?$"

## Where the run files go. The base needs nothing else from user://.
var log_dir: String = "user://logs/play"
## How many runs' files are kept, the newest.
var keep_files: int = 20
## How many boot-only files (launches that ended before a run began) are kept, the newest.
var keep_boot_files: int = 5
## A frame that takes longer than this is logged as a hitch.
var hitch_threshold_ms: int = 250
## How many times one engine error (the same message and place) is logged in a session.
var max_engine_repeats: int = 20
## How many recent text lines tail() keeps.
var tail_size: int = 200
## A run's files get its first view if the shell hasn't announced one by this many frames after
## begin_run() or continue_run(): the view _current_view() names (see there).
var first_view_frames: int = 3
## The folder whose resources the session header counts, per subfolder.
var data_dir: String = "res://data"
## Parts of a setting's name (any case) that mark it secret: it's left out of the header, and its
## value is scrubbed from every line.
var secret_names: PackedStringArray = ["secret", "token", "password", "passwd", "_key", "apikey",
	"auth", "credential", "_id", "uuid", "guid", "account", "email"]
## The built-in ui_* actions that are logged when pressed; the game's own actions always are.
var logged_ui_actions: PackedStringArray = ["ui_accept", "ui_cancel", "ui_up", "ui_down", "ui_left",
	"ui_right", "ui_focus_next", "ui_focus_prev", "ui_page_up", "ui_page_down"]

## The current turn, set with set_turn().
var turn: int = 0
## The current run's id, "" until begin_run() or continue_run().
var run_id: String = ""

var _pending: bool = true
var _held: Array[Dictionary] = []
var _log_file: FileAccess = null
var _jsonl_file: FileAccess = null
var _capturing: bool = false
var _captured: Array[Dictionary] = []
var _tail: PackedStringArray = PackedStringArray()
var _engine: EngineLog = null
var _scrubs: Array[PackedStringArray] = []
var _scrubs_built: bool = false
var _user_pattern: RegEx = null
var _secret_values: PackedStringArray = PackedStringArray()
var _event_pattern: RegEx = RegEx.create_from_string(EVENT_ID)
var _warned_ids: Dictionary = {}
var _actions: PackedStringArray = PackedStringArray()
var _actions_ready: bool = false
var _view: String = ""
var _view_written: bool = false
var _first_view_wait: int = 0
var _screen_ids: Dictionary = {}
var _screens_read: bool = false
var _block_known: bool = false
var _block: String = ""
var _frames: int = 0
var _ended: bool = false
var _issued: PackedStringArray = PackedStringArray()
var _file_name: String = ""
var _engine_seen: Dictionary = {}


# --- hooks the project fills --------------------------------------------------------------------

## Added to the session header, one line per key: the settings ({"settings": Settings.to_dict()})
## and whatever else describes this session, such as whether the failsafe start is on. Keys named
## as secret_names says are left out, and their values scrubbed.
func _session_extras() -> Dictionary:
	return {}


## The state at a point the player may act, for log_snapshot(): resources, what is queued, available
## and blocking. Keep it small, and plain data.
func _build_snapshot() -> Dictionary:
	return {}


## Why the player can't continue right now (End Turn, Next Day): "" when they can. Polled every
## frame while a run is on, so keep it cheap.
func progress_block_reason() -> String:
	return ""


## The name of the view the player sees now, for a run that starts without a view change: its files
## then get this view as their first view.changed line, so a log and its review always carry the
## first view. By default the current scene's catalog id (tools/ui_screens.gd), else its node name in
## snake_case, as the autoplay adapter's current_view() names it. A game whose shell swaps views
## inside one scene overrides it. "" names nothing.
func _current_view() -> String:
	var scene: Node = get_tree().current_scene if is_inside_tree() else null
	if scene == null or not is_instance_valid(scene):
		return ""
	if not _screens_read:
		_screens_read = true
		_read_screens()
	return str(_screen_ids.get(scene.scene_file_path, scene.name.to_snake_case()))


## The game's install id, if it has one, so it's scrubbed from every line.
func _install_id() -> String:
	return ""


# --- logging ------------------------------------------------------------------------------------

## Logs one line to both files. `event` is a stable id: lower case, dots between parts.
func log_event(category: String, event: String, text: String, data: Dictionary = {}) -> void:
	if not _event_pattern.search(event) and not _warned_ids.has(event):
		_warned_ids[event] = true
		push_warning("PlayLog: '%s' isn't a stable event id (lower case, dots between parts)" % event)
	var line: Dictionary = {
		"t": Time.get_ticks_msec(),
		"turn": null if _pending else turn,
		"cat": _one_line(category).replace("]", ")"),
		"event": event,
		"text": _scrub(_one_line(text)),
		"data": _scrub_value(data),
	}
	var clock: String = Time.get_time_string_from_system()
	if event == "view.changed":
		_view_written = true
	_record(line, clock)
	if _pending:
		if _held.size() < MAX_HELD:
			_held.append({"line": line, "clock": clock})
	else:
		_write(line, clock)


## Logs the project's _build_snapshot(), plus the orphan-node count in debug builds. Call it at each
## point the player may act: the start of a turn or phase.
func log_snapshot() -> void:
	var data: Dictionary = _build_snapshot().duplicate(true)
	if OS.is_debug_build():
		data["orphan_nodes"] = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	log_event("snapshot", "snapshot", _describe(data), data)


func set_turn(value: int) -> void:
	turn = value


## Logs a view change. watch_views() calls it for the shell's view_changed(name) signal.
func log_view(view_name: String) -> void:
	if view_name == _view:
		return
	log_event("view", "view.changed", view_name, {"view": view_name, "from": _view})
	_view = view_name


## Logs every view change the shell (or any node) announces with a view_changed(name) signal.
func watch_views(shell: Object, signal_name: StringName = &"view_changed") -> void:
	shell.connect(signal_name, log_view)


## Logs every press of the main progress button, with what blocked it, also while it's disabled.
func watch_progress_button(button: BaseButton) -> void:
	button.gui_input.connect(_on_progress_input)


## Logs a press of the progress button with progress_block_reason(). watch_progress_button() calls
## it; call it yourself for a press that arrives another way, such as a shortcut.
func log_progress_press() -> void:
	var reason: String = progress_block_reason()
	if reason.is_empty():
		log_event("progress", "progress.pressed", "pressed")
	else:
		log_event("progress", "progress.pressed_blocked", "pressed while blocked: " + reason, {"blocked": reason})


## Logs the progress button's state when it changed since the last call. Called every frame while a
## run is on; tests call it directly.
func check_progress() -> void:
	var reason: String = progress_block_reason()
	if _block_known and reason == _block:
		return
	_block_known = true
	_block = reason
	if reason.is_empty():
		log_event("progress", "progress.unblocked", "can continue")
	else:
		log_event("progress", "progress.blocked", "blocked: " + reason, {"reason": reason})


## Logs the engine errors and warnings caught since the last call. Called every frame; tests call
## it directly after the error they expect.
func flush_engine_log() -> void:
	if _engine == null:
		return
	for entry: Dictionary in _engine.take():
		var warning: bool = int(entry["type"]) == Logger.ERROR_TYPE_WARNING
		var where: String = str(entry["file"])
		if int(entry["line"]) >= 0:
			where += ":%d" % int(entry["line"])
		if not str(entry["function"]).is_empty():
			where += " in %s()" % str(entry["function"])
		var data: Dictionary = {
			"kind": ["error", "warning", "script", "shader"][clampi(int(entry["type"]), 0, 3)],
			"message": entry["message"], "file": entry["file"], "line": entry["line"],
			"function": entry["function"],
		}
		# The same error every frame (a failing hook, say) would flood the files: after
		# max_engine_repeats, one line says it keeps happening, and the rest are counted in memory only.
		var key: String = "%s|%s" % [entry["message"], where]
		var seen: int = int(_engine_seen.get(key, 0)) + 1
		_engine_seen[key] = seen
		if seen > max_engine_repeats + 1:
			continue
		var text: String = "%s (at %s)" % [entry["message"], where]
		if seen == max_engine_repeats + 1:
			text += " (repeated %d times; further repeats aren't logged)" % max_engine_repeats
			data["repeats_hidden"] = true
		log_event("engine warning" if warning else "engine error", "engine.warning" if warning else "engine.error", text, data)


# --- runs ---------------------------------------------------------------------------------------

## A new run: opens its files, writes the session header and the held lines, and returns the run id
## to keep in the run save, for continue_run().
func begin_run() -> String:
	_close_files()
	turn = 0
	run_id = _new_id("run-")
	_start_files("run-", run_id)
	log_event("run", "run.new", "new run " + run_id, {"run": run_id})
	_prune("run-", keep_files)
	return run_id


## A run loaded from its save: appends to that run's files (new ones if they were pruned) and drops
## the held lines, apart from engine errors and warnings.
func continue_run(id: String) -> void:
	if RegEx.create_from_string(RUN_ID).search(id) == null:
		# The id comes from a save the player can edit: anything but a run id gets new files.
		begin_run()
		log_event("run", "run.id_rejected", "the save's run id isn't one; continued in new files")
		return
	_close_files()
	run_id = id
	var held: Array[Dictionary] = _held
	_held = []
	_pending = false
	_open_files("run-", id, true)
	_view_written = false
	_view = ""
	_first_view_wait = first_view_frames
	_write_header()
	for entry: Dictionary in held:
		var line: Dictionary = entry["line"]
		if str(line["cat"]).begins_with("engine"):
			_write(line, str(entry["clock"]))
	log_event("run", "run.continue", "continued run " + id, {"run": id})


## True when this session writes files: not under the check or a capture, and not when a tool script
## runs the project, unless autoplay asks for the log.
func writes_files() -> bool:
	if Engine.has_meta(AUTOPLAY_META):
		return true
	if Engine.has_meta(CHECK_META) or Engine.has_meta(CAPTURE_META):
		return false
	return not _is_tool_run()


## The path of the current run's text log, "" when none is open.
func log_path() -> String:
	return _log_file.get_path_absolute() if _log_file != null else ""


# --- tests and the dev menu ---------------------------------------------------------------------

## Records every line from now on into memory (also under the check), for tests.
func start_capture() -> void:
	_capturing = true
	_captured = []


## Stops recording and returns the lines: the JSONL fields, plus "line", the text line.
func stop_capture() -> Array[Dictionary]:
	_capturing = false
	var lines: Array[Dictionary] = _captured
	_captured = []
	return lines


## The lines recorded so far, without stopping.
func captured() -> Array[Dictionary]:
	return _captured.duplicate()


## The most recent text lines, oldest first.
func tail(count: int = 50) -> PackedStringArray:
	return _tail.slice(maxi(0, _tail.size() - count))


# --- engine -------------------------------------------------------------------------------------

## Starts catching engine errors and warnings. Called when the node enters the tree.
func attach_engine_logger() -> void:
	if _engine == null:
		_engine = EngineLog.new()
		OS.add_logger(_engine)


func detach_engine_logger() -> void:
	if _engine != null:
		OS.remove_logger(_engine)
		_engine = null


## Godot calls a Logger from whatever thread hit the error, so it only queues them, under a mutex.
## flush_engine_log() logs them on the main thread.
class EngineLog extends Logger:
	const MAX_QUEUED: int = 1000
	var _mutex: Mutex = Mutex.new()
	var _queue: Array[Dictionary] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		var entry: Dictionary = {"type": error_type, "message": rationale if not rationale.is_empty() else code,
			"file": file, "line": line, "function": function}
		for backtrace: ScriptBacktrace in script_backtraces:
			if backtrace != null and backtrace.get_frame_count() > 0:
				entry["file"] = backtrace.get_frame_file(0)
				entry["line"] = backtrace.get_frame_line(0)
				entry["function"] = backtrace.get_frame_function(0)
				break
		_mutex.lock()
		if _queue.size() < MAX_QUEUED:
			_queue.append(entry)
		_mutex.unlock()

	func take() -> Array[Dictionary]:
		_mutex.lock()
		var entries: Array[Dictionary] = _queue
		_queue = []
		_mutex.unlock()
		return entries


# --- node ---------------------------------------------------------------------------------------

func _enter_tree() -> void:
	attach_engine_logger()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_window().size_changed.connect(_on_window_resized)
	get_viewport().gui_focus_changed.connect(_on_gui_focus_changed)


func _process(delta: float) -> void:
	flush_engine_log()
	_frames += 1
	var ms: int = roundi(delta * 1000.0)
	if _frames > 2 and ms > hitch_threshold_ms:
		log_event("hitch", "frame.hitch", "frame took %d ms" % ms, {"ms": ms})
	_log_actions()
	_log_first_view()
	if not _pending:
		check_progress()


## A run that began without the shell announcing a view gets the current one, a few frames in (the
## shell's own announcement, if it comes in that time, is the line, so the view isn't logged twice).
func _log_first_view() -> void:
	if _first_view_wait <= 0:
		return
	_first_view_wait -= 1
	if _first_view_wait > 0 or _view_written or _pending:
		return
	var view_name: String = _current_view()
	if view_name.is_empty():
		return
	log_event("view", "view.changed", view_name, {"view": view_name, "from": _view, "initial": true})
	_view = view_name


## The catalog's scenes (tools/ui_screens.gd), scene path to id, for _current_view().
func _read_screens() -> void:
	var path: String = "res://tools/ui_screens.gd"
	if not ResourceLoader.exists(path):
		return
	var script: GDScript = ResourceLoader.load(path) as GDScript
	var catalog: Variant = script.new() if script != null and script.can_instantiate() else null
	if not (catalog is RefCounted) or not (catalog as RefCounted).has_method("checked_screens"):
		return
	var checked: Array = (catalog as RefCounted).call("checked_screens")
	for screen: Dictionary in (checked[0] as Array):
		if not str(screen.get("scene", "")).is_empty():
			_screen_ids[str(screen["scene"])] = str(screen["id"])


## Logs the actions that became pressed this frame. Polled rather than read from _input, so a held
## stick logs once, and an action a node handles (set_input_as_handled) is still logged. Nothing is
## logged while a text field has focus: never what the player types.
func _log_actions() -> void:
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if not _actions_ready:
		_actions_ready = true
		for action: StringName in InputMap.get_actions():
			if not str(action).begins_with("ui_") or logged_ui_actions.has(str(action)):
				_actions.append(str(action))
	for action: String in _actions:
		if Input.is_action_just_pressed(action):
			log_event("input", "input.action", action, {"action": action})


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_IN:
			log_event("window", "window.focus", "focus in", {"focused": true})
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			log_event("window", "window.focus", "focus out", {"focused": false})
		NOTIFICATION_PREDELETE:
			detach_engine_logger()
			_close_files()


func _exit_tree() -> void:
	flush_engine_log()
	detach_engine_logger()
	if _ended:
		return
	_ended = true
	if _pending and not _held.is_empty() and writes_files():
		# A launch that ended before any run began keeps its lines in a boot file, under its own cap.
		_start_files("boot-", _new_id("boot-"))
		_prune("boot-", keep_boot_files)
	log_event("session", "session.end", "session ended")
	_close_files()


func _on_window_resized() -> void:
	var size: Vector2i = get_window().size
	log_event("window", "window.resized", "%dx%d" % [size.x, size.y], {"width": size.x, "height": size.y})


func _on_gui_focus_changed(control: Control) -> void:
	log_event("focus", "ui.focus", str(control.name), {"node": str(control.name), "path": str(control.get_path())})


func _on_progress_input(event: InputEvent) -> void:
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if (mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT) \
			or (mouse == null and event.is_action_pressed("ui_accept")):
		log_progress_press()


## True when a tool script (`--script`) runs the project, such as the check or a capture.
func _is_tool_run() -> bool:
	var args: PackedStringArray = OS.get_cmdline_args()
	return args.has("--script") or args.has("-s")


# --- files --------------------------------------------------------------------------------------

func _record(line: Dictionary, clock: String) -> void:
	var text: String = _text_line(line, clock)
	_tail.append(text)
	if _tail.size() > tail_size:
		_tail = _tail.slice(_tail.size() - tail_size)
	if _capturing:
		var entry: Dictionary = line.duplicate(true)
		entry["line"] = text
		_captured.append(entry)


func _text_line(line: Dictionary, clock: String) -> String:
	var stamp: String = "-" if line["turn"] == null else str(line["turn"])
	return "%s T%s [%s] %s" % [clock, stamp, line["cat"], line["text"]]


func _write(line: Dictionary, clock: String) -> void:
	if _log_file == null or _jsonl_file == null:
		return
	# Held lines were scrubbed before the run's settings were known: scrub them again.
	line["text"] = _scrub(str(line["text"]))
	line["data"] = _scrub_value(line["data"])
	_log_file.store_line(_text_line(line, clock))
	_log_file.flush()
	_jsonl_file.store_line(JSON.stringify(line, "", false))
	_jsonl_file.flush()


## Opens new files <prefix><id>, writes the session header, then the held lines.
func _start_files(prefix: String, id: String) -> void:
	var held: Array[Dictionary] = _held
	_held = []
	_pending = false
	_open_files(prefix, id, false)
	_view_written = false
	_view = ""
	_first_view_wait = first_view_frames
	_write_header()
	for entry: Dictionary in held:
		_write(entry["line"], str(entry["clock"]))
		if entry["line"]["event"] == "view.changed":
			_view_written = true
			_view = str((entry["line"]["data"] as Dictionary).get("view", ""))


func _open_files(prefix: String, id: String, append: bool) -> void:
	if not writes_files():
		return
	DirAccess.make_dir_recursive_absolute(log_dir)
	_file_name = prefix + id
	var base: String = log_dir.path_join(_file_name)
	_log_file = _open(base + ".log", append)
	_jsonl_file = _open(base + ".jsonl", append)
	if _log_file == null or _jsonl_file == null:
		_close_files()


func _open(path: String, append: bool) -> FileAccess:
	if append and FileAccess.file_exists(path):
		var file: FileAccess = FileAccess.open(path, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
		return file
	return FileAccess.open(path, FileAccess.WRITE)


func _close_files() -> void:
	_log_file = null   # FileAccess closes when the last reference goes
	_jsonl_file = null


func _new_id(prefix: String) -> String:
	var stamp: String = Time.get_datetime_string_from_system(false, false).replace("-", "").replace(":", "").replace("T", "-")
	var id: String = stamp
	var count: int = 1
	while FileAccess.file_exists(log_dir.path_join("%s%s.log" % [prefix, id])) or _issued.has(prefix + id):
		count += 1
		id = "%s-%02d" % [stamp, count]
	_issued.append(prefix + id)
	return id


## Keeps the newest `keep` files that start with prefix (run- or boot-), never the open one.
func _prune(prefix: String, keep: int) -> void:
	if not writes_files() or not DirAccess.dir_exists_absolute(log_dir):
		return
	var runs: PackedStringArray = PackedStringArray()
	for file_name: String in DirAccess.get_files_at(log_dir):
		if file_name.begins_with(prefix) and file_name.ends_with(".log"):
			runs.append(file_name.get_basename())
	runs.sort()   # ids sort by time
	var current: String = _file_name
	var extra: int = runs.size() - maxi(1, keep)
	for index: int in runs.size():
		if extra <= 0:
			break
		if runs[index] == current:
			continue
		DirAccess.remove_absolute(log_dir.path_join(runs[index] + ".log"))
		DirAccess.remove_absolute(log_dir.path_join(runs[index] + ".jsonl"))
		extra -= 1


func _write_header() -> void:
	var extras: Dictionary = _session_extras()
	_secret_values = PackedStringArray()
	var kept: Dictionary = _without_secrets(extras)
	_scrubs_built = false   # rebuilt with the secret values and the install id
	var version: String = str(ProjectSettings.get_setting("application/config/version", ""))
	var name_text: String = str(ProjectSettings.get_setting("application/config/name", ""))
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var info: Dictionary = {
		"game": name_text, "build": version, "godot": str(Engine.get_version_info().get("string", "")),
		"os": OS.get_name(), "os_version": OS.get_version(), "debug": OS.is_debug_build(),
		"args": " ".join(args),
	}
	log_event("session", "session.start", "%s %s · Godot %s · %s · %s · args: %s" % [
		name_text, version if not version.is_empty() else "(no version)", info["godot"], info["os"],
		"debug" if OS.is_debug_build() else "release", info["args"] if not args.is_empty() else "(none)"], info)
	for key: Variant in kept:
		var value: Variant = kept[key]
		log_event("session", "session.extra", "%s: %s" % [key, _describe(value) if value is Dictionary else str(value)],
			{"name": str(key), "value": value})
	var counts: Dictionary = {}
	_count_resources(data_dir, counts)
	var parts: PackedStringArray = PackedStringArray()
	for folder: Variant in counts:
		parts.append("%s=%d" % [folder, int(counts[folder])])
	log_event("session", "session.resources", "resources: " + (", ".join(parts) if not parts.is_empty() else "(none)"), counts)


func _count_resources(dir: String, counts: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	var count: int = 0
	for entry: String in ResourceLoader.list_directory(dir):
		if entry.ends_with("/"):
			_count_resources(dir.path_join(entry.trim_suffix("/")), counts)
		elif entry.get_extension() in ["tres", "res"]:
			count += 1
	if count > 0:
		counts[dir.trim_prefix("res://")] = count


# --- scrubbing ----------------------------------------------------------------------------------

func _is_secret(key: String) -> bool:
	var lower: String = key.to_lower()
	for part: String in secret_names:
		if lower.contains(part.to_lower()):
			return true
	return false


## A copy without secret keys, at any depth; their string values are kept aside for scrubbing.
func _without_secrets(value: Variant) -> Variant:
	if value is Dictionary:
		var source: Dictionary = value
		var result: Dictionary = {}
		for key: Variant in source:
			if _is_secret(str(key)):
				_collect_secrets(source[key])
				continue
			result[key] = _without_secrets(source[key])
		return result
	if value is Array:
		var items: Array = []
		for item: Variant in value:
			items.append(_without_secrets(item))
		return items
	return value


func _collect_secrets(value: Variant) -> void:
	if value is Dictionary:
		var source: Dictionary = value
		for item: Variant in source.values():
			_collect_secrets(item)
	elif value is Array:
		for item: Variant in value:
			_collect_secrets(item)
	elif (value is String or value is StringName) and str(value).length() >= 4:
		_secret_values.append(str(value))   # a boolean or number would blank ordinary words and digits


func _scrub(text: String) -> String:
	if not _scrubs_built:
		_build_scrubs()
	var result: String = text
	for pair: PackedStringArray in _scrubs:
		result = result.replacen(pair[0], pair[1])
	if _user_pattern != null:
		result = _user_pattern.sub(result, "<user>", true)
	return result


func _scrub_value(value: Variant) -> Variant:
	if value is String or value is StringName:
		return _scrub(str(value))
	if value is Dictionary:
		var source: Dictionary = value
		var result: Dictionary = {}
		for key: Variant in source:
			result[key] = _scrub_value(source[key])
		return result
	if value is Array:
		var items: Array = []
		for item: Variant in value:
			items.append(_scrub_value(item))
		return items
	return value


## The text replaced in every line, longest first: home folders (in each slash style) become ~,
## the install id <install-id>, secret values <secret>. The user name, as a whole word, <user>.
func _build_scrubs() -> void:
	var pairs: Array[PackedStringArray] = []
	for variable: String in ["HOME", "USERPROFILE"]:
		var home: String = OS.get_environment(variable).strip_edges().trim_suffix("/").trim_suffix("\\")
		if home.length() < 3:
			continue
		var forward: String = home.replace("\\", "/")
		for form: String in [home, forward, forward.replace("/", "\\")]:
			pairs.append(PackedStringArray([form, "~"]))
		if forward.length() > 2 and forward[1] == ":":   # C:/Users/x as Git Bash writes it: /c/Users/x
			pairs.append(PackedStringArray(["/" + forward[0].to_lower() + forward.substr(2), "~"]))
	var install: String = _install_id().strip_edges()
	if install.length() >= 4:
		pairs.append(PackedStringArray([install, "<install-id>"]))
	for secret: String in _secret_values:
		pairs.append(PackedStringArray([secret, "<secret>"]))
	pairs.sort_custom(func(a: PackedStringArray, b: PackedStringArray) -> bool: return a[0].length() > b[0].length())
	_scrubs = pairs
	_scrubs_built = true
	_user_pattern = null
	for variable: String in ["USERNAME", "USER"]:
		var user: String = OS.get_environment(variable).strip_edges()
		if user.length() >= 3:   # shorter names would blank ordinary words
			_user_pattern = RegEx.create_from_string("(?i)(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % _escape(user))
			break


func _escape(text: String) -> String:
	var result: String = ""
	for character: String in text:
		result += ("\\" + character) if "\\^$.|?*+()[]{}".contains(character) else character
	return result


# --- text ---------------------------------------------------------------------------------------

func _one_line(text: String) -> String:
	return text.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")


## key=value pairs for a line's text; nested values as JSON.
func _describe(value: Variant) -> String:
	if not value is Dictionary:
		return str(value)
	var source: Dictionary = value
	var parts: PackedStringArray = PackedStringArray()
	for key: Variant in source:
		var item: Variant = source[key]
		var shown: String = JSON.stringify(item, "", false) if (item is Dictionary or item is Array) else str(item)
		parts.append("%s=%s" % [key, shown])
	return " ".join(parts)
