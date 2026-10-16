extends SceneTree
## Screen drawings: the reader and the starter drawing · framework-owned: replaced on upgrade.
##
## The reader turns a drawing the human made in Excalidraw into drawing.json, which is small and
## holds no image (the raw .excalidraw embeds the screenshot as base64, so never read it):
##   godot --headless --path . --script tools/ui_drawing.gd -- director/ui/<id>.excalidraw design/ui/captures/<id>.drawing.json [<id>]
## An id limits the reading to the frames of that screen. The format and the rules are in
## .godot-director/procedures/ui-design.md › Reading a drawing. To tell what a box overlaps, it reads
## the element map of the frame's state and size (`<id>[.<state>]@<W>x<H>.elements.json`) from the
## folder it writes to, when that file is there.
##
## The starter drawing is what the human draws over. tools/ui_capture.gd calls starter_text() for the
## default state at the default size; this writes the same from a capture's files:
##   godot --headless --path . --script tools/ui_drawing.gd -- starter design/ui/captures/<id>@<W>x<H> <out>.excalidraw
## Everything in the starter that isn't the human's carries customData.ddd, and the reader skips it.
##
## Exit codes: 0 done · 1 the file couldn't be read or written, or holds no frame.

const SCHEMA: int = 1
const USAGE: String = "usage: godot --headless --path . --script tools/ui_drawing.gd -- <drawing.excalidraw> <drawing.json> [<screen>]  |  starter <capture without extension> <out.excalidraw>"
## A free note this close to a box (as a multiple of its own height) is a comment on that box.
const COMMENT_DISTANCE: float = 1.5
## Matches in the element map are listed above this overlap (intersection over union).
const OVERLAP_MIN: float = 0.2
## An arrow's end is on a note or a box when it is within this many pixels of it.
const ARROW_REACH: float = 10.0
## Keys a box may use; anything else in its text stays in `text`.
const KEYS: PackedStringArray = ["shows", "does", "click", "key", "size", "stick", "scroll", "empty", "hidden when"]
## Excalidraw's stroke colours (and the shades of the same families) by what they say.
const INTENTS: Dictionary = {
	"#2f9e44": "new", "#2b8a3e": "new", "#37b24d": "new", "#40c057": "new",
	"#1971c2": "keep", "#1864ab": "keep", "#1c7ed6": "keep", "#228be6": "keep",
	"#e03131": "remove", "#c92a2a": "remove", "#f03e3e": "remove", "#fa5252": "remove",
	"#f08c00": "unsure", "#e67700": "unsure", "#fd7e14": "unsure", "#f76707": "unsure",
	"#e8590c": "unsure", "#d9480f": "unsure",
}
const DIGITS: String = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
const LEGEND: PackedStringArray = [
	"Draw over the screenshot, then save as director/ui/<screen>.excalidraw",
	"One rectangle per thing you care about: its name on the first line, details below.",
	"Details the agent understands: shows: does: click: key: size: stick: scroll: empty: hidden when:",
	"Colour says what changes: green new, blue keep but move or resize,",
	"red remove (or a red X), orange not sure, black as it should be.",
	"A box inside a box means it contains it.",
	"An arrow from a note to a box is a comment; from a box to a box, a flow.",
	"Text outside the frame is notes for the whole screen (mode: replace keeps only what you drew).",
	"Delete this text when you like.",
]


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() == 3 and args[0] == "starter":
		quit(_run_starter(args[1], args[2]))
	elif args.size() == 2 or args.size() == 3:
		quit(_run_read(args[0], args[1], args[2] if args.size() == 3 else ""))
	else:
		printerr(USAGE)
		quit(1)


func _run_read(source: String, out: String, screen: String) -> int:
	if not FileAccess.file_exists(source):
		printerr("GDIR-UI-FAIL: ui_drawing: no drawing at %s" % source)
		return 1
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(source)
	var hashing: HashingContext = HashingContext.new()
	hashing.start(HashingContext.HASH_SHA1)
	hashing.update(bytes)
	var sha1: String = hashing.finish().hex_encode()
	var result: Dictionary = read_drawing(bytes.get_string_from_utf8(), source, sha1, screen, out.get_base_dir())
	if result.has("error"):
		printerr("GDIR-UI-FAIL: ui_drawing: " + str(result["error"]))
		return 1
	for warning: String in (result["warnings"] as PackedStringArray):
		print("GDIR-UI-NOTE: " + warning)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var file: FileAccess = FileAccess.open(out, FileAccess.WRITE)
	if file == null:
		printerr("GDIR-UI-FAIL: ui_drawing: can't write %s" % out)
		return 1
	file.store_string(dump(result["drawing"]) + "\n")
	file.close()
	var frames: Array = (result["drawing"] as Dictionary)["frames"]
	var boxes: int = 0
	for frame: Dictionary in frames:
		boxes += (frame["boxes"] as Array).size()
	print("GDIR-UI: read %s: %d frame%s, %d box%s" % [source, frames.size(), "" if frames.size() == 1 else "s", boxes, "" if boxes == 1 else "es"])
	return 0


func _run_starter(base: String, out: String) -> int:
	var png: PackedByteArray = FileAccess.get_file_as_bytes(base + ".png")
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(base + ".elements.json"))
	if png.is_empty() or not (json is Dictionary):
		printerr("GDIR-UI-FAIL: ui_drawing: needs %s.png and %s.elements.json" % [base, base])
		return 1
	var map: Dictionary = json
	var size_values: Array = map.get("size", [0, 0])
	var size: Vector2i = Vector2i(int(size_values[0]), int(size_values[1]))
	var text: String = starter_text(str(map.get("screen", "screen")), size, png, map.get("elements", []) as Array)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var file: FileAccess = FileAccess.open(out, FileAccess.WRITE)
	if file == null:
		printerr("GDIR-UI-FAIL: ui_drawing: can't write %s" % out)
		return 1
	file.store_string(text)
	file.close()
	return 0


# --- the reader ---------------------------------------------------------------------------------

## Reads an Excalidraw file's text. Returns {"drawing": Dictionary, "warnings": PackedStringArray},
## or {"error": String} when the text isn't JSON, isn't an Excalidraw file or has no frame.
## `screen` limits the reading to that screen's frames; captures_dir is where the element maps are.
static func read_drawing(text: String, source: String, sha1: String, screen: String, captures_dir: String) -> Dictionary:
	var reader: JSON = JSON.new()
	var parsed: Variant = reader.data if reader.parse(text) == OK else null
	if not (parsed is Dictionary):
		return {"error": "%s isn't valid JSON" % source}
	var document: Dictionary = parsed
	if str(document.get("type", "")) != "excalidraw" or not (document.get("elements") is Array):
		return {"error": "%s isn't an Excalidraw file (it needs \"type\": \"excalidraw\" and a list of elements)" % source}
	var elements: Array[Dictionary] = []
	var by_id: Dictionary = {}
	for item: Variant in (document["elements"] as Array):
		if item is Dictionary and not bool((item as Dictionary).get("isDeleted", false)):
			var element: Dictionary = item
			element["_order"] = elements.size()
			elements.append(element)
			by_id[_text(element, "id")] = element
	var files: Dictionary = {}
	if document.get("files") is Dictionary:
		files = document["files"]
	var frames: Array[Dictionary] = []
	for element: Dictionary in elements:
		if _text(element, "type") == "frame":
			var named: Dictionary = _frame_name(_text(element, "name"))
			if screen.is_empty() or str(named["screen"]) == screen:
				named["el"] = element
				frames.append(named)
	if frames.is_empty():
		if screen.is_empty():
			return {"error": "%s has no frame (the starter drawing has one, named after the screen)" % source}
		return {"error": "%s has no frame named %s (or %s.<state>, or with @<W>x<H>)" % [source, screen, screen]}
	var all_frames: Array[Dictionary] = []
	for element: Dictionary in elements:
		if _text(element, "type") == "frame":
			all_frames.append({"el": element})
	# Texts outside every frame are notes for the whole screen; other elements out there are reported.
	var file_notes: Array[String] = []
	var outside: Array = []
	for element: Dictionary in elements:
		var kind: String = _text(element, "type")
		if kind == "frame" or _is_ours(element) or _frame_of(element, all_frames, by_id, 0) >= 0:
			continue
		if kind == "text" and _text(element, "containerId").is_empty():
			var note: String = _note_text(element)
			if not note.is_empty():
				file_notes.append(note)
		elif kind != "text":
			outside.append([int(element["_order"]), "%s outside the frame near canvas (%d, %d)" % [_describe(kind), roundi(_bounds(element).get_center().x), roundi(_bounds(element).get_center().y)]])
	var warnings: PackedStringArray = PackedStringArray()
	var read_frames: Array = []
	for frame: Dictionary in frames:
		var members: Array[Dictionary] = []
		var index: int = all_frames.find_custom(func(f: Dictionary) -> bool: return f["el"] == frame["el"])
		for element: Dictionary in elements:
			if element != frame["el"] and _frame_of(element, all_frames, by_id, 0) == index:
				members.append(element)
		read_frames.append(_read_frame(frame, members, by_id, files, file_notes, outside, captures_dir, warnings))
	return {"drawing": {"schema": SCHEMA, "source": source, "sha1": sha1, "frames": read_frames}, "warnings": warnings}


static func _read_frame(frame: Dictionary, members: Array[Dictionary], by_id: Dictionary, files: Dictionary, file_notes: Array[String], outside: Array, captures_dir: String, warnings: PackedStringArray) -> Dictionary:
	var frame_element: Dictionary = frame["el"]
	var frame_rect: Rect2 = _bounds(frame_element)
	var screen: String = str(frame["screen"])
	var state: String = str(frame["state"])
	# The background image: what every position is measured against.
	var background: Dictionary = {}
	var natural: Vector2i = Vector2i.ZERO
	for element: Dictionary in members:
		if _text(element, "type") != "image" or not files.has(_text(element, "fileId")):
			continue
		var tagged: bool = _ours(element) == "background"
		if background.is_empty() or tagged or (_ours(background) != "background" and _bounds(element).get_area() > _bounds(background).get_area()):
			background = element
			if tagged:
				break
	var origin: Rect2 = frame_rect
	if not background.is_empty():
		origin = _bounds(background)
		natural = _natural_size(files[_text(background, "fileId")] as Dictionary)
	if natural == Vector2i.ZERO:
		if not background.is_empty():
			warnings.append("%s: the background image can't be decoded; positions use its size on the canvas" % screen)
		else:
			warnings.append("%s: the frame holds no background image; positions are measured against the frame" % screen)
		natural = Vector2i(roundi(origin.size.x), roundi(origin.size.y))
	var size: Vector2 = Vector2(natural)
	var map_name: String = "%s%s@%dx%d.elements.json" % [screen, "" if state == "default" else "." + state, natural.x, natural.y]
	var mapped: Array[Dictionary] = _read_map(captures_dir.path_join(map_name))
	var unparsed: Array = outside.duplicate()

	# Sort what is in the frame.
	var boxes: Array[Dictionary] = []
	var box_of: Dictionary = {}          # element id -> box
	var texts: Array[Dictionary] = []
	var linears: Array[Dictionary] = []
	for element: Dictionary in members:
		if _is_ours(element):
			continue
		var kind: String = _text(element, "type")
		match kind:
			"rectangle":
				var box: Dictionary = {"el": element, "rect": _bounds(element), "id": "b%d" % (boxes.size() + 1), "comments": [], "flows_to": [], "label_el": {}}
				boxes.append(box)
				box_of[_text(element, "id")] = box
			"text":
				texts.append(element)
			"line", "arrow":
				linears.append(element)
			_:
				if not (kind == "image" and element == background):
					unparsed.append([int(element["_order"]), "%s near (%d, %d)" % [_describe(kind), _near(element, origin, size).x, _near(element, origin, size).y]])
	var free: Array[Dictionary] = []
	for element: Dictionary in texts:
		var container: String = _text(element, "containerId")
		if container.is_empty():
			free.append(element)
		elif box_of.has(container):
			(box_of[container] as Dictionary)["label_el"] = element
		elif by_id.has(container) and _text(by_id[container] as Dictionary, "type") == "arrow":
			free.append(element)

	# Boxes: label, keys, intent, parent, overlaps.
	for box: Dictionary in boxes:
		var element: Dictionary = box["el"]
		var full: String = ""
		if not (box["label_el"] as Dictionary).is_empty():
			full = _note_text(box["label_el"] as Dictionary)
		var lines: PackedStringArray = full.split("\n")
		var keys: Dictionary = {}
		for line_number: int in range(1, lines.size()):
			var colon: int = lines[line_number].find(":")
			if colon > 0 and KEYS.has(lines[line_number].substr(0, colon).strip_edges().to_lower()):
				keys[lines[line_number].substr(0, colon).strip_edges().to_lower()] = lines[line_number].substr(colon + 1).strip_edges()
		box["label"] = lines[0].strip_edges() if not lines.is_empty() else ""
		box["text"] = full
		box["keys"] = keys
		box["intent"] = _intent(_text(element, "strokeColor"))
		var parent: Dictionary = {}
		for other: Dictionary in boxes:
			var outer: Rect2 = other["rect"]
			var inner: Rect2 = box["rect"]
			if other != box and outer.get_area() > inner.get_area() and outer.grow(0.5).encloses(inner):
				if parent.is_empty() or outer.get_area() < (parent["rect"] as Rect2).get_area():
					parent = other
		box["parent"] = null if parent.is_empty() else parent["id"]
		var overlaps: Array = []
		var pixels: Rect2 = _to_pixels(box["rect"], origin, size)
		for entry: Dictionary in mapped:
			var iou: float = _iou(pixels, _map_rect(entry))
			if iou > OVERLAP_MIN:
				overlaps.append({"n": int(entry.get("n", 0)), "name": str(entry.get("id", "")), "iou": roundf(iou * 100.0) / 100.0})
		overlaps.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["iou"]) > float(b["iou"]) or (float(a["iou"]) == float(b["iou"]) and int(a["n"]) < int(b["n"])))
		box["overlaps"] = overlaps

	# A red X: two red strokes crossing. It removes the element it is over.
	var removed: Array = []
	var used: Dictionary = {}
	var strokes: Array[Dictionary] = []
	for element: Dictionary in linears:
		if _intent(_text(element, "strokeColor")) == "remove" and _points(element).size() == 2 and element.get("startBinding") == null and element.get("endBinding") == null:
			strokes.append(element)
	for first: int in strokes.size():
		for second: int in range(first + 1, strokes.size()):
			if used.has(first) or used.has(second):
				continue
			var a: PackedVector2Array = _points(strokes[first])
			var b: PackedVector2Array = _points(strokes[second])
			if not Geometry2D.segment_intersects_segment(a[0], a[1], b[0], b[1]) is Vector2:
				continue
			used[first] = true
			used[second] = true
			var x_rect: Rect2 = _bounds(strokes[first]).merge(_bounds(strokes[second]))
			var hit: Dictionary = _element_under(_to_pixels(x_rect, origin, size), mapped)
			if hit.is_empty():
				unparsed.append([int(strokes[first]["_order"]), "a red X near (%d, %d) over no element in the element map" % [_near_rect(x_rect, origin, size).x, _near_rect(x_rect, origin, size).y]])
			else:
				var entry_removed: Dictionary = {"n": int(hit.get("n", 0)), "name": str(hit.get("id", "")), "by": "red-x"}
				if not removed.has(entry_removed):
					removed.append(entry_removed)
	removed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["n"]) < int(b["n"]))

	# Other strokes: an arrow joining a note and a box is a comment, one joining two boxes is a flow.
	var consumed: Dictionary = {}        # text element id -> true
	var comments: Array = []             # [text order, box, text]
	for index: int in linears.size():
		var element: Dictionary = linears[index]
		var strokes_index: int = strokes.find(element)
		if strokes_index >= 0 and used.has(strokes_index):
			continue
		var points: PackedVector2Array = _points(element)
		if _text(element, "type") != "arrow" or points.size() < 2:
			unparsed.append([int(element["_order"]), "%s near (%d, %d)" % [_describe(_text(element, "type")), _near(element, origin, size).x, _near(element, origin, size).y]])
			continue
		var from_end: Dictionary = _end(element.get("startBinding"), points[0], boxes, box_of, free, by_id)
		var to_end: Dictionary = _end(element.get("endBinding"), points[points.size() - 1], boxes, box_of, free, by_id)
		var kinds: String = str(from_end.get("kind", "")) + "+" + str(to_end.get("kind", ""))
		if kinds == "text+box" or kinds == "box+text":
			var note_end: Dictionary = from_end if from_end["kind"] == "text" else to_end
			var box_end: Dictionary = to_end if from_end["kind"] == "text" else from_end
			consumed[_text(note_end["el"] as Dictionary, "id")] = true
			comments.append([int((note_end["el"] as Dictionary)["_order"]), box_end["box"], _note_text(note_end["el"] as Dictionary)])
		elif kinds == "box+box" and from_end["box"] != to_end["box"]:
			var flows: Array = (from_end["box"] as Dictionary)["flows_to"]
			if not flows.has((to_end["box"] as Dictionary)["id"]):
				flows.append((to_end["box"] as Dictionary)["id"])
		else:
			unparsed.append([int(element["_order"]), "an arrow near (%d, %d) that doesn't join a note and a box, or two boxes" % [_near(element, origin, size).x, _near(element, origin, size).y]])

	# Free text: a comment on a box close to it, otherwise a note for the frame.
	var notes: Array = []
	for element: Dictionary in free:
		if consumed.has(_text(element, "id")):
			continue
		var note: String = _note_text(element)
		if note.is_empty():
			continue
		var rect: Rect2 = _bounds(element)
		var nearest: Dictionary = {}
		var nearest_gap: float = 0.0
		for box: Dictionary in boxes:
			var gap: float = _gap(rect, box["rect"])
			if gap <= COMMENT_DISTANCE * rect.size.y and (nearest.is_empty() or gap < nearest_gap or (gap == nearest_gap and (box["rect"] as Rect2).get_area() < (nearest["rect"] as Rect2).get_area())):
				nearest = box
				nearest_gap = gap
		if nearest.is_empty():
			notes.append(note)
		else:
			comments.append([int(element["_order"]), nearest, note])
	comments.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	for comment: Array in comments:
		((comment[1] as Dictionary)["comments"] as Array).append(comment[2])
	notes.append_array(file_notes)
	var mode: String = "patch"
	for note: String in notes:
		for line: String in note.split("\n"):
			var cleaned: String = line.strip_edges().to_lower()
			if cleaned == "mode: replace" or cleaned == "mode: patch":
				mode = cleaned.trim_prefix("mode:").strip_edges()

	unparsed.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	var unparsed_texts: Array = []
	for item: Array in unparsed:
		unparsed_texts.append(item[1])
	var box_rows: Array = []
	for box: Dictionary in boxes:
		var unit: Rect2 = _to_unit(box["rect"], origin)
		box_rows.append({
			"id": box["id"], "label": box["label"], "text": box["text"], "keys": box["keys"],
			"intent": box["intent"],
			"rect_pct": [_pct(unit.position.x), _pct(unit.position.y), _pct(unit.size.x), _pct(unit.size.y)],
			"parent": box["parent"], "comments": box["comments"], "flows_to": box["flows_to"],
			"overlaps": box["overlaps"],
		})
	return {
		"name": screen, "state": state, "size": [natural.x, natural.y], "mode": mode,
		"notes": notes, "boxes": box_rows, "removed": removed, "unparsed": unparsed_texts,
	}


## "hero_room", "hero_room.exhausted", "hero_room@2560x1080" or both: the screen and the state.
static func _frame_name(name: String) -> Dictionary:
	var head: String = name.strip_edges()
	var at: int = head.rfind("@")
	if at >= 0 and head.substr(at + 1).to_lower().contains("x") and head.substr(at + 1).replace("x", "").replace("X", "").is_valid_int():
		head = head.substr(0, at)
	var dot: int = head.find(".")
	if dot > 0:
		return {"screen": head.substr(0, dot), "state": head.substr(dot + 1)}
	return {"screen": head, "state": "default"}


## The index of the frame an element is in: the one it names, else the one holding its centre. A
## text bound to a rectangle goes where the rectangle goes. -1 when it is in none.
static func _frame_of(element: Dictionary, frames: Array[Dictionary], by_id: Dictionary, depth: int) -> int:
	var container: String = _text(element, "containerId")
	if not container.is_empty() and by_id.has(container) and depth < 3:
		return _frame_of(by_id[container] as Dictionary, frames, by_id, depth + 1)
	var named: String = _text(element, "frameId")
	for index: int in frames.size():
		if not named.is_empty() and _text(frames[index]["el"] as Dictionary, "id") == named:
			return index
	for index: int in frames.size():
		if _bounds(frames[index]["el"] as Dictionary).has_point(_bounds(element).get_center()):
			return index
	return -1


static func _read_map(path: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not FileAccess.file_exists(path):
		return result
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if json is Dictionary and (json as Dictionary).get("elements") is Array:
		for item: Variant in ((json as Dictionary)["elements"] as Array):
			if item is Dictionary and bool((item as Dictionary).get("visible", true)):
				result.append(item)
	return result


static func _map_rect(entry: Dictionary) -> Rect2:
	var values: Array = entry.get("rect", [0, 0, 0, 0])
	return Rect2(float(values[0]), float(values[1]), float(values[2]), float(values[3]))


## The mapped element an X is over: the smallest one holding its centre, else the best overlap.
static func _element_under(pixels: Rect2, mapped: Array[Dictionary]) -> Dictionary:
	var best: Dictionary = {}
	for entry: Dictionary in mapped:
		var rect: Rect2 = _map_rect(entry)
		if rect.has_point(pixels.get_center()) and (best.is_empty() or rect.get_area() < _map_rect(best).get_area()):
			best = entry
	if not best.is_empty():
		return best
	var best_iou: float = OVERLAP_MIN
	for entry: Dictionary in mapped:
		var iou: float = _iou(pixels, _map_rect(entry))
		if iou > best_iou:
			best = entry
			best_iou = iou
	return best


## What one end of an arrow touches: {"kind": "text", "el": ...}, {"kind": "box", "box": ...} or {}.
static func _end(binding: Variant, point: Vector2, boxes: Array[Dictionary], box_of: Dictionary, free: Array[Dictionary], by_id: Dictionary) -> Dictionary:
	if binding is Dictionary and by_id.has(str((binding as Dictionary).get("elementId", ""))):
		var target: Dictionary = by_id[str((binding as Dictionary)["elementId"])]
		var container: String = _text(target, "containerId")
		if box_of.has(_text(target, "id")):
			return {"kind": "box", "box": box_of[_text(target, "id")]}
		if box_of.has(container):
			return {"kind": "box", "box": box_of[container]}
		if free.has(target):
			return {"kind": "text", "el": target}
	var best: Dictionary = {}
	var best_area: float = INF
	for element: Dictionary in free:
		var rect: Rect2 = _bounds(element)
		if rect.grow(ARROW_REACH).has_point(point) and rect.get_area() < best_area:
			best = {"kind": "text", "el": element}
			best_area = rect.get_area()
	for box: Dictionary in boxes:
		var rect: Rect2 = box["rect"]
		if rect.grow(ARROW_REACH).has_point(point) and rect.get_area() < best_area:
			best = {"kind": "box", "box": box}
			best_area = rect.get_area()
	return best


static func _intent(stroke: String) -> String:
	return str(INTENTS.get(stroke.to_lower(), "default"))


static func _describe(kind: String) -> String:
	match kind:
		"freedraw":
			return "a freehand line"
		"ellipse":
			return "an ellipse"
		"diamond":
			return "a diamond"
		"image":
			return "an image"
		"line":
			return "a line"
		"arrow":
			return "an arrow"
		"rectangle":
			return "a rectangle"
		"text":
			return "a text"
	return "an element of type %s" % kind


static func _ours(element: Dictionary) -> String:
	var data: Variant = element.get("customData")
	return str((data as Dictionary).get("ddd", "")) if data is Dictionary else ""


static func _is_ours(element: Dictionary) -> bool:
	return not _ours(element).is_empty()


static func _text(element: Dictionary, key: String) -> String:
	var value: Variant = element.get(key)
	return "" if value == null else str(value)


static func _number(element: Dictionary, key: String) -> float:
	var value: Variant = element.get(key)
	return float(value) if value is float or value is int else 0.0


static func _note_text(element: Dictionary) -> String:
	var original: String = _text(element, "originalText")
	return (original if not original.is_empty() else _text(element, "text")).strip_edges()


## The canvas points of a line, arrow or freehand stroke.
static func _points(element: Dictionary) -> PackedVector2Array:
	var result: PackedVector2Array = PackedVector2Array()
	if element.get("points") is Array:
		for item: Variant in (element["points"] as Array):
			if item is Array and (item as Array).size() >= 2:
				result.append(Vector2(_number(element, "x") + float((item as Array)[0]), _number(element, "y") + float((item as Array)[1])))
	return result


## The canvas rect an element covers.
static func _bounds(element: Dictionary) -> Rect2:
	var points: PackedVector2Array = _points(element)
	if not points.is_empty():
		var rect: Rect2 = Rect2(points[0], Vector2.ZERO)
		for point: Vector2 in points:
			rect = rect.expand(point)
		return rect
	return Rect2(_number(element, "x"), _number(element, "y"), _number(element, "width"), _number(element, "height")).abs()


static func _to_unit(rect: Rect2, origin: Rect2) -> Rect2:
	return Rect2((rect.position - origin.position) / origin.size, rect.size / origin.size)


static func _to_pixels(rect: Rect2, origin: Rect2, size: Vector2) -> Rect2:
	var unit: Rect2 = _to_unit(rect, origin)
	return Rect2(unit.position * size, unit.size * size)


static func _pct(unit: float) -> float:
	return roundf(unit * 1000.0) / 10.0 + 0.0


static func _iou(a: Rect2, b: Rect2) -> float:
	var overlap: float = a.intersection(b).get_area()
	var union: float = a.get_area() + b.get_area() - overlap
	return overlap / union if union > 0.0 else 0.0


## The distance between two rects, 0 when they touch or overlap.
static func _gap(a: Rect2, b: Rect2) -> float:
	var dx: float = maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dy: float = maxf(0.0, maxf(a.position.y - b.end.y, b.position.y - a.end.y))
	return sqrt(dx * dx + dy * dy)


static func _near(element: Dictionary, origin: Rect2, size: Vector2) -> Vector2i:
	return _near_rect(_bounds(element), origin, size)


## The centre of a canvas rect in capture pixels, for the messages in `unparsed`.
static func _near_rect(rect: Rect2, origin: Rect2, size: Vector2) -> Vector2i:
	return Vector2i(_to_pixels(rect, origin, size).get_center().round())


## The size of the image a file entry holds: read from a PNG's header, decoded otherwise.
static func _natural_size(file: Dictionary) -> Vector2i:
	var url: String = str(file.get("dataURL", ""))
	var marker: int = url.find("base64,")
	if marker < 0:
		return Vector2i.ZERO
	var bytes: PackedByteArray = Marshalls.base64_to_raw(url.substr(marker + 7))
	if bytes.size() >= 24 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
		return Vector2i(_be32(bytes, 16), _be32(bytes, 20))
	var image: Image = Image.new()
	var error: Error = ERR_FILE_UNRECOGNIZED
	if url.begins_with("data:image/jpeg"):
		error = image.load_jpg_from_buffer(bytes)
	elif url.begins_with("data:image/webp"):
		error = image.load_webp_from_buffer(bytes)
	return image.get_size() if error == OK else Vector2i.ZERO


static func _be32(bytes: PackedByteArray, at: int) -> int:
	return (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]


# --- the starter drawing ------------------------------------------------------------------------

## The starter drawing for a screen's default state: a frame named after the screen, exactly the size
## of the capture, with the capture locked inside as the background; a faint, locked group of the
## mapped elements (`existing`, numbered as in the map image) that can be hidden or deleted; and a
## legend outside the frame. Valid current-format Excalidraw JSON, deterministic for the same input.
static func starter_text(screen: String, size: Vector2i, png: PackedByteArray, mapped: Array) -> String:
	var hashing: HashingContext = HashingContext.new()
	hashing.start(HashingContext.HASH_SHA1)
	hashing.update(png)
	var file_id: String = hashing.finish().hex_encode()
	var frame_id: String = "ddd-frame"
	var items: Array[Dictionary] = []
	var background: Dictionary = _base("ddd-background", "image", items.size(), 0, 0, size.x, size.y, frame_id)
	background["locked"] = true
	background["fileId"] = file_id
	background["status"] = "saved"
	background["scale"] = [1, 1]
	background["crop"] = null
	background["customData"] = {"ddd": "background"}
	items.append(background)
	for entry: Variant in mapped:
		if not (entry is Dictionary):
			continue
		var rect: Rect2i = Rect2i(_map_rect(entry as Dictionary))
		var number: int = int((entry as Dictionary).get("n", 0))
		var outline: Dictionary = _base("ddd-existing-%d" % number, "rectangle", items.size(), rect.position.x, rect.position.y, maxi(rect.size.x, 1), maxi(rect.size.y, 1), frame_id)
		outline["strokeColor"] = "#868e96"
		outline["strokeWidth"] = 1
		outline["opacity"] = 25
		outline["locked"] = true
		outline["groupIds"] = ["ddd-existing"]
		outline["customData"] = {"ddd": "existing", "n": number}
		items.append(outline)
		var label: Dictionary = _text_element("ddd-existing-label-%d" % number, items.size(), rect.position.x + 2, rect.position.y + 1, str(number), 14, frame_id)
		label["strokeColor"] = "#868e96"
		label["opacity"] = 25
		label["locked"] = true
		label["groupIds"] = ["ddd-existing"]
		label["customData"] = {"ddd": "existing", "n": number}
		items.append(label)
	var frame: Dictionary = _base(frame_id, "frame", items.size(), 0, 0, size.x, size.y, "")
	frame["strokeColor"] = "#bbbbbb"
	frame["strokeWidth"] = 1
	frame["name"] = screen
	items.append(frame)
	var legend: Dictionary = _text_element("ddd-legend", items.size(), size.x + 60, 0, "\n".join(LEGEND).replace("<screen>", screen), 20, "")
	legend["customData"] = {"ddd": "legend"}
	items.append(legend)
	var document: Dictionary = {
		"type": "excalidraw", "version": 2, "source": "https://excalidraw.com",
		"elements": items,
		"appState": {"gridSize": null, "viewBackgroundColor": "#ffffff"},
		"files": {file_id: {"mimeType": "image/png", "id": file_id, "dataURL": "data:image/png;base64," + Marshalls.raw_to_base64(png), "created": 1, "lastRetrieved": 1}},
	}
	return dump(document) + "\n"


## The screenshot a drawing was made over: the background image of the frame for the given screen
## and state, decoded. null when the frame or its image isn't there.
static func background_image(text: String, screen: String, state: String) -> Image:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("elements") is Array):
		return null
	var document: Dictionary = parsed
	var files: Dictionary = {}
	if document.get("files") is Dictionary:
		files = document["files"]
	var frame: Dictionary = {}
	var images: Array[Dictionary] = []
	for item: Variant in (document["elements"] as Array):
		if not (item is Dictionary) or bool((item as Dictionary).get("isDeleted", false)):
			continue
		var element: Dictionary = item
		var kind: String = _text(element, "type")
		if kind == "frame":
			var named: Dictionary = _frame_name(_text(element, "name"))
			if frame.is_empty() and str(named["screen"]) == screen and str(named["state"]) == state:
				frame = element
		elif kind == "image" and files.has(_text(element, "fileId")):
			images.append(element)
	if frame.is_empty():
		return null
	var frame_rect: Rect2 = _bounds(frame)
	var best: Dictionary = {}
	for element: Dictionary in images:
		var inside: bool = _text(element, "frameId") == _text(frame, "id") or frame_rect.has_point(_bounds(element).get_center())
		if not inside:
			continue
		if best.is_empty() or _ours(element) == "background" or (_ours(best) != "background" and _bounds(element).get_area() > _bounds(best).get_area()):
			best = element
	if best.is_empty():
		return null
	var url: String = str((files[_text(best, "fileId")] as Dictionary).get("dataURL", ""))
	var marker: int = url.find(";base64,")
	if marker < 0:
		return null
	var bytes: PackedByteArray = Marshalls.base64_to_raw(url.substr(marker + 8))
	var image: Image = Image.new()
	if image.load_png_from_buffer(bytes) != OK and image.load_jpg_from_buffer(bytes) != OK:
		return null
	return image


## The fields every Excalidraw element has (types.ts › _ExcalidrawElementBase).
static func _base(id: String, type: String, index: int, x: int, y: int, width: int, height: int, frame_id: String) -> Dictionary:
	return {
		"id": id, "type": type, "x": x, "y": y, "width": width, "height": height, "angle": 0,
		"strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid",
		"strokeWidth": 2, "strokeStyle": "solid", "roughness": 0, "opacity": 100,
		"groupIds": [], "frameId": null if frame_id.is_empty() else frame_id,
		"index": _fractional_index(index), "roundness": null,
		"seed": 1000003 + index * 7919, "version": 1, "versionNonce": 2000003 + index * 104729,
		"isDeleted": false, "boundElements": null, "updated": 1, "link": null, "locked": false, "created": null,
	}


static func _text_element(id: String, index: int, x: int, y: int, text: String, font_size: int, frame_id: String) -> Dictionary:
	var lines: PackedStringArray = text.split("\n")
	var longest: int = 0
	for line: String in lines:
		longest = maxi(longest, line.length())
	var element: Dictionary = _base(id, "text", index, x, y, ceili(longest * font_size * 0.6), ceili(lines.size() * font_size * 1.25), frame_id)
	element["fontSize"] = font_size
	element["fontFamily"] = 5
	element["baseFontSize"] = null
	element["text"] = text
	element["textAlign"] = "left"
	element["verticalAlign"] = "top"
	element["containerId"] = null
	element["originalText"] = text
	element["autoResize"] = true
	element["lineHeight"] = 1.25
	return element


## Excalidraw's fractional indices ("a0", "a1" ... "aZ", "az", "b00" ...), in array order.
static func _fractional_index(position: int) -> String:
	if position < DIGITS.length():
		return "a" + DIGITS[position]
	var rest: int = position - DIGITS.length()
	return "b" + DIGITS[(rest / DIGITS.length()) % DIGITS.length()] + DIGITS[rest % DIGITS.length()]


# --- output -------------------------------------------------------------------------------------

## JSON with sorted keys for the reader's output, one key per line and lists of plain values on one
## line, so the file reads and diffs well.
static func dump(value: Variant, indent: int = 0) -> String:
	var pad: String = "  ".repeat(indent + 1)
	var close: String = "  ".repeat(indent)
	if value is Dictionary:
		var map: Dictionary = value
		if map.is_empty():
			return "{}"
		var keys: Array = map.keys()
		keys.sort()
		var rows: PackedStringArray = PackedStringArray()
		for key: Variant in keys:
			rows.append("%s%s: %s" % [pad, JSON.stringify(str(key)), dump(map[key], indent + 1)])
		return "{\n" + ",\n".join(rows) + "\n" + close + "}"
	if value is Array:
		var list: Array = value
		var flat: bool = true
		for item: Variant in list:
			if item is Dictionary or item is Array:
				flat = false
		var parts: PackedStringArray = PackedStringArray()
		for item: Variant in list:
			parts.append(dump(item, indent + 1) if not flat else JSON.stringify(item))
		if list.is_empty():
			return "[]"
		if flat:
			return "[" + ", ".join(parts) + "]"
		var lines: PackedStringArray = PackedStringArray()
		for part: String in parts:
			lines.append(pad + part)
		return "[\n" + ",\n".join(lines) + "\n" + close + "]"
	return JSON.stringify(value)
