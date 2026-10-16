extends SceneTree
## Overlay images for screen captures · framework-owned: replaced on upgrade.
##
## Draws on a capture with Image operations only, so it runs headless:
##   godot --headless --path . --script tools/ui_overlay.gd -- map design/ui/captures/<id>@<W>x<H>
## writes <id>@<W>x<H>.map.png from that capture's .png and .elements.json: every mapped element
## outlined and numbered, the numbers being the element map's `n`. tools/ui_capture.gd calls
## draw_map() itself. Labels use the small bitmap font below, since nothing is rendered headless.

const OUTLINE: Color = Color(1.0, 0.0, 0.85)
const LABEL_TEXT: Color = Color(1.0, 1.0, 1.0)
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
}


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] != "map":
		printerr("usage: godot --headless --path . --script tools/ui_overlay.gd -- map <capture without extension>")
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


static func _outline(image: Image, rect: Rect2i, bounds: Rect2i) -> void:
	for edge: Rect2i in [
		Rect2i(rect.position.x, rect.position.y, rect.size.x, 2),
		Rect2i(rect.position.x, rect.end.y - 2, rect.size.x, 2),
		Rect2i(rect.position.x, rect.position.y, 2, rect.size.y),
		Rect2i(rect.end.x - 2, rect.position.y, 2, rect.size.y),
	]:
		var visible: Rect2i = edge.intersection(bounds)
		if visible.has_area():
			image.fill_rect(visible, OUTLINE)


static func _label_size(text: String) -> Vector2i:
	return Vector2i(text.length() * (GLYPH_WIDTH + 1) * SCALE + SCALE * 2, (GLYPH_HEIGHT + 2) * SCALE)


static func _label(image: Image, text: String, at: Vector2i, bounds: Rect2i) -> void:
	var background: Rect2i = Rect2i(at, _label_size(text)).intersection(bounds)
	if background.has_area():
		image.fill_rect(background, OUTLINE)
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
