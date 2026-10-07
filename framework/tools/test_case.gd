extends RefCounted
## Base for Godot Director tests · framework-owned: overwritten on upgrade.
##
## A test file is res://tests/**/test_*.gd (folder set in tools/check.cfg) that starts with
##     extends "res://tools/test_case.gd"
## and has synchronous methods named test_*() -> void. `bash tools/check.sh` runs every one.
## Game rules live in RefCounted classes, so a test builds them directly; no scene tree needed.

var _gdir_errors: PackedStringArray = PackedStringArray()


## Override to set up fresh state before each test.
func before_each() -> void:
	pass


func expect(condition: bool, message: String = "") -> void:
	if not condition:
		fail("expected true" + _about(message))


func expect_false(condition: bool, message: String = "") -> void:
	if condition:
		fail("expected false" + _about(message))


## Equal values of the same type. An int and a float compare as numbers.
func expect_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	if not _same(actual, expected):
		fail("expected %s, got %s%s" % [_show(expected), _show(actual), _about(message)])


func expect_ne(actual: Variant, unexpected: Variant, message: String = "") -> void:
	if _same(actual, unexpected):
		fail("expected anything but %s%s" % [_show(unexpected), _about(message)])


func expect_near(actual: float, expected: float, tolerance: float = 0.0001, message: String = "") -> void:
	if absf(actual - expected) > tolerance:
		fail("expected %s ± %s, got %s%s" % [expected, tolerance, actual, _about(message)])


func fail(message: String) -> void:
	_gdir_errors.append(message)


# --- used by tools/check.gd ---------------------------------------------------------------------

func _gdir_begin() -> void:
	_gdir_errors = PackedStringArray()


func _gdir_end() -> PackedStringArray:
	return _gdir_errors


func _same(a: Variant, b: Variant) -> bool:
	var type_a: int = typeof(a)
	var type_b: int = typeof(b)
	if type_a != type_b:
		if (type_a == TYPE_INT or type_a == TYPE_FLOAT) and (type_b == TYPE_INT or type_b == TYPE_FLOAT):
			var number_a: float = a
			var number_b: float = b
			return is_equal_approx(number_a, number_b)
		return false
	return a == b


func _show(value: Variant) -> String:
	return str(value) if typeof(value) == TYPE_OBJECT else var_to_str(value)


func _about(message: String) -> String:
	return "" if message.is_empty() else " (%s)" % message
