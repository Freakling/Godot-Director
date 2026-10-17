extends RefCounted
## Element map and layout lint for screen captures · framework-owned: replaced on upgrade.
##
## map() lists what is on screen: the element map of .godot-director/procedures/ui-design.md.
## findings() lints the mapped elements, one line per finding: `<rule> element <n> <path>: <message>`.
## element_map() writes the mapped elements as an .elements.json file's text. They read the live scene
## tree and work with or without a display; tools/ui_capture.gd and tools/autoplay.gd use them.
## Don't edit this file in a project; thresholds are in tools/ui_capture.cfg › [lint].

## The rules, in the order findings are listed for an element.
const RULES: PackedStringArray = [
	"squeezed-text", "stretched-control", "off-screen", "overlap", "unreachable",
	"no-default-focus", "hard-coded-position",
]
const NAME_LENGTH: int = 24
## Properties that place a Control in pixels. Saved on a Container's child, the Container overrides them.
const POSITION_PROPERTIES: PackedStringArray = [
	"position", "offset_left", "offset_top", "offset_right", "offset_bottom",
]
const SAMPLE_TEXT: String = "The quick brown fox jumps over the lazy dog"

var min_label_chars: int = 6
var max_button_height_ratio: float = 2.0
var max_elements: int = 200

## The element map: one Dictionary per mapped element, in tree order, numbered from 1.
var elements: Array[Dictionary] = []
## Clickable 3D objects projected through the active camera, numbered after the elements.
var pickables_3d: Array[Dictionary] = []
## True when the screen had more than max_elements elements.
var capped: bool = false

var _nodes: Array[Control] = []          # the mapped controls, in the order of elements
var _canvas: Array[Rect2] = []           # their rects in their own viewport's canvas
var _focus_order: Dictionary = {}        # Control -> position in focus traversal (1 = default focus)
var _viewports: Array[Viewport] = []     # the screen's viewport and every visible embedded Window
var _focusables: Dictionary = {}         # Viewport -> Array of its visible focusable controls
var _scene_states: Dictionary = {}       # scene path -> SceneState, for hard-coded-position


## Maps the screen shown in root. to_pixels turns its canvas coordinates into capture pixels; size
## is the capture.
func map(root: Viewport, to_pixels: Transform2D, size: Vector2i) -> void:
	elements.clear()
	pickables_3d.clear()
	_nodes.clear()
	_canvas.clear()
	_focus_order.clear()
	_viewports.clear()
	_focusables.clear()
	capped = false
	var visible: Array[Control] = []
	var offsets: Dictionary = {}   # Control -> offset of its viewport in the root canvas
	_viewports.append(root)
	_focusables[root] = []
	_walk(root, root, Vector2.ZERO, visible, offsets)
	for viewport: Viewport in _viewports:
		_traverse_focus(viewport)
	for control: Control in visible:
		if not _is_mapped(control):
			continue
		if _nodes.size() >= max_elements:
			capped = true
			break
		_nodes.append(control)
		var canvas: Rect2 = _canvas_rect(control)
		_canvas.append(canvas)
		var pixels: Rect2i = _pixel_rect(to_pixels, Rect2(canvas.position + (offsets[control] as Vector2), canvas.size))
		elements.append(_element(root, control, _nodes.size(), pixels, size))
	_map_pickables(root, to_pixels, size)


## The lint findings for the mapped elements, in element order.
func findings() -> PackedStringArray:
	var by_element: Array[Dictionary] = []
	for index: int in _nodes.size():
		by_element.append({})
	_lint_text(by_element)
	_lint_stretched(by_element)
	_lint_off_screen(by_element)
	_lint_overlap(by_element)
	_lint_focus(by_element)
	_lint_hard_coded(by_element)
	var lines: PackedStringArray = PackedStringArray()
	for index: int in _nodes.size():
		var found: Dictionary = by_element[index]
		for rule: String in RULES:
			if found.has(rule):
				lines.append("%s element %d %s: %s" % [rule, index + 1, str(elements[index]["path"]), str(found[rule])])
	return lines


## The element map file's text (.elements.json): the screen, its state, the capture's size, the
## scene it came from, and the mapped elements and 3D pickables, one per line.
func element_map(screen: String, state: String, size: Vector2i, source: String) -> String:
	var lines: PackedStringArray = PackedStringArray([
		"{",
		"  \"schema\": 1, \"adapter\": \"godot\",",
		"  \"screen\": %s, \"state\": %s, \"size\": [%d, %d]," % [JSON.stringify(screen), JSON.stringify(state), size.x, size.y],
		"  \"source\": %s," % JSON.stringify(source),
		"  \"capped\": %s," % JSON.stringify(capped),
	])
	lines.append("  \"elements\": [" + _json_rows(elements) + "],")
	lines.append("  \"pickables_3d\": [" + _json_rows(pickables_3d) + "]")
	lines.append("}")
	return "\n".join(lines) + "\n"


## The control behind element n (numbered from 1, as in the map), or null.
func control_of(number: int) -> Control:
	if number < 1 or number > _nodes.size() or not is_instance_valid(_nodes[number - 1]):
		return null
	return _nodes[number - 1]


func _json_rows(rows: Array[Dictionary]) -> String:
	if rows.is_empty():
		return ""
	var texts: PackedStringArray = PackedStringArray()
	for row: Dictionary in rows:
		texts.append("    " + JSON.stringify(row, "", false))
	return "\n" + ",\n".join(texts) + "\n  "


# --- the map ------------------------------------------------------------------------------------

func _walk(node: Node, viewport: Viewport, offset: Vector2, visible: Array[Control], offsets: Dictionary) -> void:
	for child: Node in node.get_children():
		var window: Window = child as Window
		if window != null:
			if window.visible:
				_viewports.append(window)
				_focusables[window] = []
				_walk(window, window, offset + Vector2(window.position), visible, offsets)
			continue
		if child is SubViewport:
			continue   # drawn into a texture; its controls aren't on screen where they say
		var control: Control = child as Control
		if control != null:
			if not control.is_visible_in_tree():
				continue
			visible.append(control)
			offsets[control] = offset
			if control.focus_mode == Control.FOCUS_ALL:
				(_focusables[viewport] as Array).append(control)
		_walk(child, viewport, offset, visible, offsets)


## Follows Tab from the default focus (the focus owner, else the first focusable control), then
## Shift+Tab and the four directions from everything reached.
func _traverse_focus(viewport: Viewport) -> void:
	var focusables: Array = _focusables[viewport]
	if focusables.is_empty():
		return
	var start: Control = viewport.gui_get_focus_owner()
	if start == null or not focusables.has(start):
		start = focusables[0] as Control
	var order: Array[Control] = [start]
	var current: Control = start
	for step: int in focusables.size() + 10:
		current = current.find_next_valid_focus()
		if current == null or order.has(current):
			break
		order.append(current)
	var index: int = 0
	while index < order.size():
		for next: Control in _neighbours(order[index]):
			if next != null and not order.has(next) and focusables.has(next):
				order.append(next)
		index += 1
	for position: int in order.size():
		_focus_order[order[position]] = position + 1


func _neighbours(control: Control) -> Array[Control]:
	var result: Array[Control] = [control.find_prev_valid_focus()]
	if control.has_method("find_valid_focus_neighbor"):
		for side: int in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			result.append(control.call("find_valid_focus_neighbor", side) as Control)
	return result


func _is_mapped(control: Control) -> bool:
	if control.focus_mode == Control.FOCUS_ALL or control.unique_name_in_owner or not _text(control).is_empty():
		return true
	var parent: Container = control.get_parent() as Container
	return parent != null and parent.unique_name_in_owner


func _element(root: Viewport, control: Control, number: int, pixels: Rect2i, size: Vector2i) -> Dictionary:
	var text: String = _text(control).replace("\n", " ").strip_edges()
	if text.length() > NAME_LENGTH:
		text = text.left(NAME_LENGTH - 3) + "..."
	var order: Variant = _focus_order.get(control, null)
	var minimum: Vector2 = control.get_combined_minimum_size()
	return {
		"n": number,
		"id": _segment(control),
		"stable": control.unique_name_in_owner,
		"path": _path(root, control),
		"kind": control.get_class(),
		"name": text,
		"rect": [pixels.position.x, pixels.position.y, pixels.size.x, pixels.size.y],
		"rect_pct": _percent(pixels, size),
		"visible": true,
		"focusable": control.focus_mode == Control.FOCUS_ALL,
		"focus_order": order,
		"overflow": {"clipped": _clipped(control), "wraps": _wraps(control)},
		"min_size": [roundi(minimum.x), roundi(minimum.y)],
		"native": {
			"class": control.get_class(),
			"autowrap": _wraps(control),
			"focus": {
				"next": str(control.focus_next), "prev": str(control.focus_previous),
				"up": str(control.focus_neighbor_top), "down": str(control.focus_neighbor_bottom),
				"left": str(control.focus_neighbor_left), "right": str(control.focus_neighbor_right),
			},
		},
	}


func _map_pickables(root: Viewport, to_pixels: Transform2D, size: Vector2i) -> void:
	var camera: Camera3D = root.get_camera_3d()
	if camera == null:
		return
	var found: Array[Node] = root.find_children("*", "CollisionObject3D", true, false)
	for node: Node in found:
		var body: CollisionObject3D = node as CollisionObject3D
		if body.get_viewport() != root or not body.input_ray_pickable or not body.is_visible_in_tree():
			continue
		var points: PackedVector2Array = PackedVector2Array()
		for shape_node: Node in body.find_children("*", "CollisionShape3D", true, false):
			var shape: CollisionShape3D = shape_node as CollisionShape3D
			if shape.shape == null or shape.disabled:
				continue
			var box: AABB = shape.global_transform * shape.shape.get_debug_mesh().get_aabb()
			for corner: int in 8:
				var point: Vector3 = box.get_endpoint(corner)
				if not camera.is_position_behind(point):
					points.append(camera.unproject_position(point))
		if points.is_empty():
			continue
		var bounds: Rect2 = Rect2(points[0], Vector2.ZERO)
		for point: Vector2 in points:
			bounds = bounds.expand(point)
		var pixels: Rect2i = _pixel_rect(to_pixels, bounds)
		pickables_3d.append({
			"n": elements.size() + pickables_3d.size() + 1,
			"id": _segment(body),
			"path": _path(root, body),
			"kind": body.get_class(),
			"rect": [pixels.position.x, pixels.position.y, pixels.size.x, pixels.size.y],
			"rect_pct": _percent(pixels, size),
		})


# --- the lint -----------------------------------------------------------------------------------

func _lint_text(by_element: Array[Dictionary]) -> void:
	for index: int in _nodes.size():
		var control: Control = _nodes[index]
		var text: String = _text(control)
		if text.is_empty() or not (control is Label or control is Button or control is RichTextLabel):
			continue
		if _wraps(control):
			var font: Font = _font(control)
			if font == null:
				continue
			var font_size: int = _font_size(control)
			var width: float = control.size.x - _padding(control)
			var average: float = font.get_string_size(SAMPLE_TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x / SAMPLE_TEXT.length()
			var needed: float = minf(_text_width(font, font_size, _drawn_text(control)), average * min_label_chars)
			if width + 1.0 < needed:
				by_element[index]["squeezed-text"] = "wrapping text is %d px wide, under %d average characters (%d px)" % [
					roundi(width), min_label_chars, roundi(needed)]
		elif not (control is RichTextLabel) and not _shortened(control) and control.get_minimum_size().x > control.size.x + 1.0:
			# Godot sizes non-wrapping text in get_minimum_size(), with the label's settings and padding.
			by_element[index]["squeezed-text"] = "the text needs %d px but the box is %d px, and it isn't clipped or shortened" % [
				roundi(control.get_minimum_size().x), roundi(control.size.x)]


func _lint_stretched(by_element: Array[Dictionary]) -> void:
	for index: int in _nodes.size():
		var control: Control = _nodes[index]
		if not (control is BaseButton) or not (control.get_parent() is Container):
			continue
		var minimum: float = control.get_combined_minimum_size().y
		if minimum > 0.0 and control.size.y > minimum * max_button_height_ratio:
			by_element[index]["stretched-control"] = "the button is %d px tall, %.1f times its minimum height (%d px); something beside it grew" % [
				roundi(control.size.y), control.size.y / minimum, roundi(minimum)]


func _lint_off_screen(by_element: Array[Dictionary]) -> void:
	for index: int in _nodes.size():
		var control: Control = _nodes[index]
		var rect: Rect2 = _canvas[index]
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue
		var clip: Control = null
		var scrolled: bool = false
		var parent: Node = control.get_parent()
		while parent != null and not (parent is Viewport):
			if parent is ScrollContainer:
				scrolled = true
				break
			var parent_control: Control = parent as Control
			if clip == null and parent_control != null and parent_control.clip_contents:
				clip = parent_control
			parent = parent.get_parent()
		if scrolled:
			continue   # scrolled out of view is normal
		var screen: Rect2 = control.get_viewport().get_visible_rect()
		if not screen.grow(1.0).encloses(rect):
			by_element[index]["off-screen"] = "its rect %s leaves the screen (%d x %d)" % [
				_show_rect(rect), roundi(screen.size.x), roundi(screen.size.y)]
		elif clip != null and not _canvas_rect(clip).grow(1.0).encloses(rect):
			by_element[index]["off-screen"] = "its rect %s leaves its clipping parent %s %s" % [
				_show_rect(rect), clip.name, _show_rect(_canvas_rect(clip))]


func _lint_overlap(by_element: Array[Dictionary]) -> void:
	for lower: int in _nodes.size():
		var below: Control = _nodes[lower]
		if below.focus_mode != Control.FOCUS_ALL:
			continue
		for upper: int in range(lower + 1, _nodes.size()):
			var above: Control = _nodes[upper]
			if above.get_parent() != below.get_parent() or above.focus_mode != Control.FOCUS_ALL:
				continue
			if above.mouse_filter == Control.MOUSE_FILTER_IGNORE:
				continue
			var shared: Rect2 = _canvas[lower].intersection(_canvas[upper])
			if shared.size.x > 1.0 and shared.size.y > 1.0:
				by_element[lower]["overlap"] = "element %d (%s) covers %d x %d px of it and takes its clicks" % [
					upper + 1, above.name, roundi(shared.size.x), roundi(shared.size.y)]
				break


func _lint_focus(by_element: Array[Dictionary]) -> void:
	for viewport: Viewport in _viewports:
		var first: int = -1
		for index: int in _nodes.size():
			var control: Control = _nodes[index]
			if control.get_viewport() != viewport or control.focus_mode != Control.FOCUS_ALL or _disabled(control):
				continue
			if first < 0:
				first = index
			if not _focus_order.has(control):
				by_element[index]["unreachable"] = "Tab, Shift+Tab and the arrows never reach it from the default focus"
		if first >= 0 and viewport.gui_get_focus_owner() == null:
			by_element[first]["no-default-focus"] = "nothing has focus when the %s opens; give this or another element focus" % [
				"screen" if viewport == _viewports[0] else "dialog"]


func _lint_hard_coded(by_element: Array[Dictionary]) -> void:
	for index: int in _nodes.size():
		var control: Control = _nodes[index]
		if not (control.get_parent() is Container) or control.top_level or control.owner == null:
			continue
		var scene_path: String = control.owner.scene_file_path
		if scene_path.is_empty():
			continue
		if not _scene_states.has(scene_path):
			var scene: PackedScene = load(scene_path) as PackedScene
			_scene_states[scene_path] = scene.get_state() if scene != null else null
		var state: SceneState = _scene_states[scene_path] as SceneState
		if state == null:
			continue
		var path: String = str(control.owner.get_path_to(control))
		for node_index: int in state.get_node_count():
			if str(state.get_node_path(node_index)).trim_prefix("./") != path:
				continue
			for property: int in state.get_node_property_count(node_index):
				var property_name: String = str(state.get_node_property_name(node_index, property))
				var value: Variant = state.get_node_property_value(node_index, property)
				if POSITION_PROPERTIES.has(property_name) and not is_zero_approx(_magnitude(value)):
					by_element[index]["hard-coded-position"] = "%s sets %s in pixels, but its parent %s lays it out (warning)" % [
						scene_path, property_name, control.get_parent().name]
					break
			break


# --- helpers ------------------------------------------------------------------------------------

func _text(control: Control) -> String:
	var rich: RichTextLabel = control as RichTextLabel
	if rich != null:
		return rich.get_parsed_text()
	if "text" in control:
		return str(control.get("text"))
	return ""


## The text as drawn, for measuring: a Label's uppercase setting applied.
func _drawn_text(control: Control) -> String:
	var label: Label = control as Label
	return label.text.to_upper() if label != null and label.uppercase else _text(control)


func _wraps(control: Control) -> bool:
	return "autowrap_mode" in control and int(control.get("autowrap_mode")) != 0


func _shortened(control: Control) -> bool:
	return ("clip_text" in control and bool(control.get("clip_text"))) \
		or ("text_overrun_behavior" in control and int(control.get("text_overrun_behavior")) != 0)


func _clipped(control: Control) -> bool:
	if _wraps(control) or not _shortened(control):
		return false
	var font: Font = _font(control)
	var text: String = _text(control)
	return font != null and not text.is_empty() \
		and _text_width(font, _font_size(control), _drawn_text(control)) > control.size.x - _padding(control) + 1.0


func _disabled(control: Control) -> bool:
	return control is BaseButton and (control as BaseButton).disabled


## The font the control draws its text with: a Label's label_settings win over the theme.
func _font(control: Control) -> Font:
	var settings: LabelSettings = _label_settings(control)
	if settings != null and settings.font != null:
		return settings.font
	return control.get_theme_font(&"normal_font" if control is RichTextLabel else &"font")


func _font_size(control: Control) -> int:
	var settings: LabelSettings = _label_settings(control)
	if settings != null:
		return settings.font_size
	return control.get_theme_font_size(&"normal_font_size" if control is RichTextLabel else &"font_size")


func _label_settings(control: Control) -> LabelSettings:
	var label: Label = control as Label
	return label.label_settings if label != null else null


## A node's name in a path: its name, or `Class#<index among its siblings>` for a node Godot named
## (`@Button@12`, from a counter that depends on what else ran), so code-built screens map the same
## every time.
func _segment(node: Node) -> String:
	var name: String = str(node.name)
	return "%s#%d" % [node.get_class(), node.get_index()] if name.begins_with("@") else name


func _path(root: Node, node: Node) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var current: Node = node
	while current != null and current != root:
		parts.insert(0, _segment(current))
		current = current.get_parent()
	return "/".join(parts)


func _padding(control: Control) -> float:
	if control is RichTextLabel or not control.has_theme_stylebox(&"normal"):
		return 0.0
	return control.get_theme_stylebox(&"normal").get_minimum_size().x


func _text_width(font: Font, font_size: int, text: String) -> float:
	var widest: float = 0.0
	for line: String in text.split("\n"):
		widest = maxf(widest, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	return widest


## The control's rect in its viewport's canvas (after CanvasLayer and Camera2D transforms).
func _canvas_rect(control: Control) -> Rect2:
	var transform: Transform2D = control.get_global_transform_with_canvas()
	var local: Rect2 = Rect2(Vector2.ZERO, control.size)
	var rect: Rect2 = Rect2(transform * local.position, Vector2.ZERO)
	for corner: Vector2 in [Vector2(local.end.x, 0.0), local.end, Vector2(0.0, local.end.y)]:
		rect = rect.expand(transform * corner)
	return rect


func _pixel_rect(to_pixels: Transform2D, canvas: Rect2) -> Rect2i:
	var first: Vector2 = (to_pixels * canvas.position).round()
	var last: Vector2 = (to_pixels * canvas.end).round()
	var top_left: Vector2i = Vector2i(roundi(minf(first.x, last.x)), roundi(minf(first.y, last.y)))
	var bottom_right: Vector2i = Vector2i(roundi(maxf(first.x, last.x)), roundi(maxf(first.y, last.y)))
	return Rect2i(top_left, bottom_right - top_left)


func _percent(rect: Rect2i, size: Vector2i) -> Array[float]:
	return [
		snappedf(100.0 * rect.position.x / size.x, 0.1), snappedf(100.0 * rect.position.y / size.y, 0.1),
		snappedf(100.0 * rect.size.x / size.x, 0.1), snappedf(100.0 * rect.size.y / size.y, 0.1),
	]


func _show_rect(rect: Rect2) -> String:
	return "(%d, %d, %d x %d)" % [roundi(rect.position.x), roundi(rect.position.y), roundi(rect.size.x), roundi(rect.size.y)]


func _magnitude(value: Variant) -> float:
	if value is Vector2:
		return (value as Vector2).length()
	if value is float or value is int:
		return absf(float(value))
	return 0.0
