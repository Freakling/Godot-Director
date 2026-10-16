extends SceneTree
## Verifies a built screen against its spec · framework-owned: replaced on upgrade.
##
## Run it with `bash tools/ui_capture.sh <screen> --verify` (.godot-director/procedures/ui-design.md),
## which captures the screen first. This script reads, headless and with no display:
##   design/ui/<id>.md                         the spec: its Layout table is what is checked
##   design/ui/captures/<id>@<W>x<H>.elements.json and .lint.txt   the latest capture
##   design/ui/captures/<id>.drawing.json      the human's drawing, when it has been processed
## and prints one row per spec element: present (an element with that unique name is on screen),
## where (every edge of its rect_pct within [verify] tolerance_pct of the spec's Where), reachable
## (a focusable element has a focus_order) and lint-clean (no finding names it). It lists the
## elements with unique names that the spec doesn't, lint findings in the screen's other states and
## sizes, and drawn boxes whose element has moved away. When the drawing is there it also writes the
## compare image for each size captured (tools/ui_overlay.gd).
##   godot --headless --path . --script tools/ui_verify.gd -- <screen> [--state <name>] [--size <W>x<H>]
## Exit codes: 0 no deviations · 1 deviations · 3 nothing to check (no spec, or no capture).

const UiOverlay := preload("res://tools/ui_overlay.gd")
const CONFIG_PATH: String = "res://tools/ui_capture.cfg"
const CAPTURES: String = "res://design/ui/captures"
const SPECS: String = "res://design/ui"
const CHECK_META: StringName = &"godot_director_check"
const CAPTURE_META: StringName = &"godot_director_capture"
## Lint rules that are warnings: listed, never a deviation.
const WARNINGS: PackedStringArray = ["hard-coded-position"]

var _screen: String = ""
var _state: String = "default"
var _size_option: String = ""
var _tolerance: float = 4.0
var _default_size: Vector2i = Vector2i(1920, 1080)
var _deviations: int = 0


func _init() -> void:
	# Before any autoload's _ready runs: nothing here reads or writes player data.
	Engine.set_meta(CHECK_META, true)
	Engine.set_meta(CAPTURE_META, true)


func _initialize() -> void:
	quit(_run())


func _say(text: String) -> void:
	print("GDIR-UI-VERIFY: " + text)


func _stop_with(message: String, code: int) -> int:
	printerr("GDIR-UI-FAIL: ui_verify: " + message)
	return code


func _run() -> int:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var index: int = 0
	while index < args.size():
		match args[index]:
			"--state":
				index += 1
				_state = args[index] if index < args.size() else "default"
			"--size":
				index += 1
				_size_option = args[index] if index < args.size() else ""
			"--no-images":
				pass
			_:
				if not args[index].begins_with("-"):
					_screen = args[index]
		index += 1
	if _screen.is_empty():
		return _stop_with("usage: tools/ui_verify.gd -- <screen> [--state <name>] [--size <W>x<H>]", 1)
	_read_config()
	var spec_path: String = SPECS.path_join(_screen + ".md")
	if not FileAccess.file_exists(spec_path):
		return _stop_with("no spec at design/ui/%s.md; /ui-design process %s writes it from the drawing" % [_screen, _screen], 3)
	var spec: Dictionary = _read_spec(spec_path)
	var size: Vector2i = spec["size"] if spec["size"] != Vector2i.ZERO else _default_size
	if not _size_option.is_empty():
		size = _parse_size(_size_option)
		if size == Vector2i.ZERO:
			return _stop_with("--size takes WxH, such as 1920x1080", 1)
	var prefix: String = _screen if _state == "default" else "%s.%s" % [_screen, _state]
	var base: String = "%s@%dx%d" % [prefix, size.x, size.y]
	var map_path: String = CAPTURES.path_join(base + ".elements.json")
	if not FileAccess.file_exists(map_path):
		return _stop_with("no capture %s.elements.json; run bash tools/ui_capture.sh %s first" % [base, _screen], 3)
	var map: Variant = JSON.parse_string(FileAccess.get_file_as_string(map_path))
	if not (map is Dictionary) or not ((map as Dictionary).get("elements") is Array):
		return _stop_with("design/ui/captures/%s.elements.json isn't an element map" % base, 3)
	var spec_rows: Array = spec["rows"]
	if spec_rows.is_empty():
		return _stop_with("design/ui/%s.md has no Layout table (## Layout (at WxH), with a row per element)" % _screen, 3)

	var by_name: Dictionary = {}
	var by_number: Dictionary = {}
	for item: Variant in ((map as Dictionary)["elements"] as Array):
		var element: Dictionary = item
		by_number[int(element.get("n", 0))] = element
		if bool(element.get("stable", false)) and not by_name.has(str(element.get("id", ""))):
			by_name[str(element.get("id", ""))] = element
	var lint: Dictionary = _read_lint(CAPTURES.path_join(base + ".lint.txt"))

	_say("%s against design/ui/%s.md (tolerance %s%% per edge)" % [base, _screen, _n(_tolerance)])
	_say("| Element | Name | Expected (x, y, w, h %) | Found | Verdict |")
	_say("|---|---|---|---|---|")
	var listed: PackedStringArray = PackedStringArray()
	var checked: int = 0
	var reported: Dictionary = {}
	for item: Variant in spec_rows:
		var row: Dictionary = item
		var name: String = str(row["name"])
		var where: PackedFloat64Array = _numbers(str(row["where"]))
		var problems: PackedStringArray = PackedStringArray()
		var found_text: String = "-"
		if name.is_empty() or name == "-":
			_say("| %s | - | %s | - | skipped: no unique name in the spec |" % [row["element"], row["where"]])
			continue
		checked += 1
		listed.append(name)
		if where.size() != 4:
			problems.append("the spec's Where isn't x, y, w, h")
		if not by_name.has(name):
			problems.append("missing: no visible element named %%%s" % name)
		else:
			var element: Dictionary = by_name[name]
			var rect: Array = element.get("rect_pct", [0, 0, 0, 0])
			found_text = "%s, %s, %s, %s" % [_n(float(rect[0])), _n(float(rect[1])), _n(float(rect[2])), _n(float(rect[3]))]
			if where.size() == 4:
				var moved: PackedStringArray = PackedStringArray()
				var edges: Array = [["left", where[0], float(rect[0])], ["top", where[1], float(rect[1])],
					["right", where[0] + where[2], float(rect[0]) + float(rect[2])],
					["bottom", where[1] + where[3], float(rect[1]) + float(rect[3])]]
				for edge: Array in edges:
					if absf(float(edge[1]) - float(edge[2])) > _tolerance:
						moved.append("%s edge %s, expected %s" % [edge[0], _n(float(edge[2])), _n(float(edge[1]))])
				if not moved.is_empty():
					problems.append("moved: " + "; ".join(moved))
			var own: Array = lint.get(int(element.get("n", 0)), [])
			if bool(element.get("focusable", false)) and element.get("focus_order") == null and not own.has("unreachable"):
				problems.append("unreachable: focusable, but focus never gets there")
			for rule: Variant in own:
				if not WARNINGS.has(str(rule)):
					problems.append("lint: " + str(rule))
		reported[name] = not problems.is_empty()
		if not problems.is_empty():
			_deviations += 1
		_say("| %s | %%%s | %s | %s | %s |" % [row["element"], name, str(row["where"]), found_text, "ok" if problems.is_empty() else ", ".join(problems)])

	# Elements with unique names that the spec doesn't list.
	for name: Variant in by_name:
		if not listed.has(str(name)):
			var rect: Array = (by_name[name] as Dictionary).get("rect_pct", [0, 0, 0, 0])
			_say("not in the spec: %%%s at %s, %s, %s, %s" % [name, _n(float(rect[0])), _n(float(rect[1])), _n(float(rect[2])), _n(float(rect[3]))])

	# The lint errors of the capture itself, and findings in the screen's other states and sizes.
	for line: String in lint.get("errors", []):
		_deviations += 1
		_say("capture error: " + line)
	_other_lint(prefix, base)

	# The drawing: boxes whose element moved away, and the compare images.
	var drawing: Variant = JSON.parse_string(FileAccess.get_file_as_string(CAPTURES.path_join(_screen + ".drawing.json")))
	if drawing is Dictionary:
		_drawn_boxes(drawing as Dictionary, by_name, reported)
		_compare_images(drawing as Dictionary)
	else:
		_say("no %s.drawing.json, so no compare image (process the drawing first)" % _screen)

	_say("%d element%s checked, %d deviation%s" % [checked, "" if checked == 1 else "s", _deviations, "" if _deviations == 1 else "s"])
	return 0 if _deviations == 0 else 1


func _read_config() -> void:
	var config: ConfigFile = ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	_tolerance = float(config.get_value("verify", "tolerance_pct", _tolerance))
	var sizes: Variant = config.get_value("sizes", "list", [])
	if sizes is Array and not (sizes as Array).is_empty():
		var first: Vector2i = _parse_size(str((sizes as Array)[0]))
		if first != Vector2i.ZERO:
			_default_size = first


## The spec's Layout table: {size, rows: [{element, name, where}]}. The size is the one in the
## heading, `## Layout (at 1920x1080)`; zero when it names none.
func _read_spec(path: String) -> Dictionary:
	var size: Vector2i = Vector2i.ZERO
	var rows: Array[Dictionary] = []
	var in_layout: bool = false
	var size_pattern: RegEx = RegEx.create_from_string(r"(\d+)\s*[xX]\s*(\d+)")
	for line: String in FileAccess.get_file_as_string(path).replace("\r", "").split("\n"):
		if line.begins_with("#"):
			in_layout = line.begins_with("## Layout")
			if in_layout:
				var found: RegExMatch = size_pattern.search(line)
				if found != null:
					size = Vector2i(int(found.get_string(1)), int(found.get_string(2)))
			continue
		if not in_layout or not line.strip_edges().begins_with("|"):
			continue
		var cells: PackedStringArray = PackedStringArray()
		for cell: String in line.strip_edges().trim_prefix("|").trim_suffix("|").split("|"):
			cells.append(cell.replace("`", "").strip_edges())
		if cells.size() < 4 or cells[0] == "#" or cells[0].trim_prefix(":").begins_with("-"):
			continue
		rows.append({"element": cells[1], "name": cells[2].trim_prefix("%"), "where": cells[3]})
	return {"size": size, "rows": rows}


## The lint file as {element number: [rules]}, plus "errors": the lines a failed setup left on top.
func _read_lint(path: String) -> Dictionary:
	var result: Dictionary = {"errors": PackedStringArray()}
	var pattern: RegEx = RegEx.create_from_string(r"^(\S+) element (\d+) ")
	for line: String in FileAccess.get_file_as_string(path).replace("\r", "").split("\n"):
		if line.begins_with("error:"):
			(result["errors"] as PackedStringArray).append(line)
			continue
		var found: RegExMatch = pattern.search(line)
		if found != null:
			var number: int = int(found.get_string(2))
			if not result.has(number):
				result[number] = []
			(result[number] as Array).append(found.get_string(1))
	return result


## Findings in the other lint files of this screen (other states and sizes).
func _other_lint(prefix: String, base: String) -> void:
	var dir: DirAccess = DirAccess.open(CAPTURES)
	if dir == null:
		return
	var names: Array[String] = []
	for file: String in dir.get_files():
		var stem: String = file.trim_suffix(".lint.txt")
		if file.ends_with(".lint.txt") and stem != base and _is_capture_of(stem, _screen):
			names.append(file)
	names.sort()
	for file: String in names:
		for line: String in FileAccess.get_file_as_string(CAPTURES.path_join(file)).replace("\r", "").split("\n"):
			if line.strip_edges().is_empty():
				continue
			var rule: String = line.get_slice(" ", 0)
			if not WARNINGS.has(rule):
				_deviations += 1
			_say("lint in %s: %s" % [file.trim_suffix(".lint.txt"), line])


## True for `<screen>@<W>x<H>` and `<screen>.<state>@<W>x<H>`, not for another screen whose id starts the same.
func _is_capture_of(stem: String, screen: String) -> bool:
	if not stem.begins_with(screen) or not stem.contains("@"):
		return false
	var rest: String = stem.substr(screen.length())
	return rest.begins_with("@") or (rest.begins_with(".") and not rest.get_slice("@", 0).substr(1).contains("."))


## A box drawn over an existing element (overlaps) whose element is no longer where the box is.
func _drawn_boxes(drawing: Dictionary, by_name: Dictionary, reported: Dictionary) -> void:
	for frame: Variant in (drawing.get("frames", []) as Array):
		var shown: Dictionary = frame
		if str(shown.get("name", "")) != _screen or str(shown.get("state", "default")) != _state:
			continue
		for item: Variant in (shown.get("boxes", []) as Array):
			var box: Dictionary = item
			if str(box.get("intent", "")) == "remove":
				continue
			for overlap: Variant in (box.get("overlaps", []) as Array):
				var name: String = str((overlap as Dictionary).get("name", ""))
				if not by_name.has(name) or bool(reported.get(name, false)):
					continue
				var box_rect: Array = box.get("rect_pct", [0, 0, 0, 0])
				var element_rect: Array = (by_name[name] as Dictionary).get("rect_pct", [0, 0, 0, 0])
				if _moved(box_rect, element_rect):
					reported[name] = true
					_deviations += 1
					_say("moved from the drawing: %%%s, box %s (%s) was drawn at %s and is now at %s" % [
						name, box.get("id", "?"), box.get("label", ""), _rect_text(box_rect), _rect_text(element_rect)])


## The compare image for every size of this screen's state that was captured with images.
func _compare_images(drawing: Dictionary) -> void:
	var dir: DirAccess = DirAccess.open(CAPTURES)
	if dir == null:
		return
	var written: int = 0
	var names: Array[String] = []
	for file: String in dir.get_files():
		var stem: String = file.trim_suffix(".png")
		if file.ends_with(".png") and not file.contains(".map.") and not file.contains(".compare@") and _is_capture_of(stem, _screen):
			names.append(stem)
	names.sort()
	for stem: String in names:
		var state: String = stem.get_slice("@", 0).substr(_screen.length() + 1) if stem.get_slice("@", 0).length() > _screen.length() else "default"
		var drawn: bool = false
		for frame: Variant in (drawing.get("frames", []) as Array):
			if str((frame as Dictionary).get("name", "")) == _screen and str((frame as Dictionary).get("state", "default")) == state:
				drawn = true
		if not drawn:
			continue
		var result: Dictionary = UiOverlay.compare_files(CAPTURES.path_join(stem))
		if not bool(result["ok"]):
			_say(str(result["message"]))
		else:
			written += 1
			_say("compare image: " + str(result["path"]).trim_prefix("res://"))
			if not str(result["message"]).is_empty():
				_say(str(result["message"]))
	if written == 0 and names.is_empty():
		_say("no compare image: the capture has no .png (a --no-images capture writes none)")


## True when any edge of the element is further from the box's edge than the tolerance.
func _moved(box: Array, element: Array) -> bool:
	var edges: Array = [
		[float(box[0]), float(element[0])], [float(box[1]), float(element[1])],
		[float(box[0]) + float(box[2]), float(element[0]) + float(element[2])],
		[float(box[1]) + float(box[3]), float(element[1]) + float(element[3])],
	]
	for edge: Array in edges:
		if absf(float(edge[0]) - float(edge[1])) > _tolerance:
			return true
	return false


func _rect_text(rect: Array) -> String:
	return "%s, %s, %s, %s" % [_n(float(rect[0])), _n(float(rect[1])), _n(float(rect[2])), _n(float(rect[3]))]


func _numbers(text: String) -> PackedFloat64Array:
	var result: PackedFloat64Array = PackedFloat64Array()
	for part: String in text.replace("%", "").split(","):
		if part.strip_edges().is_valid_float():
			result.append(part.strip_edges().to_float())
	return result


func _n(value: float) -> String:
	var text: String = String.num(value, 1)
	return text.trim_suffix(".0") if text.ends_with(".0") else text


func _parse_size(text: String) -> Vector2i:
	var parts: PackedStringArray = text.strip_edges().to_lower().split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	return Vector2i(parts[0].to_int(), parts[1].to_int())
