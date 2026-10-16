extends RefCounted
## Base of the screen catalog · framework-owned: replaced on upgrade.
##
## The project's catalog, res://tools/ui_screens.gd, extends this file and lists every screen and
## how to put it on screen in a representative state, for `bash tools/ui_capture.sh`
## (.godot-director/procedures/ui-design.md). Override screens(); override reset() or open_view()
## when the game needs it. Don't edit this file in a project.
##
## An entry is a Dictionary:
##   id      String, required: lower-case letters, digits and _ (capture file names start with it)
##   title   String, required: what the director calls the screen
##   scene   String: the view's scene (res://...). Without setup or states it's opened with open_view()
##   setup   Callable: puts the screen on screen in its default state
##   states  Dictionary of state name to Callable, instead of setup (for example "default", "empty")
##   pause   bool, default true: pause the tree before the screenshot, which also stops Tweens and
##           AnimationPlayers. Set false for a screen that must keep processing to look right.
##   overlays  Array of String: what the screen shows that it doesn't draw itself, such as a HUD or
##           a toast layer an autoload owns. A node path in the scene tree ("/root/Hud") is moved into
##           the screen's viewport for the shot and put back afterwards; a scene ("res://...tscn") is
##           instanced there. Without it, a capture leaves out whatever an autoload draws.
## A setup builds its state through the game's public APIs, fixtures and debug hooks, never player
## data. It returns the node to show (open_view() returns one already on screen; a node that isn't
## in the tree yet is added to screen_root()), or opens the screen through the game's own
## navigation and returns null. It may await, for example wait_frames().
##
## During a capture, screens are shown in screen_root(): a viewport of the capture's size, rendered
## offscreen with the project's stretch settings, so any size captures on any monitor. A node a
## setup adds to the scene tree's root is moved there. Outside a capture, screen_root() is the root.

const KEYS: PackedStringArray = ["id", "title", "scene", "setup", "states", "pause", "overlays"]
const DEFAULT_STATE: String = "default"

## The viewport screens are shown in during a capture; set by tools/ui_capture.gd.
var host: Viewport = null


## Every screen the game has. Override this.
func screens() -> Array[Dictionary]:
	return []


## Called before each screen's setup, so every capture starts from the same run state, as tests do.
## By default it calls reset_run() on every autoload that has it.
func reset() -> void:
	for node: Node in autoloads():
		if node.has_method("reset_run"):
			node.call("reset_run")


## Instantiates a scene, sets the given properties on it, adds it to the root and returns it.
## Override it when the game has a shell that must host its views.
func open_view(scene_path: String, args: Dictionary = {}) -> Node:
	var scene: PackedScene = load(scene_path) as PackedScene
	if scene == null:
		printerr("GDIR-UI-FAIL: can't load the scene %s" % scene_path)
		return null
	var view: Node = scene.instantiate()
	for key: Variant in args:
		view.set(str(key), args[key])
	screen_root().add_child(view)
	return view


## Where screens are shown: the capture's viewport during a capture, else the root.
func screen_root() -> Viewport:
	return host if host != null else tree().root


## Waits the given number of frames.
func wait_frames(count: int) -> void:
	for index: int in count:
		await tree().process_frame


## Gives the node, or its first focusable descendant, the keyboard and controller focus, as the
## game does when it opens the screen. Works before the node is added to the tree.
func focus_default(node: Node) -> void:
	var target: Control = _first_focusable(node)
	if target == null:
		return
	if target.is_inside_tree():
		target.grab_focus()
	else:
		target.call_deferred("grab_focus")


## The autoload nodes, in project order.
func autoloads() -> Array[Node]:
	var result: Array[Node] = []
	for property: Dictionary in ProjectSettings.get_property_list():
		var key: String = str(property.get("name", ""))
		if not key.begins_with("autoload/"):
			continue
		var node: Node = tree().root.get_node_or_null(NodePath(key.trim_prefix("autoload/")))
		if node != null:
			result.append(node)
	return result


func tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## The entries, checked: [entries, errors]. Each entry is {id, title, scene, states, pause, overlays}, with
## states a Dictionary of state name to Callable. An entry with an error is left out.
func checked_screens() -> Array:
	var entries: Array[Dictionary] = []
	var errors: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}
	var id_format: RegEx = RegEx.create_from_string("^[a-z0-9_]+$")
	var index: int = 0
	for raw: Dictionary in screens():
		index += 1
		var id: String = str(raw.get("id", ""))
		var where: String = "tools/ui_screens.gd: entry %d%s" % [index, "" if id.is_empty() else " (%s)" % id]
		var problems: PackedStringArray = PackedStringArray()
		for key: Variant in raw:
			if not KEYS.has(str(key)):
				problems.append("unknown key '%s' (known: %s)" % [key, ", ".join(KEYS)])
		if id.is_empty() or id_format.search(id) == null:
			problems.append("id must be lower-case letters, digits and _")
		elif seen.has(id):
			problems.append("duplicate id, also entry %d" % int(seen[id]))
		if str(raw.get("title", "")).is_empty():
			problems.append("no title")
		var scene: String = str(raw.get("scene", ""))
		if not scene.is_empty() and not ResourceLoader.exists(scene):
			problems.append("the scene %s doesn't exist" % scene)
		var states: Dictionary = {}
		if raw.has("states"):
			if raw.has("setup"):
				problems.append("has both setup and states; use one")
			if not (raw["states"] is Dictionary) or (raw["states"] as Dictionary).is_empty():
				problems.append("states must be a Dictionary of state name to Callable")
			else:
				for state: Variant in raw["states"]:
					var callable: Variant = (raw["states"] as Dictionary)[state]
					if not (callable is Callable) or not id_format.search(str(state)):
						problems.append("state '%s' must have a lower-case name and a Callable" % state)
					else:
						states[str(state)] = callable
		elif raw.has("setup"):
			if not (raw["setup"] is Callable):
				problems.append("setup must be a Callable")
			else:
				states[DEFAULT_STATE] = raw["setup"]
		elif scene.is_empty():
			problems.append("needs a scene, a setup or states")
		else:
			states[DEFAULT_STATE] = open_view.bind(scene)
		if raw.has("pause") and not (raw["pause"] is bool):
			problems.append("pause must be true or false")
		var overlays: Array[String] = []
		if raw.has("overlays"):
			if not (raw["overlays"] is Array):
				problems.append("overlays must be an Array of node paths (\"/root/Hud\") and scenes (\"res://...tscn\")")
			else:
				for overlay: Variant in (raw["overlays"] as Array):
					var text: String = str(overlay)
					if not (overlay is String) or not (text.begins_with("/root/") or text.begins_with("res://")):
						problems.append("overlay '%s' must be a node path from /root or a scene under res://" % text)
					elif text.begins_with("res://") and not ResourceLoader.exists(text):
						problems.append("the overlay scene %s doesn't exist" % text)
					else:
						overlays.append(text)
		if not id.is_empty() and not seen.has(id):
			seen[id] = index
		if not problems.is_empty():
			for problem: String in problems:
				errors.append("%s: %s" % [where, problem])
			continue
		entries.append({
			"id": id, "title": str(raw["title"]), "scene": scene, "states": states,
			"pause": bool(raw.get("pause", true)), "overlays": overlays,
		})
	return [entries, errors]


func _first_focusable(node: Node) -> Control:
	var control: Control = node as Control
	if control != null and control.focus_mode == Control.FOCUS_ALL and control.visible:
		return control
	for child: Node in node.get_children():
		var found: Control = _first_focusable(child)
		if found != null:
			return found
	return null
