extends RefCounted
## The game's autoplay invariants · project-owned: edit freely.
##
## tools/autoplay.gd calls check() after every step, with the adapter's state() (plus "view", the
## current view's catalog id) and the adapter itself, next to the framework's own invariants (errors,
## softlocks, no actions, a freed view, no focus, orphan growth, slow steps). Return one line per
## broken rule; each becomes a finding with a screenshot and a repro.
##
## Examples:
##	if int(state.get("gold", 0)) < 0: problems.append("gold is below zero: %d" % int(state["gold"]))
##	if int(state.get("roster", 0)) > int(state.get("roster_cap", 0)): problems.append("the roster is over its cap")


## PLACEHOLDER: the game's own rules that must hold after every step.
func check(_state: Dictionary, _adapter: Object) -> PackedStringArray:
	return PackedStringArray()
