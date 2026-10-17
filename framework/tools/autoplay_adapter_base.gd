extends RefCounted
## The AutoplayAdapter base · framework-owned: replaced on upgrade.
##
## The game's adapter, res://tools/autoplay_adapter.gd, extends this file. tools/autoplay.gd (run it
## with `bash tools/autoplay.sh`) talks to the game only through it: it starts a run, asks which
## player actions are legal, performs them, and reads the state its invariants and the report need.
## Don't edit this file in a project.
##
## An action, as list_actions() returns it, is a Dictionary:
##   id        String, required: stable, lower case (scenarios, repros and the log name it)
##   label     String: what the player sees, for the log and the report (default: the id)
##   kind      "ui" or "api", required. A ui action is performed through real input: a click at the
##             centre of the control `node` names (taken from the element map), or a press of the
##             InputMap action `input` (its first key, then pad button). An api action is performed
##             by perform(), which calls the game's systems directly, for speed.
##   node      String: the unique node name (%EndTurn, or EndTurn) of the control to click
##   input     String: the InputMap action to press (a key or a pad button), instead of node
##   progress  bool: this is the main progress action (End Turn, Next Day); smoke and the end_turn
##             strategy end turns with it
##   opens     String: the catalog id (tools/ui_screens.gd) of the view this action opens; smoke
##             opens every catalog view with these
##   back      bool: this action closes the current view; smoke backs out of a view with it (else
##             it presses ui_cancel)
##   unblocks  bool: this action is meant to clear what blocks progress (assign the idle worker);
##             a block that lasts while every such action has been tried is a softlock
##   weight    float: how often the random strategy picks it (default 1.0; a scenario may override)
## A ui action may also carry the api fields; perform() is only called for kind "api".
##
## Randomness: the game's run owns one seeded RandomNumberGenerator (rules.md › Seeded randomness).
## start_run(run_seed) passes the seed to it, so the same seed plays the same run.

## The scene tree, set by tools/autoplay.gd before start_run().
var tree: SceneTree = null
## The catalog's views, scene path to catalog id (tools/ui_screens.gd), set by tools/autoplay.gd.
var views: Dictionary = {}
## True once this base's start_run() has run: the game's adapter hasn't filled it in, so there is
## no run to play. tools/autoplay.gd then skips the run and says what to wire (exit 0), so a game
## made from the seeds passes the check until its adapter is written.
var unfilled: bool = false


## Starts a new run with this seed, the way a player starts one (press New Game in the shell, or call
## the run's API), and waits until the player may act. It may await. This base version only marks the
## adapter unfilled.
func start_run(_run_seed: int) -> void:
	unfilled = true


## Loads a run from a save file (a player's report, a repro), the way Continue does. False when the
## game can't.
func load_save(_path: String) -> bool:
	return false


## Writes the current run to a save file at path through the game's save API, for a repro. False when
## the game has no saves; the repro then has the seed and the actions only.
func save_run(_path: String) -> bool:
	return false


## The player actions that are legal right now, in a stable order (see the action format above).
func list_actions() -> Array[Dictionary]:
	return []


## Performs an api action through the game's systems. True when it was done. It may await.
func perform(_action: Dictionary) -> bool:
	return false


## A small summary of the run for invariants, expects and the report; plain data. It may reuse the
## play log's snapshot.
func state() -> Dictionary:
	return {}


## Why the player can't continue right now, "" when they can: the play log's own hook by default.
func progress_block_reason() -> String:
	var logger: Node = play_log()
	return str(logger.call("progress_block_reason")) if logger != null and logger.has_method("progress_block_reason") else ""


## True when the run has ended (won, lost, the last day passed). Autoplay stops a strategy scenario there.
func is_run_over() -> bool:
	return false


## The catalog id of the view the player sees now, "" when none: by default the current scene's, from
## the catalog. A game whose shell swaps views inside one scene overrides it.
func current_view() -> String:
	var scene: Node = tree.current_scene if tree != null else null
	if scene == null or not is_instance_valid(scene):
		return ""
	return str(views.get(scene.scene_file_path, scene.name.to_snake_case()))


## The node of the current view, as the shell keeps it, for the invariants (it isn't freed, it has a
## focused control). Return exactly what the shell holds, even when it was freed. Typed Variant on
## purpose: a typed return would stop on a freed node instead of reporting it.
func view_node() -> Variant:
	return tree.current_scene if tree != null else null


# --- helpers ------------------------------------------------------------------------------------

## The PlayLog autoload, or null.
func play_log() -> Node:
	return tree.root.get_node_or_null("PlayLog") if tree != null else null


## An autoload or any node by its path from the root (/root/RunState), or null.
func node(path: String) -> Node:
	return tree.root.get_node_or_null(NodePath(path)) if tree != null else null


## The control with this unique name (%EndTurn or EndTurn) in the current scene, or null.
func unique(unique_name: String) -> Node:
	var scene: Node = tree.current_scene if tree != null else null
	if scene == null:
		return null
	return scene.get_node_or_null(NodePath("%" + unique_name.trim_prefix("%")))


## Waits the given number of frames.
func wait_frames(count: int) -> void:
	for index: int in count:
		await tree.process_frame
