extends RefCounted
## Base of the autoplay scenarios · framework-owned: replaced on upgrade.
##
## The project's scenarios, res://tools/autoplay_scenarios.gd, extend this file and list how the game
## is played by `bash tools/autoplay.sh <scenario>`. Override scenarios(); set the thresholds below in
## _init() when the game needs others. Don't edit this file in a project.
##
## A scenario is a Dictionary:
##   id      String, required: lower-case letters, digits and _ (run folders start with it)
##   title   String: what it plays, for the list
##   kind    "smoke", "scripted" or "strategy", required. Exactly one smoke scenario is required.
##   seed    int: the seed when --seed isn't given (default: default_seed)
## smoke: starts a run, opens every view the catalog (tools/ui_screens.gd) lists through the real
## shell (the actions whose `opens` names it, backing out with a `back` action or ui_cancel), then
## plays `turns` turns: up to `actions_per_turn` random actions, then the progress action.
##   turns             int, default smoke_turns
##   actions_per_turn  int, default 2
##   skip_views        Array of catalog ids smoke doesn't open (a game over screen, say)
##   steps             int: the most actions it takes (default 200)
## scripted: an ordered list of actions, with an expect after each.
##   actions  Array of {"do": action id, "repeat": n (default 1), "expect": ...}. The expect is
##            checked after the action (after the last repeat): a Dictionary of keys the adapter's
##            state() must have with these values ("view" is the current view's catalog id), or a
##            Callable(state: Dictionary) -> bool.
## strategy: picks among the legal actions for `steps` actions or until the run is over.
##   strategy  "random" (weighted), "greedy" (the highest `score`) or "end_turn" (the progress
##             action whenever it's offered and nothing blocks it, else a random one)
##   steps     int, default default_steps
##   weights   Dictionary of action id to weight, for random and end_turn (default: the action's
##             own `weight`, else 1.0)
##   score     Callable(action: Dictionary, state: Dictionary) -> float, required for greedy; ties
##             go to the action listed first
## --steps N caps every scenario at N actions.

const KEYS: PackedStringArray = ["id", "title", "kind", "seed", "turns", "actions_per_turn", "skip_views",
	"steps", "actions", "strategy", "weights", "score"]
const KINDS: PackedStringArray = ["smoke", "scripted", "strategy"]
const STRATEGIES: PackedStringArray = ["random", "greedy", "end_turn"]

## The seed a scenario plays with when neither --seed nor its own `seed` gives one.
var default_seed: int = 1
## The actions a strategy scenario takes when it doesn't say.
var default_steps: int = 50
## The turns smoke plays when it doesn't say.
var smoke_turns: int = 3
## Frames to wait after each action before the invariants are checked.
var settle_frames: int = 3
## Then, while a Tween that ends is still running, up to this many more frames (5 seconds at the
## 60 frames a second autoplay runs at), so an animation ends the same way on every run.
var tween_frames: int = 300
## Progress blocked across this many actions, with nothing offered that unblocks it, is a softlock.
var softlock_actions: int = 10
## A step (the action and its settle frames) slower than this, in seconds, is a finding.
var step_seconds: float = 5.0
## A step that hasn't finished after this many seconds stops the run.
var stuck_seconds: float = 60.0
## The orphan-node count growing at every one of this many turns in a row is a finding.
var orphan_turns: int = 3


## Every scenario. Override this.
func scenarios() -> Array[Dictionary]:
	return []


## The scenarios, checked: [entries, errors]. An entry with an error is left out; a missing smoke
## scenario is an error.
func checked_scenarios() -> Array:
	var entries: Array[Dictionary] = []
	var errors: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}
	var id_format: RegEx = RegEx.create_from_string("^[a-z0-9_]+$")
	var smokes: int = 0
	var index: int = 0
	for raw: Dictionary in scenarios():
		index += 1
		var id: String = str(raw.get("id", ""))
		var where: String = "tools/autoplay_scenarios.gd: scenario %d%s" % [index, "" if id.is_empty() else " (%s)" % id]
		var problems: PackedStringArray = PackedStringArray()
		for key: Variant in raw:
			if not KEYS.has(str(key)):
				problems.append("unknown key '%s' (known: %s)" % [key, ", ".join(KEYS)])
		if id.is_empty() or id_format.search(id) == null:
			problems.append("id must be lower-case letters, digits and _")
		elif seen.has(id):
			problems.append("duplicate id, also scenario %d" % int(seen[id]))
		var kind: String = str(raw.get("kind", ""))
		if not KINDS.has(kind):
			problems.append("kind must be one of %s" % ", ".join(KINDS))
		for key: String in ["seed", "turns", "actions_per_turn", "steps"]:
			if raw.has(key) and not (raw[key] is int and int(raw[key]) >= 0):
				problems.append("%s must be a whole number, 0 or more" % key)
		if raw.has("skip_views") and not (raw["skip_views"] is Array):
			problems.append("skip_views must be an Array of catalog ids")
		if raw.has("weights") and not (raw["weights"] is Dictionary):
			problems.append("weights must be a Dictionary of action id to weight")
		if kind == "scripted":
			if not (raw.get("actions", null) is Array) or (raw["actions"] as Array).is_empty():
				problems.append("a scripted scenario needs actions: an Array of {\"do\": action id, \"expect\": ...}")
			else:
				var number: int = 0
				for item: Variant in (raw["actions"] as Array):
					number += 1
					var step: Dictionary = item if item is Dictionary else {}
					if str(step.get("do", "")).is_empty():
						problems.append("action %d needs \"do\": an action id" % number)
					if step.has("repeat") and not (step["repeat"] is int and int(step["repeat"]) >= 1):
						problems.append("action %d: repeat must be a whole number, 1 or more" % number)
					if step.has("expect") and not (step["expect"] is Dictionary or step["expect"] is Callable):
						problems.append("action %d: expect must be a Dictionary or a Callable(state) -> bool" % number)
		elif kind == "strategy":
			var strategy: String = str(raw.get("strategy", ""))
			if not STRATEGIES.has(strategy):
				problems.append("strategy must be one of %s" % ", ".join(STRATEGIES))
			elif strategy == "greedy" and not (raw.get("score", null) is Callable):
				problems.append("a greedy strategy needs score: a Callable(action, state) -> float")
		if not id.is_empty() and not seen.has(id):
			seen[id] = index
		if not problems.is_empty():
			for problem: String in problems:
				errors.append("%s: %s" % [where, problem])
			continue
		if kind == "smoke":
			smokes += 1
		var entry: Dictionary = raw.duplicate()
		entry["title"] = str(raw.get("title", id))
		entries.append(entry)
	if smokes == 0:
		errors.append("tools/autoplay_scenarios.gd: a smoke scenario is required ({\"id\": \"smoke\", \"kind\": \"smoke\"})")
	elif smokes > 1:
		errors.append("tools/autoplay_scenarios.gd: only one smoke scenario, please (%d found)" % smokes)
	return [entries, errors]
