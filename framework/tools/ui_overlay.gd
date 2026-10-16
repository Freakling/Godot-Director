extends SceneTree
## Overlay images for screen captures · framework-owned: replaced on upgrade.
##
## Draws on a capture with Image operations only, so it runs headless:
##   godot --headless --path . --script tools/ui_overlay.gd -- map design/ui/captures/<id>@<W>x<H>
## writes <id>@<W>x<H>.map.png from that capture's .png and .elements.json: every mapped element
## outlined and numbered, the numbers being the element map's `n`. tools/ui_capture.gd calls
## draw_map() itself.
##   godot --headless --path . --script tools/ui_overlay.gd -- compare design/ui/captures/<id>@<W>x<H>
## writes <id>.compare@<W>x<H>.png (<id>.<state>.compare@... for another state): the screenshot the
## human's drawing was made over on the left, and the new capture on the right with the drawing's boxes
## outlined and labelled (b1, b2 ... in drawing.json's order), coloured by intent: green new, blue keep,
## red remove, orange unsure, dark default. tools/ui_verify.gd draws it too.
## Labels use the small bitmap font below, since nothing is rendered headless.

const OUTLINE: Color = Color(1.0, 0.0, 0.85)
const LABEL_TEXT: Color = Color(1.0, 1.0, 1.0)
const UiDrawing := preload("res://tools/ui_drawing.gd")
const INTENT_COLORS: Dictionary = {
	"new": Color("2f9e44"), "keep": Color("1971c2"), "remove": Color("e03131"),
	"unsure": Color("f08c00"), "default": Color("212529"),
}
const GAP: int = 8
const SCALE: int = 3            # font pixels per glyph pixel
const GLYPH_WIDTH: int = 5
const GLYPH_HEIGHT: int = 7
## 5 x 7 glyphs, row by row; "1" is a lit pixel.
const GLYPHS: Dictionary = {
	"0": "01110100011001110101110011000101110", "1": "00100011000010000100001000010001110",
	"2": "01110100010000100010001000100011111", "3": "11110000010000101110000010000111110",
	"4": "00010001100101010010111110001000010", "5": "11111100001111000001000011000101110",
	"6": "00110010001000011110100011000101110", "7": "11111000010001000100010000100001000",
	"8": "01110100011000101110100011000101110", "9": "01110100011000101111000010001001100",
	"b": "10000100001011011001100011000111110",
}


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() == 2 and args[0] == "compare":
		var result: Dictionary = compare_files(args[1])
		if not str(result["message"]).is_empty():
			print(("GDIR-UI-NOTE: " if bool(result["ok"]) else "GDIR-UI-FAIL: ") + str(result["message"]))
		quit(0 if bool(result["ok"]) else 1)
		return
	if args.size() != 2 or args[0] != "map":
		printerr("usage: godot --headless --path . --script tools/ui_overlay.gd -- map|compare <capture without extension>")
		quit(1)
		return
	var base: String = args[1].trim_suffix(".png")
	var image: Image = Image.load_from_file(ProjectSettings.globalize_path(base + ".png"))
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(base + ".elements.json"))
	if image == null or not (json is Dictionary):
		printerr("ui_overlay: needs %s.png and %s.elements.json" % [base, base])
		quit(1)
		return
	var map: Dictionary = json
	var boxes: Array = (map.get("elements", []) as Array) + (map.get("pickables_3d", []) as Array)
	var error: Error = draw_map(image, boxes).save_png(ProjectSettings.globalize_path(base + ".map.png"))
	quit(0 if error == OK else 1)


## A copy of the capture with each element's rect outlined and labelled with its number.
static func draw_map(capture: Image, boxes: Array) -> Image:
	var image: Image = capture.duplicate() as Image
	image.convert(Image.FORMAT_RGBA8)
	var bounds: Rect2i = Rect2i(Vector2i.ZERO, image.get_size())
	for box: Variant in boxes:
		var entry: Dictionary = box
		var values: Array = entry.get("rect", [0, 0, 0, 0])
		var rect: Rect2i = Rect2i(int(values[0]), int(values[1]), int(values[2]), int(values[3]))
		_outline(image, rect, bounds)
		var label: String = str(int(entry.get("n", 0)))
		var at: Vector2i = rect.position.clamp(Vector2i.ZERO, bounds.end - _label_size(label))
		_label(image, label, at, bounds)
	return image


static func _outline(image: Image, rect: Rect2i, bounds: Rect2i, color: Color = OUTLINE) -> void:
	for edge: Rect2i in [
		Rect2i(rect.position.x, rect.position.y, rect.size.x, 2),
		Rect2i(rect.position.x, rect.end.y - 2, rect.size.x, 2),
		Rect2i(rect.position.x, rect.position.y, 2, rect.size.y),
		Rect2i(rect.end.x - 2, rect.position.y, 2, rect.size.y),
	]:
		var visible: Rect2i = edge.intersection(bounds)
		if visible.has_area():
			image.fill_rect(visible, color)


static func _label_size(text: String) -> Vector2i:
	return Vector2i(text.length() * (GLYPH_WIDTH + 1) * SCALE + SCALE * 2, (GLYPH_HEIGHT + 2) * SCALE)


static func _label(image: Image, text: String, at: Vector2i, bounds: Rect2i, color: Color = OUTLINE) -> void:
	var background: Rect2i = Rect2i(at, _label_size(text)).intersection(bounds)
	if background.has_area():
		image.fill_rect(background, color)
	var x: int = at.x + SCALE * 2
	for character: String in text:
		var rows: String = str(GLYPHS.get(character, ""))
		for pixel: int in rows.length():
			if rows[pixel] != "1":
				continue
			var dot: Rect2i = Rect2i(x + (pixel % GLYPH_WIDTH) * SCALE, at.y + SCALE + (pixel / GLYPH_WIDTH) * SCALE, SCALE, SCALE)
			var shown: Rect2i = dot.intersection(bounds)
			if shown.has_area():
				image.fill_rect(shown, LABEL_TEXT)
		x += (GLYPH_WIDTH + 1) * SCALE


## The comparison: the screenshot the drawing was made over (original; a dark panel when null) on the
## left, the capture on the right with each drawing box (rect_pct, intent, id) outlined and labelled.
static func draw_compare(capture: Image, boxes: Array, original: Image) -> Image:
	var size: Vector2i = capture.get_size()
	var result: Image = Image.create(size.x * 2 + GAP, size.y, false, Image.FORMAT_RGBA8)
	result.fill(Color(0.15, 0.15, 0.15))
	if original != null:
		var left: Image = original.duplicate() as Image
		left.convert(Image.FORMAT_RGBA8)
		if left.get_size() != size:
			left.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
		result.blit_rect(left, Rect2i(Vector2i.ZERO, size), Vector2i.ZERO)
	var right: Image = capture.duplicate() as Image
	right.convert(Image.FORMAT_RGBA8)
	var bounds: Rect2i = Rect2i(Vector2i.ZERO, size)
	for item: Variant in boxes:
		var box: Dictionary = item
		var pct: Array = box.get("rect_pct", [0, 0, 0, 0])
		var rect: Rect2i = Rect2i(
			roundi(float(pct[0]) / 100.0 * size.x), roundi(float(pct[1]) / 100.0 * size.y),
			roundi(float(pct[2]) / 100.0 * size.x), roundi(float(pct[3]) / 100.0 * size.y))
		var color: Color = INTENT_COLORS.get(str(box.get("intent", "default")), INTENT_COLORS["default"])
		_outline(right, rect, bounds, color)
		var label: String = str(box.get("id", ""))
		_label(right, label, rect.position.clamp(Vector2i.ZERO, bounds.end - _label_size(label)), bounds, color)
	result.blit_rect(right, bounds, Vector2i(size.x + GAP, 0))
	return result


## Writes the comparison for a capture (`<folder>/<id>[.<state>]@<W>x<H>`, no extension) from its
## .png, the drawing's boxes in `<folder>/<id>.drawing.json` and the screenshot inside the drawing
## itself. Returns {"ok", "message", "path"}: ok with a message when it was drawn without the
## original, and not ok when there is no capture image or no reading of the drawing to compare with.
static func compare_files(base: String) -> Dictionary:
	var folder: String = _res(base).get_base_dir()
	var name: String = base.get_file()
	var at: int = name.rfind("@")
	if at < 0:
		return {"ok": false, "message": "ui_overlay: %s isn't <id>[.<state>]@<W>x<H>" % base, "path": ""}
	var head: String = name.substr(0, at)
	var id: String = head.get_slice(".", 0)
	var state: String = head.substr(id.length() + 1) if head.contains(".") else "default"
	var image: Image = Image.load_from_file(ProjectSettings.globalize_path(_res(base + ".png")))
	if image == null:
		return {"ok": false, "message": "ui_overlay: no capture image %s.png (a capture with --no-images writes none)" % base, "path": ""}
	var reading: Variant = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join(id + ".drawing.json")))
	if not (reading is Dictionary):
		return {"ok": false, "message": "ui_overlay: no %s.drawing.json: process the drawing first" % id, "path": ""}
	var boxes: Array = []
	for frame: Variant in ((reading as Dictionary).get("frames", []) as Array):
		if frame is Dictionary and str((frame as Dictionary).get("name", "")) == id and str((frame as Dictionary).get("state", "default")) == state:
			boxes = (frame as Dictionary).get("boxes", []) as Array
	var note: String = ""
	var original: Image = null
	var source: String = str((reading as Dictionary).get("source", ""))
	if FileAccess.file_exists(_res(source)):
		original = UiDrawing.background_image(FileAccess.get_file_as_string(_res(source)), id, state)
	if original == null:
		note = "the drawing %s holds no screenshot to put beside the capture" % source
	var out: String = folder.path_join("%s%s.compare%s" % [id, "" if state == "default" else "." + state, name.substr(at)]) + ".png"
	var error: Error = draw_compare(image, boxes, original).save_png(ProjectSettings.globalize_path(out))
	if error != OK:
		return {"ok": false, "message": "ui_overlay: can't write %s" % out, "path": out}
	return {"ok": true, "message": note, "path": out}


static func _res(path: String) -> String:
	return path if path.begins_with("res://") or path.is_absolute_path() else "res://" + path
