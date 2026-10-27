extends RefCounted
## Constraint-based constructor for Classical Greek pastas houses.
##
## The plan is built from the rules instead of placing random rectangles: a
## northern wing of rooms, a full-width pastas below it, and a southern zone of
## vertical strips (side rooms, courtyard, entrance passage, side rooms).
##
## Exterior footprint (H00 + H11): 4, 5 or 6 sides and no corner between 80°
## and 110°. The north and south faces stay horizontal (wing and street
## front); each east/west side is either
##   "slant" — one straight side tilted 21.5–24° (corners 90 ± tilt), or
##   "vee"   — two sides meeting at an inward point (corners 90 − tilt with
##             tilt 12–15°, reflex point), placed on an east–west wall line.
## 4 sides = slant + slant, 5 = vee + slant, 6 = vee + vee.
## The orthogonal layout is sized so the outermost rooms keep at least 2.5 m
## beyond the slanted walls, then every space and interior wall is clipped to
## the interior polygon (footprint minus the 0.50 m exterior wall band).
## The courtyard, entrance passage and all doors are never clipped.
##
## Every candidate is then checked by house_validator.gd; only a house that
## passes all hard rules H00–H12 is ever returned as valid.
##
## The layout runs on an integer centimetre grid (5 cm steps) so shared edges
## are exact; geometry is converted to metres when emitted. Only the slanted
## exterior sides and the clipped ends lie off the grid.

const V := preload("res://scripts/house_validator.gd")
const G := preload("res://scripts/geometry.gd")

const STREET := V.STREET
const MAX_ATTEMPTS := 10
const SIDE_COUNTS := [4, 5, 6]

const EXT := 50   # exterior wall thickness, cm (V.EXT_WALL)
const INT := 25   # interior wall thickness, cm (V.INT_WALL)
const COURTYARD_SIZES := [Vector2i(400, 400), Vector2i(320, 500), Vector2i(500, 320)]  # all exactly 16 m²
const NORTH_DEPTH := Vector2i(300, 450)
const PASTAS_DEPTH := Vector2i(150, 250)
const PASSAGE_WIDTH := Vector2i(120, 160)
const SIDE_COL_BASE := Vector2i(250, 400)   # side-room width kept clear of the slanted wall
const NORTH_ROOM_MIN := 250
const NORTH_ROOM_MAX := 600
const ROOM_MIN := 200            # V.MIN_ROOM_WIDTH
const ROOM_MIN_AREA := 50000     # cm², V.MIN_ROOM_AREA
const DOOR_WIDTH := Vector2i(90, 120)
const DOOR_MARGIN := 15          # keeps door jambs clear of wall junctions
# Side tilts from north–south, degrees, chosen with a margin from H11's limits.
const SLANT_TILT := Vector2(21.5, 24.0)
const VEE_TILT := Vector2(12.0, 15.0)
const VEE_MAX_TILT := 28.0       # steeper half of a vee keeps room corners >= 62°

static var _failure := ""        # why the last build_candidate() gave up


## Builds candidates for `house_seed` until one passes validation (max 10).
## The side count is drawn from the seed unless `sides` (4, 5 or 6) is given.
## Returns {ok, house, attempts, sides, rejections}; `house` is empty when not ok.
static func generate_valid_house(house_seed: int, sides := 0) -> Dictionary:
	if sides == 0:
		var pick := RandomNumberGenerator.new()
		pick.seed = hash([house_seed, "sides"])
		sides = SIDE_COUNTS[pick.randi() % SIDE_COUNTS.size()]
	var rejections: Array = []
	for attempt in MAX_ATTEMPTS:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([house_seed, attempt])
		var house := build_candidate(rng, sides)
		if house.is_empty():
			rejections.append("attempt %d: construction gave up: %s" % [attempt + 1, _failure])
			continue
		house["seed"] = house_seed
		house["attempt"] = attempt + 1
		var check := V.validate_house(house)
		if check["valid"]:
			house["validation"] = check
			return {"ok": true, "house": house, "attempts": attempt + 1, "sides": sides, "rejections": rejections}
		rejections.append("attempt %d: %s" % [attempt + 1, "; ".join(check["errors"])])
	return {"ok": false, "house": {}, "attempts": MAX_ATTEMPTS, "sides": sides, "rejections": rejections}


## Constructs one candidate plan with the requested number of exterior sides.
## Returns {} if the sampled parameters cannot hold a legal arrangement (the
## caller then tries another candidate).
static func build_candidate(rng: RandomNumberGenerator, sides: int) -> Dictionary:
	# 1. Courtyard of exactly 16 m² and the depths of the east–west bands.
	var court: Vector2i = COURTYARD_SIZES[rng.randi() % COURTYARD_SIZES.size()]
	var dn := _step(rng, NORTH_DEPTH)
	var dp := _step(rng, PASTAS_DEPTH)
	var pb := EXT + dn + INT + dp       # pastas bottom = courtyard top
	var yb := pb + court.y              # interior south face
	var depth := yb + EXT
	var D := depth / 100.0

	# 2. Side profiles. A vee point sits on whichever east–west wall line (wing
	# wall or pastas south wall) is nearer mid-depth, so no room is concave.
	var vee_y := (EXT + dn + INT / 2.0) / 100.0
	if absf((pb + INT / 2.0) / 100.0 - D / 2.0) < absf(vee_y - D / 2.0):
		vee_y = (pb + INT / 2.0) / 100.0
	var kinds: Array = {4: ["slant", "slant"], 5: ["vee", "slant"], 6: ["vee", "vee"]}[sides]
	if rng.randf() < 0.5:
		kinds.reverse()
	var chains: Array = []   # [west, east]
	for k in kinds:
		var ch := _make_slant(rng, D) if k == "slant" else _make_vee(rng, D, vee_y)
		if ch.is_empty():
			_failure = "no vee side fits this depth"
			return {}
		chains.append(ch)
	var probes: Array = chains.map(func(ch): return _probe_inset(ch, D))

	# 3. Southern zone as west-to-east strips; both sides carry a strip of rooms
	# widened by the slanted wall's intrusion so the core is never clipped.
	var south_y := Vector2(pb / 100.0, yb / 100.0)
	var cols: Array = [{"kind": "side", "west": true,
		"w": _step(rng, SIDE_COL_BASE) + _cut_cm(probes[0], south_y)}]
	var core := [{"kind": "passage", "w": _step(rng, PASSAGE_WIDTH)}, {"kind": "courtyard", "w": court.x}]
	if rng.randf() < 0.5:
		core.reverse()
	cols.append_array(core)
	cols.append({"kind": "side", "west": false, "w": _step(rng, SIDE_COL_BASE) + _cut_cm(probes[1], south_y)})
	var wi := INT * (cols.size() - 1)   # clear interior width
	for c in cols:
		wi += c["w"]
	var width := wi + 2 * EXT
	var clear: int = court.y - INT

	# Side strips hold one room, or two stacked rooms when the depth allows.
	var south_rooms := 0
	for c in cols:
		if c["kind"] != "side":
			continue
		c["split"] = -1
		if clear >= 2 * ROOM_MIN + INT and rng.randf() < 0.6:
			c["split"] = _step(rng, Vector2i(ROOM_MIN, clear - INT - ROOM_MIN))
		south_rooms += 2 if c["split"] > 0 else 1

	# 4. Northern wing: choose a room count that fits, lowering it if needed.
	# The end rooms are widened by the slanted walls' intrusion.
	var wing_y := Vector2(EXT / 100.0, (EXT + dn) / 100.0)
	var extra := [_cut_cm(probes[0], wing_y), _cut_cm(probes[1], wing_y)]
	var min_w := maxi(NORTH_ROOM_MIN, ceili(ROOM_MIN_AREA / float(dn) / 5.0) * 5)
	var feasible: Array = []
	for n in range(2, V.MAX_ROOMS - south_rooms + 1):
		var fixed: int = extra[0] + extra[1] + INT * (n - 1)
		if n + south_rooms >= V.MIN_ROOMS and fixed + n * min_w <= wi and fixed + n * NORTH_ROOM_MAX >= wi:
			feasible.append(n)
	if feasible.is_empty():
		_failure = "no northern room count fits the width"
		return {}
	var target := rng.randi_range(V.MIN_ROOMS, V.MAX_ROOMS) - south_rooms
	var n: int = feasible[0]
	for f in feasible:
		if absi(f - target) < absi(n - target):
			n = f
	var lo: Array = []
	var hi: Array = []
	for i in n:
		var e: int = extra[0] if i == 0 else (extra[1] if i == n - 1 else 0)
		lo.append(min_w + e)
		hi.append(NORTH_ROOM_MAX + e)
	var widths := _partition(rng, wi - INT * (n - 1), lo, hi)

	# 5. Exterior polygon (metres), clockwise on screen from the north-west
	# corner, and the interior polygon every space must fit in.
	var W := width / 100.0
	var west := _chain_points(chains[0], D)
	var east := _chain_points(chains[1], D)
	var fp := PackedVector2Array([west[0], Vector2(W - east[0].x, 0.0)])
	for i in range(1, east.size()):
		fp.append(Vector2(W - east[i].x, east[i].y))
	for i in range(west.size() - 1, 0, -1):
		fp.append(west[i])
	var q := V.inset_polygon(fp, V.EXT_WALL)

	var b := {"spaces": [], "walls": [], "openings": []}

	# Northern wing rooms separated by full-depth north–south partitions.
	var north: Array = []
	var x := EXT
	for i in n:
		north.append(_space(b, "room", "north", Rect2i(x, EXT, widths[i], dn)))
		if i < n - 1:
			_wall(b, Rect2i(x + widths[i], EXT, INT, dn), "v")
		x += widths[i] + INT
	_wall(b, Rect2i(EXT, EXT + dn, wi, INT), "h")

	# 6. Pastas across the full width, open to the courtyard below.
	var pastas := _space(b, "pastas", "middle", Rect2i(EXT, EXT + dn + INT, wi, dp))

	# 7. Southern strips.
	x = EXT
	for c in cols:
		c["x0"] = x
		x += c["w"] + INT
	var court_id := -1
	var passage_id := -1
	var side_rooms: Array = []   # [{id, col, top}]
	for c in cols:
		var x0: int = c["x0"]
		match c["kind"]:
			"courtyard":
				court_id = _space(b, "courtyard", "south", Rect2i(x0, pb, c["w"], court.y))
				c["id"] = court_id
			"passage":
				passage_id = _space(b, "passage", "south", Rect2i(x0, pb + INT, c["w"], clear))
				c["id"] = passage_id
			"side":
				if c["split"] > 0:
					var top: int = c["split"]
					side_rooms.append({"id": _space(b, "room", "south", Rect2i(x0, pb + INT, c["w"], top)), "col": c, "top": true})
					_wall(b, Rect2i(x0, pb + INT + top, c["w"], INT), "h")
					side_rooms.append({"id": _space(b, "room", "south", Rect2i(x0, pb + 2 * INT + top, c["w"], yb - pb - 2 * INT - top)), "col": c, "top": false})
				else:
					side_rooms.append({"id": _space(b, "room", "south", Rect2i(x0, pb + INT, c["w"], clear)), "col": c, "top": false})

	# Walls between strips; those flanking the courtyard rise to the pastas line.
	var ew_spans: Array = []   # x-intervals of the wall along the pastas' south edge
	for i in cols.size():
		if cols[i]["kind"] != "courtyard":
			ew_spans.append(Vector2i(cols[i]["x0"], cols[i]["x0"] + cols[i]["w"]))
		if i == cols.size() - 1:
			continue
		var wx: int = cols[i]["x0"] + cols[i]["w"]
		var by_court: bool = cols[i]["kind"] == "courtyard" or cols[i + 1]["kind"] == "courtyard"
		var y0 := pb if by_court else pb + INT
		_wall(b, Rect2i(wx, y0, INT, yb - y0), "v")
		if not by_court:
			ew_spans.append(Vector2i(wx, wx + INT))
	for span in _merge(ew_spans):
		_wall(b, Rect2i(span.x, pb, span.y - span.x, INT), "h")

	# Room functions (needed before doors: the andron door is off-centre).
	_assign_types(rng, b, north, side_rooms, yb)

	# 8. Openings. Doors through east–west walls stay inside the interior
	# polygon where a slanted wall trims the rooms they join.
	var court_col: Dictionary = cols.filter(func(c): return c["kind"] == "courtyard")[0]
	var passage_col: Dictionary = cols.filter(func(c): return c["kind"] == "passage")[0]
	_opening(b, Rect2i(court_col["x0"], pb, court_col["w"], 0), "ns", "open", pastas, court_id)
	for id in north:
		var r: Rect2i = _rect(b, id)
		var span := _clear_span(q, r.position.x, r.end.x, EXT + dn, EXT + dn + INT)
		if span.y - span.x < DOOR_WIDTH.y + 2 * DOOR_MARGIN:
			_failure = "no room for a door beside a slanted wall"
			return {}
		var d := _door_pos(rng, b, id, span.x, span.y)
		_opening(b, Rect2i(d.x, EXT + dn, d.y, INT), "ns", "door", id, pastas)
	for sr in side_rooms:
		var r: Rect2i = _rect(b, sr["id"])
		var col: Dictionary = sr["col"]
		if sr["top"] and rng.randf() < 0.5:
			var span := _clear_span(q, r.position.x, r.end.x, pb, pb + INT)
			if span.y - span.x >= DOOR_WIDTH.y + 2 * DOOR_MARGIN:
				var d := _door_pos(rng, b, sr["id"], span.x, span.y)
				_opening(b, Rect2i(d.x, pb, d.y, INT), "ns", "door", pastas, sr["id"])
				continue
		var west_side: bool = col["west"]
		var inner_idx := cols.find(col) + (1 if west_side else -1)
		var wall_x: int = r.end.x if west_side else r.position.x - INT
		var d := _door_pos(rng, b, sr["id"], r.position.y, r.end.y)
		var a: int = sr["id"] if west_side else cols[inner_idx]["id"]
		var bb: int = cols[inner_idx]["id"] if west_side else sr["id"]
		_opening(b, Rect2i(wall_x, d.x, INT, d.y), "ew", "door", a, bb)
	# Passage -> courtyard, near the street end.
	var pr := _rect(b, passage_id)
	var pdw := _step(rng, DOOR_WIDTH)
	var py := pr.end.y - DOOR_MARGIN - pdw - _step(rng, Vector2i(0, 40))
	var passage_west: bool = passage_col["x0"] < court_col["x0"]
	var pwx: int = pr.end.x if passage_west else pr.position.x - INT
	_opening(b, Rect2i(pwx, py, INT, pdw), "ew", "door",
		passage_id if passage_west else court_id, court_id if passage_west else passage_id)
	# Street entrance through the south wall into the passage.
	var ew := floori(mini(120, pr.size.x - 2 * DOOR_MARGIN) / 5.0) * 5
	var entrance := Rect2i(pr.position.x + floori((pr.size.x - ew) / 10.0) * 5, yb, ew, EXT)
	_opening(b, entrance, "ns", "entrance", passage_id, STREET)

	# 9. Interior wall lines lose their door gaps; spaces and walls are clipped
	# to the interior polygon; the exterior wall band is one mitred quad per
	# footprint side, with the entrance cut from its side.
	var spaces: Array = []
	for s in b["spaces"]:
		var clipped := _clip(_emit(s), q)
		if clipped.is_empty() or (clipped.has("poly") and s["kind"] in ["courtyard", "passage"]):
			_failure = "a slanted wall would clip the courtyard or passage"
			return {}
		spaces.append(clipped)
	var walls: Array = []
	for w in b["walls"]:
		for piece in _cut(w, b["openings"]):
			var clipped := _clip(_emit(piece), q)
			if clipped.is_empty():
				_failure = "a wall piece falls outside the interior"
				return {}
			walls.append(clipped)
	walls.append_array(_exterior_walls(fp, _m(entrance)))

	return {
		"footprint": fp,
		"shape": _shape_name(chains),
		"street_side": "south",
		"courtyard_dims": Vector2(court) / 100.0,
		"spaces": spaces,
		"walls": walls,
		"openings": b["openings"].map(func(o): return _emit(o)),
	}


# --------------------------------------------------------------------------
# Footprint sides (metres). A chain is described for the west side with x
# measured inward from the bounding box; the east side mirrors it.
# --------------------------------------------------------------------------

static func _make_slant(rng: RandomNumberGenerator, D: float) -> Dictionary:
	var tilt := deg_to_rad(rng.randf_range(SLANT_TILT.x, SLANT_TILT.y))
	return {"type": "slant", "c": D * tan(tilt), "in_north": rng.randf() < 0.5}


## Inward point placed so the interior polygon's matching corner lies at
## `y_target` (the middle of an east–west wall); the longer half is tilted
## by 12–15°, the shorter half more steeply.
static func _make_vee(rng: RandomNumberGenerator, D: float, y_target: float) -> Dictionary:
	var tilt := deg_to_rad(rng.randf_range(VEE_TILT.x, VEE_TILT.y))
	var ch := {"type": "vee", "c": 0.0, "y_p": y_target}
	for k in 6:
		ch["c"] = tan(tilt) * maxf(ch["y_p"], D - ch["y_p"])
		ch["y_p"] += y_target - _probe_inset(ch, D)[4].y
	ch["c"] = tan(tilt) * maxf(ch["y_p"], D - ch["y_p"])
	var steep := rad_to_deg(atan(ch["c"] / minf(ch["y_p"], D - ch["y_p"])))
	if absf(_probe_inset(ch, D)[4].y - y_target) > 0.05 or steep > VEE_MAX_TILT:
		return {}
	return ch


static func _chain_points(ch: Dictionary, D: float) -> Array:
	if ch["type"] == "slant":
		return [Vector2(ch["c"] if ch["in_north"] else 0.0, 0.0), Vector2(0.0 if ch["in_north"] else ch["c"], D)]
	return [Vector2(0.0, 0.0), Vector2(ch["c"], ch["y_p"]), Vector2(0.0, D)]


## Interior polygon of a probe footprint with this chain on the west and a far
## straight east side; measures how far the interior boundary intrudes.
static func _probe_inset(ch: Dictionary, D: float) -> PackedVector2Array:
	var pts := _chain_points(ch, D)
	var poly := PackedVector2Array([pts[0], Vector2(100.0, 0.0), Vector2(100.0, D), pts[-1]])
	for i in range(pts.size() - 2, 0, -1):
		poly.append(pts[i])
	return V.inset_polygon(poly, V.EXT_WALL)


## Largest intrusion (cm, rounded up, +5 cm) of the probe interior boundary
## beyond the straight interior face over the band y_range (metres).
static func _cut_cm(probe: PackedVector2Array, y_range: Vector2) -> int:
	var ys := [y_range.x, y_range.y]
	for p in probe:
		if p.y > y_range.x and p.y < y_range.y:
			ys.append(p.y)
	var cut := 0.0
	for y in ys:
		cut = maxf(cut, _x_range(probe, y).x - V.EXT_WALL)
	return ceili(cut * 100.0 / 5.0) * 5 + 5


## [west, east] x of a polygon on the horizontal line y (x-monotone rows).
static func _x_range(poly: PackedVector2Array, y: float) -> Vector2:
	var lo := INF
	var hi := -INF
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		# 1e-6 m tolerance: a band edge may lie exactly on a horizontal party wall.
		if absf(a.y - b.y) < 1e-6:
			if absf(a.y - y) < 1e-6:
				lo = minf(lo, minf(a.x, b.x))
				hi = maxf(hi, maxf(a.x, b.x))
		elif (a.y - y) * (b.y - y) <= 0.0 or minf(absf(a.y - y), absf(b.y - y)) < 1e-6:
			var t := clampf((y - a.y) / (b.y - a.y), 0.0, 1.0)
			var xi := a.x + (b.x - a.x) * t
			lo = minf(lo, xi)
			hi = maxf(hi, xi)
	return Vector2(lo, hi)


## Part of [from, to) (cm) inside the interior polygon over the whole band
## y0..y1 (cm), so a door there is not clipped by a slanted wall.
static func _clear_span(q: PackedVector2Array, from: int, to: int, y0: int, y1: int) -> Vector2i:
	var ys := [y0 / 100.0, y1 / 100.0]
	for p in q:
		if p.y > y0 / 100.0 and p.y < y1 / 100.0:
			ys.append(p.y)
	var lo := from
	var hi := to
	for y in ys:
		var xr := _x_range(q, y)
		lo = maxi(lo, ceili(xr.x * 100.0 - 0.01))
		hi = mini(hi, floori(xr.y * 100.0 + 0.01))
	return Vector2i(lo, hi)


static func _shape_name(chains: Array) -> String:
	var kinds: Array = chains.map(func(ch): return ch["type"])
	if kinds == ["vee", "vee"]:
		return "waisted hexagon"
	if kinds.has("vee"):
		return "pentagon, one waisted side"
	if chains[0]["in_north"] == chains[1]["in_north"]:
		return "trapezoid, narrower to the %s" % ("north" if chains[0]["in_north"] else "south")
	return "rhomboid"


## Space or wall (metres) intersected with the interior polygon. Unchanged
## items stay plain rectangles; trimmed ones get an exact `poly` and their
## `rect` becomes its bounding box. Returns {} if nothing (or several pieces) remain.
static func _clip(item: Dictionary, q: PackedVector2Array) -> Dictionary:
	var r: Rect2 = item["rect"]
	var parts := Geometry2D.intersect_polygons(V._rect_poly(r), q)
	if parts.size() != 1:
		return {}
	var poly: PackedVector2Array = parts[0]
	if absf(absf(V._signed_area(poly)) - r.get_area()) < 1e-4:   # Clipper rounding only
		return item
	item["poly"] = poly
	item["rect"] = V._bbox(poly)
	return item


# --------------------------------------------------------------------------
# Construction helpers (centimetre grid)
# --------------------------------------------------------------------------

static func _step(rng: RandomNumberGenerator, range_cm: Vector2i) -> int:
	return rng.randi_range(ceili(range_cm.x / 5.0), floori(range_cm.y / 5.0)) * 5


static func _space(b: Dictionary, kind: String, zone: String, r: Rect2i) -> int:
	var id: int = b["spaces"].size()
	b["spaces"].append({"id": id, "kind": kind, "zone": zone, "type": "", "rect": r})
	return id


static func _rect(b: Dictionary, id: int) -> Rect2i:
	return b["spaces"][id]["rect"]


static func _wall(b: Dictionary, r: Rect2i, orient: String) -> void:
	b["walls"].append({"rect": r, "kind": "interior", "orient": orient})


static func _opening(b: Dictionary, r: Rect2i, axis: String, kind: String, a: int, other: int) -> void:
	b["openings"].append({"rect": r, "axis": axis, "kind": kind, "a": a, "b": other})


## Splits `total` cm into widths with per-room bounds [lo[i], hi[i]], on the 5 cm grid.
static func _partition(rng: RandomNumberGenerator, total: int, lo: Array, hi: Array) -> Array:
	var n := lo.size()
	var widths: Array = lo.duplicate()
	var weights: Array = []
	var spare := total
	for i in n:
		weights.append(rng.randf_range(0.3, 1.0))
		spare -= lo[i]
	for chunk in floori(spare / 5.0):
		var sum := 0.0
		for i in n:
			if widths[i] < hi[i]:
				sum += weights[i]
		var pick := rng.randf() * sum
		for i in n:
			if widths[i] >= hi[i]:
				continue
			pick -= weights[i]
			if pick <= 0.0 or i == n - 1:
				widths[i] += 5
				break
	return widths


## Door position along a wall segment [from, to): returns (start, width).
## Andron doors sit off-centre, as at Olynthos, to suit the couch layout.
static func _door_pos(rng: RandomNumberGenerator, b: Dictionary, id: int, from: int, to: int) -> Vector2i:
	var dw := _step(rng, DOOR_WIDTH)
	var lo := from + DOOR_MARGIN
	var hi := to - DOOR_MARGIN - dw
	if b["spaces"][id]["type"] == "Andron":
		return Vector2i(ceili(lo / 5.0) * 5 if rng.randf() < 0.5 else floori(hi / 5.0) * 5, dw)
	var mid := floori((lo + hi) / 2.0)
	var jitter := floori((hi - lo) / 4.0)
	return Vector2i(clampi(floori(rng.randi_range(mid - jitter, mid + jitter) / 5.0) * 5, lo, hi), dw)


static func _assign_types(rng: RandomNumberGenerator, b: Dictionary, north: Array, side_rooms: Array, yb: int) -> void:
	var spaces: Array = b["spaces"]
	# Hearth room ("oikos") in the northern wing, off the pastas.
	var kitchen: int = north[0]
	for id in north:
		if _rect(b, id).size.x > _rect(b, kitchen).size.x or (rng.randf() < 0.3 and _rect(b, id).size.x >= 300):
			kitchen = id
	spaces[kitchen]["type"] = "Kitchen / hearth"
	# Andron: preferably a near-square room on the street side.
	var candidates: Array = []
	for sr in side_rooms:
		var r := _rect(b, sr["id"])
		if r.end.y == yb and mini(r.size.x, r.size.y) >= 300:
			candidates.append(sr["id"])
	if candidates.is_empty():
		for id in north:
			if id != kitchen and mini(_rect(b, id).size.x, _rect(b, id).size.y) >= 300:
				candidates.append(id)
	if not candidates.is_empty():
		spaces[candidates[rng.randi() % candidates.size()]]["type"] = "Andron"
	for s in spaces:
		if s["kind"] != "room" or s["type"] != "":
			continue
		var on_street: bool = s["zone"] == "south" and (s["rect"] as Rect2i).end.y == yb
		if on_street and rng.randf() < 0.6:
			s["type"] = "Workroom"
		else:
			s["type"] = ["Domestic room", "Domestic room", "Storage"][rng.randi() % 3]


static func _merge(spans: Array) -> Array:
	spans.sort_custom(func(p, q): return p.x < q.x)
	var out: Array = []
	for s in spans:
		if not out.is_empty() and out[-1].y == s.x:
			out[-1] = Vector2i(out[-1].x, s.y)
		else:
			out.append(s)
	return out


## Removes door gaps from an interior wall line, returning the remaining pieces.
static func _cut(w: Dictionary, openings: Array) -> Array:
	var r: Rect2i = w["rect"]
	var horiz: bool = w["orient"] == "h"
	var gaps: Array = []
	for o in openings:
		var orr: Rect2i = o["rect"]
		if o["kind"] == "door" and r.encloses(orr):
			gaps.append(Vector2i(orr.position.x, orr.end.x) if horiz else Vector2i(orr.position.y, orr.end.y))
	gaps.sort_custom(func(p, q): return p.x < q.x)
	var pieces: Array = []
	var start := r.position.x if horiz else r.position.y
	var stop := r.end.x if horiz else r.end.y
	for g in gaps + [Vector2i(stop, stop)]:
		if g.x > start:
			var piece := Rect2i(start, r.position.y, g.x - start, r.size.y) if horiz \
				else Rect2i(r.position.x, start, r.size.x, g.x - start)
			pieces.append({"rect": piece, "kind": w["kind"], "orient": w["orient"]})
		start = maxi(start, g.y)
	return pieces


## One mitred quad per footprint side between the outer face and the inset
## face; the side holding the entrance is split around the entrance gap.
static func _exterior_walls(fp: PackedVector2Array, entrance: Rect2) -> Array:
	var inner := V.inset_polygon(fp, V.EXT_WALL)
	var out: Array = []
	for i in fp.size():
		var j := (i + 1) % fp.size()
		var p0 := fp[i]
		var p1 := fp[j]
		var orient := "h" if is_equal_approx(p0.y, p1.y) else ("v" if is_equal_approx(p0.x, p1.x) else "d")
		var holds_entrance := orient == "h" and is_equal_approx(p0.y, entrance.end.y) \
			and minf(p0.x, p1.x) <= entrance.position.x and maxf(p0.x, p1.x) >= entrance.end.x
		if not holds_entrance:
			out.append(_poly_wall(PackedVector2Array([p0, p1, inner[j], inner[i]]), orient))
			continue
		# Split at the gap: the piece next to p0 ends at the gap edge nearer p0.
		var near_x := entrance.position.x if p0.x < p1.x else entrance.end.x
		var far_x := entrance.end.x if p0.x < p1.x else entrance.position.x
		var yo := p0.y
		var yi := inner[i].y
		out.append(_poly_wall(PackedVector2Array([p0, Vector2(near_x, yo), Vector2(near_x, yi), inner[i]]), orient))
		out.append(_poly_wall(PackedVector2Array([Vector2(far_x, yo), p1, inner[j], Vector2(far_x, yi)]), orient))
	return out


static func _poly_wall(poly: PackedVector2Array, orient: String) -> Dictionary:
	return {"rect": V._bbox(poly), "poly": poly, "kind": "exterior", "orient": orient}


static func _m(r: Rect2i) -> Rect2:
	return Rect2(r.position.x / 100.0, r.position.y / 100.0, r.size.x / 100.0, r.size.y / 100.0)


static func _emit(d: Dictionary) -> Dictionary:
	var out := d.duplicate()
	out["rect"] = _m(d["rect"])
	return out


# --------------------------------------------------------------------------
# Houses inside city-block plots
# --------------------------------------------------------------------------
# A plot footprint comes from the block subdivision: one horizontal face is a
# party wall on the row line (or both faces are streets in a one-row block),
# the other faces are streets or slanted party walls. The orthogonal layout
# is laid out on the 5 cm grid over the plot's interior polygon and clipped to
# it; only rooms, the pastas and wall ends may be trimmed — never the
# courtyard or a door. Plot kinds:
#   "south"   — party wall on top, street below: wing, pastas, courtyard band,
#               then a street range of rooms with the entrance passage;
#   "north"   — street on top, party wall below: the entrance passage runs
#               through the wing to the pastas; the courtyard backs onto the
#               party wall;
#   "through" — streets above and below (one-row block): like "south" with
#               the wing trimmed by the northern street front.

const PLOT_STRIP_MIN := 250       # clear width of a side strip beside the courtyard, cm
const PLOT_SPLIT_STRIP := 650     # wider side strips hold two rooms side by side
const RANGE_MIN_DEPTH := 220      # street-range rooms at the shallowest point, cm
const WING_MIN_DEPTH := 300       # wing rooms at the shallowest point, cm
const WING_MAX_DEPTH := 800       # deepest wing point; past 5 m the rooms are at most 5 m wide
const RANGE_MAX_DEPTH := 500      # deepest street-range point, same reason
const PLOT_ROOM_MAX := 800        # wing room width when the wing is at most 5 m deep (span = depth)
const FRONT_MARGIN := 30          # keep the entrance clear of the street wall's corners, cm


static func build_in_plot(rng: RandomNumberGenerator, fp: PackedVector2Array, block: PackedVector2Array, kind: String) -> Dictionary:
	var q := V.inset_polygon(fp, V.EXT_WALL)
	if G.polygon_area(q) < 40.0 or signf(G.signed_area(q)) != signf(G.signed_area(fp)):
		return _fail("plot too small for its walls")
	var qb := G.bbox(q)
	var X0 := floori(qb.position.x * 20.0) * 5      # rect extents (cm) covering the interior
	var X1 := ceili(qb.end.x * 20.0) * 5
	var Y0 := floori(qb.position.y * 20.0) * 5
	var Y1 := ceili(qb.end.y * 20.0) * 5
	# Depths are measured under the north-facing and over the south-facing
	# street edges, where the middle rooms stand (not in the corner wedges).
	var mid_top := _facing_range(fp, q, true)
	var mid_bottom := _facing_range(fp, q, false)
	var front := _plot_frontage(fp, q, block, "north" if kind == "north" else "south")
	if front.is_empty():
		return _fail("no straight street frontage on the %s side" % ("north" if kind == "north" else "south"))

	# Band depths (wing, pastas, courtyard) are searched, in random order, for
	# a combination that fits the plot's depth with every band legal.
	var pw := _step(rng, PASSAGE_WIDTH)
	var top_ext := ceili(_top_extreme(q, mid_top) * 100.0 / 5.0) * 5     # shallowest wing top
	var bottom_ext := floori(_bottom_extreme(q, mid_bottom) * 100.0)       # shallowest street-range bottom
	var centre_y := G.bbox(fp).get_center().y * 100.0
	var options: Array = []
	for c in COURTYARD_SIZES:
		for dp_o in range(PASTAS_DEPTH.x, PASTAS_DEPTH.y + 1, 25):
			for dn_o in range(NORTH_DEPTH.x, NORTH_DEPTH.y + 1, 25):
				options.append([c, dp_o, dn_o])
	for i in range(options.size() - 1, 0, -1):   # seeded shuffle (Array.shuffle uses the global RNG)
		var j := rng.randi_range(0, i)
		var tmp = options[i]
		options[i] = options[j]
		options[j] = tmp
	var court := Vector2i.ZERO
	var dp := 0
	var y_w := 0     # wing south face (top of the wing wall)
	var pb := 0      # pastas south face = courtyard top
	var pc := 0      # courtyard band south face
	var fallback: Array = []   # a legal option whose wing is deeper than 5 m
	for o in options + [null]:
		if o == null:
			if fallback.is_empty():
				break
			o = fallback
		var c: Vector2i = o[0]
		if kind == "north":
			pc = roundi(qb.end.y * 100.0)           # party wall on the 5 cm grid
			pb = pc - c.y
			y_w = pb - o[1] - INT
			if y_w - top_ext < WING_MIN_DEPTH or y_w - Y0 > WING_MAX_DEPTH:
				continue
		else:
			var wing_top := roundi(qb.position.y * 100.0) if kind == "south" else top_ext
			y_w = wing_top + o[2]
			pb = y_w + INT + o[1]
			pc = pb + c.y
			if (kind == "through" and y_w - Y0 > WING_MAX_DEPTH) or bottom_ext - (pc + INT) < RANGE_MIN_DEPTH \
					or Y1 - (pc + INT) > RANGE_MAX_DEPTH:
				continue
			if pb + c.y / 2.0 <= centre_y + 5.0:
				continue   # H03: the courtyard must lie in the southern part
		# Prefer wings at most 5 m deep (any room width is then within the span).
		if kind != "south" and y_w - Y0 > 500 and o != fallback:
			if fallback.is_empty():
				fallback = o
			continue
		court = c
		dp = o[1]
		break
	if court == Vector2i.ZERO:
		return _fail("plot depth does not fit wing, pastas, courtyard%s (interior %.1f m deep, street front varies %.1f m)" % [
			"" if kind == "north" else " and street rooms", (Y1 - Y0) / 100.0,
			((y_w - top_ext) if kind == "north" else (Y1 - bottom_ext)) / 100.0 if kind != "north" else (top_ext - Y0) / 100.0])
	var cw := court.x
	var cd := court.y

	# A north-row courtyard backs onto the row line: the plot's lowest face must
	# be that horizontal party wall.
	if kind == "north" and absf(_x_range(q, qb.end.y).y - _x_range(q, qb.end.y).x) < 4.0:
		return _fail("plot's south face is not the row party wall")
	# Courtyard band: side strip | courtyard | side strip, clear of the slanted sides.
	var sc := _span_m(q, pb / 100.0, pc / 100.0)
	if not _usable(sc):
		return _fail("courtyard band leaves the plot")
	var lo := ceili(sc.x * 20.0) * 5 + PLOT_STRIP_MIN + INT
	var hi := floori(sc.y * 20.0) * 5 - PLOT_STRIP_MIN - INT - cw
	if kind != "north":
		# The entrance passage runs south from the courtyard to the street front.
		lo = maxi(lo, front["x0"] + pw + 30 - cw)
		hi = mini(hi, front["x1"] - pw - 30)
	if ceili(lo / 5.0) > floori(hi / 5.0):
		return _fail("plot too narrow for the courtyard and side rooms")
	var cx0 := _step(rng, Vector2i(lo, hi))
	var cx1 := cx0 + cw

	# Northern wing: rooms between full-depth partitions (plus the entrance
	# passage for a north-facing house), end rooms widened over the slanted sides.
	var sw := _span_m(q, (y_w - 200) / 100.0, y_w / 100.0)
	if not _usable(sw):
		return _fail("wing band leaves the plot")
	# Each band's rooms start at that band's own extent, so an end room only
	# carries the wedge its band actually loses to a slanted side.
	var ew := _extent_m(q, qb.position.y, y_w / 100.0)
	var WX0 := floori(ew.x * 20.0) * 5
	var WX1 := ceili(ew.y * 20.0) * 5
	var ec := _extent_m(q, pb / 100.0, pc / 100.0)
	var CX0 := floori(ec.x * 20.0) * 5
	var CX1 := ceili(ec.y * 20.0) * 5
	var er := _extent_m(q, (pc + INT) / 100.0, qb.end.y) if kind != "north" else ec
	var RX0 := floori(er.x * 20.0) * 5
	var RX1 := ceili(er.y * 20.0) * 5
	var extra_w := ceili((sw.x * 100.0 - WX0) / 5.0) * 5 + 5
	var extra_e := ceili((WX1 - sw.y * 100.0) / 5.0) * 5 + 5
	var deep := y_w - Y0
	var shallow_d := y_w - ceili(_top_extreme(q, mid_top) * 100.0) if kind != "south" else y_w - Y0
	# Clear span is the shorter side: up to 5 m deep any width is fine, deeper
	# wings get rooms (end rooms included) at most 5 m wide.
	var room_max := PLOT_ROOM_MAX if deep <= 500 else 500
	var min_w := maxi(NORTH_ROOM_MIN, ceili(ROOM_MIN_AREA / float(maxi(shallow_d, 1)) / 5.0) * 5)

	var b := {"spaces": [], "walls": [], "openings": []}
	var strip_rooms := 0
	var px0 := 0
	var wing_parts: Array = []   # [x0, x1, extra at x0, extra at x1]
	if kind == "north":
		var plo := maxi(front["x0"], WX0 + extra_w + maxi(min_w, extra_w) + INT)
		var phi := mini(front["x1"], WX1 - extra_e - maxi(min_w, extra_e) - INT) - pw
		if ceili(plo / 5.0) > floori(phi / 5.0):
			return _fail("no room for an entrance passage through the wing")
		px0 = _step(rng, Vector2i(plo, phi))
		wing_parts = [[WX0, px0 - INT, extra_w, 0], [px0 + pw + INT, WX1, 0, extra_e]]
	else:
		# The passage splits the street range in two; try positions until both
		# street rooms keep a usable shape against the slanted walls.
		var plo := maxi(cx0 + DOOR_MARGIN, front["x0"])
		var phi := mini(cx1 - DOOR_MARGIN, front["x1"]) - pw
		var tries: Array = []
		for k in 8:
			tries.append(_step(rng, Vector2i(plo, phi)))
		px0 = -1
		var rt0 := pc + INT
		for x in tries:
			var west_room := _clip({"rect": _m(Rect2i(RX0, rt0, x - INT - RX0, Y1 - rt0))}, q)
			var east_room := _clip({"rect": _m(Rect2i(x + pw + INT, rt0, RX1 - x - pw - INT, Y1 - rt0))}, q)
			if _room_shape_ok(west_room) and _room_shape_ok(east_room):
				px0 = x
				break
		if px0 < 0:
			return _fail("street rooms beside the entrance would be slivers")
		wing_parts = [[WX0, WX1, extra_w, extra_e]]

	# Side strips (counted first so the wing can take the remaining room budget).
	var strips: Array = []   # {x0, x1, split, stack, west}
	for west in [true, false]:
		var sx0 := CX0 if west else cx1 + INT
		var sx1 := cx0 - INT if west else CX1
		var clear_w := (cx0 - INT) - ceili(sc.x * 100.0) if west else floori(sc.y * 100.0) - (cx1 + INT)
		var st := {"x0": sx0, "x1": sx1, "west": west, "split": -1, "stack": -1}
		if clear_w > PLOT_SPLIT_STRIP:
			st["split"] = (cx0 - INT - clear_w / 2) / 5 * 5 if west else (cx1 + INT + clear_w / 2) / 5 * 5
			strip_rooms += 2
		elif cd - INT >= 2 * ROOM_MIN + INT and rng.randf() < 0.5:
			st["stack"] = _step(rng, Vector2i(ROOM_MIN, cd - 2 * INT - ROOM_MIN))
			strip_rooms += 2
		else:
			strip_rooms += 1
		strips.append(st)
	var range_rooms := 0 if kind == "north" else 2
	var budget := V.MAX_ROOMS - strip_rooms - range_rooms
	var counts: Array = []
	for part in wing_parts:
		var span_cm: int = part[1] - part[0]
		var fixed: int = part[2] + part[3]
		var n_opts: Array = []
		var lo_sum: int = (maxi(min_w, part[2]) - min_w) + (maxi(min_w, part[3]) - min_w)
		var hi_fixed: int = fixed
		for n in range(1, 6):
			if fixed + lo_sum + n * min_w + INT * (n - 1) <= span_cm and hi_fixed + n * room_max + INT * (n - 1) >= span_cm:
				n_opts.append(n)
		if n_opts.is_empty():
			return _fail("wing width cannot be divided into rooms")
		counts.append(n_opts)
	var chosen: Array = []
	for n_opts in counts:
		chosen.append(n_opts[rng.randi() % n_opts.size()])
	for st in strips:
		# Optional second strip rooms give way first when the room budget is tight.
		if chosen.reduce(func(a, n): return a + n, 0) > budget and (st["split"] > 0 or st["stack"] > 0):
			st["split"] = -1
			st["stack"] = -1
			strip_rooms -= 1
			budget += 1
	while chosen.reduce(func(a, n): return a + n, 0) > budget:
		var reducible := range(chosen.size()).filter(func(k): return counts[k].has(chosen[k] - 1))
		if reducible.is_empty():
			return _fail("too many rooms for this plot")
		chosen[reducible[rng.randi() % reducible.size()]] -= 1
	if chosen.reduce(func(a, n): return a + n, 0) + strip_rooms + range_rooms < V.MIN_ROOMS:
		return _fail("too few rooms for this plot")

	# --- Spaces ---
	var north: Array = []
	for k in wing_parts.size():
		var part: Array = wing_parts[k]
		var n: int = chosen[k]
		var los: Array = []
		var his: Array = []
		for i in n:
			# An end room keeps at least as much straight width as the slanted
			# wall takes away, so it is not a sliver.
			var e: int = (part[2] if i == 0 else 0) + (part[3] if i == n - 1 else 0)
			los.append(maxi(min_w, e) + e)
			his.append(room_max + e)   # the validator measures a trimmed room's real clear span
		# Re-draw the partition (a few times) until the end rooms against the
		# slanted walls keep usable shapes.
		var widths: Array = []
		for attempt in 8:
			widths = _partition(rng, part[1] - part[0] - INT * (n - 1), los, his)
			var first := _clip({"rect": _m(Rect2i(part[0], Y0, widths[0], y_w - Y0))}, q)
			var last := _clip({"rect": _m(Rect2i(part[1] - widths[n - 1], Y0, widths[n - 1], y_w - Y0))}, q)
			if _room_shape_ok(first) and _room_shape_ok(last):
				break
		var x: int = part[0]
		for i in n:
			north.append(_space(b, "room", "north", Rect2i(x, Y0, widths[i], y_w - Y0)))
			if i < n - 1:
				_wall(b, Rect2i(x + widths[i], Y0, INT, y_w - Y0), "v")
			x += widths[i] + INT
	var passage := -1
	if kind == "north":
		passage = _space(b, "passage", "north", Rect2i(px0, Y0, pw, y_w - Y0))
		_wall(b, Rect2i(px0 - INT, Y0, INT, y_w - Y0), "v")
		_wall(b, Rect2i(px0 + pw, Y0, INT, y_w - Y0), "v")
	_wall(b, Rect2i(X0, y_w, X1 - X0, INT), "h")
	var pastas := _space(b, "pastas", "middle", Rect2i(X0, y_w + INT, X1 - X0, dp))
	var court_id := _space(b, "courtyard", "south", Rect2i(cx0, pb, cw, cd))
	_wall(b, Rect2i(cx0 - INT, pb, INT, pc - pb), "v")
	_wall(b, Rect2i(cx1, pb, INT, pc - pb), "v")
	_wall(b, Rect2i(mini(CX0, X0), pb, cx0 - INT - mini(CX0, X0), INT), "h")
	_wall(b, Rect2i(cx1 + INT, pb, maxi(CX1, X1) - cx1 - INT, INT), "h")
	var strip_list: Array = []   # [{id, to: "court"|"pastas"}]
	for st in strips:
		var y0 := pb + INT
		var h := pc - y0
		if st["split"] > 0:
			var sp: int = st["split"]
			var outer := Rect2i(st["x0"], y0, sp - st["x0"], h) if st["west"] else Rect2i(sp + INT, y0, st["x1"] - sp - INT, h)
			var inner := Rect2i(sp + INT, y0, st["x1"] - sp - INT, h) if st["west"] else Rect2i(st["x0"], y0, sp - st["x0"], h)
			_wall(b, Rect2i(sp, y0, INT, h), "v")
			strip_list.append({"id": _space(b, "room", "south", inner), "to": "court", "west": st["west"]})
			strip_list.append({"id": _space(b, "room", "south", outer), "to": "pastas", "west": st["west"]})
		elif st["stack"] > 0:
			var t: int = st["stack"]
			strip_list.append({"id": _space(b, "room", "south", Rect2i(st["x0"], y0, st["x1"] - st["x0"], t)), "to": "court", "west": st["west"]})
			_wall(b, Rect2i(st["x0"], y0 + t, st["x1"] - st["x0"], INT), "h")
			strip_list.append({"id": _space(b, "room", "south", Rect2i(st["x0"], y0 + t + INT, st["x1"] - st["x0"], h - t - INT)), "to": "court", "west": st["west"]})
		else:
			strip_list.append({"id": _space(b, "room", "south", Rect2i(st["x0"], y0, st["x1"] - st["x0"], h)), "to": "court", "west": st["west"]})
	var street_rooms: Array = []
	var rt := pc + INT
	if kind != "north":
		_wall(b, Rect2i(X0, pc, X1 - X0, INT), "h")
		passage = _space(b, "passage", "street", Rect2i(px0, rt, pw, Y1 - rt))
		_wall(b, Rect2i(px0 - INT, rt, INT, Y1 - rt), "v")
		_wall(b, Rect2i(px0 + pw, rt, INT, Y1 - rt), "v")
		street_rooms.append(_space(b, "room", "street", Rect2i(RX0, rt, px0 - INT - RX0, Y1 - rt)))
		street_rooms.append(_space(b, "room", "street", Rect2i(px0 + pw + INT, rt, RX1 - px0 - pw - INT, Y1 - rt)))
	_assign_plot_types(rng, b, north, street_rooms, strip_list.map(func(s): return s["id"]))

	# --- Openings ---
	_opening(b, Rect2i(cx0, pb, cw, 0), "ns", "open", pastas, court_id)
	for id in north:
		var r: Rect2i = _rect(b, id)
		var span := _clear_span(q, r.position.x, r.end.x, y_w, y_w + INT)
		if span.y - span.x < DOOR_WIDTH.y + 2 * DOOR_MARGIN:
			return _fail("no room for a door beside a slanted wall")
		var d := _door_pos(rng, b, id, span.x, span.y)
		_opening(b, Rect2i(d.x, y_w, d.y, INT), "ns", "door", id, pastas)
	for s in strip_list:
		var r: Rect2i = _rect(b, s["id"])
		if s["to"] == "pastas":
			var span := _clear_span(q, r.position.x, r.end.x, pb, pb + INT)
			if span.y - span.x < DOOR_WIDTH.y + 2 * DOOR_MARGIN:
				return _fail("no room for a door beside a slanted wall")
			var d := _door_pos(rng, b, s["id"], span.x, span.y)
			_opening(b, Rect2i(d.x, pb, d.y, INT), "ns", "door", pastas, s["id"])
		else:
			var d := _door_pos(rng, b, s["id"], r.position.y, r.end.y)
			if s["west"]:
				_opening(b, Rect2i(cx0 - INT, d.x, INT, d.y), "ew", "door", s["id"], court_id)
			else:
				_opening(b, Rect2i(cx1, d.x, INT, d.y), "ew", "door", court_id, s["id"])
	var pdw := mini(_step(rng, DOOR_WIDTH), pw - 2 * DOOR_MARGIN)
	if kind == "north":
		_opening(b, Rect2i(px0 + (pw - pdw) / 10 * 5, y_w, pdw, INT), "ns", "door", passage, pastas)
	else:
		var ox0 := maxi(px0, cx0)
		var ox1 := mini(px0 + pw, cx1)
		_opening(b, Rect2i(ox0 + (ox1 - ox0 - pdw) / 10 * 5, pc, pdw, INT), "ns", "door", court_id, passage)
		for k in 2:
			var wx := px0 - INT if k == 0 else px0 + pw
			var bottom := floori(minf(_y_range(q, wx / 100.0).y, _y_range(q, (wx + INT) / 100.0).y) * 100.0)
			var dw := _step(rng, DOOR_WIDTH)
			var top := rt + DOOR_MARGIN
			if bottom - DOOR_MARGIN - dw < top:
				return _fail("street range too shallow for its doors")
			var dy := _step(rng, Vector2i(top, bottom - DOOR_MARGIN - dw))
			if k == 0:
				_opening(b, Rect2i(wx, dy, INT, dw), "ew", "door", street_rooms[0], passage)
			else:
				_opening(b, Rect2i(wx, dy, INT, dw), "ew", "door", passage, street_rooms[1])
	# Street entrance: a gap through the street wall straight in front of the passage.
	var gap_w := floori(mini(120, pw - 2 * DOOR_MARGIN) / 5.0) * 5
	var ex0 := (px0 + (pw - gap_w) / 2) / 100.0
	var ex1 := ex0 + gap_w / 100.0

	# --- Clip to the interior, cut doors, build the exterior band ---
	var spaces: Array = []
	for s in b["spaces"]:
		var clipped := _clip(_emit(s), q)
		if clipped.is_empty() or (clipped.has("poly") and s["kind"] == "courtyard"):
			return _fail("a slanted wall would clip the courtyard")
		spaces.append(clipped)
	var openings: Array = []
	for o in b["openings"]:
		var e := _emit(o)
		if o["kind"] == "door" and V._outside_area(G.rect_poly(e["rect"]), q) > 1e-4:   # Clipper rounding only
			return _fail("a door (%s–%s) would fall outside the interior" % [b["spaces"][o["a"]]["kind"], b["spaces"][o["b"]]["kind"]])
		openings.append(e)
	var walls: Array = []
	for w in b["walls"]:
		for piece in _cut(w, b["openings"]):
			var clipped := _clip(_emit(piece), q)
			if clipped.is_empty():
				return _fail("a wall piece falls outside the interior")
			walls.append(clipped)
	var band := _exterior_walls_cut(fp, q, front["edge"], ex0, ex1)
	if band.is_empty():
		return _fail("entrance gap does not fit the street wall")
	walls.append_array(band["walls"])
	var gap: PackedVector2Array = band["gap"]
	openings.append({"rect": G.bbox(gap), "poly": gap, "axis": "ns", "kind": "entrance", "a": passage, "b": STREET})

	return {
		"footprint": fp,
		"block": block,
		"plot_kind": kind,
		"shape": "%d-sided plot, %s" % [V.count_sides(fp), {"south": "south row", "north": "north row", "through": "through plot"}[kind]],
		"street_side": "north" if kind == "north" else "south",
		"courtyard_dims": Vector2(court) / 100.0,
		"spaces": spaces,
		"walls": walls,
		"openings": openings,
	}


static func _fail(why: String) -> Dictionary:
	_failure = why
	return {}


## The longest footprint edge on the block boundary whose outward side faces
## the given street side; returns {edge, x0, x1} where x0..x1 (cm) is the part
## of its inner face usable for an entrance passage.
static func _plot_frontage(fp: PackedVector2Array, q: PackedVector2Array, block: PackedVector2Array, side: String) -> Dictionary:
	var best := {}
	var best_len := 0.0
	for i in fp.size():
		var a := fp[i]
		var c := fp[(i + 1) % fp.size()]
		if not V._segment_on_boundary(a, c, block):
			continue
		var n := V._outward_normal([a, c], fp)
		if (side == "south" and n.y < 0.5) or (side == "north" and n.y > -0.5):
			continue
		var qa := q[i]
		var qc := q[(i + 1) % q.size()]
		var x0 := ceili(minf(qa.x, qc.x) * 100.0) + FRONT_MARGIN
		var x1 := floori(maxf(qa.x, qc.x) * 100.0) - FRONT_MARGIN
		if a.distance_to(c) >= V.MIN_STREET_FRONTAGE and x1 - x0 > best_len:
			best_len = x1 - x0
			best = {"edge": i, "x0": x0, "x1": x1}
	return best


## Exterior wall band of a plot: one mitred quad per side; the street side
## `edge` is split around the entrance gap x0..x1 (metres).
static func _exterior_walls_cut(fp: PackedVector2Array, q: PackedVector2Array, edge: int, x0: float, x1: float) -> Dictionary:
	var out: Array = []
	var gap := PackedVector2Array()
	for i in fp.size():
		var j := (i + 1) % fp.size()
		var quad := PackedVector2Array([fp[i], fp[j], q[j], q[i]])
		var orient := "h" if is_equal_approx(fp[i].y, fp[j].y) else ("v" if is_equal_approx(fp[i].x, fp[j].x) else "d")
		if i != edge:
			out.append(_poly_wall(quad, orient))
			continue
		for cut in [Rect2(-1e4, -1e4, x0 + 1e4, 2e4), Rect2(x1, -1e4, 1e4, 2e4)]:
			for part in Geometry2D.intersect_polygons(quad, G.rect_poly(cut)):
				out.append(_poly_wall(part, orient))
		var parts := Geometry2D.intersect_polygons(quad, G.rect_poly(Rect2(x0, -1e4, x1 - x0, 2e4)))
		if parts.size() != 1 or parts[0].size() != 4:
			return {}
		gap = parts[0]
	return {"walls": out, "gap": gap}


## Inner x-range [max west, min east] (metres) of polygon q over the band y0..y1.
static func _span_m(q: PackedVector2Array, y0: float, y1: float) -> Vector2:
	# Sampled 0.1 mm inside the band, so a band edge lying on a (float32)
	# horizontal wall never misses the polygon.
	var ys := [y0 + 1e-4, y1 - 1e-4]
	for p in q:
		if p.y > y0 and p.y < y1:
			ys.append(p.y)
	var out := Vector2(-INF, INF)
	for y in ys:
		var xr := _x_range(q, y)
		out = Vector2(maxf(out.x, xr.x), minf(out.y, xr.y))
	return out


## True if a clipped room (or plain rectangle) would pass the H06 shape rules.
static func _room_shape_ok(item: Dictionary) -> bool:
	if item.is_empty():
		return false
	if not item.has("poly"):
		var r: Rect2 = item["rect"]
		return minf(r.size.x, r.size.y) >= V.MIN_ROOM_WIDTH and r.get_area() >= V.MIN_ROOM_AREA
	return V._clipped_shape_problem(item["poly"], item["rect"], true) == "" and G.polygon_area(item["poly"]) >= V.MIN_ROOM_AREA \
		and V._min_width(item["poly"]) <= V.MAX_ROOM_SPAN


static func _usable(span: Vector2) -> bool:
	return is_finite(span.x) and is_finite(span.y) and span.y - span.x > 1.0


## Outer x-range [min west, max east] (metres) of polygon q over the band y0..y1.
static func _extent_m(q: PackedVector2Array, y0: float, y1: float) -> Vector2:
	var ys := [y0 + 1e-4, y1 - 1e-4]
	for p in q:
		if p.y > y0 and p.y < y1:
			ys.append(p.y)
	var out := Vector2(INF, -INF)
	for y in ys:
		var xr := _x_range(q, y)
		if is_finite(xr.x):
			out = Vector2(minf(out.x, xr.x), maxf(out.y, xr.y))
	return out


## [top, bottom] y of polygon q on the vertical line x.
static func _y_range(poly: PackedVector2Array, x: float) -> Vector2:
	var flipped := PackedVector2Array()
	for p in poly:
		flipped.append(Vector2(p.y, p.x))
	return _x_range(flipped, x)


## x-range (metres, 0.5 m in from its ends) of the longest interior edge
## facing north (top) or south, i.e. the inner face of a street or row wall.
static func _facing_range(fp: PackedVector2Array, q: PackedVector2Array, north: bool) -> Vector2:
	var best := Vector2(q[0].x, q[0].x)
	for i in fp.size():
		var n := V._outward_normal([fp[i], fp[(i + 1) % fp.size()]], fp)
		if (north and n.y < -0.5) or (not north and n.y > 0.5):
			var a := q[i].x
			var c := q[(i + 1) % q.size()].x
			if absf(c - a) > best.y - best.x:
				best = Vector2(minf(a, c), maxf(a, c))
	return Vector2(best.x + 0.5, best.y - 0.5) if best.y - best.x > 1.0 else best


## Lowest point (largest y) of q's top boundary over x-range xr.
static func _top_extreme(q: PackedVector2Array, xr: Vector2) -> float:
	var out := -INF
	for x in _sample_xs(q, xr):
		out = maxf(out, _y_range(q, x).x)
	return out


## Highest point (smallest y) of q's bottom boundary over x-range xr.
static func _bottom_extreme(q: PackedVector2Array, xr: Vector2) -> float:
	var out := INF
	for x in _sample_xs(q, xr):
		out = minf(out, _y_range(q, x).y)
	return out


static func _sample_xs(q: PackedVector2Array, xr: Vector2) -> Array:
	var xs := [xr.x, xr.y]
	for p in q:
		if p.x > xr.x and p.x < xr.y:
			xs.append(p.x)
	return xs


static func _assign_plot_types(rng: RandomNumberGenerator, b: Dictionary, wing: Array, street: Array, strips: Array) -> void:
	var spaces: Array = b["spaces"]
	var kitchen: int = wing[0]
	for id in wing:
		if _rect(b, id).size.x > _rect(b, kitchen).size.x:
			kitchen = id
	spaces[kitchen]["type"] = "Kitchen / hearth"
	# Andron near the street (Olynthos), else beside the courtyard.
	var candidates: Array = (street if not street.is_empty() else strips).filter(func(id): return mini(_rect(b, id).size.x, _rect(b, id).size.y) >= 300)
	if not candidates.is_empty():
		spaces[candidates[rng.randi() % candidates.size()]]["type"] = "Andron"
	for id in street:
		if spaces[id]["type"] == "":
			spaces[id]["type"] = "Workroom"
	for s in spaces:
		if s["kind"] == "room" and s["type"] == "":
			s["type"] = ["Domestic room", "Domestic room", "Storage"][rng.randi() % 3]
