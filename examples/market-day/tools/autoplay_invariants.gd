extends RefCounted
## The game's autoplay invariants · project-owned: edit freely.
##
## tools/autoplay.gd calls check() after every step with the adapter's state(); each line returned is
## a finding.


func check(state: Dictionary, _adapter: Object) -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if int(state.get("gold", 0)) < 0:
		problems.append("gold is below zero: %d" % int(state["gold"]))
	if int(state.get("grain", 0)) < 0:
		problems.append("grain is below zero: %d" % int(state["grain"]))
	return problems
