extends SceneTree
## Headless smoke test:
##   godot --headless --path . --script res://tests/smoke_test.gd
## - generates seeded 4-, 5- and 6-sided houses and re-validates each one
##   independently (H00–H10), checking the side count derived from geometry;
## - checks that navigation shows stored houses without generating new ones,
##   and that regeneration replaces all five;
## - runs negative checks proving the validator rejects broken houses.
## Exits with status 1 on any failure.

const Generator := preload("res://scripts/house_generator.gd")
const Validator := preload("res://scripts/house_validator.gd")
const PER_SIDE_COUNT := 8

var failures := 0
var main: Node


func _initialize() -> void:
	var samples := _generation_checks()
	if samples.has(4):
		_negative_checks(samples[4])
	else:
		_fail("no valid sample house for negative checks")
	# The UI check runs on the first frame, once the tree (and main._ready) is live.
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


func _process(_delta: float) -> bool:
	_navigation_checks()
	print("SMOKE TEST %s" % ("PASSED" if failures == 0 else "FAILED (%d)" % failures))
	quit(1 if failures > 0 else 0)
	return true


func _generation_checks() -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var samples := {}
	var failed := 0
	for sides in [4, 5, 6]:
		for i in PER_SIDE_COUNT:
			var house_seed: int = 1000 + sides * 100 + i
			var result := Generator.generate_valid_house(house_seed, sides)
			for line in result["rejections"]:
				print("  seed %d rejected candidate: %s" % [house_seed, line.left(300)])
			if not result["ok"]:
				failed += 1
				print("seed %d (%d sides): GENERATION FAILED (shown as error, not as a house)" % [house_seed, sides])
				continue
			var house: Dictionary = result["house"]
			var check := Validator.validate_house(house)
			# Side count recomputed from the polygon itself, not from metadata.
			var geometric_sides := Validator.count_sides(house["footprint"])
			if not check["valid"]:
				_fail("seed %d was returned as valid but violates: %s" % [house_seed, check["errors"]])
			elif geometric_sides != sides or check["sides"] != sides or house["footprint"].size() != sides:
				_fail("seed %d: requested %d sides, polygon has %d (validator %d, vertices %d)"
					% [house_seed, sides, geometric_sides, check["sides"], house["footprint"].size()])
			else:
				print("seed %d: valid, %d sides (%s), %d rooms" % [house_seed, geometric_sides, house["shape"],
					house["spaces"].filter(func(s): return s["kind"] == "room").size()])
				if not samples.has(sides):
					samples[sides] = house
	print("Generated %d houses in %.1f ms (%d generation failures)" % [3 * PER_SIDE_COUNT, (Time.get_ticks_usec() - t0) / 1000.0, failed])
	if failed > 0:
		_fail("%d seeds produced no valid house" % failed)
	return samples


func _navigation_checks() -> void:
	var gen0: int = main.generation
	var stored: Array = main.houses.duplicate()   # same result objects
	if stored.size() != 5 or main.index != 0 or not is_same(main.view.result, stored[0]):
		_fail("startup must store five houses and display house 1")
	for r in stored:
		if not r["ok"] or not Validator.validate_house(r["house"])["valid"]:
			_fail("startup stored a house that is not valid")
	var steps := [["next", 1], ["next", 2], ["prev", 1], ["prev", 0], ["prev", 4], ["next", 0]]
	for step in steps:
		if step[0] == "next":
			main.show_next()
		else:
			main.show_previous()
		var same_data: bool = main.generation == gen0 and main.houses.size() == 5
		for i in 5:
			same_data = same_data and is_same(main.houses[i], stored[i])
		if main.index != step[1] or not is_same(main.view.result, stored[step[1]]) or not same_data:
			_fail("navigation %s should show stored house %d without regenerating" % [step[0], step[1] + 1])
	if main.counter.text != "House 1 / 5":
		_fail("counter label should read 'House 1 / 5', got '%s'" % main.counter.text)
	main.show_next()
	main.regenerate_all()
	if main.generation != gen0 + 1 or main.index != 0 or not is_same(main.view.result, main.houses[0]):
		_fail("regeneration must store a new set and return to house 1")
	for i in 5:
		var r: Dictionary = main.houses[i]
		if is_same(r, stored[i]) or (r["ok"] and stored[i]["ok"] and main._signature(r["house"]) == main._signature(stored[i]["house"])):
			_fail("regeneration did not replace house %d" % (i + 1))
		if not r["ok"] or not Validator.validate_house(r["house"])["valid"]:
			_fail("regenerated house %d is not valid" % (i + 1))
	if failures == 0:
		print("navigation check OK: wraps 1↔5 without regenerating; regeneration replaced all five")


func _negative_checks(base: Dictionary) -> void:
	var h := base.duplicate(true)
	var c: Rect2 = _courtyard(h)["rect"]
	_courtyard(h)["rect"] = Rect2(c.position, Vector2(c.size.x, c.size.y + 0.5))
	_expect_rejected(h, "H01", "courtyard larger than 16 m²", "area incorrect")

	h = base.duplicate(true)
	_courtyard(h)["rect"] = Rect2(c.position, Vector2(c.size.x, c.size.y - 0.5))
	_expect_rejected(h, "H01", "courtyard smaller than 16 m²", "area incorrect")

	# Northern wing turned north–south: keep one northern room, make it deeper than wide.
	h = base.duplicate(true)
	var pastas_top: float = h["spaces"].filter(func(s): return s["kind"] == "pastas")[0]["rect"].position.y
	var north: Array = h["spaces"].filter(func(s): return s["kind"] == "room" and s["rect"].end.y <= pastas_top + 0.001)
	var keep: Dictionary = north[0]
	for extra in north.slice(1):
		h["spaces"].erase(extra)
	keep["rect"] = Rect2(keep["rect"].end - Vector2(2.2, 3.0), Vector2(2.2, 3.0))
	_expect_rejected(h, "H02", "northern wing oriented north–south", "east–west")

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
	var fp: PackedVector2Array = h["footprint"]
	h["footprint"] = PackedVector2Array([fp[0], fp[2], fp[1], fp[3]])   # bow-tie
	_expect_rejected(h, "H00", "self-intersecting exterior polygon", "intersect")

	h = base.duplicate(true)
	fp = h["footprint"]
	fp.insert(1, (fp[0] + fp[1]) / 2.0)   # redundant collinear vertex
	h["footprint"] = fp
	_expect_rejected(h, "H00", "exterior polygon with a redundant collinear side", "collinear")

	h = base.duplicate(true)
	var room: Dictionary = h["spaces"].filter(func(s): return s["kind"] == "room")[0]
	room["rect"] = Rect2(room["rect"].position - Vector2(0.0, 1.0), room["rect"].size)
	_expect_rejected(h, "H05", "room extending outside the footprint", "outside the footprint")

	h = base.duplicate(true)
	room = h["spaces"].filter(func(s): return s["kind"] == "room")[0]
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
		print("negative check OK: %s -> %s" % [what, check["errors"].filter(func(e): return e.begins_with(code + ":") and e.contains(phrase))[0]])


func _fail(msg: String) -> void:
	failures += 1
	printerr("FAIL: " + msg)
