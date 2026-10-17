extends SceneTree
## Log review: the assistant reads a play log · framework-owned: replaced on upgrade.
##
## Run it with `bash tools/log_review.sh`, which finds Godot, the game's real user:// folder for
## --player, and reads this script's output. It reads only the play log's JSONL (never the .log) and
## writes two files next to it:
## - review.md, for an assistant that can't view images: the run in a few lines, a timeline in turns
##   and views, the findings by signature (each with its first step, count and the paths of its
##   screenshot, element map, save and repro), the coverage, and the delta against the previous
##   autoplay run of the same scenario;
## - findings.json, the same findings as data: {"schema", "log", "run", "scenario", "seed", "build",
##   "findings": [{"signature", "kind", "text", "example", "first_step", "first_turn", "first_line",
##   "count", "screenshot", "elements", "repro", "save"}], "coverage", "delta"}.
## Paths in both are relative to the project when the log is inside it, else absolute; a finding's
## files are named relative to the log's folder in findings.json.
##
## A finding is a problem line, grouped by signature. The kinds and where they come from:
##   error, warning   engine.error and engine.warning lines
##   blocked          progress.blocked, and progress.pressed_blocked: the reason progress was blocked
##   hitch            frame.hitch lines
##   softlock, invariant and the other autoplay kinds (no-actions, freed-view, no-focus, orphans,
##   slow, drive, smoke, expect, adapter, stuck, ...): autoplay.finding lines
## An autoplay finding of kind error or warning repeats an engine line, so its line is used only for
## the screenshot and the step.
##
## The signature of a finding is "sig-" and the first eight hex digits of the md5 of
## "<kind>|<normalised text>". Normalising keeps what the problem is and drops what changes between
## runs: the repeat note the play log adds, UUIDs, hex addresses (0x...), hashes (eight or more hex
## digits with a letter and a digit), numbers (line numbers, object ids such as <Button#1234>, counts
## and times) and runs of white space. So the same error at another line, with other object ids or a
## changing count, has one signature; two different errors have two. tests/log-review/ has the cases.
##
## playtesting/signatures.tsv records each signature a review finds: id, kind, normalised text, the
## build it was first seen in, the build it was last seen in (a project seed with the header). The
## game's project owns it; a backend can import it. `--check sig-xxxxxxxx` reviews the log and
## reports whether that signature appears in it: exit 0 absent (a fix confirmed for this run), 1
## present, 2 not a signature in the file.
##
## The delta compares with the newest earlier non-replay run folder of the same scenario in the same
## folder (autoplay/<scenario>-<seed>-<datetime>), whatever its seed: new, gone and still-present
## signatures.
##
## Arguments after `--`: --log <run folder or .jsonl>, --latest (the newest autoplay run folder),
## --player <folder> (the newest run-*.jsonl in it; tools/log_review.sh finds the game's real
## user://logs/play), --check <signature>, --cases <file> (checks the normalisation against a
## fixture of cases, group, kind, text, expected text and expected signature, tab separated; prints
## PASS and FAIL lines and DONE).
## Output: GDIR-REVIEW: lines and GDIR-REVIEW-FAIL: lines.
## Exit codes: 0 reviewed (--check: absent) · 1 --check: present · 2 bad arguments or an unknown
## signature · 3 couldn't run (no log found).

const TAG: String = "GDIR-REVIEW: "
const FAIL_TAG: String = "GDIR-REVIEW-FAIL: "
const SIGNATURES_PATH: String = "res://playtesting/signatures.tsv"
const SCREENS_PATH: String = "res://tools/ui_screens.gd"
const AUTOPLAY_DIR: String = "res://playtesting/autoplay"
const TSV_HEADER: String = "id\tkind\ttext\tfirst_seen_build\tlast_seen_build"
const SIGNATURE_FORMAT: String = "^sig-[0-9a-f]{8}$"
const RUN_FOLDER: String = "^([a-z0-9_]+)-(\\d+)-(\\d{8}-\\d{6})(?:-(\\d\\d+))?(-replay)?(?:-(\\d\\d+))?$"
const UNVERSIONED: String = "unversioned"
## Worst first.
const KIND_ORDER: PackedStringArray = ["softlock", "invariant", "error", "blocked", "warning", "hitch"]
## Play log categories every game has: the timeline lists the others as the game's own events.
const BUILT_IN_CATEGORIES: PackedStringArray = ["session", "snapshot", "view", "focus", "window", "input",
	"progress", "engine error", "engine warning", "hitch", "autoplay", "screenshot", "run"]
const MAX_EVENT_IDS: int = 6

var _log_arg: String = ""
var _latest: bool = false
var _player_arg: String = ""
var _check_arg: String = ""
var _cases_arg: String = ""
var _problems: PackedStringArray = PackedStringArray()
var _bad_lines: int = 0
var _started: bool = false

var _rx_repeat: RegEx = RegEx.create_from_string("\\s*\\(repeated \\d+ times; further repeats aren't logged\\)")
var _rx_uuid: RegEx = RegEx.create_from_string("(?i)\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b")
var _rx_address: RegEx = RegEx.create_from_string("\\b0[xX][0-9a-fA-F]+\\b")
var _rx_hash: RegEx = RegEx.create_from_string("(?i)\\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\\d)[0-9a-f]{8,}\\b")
var _rx_number: RegEx = RegEx.create_from_string("(?<![A-Za-z_0-9])-?\\d+(?:\\.\\d+)?")
var _rx_space: RegEx = RegEx.create_from_string("\\s+")
var _rx_folder: RegEx = RegEx.create_from_string(RUN_FOLDER)


func _initialize() -> void:
	# Autoloads are registered after this script is compiled, so the work starts on the first frame.
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	if _started:
		return
	_started = true
	_read_args()
	if not _problems.is_empty():
		for problem: String in _problems:
			printerr(FAIL_TAG + problem)
		quit(2)
		return
	if not _cases_arg.is_empty():
		quit(_run_cases(_cases_arg))
		return
	quit(_run())


func _read_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var index: int = 0
	while index < args.size():
		var arg: String = args[index]
		index += 1
		match arg:
			"--latest":
				_latest = true
			"--log", "--player", "--check", "--cases":
				if index >= args.size():
					_problems.append("%s needs a value" % arg)
					continue
				var value: String = args[index]
				index += 1
				match arg:
					"--log":
						_log_arg = value
					"--player":
						_player_arg = value
					"--check":
						_check_arg = value
					"--cases":
						_cases_arg = value
			_:
				_problems.append("unknown argument %s" % arg)
	var chosen: int = int(_latest) + int(not _log_arg.is_empty()) + int(not _player_arg.is_empty())
	if chosen > 1:
		_problems.append("name one log: a run folder or .jsonl, --latest or --player")
	if not _check_arg.is_empty() and _rx_signature().search(_check_arg) == null:
		_problems.append("%s isn't a signature (sig- and eight hex digits)" % _check_arg)
	if _cases_arg.is_empty() and chosen == 0:
		_latest = true


func _rx_signature() -> RegEx:
	return RegEx.create_from_string(SIGNATURE_FORMAT)


# --- one review ---------------------------------------------------------------------------------

func _run() -> int:
	var path: String = _resolve()
	if path.is_empty():
		return 3
	var analysis: Dictionary = _analyse(path)
	if analysis.is_empty():
		printerr(FAIL_TAG + "can't read %s" % _shown(path))
		return 3
	var folder: String = path.get_base_dir()
	var previous_path: String = _previous(folder)
	var delta: Dictionary = {}
	if not previous_path.is_empty():
		var before: Dictionary = _analyse(previous_path)
		if not before.is_empty():
			delta = _delta(analysis, before, previous_path.get_base_dir())
	analysis["delta"] = delta
	var findings: Array[Dictionary] = _sorted(analysis["findings"])
	var out_md: String = folder.path_join("review.md")
	var out_json: String = folder.path_join("findings.json")
	if not _write(out_md, _report(analysis, findings, folder)) or not _write(out_json, JSON.stringify(_data(analysis, findings, folder), "  ", false) + "\n"):
		return 3
	_update_signatures(findings, str(analysis["build"]))
	_print_summary(analysis, findings, folder)
	if _check_arg.is_empty():
		return 0
	return _check(analysis)


## The JSONL to review, from the arguments: a file, a folder (its newest run-*.jsonl), the newest
## autoplay run folder, or the newest run-*.jsonl in the player's log folder.
func _resolve() -> String:
	if not _player_arg.is_empty():
		var newest: String = _newest_log(_player_arg)
		if newest.is_empty():
			printerr(FAIL_TAG + "no run-*.jsonl in %s (play the game first)" % _player_arg)
		return newest
	if _latest:
		var folder: String = _latest_run_folder()
		if folder.is_empty():
			printerr(FAIL_TAG + "no autoplay run with a play log in %s (bash tools/autoplay.sh smoke makes one)" % AUTOPLAY_DIR.trim_prefix("res://"))
			return ""
		return _newest_log(folder)
	if DirAccess.dir_exists_absolute(_log_arg):
		var inside: String = _newest_log(_log_arg)
		if inside.is_empty():
			printerr(FAIL_TAG + "no run-*.jsonl in %s" % _shown(_log_arg))
		return inside
	if FileAccess.file_exists(_log_arg):
		return _log_arg
	printerr(FAIL_TAG + "%s isn't a run folder or a .jsonl file" % _log_arg)
	return ""


## The newest run-*.jsonl in a folder (ids sort by time).
func _newest_log(folder: String) -> String:
	var names: PackedStringArray = PackedStringArray()
	for file_name: String in DirAccess.get_files_at(folder):
		if file_name.begins_with("run-") and file_name.ends_with(".jsonl"):
			names.append(file_name)
	if names.is_empty():
		return ""
	names.sort()
	return folder.path_join(names[names.size() - 1])


## A run folder's sort key, "<datetime>-<counter>", or "" for a folder that isn't an autoplay run.
func _folder_key(folder_name: String) -> String:
	var found: RegExMatch = _rx_folder.search(folder_name)
	if found == null:
		return ""
	var counter: String = found.get_string(4) if not found.get_string(4).is_empty() else found.get_string(6)
	return "%s-%s" % [found.get_string(3), counter if not counter.is_empty() else "01"]


func _latest_run_folder() -> String:
	var base: String = ProjectSettings.globalize_path(AUTOPLAY_DIR)
	var best: String = ""
	var best_key: String = ""
	for folder_name: String in DirAccess.get_directories_at(base):
		var key: String = _folder_key(folder_name)
		if key.is_empty() or _newest_log(base.path_join(folder_name)).is_empty():
			continue
		if key > best_key:
			best_key = key
			best = folder_name
	return base.path_join(best) if not best.is_empty() else ""


## The log of the newest earlier run of the same scenario in the folder's parent: not a replay.
func _previous(folder: String) -> String:
	var own: RegExMatch = _rx_folder.search(folder.get_file())
	if own == null:
		return ""
	var own_key: String = _folder_key(folder.get_file())
	var parent: String = folder.get_base_dir()
	var best: String = ""
	var best_key: String = ""
	for folder_name: String in DirAccess.get_directories_at(parent):
		var found: RegExMatch = _rx_folder.search(folder_name)
		if found == null or not found.get_string(5).is_empty() or found.get_string(1) != own.get_string(1):
			continue
		var key: String = _folder_key(folder_name)
		if key >= own_key or key <= best_key or _newest_log(parent.path_join(folder_name)).is_empty():
			continue
		best_key = key
		best = folder_name
	return _newest_log(parent.path_join(best)) if not best.is_empty() else ""


# --- reading the log ----------------------------------------------------------------------------

func _read_events(path: String) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_bad_lines = 0
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return events
	var number: int = 0
	while not file.eof_reached():
		var line: String = file.get_line()
		number += 1
		if line.strip_edges().is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			var entry: Dictionary = parsed
			entry["_n"] = number
			events.append(entry)
		else:
			_bad_lines += 1
	return events


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _data_of(entry: Dictionary) -> Dictionary:
	var data: Variant = entry.get("data", {})
	return data if data is Dictionary else {}


func _turn_label(turn: Variant) -> String:
	return "boot" if turn == null else "T%d" % int(turn)


## Everything a review says about one log: the run's facts, the timeline rows, the findings by
## signature and the coverage. {} when the log can't be read.
func _analyse(path: String) -> Dictionary:
	var events: Array[Dictionary] = _read_events(path)
	if events.is_empty():
		return {}
	var folder: String = path.get_base_dir()
	var repro: Dictionary = _read_json(folder.path_join("repro.json"))
	var info: Dictionary = {"scenario": "", "seed": -1, "build": UNVERSIONED, "godot": "", "os": "", "game": "",
		"autoplay": false, "ended": false}
	var findings: Dictionary = {}   # signature -> finding
	var rows: Dictionary = {}       # turn label -> timeline row
	var row_order: PackedStringArray = PackedStringArray()
	var view_path: PackedStringArray = PackedStringArray()
	var shots: Dictionary = {}      # "<step>|<reason>" -> screenshot line data
	var from_findings: Dictionary = {}   # "<kind>|<text>" -> autoplay.finding line data
	var controls_pressed: Dictionary = {}
	var actions_taken: Dictionary = {}
	var views_opened: PackedStringArray = PackedStringArray()
	var step: int = 0
	var max_step: int = 0
	var snapshot_turns: Dictionary = {}
	var numbered_turns: Dictionary = {}
	for entry: Dictionary in events:
		var data: Dictionary = _data_of(entry)
		var event: String = str(entry.get("event", ""))
		var turn: Variant = entry.get("turn", null)
		var label: String = _turn_label(turn)
		if turn != null:
			numbered_turns[int(turn)] = true
			if event == "snapshot":
				snapshot_turns[int(turn)] = true
		if not rows.has(label):
			rows[label] = {"label": label, "steps": [], "views": PackedStringArray(), "events": {}, "findings": PackedStringArray(),
				"first_line": int(entry["_n"])}
			row_order.append(label)
		var row: Dictionary = rows[label]
		match event:
			"session.start":
				info["build"] = str(data.get("build", "")) if not str(data.get("build", "")).is_empty() else UNVERSIONED
				info["godot"] = str(data.get("godot", ""))
				info["os"] = str(data.get("os", ""))
				info["game"] = str(data.get("game", ""))
			"session.end":
				info["ended"] = true
			"autoplay.start":
				info["autoplay"] = true
				info["scenario"] = str(data.get("scenario", ""))
				info["seed"] = int(data.get("seed", -1))
			"autoplay.step":
				step = int(data.get("step", step + 1))
				max_step = maxi(max_step, step)
				var span: Array = row["steps"]
				if span.is_empty():
					span.append(step)
					span.append(step)
				else:
					span[1] = step
				var id: String = str(data.get("action", ""))
				var taken: Dictionary = actions_taken.get(id, {"count": 0, "kind": str(data.get("kind", ""))})
				taken["count"] = int(taken["count"]) + 1
				actions_taken[id] = taken
			"view.changed", "screenshot":
				var view: String = str(data.get("view", entry.get("text", ""))) if event == "view.changed" else str(data.get("view", ""))
				if event == "screenshot":
					shots["%d|%s" % [int(data.get("step", 0)), str(data.get("reason", ""))]] = data
				if not view.is_empty():
					if view_path.is_empty() or view_path[view_path.size() - 1] != view:
						view_path.append(view)
					var row_views: PackedStringArray = row["views"]
					if not row_views.has(view):
						row_views.append(view)
					if not views_opened.has(view):
						views_opened.append(view)
			"input.action":
				var action: String = str(data.get("action", entry.get("text", "")))
				controls_pressed[action] = int(controls_pressed.get(action, 0)) + 1
			"autoplay.finding":
				var kind: String = str(data.get("kind", ""))
				var summary: String = str(data.get("summary", ""))
				from_findings["%s|%s" % [kind, summary]] = data
				if kind != "error" and kind != "warning":
					_add(findings, row, kind, summary, int(data.get("step", step)), turn, int(entry["_n"]), bool(info["autoplay"]))
			"engine.error":
				_add(findings, row, "error", str(entry.get("text", "")), step, turn, int(entry["_n"]), bool(info["autoplay"]))
			"engine.warning":
				_add(findings, row, "warning", str(entry.get("text", "")), step, turn, int(entry["_n"]), bool(info["autoplay"]))
			"progress.blocked":
				_add(findings, row, "blocked", str(data.get("reason", "")), step, turn, int(entry["_n"]), bool(info["autoplay"]))
			"progress.pressed_blocked":
				_add(findings, row, "blocked", str(data.get("blocked", "")), step, turn, int(entry["_n"]), bool(info["autoplay"]))
			"frame.hitch":
				_add(findings, row, "hitch", str(entry.get("text", "")), step, turn, int(entry["_n"]), bool(info["autoplay"]))
		if not BUILT_IN_CATEGORIES.has(str(entry.get("cat", ""))) and event != "snapshot":
			var counts: Dictionary = row["events"]
			counts[event] = int(counts.get(event, 0)) + 1
	# The files each finding names: its autoplay.finding line, a progress block's screenshot, and
	# the repro's own record of it (its count, which also covers repeats the play log didn't write).
	var repro_rows: Array = repro.get("findings", []) as Array if repro.get("findings", []) is Array else []
	var has_repro: bool = FileAccess.file_exists(folder.path_join("repro.json"))
	for sig: Variant in findings:
		var finding: Dictionary = findings[sig]
		var first_step: int = int(finding["first_step"]) if finding["first_step"] != null else 0
		var raws: Dictionary = finding["_raw"]
		for raw: Variant in raws:
			var key: String = "%s|%s" % [finding["kind"], raw]
			if from_findings.has(key) and str(finding["elements"]).is_empty():
				var found: Dictionary = from_findings[key]
				finding["screenshot"] = str(found.get("screenshot", ""))
				finding["elements"] = str(found.get("elements", ""))
		if str(finding["kind"]) == "blocked" and str(finding["elements"]).is_empty() and shots.has("%d|blocked" % first_step):
			var shot: Dictionary = shots["%d|blocked" % first_step]
			finding["screenshot"] = str(shot.get("image", "")) if shot.get("image", null) != null else ""
			finding["elements"] = str(shot.get("elements", ""))
	for row_data: Variant in repro_rows:
		if not (row_data is Dictionary):
			continue
		var found_row: Dictionary = row_data
		var found_sig: String = _signature(str(found_row.get("kind", "")), normalise(str(found_row.get("summary", ""))))
		if not findings.has(found_sig):
			continue
		var target: Dictionary = findings[found_sig]
		target["_repro_count"] = int(target["_repro_count"]) + int(found_row.get("count", 1))
		if str(target["repro"]).is_empty():
			target["repro"] = "repro.json"
		if str(target["elements"]).is_empty():
			target["screenshot"] = str(found_row.get("screenshot", ""))
			target["elements"] = str(found_row.get("elements", ""))
		if str(target["save"]).is_empty() and found_row.get("save", null) != null:
			target["save"] = str(found_row["save"])
	for sig: Variant in findings:
		var finding: Dictionary = findings[sig]
		finding["count"] = maxi(int(finding["count"]), int(finding["_repro_count"]))
		for field: String in ["screenshot", "elements", "save"]:
			if not str(finding[field]).is_empty() and not FileAccess.file_exists(folder.path_join(str(finding[field]))):
				finding[field] = ""
		if not has_repro:
			finding["repro"] = ""
	var seen_turns: Array = (snapshot_turns if not snapshot_turns.is_empty() else numbered_turns).keys()
	seen_turns.sort()
	var catalog: PackedStringArray = _catalog_views()
	var defined: PackedStringArray = PackedStringArray()
	for action: StringName in InputMap.get_actions():
		if not str(action).begins_with("ui_"):
			defined.append(str(action))
	defined.sort()
	var list: Array[Dictionary] = []
	for sig: Variant in findings:
		list.append(findings[sig])
	return {"path": path, "info": info, "lines": events.size(), "bad_lines": _bad_lines, "steps": max_step, "turns": seen_turns.size(), "turn_range": [int(seen_turns.front()) if not seen_turns.is_empty() else 0, int(seen_turns.back()) if not seen_turns.is_empty() else 0],
		"scenario": info["scenario"], "seed": info["seed"], "build": info["build"], "autoplay": info["autoplay"],
		"findings": list, "rows": rows, "row_order": row_order, "view_path": view_path,
		"views_opened": views_opened, "catalog_views": catalog, "controls_defined": defined, "controls_pressed": controls_pressed,
		"actions_taken": actions_taken, "has_repro": has_repro}


## Adds one occurrence to the findings, grouped by signature.
func _add(findings: Dictionary, row: Dictionary, kind: String, raw: String, step: int, turn: Variant, line: int, autoplay: bool) -> void:
	var normal: String = normalise(raw)
	var sig: String = _signature(kind, normal)
	if not findings.has(sig):
		findings[sig] = {"signature": sig, "kind": kind, "text": normal, "example": raw.strip_edges(),
			"first_step": step if autoplay else null, "first_turn": turn, "first_line": line, "count": 0,
			"screenshot": "", "elements": "", "repro": "", "save": "", "_raw": {}, "_repro_count": 0}
	var finding: Dictionary = findings[sig]
	finding["count"] = int(finding["count"]) + 1
	(finding["_raw"] as Dictionary)[raw] = true
	var in_row: PackedStringArray = row["findings"]
	if not in_row.has(sig):
		in_row.append(sig)


func _catalog_views() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray()
	if not ResourceLoader.exists(SCREENS_PATH):
		return ids
	var screens: GDScript = ResourceLoader.load(SCREENS_PATH) as GDScript
	var catalog: Variant = screens.new() if screens != null and screens.can_instantiate() else null
	if catalog is RefCounted and (catalog as RefCounted).has_method("checked_screens"):
		var checked: Array = (catalog as RefCounted).call("checked_screens")
		for screen: Dictionary in (checked[0] as Array):
			ids.append(str(screen["id"]))
	return ids


# --- signatures ---------------------------------------------------------------------------------

## What a problem line says without what changes between runs: see the header.
func normalise(text: String) -> String:
	var result: String = _rx_repeat.sub(text, "", true)
	result = _rx_uuid.sub(result, "<uuid>", true)
	result = _rx_address.sub(result, "<hash>", true)
	result = _rx_hash.sub(result, "<hash>", true)
	result = _rx_number.sub(result, "<n>", true)
	return _rx_space.sub(result, " ", true).strip_edges()


func _signature(kind: String, normal_text: String) -> String:
	return "sig-" + ("%s|%s" % [kind, normal_text]).md5_text().substr(0, 8)


## playtesting/signatures.tsv: adds the signatures this review found, and moves the last seen build
## of those it knew. Other lines stay as they are.
func _update_signatures(findings: Array[Dictionary], build: String) -> void:
	var lines: PackedStringArray = PackedStringArray()
	if FileAccess.file_exists(SIGNATURES_PATH):
		lines = FileAccess.get_file_as_string(SIGNATURES_PATH).replace("\r", "").split("\n")
		while not lines.is_empty() and lines[lines.size() - 1].is_empty():
			lines.remove_at(lines.size() - 1)
	var changed: bool = false
	if lines.is_empty():
		lines.append(TSV_HEADER)
		changed = true
	var at: Dictionary = {}
	for index: int in lines.size():
		var cells: PackedStringArray = lines[index].split("\t")
		if cells.size() >= 5 and not lines[index].begins_with("#"):
			at[cells[0]] = index
	for finding: Dictionary in findings:
		var sig: String = str(finding["signature"])
		if at.has(sig):
			var cells: PackedStringArray = lines[int(at[sig])].split("\t")
			if cells[4] != build:
				cells[4] = build
				lines[int(at[sig])] = "\t".join(cells)
				changed = true
		else:
			lines.append("\t".join([sig, str(finding["kind"]), str(finding["text"]), build, build]))
			changed = true
	if changed:
		DirAccess.make_dir_recursive_absolute(SIGNATURES_PATH.get_base_dir())
		_write(SIGNATURES_PATH, "\n".join(lines) + "\n")


## --check: the signature must be in the file; present or absent in this log decides the exit code.
func _check(analysis: Dictionary) -> int:
	var known: String = ""
	for line: String in FileAccess.get_file_as_string(SIGNATURES_PATH).replace("\r", "").split("\n"):
		if line.begins_with(_check_arg + "\t"):
			known = line
	if known.is_empty():
		printerr(FAIL_TAG + "%s isn't in playtesting/signatures.tsv (a review adds the signatures it finds)" % _check_arg)
		return 2
	var cells: PackedStringArray = known.split("\t")
	var where: String = "%s · build %s · %s" % [_shown(str(analysis["path"]).get_base_dir()), analysis["build"],
		"scenario " + str(analysis["scenario"]) if not str(analysis["scenario"]).is_empty() else "played by a person"]
	var history: String = "%s: %s · first seen in build %s, last seen in build %s" % [cells[1], cells[2], cells[3], cells[4]]
	for finding: Dictionary in (analysis["findings"] as Array):
		if str(finding["signature"]) == _check_arg:
			print(TAG + "check %s: PRESENT in %s (%dx, first at %s) · %s" % [_check_arg, where, int(finding["count"]),
				_where_first(finding), history])
			return 1
	print(TAG + "check %s: absent from %s · %s" % [_check_arg, where, history])
	return 0


# --- the delta ----------------------------------------------------------------------------------

func _delta(now: Dictionary, before: Dictionary, previous_folder: String) -> Dictionary:
	var before_sigs: Dictionary = {}
	for finding: Dictionary in (before["findings"] as Array):
		before_sigs[str(finding["signature"])] = finding
	var now_sigs: Dictionary = {}
	var fresh: PackedStringArray = PackedStringArray()
	var still: PackedStringArray = PackedStringArray()
	var gone: PackedStringArray = PackedStringArray()
	for finding: Dictionary in _sorted(now["findings"]):
		var sig: String = str(finding["signature"])
		now_sigs[sig] = finding
		(still if before_sigs.has(sig) else fresh).append(sig)
	for finding: Dictionary in _sorted(before["findings"]):
		if not now_sigs.has(str(finding["signature"])):
			gone.append(str(finding["signature"]))
	var names: Dictionary = {}
	for source: Dictionary in [now_sigs, before_sigs]:
		for sig: Variant in source:
			names[sig] = "%s: %s" % [(source[sig] as Dictionary)["kind"], (source[sig] as Dictionary)["text"]]
	return {"against": previous_folder, "seed": before["seed"], "new": fresh, "gone": gone, "still": still, "names": names}


# --- output -------------------------------------------------------------------------------------

func _sorted(list: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for item: Variant in list:
		result.append(item)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var rank_a: int = KIND_ORDER.find(str(a["kind"]))
		var rank_b: int = KIND_ORDER.find(str(b["kind"]))
		rank_a = rank_a if rank_a >= 0 else KIND_ORDER.size()
		rank_b = rank_b if rank_b >= 0 else KIND_ORDER.size()
		if rank_a != rank_b:
			return rank_a < rank_b
		return int(a["first_line"]) < int(b["first_line"]))
	return result


## A path as the project shows it: relative to the project when it is inside it.
func _shown(path: String) -> String:
	var root: String = ProjectSettings.globalize_path("res://").trim_suffix("/") + "/"
	if path.to_lower().begins_with(root.to_lower()):
		return path.substr(root.length())
	return path


func _where_first(finding: Dictionary) -> String:
	var text: String = "%s, line %d" % [_turn_label(finding["first_turn"]), int(finding["first_line"])]
	if finding["first_step"] != null:
		text = "step %d, " % int(finding["first_step"]) + text
	return text


func _counts(findings: Array[Dictionary]) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var kinds: PackedStringArray = PackedStringArray()
	for finding: Dictionary in findings:
		if not kinds.has(str(finding["kind"])):
			kinds.append(str(finding["kind"]))
	for kind: String in kinds:
		var total: int = 0
		for finding: Dictionary in findings:
			if str(finding["kind"]) == kind:
				total += 1
		parts.append("%s %d" % [kind, total])
	return ", ".join(parts)


func _print_summary(analysis: Dictionary, findings: Array[Dictionary], folder: String) -> void:
	var delta: Dictionary = analysis["delta"]
	print(TAG + "%s · %s · %d step%s · %d turn%s · %d finding%s%s%s" % [
		_shown(folder), "scenario %s seed %d" % [analysis["scenario"], analysis["seed"]] if bool(analysis["autoplay"]) else "played by a person",
		int(analysis["steps"]), "" if int(analysis["steps"]) == 1 else "s", int(analysis["turns"]), "" if int(analysis["turns"]) == 1 else "s",
		findings.size(), "" if findings.size() == 1 else "s", " (%s)" % _counts(findings) if not findings.is_empty() else "",
		" · vs %s: %d new, %d gone, %d still present" % [str(delta["against"]).get_file(), (delta["new"] as PackedStringArray).size(),
			(delta["gone"] as PackedStringArray).size(), (delta["still"] as PackedStringArray).size()] if not delta.is_empty() else ""])
	for finding: Dictionary in findings:
		print(TAG + "  %s · %s · %s · %dx · %s" % [finding["signature"], finding["kind"], _where_first(finding), int(finding["count"]), finding["text"]])
	print(TAG + "wrote %s and findings.json" % _shown(folder.path_join("review.md")))


func _escape_cell(text: String) -> String:
	return text.replace("|", "\\|").replace("\n", " ")


func _code(text: String) -> String:
	return "`" + text.replace("`", "'") + "`"


func _report(analysis: Dictionary, findings: Array[Dictionary], folder: String) -> String:
	var info: Dictionary = analysis["info"]
	var out: PackedStringArray = PackedStringArray()
	out.append("# Log review: %s" % _shown(folder).get_file())
	out.append("")
	out.append("- Log: %s" % _shown(str(analysis["path"])))
	if bool(analysis["autoplay"]):
		out.append("- Played by: autoplay, scenario %s, seed %d" % [info["scenario"], int(info["seed"])])
	else:
		out.append("- Played by: a person (no autoplay.start line)")
	out.append("- Build: %s · Godot %s · %s%s" % [info["build"], info["godot"] if not str(info["godot"]).is_empty() else "?",
		info["os"] if not str(info["os"]).is_empty() else "?", " · %s" % info["game"] if not str(info["game"]).is_empty() else ""])
	var turn_span: Array = analysis["turn_range"]
	out.append("- Length: %d lines, %d turn%s%s%s · session end %s%s" % [int(analysis["lines"]), int(analysis["turns"]),
		"" if int(analysis["turns"]) == 1 else "s", " (T%d-T%d)" % [int(turn_span[0]), int(turn_span[1])] if int(analysis["turns"]) > 1 else "",
		", %d steps" % int(analysis["steps"]) if bool(analysis["autoplay"]) else "",
		"logged" if bool(info["ended"]) else "not logged (still running, or the game crashed)",
		" · %d unreadable line%s skipped" % [int(analysis["bad_lines"]), "" if int(analysis["bad_lines"]) == 1 else "s"] if int(analysis["bad_lines"]) > 0 else ""])
	out.append("- Findings: %s" % (("%d signature%s (%s)" % [findings.size(), "" if findings.size() == 1 else "s", _counts(findings)]) if not findings.is_empty() else "none"))
	out.append("")
	out.append("## Timeline")
	out.append("")
	var path: PackedStringArray = analysis["view_path"]
	out.append("Views: %s" % (" > ".join(path) if not path.is_empty() else "(no view.changed line)"))
	out.append("")
	var steps_column: bool = bool(analysis["autoplay"])
	out.append("| Turn | %sViews | Game events | Findings |" % ("Steps | " if steps_column else ""))
	out.append("|---|%s---|---|---|" % ("---|" if steps_column else ""))
	var rows: Dictionary = analysis["rows"]
	for label: String in (analysis["row_order"] as PackedStringArray):
		var row: Dictionary = rows[label]
		var span: Array = row["steps"]
		var events: Dictionary = row["events"]
		if span.is_empty() and events.is_empty() and (row["views"] as PackedStringArray).is_empty() and (row["findings"] as PackedStringArray).is_empty():
			continue   # a turn with nothing to say (the session header, the end)
		var ids: PackedStringArray = PackedStringArray()
		var names: Array = events.keys()
		names.sort()
		for id: Variant in names:
			if ids.size() >= MAX_EVENT_IDS:
				break
			ids.append("%s x%d" % [id, int(events[id])] if int(events[id]) > 1 else str(id))
		if names.size() > MAX_EVENT_IDS:
			ids.append("+%d more" % (names.size() - MAX_EVENT_IDS))
		out.append("| %s | %s%s | %s | %s |" % [label,
			(("%d-%d" % [int(span[0]), int(span[1])] if int(span[0]) != int(span[1]) else str(int(span[0]))) if not span.is_empty() else "") + " | " if steps_column else "",
			_escape_cell(", ".join(row["views"] as PackedStringArray)), _escape_cell(", ".join(ids)),
			_escape_cell(", ".join(row["findings"] as PackedStringArray))])
	out.append("")
	out.append("## Findings")
	out.append("")
	if findings.is_empty():
		out.append("None: no error, warning, blocked progress, hitch or autoplay finding in this log.")
		out.append("")
	for finding: Dictionary in findings:
		out.append("### %s · %s · %dx" % [finding["signature"], finding["kind"], int(finding["count"])])
		out.append("")
		out.append("- What: %s" % _code(str(finding["text"])))
		if str(finding["example"]) != str(finding["text"]):
			out.append("- As logged: %s" % _code(str(finding["example"])))
		out.append("- First: %s" % _where_first(finding))
		var files: Dictionary = {"screenshot": "Screenshot", "elements": "Element map", "repro": "Repro", "save": "Save before the step"}
		for field: Variant in files:
			if not str(finding[field]).is_empty():
				out.append("- %s: %s" % [files[field], _shown(folder.path_join(str(finding[field])))])
		if str(finding["repro"]) == "repro.json" and finding["first_step"] != null:
			out.append("- Replay: bash tools/autoplay.sh --replay %s --until %d" % [_shown(folder), int(finding["first_step"])])
		out.append("")
	out.append("## Coverage")
	out.append("")
	var catalog: PackedStringArray = analysis["catalog_views"]
	var opened: PackedStringArray = analysis["views_opened"]
	var missing: PackedStringArray = PackedStringArray()
	var extra: PackedStringArray = PackedStringArray()
	for view: String in catalog:
		if not opened.has(view):
			missing.append(view)
	for view: String in opened:
		if not catalog.has(view):
			extra.append(view)
	if catalog.is_empty():
		out.append("- Views opened: %s (the game has no screen catalog to compare with)" % (", ".join(opened) if not opened.is_empty() else "none"))
	else:
		out.append("- Views opened: %d of %d in the catalog%s%s%s" % [catalog.size() - missing.size(), catalog.size(),
			" (%s)" % ", ".join(opened) if not opened.is_empty() else "",
			" · not opened: %s" % ", ".join(missing) if not missing.is_empty() else "",
			" · opened but not in the catalog: %s" % ", ".join(extra) if not extra.is_empty() else ""])
	var defined: PackedStringArray = analysis["controls_defined"]
	var pressed: Dictionary = analysis["controls_pressed"]
	var unpressed: PackedStringArray = PackedStringArray()
	var pressed_list: PackedStringArray = PackedStringArray()
	for action: String in defined:
		if not pressed.has(action):
			unpressed.append(action)
	for action: Variant in pressed:
		pressed_list.append("%s x%d" % [action, int(pressed[action])])
	pressed_list.sort()
	if defined.is_empty():
		out.append("- Controls actions pressed: %s (the game defines no input action beyond ui_*)" % (", ".join(pressed_list) if not pressed_list.is_empty() else "none"))
	else:
		var defined_pressed: int = defined.size() - unpressed.size()
		out.append("- Controls actions pressed: %d of %d defined%s%s" % [defined_pressed, defined.size(),
			" (%s)" % ", ".join(pressed_list) if not pressed_list.is_empty() else "", " · never pressed: %s" % ", ".join(unpressed) if not unpressed.is_empty() else ""])
	var taken: Dictionary = analysis["actions_taken"]
	if bool(analysis["autoplay"]):
		var parts: PackedStringArray = PackedStringArray()
		var ids: Array = taken.keys()
		ids.sort()
		for id: Variant in ids:
			parts.append("%s x%d (%s)" % [id, int((taken[id] as Dictionary)["count"]), (taken[id] as Dictionary)["kind"]])
		out.append("- Adapter actions taken: %s" % (", ".join(parts) if not parts.is_empty() else "none"))
	else:
		out.append("- Adapter actions taken: none (a person played)")
	out.append("")
	out.append("## Delta")
	out.append("")
	var delta: Dictionary = analysis["delta"]
	if delta.is_empty():
		if _rx_folder.search(folder.get_file()) == null:
			out.append("None: only an autoplay run folder has a delta, against the previous run of its scenario.")
		else:
			out.append("None: no earlier run of the scenario %s in %s." % [analysis["scenario"], _shown(folder.get_base_dir())])
	else:
		out.append("Against %s (seed %d)." % [_shown(str(delta["against"])), int(delta["seed"])])
		out.append("")
		var names: Dictionary = delta["names"]
		for part: Array in [["New", "new"], ["Gone", "gone"], ["Still present", "still"]]:
			var sigs: PackedStringArray = delta[part[1]]
			if sigs.is_empty():
				out.append("- %s: none" % part[0])
				continue
			out.append("- %s:" % part[0])
			for sig: String in sigs:
				out.append("  - %s %s" % [sig, _code(str(names[sig]))])
	out.append("")
	return "\n".join(out)


func _data(analysis: Dictionary, findings: Array[Dictionary], folder: String) -> Dictionary:
	var list: Array = []
	for finding: Dictionary in findings:
		var copy: Dictionary = {}
		for key: Variant in finding:
			if not str(key).begins_with("_"):
				copy[key] = finding[key]
		list.append(copy)
	var delta: Dictionary = (analysis["delta"] as Dictionary).duplicate()
	if not delta.is_empty():
		delta["against"] = _shown(str(delta["against"]))
		delta.erase("names")
		for key: String in ["new", "gone", "still"]:
			delta[key] = Array(delta[key] as PackedStringArray)
	var catalog: PackedStringArray = analysis["catalog_views"]
	var opened: PackedStringArray = analysis["views_opened"]
	var missing: Array = []
	for view: String in catalog:
		if not opened.has(view):
			missing.append(view)
	var unpressed: Array = []
	for action: String in (analysis["controls_defined"] as PackedStringArray):
		if not (analysis["controls_pressed"] as Dictionary).has(action):
			unpressed.append(action)
	return {"schema": 1, "log": _shown(str(analysis["path"])), "run": folder.get_file(), "scenario": analysis["scenario"],
		"seed": analysis["seed"], "build": analysis["build"], "autoplay": analysis["autoplay"], "lines": analysis["lines"],
		"steps": analysis["steps"], "turns": analysis["turns"], "findings": list,
		"coverage": {"views_opened": Array(opened), "catalog_views": Array(catalog), "views_not_opened": missing,
			"controls_pressed": analysis["controls_pressed"], "controls_never_pressed": unpressed,
			"actions_taken": analysis["actions_taken"]},
		"delta": delta}


func _write(path: String, text: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr(FAIL_TAG + "can't write %s" % _shown(path))
		return false
	file.store_string(text)
	file.close()
	return true


# --- the normalisation fixture ------------------------------------------------------------------

## --cases <file>: lines of group, kind, text, expected normalised text and expected signature, tab
## separated (# starts a comment). Each row is normalised as expected and hashes to its signature;
## rows of one group share a signature and rows of two groups don't.
func _run_cases(path: String) -> int:
	if not FileAccess.file_exists(path):
		printerr(FAIL_TAG + "no cases file %s" % path)
		return 3
	var failed: int = 0
	var group_sig: Dictionary = {}
	var sig_group: Dictionary = {}
	var rows: int = 0
	var number: int = 0
	var format: RegEx = _rx_signature()
	for line: String in FileAccess.get_file_as_string(path).replace("\r", "").split("\n"):
		number += 1
		if line.strip_edges().is_empty() or line.begins_with("#"):
			continue
		var cells: PackedStringArray = line.split("\t")
		if cells.size() != 5:
			print("FAIL line %d: five tab separated cells expected, found %d" % [number, cells.size()])
			failed += 1
			continue
		rows += 1
		var normal: String = normalise(cells[2])
		var sig: String = _signature(cells[1], normal)
		var what: String = "%s (%s, line %d)" % [cells[0], cells[1], number]
		if normal == cells[3]:
			print("PASS %s normalises to the expected text" % what)
		else:
			print("FAIL %s normalises to '%s', expected '%s'" % [what, normal, cells[3]])
			failed += 1
		if normalise(normal) != normal:
			print("FAIL %s: normalising twice changes the text" % what)
			failed += 1
		if format.search(sig) == null or sig != cells[4]:
			print("FAIL %s has the signature %s, expected %s" % [what, sig, cells[4]])
			failed += 1
		else:
			print("PASS %s has the expected signature %s" % [what, sig])
		if group_sig.has(cells[0]) and group_sig[cells[0]] != sig:
			print("FAIL group %s hashes to two signatures (%s, %s)" % [cells[0], group_sig[cells[0]], sig])
			failed += 1
		group_sig[cells[0]] = sig
		if sig_group.has(sig) and sig_group[sig] != cells[0]:
			print("FAIL groups %s and %s share the signature %s" % [sig_group[sig], cells[0], sig])
			failed += 1
		sig_group[sig] = cells[0]
	print("%s %d groups give %d signatures over %d rows" % ["PASS" if group_sig.size() == sig_group.size() and rows > 0 else "FAIL",
		group_sig.size(), sig_group.size(), rows])
	if group_sig.size() != sig_group.size() or rows == 0:
		failed += 1
	print("DONE")
	return 0 if failed == 0 else 1
