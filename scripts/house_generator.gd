extends RefCounted
## Constraint-based constructor for Classical Greek pastas houses.
##
## The plan is built top-down from the rules instead of placing random
## rectangles: a northern wing of rooms, a full-width pastas below it, and a
## southern zone of vertical strips (courtyard, entrance passage, side rooms).
## The exterior footprint has 4, 5 or 6 sides:
##   4 — rectangle;
##   5 — rectangle with one southern corner clipped (one slanted side) over a
##       side room, away from the wing, courtyard and entrance;
##   6 — L-shape: a rectangular notch cut from one southern corner under a
##       side room, so the other side of the house forms the extension.
## Every candidate is then checked by house_validator.gd; only a house that
## passes all hard rules H00–H10 is ever returned as valid.
##
## Construction runs on an integer centimetre grid (5 cm steps) so shared
## edges are exact; geometry is converted to metres when emitted. Only the
## slanted side of a 5-sided footprint lies off the grid.

const V := preload("res://scripts/house_validator.gd")

const STREET := V.STREET
const MAX_ATTEMPTS := 10
const SIDE_COUNTS := [4, 5, 6]
const SHAPE_NAMES := {4: "rectangle", 5: "clipped corner", 6: "L-shape"}

const EXT := 50   # exterior wall thickness, cm (V.EXT_WALL)
const INT := 25   # interior wall thickness, cm (V.INT_WALL)
const COURTYARD_SIZES := [Vector2i(400, 400), Vector2i(320, 500), Vector2i(500, 320)]  # all exactly 16 m²
const NORTH_DEPTH := Vector2i(300, 450)
const PASTAS_DEPTH := Vector2i(150, 250)
const PASSAGE_WIDTH := Vector2i(120, 160)
const SIDE_COL_WIDTH := Vector2i(250, 450)
const NORTH_ROOM_MIN := 250
const NORTH_ROOM_MAX := 600
const ROOM_MIN := 200            # V.MIN_ROOM_WIDTH
const ROOM_MIN_AREA := 50000     # cm², V.MIN_ROOM_AREA
const DOOR_WIDTH := Vector2i(90, 120)
const DOOR_MARGIN := 15          # keeps door jambs clear of wall junctions
const NOTCH_MIN := 100           # smallest L-notch depth, cm
const CLIP_MIN := 75             # smallest clipped-corner leg on the room, cm


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
			rejections.append("attempt %d: rooms could not be fitted within the rules" % (attempt + 1))
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
	# 1–2. Courtyard of exactly 16 m² and the depths of the northern bands.
	# An L-notch needs >= 4 m of courtyard depth beside it, so 6-sided houses
	# use the 4×4 or 3.2×5 courtyard.
	var court: Vector2i = COURTYARD_SIZES[rng.randi() % (2 if sides == 6 else COURTYARD_SIZES.size())]
	var dn := _step(rng, NORTH_DEPTH)
	var dp := _step(rng, PASTAS_DEPTH)

	# 3. Southern zone as west-to-east strips; the courtyard spans its full depth.
	var cols: Array = []
	var has_west := rng.randf() < 0.75
	var has_east := rng.randf() < 0.75
	if not has_west and not has_east:
		if rng.randf() < 0.5:
			has_west = true
		else:
			has_east = true
	if has_west:
		cols.append({"kind": "side", "w": _step(rng, SIDE_COL_WIDTH), "west": true})
	var core := [{"kind": "passage", "w": _step(rng, PASSAGE_WIDTH)}, {"kind": "courtyard", "w": court.x}]
	if rng.randf() < 0.5:
		core.reverse()
	cols.append_array(core)
	if has_east:
		cols.append({"kind": "side", "w": _step(rng, SIDE_COL_WIDTH), "west": false})

	var wi := INT * (cols.size() - 1)   # clear interior width
	for c in cols:
		wi += c["w"]
	var pb := EXT + dn + INT + dp       # pastas bottom = courtyard top
	var yb := pb + court.y              # interior south face
	var width := wi + 2 * EXT
	var depth := yb + EXT

	# The irregular corner (5/6 sides) goes under a side strip, never under the
	# northern wing, the courtyard or the entrance passage.
	var side_cols := cols.filter(func(c): return c["kind"] == "side")
	var feature: Dictionary = side_cols[rng.randi() % side_cols.size()] if sides != 4 else {}
	var clear: int = court.y - INT
	var notch := 0
	if sides == 6:
		notch = _step(rng, Vector2i(NOTCH_MIN, clear - INT - ROOM_MIN))
		feature["notch"] = notch

	# Side strips hold one room, or two stacked rooms when the depth allows.
	var south_rooms := 0
	for c in cols:
		if c["kind"] != "side":
			continue
		c["split"] = -1
		if not c.has("notch") and clear >= 2 * ROOM_MIN + INT and rng.randf() < 0.6:
			var top := _step(rng, Vector2i(ROOM_MIN, clear - INT - ROOM_MIN))
			if c["w"] * top >= ROOM_MIN_AREA and c["w"] * (clear - INT - top) >= ROOM_MIN_AREA:
				c["split"] = top
		south_rooms += 2 if c["split"] > 0 else 1

	# 4. Northern wing: choose a room count that fits, lowering it if needed.
	var min_w := maxi(NORTH_ROOM_MIN, ceili(ROOM_MIN_AREA / float(dn) / 5.0) * 5)
	var max_fit := floori((wi + INT) / float(min_w + INT))
	var min_fit := ceili((wi + INT) / float(NORTH_ROOM_MAX + INT))
	var lo := maxi(maxi(2, min_fit), V.MIN_ROOMS - south_rooms)
	var hi := mini(max_fit, V.MAX_ROOMS - south_rooms)
	if lo > hi:
		return {}
	var n := clampi(rng.randi_range(V.MIN_ROOMS, V.MAX_ROOMS) - south_rooms, lo, hi)
	var widths := _partition(rng, wi - INT * (n - 1), n, min_w, NORTH_ROOM_MAX)

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

	# 5. Pastas across the full width, open to the courtyard below.
	var pastas := _space(b, "pastas", "middle", Rect2i(EXT, EXT + dn + INT, wi, dp))

	# 6. Southern strips.
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
				var bottom: int = yb - c.get("notch", 0)   # a notch raises the strip's south face
				if c["split"] > 0:
					var top: int = c["split"]
					side_rooms.append({"id": _space(b, "room", "south", Rect2i(x0, pb + INT, c["w"], top)), "col": c, "top": true})
					_wall(b, Rect2i(x0, pb + INT + top, c["w"], INT), "h")
					side_rooms.append({"id": _space(b, "room", "south", Rect2i(x0, pb + 2 * INT + top, c["w"], bottom - pb - 2 * INT - top)), "col": c, "top": false})
				else:
					side_rooms.append({"id": _space(b, "room", "south", Rect2i(x0, pb + INT, c["w"], bottom - pb - INT)), "col": c, "top": false})

	# Walls between strips; those flanking the courtyard rise to the pastas
	# line, and one beside an L-notch stops at the notch's exterior wall.
	var ew_spans: Array = []   # x-intervals of the wall along the pastas' south edge
	for i in cols.size():
		if cols[i]["kind"] != "courtyard":
			ew_spans.append(Vector2i(cols[i]["x0"], cols[i]["x0"] + cols[i]["w"]))
		if i == cols.size() - 1:
			continue
		var wx: int = cols[i]["x0"] + cols[i]["w"]
		var by_court: bool = cols[i]["kind"] == "courtyard" or cols[i + 1]["kind"] == "courtyard"
		var y0 := pb if by_court else pb + INT
		var y1: int = yb - cols[i].get("notch", 0) - cols[i + 1].get("notch", 0)
		_wall(b, Rect2i(wx, y0, INT, y1 - y0), "v")
		if not by_court:
			ew_spans.append(Vector2i(wx, wx + INT))
	for span in _merge(ew_spans):
		_wall(b, Rect2i(span.x, pb, span.y - span.x, INT), "h")

	# 2. Exterior polygon (metres), traced clockwise on screen from the NW corner.
	var W := width / 100.0
	var D := depth / 100.0
	var fp := PackedVector2Array([Vector2(0, 0), Vector2(W, 0), Vector2(W, D), Vector2(0, D)])
	if sides == 5:
		# Clip the outer corner of the strip's southernmost room. `t` is the
		# leg cut from the room; the outer leg is longer by the wall's offset.
		var corner: Dictionary = side_rooms.filter(func(sr): return sr["col"] == feature and not sr["top"])[0]
		var rr := _rect(b, corner["id"])
		var t_max := mini(mini(rr.size.x, rr.size.y) / 2, floori(sqrt(2.0 * (rr.get_area() - ROOM_MIN_AREA)) / 5.0) * 5)
		if t_max < CLIP_MIN:
			return {}
		var t := _step(rng, Vector2i(CLIP_MIN, t_max))
		var c := (t + EXT * (2.0 - sqrt(2.0))) / 100.0
		var room_poly: PackedVector2Array
		if feature["west"]:
			fp = PackedVector2Array([Vector2(0, 0), Vector2(W, 0), Vector2(W, D), Vector2(c, D), Vector2(0, D - c)])
			room_poly = _pts([rr.position, Vector2i(rr.end.x, rr.position.y), rr.end, Vector2i(rr.position.x + t, rr.end.y), Vector2i(rr.position.x, rr.end.y - t)])
		else:
			fp = PackedVector2Array([Vector2(0, 0), Vector2(W, 0), Vector2(W, D - c), Vector2(W - c, D), Vector2(0, D)])
			room_poly = _pts([rr.position, Vector2i(rr.end.x, rr.position.y), Vector2i(rr.end.x, rr.end.y - t), Vector2i(rr.end.x - t, rr.end.y), Vector2i(rr.position.x, rr.end.y)])
		b["spaces"][corner["id"]]["poly"] = room_poly
	elif sides == 6:
		# Notch outer corner sits half an exterior wall beyond the strip wall,
		# so the courtyard/passage face stays straight along the step.
		var ys := (depth - notch) / 100.0
		if feature["west"]:
			var xn: float = (feature["x0"] + feature["w"] + INT - EXT) / 100.0
			fp = PackedVector2Array([Vector2(0, 0), Vector2(W, 0), Vector2(W, D), Vector2(xn, D), Vector2(xn, ys), Vector2(0, ys)])
		else:
			var xn: float = (feature["x0"] - INT + EXT) / 100.0
			fp = PackedVector2Array([Vector2(0, 0), Vector2(W, 0), Vector2(W, ys), Vector2(xn, ys), Vector2(xn, D), Vector2(0, D)])

	# Room functions (needed before doors: the andron door is off-centre).
	_assign_types(rng, b, north, side_rooms, yb)

	# 8. Openings.
	var court_col: Dictionary = cols.filter(func(c): return c["kind"] == "courtyard")[0]
	var passage_col: Dictionary = cols.filter(func(c): return c["kind"] == "passage")[0]
	_opening(b, Rect2i(court_col["x0"], pb, court_col["w"], 0), "ns", "open", pastas, court_id)
	for id in north:
		var r: Rect2i = _rect(b, id)
		var d := _door_pos(rng, b, id, r.position.x, r.end.x)
		_opening(b, Rect2i(d.x, EXT + dn, d.y, INT), "ns", "door", id, pastas)
	for sr in side_rooms:
		var r: Rect2i = _rect(b, sr["id"])
		var col: Dictionary = sr["col"]
		if sr["top"] and rng.randf() < 0.5:
			var d := _door_pos(rng, b, sr["id"], r.position.x, r.end.x)
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
	# 7. Street entrance through the south wall into the passage.
	var ew := floori(mini(120, pr.size.x - 2 * DOOR_MARGIN) / 5.0) * 5
	var entrance := Rect2i(pr.position.x + floori((pr.size.x - ew) / 10.0) * 5, yb, ew, EXT)
	_opening(b, entrance, "ns", "entrance", passage_id, STREET)

	# 9. Interior wall lines lose their door gaps; the exterior wall band is
	# one mitred quad per footprint side, with the entrance cut from its side.
	var walls: Array = []
	for w in b["walls"]:
		for piece in _cut(w, b["openings"]):
			walls.append(_emit(piece))
	walls.append_array(_exterior_walls(fp, _m(entrance)))

	return {
		"footprint": fp,
		"shape": SHAPE_NAMES[sides],
		"street_side": "south",
		"courtyard_dims": Vector2(court) / 100.0,
		"spaces": b["spaces"].map(func(s): return _emit(s)),
		"walls": walls,
		"openings": b["openings"].map(func(o): return _emit(o)),
	}


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


## Splits `total` cm into n widths in [lo, hi], on the 5 cm grid.
static func _partition(rng: RandomNumberGenerator, total: int, n: int, lo: int, hi: int) -> Array:
	var widths: Array = []
	var weights: Array = []
	for i in n:
		widths.append(lo)
		weights.append(rng.randf_range(0.3, 1.0))
	for chunk in floori((total - n * lo) / 5.0):
		var sum := 0.0
		for i in n:
			if widths[i] < hi:
				sum += weights[i]
		var pick := rng.randf() * sum
		for i in n:
			if widths[i] >= hi:
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
		if r.end.y == yb and mini(r.size.x, r.size.y) >= 300 and not spaces[sr["id"]].has("poly"):
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


static func _pts(cm: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in cm:
		out.append(Vector2(p) / 100.0)
	return out


static func _m(r: Rect2i) -> Rect2:
	return Rect2(r.position.x / 100.0, r.position.y / 100.0, r.size.x / 100.0, r.size.y / 100.0)


static func _emit(d: Dictionary) -> Dictionary:
	var out := d.duplicate()
	out["rect"] = _m(d["rect"])
	return out
