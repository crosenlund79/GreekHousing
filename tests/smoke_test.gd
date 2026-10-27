extends SceneTree
## Headless smoke test:
##   godot --headless --path . --script res://tests/smoke_test.gd </dev/null
## - generates seeded 4-, 5- and 6-sided houses and re-validates each one
##   independently (H00–H11), recomputing side count and corner angles from
##   the polygon;
## - negative checks proving the validator rejects broken houses;
## - 3D checks: meshes read back from the 3D view match the validated data
##   (exterior polygon, courtyard, walls, open doors), rotation moves only the
##   camera;
## - UI checks: navigation shows stored houses without regenerating and builds
##   only the selected house's 3D model; regeneration replaces all five.
## Exits with status 1 on any failure.

const Generator := preload("res://scripts/house_generator.gd")
const Validator := preload("res://scripts/house_validator.gd")
const House3DView := preload("res://scripts/house_3d_view.gd")
const PER_SIDE_COUNT := 8

var failures := 0
var main: Node
var samples := {}


func _initialize() -> void:
	samples = _generation_checks()
	if samples.size() == 3:
		_negative_checks(samples[4])
	else:
		_fail("missing valid sample houses for 4, 5 and 6 sides")
	# 3D and UI checks run on the first frame, once the tree is live.
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


var _frames := 0


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		for sides in samples:
			_3d_checks(samples[sides], sides)
		_navigation_checks()
		main.queue_free()   # release meshes before the engine shuts down
		return false
	print("SMOKE TEST %s" % ("PASSED" if failures == 0 else "FAILED (%d)" % failures))
	quit(1 if failures > 0 else 0)
	return true


func _generation_checks() -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var found := {}
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
			# Side count and corner angles recomputed from the polygon itself.
			var fp: PackedVector2Array = house["footprint"]
			var geometric_sides := Validator.count_sides(fp)
			var angles := Validator.interior_angles(fp)
			var bad_angles := angles.filter(func(a): return a >= 80.0 and a <= 110.0)
			if not check["valid"]:
				_fail("seed %d was returned as valid but violates: %s" % [house_seed, check["errors"]])
			elif geometric_sides != sides or check["sides"] != sides or fp.size() != sides:
				_fail("seed %d: requested %d sides, polygon has %d (validator %d, vertices %d)"
					% [house_seed, sides, geometric_sides, check["sides"], fp.size()])
			elif not bad_angles.is_empty():
				_fail("seed %d: footprint corner angles %s fall in 80°–110°" % [house_seed, bad_angles])
			else:
				print("seed %d: valid, %d sides (%s), corners %s, %d rooms" % [house_seed, geometric_sides, house["shape"],
					angles.map(func(a): return snappedf(a, 0.1)),
					house["spaces"].filter(func(s): return s["kind"] == "room").size()])
				if not found.has(sides):
					found[sides] = house
	print("Generated %d houses in %.1f ms (%d generation failures)" % [3 * PER_SIDE_COUNT, (Time.get_ticks_usec() - t0) / 1000.0, failed])
	if failed > 0:
		_fail("%d seeds produced no valid house" % failed)
	return found


# --------------------------------------------------------------------------
# 3D view: meshes must reproduce the validated data exactly
# --------------------------------------------------------------------------

func _3d_checks(house: Dictionary, sides: int) -> void:
	var view: SubViewportContainer = House3DView.new()
	view.size = Vector2(800, 600)
	root.add_child(view)
	var tag := "3D (%d sides)" % sides
	if not view.show_house(house):
		_fail("%s: validated house refused by the 3D view" % tag)
		view.free()
		return
	var invalid := house.duplicate(true)
	invalid.erase("validation")
	var probe: SubViewportContainer = House3DView.new()
	if probe.show_house(invalid) or probe.model.get_child_count() != 0:
		_fail("%s: 3D view accepted a house without a passing validation" % tag)
	probe.free()

	var floors := {}
	var gaps := {}
	var walls := {}
	for mi in view.model.get_children():
		match mi.get_meta("role"):
			"floor": floors[mi.get_meta("ref")] = House3DView.mesh_outline(mi)
			"gap": gaps[mi.get_meta("ref")] = House3DView.mesh_outline(mi)
			"wall": walls[mi.get_meta("ref")] = House3DView.mesh_outline(mi)

	var fp: PackedVector2Array = house["footprint"]
	var fp_area := absf(Validator._signed_area(fp))
	var total := 0.0
	# Floors: one per space, same area and extent as the data.
	if floors.size() != house["spaces"].size():
		_fail("%s: %d floor meshes for %d spaces" % [tag, floors.size(), house["spaces"].size()])
	for sp in house["spaces"]:
		var o: Dictionary = floors.get(sp["id"], {})
		if o.is_empty() or absf(o["area"] - Validator._area(sp)) > 1e-3 or not _bbox(o["points"]).is_equal_approx(sp["rect"]):
			_fail("%s: floor of space %d does not match its geometry" % [tag, sp["id"]])
			continue
		total += o["area"]
		if sp["kind"] == "courtyard" and absf(o["area"] - 16.0) > 0.001:
			_fail("%s: courtyard floor is %.4f m², not 16 m²" % [tag, o["area"]])
	# Walls: exactly one mesh per wall record (none invented), same footprint, 0.8 m tall.
	if walls.size() != house["walls"].size():
		_fail("%s: %d wall meshes for %d walls" % [tag, walls.size(), house["walls"].size()])
	var ext_points := PackedVector2Array()
	for i in house["walls"].size():
		var w: Dictionary = house["walls"][i]
		var o: Dictionary = walls.get(i, {})
		if o.is_empty() or absf(o["area"] - Validator._area(w)) > 1e-3 or not _bbox(o["points"]).is_equal_approx(w["rect"]) \
				or absf(o["top"] - House3DView.WALL_HEIGHT) > 1e-4 or absf(o["bottom"]) > 1e-4:
			_fail("%s: wall %d mesh does not match the validated wall segment" % [tag, i])
			continue
		total += o["area"]
		if w["kind"] == "exterior":
			ext_points.append_array(o["points"])
	# Door and entrance gaps: a floor patch, and no wall mesh across them.
	var openings: Array = house["openings"]
	for i in openings.size():
		var op: Dictionary = openings[i]
		if op["kind"] == "open":
			continue
		if not gaps.has(i):
			_fail("%s: opening %d has no floor patch" % [tag, i])
			continue
		total += gaps[i]["area"]
		var gap_poly := Validator._rect_poly(op["rect"])
		for k in walls:
			var hull := Geometry2D.convex_hull(walls[k]["points"])
			if Validator._overlap_area(gap_poly, hull) > 1e-4:
				_fail("%s: wall %d blocks opening %d" % [tag, k, i])
	# The meshes tile the footprint, and the exterior walls follow its polygon.
	if absf(total - fp_area) > 0.01:
		_fail("%s: floors, gaps and walls cover %.3f of %.3f m²" % [tag, total, fp_area])
	for corner in fp:
		if not Array(ext_points).any(func(p): return p.distance_to(corner) < 1e-3):
			_fail("%s: footprint corner %s is not a corner of the exterior wall meshes" % [tag, corner])
	for p in ext_points:
		if not Geometry2D.is_point_in_polygon(p, fp) and not Validator._segment_on_boundary(p, p, fp):
			_fail("%s: exterior wall point %s lies outside the footprint" % [tag, p])
			break

	# Rotation moves the camera around the centre; the model is untouched.
	var before := _model_state(view)
	var builds: int = view.build_count
	var cam0: Vector3 = view.camera.position
	var dist0 := cam0.distance_to(view.center)
	for steps in [1, -2, 1]:
		view.rotate_view(steps, false)
		var cam: Vector3 = view.camera.position
		var looks_at_center: float = (-view.camera.transform.basis.z).dot((view.center - cam).normalized())
		if absf(cam.distance_to(view.center) - dist0) > 1e-3 or absf(cam.y - cam0.y) > 1e-3 or looks_at_center < 0.9999:
			_fail("%s: rotation changed camera distance/elevation or focal point" % tag)
		if steps == 1 and cam.distance_to(cam0) < 0.1 and view.yaw != 0.0:
			_fail("%s: rotation did not move the camera" % tag)
	if view.camera.position.distance_to(cam0) > 1e-3:
		_fail("%s: rotating +45°, -90°, +45° did not return the camera" % tag)
	if _model_state(view) != before or view.build_count != builds:
		_fail("%s: rotation changed or rebuilt the model" % tag)
	if failures == 0:
		print("%s check OK: %d floors, %d walls, %d open gaps match the data; rotation keeps the model" % [tag, floors.size(), walls.size(), gaps.size()])
	view.queue_free()


func _model_state(view: SubViewportContainer) -> Array:
	return view.model.get_children().map(func(n): return [n.get_instance_id(), n.transform])


func _bbox(points: PackedVector2Array) -> Rect2:
	return Validator._bbox(points)


# --------------------------------------------------------------------------
# UI: navigation and regeneration
# --------------------------------------------------------------------------

func _navigation_checks() -> void:
	var gen0: int = main.generation
	var stored: Array = main.houses.duplicate()   # same result objects
	var view3d: SubViewportContainer = main.view3d
	if stored.size() != 5 or main.index != 0 or not is_same(main.plan_view.result, stored[0]):
		_fail("startup must store five houses and display house 1")
	for r in stored:
		if not r["ok"] or not Validator.validate_house(r["house"])["valid"]:
			_fail("startup stored a house that is not valid")
	if stored[0]["ok"] and not is_same(view3d.house, stored[0]["house"]):
		_fail("startup must build the 3D model of house 1")
	var steps := [["next", 1], ["next", 2], ["prev", 1], ["prev", 0], ["prev", 4], ["next", 0]]
	for step in steps:
		var builds: int = view3d.build_count
		if step[0] == "next":
			main.show_next()
		else:
			main.show_previous()
		var same_data: bool = main.generation == gen0 and main.houses.size() == 5
		for i in 5:
			same_data = same_data and is_same(main.houses[i], stored[i])
		var r: Dictionary = stored[step[1]]
		var wall_meshes: int = view3d.model.get_children().filter(func(n): return n.get_meta("role") == "wall").size()
		if main.index != step[1] or not is_same(main.plan_view.result, r) or not same_data:
			_fail("navigation %s should show stored house %d without regenerating" % [step[0], step[1] + 1])
		elif r["ok"] and (not is_same(view3d.house, r["house"]) or view3d.build_count != builds + 1 or wall_meshes != r["house"]["walls"].size()):
			_fail("navigation %s should rebuild the 3D model once, for house %d only" % [step[0], step[1] + 1])
	if main.counter.text != "House 1 / 5":
		_fail("counter label should read 'House 1 / 5', got '%s'" % main.counter.text)
	var builds_before_rotation: int = view3d.build_count
	main.rotate_left()
	main.rotate_right()
	main.rotate_right()
	if view3d.build_count != builds_before_rotation or main.generation != gen0 or not is_same(view3d.house, stored[0]["house"]):
		_fail("rotation buttons must not regenerate or rebuild")
	main.toggle_plan()
	if view3d.visible or not main.plan_view.visible or not is_same(main.plan_view.result, stored[0]):
		_fail("2D plan toggle should show the same stored house")
	main.toggle_plan()
	main.show_next()
	main.regenerate_all()
	if main.generation != gen0 + 1 or main.index != 0 or not is_same(main.plan_view.result, main.houses[0]):
		_fail("regeneration must store a new set and return to house 1")
	if main.houses[0]["ok"] and not is_same(view3d.house, main.houses[0]["house"]):
		_fail("regeneration must build the 3D model of the new house 1")
	for i in 5:
		var r: Dictionary = main.houses[i]
		if is_same(r, stored[i]) or (r["ok"] and stored[i]["ok"] and main._signature(r["house"]) == main._signature(stored[i]["house"])):
			_fail("regeneration did not replace house %d" % (i + 1))
		if not r["ok"] or not Validator.validate_house(r["house"])["valid"]:
			_fail("regenerated house %d is not valid" % (i + 1))
	if failures == 0:
		print("navigation check OK: wraps 1↔5 without regenerating, one 3D build per selection; rotation never rebuilds; regeneration replaced all five")


# --------------------------------------------------------------------------
# Validator negative checks
# --------------------------------------------------------------------------

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
	var keep: Dictionary = north.filter(func(s): return not s.has("poly"))[0]
	for extra in north:
		if extra != keep:
			h["spaces"].erase(extra)
	keep["rect"] = Rect2(keep["rect"].end - Vector2(2.2, 3.0), Vector2(2.2, 3.0))
	_expect_rejected(h, "H02", "northern wing oriented north–south", "east–west")

	# Brick up every opening of one room: replace door gaps with wall.
	h = base.duplicate(true)
	var room_id: int = _plain_room(h)["id"]
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

	# Right-angled footprint: the bounding rectangle of the real footprint.
	h = base.duplicate(true)
	var box := Validator._bbox(h["footprint"])
	h["footprint"] = Validator._rect_poly(box)
	_expect_rejected(h, "H11", "rectangular footprint (90° corners)", "80°–110°")

	# A corner of exactly 110° (inclusive limit) must be rejected too.
	h = base.duplicate(true)
	var t := tan(deg_to_rad(20.0)) * box.size.y
	h["footprint"] = PackedVector2Array([Vector2(box.position.x + t, box.position.y), Vector2(box.end.x - t, box.position.y), box.end, Vector2(box.position.x, box.end.y)])
	_expect_rejected(h, "H11", "corner of exactly 110°", "110.00°")

	h = base.duplicate(true)
	var room := _plain_room(h)
	room["rect"] = Rect2(room["rect"].position - Vector2(0.0, 1.0), room["rect"].size)
	_expect_rejected(h, "H05", "room extending outside the footprint", "outside the footprint")

	h = base.duplicate(true)
	room = _plain_room(h)
	room["rect"] = Rect2(room["rect"].position + Vector2(1.0, 0.0), room["rect"].size)
	_expect_rejected(h, "H05", "overlapping room geometry", "overlap")


func _courtyard(h: Dictionary) -> Dictionary:
	return h["spaces"].filter(func(s): return s["kind"] == "courtyard")[0]


## A northern room not trimmed by a slanted wall (plain rectangle).
func _plain_room(h: Dictionary) -> Dictionary:
	return h["spaces"].filter(func(s): return s["kind"] == "room" and s["zone"] == "north" and not s.has("poly"))[0]


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
