extends SceneTree
## Autoplay: the game plays itself · framework-owned: replaced on upgrade.
##
## Run it with `bash tools/autoplay.sh <scenario>`, which finds Godot, points user:// at a temporary
## folder and reads this script's output. It launches the real game through its main scene with
## Engine.has_meta("godot_director_autoplay") set, and drives it only through the game's adapter,
## res://tools/autoplay_adapter.gd (which extends tools/autoplay_adapter_base.gd): ui actions by real
## input (a click at the centre of the control's rect in the element map, or a key or pad button of
## an InputMap action), api actions through perform(). The scenarios are in
## res://tools/autoplay_scenarios.gd (which extends tools/autoplay_catalog.gd); a smoke scenario is
## required. The project's own invariants are in res://tools/autoplay_invariants.gd.
##
## Each run writes to playtesting/autoplay/<scenario>-<seed>-<datetime>/ (gitignored):
## - the play log's run-<datetime>.log and .jsonl (the PlayLog autoload writes them there, because
##   autoplay sets its log_dir), with a line per step (`autoplay.step`), per finding
##   (`autoplay.finding`) and per screenshot (`screenshot`);
## - `<step>-<reason>.png`, `.elements.json` and `.map.png` at the run's start, every view change,
##   every snapshot, every progress block, every finding and the end (with --no-images, headless,
##   the element maps only). A step's reasons share one rendered frame.
## - repro.json on any finding: the scenario, seed, size, every action so far and each finding with
##   its step, screenshot and the save written before that step (saves/before-<step>.save, through
##   the adapter's save_run(), when the game has saves). `--replay <run folder> [--until <step>]`
##   plays the scenario again into a new folder ending in -replay, with the run's seeds and each
##   step's recorded action, so expects and smoke's own checks are made again. With --from-save it
##   loads the save before the first finding that has one (the adapter's load_save()) and replays
##   the recorded actions from that step, with the same step numbers.
##
## The framework's invariants, checked after every step: no engine or script error (from the play
## log's Logger); progress isn't blocked across softlock_actions actions while nothing offered
## unblocks it (softlock); list_actions() isn't empty before the run is over (no-actions); the view
## the shell holds isn't freed (freed-view); the current view has a focused control when it has any
## focusable one (no-focus); the orphan-node count doesn't grow every turn for orphan_turns turns
## (orphans, debug builds); no step takes longer than step_seconds (slow). Then each line
## tools/autoplay_invariants.gd's check(state, adapter) returns (invariant). Warnings are reported as
## notes and don't fail the run. Thresholds: tools/autoplay_catalog.gd.
##
## Determinism: the seed seeds the global generator, the driver's own choices, and the run, through
## the adapter's start_run(seed). tools/autoplay.sh runs Godot with --fixed-fps 60, so every frame
## advances time by the same amount, and each step settles until its finite Tweens have ended. The
## same seed and scenario give the same actions and the same log, apart from time stamps, run ids
## and timing lines (frame.hitch, window focus).
##
## A ui action must reach the game: a click that never arrives at its control (a panel on top,
## mouse_filter IGNORE, a clipped centre) and a key press that never registers as its action are
## drive findings, and smoke that ends before playing its turns is a smoke finding.
##
## A game that can't be played yet (no PlayLog on the base, no main scene, or the adapter still has the seed's start_run()) is
## skipped: the run says what to set up, writes nothing and exits 0, so a game made from the seeds
## passes the check until it can be played.
##
## Arguments after `--`: <scenario>, --list, --seed N, --steps N, --no-images, --size WxH,
## --replay <run folder>, --until <step>, --from-save.
## Output: GDIR-AUTOPLAY: lines, GDIR-AUTOPLAY-FAIL: <scenario> step <n>: <kind>: <summary> lines,
## GDIR-AUTOPLAY-LIST: lines for --list, and GDIR-AUTOPLAY-SKIP: when it can't run.
## Exit codes: 0 clean · 1 findings or failures · 3 couldn't run (no display).

const UiLint := preload("res://tools/ui_lint.gd")
const UiOverlay := preload("res://tools/ui_overlay.gd")
const AdapterBase := preload("res://tools/autoplay_adapter_base.gd")
const ScenarioBase := preload("res://tools/autoplay_catalog.gd")
const ADAPTER_PATH: String = "res://tools/autoplay_adapter.gd"
const SCENARIOS_PATH: String = "res://tools/autoplay_scenarios.gd"
const INVARIANTS_PATH: String = "res://tools/autoplay_invariants.gd"
const SCREENS_PATH: String = "res://tools/ui_screens.gd"
const OUT_DIR: String = "res://playtesting/autoplay"
const SAVE_PATH: String = "user://godot-director-autoplay-before.save"
const AUTOPLAY_META: StringName = &"godot_director_autoplay"
const TAG: String = "GDIR-AUTOPLAY: "
const FAIL_TAG: String = "GDIR-AUTOPLAY-FAIL: "
const SKIP_TAG: String = "GDIR-AUTOPLAY-SKIP: "
const LIST_TAG: String = "GDIR-AUTOPLAY-LIST: "
const SMOKE_STEPS: int = 200
const MAX_DEPTH: int = 4
## Finding kinds that are reported but don't fail the run.
const NOTE_KINDS: PackedStringArray = ["warning"]
## Finding kinds after which the run can't usefully go on.
const STOP_KINDS: PackedStringArray = ["softlock", "no-actions", "stuck", "scenario", "replay", "adapter"]

# arguments
var _scenario_id: String = ""
var _seed_arg: int = -1
var _steps_arg: int = -1
var _images: bool = true
var _size_arg: Vector2i = Vector2i.ZERO
var _replay_arg: String = ""
var _until: int = -1
var _list: bool = false
var _from_save: bool = false
var _arg_problems: PackedStringArray = PackedStringArray()

# the run
var _catalog: ScenarioBase = null
var _adapter: AdapterBase = null
var _invariants: RefCounted = null
var _log: Node = null
var _entry: Dictionary = {}
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _seed: int = 1
var _max_steps: int = 0
var _run_dir: String = ""
var _replay_actions: Array = []
var _replay_boot: int = -1             # the global seed the replayed run booted with
var _save_step: int = 0                # --from-save: the step whose before-save is loaded
var _save_file: String = ""
var _boot_seed: int = 1
var _cap_own: bool = true              # the step cap is the scenario's own (no --steps, no --until)
var _view_ids: PackedStringArray = PackedStringArray()   # the catalog's views, in catalog order
var _step: int = 0
var _actions: Array[Dictionary] = []    # legal now
var _taken: Array[Dictionary] = []      # performed, for the repro
var _findings: Array[Dictionary] = []   # first occurrences
var _seen: Dictionary = {}              # "kind|summary" -> index in _findings
var _pending: Array[Dictionary] = []    # new findings of this step, not reported yet
var _view: String = ""
var _turn: Variant = null
var _turns: int = 0
var _orphans: Array[int] = []
var _block_reason: String = ""
var _blocked: bool = false
var _block_steps: int = 0
var _block_tried: Dictionary = {}
var _last_action: String = ""
var _saved_before: bool = false
var _halt: bool = false
var _failing: int = 0
var _notes: int = 0

var _started: bool = false
var _done: bool = false
var _beat_ms: int = 0


func _init() -> void:
	# Before any autoload's _ready: the play log writes files under autoplay, and the boot's own
	# randomness repeats.
	Engine.set_meta(AUTOPLAY_META, true)
	_arg_problems = _read_args()
	if _arg_problems.is_empty() and not _replay_arg.is_empty():
		_arg_problems = _read_replay()   # its seeds, before the autoloads draw from the generator
	_boot_seed = _replay_boot if _replay_boot >= 0 else (_seed_arg if _seed_arg >= 0 else 1)
	seed(_boot_seed)


func _initialize() -> void:
	# Autoloads are registered after this script is compiled, so the run starts on the first frame.
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	if not _started:
		_started = true
		_beat_ms = Time.get_ticks_msec()
		_run()
	elif _done:
		return
	elif Time.get_ticks_msec() - _beat_ms > int(_stuck_seconds() * 1000.0) + 5000:
		# Nothing the driver awaits has come back: a script error stopped it, or a step hangs.
		_finding("stuck", "autoplay stopped at step %d: nothing came back for %d seconds (see the errors above)" % [_step, int(_stuck_seconds()) + 5])
		_report_pending(PackedStringArray(), false)
		_finish()


func _stuck_seconds() -> float:
	return _catalog.stuck_seconds if _catalog != null else 60.0


func _run() -> void:
	if not _arg_problems.is_empty():
		for problem: String in _arg_problems:
			printerr(FAIL_TAG + problem)
		_stop(1)
		return
	if not _load_catalog():
		return
	if _list:
		_print_list()
		return
	if not _choose_entry():
		return
	if _images and DisplayServer.get_name() == "headless":
		printerr(SKIP_TAG + "needs a display to take screenshots; this Godot has none (--no-images plays headless)")
		_stop(3)
		return
	if not _load_game_parts():
		return
	if not _make_run_dir():
		return
	_log.set("log_dir", ProjectSettings.globalize_path(_run_dir))
	_log.call("start_capture")
	var size: Vector2i = _size_arg if _size_arg != Vector2i.ZERO else _project_size()
	root.size = size
	var main_scene: String = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	var packed: PackedScene = load(main_scene) as PackedScene if not main_scene.is_empty() else null
	if main_scene.is_empty():
		_skip("the project has no main scene yet (application/run/main_scene in project.godot); set one, then this plays the game")
		return
	if packed == null:
		printerr(FAIL_TAG + "the project has no main scene that loads (application/run/main_scene: '%s')" % main_scene)
		_stop(1)
		return
	change_scene_to_packed(packed)
	await _frames(_catalog.settle_frames + 1)
	if root.size != size:
		print(TAG + "note: the window is %dx%d, not %dx%d (the screen is smaller?)" % [root.size.x, root.size.y, size.x, size.y])
	_adapter.tree = self
	print(TAG + "%s · seed %d · %s · %s" % [_entry["id"], _seed, "replay of " + _replay_arg if not _replay_arg.is_empty() else str(_entry["kind"]),
		_run_dir.trim_prefix("res://")])
	var how: String = "start_run(%d)" % _seed
	var started: Dictionary = {}
	if _from_save:
		# The state before the step that failed, through the game's own load path; numbering goes on
		# from there, so a finding has the same step as in the run replayed.
		how = "load_save(%s)" % _save_file.get_file()
		_step = _save_step - 1
		started = await _call(Callable(_adapter, "load_save").bind(ProjectSettings.globalize_path(_save_file)))
		if bool(started["done"]) and not bool(started["value"]):
			_finding("adapter", "load_save() returned false for %s, so the run can't start from it" % _save_file.get_file())
	else:
		started = await _call(Callable(_adapter, "start_run").bind(_seed))
	if _adapter.unfilled and not _from_save:
		_skip("tools/autoplay_adapter.gd isn't filled in yet, so there is no run to play. Fill in start_run(), list_actions() and perform() there (its comments say how); then this plays the game")
		return
	if not bool(started["done"]):
		_finding("stuck", "%s didn't finish within %d seconds" % [how, int(_catalog.stuck_seconds)])
	await _settle()
	if not _log_in_run_dir():
		_finding("adapter", "the play log isn't writing into the run folder after %s: it must start or load the run the way the game does, so PlayLog.begin_run() or continue_run() runs" % how)
	_log.call("log_event", "autoplay", "autoplay.start", "%s seed %d" % [_entry["id"], _seed],
		{"scenario": _entry["id"], "seed": _seed, "kind": _entry["kind"], "replay": not _replay_arg.is_empty(),
		"from_step": _step + 1})
	await _observe(PackedStringArray(["start"]))
	if not _halt:
		if _from_save:
			await _play_from_save()
		else:
			match str(_entry["kind"]):
				"smoke":
					await _play_smoke()
				"scripted":
					await _play_scripted()
				"strategy":
					await _play_strategy()
	if _done:
		return
	_log.call("flush_engine_log")
	await _observe(PackedStringArray(["end"]), false)
	_finish()


## The game isn't ready to be played yet (no main scene, or the adapter still has the seed's start_run()):
## say what to set up and stop cleanly, leaving no run folder, so a game made from the seeds passes the
## check until it can be played.
func _skip(reason: String) -> void:
	if Engine.has_meta(AUTOPLAY_META):
		Engine.remove_meta(AUTOPLAY_META)   # the play log writes nothing at exit: a tool run, not a run to keep
	if not _run_dir.is_empty():
		for file: String in DirAccess.get_files_at(_run_dir):
			DirAccess.remove_absolute(_run_dir.path_join(file))
		DirAccess.remove_absolute(_run_dir)
	print(TAG + "%s · seed %d · skipped: %s" % [_entry["id"], _seed, reason])
	_stop(0)


func _finish() -> void:
	if _done:
		return
	if _log == null:
		_stop(1)
		return
	if _failing + _notes > 0:
		_write_repro()
	_log.call("log_event", "autoplay", "autoplay.end", "%d steps, %d findings" % [_step, _failing],
		{"steps": _step, "turns": _turns, "findings": _failing, "notes": _notes})
	print(TAG + "%s · seed %d · %d step%s · %d turn%s · %d finding%s%s · %s" % [
		_entry.get("id", "?"), _seed, _step, "" if _step == 1 else "s", _turns, "" if _turns == 1 else "s",
		_failing, "" if _failing == 1 else "s", " · %d warning%s" % [_notes, "" if _notes == 1 else "s"] if _notes > 0 else "",
		_run_dir.trim_prefix("res://")])
	_stop(1 if _failing > 0 else 0)


func _stop(code: int) -> void:
	_done = true
	paused = false
	quit(code)


# --- arguments and setup ------------------------------------------------------------------------

func _read_args() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var index: int = 0
	while index < args.size():
		var arg: String = args[index]
		match arg:
			"--no-images":
				_images = false
			"--list":
				_list = true
			"--from-save":
				_from_save = true
			"--seed", "--steps", "--size", "--replay", "--until":
				if index + 1 >= args.size():
					problems.append("%s needs a value" % arg)
				else:
					var value: String = args[index + 1]
					match arg:
						"--seed":
							if value.is_valid_int() and value.to_int() >= 0:
								_seed_arg = value.to_int()
							else:
								problems.append("--seed takes a whole number, 0 or more")
						"--steps":
							if value.is_valid_int() and value.to_int() >= 0:
								_steps_arg = value.to_int()
							else:
								problems.append("--steps takes a whole number, 0 or more")
						"--until":
							if value.is_valid_int() and value.to_int() >= 0:
								_until = value.to_int()
							else:
								problems.append("--until takes a step number")
						"--size":
							_size_arg = _parse_size(value)
							if _size_arg == Vector2i.ZERO:
								problems.append("--size takes WxH, such as 1280x720")
						"--replay":
							_replay_arg = value.replace("\\", "/").trim_suffix("/")
				index += 1
			_:
				if arg.begins_with("-"):
					problems.append("unknown option %s" % arg)
				elif not _scenario_id.is_empty():
					problems.append("one scenario at a time (bash tools/autoplay.sh --all runs them all)")
				else:
					_scenario_id = arg
		index += 1
	if _until >= 0 and _replay_arg.is_empty():
		problems.append("--until goes with --replay <run folder>")
	if _from_save and _replay_arg.is_empty():
		problems.append("--from-save goes with --replay <run folder>")
	if not _replay_arg.is_empty() and not _scenario_id.is_empty():
		problems.append("--replay takes the scenario from the run folder; leave the scenario out")
	return problems


func _parse_size(text: String) -> Vector2i:
	var parts: PackedStringArray = text.strip_edges().to_lower().split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	var size: Vector2i = Vector2i(parts[0].to_int(), parts[1].to_int())
	return size if size.x > 0 and size.y > 0 else Vector2i.ZERO


## The window size a player gets at launch.
func _project_size() -> Vector2i:
	var width: int = int(ProjectSettings.get_setting("display/window/size/window_width_override", 0))
	var height: int = int(ProjectSettings.get_setting("display/window/size/window_height_override", 0))
	if width <= 0 or height <= 0:
		width = int(ProjectSettings.get_setting("display/window/size/viewport_width", 1152))
		height = int(ProjectSettings.get_setting("display/window/size/viewport_height", 648))
	return Vector2i(maxi(width, 1), maxi(height, 1))


func _load_catalog() -> bool:
	var script: GDScript = ResourceLoader.load(SCENARIOS_PATH) as GDScript if ResourceLoader.exists(SCENARIOS_PATH) else null
	if script == null or not script.can_instantiate():
		printerr(FAIL_TAG + "%s is missing or doesn't compile" % SCENARIOS_PATH.trim_prefix("res://"))
		_stop(1)
		return false
	var instance: Variant = script.new()
	if not (instance is ScenarioBase):
		printerr(FAIL_TAG + "%s must start with extends \"res://tools/autoplay_catalog.gd\"" % SCENARIOS_PATH.trim_prefix("res://"))
		_stop(1)
		return false
	_catalog = instance
	var checked: Array = _catalog.checked_scenarios()
	var errors: PackedStringArray = checked[1]
	if not errors.is_empty():
		for error: String in errors:
			printerr(FAIL_TAG + error)
		_stop(1)
		return false
	_catalog.set_meta(&"entries", checked[0])
	return true


func _print_list() -> void:
	for entry: Dictionary in (_catalog.get_meta(&"entries") as Array):
		print(LIST_TAG + "%s · %s · %s" % [entry["id"], entry["kind"], entry["title"]])
	_stop(0)


## Reads the run folder's repro.json: the scenario, both seeds, the size and the actions; with
## --from-save, the first finding that has a save. Returns what's wrong with it.
func _read_replay() -> PackedStringArray:
	var folder: String = _replay_arg
	if not folder.begins_with("res://") and not folder.is_absolute_path():
		folder = "res://" + folder
	var text: String = FileAccess.get_file_as_string(folder.path_join("repro.json"))
	var data: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if not (data is Dictionary) or not ((data as Dictionary).get("actions", null) is Array):
		return PackedStringArray(["%s has no repro.json to replay (a run writes one when it finds something)" % _replay_arg])
	var repro: Dictionary = data
	_scenario_id = str(repro.get("scenario", ""))
	if _seed_arg < 0:
		_seed_arg = int(repro.get("seed", 1))
	_replay_boot = int(repro.get("boot_seed", _seed_arg))
	var size: Variant = repro.get("size", [])
	if _size_arg == Vector2i.ZERO and size is Array and (size as Array).size() == 2:
		_size_arg = Vector2i(int(size[0]), int(size[1]))
	_replay_actions = repro["actions"]
	if _from_save:
		for finding: Variant in (repro.get("findings", []) as Array):
			var save: Variant = (finding as Dictionary).get("save", null) if finding is Dictionary else null
			if save is String and not (save as String).is_empty():
				_save_step = int((finding as Dictionary)["step"])
				_save_file = folder.path_join(save)
				break
		if _save_file.is_empty():
			return PackedStringArray(["%s has no finding with a save to start from (the adapter's save_run() returned false; replay without --from-save)" % _replay_arg])
	return PackedStringArray()


func _choose_entry() -> bool:
	var entries: Array = _catalog.get_meta(&"entries")
	if _scenario_id.is_empty():
		printerr(FAIL_TAG + "name a scenario (bash tools/autoplay.sh --list lists them), or --all")
		_stop(1)
		return false
	for entry: Dictionary in entries:
		if str(entry["id"]) == _scenario_id:
			_entry = entry
	if _entry.is_empty():
		printerr(FAIL_TAG + "no scenario '%s' in tools/autoplay_scenarios.gd; run bash tools/autoplay.sh --list" % _scenario_id)
		_stop(1)
		return false
	_seed = _seed_arg if _seed_arg >= 0 else int(_entry.get("seed", _catalog.default_seed))
	seed(_seed)
	_rng.seed = _seed
	var steps: int = int(_entry.get("steps", SMOKE_STEPS if str(_entry["kind"]) == "smoke" else _catalog.default_steps))
	if str(_entry["kind"]) == "scripted":
		steps = 0
		for item: Variant in (_entry["actions"] as Array):
			steps += int((item as Dictionary).get("repeat", 1))
	if not _replay_arg.is_empty():
		steps = _replay_actions.size()
		if _until >= 0:
			steps = mini(steps, _until)
	_max_steps = mini(steps, _steps_arg) if _steps_arg >= 0 else steps
	_cap_own = _steps_arg < 0 and _until < 0
	return true


func _load_game_parts() -> bool:
	_log = root.get_node_or_null("PlayLog")
	if _log == null or not _log.has_method("log_event") or not _log.has_method("start_capture"):
		_skip("the game has no PlayLog autoload built on tools/play_log_base.gd yet (register PlayLog=\"*res://tools/play_log.gd\" under [autoload] in project.godot, or make the game's own PlayLog extend the base); do that, then this plays the game")
		return false
	var script: GDScript = ResourceLoader.load(ADAPTER_PATH) as GDScript if ResourceLoader.exists(ADAPTER_PATH) else null
	var instance: Variant = script.new() if script != null and script.can_instantiate() else null
	if not (instance is AdapterBase):
		printerr(FAIL_TAG + "%s is missing, doesn't compile, or doesn't start with extends \"res://tools/autoplay_adapter_base.gd\"" % ADAPTER_PATH.trim_prefix("res://"))
		_stop(1)
		return false
	_adapter = instance
	if ResourceLoader.exists(INVARIANTS_PATH):
		var checks: GDScript = ResourceLoader.load(INVARIANTS_PATH) as GDScript
		var made: Variant = checks.new() if checks != null and checks.can_instantiate() else null
		if not (made is RefCounted) or not (made as RefCounted).has_method("check"):
			printerr(FAIL_TAG + "%s doesn't compile, or has no check(state, adapter)" % INVARIANTS_PATH.trim_prefix("res://"))
			_stop(1)
			return false
		_invariants = made
	# The catalog's views: what smoke opens, and the adapter's default current_view().
	var views: Dictionary = {}
	if ResourceLoader.exists(SCREENS_PATH):
		var screens: GDScript = ResourceLoader.load(SCREENS_PATH) as GDScript
		var catalog: Variant = screens.new() if screens != null and screens.can_instantiate() else null
		if catalog is RefCounted and (catalog as RefCounted).has_method("checked_screens"):
			var checked: Array = (catalog as RefCounted).call("checked_screens")
			for screen: Dictionary in (checked[0] as Array):
				_view_ids.append(str(screen["id"]))
				if not str(screen["scene"]).is_empty():
					views[str(screen["scene"])] = str(screen["id"])
	_adapter.views = views
	return true


func _make_run_dir() -> bool:
	var stamp: String = Time.get_datetime_string_from_system(false, false).replace("-", "").replace(":", "").replace("T", "-")
	var base: String = "%s-%d-%s%s" % [_entry["id"], _seed, stamp, "-replay" if not _replay_arg.is_empty() else ""]
	var folder: String = base
	var count: int = 1
	while DirAccess.dir_exists_absolute(OUT_DIR.path_join(folder)):
		count += 1
		folder = "%s-%02d" % [base, count]
	_run_dir = OUT_DIR.path_join(folder)
	if DirAccess.make_dir_recursive_absolute(_run_dir) != OK:
		printerr(FAIL_TAG + "can't create %s" % _run_dir.trim_prefix("res://"))
		_stop(1)
		return false
	return true


# --- scenarios ----------------------------------------------------------------------------------

func _stopped() -> bool:
	return _halt or _done or _step >= _max_steps


func _play_scripted() -> void:
	for item: Variant in (_entry["actions"] as Array):
		var step: Dictionary = item
		for _repeat: int in int(step.get("repeat", 1)):
			if _stopped():
				return
			var action: Dictionary = _offered(str(step["do"]))
			if action.is_empty():
				_finding("scenario", "%s isn't offered now (offered: %s)" % [step["do"], _offered_ids()])
				await _report_pending(PackedStringArray())
				return
			await _do(action)
		if step.has("expect") and not _halt and not _done:
			var problem: String = _expect(step["expect"])
			if not problem.is_empty():
				_finding("expect", "after %s: %s" % [step["do"], problem])
				await _report_pending(PackedStringArray())


func _play_strategy() -> void:
	var strategy: String = str(_entry["strategy"])
	var weights: Dictionary = _entry.get("weights", {})
	while not _stopped() and not _run_over():
		if _actions.is_empty():
			return
		var action: Dictionary = {}
		match strategy:
			"random":
				action = _pick(_actions, weights)
			"greedy":
				var score: Callable = _entry["score"]
				var state: Dictionary = _state()
				var best: float = -INF
				for candidate: Dictionary in _actions:
					var value: float = float(score.call(candidate, state))
					if value > best:
						best = value
						action = candidate
			"end_turn":
				action = _progress_action()
				if action.is_empty():
					action = _pick(_others(), weights)
		if action.is_empty():
			return
		await _do(action)


func _play_smoke() -> void:
	var skip: Array = _entry.get("skip_views", [])
	var targets: PackedStringArray = PackedStringArray()
	for id: String in _view_ids:
		if not skip.has(id):
			targets.append(id)
	var opened: Dictionary = {}
	if not _view.is_empty():
		opened[_view] = true
	await _open_views(targets, opened, 0)
	for id: String in targets:
		if not opened.has(id) and not _halt and not _done:
			_finding("smoke", "no action opens the view %s from the views smoke reached (an action's opens names its catalog id)" % id)
	await _report_pending(PackedStringArray())
	var turns: int = int(_entry.get("turns", _catalog.smoke_turns))
	var per_turn: int = int(_entry.get("actions_per_turn", 2))
	var played: int = 0
	var weights: Dictionary = _entry.get("weights", {})
	while played < turns and not _stopped() and not _run_over():
		var before: int = _turns
		for _index: int in per_turn:
			var others: Array[Dictionary] = _others()
			if others.is_empty() or _stopped() or _run_over():
				break
			await _do(_pick(others, weights))
		if _stopped() or _run_over():
			break
		var progress: Dictionary = _progress_action()
		if not progress.is_empty():
			await _do(progress)
		elif _others().is_empty():
			break
		if _turns > before:
			played += 1
	if played < turns and _cap_own and not _halt and not _done and not _run_over():
		_finding("smoke", "played %d of %d turns in %d steps: the turn never moved on (see the drive findings)" % [played, turns, _step])
		await _report_pending(PackedStringArray())


## Opens each target view reachable from here through an action whose `opens` names it, the views
## reachable from that one, and backs out again.
func _open_views(targets: PackedStringArray, opened: Dictionary, depth: int) -> void:
	if depth >= MAX_DEPTH:
		return
	var here: String = _view
	for id: String in targets:
		if opened.has(id) or _stopped():
			continue
		var action: Dictionary = {}
		for candidate: Dictionary in _actions:
			if str(candidate.get("opens", "")) == id:
				action = candidate
				break
		if action.is_empty():
			continue
		await _do(action)
		if _halt or _done:
			return
		if _view != id:
			_finding("smoke", "%s should open the view %s, but the view is %s" % [action["id"], id, _view if not _view.is_empty() else "(none)"])
			await _report_pending(PackedStringArray())
		else:
			opened[id] = true
			await _open_views(targets, opened, depth + 1)
		await _back_to(here)
		if _halt or _done:
			return
		if _view != here:
			_finding("smoke", "couldn't go back from the view %s to %s (no back action, and ui_cancel didn't)" % [_view, here])
			await _report_pending(PackedStringArray())
			return


func _back_to(view: String) -> void:
	for _attempt: int in 3:
		if _view == view or _stopped():
			return
		var back: Dictionary = {}
		for candidate: Dictionary in _actions:
			if bool(candidate.get("back", false)):
				back = candidate
				break
		if back.is_empty():
			back = {"id": "ui_cancel", "label": "back (ui_cancel)", "kind": "ui", "input": "ui_cancel", "synthetic": true}
		await _do(back)


## --from-save: the recorded actions from the save's step on. The scenario's own checks (expects,
## smoke's views and turns) need the run from its start, so they aren't made here.
func _play_from_save() -> void:
	while not _stopped():
		await _do({})


## The recorded action for the next step, as offered now; {} (and the run halted) when the recording
## has no such step or the game doesn't offer it. A replay runs the scenario's own code, so its
## expects and smoke's checks are made again, with each step's action taken from the recording.
func _recorded_action() -> Dictionary:
	var recorded: Dictionary = {}
	for item: Variant in _replay_actions:
		if item is Dictionary and int((item as Dictionary).get("step", 0)) == _step + 1:
			recorded = item
			break
	if recorded.is_empty():
		_halt = true
		return {}
	if bool(recorded.get("synthetic", false)):
		return recorded
	var action: Dictionary = _offered(str(recorded.get("id", "")))
	if action.is_empty():
		_finding("replay", "step %d: %s isn't offered now, so the run went another way than the recorded one (offered: %s)" % [
			_step + 1, recorded.get("id", "?"), _offered_ids()])
	return action


func _offered(id: String) -> Dictionary:
	for action: Dictionary in _actions:
		if str(action["id"]) == id:
			return action
	return {}


func _offered_ids() -> String:
	var ids: PackedStringArray = PackedStringArray()
	for action: Dictionary in _actions:
		ids.append(str(action["id"]))
	return ", ".join(ids) if not ids.is_empty() else "nothing"


## The progress action when it's offered and nothing blocks it, else {}.
func _progress_action() -> Dictionary:
	if not str(_adapter.progress_block_reason()).is_empty():
		return {}
	for action: Dictionary in _actions:
		if bool(action.get("progress", false)):
			return action
	return {}


## The offered actions that don't end the turn or move between views.
func _others() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for action: Dictionary in _actions:
		if not bool(action.get("progress", false)) and not action.has("opens") and not bool(action.get("back", false)):
			result.append(action)
	return result


func _pick(candidates: Array[Dictionary], weights: Dictionary) -> Dictionary:
	if candidates.is_empty():
		return {}
	var total: float = 0.0
	var each: Array[float] = []
	for action: Dictionary in candidates:
		var weight: float = maxf(0.0, float(weights.get(str(action["id"]), action.get("weight", 1.0))))
		each.append(weight)
		total += weight
	if total <= 0.0:
		return candidates[0]
	var roll: float = _rng.randf() * total
	for index: int in candidates.size():
		roll -= each[index]
		if roll < 0.0:
			return candidates[index]
	return candidates[candidates.size() - 1]


func _expect(expect: Variant) -> String:
	var state: Dictionary = _state()
	if expect is Callable:
		return "" if bool((expect as Callable).call(state)) else "the expect returned false (state %s)" % JSON.stringify(state, "", false)
	var wanted: Dictionary = expect
	var wrong: PackedStringArray = PackedStringArray()
	for key: Variant in wanted:
		if not state.has(key) or not _same(state[key], wanted[key]):
			wrong.append("%s is %s, expected %s" % [key, JSON.stringify(state.get(key, null)), JSON.stringify(wanted[key])])
	return "; ".join(wrong)


## Equal values, numbers compared as numbers (JSON and saves turn ints into floats).
func _same(a: Variant, b: Variant) -> bool:
	var numbers: Array[int] = [TYPE_INT, TYPE_FLOAT]
	if typeof(a) in numbers and typeof(b) in numbers:
		return is_equal_approx(float(a), float(b))
	if typeof(a) != typeof(b):
		return false
	return a == b


func _state() -> Dictionary:
	var state: Dictionary = _adapter.state().duplicate(true)
	if not state.has("view"):
		state["view"] = _view
	return state


func _run_over() -> bool:
	return bool(_adapter.is_run_over())


# --- a step -------------------------------------------------------------------------------------

func _do(chosen: Dictionary) -> void:
	var action: Dictionary = chosen
	if not _replay_arg.is_empty():
		action = _recorded_action()
		if action.is_empty():
			_halt = true
			await _report_pending(PackedStringArray())
			return
	_step += 1
	_beat_ms = Time.get_ticks_msec()
	var id: String = str(action["id"])
	var kind: String = str(action.get("kind", ""))
	var route: String = ""
	if kind == "ui":
		route = ("input " + str(action["input"])) if action.has("input") else ("%" + str(action.get("node", "")).trim_prefix("%"))
	# The state before this step, through the game's save API, for the repro of a finding at this step.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	_saved_before = bool(_adapter.save_run(SAVE_PATH)) and FileAccess.file_exists(SAVE_PATH)
	var record: Dictionary = {"step": _step, "id": id, "kind": kind, "label": str(action.get("label", id)), "route": route}
	for key: String in ["input", "node", "synthetic"]:
		if action.has(key):
			record[key] = action[key]
	_taken.append(record)
	_log.call("log_event", "autoplay", "autoplay.step", "step %d: %s (%s)" % [_step, record["label"], route if kind == "ui" else "api"],
		{"step": _step, "action": id, "kind": kind, "route": route})
	var started: int = Time.get_ticks_msec()
	var problem: String = ""
	if kind == "ui":
		problem = await _press(action)
	else:
		var result: Dictionary = await _call(Callable(_adapter, "perform").bind(action))
		if not bool(result["done"]):
			_finding("stuck", "perform(%s) didn't finish within %d seconds" % [id, int(_catalog.stuck_seconds)])
			_halt = true
		elif not bool(result["value"]):
			problem = "perform() returned false for %s, which list_actions() offered" % id
	await _settle()
	var seconds: float = (Time.get_ticks_msec() - started) / 1000.0
	if not problem.is_empty():
		_finding("drive", problem)
	if seconds > _catalog.step_seconds:
		_finding("slow", "%s took %.1f seconds (more than %.1f)" % [id, seconds, _catalog.step_seconds])
	_last_action = id
	await _observe(PackedStringArray())


## Performs a ui action through real input. Returns what went wrong, or "".
func _press(action: Dictionary) -> String:
	if action.has("input"):
		return await _press_input(str(action["input"]))
	var wanted: String = str(action.get("node", "")).trim_prefix("%")
	var lint: UiLint = UiLint.new()
	lint.map(root, root.get_final_transform(), root.size)
	var element: Dictionary = {}
	for candidate: Dictionary in lint.elements:
		if str(candidate["id"]) == wanted and bool(candidate["stable"]):   # unique names only
			element = candidate
			break
	if element.is_empty():
		return "the control %%%s, %s's route, isn't on screen" % [wanted, action["id"]]
	var control: Control = lint.control_of(int(element["n"]))
	if control == null:
		return "the control %%%s, %s's route, isn't on screen" % [wanted, action["id"]]
	if control is BaseButton and (control as BaseButton).disabled:
		return "%%%s is disabled, but list_actions() offers %s" % [wanted, action["id"]]
	var rect: Array = element["rect"]
	var at: Vector2 = Vector2(float(rect[0]) + float(rect[2]) / 2.0, float(rect[1]) + float(rect[3]) / 2.0)
	# The click has to reach the control: a panel on top, mouse_filter IGNORE, or a centre that's
	# clipped or off screen would take it instead, and a player's click with it.
	var reached: Dictionary = {"pressed": false}
	var watch: Callable = func(event: InputEvent) -> void:
		var button: InputEventMouseButton = event as InputEventMouseButton
		if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			reached["pressed"] = true
	control.gui_input.connect(watch)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	Input.parse_input_event(motion)
	var down: InputEventMouseButton = InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	down.position = at
	down.global_position = at
	down.pressed = true
	Input.parse_input_event(down)
	await _frames(1)
	var up: InputEventMouseButton = down.duplicate() as InputEventMouseButton
	up.pressed = false
	up.button_mask = 0
	Input.parse_input_event(up)
	await _frames(1)
	if is_instance_valid(control) and control.gui_input.is_connected(watch):
		control.gui_input.disconnect(watch)
	if not bool(reached["pressed"]):
		return "the click on %%%s (%s) didn't reach it: something on top took it, it ignores the mouse, or its centre is clipped or off screen" % [
			wanted, action["id"]]
	return ""


## Presses and releases an InputMap action through its first key, else its first pad button, else
## the action itself. The press has to register: a text field with focus would take the key, and
## the play log, which logs every action it polls as pressed, must have a line for it.
func _press_input(action_name: String) -> String:
	if not InputMap.has_action(action_name):
		return "the InputMap has no action %s" % action_name
	var focus: Control = root.gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return "the text field %s has focus, so the key for %s would be typed into it" % [focus.name, action_name]
	var logged: bool = not action_name.begins_with("ui_") or PackedStringArray(_log.get("logged_ui_actions")).has(action_name)
	var before: int = (_log.call("captured") as Array).size()
	var chosen: InputEvent = null
	for event: InputEvent in InputMap.action_get_events(action_name):
		if event is InputEventKey:
			chosen = event
			break
	if chosen == null:
		for event: InputEvent in InputMap.action_get_events(action_name):
			if event is InputEventJoypadButton:
				chosen = event
				break
	if chosen == null:
		var fallback: InputEventAction = InputEventAction.new()
		fallback.action = action_name
		chosen = fallback
	var down: InputEvent = chosen.duplicate() as InputEvent
	down.set("pressed", true)
	if down is InputEventAction:
		(down as InputEventAction).strength = 1.0
	Input.parse_input_event(down)
	await _frames(1)
	var up: InputEvent = chosen.duplicate() as InputEvent
	up.set("pressed", false)
	Input.parse_input_event(up)
	await _frames(1)
	if logged:
		var lines: Array = _log.call("captured")
		for index: int in range(mini(before, lines.size()), lines.size()):
			var line: Dictionary = lines[index]
			if str(line.get("event", "")) == "input.action" and str((line.get("data", {}) as Dictionary).get("action", "")) == action_name:
				return ""
		return "the press of %s never registered as the action (the play log has no input.action line for it)" % action_name
	return ""


## Calls a method of the adapter that may await, giving up after stuck_seconds:
## {"done": bool, "value": what it returned}.
func _call(callable: Callable) -> Dictionary:
	var box: Dictionary = {"done": false, "value": null}
	var runner: Callable = func() -> void:
		box["value"] = await callable.call()
		box["done"] = true
	runner.call()
	var started: int = Time.get_ticks_msec()
	while not bool(box["done"]):
		if Time.get_ticks_msec() - started > int(_catalog.stuck_seconds * 1000.0):
			return box
		await _frames(1)
	return box


func _frames(count: int) -> void:
	for _index: int in count:
		await process_frame
		_beat_ms = Time.get_ticks_msec()


## Waits settle_frames, then while a finite Tween is still running (up to tween_frames), so
## animations end in the same state on every run.
func _settle() -> void:
	await _frames(_catalog.settle_frames)
	var waited: int = 0
	while waited < _catalog.tween_frames and _tweens_running():
		await _frames(1)
		waited += 1
	_log.call("flush_engine_log")


func _tweens_running() -> bool:
	for tween: Tween in get_processed_tweens():
		if tween.is_valid() and tween.is_running() and tween.get_loops_left() != -1:
			return true
	return false


## True when the play log's current files are in this run's folder.
func _log_in_run_dir() -> bool:
	var path: String = str(_log.call("log_path")).replace("\\", "/").to_lower()
	var folder: String = ProjectSettings.globalize_path(_run_dir).replace("\\", "/").to_lower().trim_suffix("/")
	return not path.is_empty() and path.begins_with(folder + "/")


# --- invariants ---------------------------------------------------------------------------------

## Reads the play log's new lines, checks the invariants, and writes the screenshots and findings of
## this step.
func _observe(reasons: PackedStringArray, check: bool = true) -> void:
	_log.call("flush_engine_log")
	var lines: Array = _log.call("stop_capture")
	_log.call("start_capture")
	for line: Variant in lines:
		var entry: Dictionary = line
		match str(entry.get("event", "")):
			"engine.error":
				_finding("error", str(entry.get("text", "")))
			"engine.warning":
				_finding("warning", str(entry.get("text", "")))
			"view.changed":
				_reason(reasons, "view")
			"snapshot":
				_reason(reasons, "snapshot")
			"progress.blocked":
				_reason(reasons, "blocked")
	var view: String = str(_adapter.current_view())
	if view != _view:
		_view = view
		_reason(reasons, "view")
	var turn: Variant = _log.get("turn")
	if turn != _turn:
		if _turn != null:
			_turns += 1
			_check_orphans()
		_turn = turn
	if check:
		_actions = _legal()
		var over: bool = _run_over()
		if _actions.is_empty() and not over:
			_finding("no-actions", "list_actions() offers nothing, but the run isn't over (view %s)" % (_view if not _view.is_empty() else "(none)"))
		_check_view()
		_check_softlock(over)
		if _invariants != null:
			var problems: Variant = _invariants.call("check", _state(), _adapter)
			if problems is PackedStringArray or problems is Array:
				for problem: Variant in problems:
					_finding("invariant", str(problem))
	await _report_pending(reasons)


func _reason(reasons: PackedStringArray, reason: String) -> void:
	if not reasons.has(reason):
		reasons.append(reason)


## The offered actions, checked: an action the driver can't use is a finding (adapter) and left out.
func _legal() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var ids: Dictionary = {}
	for action: Dictionary in _adapter.list_actions():
		var id: String = str(action.get("id", ""))
		var kind: String = str(action.get("kind", ""))
		var problem: String = ""
		if id.is_empty():
			problem = "an action without an id: %s" % JSON.stringify(action, "", false)
		elif ids.has(id):
			problem = "two actions have the id %s" % id
		elif kind != "ui" and kind != "api":
			problem = "%s: kind must be ui or api" % id
		elif kind == "ui" and str(action.get("node", "")).is_empty() and str(action.get("input", "")).is_empty():
			problem = "%s: a ui action needs node (a unique node name) or input (an InputMap action)" % id
		if not problem.is_empty():
			_finding("adapter", "list_actions(): " + problem)
			continue
		ids[id] = true
		result.append(action)
	return result


func _check_view() -> void:
	var held: Variant = _adapter.view_node()
	if typeof(held) == TYPE_OBJECT and not is_instance_valid(held):
		_finding("freed-view", "the view the shell holds as current (%s) was freed" % (_view if not _view.is_empty() else "?"))
		return
	var view: Node = held as Node
	if view == null or not view.is_inside_tree():
		return
	var owner: Control = view.get_viewport().gui_get_focus_owner()
	if owner != null and (owner == view or view.is_ancestor_of(owner) or owner.get_window() != view.get_window()):
		return
	if _has_focusable(view):
		_finding("no-focus", "the view %s has no focused control, so a keyboard or controller player can't act" % (_view if not _view.is_empty() else str(view.name)))


func _has_focusable(node: Node) -> bool:
	var control: Control = node as Control
	if control != null:
		if not control.is_visible_in_tree():
			return false
		if control.focus_mode == Control.FOCUS_ALL and not (control is BaseButton and (control as BaseButton).disabled):
			return true
	for child: Node in node.get_children():
		if not (child is Window) and _has_focusable(child):
			return true
	return false


func _check_softlock(over: bool) -> void:
	var reason: String = str(_adapter.progress_block_reason())
	if over or reason.is_empty():
		_blocked = false
		_block_reason = ""
		_block_steps = 0
		_block_tried = {}
		return
	# Counted on being blocked, whatever the reason says: a reason with a countdown in it is still
	# the same block. The finding names the latest reason.
	_block_reason = reason
	if not _blocked:
		_blocked = true
		_block_steps = 0
		_block_tried = {}
		return
	_block_steps += 1
	_block_tried[_last_action] = true
	if _block_steps < _catalog.softlock_actions:
		return
	for action: Dictionary in _actions:
		if bool(action.get("unblocks", false)) and not _block_tried.has(str(action["id"])):
			return
	_finding("softlock", "progress blocked across %d actions (%s), and nothing list_actions() offers unblocks it" % [
		_catalog.softlock_actions, _block_reason])


func _check_orphans() -> void:
	if not OS.is_debug_build():
		return
	_orphans.append(int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)))
	var span: int = _catalog.orphan_turns + 1
	if _orphans.size() > span:
		_orphans = _orphans.slice(_orphans.size() - span)
	if _orphans.size() < span:
		return
	for index: int in range(1, _orphans.size()):
		if _orphans[index] <= _orphans[index - 1]:
			return
	_finding("orphans", "the orphan-node count grew every turn for %d turns (%s)" % [_catalog.orphan_turns,
		", ".join(PackedStringArray(_orphans.map(func(count: int) -> String: return str(count))))])


# --- findings, screenshots and the repro ------------------------------------------------------

## Records a finding. Only its first occurrence is reported (screenshot, log line, repro); later
## ones are counted.
func _finding(kind: String, summary: String) -> void:
	var key: String = kind + "|" + summary
	if _seen.has(key):
		var known: Dictionary = _findings[int(_seen[key])]
		known["count"] = int(known["count"]) + 1
		return
	var finding: Dictionary = {"step": _step, "kind": kind, "summary": summary, "count": 1,
		"fails": not NOTE_KINDS.has(kind), "screenshot": "", "elements": "", "save": null}
	_seen[key] = _findings.size()
	_findings.append(finding)
	_pending.append(finding)
	if finding["fails"]:
		_failing += 1
	else:
		_notes += 1
	if STOP_KINDS.has(kind):
		_halt = true


## Writes this step's screenshots (one per reason and per new finding kind) and reports the new
## findings.
func _report_pending(reasons: PackedStringArray, render: bool = true) -> void:
	var all: PackedStringArray = reasons.duplicate()
	for finding: Dictionary in _pending:
		_reason(all, str(finding["kind"]))
	var findings: Array[Dictionary] = _pending
	_pending = []
	for finding: Dictionary in findings:
		var base: String = "%04d-%s" % [_step, finding["kind"]]
		finding["screenshot"] = base + ".png" if _images else ""
		finding["elements"] = base + ".elements.json"
		if _saved_before and int(finding["step"]) > 0:
			var save: String = "saves/before-%04d.save" % int(finding["step"])
			DirAccess.make_dir_recursive_absolute(_run_dir.path_join("saves"))
			if DirAccess.copy_absolute(ProjectSettings.globalize_path(SAVE_PATH), ProjectSettings.globalize_path(_run_dir.path_join(save))) == OK:
				finding["save"] = save
		_log.call("log_event", "autoplay", "autoplay.finding", "step %d: %s: %s" % [finding["step"], finding["kind"], finding["summary"]],
			{"step": finding["step"], "kind": finding["kind"], "summary": finding["summary"], "fails": finding["fails"],
			"screenshot": finding["screenshot"], "elements": finding["elements"]})
	if not all.is_empty():
		if render:
			await _shot(all)
		else:
			_shot_now(all, null)
	for finding: Dictionary in findings:
		var where: String = " · %s %s · repro %s" % ["screenshot" if _images else "element map",
			_run_dir.trim_prefix("res://").path_join(str(finding["screenshot"]) if _images else str(finding["elements"])),
			_run_dir.trim_prefix("res://")]
		var line: String = "%s step %d: %s: %s%s" % [_entry.get("id", "?"), finding["step"], finding["kind"], finding["summary"], where]
		if bool(finding["fails"]):
			printerr(FAIL_TAG + line)
		else:
			print(TAG + "note: " + line)
	if not findings.is_empty():
		_write_repro()


func _shot(reasons: PackedStringArray) -> void:
	var image: Image = null
	if _images:
		await RenderingServer.frame_post_draw
		_beat_ms = Time.get_ticks_msec()
		image = root.get_texture().get_image()
	_shot_now(reasons, image)


## Writes `<step>-<reason>` .png, .elements.json and .map.png for each reason, from one frame.
func _shot_now(reasons: PackedStringArray, image: Image) -> void:
	var size: Vector2i = root.size
	var to_pixels: Transform2D = root.get_final_transform()
	if image != null:
		image.convert(Image.FORMAT_RGBA8)
		if image.get_size() != size:   # viewport stretch renders at the base size
			to_pixels = Transform2D(0.0, Vector2(image.get_size()) / root.get_visible_rect().size, 0.0, Vector2.ZERO)
			size = image.get_size()
	var lint: UiLint = UiLint.new()
	lint.map(root, to_pixels, size)
	var map_image: Image = UiOverlay.draw_map(image, lint.elements + lint.pickables_3d) if image != null else null
	var scene: Node = current_scene
	var source: String = scene.scene_file_path if scene != null and is_instance_valid(scene) else ""
	for reason: String in reasons:
		var base: String = "%04d-%s" % [_step, reason]
		var path: String = _run_dir.path_join(base)
		_write(path + ".elements.json", lint.element_map(_view, reason, size, source))
		if image != null:
			image.save_png(ProjectSettings.globalize_path(path + ".png"))
			map_image.save_png(ProjectSettings.globalize_path(path + ".map.png"))
		_log.call("log_event", "autoplay", "screenshot", base + (".png" if image != null else ".elements.json"),
			{"step": _step, "reason": reason, "view": _view, "image": base + ".png" if image != null else null,
			"elements": base + ".elements.json", "map": base + ".map.png" if image != null else null})


func _write(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr(FAIL_TAG + "can't write %s" % path.trim_prefix("res://"))
		return
	file.store_string(text)
	file.close()


## repro.json: what --replay needs (the scenario, seed, size and every action so far) and each
## finding with its step, screenshot and save.
func _write_repro() -> void:
	var findings: Array = []
	for finding: Dictionary in _findings:
		findings.append({"step": finding["step"], "kind": finding["kind"], "summary": finding["summary"],
			"count": finding["count"], "fails": finding["fails"], "screenshot": finding["screenshot"],
			"elements": finding["elements"], "save": finding["save"]})
	var head: Dictionary = {
		"schema": 1, "scenario": _entry.get("id", ""), "seed": _seed, "boot_seed": _boot_seed, "size": [root.size.x, root.size.y],
		"images": _images, "replay_of": _replay_arg, "steps": _step,
		"replay": "bash tools/autoplay.sh --replay %s --until <step>" % _run_dir.trim_prefix("res://"),
	}
	for finding: Dictionary in findings:
		if finding["save"] != null:
			head["replay_from_save"] = "bash tools/autoplay.sh --replay %s --from-save" % _run_dir.trim_prefix("res://")
			break
	# One finding and one action per line, so the file reads as a list.
	var lines: PackedStringArray = PackedStringArray(["{"])
	for key: Variant in head:
		lines.append("  %s: %s," % [JSON.stringify(key), JSON.stringify(head[key], "", false)])
	for list: String in ["findings", "actions"]:
		var rows: PackedStringArray = PackedStringArray()
		for row: Variant in (findings if list == "findings" else _taken):
			rows.append("    " + JSON.stringify(row, "", false))
		var body: String = ("\n" + ",\n".join(rows) + "\n  ") if not rows.is_empty() else ""
		lines.append("  \"%s\": [%s]%s" % [list, body, "," if list == "findings" else ""])
	lines.append("}")
	_write(_run_dir.path_join("repro.json"), "\n".join(lines) + "\n")
