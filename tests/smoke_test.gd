extends SceneTree
## Headless smoke test:
##   godot --headless --path . --script res://tests/smoke_test.gd </dev/null
## City block:
## - generates blocks on fixed outlines (5 or 6 houses each) and re-checks
##   them independently: every house H00–H12, inside the block, no overlaps,
##   its own 16 m² courtyard, an entrance straight onto the block perimeter on
##   >= 2.0 m frontage, no rotation; plus the block validator (B00–B07);
## - an outline that cannot hold 5 houses fails with a reason (no block shown);
## - negative block checks: 4 or 7 houses, overlap, house outside the block,
##   entrance off the perimeter, shared spaces, shared courtyard, rotation;
## - 3D: one model with every house's floors and walls built from the data;
##   selecting and rotating never rebuild it; picking finds the clicked house;
## - coordinate schematic at block and house level;
## - UI workflow: draw by clicking, close on the first corner, generate, select,
##   rotate, switch views without regenerating, regenerate in the same outline.
## Single houses (standalone generator, kept for the validator):
## - seeded 4-, 5- and 6-sided houses re-validated (H00–H12) from geometry;
## - negative checks proving the house validator rejects broken houses;
## - 3D meshes and the schematic reproduce the validated data exactly.
## Exits with status 1 on any failure.

const Generator := preload("res://scripts/house_generator.gd")
const Validator := preload("res://scripts/house_validator.gd")
const BG := preload("res://scripts/block_generator.gd")
const BV := preload("res://scripts/block_validator.gd")
const House3DView := preload("res://scripts/house_3d_view.gd")
const SchematicView := preload("res://scripts/house_schematic_view.gd")
const G := preload("res://scripts/geometry.gd")
const PER_SIDE_COUNT := 8
## Fixed block outlines (metres, X east, Y south) with seeds known to succeed.
const BLOCKS := [
	["wide hexagon", [Vector2(5, 8), Vector2(30, 4), Vector2(62, 6), Vector2(70, 18), Vector2(62, 32), Vector2(28, 34), Vector2(3, 27)], 1],
	["quadrilateral", [Vector2(4, 6), Vector2(66, 2), Vector2(70, 30), Vector2(8, 34)], 2],
	["quadrilateral (5 houses)", [Vector2(4, 6), Vector2(66, 2), Vector2(70, 30), Vector2(8, 34)], 6],
	["long shallow", [Vector2(2, 5), Vector2(98, 3), Vector2(96, 20), Vector2(4, 22)], 1],
	["irregular heptagon", [Vector2(18, 26), Vector2(50, 21), Vector2(96, 23), Vector2(120, 33), Vector2(112, 50), Vector2(62, 54), Vector2(22, 49)], 11],
]
## Too small for 5 houses: generation must fail with a reason.
const SMALL_BLOCK := [Vector2(10, 4), Vector2(55, 2), Vector2(72, 20), Vector2(50, 36), Vector2(6, 30)]

var failures := 0
var main: Node
var samples := {}
var blocks: Array = []


func _initialize() -> void:
	blocks = _block_generation_checks()
	if not blocks.is_empty():
		_block_negative_checks(blocks[0])
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
		for b in blocks:
			_block_3d_checks(b)
			_block_schematic_checks(b)
		for sides in samples:
			_3d_checks(samples[sides], sides)
		_ui_checks()
		main.queue_free()   # release meshes before the engine shuts down
		return false
	print("SMOKE TEST %s" % ("PASSED" if failures == 0 else "FAILED (%d)" % failures))
	quit(1 if failures > 0 else 0)
	return true


# --------------------------------------------------------------------------
# City block generation, independently re-checked
# --------------------------------------------------------------------------

func _block_generation_checks() -> Array:
	var found: Array = []
	for spec in BLOCKS:
		var poly := PackedVector2Array(spec[1])
		var t0 := Time.get_ticks_usec()
		var res := BG.generate_block(poly, spec[2])
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var tag := "block '%s'" % spec[0]
		if not res["ok"]:
			_fail("%s (seed %d): generation failed: %s" % [tag, spec[2], res["reason"]])
			continue
		var b: Dictionary = res["block"]
		var before := failures
		_check_block_geometry(b, tag)
		if failures == before:
			print("%s: VALID, %d houses in %.0f ms (%d layouts), unbuilt corner ground %.1f m²" % [tag, b["houses"].size(), ms,
				res["attempts"], b["validation"]["residual_area"]])
			found.append(b)
	if not found.any(func(b): return b["houses"].size() == 5) or not found.any(func(b): return b["houses"].size() == 6):
		_fail("the fixed outlines should cover blocks of both 5 and 6 houses")
	if found.size() != BLOCKS.size():
		_fail("only %d of %d fixed block outlines produced a valid block" % [found.size(), BLOCKS.size()])
	var small := BG.generate_block(PackedVector2Array(SMALL_BLOCK), 1)
	if small["ok"] or not small["block"].is_empty() or small["reason"] == "":
		_fail("a block too small for 5 houses must fail with a reason and no block")
	else:
		print("small block check OK: refused — %s" % small["reason"].left(120))
	var bowtie := PackedVector2Array([Vector2(0, 0), Vector2(60, 30), Vector2(60, 0), Vector2(0, 30)])
	if BG.check_block_polygon(bowtie) == "" or BG.generate_block(bowtie, 1)["ok"]:
		_fail("a self-intersecting block outline must be refused")
	return found


## Everything the brief demands, measured directly on the geometry (not on
## the validator's say-so), then the validators themselves.
func _check_block_geometry(b: Dictionary, tag: String) -> void:
	var poly: PackedVector2Array = b["polygon"]
	var houses: Array = b["houses"]
	if houses.size() < 5 or houses.size() > 6:
		_fail("%s: %d houses (required 5 or 6)" % [tag, houses.size()])
	var v := BV.validate_block(b)
	if not v["valid"] or not b["validation"]["valid"]:
		_fail("%s: block returned as valid but violates: %s" % [tag, v["errors"]])
	for i in houses.size():
		var h: Dictionary = houses[i]
		var ht := "%s house %d" % [tag, i + 1]
		var fp: PackedVector2Array = h["footprint"]
		var hv := Validator.validate_house(h)
		if not hv["valid"]:
			_fail("%s violates %s" % [ht, hv["errors"]])
		var sides := Validator.count_sides(fp)
		if sides < 4 or sides > 6 or fp.size() != sides:
			_fail("%s: footprint has %d sides" % [ht, sides])
		var bad := Validator.interior_angles(fp).filter(func(a): return a >= 80.0 and a <= 110.0)
		if not bad.is_empty():
			_fail("%s: corner angles %s in 80°–110°" % [ht, bad])
		if Validator._outside_area(fp, poly) > 1e-4:
			_fail("%s extends outside the block" % ht)
		if h.get("rotation", 0.0) != 0.0:
			_fail("%s is rotated" % ht)
		for j in range(i + 1, houses.size()):
			if Validator._overlap_area(fp, houses[j]["footprint"]) > 1e-4:
				_fail("%s overlaps house %d" % [ht, j + 1])
		var courts: Array = h["spaces"].filter(func(s): return s["kind"] == "courtyard")
		if courts.size() != 1 or absf(G.item_area(courts[0]) - 16.0) > 1e-3:
			_fail("%s: needs exactly one 16 m² courtyard" % ht)
		elif Validator._outside_area(G.shape(courts[0]), fp) > 1e-4:
			_fail("%s: courtyard outside its own house" % ht)
		# Entrance outer face straight on a block edge (a street), on >= 2.0 m frontage.
		var ctx := {"footprint": fp, "by_id": {}}
		for sp in h["spaces"]:
			ctx["by_id"][sp["id"]] = sp
		var on_street := false
		for op in h["openings"]:
			if op["kind"] == "entrance":
				var face := Validator._street_face(op, ctx)
				on_street = on_street or (not face.is_empty() and Validator._segment_on_boundary(face[0], face[1], poly))
		if not on_street:
			_fail("%s: no entrance on the block perimeter" % ht)
		if Validator.street_frontage(h)["length"] < 2.0:
			_fail("%s: street frontage under 2.0 m" % ht)
		# Northern wing north of the courtyard in the one shared frame.
		var court_top: float = G.bbox(G.shape(courts[0])).position.y if courts.size() == 1 else 0.0
		var wing: Array = h["spaces"].filter(func(s): return s["kind"] == "room" and s.get("zone", "") == "north")
		if wing.is_empty() or wing.any(func(s): return (s["rect"] as Rect2).end.y > court_top + 1e-4):
			_fail("%s: northern wing not north of its courtyard" % ht)
	for key in ["spaces", "walls", "openings", "shared_spaces"]:
		if b.has(key):
			_fail("%s: the block defines shared %s" % [tag, key])


# --------------------------------------------------------------------------
# Block validator negative checks
# --------------------------------------------------------------------------

func _block_negative_checks(base: Dictionary) -> void:
	var b := _copy_block(base)
	b["houses"] = b["houses"].slice(0, 4)
	_expect_block_rejected(b, "B01", "a block of 4 houses", "4 houses")

	b = _copy_block(base)
	b["houses"].append(b["houses"][0].duplicate(true))
	_expect_block_rejected(b, "B03", "two houses on the same plot", "overlap")

	b = _copy_block(base)
	_translate_house(b["houses"][0], Vector2(0.0, -300.0))
	_expect_block_rejected(b, "B02", "a house outside the block", "outside the block")

	# Streets moved away: the block outline is enlarged, entrances no longer on it.
	b = _copy_block(base)
	var c := G.centroid(b["polygon"])
	var big := PackedVector2Array(Array(b["polygon"]).map(func(p): return c + (p - c) * 1.25))
	b["polygon"] = big
	for h in b["houses"]:
		h["block"] = big
	_expect_block_rejected(b, "B05", "entrances not on the block perimeter", "no entrance on the block perimeter")

	b = _copy_block(base)
	b["shared_spaces"] = [{"kind": "courtyard", "rect": Rect2(30, 15, 4, 4)}]
	_expect_block_rejected(b, "B04", "a communal courtyard", "shared space")

	# House 1's courtyard placed inside house 2.
	b = _copy_block(base)
	var court2: Dictionary = _courtyard(b["houses"][1])
	var court1: Dictionary = _courtyard(b["houses"][0])
	court1["rect"] = court2["rect"]
	if court2.has("poly"):
		court1["poly"] = court2["poly"]
	_expect_block_rejected(b, "B06", "a courtyard reaching into a neighbour", "courtyard reaches into House 2")

	b = _copy_block(base)
	b["houses"][2]["rotation"] = 90.0
	_expect_block_rejected(b, "B07", "a rotated house", "rotated")


func _copy_block(b: Dictionary) -> Dictionary:
	var out := b.duplicate(true)
	out.erase("validation")
	return out


## Moves every piece of a house's geometry (a stand-in for a misplaced plot).
func _translate_house(h: Dictionary, d: Vector2) -> void:
	h["footprint"] = Transform2D(0.0, d) * (h["footprint"] as PackedVector2Array)
	for key in ["spaces", "walls", "openings"]:
		for item in h[key]:
			item["rect"] = Rect2((item["rect"] as Rect2).position + d, (item["rect"] as Rect2).size)
			if item.has("poly"):
				item["poly"] = Transform2D(0.0, d) * (item["poly"] as PackedVector2Array)


func _expect_block_rejected(b: Dictionary, code: String, what: String, phrase: String) -> void:
	var check := BV.validate_block(b)
	var hits: Array = check["errors"].filter(func(e): return e.begins_with(code + ":") and e.contains(phrase))
	if check["valid"] or hits.is_empty():
		_fail("block validator did not reject %s with %s (got %s)" % [what, code, check["errors"].slice(0, 4)])
	else:
		print("block negative check OK: %s -> %s" % [what, hits[0]])
	var shown: SubViewportContainer = House3DView.new()
	b["validation"] = check
	if shown.show_block(b) or shown.model.get_child_count() != 0:
		_fail("3D view displayed an invalid block (%s)" % what)
	shown.free()


# --------------------------------------------------------------------------
# 3D city view: one model, all houses, built from the data
# --------------------------------------------------------------------------

func _block_3d_checks(b: Dictionary) -> void:
	var view: SubViewportContainer = House3DView.new()
	view.size = Vector2(1000, 700)
	root.add_child(view)
	var houses: Array = b["houses"]
	var tag := "3D block (%d houses)" % houses.size()
	if not view.show_block(b, 0):
		_fail("%s: validated block refused" % tag)
		view.free()
		return
	var floors := {}
	var walls := {}
	for mi in view.model.get_children():
		var hi: int = mi.get_meta("house")
		match mi.get_meta("role"):
			"floor": floors[hi] = floors.get(hi, 0) + 1
			"wall": walls[hi] = walls.get(hi, 0) + 1
	for i in houses.size():
		if floors.get(i, 0) != houses[i]["spaces"].size() or walls.get(i, 0) != houses[i]["walls"].size():
			_fail("%s: house %d has %d floors / %d walls for %d spaces / %d walls" % [tag, i + 1, floors.get(i, 0),
				walls.get(i, 0), houses[i]["spaces"].size(), houses[i]["walls"].size()])
	if floors.size() != houses.size():
		_fail("%s: floors for %d houses, expected all %d in one model" % [tag, floors.size(), houses.size()])
	# Selecting (by click on a courtyard) and rotating never rebuild the model.
	var before := _model_state(view)
	var builds: int = view.build_count
	for i in houses.size():
		var c := G.centroid(G.shape(_courtyard(houses[i])))
		var picked: int = view.pick_house(view.camera.unproject_position(Vector3(c.x, 0.0, c.y)))
		if picked != i:
			_fail("%s: clicking house %d's courtyard picked %d" % [tag, i + 1, picked])
		view.set_selected(i)
		if view.selected != i or view.overlay.get_children().filter(func(n): return n.get_meta("role") == "highlight").is_empty():
			_fail("%s: selecting house %d shows no highlight" % [tag, i + 1])
	var cam0: Vector3 = view.camera.position
	var dist0 := cam0.distance_to(view.center)
	for steps in [1, -2, 1]:
		view.rotate_view(steps, false)
		var cam: Vector3 = view.camera.position
		var looks_at_center: float = (-view.camera.transform.basis.z).dot((view.center - cam).normalized())
		if absf(cam.distance_to(view.center) - dist0) > 1e-3 or looks_at_center < 0.9999:
			_fail("%s: rotation changed the camera distance or focal point" % tag)
	if view.camera.position.distance_to(cam0) > 1e-3:
		_fail("%s: rotating +45°, -90°, +45° did not return the camera" % tag)
	if _model_state(view) != before or view.build_count != builds:
		_fail("%s: selection or rotation changed or rebuilt the model" % tag)
	var bb := G.bbox(b["polygon"])
	if view.center.distance_to(Vector3(bb.get_center().x, 0.0, bb.get_center().y)) > 1e-3:
		_fail("%s: camera does not orbit the block centre" % tag)
	if failures == 0:
		print("%s check OK: every house's floors and walls in one model; picking, selection and rotation keep it" % tag)
	view.queue_free()


func _block_schematic_checks(b: Dictionary) -> void:
	var view: Control = SchematicView.new()
	view.size = Vector2(1200, 800)
	root.add_child(view)
	var tag := "block schematic"
	if not view.show_block(b, 0):
		_fail("%s: validated block refused" % tag)
		view.queue_free()
		return
	var text: String = view.inspection_text()
	var poly: PackedVector2Array = b["polygon"]
	for i in poly.size():
		if not text.contains("B%d: (%.2f, %.2f)" % [i, poly[i].x, poly[i].y]):
			_fail("%s: block vertex B%d not listed with global coordinates" % [tag, i])
	var bm: Dictionary = view._bm
	if bm["houses"].size() != b["houses"].size() or bm["party"].is_empty():
		_fail("%s: houses or party walls missing" % tag)
	for h in bm["houses"]:
		if h["entrances"].is_empty() or absf(h["court_area"] - 16.0) > 1e-3:
			_fail("%s: house %d shows no entrance or a wrong courtyard" % [tag, h["index"] + 1])
	var clicked := []
	view.house_clicked.connect(func(i): clicked.append(i))
	var last: int = b["houses"].size() - 1
	var c := G.centroid(G.shape(_courtyard(b["houses"][last])))
	var sel: Dictionary = view.select_at(view.world_to_screen(c))
	if sel.get("index", -1) != last or clicked != [last]:
		_fail("%s: clicking house %d selected %s" % [tag, last + 1, sel])
	if failures == 0:
		print("%s check OK: %d block vertices, %d houses, %d party walls; clicking selects a house" % [tag, poly.size(), bm["houses"].size(), bm["party"].size()])
	view.queue_free()


# --------------------------------------------------------------------------
# Single houses (standalone generator)
# --------------------------------------------------------------------------

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
	_schematic_checks(house, sides, floors, ext_points)

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


# --------------------------------------------------------------------------
# Coordinate schematic (single house)
# --------------------------------------------------------------------------

## The schematic must show exactly the geometry the 3D meshes were built from.
func _schematic_checks(house: Dictionary, sides: int, floors: Dictionary, ext_points: PackedVector2Array) -> void:
	var tag := "schematic (%d sides)" % sides
	var view: Control = SchematicView.new()
	view.size = Vector2(1200, 800)
	root.add_child(view)
	if not view.show_house(house, "House test"):
		_fail("%s: validated house refused" % tag)
		view.queue_free()
		return
	var m: Dictionary = view._m
	var text: String = view.inspection_text()
	var fp: PackedVector2Array = house["footprint"]
	# Exterior vertices: the stored polygon itself, each a corner of the 3D exterior walls.
	if m["footprint"] != fp:
		_fail("%s: footprint differs from the house data" % tag)
	for i in fp.size():
		if not Array(ext_points).any(func(p): return p.distance_to(fp[i]) < 1e-4):
			_fail("%s: P%d is not a corner of the 3D exterior walls" % [tag, i])
		if not text.contains("P%d: (%.2f, %.2f)" % [i, fp[i].x, fp[i].y]):
			_fail("%s: panel does not list P%d with its coordinates" % [tag, i])
		var e: float = m["edges"][i]
		if absf(e - fp[i].distance_to(fp[(i + 1) % fp.size()])) > 1e-9:
			_fail("%s: edge %d length is wrong" % [tag, i])
	# Angles: identical to the validator's H11 measurement, none forbidden, all displayed.
	var angles := Validator.interior_angles(fp)
	for i in angles.size():
		if absf(m["angles"][i] - angles[i]) > 1e-9 or Validator.forbidden_angle(m["angles"][i]):
			_fail("%s: angle at P%d differs from H11 validation or is forbidden" % [tag, i])
		if not text.contains("angle %.2f°" % angles[i]):
			_fail("%s: panel does not show the angle at P%d" % [tag, i])
	# Areas: shoelace on the actual outline, equal to the 3D floor mesh area.
	var polygonal := 0
	for sp in m["spaces"]:
		var data: Dictionary = house["spaces"].filter(func(s): return s["id"] == sp["id"])[0]
		var shoelace := G.polygon_area(data["poly"] if data.has("poly") else G.rect_poly(data["rect"]))
		if absf(sp["area"] - shoelace) > 1e-9 or absf(sp["area"] - floors[sp["id"]]["area"]) > 1e-4:
			_fail("%s: area of space %d does not match its geometry / 3D floor" % [tag, sp["id"]])
		if sp["polygonal"]:
			polygonal += 1
			if sp["area"] > (sp["rect"] as Rect2).get_area() - 0.01:
				_fail("%s: polygonal space %d measured as its bounding box" % [tag, sp["id"]])
		if sp["kind"] == "courtyard" and absf(sp["area"] - 16.0) > 0.001:
			_fail("%s: courtyard shows %.4f m²" % [tag, sp["area"]])
	# Doors: the schematic's opening segments lie in the validated opening rectangles.
	for d in m["doors"]:
		var r: Rect2 = (house["openings"][d["index"]]["rect"] as Rect2).grow(1e-6)
		if not r.has_point(d["start"]) or not r.has_point(d["end"]) or absf(d["width"] - maxf(r.size.x, r.size.y) + 2e-6) > 1e-5:
			_fail("%s: door D%d does not match its validated opening" % [tag, d["index"]])
	# Picking: clicking inside a room selects it and shows its data.
	var rooms: Array = m["spaces"].filter(func(s): return s["kind"] == "room")
	var trimmed: Array = rooms.filter(func(s): return s["polygonal"])
	var pick: Dictionary = trimmed[0] if not trimmed.is_empty() else rooms[0]
	var sel: Dictionary = view.select_at(view.world_to_screen(pick["centroid"]))
	text = view.inspection_text()
	if sel.get("kind", "") != "space" or m["spaces"][sel["index"]]["id"] != pick["id"]:
		_fail("%s: clicking room %d selected %s" % [tag, pick["id"], sel])
	elif not text.begins_with("[b]Selected[/b]") or not text.contains(pick["name"]) or not text.contains("Area: %.2f m²" % pick["area"]):
		_fail("%s: selection panel does not show room %d" % [tag, pick["id"]])
	elif pick["polygonal"] and not text.contains("(%.2f, %.2f)" % [pick["shape"][0].x, pick["shape"][0].y]):
		_fail("%s: selection panel does not list the polygon vertices" % tag)
	var corner: Dictionary = view.select_at(view.world_to_screen(fp[0]))
	if corner.get("kind", "") != "vertex" or corner["index"] != 0:
		_fail("%s: clicking P0 did not select the vertex" % tag)
	if failures == 0:
		print("%s check OK: %d vertices, %d spaces (%d polygonal) match the 3D model; picking works" % [tag, fp.size(), m["spaces"].size(), polygonal])
	view.queue_free()


func _model_state(view: SubViewportContainer) -> Array:
	return view.model.get_children().map(func(n): return [n.get_instance_id(), n.transform])


func _bbox(points: PackedVector2Array) -> Rect2:
	return Validator._bbox(points)


# --------------------------------------------------------------------------
# UI workflow: draw, close, generate, select, rotate, views, regenerate
# --------------------------------------------------------------------------

func _ui_checks() -> void:
	var dv: Control = main.draw_view
	if main.mode != "draw" or not dv.visible or main.view3d.visible or not main.block.is_empty() or not dv.points.is_empty():
		_fail("startup must show an empty drawing area and no houses")
	if not main.buttons["generate"].disabled:
		_fail("Generate City Block must be disabled before a block is drawn")
	if dv.size.x < 100.0 or dv.size.y < 100.0:
		_fail("drawing area has no size (%s)" % dv.size)
		return
	var pts: Array = BLOCKS[4][1]
	for p in pts:
		dv.click(dv.world_to_screen(p))
	# A corner that would make the outline cross itself is refused.
	dv.click(dv.world_to_screen(Vector2(60, 10)))
	if dv.points.size() != pts.size() or dv.closed:
		_fail("drawing: expected %d corners and an open outline, got %d (closed %s)" % [pts.size(), dv.points.size(), dv.closed])
	dv.click(dv.world_to_screen(pts[0]) + Vector2(3, -2))   # near the first corner closes it
	if not dv.closed or main.polygon != PackedVector2Array(pts) or main.buttons["generate"].disabled:
		_fail("clicking the first corner must close the block and enable Generate City Block")
	if not main.generate(BLOCKS[4][2]):
		_fail("Generate City Block failed on the drawn outline: %s" % main.last_reason)
		return
	var b: Dictionary = main.block
	var gen: int = main.generation
	var view3d: SubViewportContainer = main.view3d
	if main.mode != "3d" or not view3d.visible or dv.visible or not is_same(view3d.block, b) or not b["validation"]["valid"]:
		_fail("after generating, the 3D view must show the validated block")
	if b["houses"].size() < 5 or b["houses"].size() > 6 or not main.info.text.begins_with("VALID CITY BLOCK"):
		_fail("the city view must report a valid block of 5 or 6 houses (info: %s)" % main.info.text)
	var builds: int = view3d.build_count
	var state := _model_state(view3d)
	main.select_house(2)
	main.rotate_left()
	main.rotate_right()
	main.rotate_right()
	if main.selected != 2 or view3d.selected != 2 or view3d.build_count != builds or _model_state(view3d) != state \
			or main.generation != gen or not is_same(main.block, b):
		_fail("selecting and rotating must keep the block and the 3D model")
	main.show_coordinates()
	if main.mode != "schematic" or not main.schematic.visible or view3d.visible or main.schematic.level != "block" \
			or not is_same(main.schematic.block, b):
		_fail("Show Coordinates must show the block level of the same block")
	main.show_house_coordinates()
	if main.schematic.level != "house" or not is_same(main.schematic.house, b["houses"][2]):
		_fail("Selected House must show the coordinates of house 3")
	main.back_to_3d()
	if not view3d.visible or main.selected != 2 or view3d.build_count != builds or main.generation != gen:
		_fail("Back to 3D must return to the same block and selection without rebuilding")
	# Regenerate: same outline, a new validated block.
	main.generate(BLOCKS[4][2] + 1)
	if main.polygon != PackedVector2Array(pts) or main.block.is_empty() or is_same(main.block, b) \
			or main.block["polygon"] != PackedVector2Array(pts) or not main.block["validation"]["valid"]:
		_fail("Regenerate Houses must build a new valid block in the same outline")
	# A failing outline shows a reason, never a block.
	main.draw_new_block()
	if not dv.points.is_empty() or not main.block.is_empty() or main.mode != "draw" or not view3d.model.get_children().is_empty():
		_fail("Draw New Block must clear the outline and the houses")
	dv.set_polygon(PackedVector2Array(SMALL_BLOCK))
	main._on_polygon_closed(PackedVector2Array(SMALL_BLOCK))
	if main.generate(1) or not main.block.is_empty() or main.mode != "draw" or not main.info.text.begins_with("GENERATION FAILED"):
		_fail("a block that cannot hold 5 houses must show GENERATION FAILED and no houses")
	if failures == 0:
		print("UI check OK: draw → close → generate %d houses → select/rotate/coordinates without rebuilding → regenerate in the same outline; failure shown as error" % b["houses"].size())


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

	# Street frontage shorter than 2.0 m (H12.1): pinch the south edge round the entrance.
	h = base.duplicate(true)
	var front := Validator.street_frontage(h)
	var ent: Rect2 = h["openings"].filter(func(o): return o["kind"] == "entrance")[0]["rect"]
	fp = h["footprint"]
	fp[front["edge"]] = Vector2(ent.get_center().x + 0.75, front["a"].y)
	fp[(front["edge"] + 1) % fp.size()] = Vector2(ent.get_center().x - 0.75, front["b"].y)
	h["footprint"] = fp
	_expect_rejected(h, "H12.1", "street frontage of 1.5 m", "frontage is 1.50 m")

	# No entrance on the street frontage (H12): the street declared on the north side.
	h = base.duplicate(true)
	h["street_side"] = "north"
	_expect_rejected(h, "H12", "house without direct street access", "directly onto the street")

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
