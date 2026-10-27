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
## passes all hard rules H00–H11 is ever returned as valid.
##
## The layout runs on an integer centimetre grid (5 cm steps) so shared edges
## are exact; geometry is converted to metres when emitted. Only the slanted
## exterior sides and the clipped ends lie off the grid.

const V := preload("res://scripts/house_validator.gd")

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
		if absf(a.y - b.y) < 1e-9:
			if absf(a.y - y) < 1e-9:
				lo = minf(lo, minf(a.x, b.x))
				hi = maxf(hi, maxf(a.x, b.x))
		elif (a.y - y) * (b.y - y) <= 0.0:
			var xi := a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y)
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
