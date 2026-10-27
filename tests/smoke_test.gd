extends SceneTree
## Headless smoke test:
##   godot --headless --path . --script res://tests/smoke_test.gd
## Generates 20 seeded houses, re-validates each one independently, and runs a
## few negative checks proving the validator rejects broken houses.
## Exits with status 1 on any failure.

const Generator := preload("res://scripts/house_generator.gd")
const Validator := preload("res://scripts/house_validator.gd")

var failures := 0


func _init() -> void:
	var t0 := Time.get_ticks_usec()
	var sample := {}
	var failed_generations := 0
	for i in 20:
		var house_seed := 1000 + i
		var result := Generator.generate_valid_house(house_seed)
		for line in result["rejections"]:
			print("  seed %d rejected candidate: %s" % [house_seed, line])
		if not result["ok"]:
			failed_generations += 1
			print("seed %d: GENERATION FAILED (shown as error, not as a house)" % house_seed)
			continue
		var check := Validator.validate_house(result["house"])
		if not check["valid"]:
			_fail("seed %d was returned as valid but violates: %s" % [house_seed, check["errors"]])
		else:
			print("seed %d: valid, %d rooms, attempt %d" % [house_seed,
				result["house"]["spaces"].filter(func(s): return s["kind"] == "room").size(), result["attempts"]])
		if sample.is_empty():
			sample = result["house"]
	print("Generated 20 houses in %.1f ms (%d generation failures)" % [(Time.get_ticks_usec() - t0) / 1000.0, failed_generations])
	if failed_generations > 0:
		_fail("%d seeds produced no valid house" % failed_generations)

	if sample.is_empty():
		_fail("no valid sample house for negative checks")
	else:
		_negative_checks(sample)

	print("SMOKE TEST %s" % ("PASSED" if failures == 0 else "FAILED (%d)" % failures))
	quit(1 if failures > 0 else 0)


func _negative_checks(base: Dictionary) -> void:
	var h := base.duplicate(true)
	_courtyard(h)["rect"] = Rect2(_courtyard(h)["rect"].position, Vector2(4.0, 4.5))
	_expect_rejected(h, "H01", "courtyard larger than 16 m²")

	h = base.duplicate(true)
	var c: Rect2 = _courtyard(h)["rect"]
	_courtyard(h)["rect"] = Rect2(c.position, Vector2(c.size.x, c.size.y - 0.5))
	_expect_rejected(h, "H01", "courtyard smaller than 16 m²")

	h = base.duplicate(true)
	var nw: Rect2 = h["north_wing"]
	h["north_wing"] = Rect2(nw.position.x, _courtyard(h)["rect"].end.y - nw.size.y, nw.size.x, nw.size.y)
	_expect_rejected(h, "H02", "northern wing placed south of the courtyard")

	h = base.duplicate(true)
	h["openings"] = h["openings"].filter(func(o): return o["kind"] != "open")
	_expect_rejected(h, "H04", "missing courtyard-to-pastas connection")

	# Brick up every opening of one room: replace door gaps with wall.
	h = base.duplicate(true)
	var room_id: int = h["spaces"].filter(func(s): return s["kind"] == "room")[0]["id"]
	var kept: Array = []
	for o in h["openings"]:
		if o["a"] == room_id or o["b"] == room_id:
			h["walls"].append({"rect": o["rect"], "kind": "interior", "orient": "h" if o["axis"] == "ns" else "v"})
		else:
			kept.append(o)
	h["openings"] = kept
	_expect_rejected(h, "H07", "inaccessible room", "inaccessible")

	h = base.duplicate(true)
	var room: Dictionary = h["spaces"].filter(func(s): return s["kind"] == "room")[0]
	room["rect"] = Rect2(room["rect"].position + Vector2(1.0, 0.0), room["rect"].size)
	_expect_rejected(h, "H05", "overlapping room geometry", "overlap")


func _courtyard(h: Dictionary) -> Dictionary:
	return h["spaces"].filter(func(s): return s["kind"] == "courtyard")[0]


func _expect_rejected(house: Dictionary, code: String, what: String, phrase := "") -> void:
	var check := Validator.validate_house(house)
	var hit := false
	for e in check["errors"]:
		hit = hit or (e.begins_with(code + ":") and (phrase == "" or e.contains(phrase)))
	if check["valid"] or not hit:
		_fail("validator did not reject %s with %s (got %s)" % [what, code, check["errors"]])
	else:
		print("negative check OK: %s -> %s" % [what, check["errors"].filter(func(e): return e.begins_with(code + ":"))[0]])


func _fail(msg: String) -> void:
	failures += 1
	printerr("FAIL: " + msg)
