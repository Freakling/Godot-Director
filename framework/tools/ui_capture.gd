extends SceneTree
## Screen capture runner · framework-owned: replaced on upgrade.
##
## Run it with `bash tools/ui_capture.sh` (.godot-director/procedures/ui-design.md), which finds
## Godot, gives it a display and checks its output for script errors. Screens are shown in a
## SubViewport of the capture's size, rendered offscreen with the project's stretch settings, so
## every size captures whatever the monitor. For every screen in the
## catalog (res://tools/ui_screens.gd), state and size, it writes to design/ui/captures/
## `<id>[.<state>]@<W>x<H>` .png (the screenshot), .elements.json (the element map), .map.png
## (the screenshot with every element outlined and numbered) and .lint.txt (layout lint findings,
## empty when clean). The default state at the default size (the first of [sizes] list) also gets
## `<id>.starter.excalidraw`, the drawing the human draws over (tools/ui_drawing.gd).
## Settings: res://tools/ui_capture.cfg.
##
## Arguments after `--`: <screen id> or --all, --state <name>, --size <W>x<H>, --no-images (the
## element maps and lint only, headless), --list (print the catalog), --missing (list the scenes
## whose root script is in a screen folder but that the catalog doesn't cover). --size may name a
## size that tools/ui_capture.cfg doesn't list. --check is what tools/check.sh runs when
## tools/ui_capture.cfg › [lint] check_in_check is true: headless, the screens in [lint] enforce at
## the default size, findings printed as GDIR-FAIL lines (a hard-coded-position warning as a note).
## A catalog entry's `overlays` (HUDs and other layers an autoload draws) are shown in the screen's
## viewport for the shot, so a capture shows what a player sees.
## While it runs, Engine.has_meta("godot_director_check") and ("godot_director_capture") are true,
## so autoloads skip reading and writing player data, as during the check.
## Exit codes: 0 done · 1 a screen failed · 3 couldn't run (no display).

const UiLint := preload("res://tools/ui_lint.gd")
const UiDrawing := preload("res://tools/ui_drawing.gd")
const UiOverlay := preload("res://tools/ui_overlay.gd")
const CATALOG_PATH: String = "res://tools/ui_screens.gd"
const CONFIG_PATH: String = "res://tools/ui_capture.cfg"
const CHECK_CONFIG_PATH: String = "res://tools/check.cfg"
const CHECK_META: StringName = &"godot_director_check"
const CAPTURE_META: StringName = &"godot_director_capture"

var _sizes: Array[Vector2i] = [Vector2i(1920, 1080), Vector2i(2560, 1080), Vector2i(1280, 720)]
var _default_size: Vector2i = Vector2i(1920, 1080)
var _seed: int = 12345
var _settle_frames: int = 6
var _max_elements: int = 200
var _skip: PackedStringArray = PackedStringArray()
var _min_label_chars: int = 6
var _max_button_height_ratio: float = 2.0
var _setup_timeout: int = 60

var _screen: String = ""
var _state: String = ""
var _size_filter: String = ""
var _images: bool = true
var _list: bool = false
var _list_missing: bool = false
var _check: bool = false           # the lint inside the check
var _enforce: PackedStringArray = PackedStringArray()
var _out_dir: String = "res://design/ui/captures"
var _fail_tag: String = "GDIR-UI-FAIL: "
var _borrowed: Array[Dictionary] = []   # nodes moved into the screen's viewport as overlays

var _config_problems: PackedStringArray = PackedStringArray()
var _failed: bool = false
var _busy: bool = false        # the run is waiting for frames or for a screen's setup
var _done: bool = false
var _started: bool = false
var _host: SubViewport = null
var _stretch: Dictionary = {}
var _captures: int = 0
var _with_findings: int = 0


func _init() -> void:
	# Before any autoload's _ready runs.
	Engine.set_meta(CHECK_META, true)
	Engine.set_meta(CAPTURE_META, true)
	_config_problems = _read_config()
	seed(_seed)


func _initialize() -> void:
	# Autoloads are registered after this script is compiled, so the run starts on the first frame.
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	if not _started:
		_started = true
		_run()
	elif _done:
		return
	elif not _busy:
		_stop("tools/ui_capture.gd stopped early; see the error above", 1)


func _run() -> void:
	var problems: PackedStringArray = _config_problems
	problems.append_array(_read_args())
	if not problems.is_empty():
		for problem: String in problems:
			printerr(_fail_tag + problem)
		_stop("", 1)
		return
	if _check:
		_fail_tag = "GDIR-FAIL: ui lint: "
		_out_dir = "res://.godot/godot-director/ui-lint"
		_size_filter = "%dx%d" % [_default_size.x, _default_size.y]
		if not ResourceLoader.exists(CATALOG_PATH):
			print("GDIR-NOTE: ui lint: no tools/ui_screens.gd, so there are no screens to lint")
			_stop("", 0)
			return
	var catalog_script: GDScript = ResourceLoader.load(CATALOG_PATH) as GDScript
	if catalog_script == null or not catalog_script.can_instantiate():
		_stop("%s is missing or doesn't compile" % CATALOG_PATH.trim_prefix("res://"), 1)
		return
	var catalog: RefCounted = catalog_script.new() as RefCounted
	if catalog == null or not catalog.has_method("checked_screens"):
		_stop("%s must start with extends \"res://tools/ui_catalog.gd\"" % CATALOG_PATH.trim_prefix("res://"), 1)
		return
	var checked: Array = catalog.call("checked_screens")
	var entries: Array = checked[0]
	for error: String in (checked[1] as PackedStringArray):
		printerr(_fail_tag + error)
		_failed = true
	if _list:
		if _list_missing:
			_print_missing(entries)
		else:
			_print_list(entries)
		_stop("", 1 if _failed else 0)
		return
	var selected: Array[Dictionary] = _select(entries)
	if _done:
		return
	if _images and DisplayServer.get_name() == "headless":
		_stop("needs a display; this Godot has none (--no-images maps and lints without one)", 3)
		return
	if not DirAccess.dir_exists_absolute(_out_dir) and DirAccess.make_dir_recursive_absolute(_out_dir) != OK:
		_stop("can't create %s" % _out_dir.trim_prefix("res://"), 1)
		return
	_make_host(catalog)
	if not _size_filter.is_empty():
		_sizes = [_parse_size(_size_filter)]
	for size: Vector2i in _sizes:
		if not await _resize(size):
			continue
		for entry: Dictionary in selected:
			var states: Dictionary = entry["states"]
			for state: String in states:
				if _state.is_empty() or _state == state:
					await _capture(catalog, entry, state, states[state] as Callable, size)
	if _check:
		print("GDIR-NOTE: ui lint: %d screen%s linted at %dx%d (tools/ui_capture.cfg › [lint] enforce)" % [
			_captures, "" if _captures == 1 else "s", _default_size.x, _default_size.y])
	print("GDIR-UI: %d capture%s in %s · %d with lint findings%s" % [
		_captures, "" if _captures == 1 else "s", _out_dir.trim_prefix("res://"), _with_findings,
		" · some screens failed" if _failed else ""])
	_stop("", 1 if _failed else 0)


func _stop(message: String, code: int) -> void:
	_restore_overlays()
	if not message.is_empty():
		if code == 3:
			printerr("GDIR-UI-SKIP: " + message)
		else:
			printerr(_fail_tag + message)
	_done = true
	paused = false
	quit(code)


# --- configuration and arguments ----------------------------------------------------------------

func _read_config() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	var config: ConfigFile = ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		print("GDIR-UI-NOTE: no tools/ui_capture.cfg: using the default settings")
		return problems
	var listed: Variant = config.get_value("sizes", "list", [])
	if listed is Array and not (listed as Array).is_empty():
		_sizes.clear()
		for item: Variant in listed:
			var size: Vector2i = _parse_size(str(item))
			if size == Vector2i.ZERO:
				problems.append("tools/ui_capture.cfg › [sizes] list: '%s' isn't WxH" % item)
			else:
				_sizes.append(size)
	if not _sizes.is_empty():
		_default_size = _sizes[0]
	_seed = int(config.get_value("capture", "seed", _seed))
	_settle_frames = maxi(1, int(config.get_value("capture", "settle_frames", _settle_frames)))
	_max_elements = maxi(1, int(config.get_value("capture", "max_elements", _max_elements)))
	_setup_timeout = maxi(1, int(config.get_value("capture", "setup_timeout", _setup_timeout)))
	var skip: Variant = config.get_value("capture", "skip", [])
	if skip is Array:
		for item: Variant in skip:
			_skip.append(str(item))
	_min_label_chars = int(config.get_value("lint", "min_label_chars", _min_label_chars))
	_max_button_height_ratio = float(config.get_value("lint", "max_button_height_ratio", _max_button_height_ratio))
	var enforce: Variant = config.get_value("lint", "enforce", [])
	if enforce is Array:
		for item: Variant in enforce:
			_enforce.append(str(item))
	return problems


func _read_args() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var index: int = 0
	while index < args.size():
		var arg: String = args[index]
		match arg:
			"--all", "all":
				_screen = ""
			"--no-images":
				_images = false
			"--list":
				_list = true
			"--missing":
				_list = true
				_list_missing = true
			"--check":
				_check = true
				_images = false
			"--state", "--size":
				if index + 1 >= args.size():
					problems.append("%s needs a value" % arg)
				elif arg == "--state":
					_state = args[index + 1]
				elif _parse_size(args[index + 1]) == Vector2i.ZERO:
					problems.append("--size takes WxH, such as 1920x1080")
				else:
					_size_filter = args[index + 1]
				index += 1
			_:
				if arg.begins_with("-"):
					problems.append("unknown option %s" % arg)
				else:
					_screen = arg
		index += 1
	return problems


func _parse_size(text: String) -> Vector2i:
	var parts: PackedStringArray = text.strip_edges().to_lower().split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	var size: Vector2i = Vector2i(parts[0].to_int(), parts[1].to_int())
	return size if size.x > 0 and size.y > 0 else Vector2i.ZERO


func _select(entries: Array) -> Array[Dictionary]:
	var selected: Array[Dictionary] = []
	for entry: Dictionary in entries:
		var id: String = str(entry["id"])
		if not _screen.is_empty() and id != _screen:
			continue
		if _check and not (_enforce.has("*") or _enforce.has(id)):
			continue
		if _skip.has(id):
			print("GDIR-UI-NOTE: %s is in tools/ui_capture.cfg › [capture] skip" % id)
			continue
		if not _state.is_empty() and not (entry["states"] as Dictionary).has(_state):
			if not _screen.is_empty():
				_stop("%s has no state '%s' (it has %s)" % [id, _state, ", ".join(PackedStringArray((entry["states"] as Dictionary).keys()))], 1)
				return selected
			continue
		selected.append(entry)
	if not _screen.is_empty() and selected.is_empty() and not _skip.has(_screen):
		_stop("no screen '%s' in tools/ui_screens.gd; run bash tools/ui_capture.sh --list" % _screen, 1)
	elif selected.is_empty():
		print("GDIR-UI-NOTE: nothing to capture: tools/ui_screens.gd lists no screen that matches")
	return selected


func _print_list(entries: Array) -> void:
	for entry: Dictionary in entries:
		var id: String = str(entry["id"])
		print("GDIR-UI-LIST: %s · %s · states: %s · opens %s · drawing: %s · spec: %s%s" % [
			id, entry["title"], ", ".join(PackedStringArray((entry["states"] as Dictionary).keys())),
			entry["scene"] if not str(entry["scene"]).is_empty() else "(set up in code)",
			"yes" if FileAccess.file_exists("res://director/ui/%s.excalidraw" % id) else "no",
			"yes" if FileAccess.file_exists("res://design/ui/%s.md" % id) else "no",
			" · skipped (tools/ui_capture.cfg)" if _skip.has(id) else ""])
	if entries.is_empty():
		print("GDIR-UI-LIST: (the catalog lists no screens)")


## The scenes whose root script is in a screen folder (tools/check.cfg › [screens] dirs) that no
## catalog entry opens and that tools/ui_capture.cfg › [capture] skip doesn't name (by scene path
## or file name without extension). It never fails: it lists.
func _print_missing(entries: Array) -> void:
	var dirs: PackedStringArray = PackedStringArray()
	var skipped: PackedStringArray = PackedStringArray(["addons", "script_templates"])
	var config: ConfigFile = ConfigFile.new()
	if config.load(CHECK_CONFIG_PATH) == OK:
		dirs = _strings(config.get_value("screens", "dirs", []))
		skipped = _strings(config.get_value("scan", "skip", Array(skipped)))
	else:
		for candidate: String in ["scripts/ui", "scripts/screens", "ui", "screens"]:
			if DirAccess.dir_exists_absolute("res://" + candidate):
				dirs.append(candidate)
	if dirs.is_empty():
		print("GDIR-UI-NOTE: no screen folders set (tools/check.cfg › [screens] dirs), so the scenes that are screens can't be told")
		return
	var scenes: Array[String] = []
	_collect_scenes("res://", skipped, scenes)
	scenes.sort()
	var covered: PackedStringArray = PackedStringArray()
	for entry: Dictionary in entries:
		covered.append(str(entry["scene"]))
	var screens: int = 0
	var missing: int = 0
	for scene: String in scenes:
		var script: String = _root_script(scene)
		if script.is_empty() or not _in_folders(script, dirs):
			continue
		screens += 1
		if covered.has(scene) or _skip.has(scene) or _skip.has(scene.get_file().get_basename()):
			continue
		missing += 1
		print("GDIR-UI-MISSING: %s · script %s" % [scene.trim_prefix("res://"), script.trim_prefix("res://")])
	print("GDIR-UI-NOTE: %d screen scene%s found, %d without a catalog entry or a skip" % [screens, "" if screens == 1 else "s", missing])


func _strings(value: Variant) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	if value is Array or value is PackedStringArray:
		for item: Variant in value:
			if not str(item).strip_edges().is_empty():
				result.append(str(item).strip_edges())
	return result


func _in_folders(path: String, folders: PackedStringArray) -> bool:
	for folder: String in folders:
		if path.trim_prefix("res://").begins_with(folder.trim_prefix("res://").trim_suffix("/") + "/"):
			return true
	return false


func _collect_scenes(dir_path: String, skipped: PackedStringArray, out: Array[String]) -> void:
	if FileAccess.file_exists(dir_path.path_join(".gdignore")):
		return
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for sub: String in dir.get_directories():
		var sub_path: String = dir_path.path_join(sub)
		if not sub.begins_with(".") and not _in_folders(sub_path + "/", skipped):
			_collect_scenes(sub_path, skipped, out)
	for file: String in dir.get_files():
		if file.get_extension() == "tscn":
			out.append(dir_path.path_join(file))


## The script attached to a scene's root node, read from the .tscn text; "" when there is none.
func _root_script(scene: String) -> String:
	var paths: Dictionary = {}
	var in_root: bool = false
	var script_id: String = ""
	var path_pattern: RegEx = RegEx.create_from_string(r'path="([^"]+)"')
	var id_pattern: RegEx = RegEx.create_from_string(r'\bid="([^"]+)"')
	var script_pattern: RegEx = RegEx.create_from_string(r'^script\s*=\s*ExtResource\("([^"]+)"\)')
	var seen_root: bool = false
	for line: String in FileAccess.get_file_as_string(scene).replace("\r", "").split("\n"):
		if line.begins_with("[ext_resource"):
			var path: RegExMatch = path_pattern.search(line)
			var id: RegExMatch = id_pattern.search(line)
			if path != null and id != null:
				paths[id.get_string(1)] = path.get_string(1)
		elif line.begins_with("[node "):
			if seen_root:
				break
			seen_root = true
			in_root = not line.contains("parent=")
			if not in_root:
				break
		elif in_root:
			var found: RegExMatch = script_pattern.search(line)
			if found != null:
				script_id = found.get_string(1)
				break
	return str(paths.get(script_id, ""))


# --- capture ------------------------------------------------------------------------------------

func _frames(count: int) -> void:
	_busy = true
	for index: int in count:
		await process_frame
	_busy = false


## The viewport screens are shown in: an offscreen SubViewport of the capture's size, with the
## project's stretch settings applied as the game window applies them, so a capture of any size
## shows what a player sees at that size, whatever the monitor.
func _make_host(catalog: RefCounted) -> void:
	_host = SubViewport.new()
	_host.name = "UiCapture"
	_host.gui_embed_subwindows = true
	_host.transparent_bg = false
	_host.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_host)
	catalog.set("host", _host)


## Sizes the host for a capture of the given size. A size the GPU can't render is a note, not a
## failure.
func _resize(size: Vector2i) -> bool:
	_stretch = _stretch_for(size)
	var canvas: Vector2i = _stretch["canvas"]
	var screen: Vector2i = _stretch["screen"]
	if bool(_stretch["viewport_mode"]):
		_host.size = canvas
		_host.size_2d_override = Vector2i.ZERO
		_host.size_2d_override_stretch = false
	else:
		_host.size = screen
		_host.size_2d_override = canvas if canvas != screen else Vector2i.ZERO
		_host.size_2d_override_stretch = canvas != screen
	await _frames(3)
	var expected: Vector2i = canvas if bool(_stretch["viewport_mode"]) else screen
	if _host.size != expected:
		print("GDIR-UI-NOTE: %dx%d can't be rendered here; skipped that size" % [size.x, size.y])
		return false
	return true


## The project's stretch (display/window/stretch/*) for a window of the given size, as Godot's
## Window computes it: the canvas size the screens lay out in, the rect it's drawn in (screen and
## margin, the rest being bars), and whether it renders at canvas size and is scaled afterwards.
func _stretch_for(size: Vector2i) -> Dictionary:
	var video: Vector2 = Vector2(size)
	var desired: Vector2 = Vector2(root.content_scale_size)
	var mode: int = root.content_scale_mode
	var result: Dictionary = {"canvas": size, "screen": size, "margin": Vector2i.ZERO, "viewport_mode": false}
	if mode == Window.CONTENT_SCALE_MODE_DISABLED or desired.x <= 0.0 or desired.y <= 0.0:
		return result
	var aspect: int = root.content_scale_aspect
	var viewport_size: Vector2 = desired
	var screen_size: Vector2 = video
	var desired_aspect: float = desired.x / desired.y
	var video_aspect: float = video.x / video.y
	if aspect == Window.CONTENT_SCALE_ASPECT_IGNORE or is_equal_approx(desired_aspect, video_aspect):
		pass
	elif desired_aspect < video_aspect:   # the window is wider
		if aspect == Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT or aspect == Window.CONTENT_SCALE_ASPECT_EXPAND:
			viewport_size = Vector2(desired.y * video_aspect, desired.y)
		else:
			screen_size = Vector2(video.y * desired_aspect, video.y)
	else:                                  # the window is taller
		if aspect == Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH or aspect == Window.CONTENT_SCALE_ASPECT_EXPAND:
			viewport_size = Vector2(desired.x, desired.x / video_aspect)
		else:
			screen_size = Vector2(video.x, video.x / desired_aspect)
	viewport_size = (viewport_size / maxf(root.content_scale_factor, 0.01)).floor()
	screen_size = screen_size.floor()
	# Integer stretch (Godot 4.2+): the largest whole scale that fits.
	if "content_scale_stretch" in root and int(root.get("content_scale_stretch")) == 1:
		var whole: float = maxf(1.0, floorf(minf(screen_size.x / viewport_size.x, screen_size.y / viewport_size.y)))
		screen_size = (viewport_size * whole).floor()
	result["canvas"] = Vector2i(viewport_size)
	result["screen"] = Vector2i(screen_size)
	result["margin"] = Vector2i(((video - screen_size) / 2.0).floor())
	result["viewport_mode"] = mode == Window.CONTENT_SCALE_MODE_VIEWPORT
	return result


func _capture(catalog: RefCounted, entry: Dictionary, state: String, setup: Callable, size: Vector2i) -> void:
	var id: String = str(entry["id"])
	var base: String = "%s%s@%dx%d" % [id, "" if state == "default" else "." + state, size.x, size.y]
	var path: String = _out_dir.path_join(base)
	await _clear(catalog)
	print("GDIR-UI: begin " + base)
	seed(_seed)
	catalog.call("reset")
	# The setup runs as its own coroutine, so one that never finishes fails only this screen.
	var result: Dictionary = {"done": false, "node": null}
	var runner: Callable = func() -> void:
		result["node"] = await setup.call()
		result["done"] = true
	runner.call()
	var started: int = Time.get_ticks_msec()
	while not bool(result["done"]):
		if Time.get_ticks_msec() - started > _setup_timeout * 1000:
			var message: String = "error: the setup didn't finish within %d seconds ([capture] setup_timeout)" % _setup_timeout
			printerr(_fail_tag + "%s: %s" % [base, message.trim_prefix("error: ")])
			_write(path + ".lint.txt", message + "\n")
			for extension: String in [".png", ".elements.json", ".map.png"]:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path + extension))
			_failed = true
			print("GDIR-UI: end %s · failed" % base)
			return
		await _frames(1)
	var shown: Variant = result["node"]
	var view: Node = shown as Node if shown is Node else null
	if view != null and not view.is_inside_tree():
		_host.add_child(view)
	_adopt(catalog)
	var overlay_errors: PackedStringArray = _show_overlays(entry["overlays"] as Array, base)
	paused = bool(entry["pause"])
	await _frames(_settle_frames)
	var image: Image = null
	if _images:
		_busy = true
		await RenderingServer.frame_post_draw
		_busy = false
		image = _framed(_host.get_texture().get_image(), size)
	var lint: UiLint = UiLint.new()
	lint.min_label_chars = _min_label_chars
	lint.max_button_height_ratio = _max_button_height_ratio
	lint.max_elements = _max_elements
	lint.map(_host, _to_pixels(), size)
	var findings: PackedStringArray = lint.findings()
	var source: String = view.scene_file_path if view != null and not view.scene_file_path.is_empty() else str(entry["scene"])
	_write(path + ".elements.json", lint.element_map(id, state, size, source))
	var top: String = ""
	for line: String in overlay_errors:
		top += "error: " + line + "\n"
	_write(path + ".lint.txt", top + ("" if findings.is_empty() else "\n".join(findings) + "\n"))
	if _check:
		for finding: String in findings:
			if finding.begins_with("hard-coded-position "):
				print("GDIR-NOTE: ui lint (a warning): %s: %s" % [base, finding])
			else:
				printerr(_fail_tag + "%s: %s" % [base, finding])
				_failed = true
	if image != null:
		_save(image, path + ".png")
		_save(UiOverlay.draw_map(image, lint.elements + lint.pickables_3d), path + ".map.png")
		if state == "default" and size == _default_size:
			_write(_out_dir.path_join(id + ".starter.excalidraw"), UiDrawing.starter_text(id, size, FileAccess.get_file_as_bytes(path + ".png"), lint.elements))
	_restore_overlays()
	paused = false
	_captures += 1
	if not findings.is_empty():
		_with_findings += 1
	print("GDIR-UI: end %s · %d element%s · %d lint finding%s" % [
		base, lint.elements.size(), "" if lint.elements.size() == 1 else "s",
		findings.size(), "" if findings.size() == 1 else "s"])


## Shows a catalog entry's overlays in the screen's viewport: a scene is instanced there, and a
## node in the scene tree (an autoload's HUD) is moved there until _restore_overlays() puts it
## back. Returns what couldn't be shown; the screen is still captured.
func _show_overlays(overlays: Array, base: String) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	for item: Variant in overlays:
		var overlay: String = str(item)
		var problem: String = ""
		if overlay.begins_with("res://"):
			var scene: PackedScene = ResourceLoader.load(overlay) as PackedScene
			var copy: Node = scene.instantiate() if scene != null and scene.can_instantiate() else null
			if copy == null:
				problem = "the overlay scene %s doesn't load" % overlay
			else:
				_host.add_child(copy)
		else:
			var node: Node = root.get_node_or_null(NodePath(overlay))
			if node == null or node == _host or _host.is_ancestor_of(node) or node == root:
				problem = "the overlay %s isn't in the scene tree (name an autoload's node path, such as /root/Hud, or a scene)" % overlay
			else:
				var parent: Node = node.get_parent()
				_borrowed.append({"node": node, "parent": parent, "index": node.get_index()})
				node.reparent(_host, false)
		if not problem.is_empty():
			errors.append(problem)
			printerr(_fail_tag + "%s: %s" % [base, problem])
			_failed = true
	return errors


## Puts the nodes _show_overlays() borrowed back where they were.
func _restore_overlays() -> void:
	for index: int in range(_borrowed.size() - 1, -1, -1):
		var item: Dictionary = _borrowed[index]
		var node: Node = item["node"] as Node
		var parent: Node = item["parent"] as Node
		if is_instance_valid(node) and is_instance_valid(parent) and node.get_parent() != parent:
			node.reparent(parent, false)
			parent.move_child(node, mini(int(item["index"]), parent.get_child_count() - 1))
	_borrowed.clear()


## Moves what a setup put on the scene tree's root (the game's own navigation) into the capture's
## viewport, keeping its focus.
func _adopt(catalog: RefCounted) -> void:
	var keep: Array = catalog.call("autoloads")
	var focused: Control = root.gui_get_focus_owner()
	for child: Node in root.get_children():
		if child == _host or keep.has(child):
			continue
		child.reparent(_host, false)
	if focused != null and focused.is_inside_tree() and _host.is_ancestor_of(focused):
		focused.grab_focus()


## Frees everything the last screen put on screen.
func _clear(catalog: RefCounted) -> void:
	paused = false
	var keep: Array = catalog.call("autoloads")
	for child: Node in root.get_children():
		if child != _host and not keep.has(child):
			child.queue_free()
	for child: Node in _host.get_children():
		child.queue_free()
	await _frames(1)


## The host's canvas coordinates to capture pixels: the stretch scale, then the bars' margin.
func _to_pixels() -> Transform2D:
	var canvas: Vector2 = Vector2(_stretch["canvas"] as Vector2i)
	var screen: Vector2 = Vector2(_stretch["screen"] as Vector2i)
	return Transform2D(0.0, screen / canvas, 0.0, Vector2(_stretch["margin"] as Vector2i))


## The rendered image placed in a capture of the window's size, as the game window shows it: scaled
## for viewport stretch, with bars where the project's stretch aspect keeps them.
func _framed(rendered: Image, size: Vector2i) -> Image:
	rendered.convert(Image.FORMAT_RGBA8)
	var screen: Vector2i = _stretch["screen"]
	if rendered.get_size() != screen:
		rendered.resize(screen.x, screen.y, Image.INTERPOLATE_NEAREST)
	if screen == size:
		return rendered
	var framed: Image = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	framed.fill(Color.BLACK)
	framed.blit_rect(rendered, Rect2i(Vector2i.ZERO, screen), _stretch["margin"] as Vector2i)
	return framed


func _write(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr(_fail_tag + "can't write %s" % path.trim_prefix("res://"))
		_failed = true
		return
	file.store_string(text)
	file.close()


func _save(image: Image, path: String) -> void:
	if image.save_png(ProjectSettings.globalize_path(path)) != OK:
		printerr(_fail_tag + "can't write %s" % path.trim_prefix("res://"))
		_failed = true
