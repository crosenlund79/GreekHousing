extends RefCounted
## Hard-rule validator for generated house data (rules H00–H10).
##
## Works only on the structured house Dictionary produced by house_generator.gd
## (or built by hand in tests). It never looks at rendering, and it derives
## every checked quantity (side count, areas, wing orientation, access) from
## the geometry itself rather than from descriptive metadata.
## A house is valid only when validate_house() returns valid == true.
##
## Coordinates are metres: X grows east, Y grows south, north is up.
##
## House data layout:
##   footprint:   PackedVector2Array  outer face of the exterior walls (closed implicitly)
##   street_side: String  "north" | "south" | "east" | "west"
##   spaces:   [{id:int, kind:"room"|"courtyard"|"pastas"|"passage", type:String, rect:Rect2, [poly]}]
##   walls:    [{rect:Rect2, kind:"exterior"|"interior", orient:"h"|"v"|"d", [poly]}]   ("h" = runs east–west)
##   openings: [{rect:Rect2, axis:"ns"|"ew", kind:"door"|"entrance"|"open", a:int, b:int}]
##             axis is the direction of travel through the opening; b == STREET for the entrance.
## `rect` is the exact shape unless `poly` is given, in which case `rect` is its
## bounding box and `poly` the exact shape (clipped rooms, mitred exterior walls).

# --- Configurable prototype dimensions (project assumptions, not historical norms) ---
const EXT_WALL := 0.50
const INT_WALL := 0.25
const MIN_ROOM_WIDTH := 2.0
const MIN_ROOM_AREA := 5.0
const MAX_ROOM_SPAN := 5.0
const MIN_DOOR_WIDTH := 0.80
const MIN_PASSAGE_WIDTH := 1.0
const COURTYARD_AREA := 16.0
const COURTYARD_AREA_TOL := 0.001
const PASTAS_MIN_DEPTH := 1.5
const PASTAS_MAX_DEPTH := 2.5
const MIN_ROOMS := 4
const MAX_ROOMS := 9
const MIN_SIDES := 4
const MAX_SIDES := 6
const MIN_CLIPPED_ROOM_FILL := 0.75   # a clipped room keeps >= 75 % of its bounding box
const ROOM_TYPES := ["Domestic room", "Storage", "Kitchen / hearth", "Andron", "Workroom"]

const STREET := -1
const EPS := 0.001        # 1 mm positional tolerance
const TILE_TOL := 0.01    # m² tolerance for tiling / containment checks


static func validate_house(house: Dictionary) -> Dictionary:
	var errors: Array = []
	if not _check_structure(house, errors):
		return {"valid": false, "errors": errors, "sides": 0}
	var sides := _check_h00(house["footprint"], errors)
	if not errors.is_empty():
		errors.append("H00: remaining rules not evaluated on an invalid footprint")
		return {"valid": false, "errors": errors, "sides": sides}
	var ctx := _build_context(house, errors)
	_check_h01(house, ctx, errors)
	_check_h02(house, ctx, errors)
	_check_h03(house, ctx, errors)
	_check_h04(house, ctx, errors)
	_check_h05(house, ctx, errors)
	_check_h06(house, ctx, errors)
	_check_h07(house, ctx, errors)
	_check_h08(house, ctx, errors)
	_check_h09(house, ctx, errors)
	_check_h10(house, ctx, errors)
	return {"valid": errors.is_empty(), "errors": errors, "sides": sides}


## Number of genuine sides of a polygon: vertices whose two edges are not
## collinear. Used by H00 and by tests; it never trusts stored metadata.
static func count_sides(poly: PackedVector2Array) -> int:
	var n := 0
	for i in poly.size():
		var e0 := poly[i] - poly[i - 1]
		var e1 := poly[(i + 1) % poly.size()] - poly[i]
		if e0.length() > EPS and e1.length() > EPS and absf(e0.normalized().cross(e1.normalized())) > 1e-6:
			n += 1
	return n


## Polygon shrunk by distance d (simple polygons whose inset keeps the same
## topology, which holds for the footprints used here). Each edge is moved
## inward by d and consecutive offset lines are intersected (mitred corners).
static func inset_polygon(poly: PackedVector2Array, d: float) -> PackedVector2Array:
	var side := 1.0 if _signed_area(poly) > 0.0 else -1.0
	var n := poly.size()
	var out := PackedVector2Array()
	for i in n:
		var p0 := poly[i - 1]
		var p1 := poly[i]
		var p2 := poly[(i + 1) % n]
		var u0 := (p1 - p0).normalized()
		var u1 := (p2 - p1).normalized()
		var n0 := Vector2(-u0.y, u0.x) * side
		var n1 := Vector2(-u1.y, u1.x) * side
		var hit = Geometry2D.line_intersects_line(p0 + n0 * d, u0, p1 + n1 * d, u1)
		out.append(hit if hit != null else p1 + n1 * d)
	return out


# --------------------------------------------------------------------------
# Structure and shared context
# --------------------------------------------------------------------------

static func _check_structure(house: Dictionary, errors: Array) -> bool:
	for key in ["footprint", "street_side", "spaces", "walls", "openings"]:
		if not house.has(key):
			errors.append("H05: malformed house data, missing '%s'" % key)
	if not errors.is_empty():
		return false
	if typeof(house["footprint"]) != TYPE_PACKED_VECTOR2_ARRAY:
		errors.append("H00: footprint must be a PackedVector2Array polygon")
		return false
	for s in house["spaces"]:
		if not (s is Dictionary and s.has("id") and s.has("kind") and s.has("rect") and typeof(s["rect"]) == TYPE_RECT2):
			errors.append("H05: malformed space entry")
			return false
	for w in house["walls"]:
		if not (w is Dictionary and w.has("kind") and w.has("orient") and w.has("rect") and typeof(w["rect"]) == TYPE_RECT2):
			errors.append("H05: malformed wall entry")
			return false
	for o in house["openings"]:
		if not (o is Dictionary and o.has("axis") and o.has("kind") and o.has("a") and o.has("b") and o.has("rect") and typeof(o["rect"]) == TYPE_RECT2):
			errors.append("H05: malformed opening entry")
			return false
	return true


## Collects spaces by kind, derives the interior (footprint minus the exterior
## wall band), the northern wing, and the physically real openings. Only
## geometrically verified openings become edges of the circulation graph.
static func _build_context(house: Dictionary, errors: Array) -> Dictionary:
	var fp: PackedVector2Array = house["footprint"]
	var ctx := {
		"by_id": {}, "rooms": [], "courtyards": [], "pastas": [], "passages": [],
		"edges": [],          # [{a, b, kind, index}] for verified openings only
		"footprint": fp,
		"bounds": _bbox(fp),
		"interior": inset_polygon(fp, EXT_WALL),
	}
	for s in house["spaces"]:
		if ctx["by_id"].has(s["id"]):
			errors.append("H05: duplicate space id %d" % s["id"])
		ctx["by_id"][s["id"]] = s
		match s["kind"]:
			"room": ctx["rooms"].append(s)
			"courtyard": ctx["courtyards"].append(s)
			"pastas": ctx["pastas"].append(s)
			"passage": ctx["passages"].append(s)
			_: errors.append("H05: space %d has unknown kind '%s'" % [s["id"], s["kind"]])
	# Northern wing = every room lying wholly north of the pastas; its extent
	# is the bounding box of those rooms (derived, never read from metadata).
	ctx["north_rooms"] = []
	if ctx["pastas"].size() == 1:
		var top: float = (ctx["pastas"][0]["rect"] as Rect2).position.y
		ctx["north_rooms"] = ctx["rooms"].filter(func(r): return (r["rect"] as Rect2).end.y <= top + EPS)
	var wing := Rect2()
	for i in ctx["north_rooms"].size():
		var rr: Rect2 = ctx["north_rooms"][i]["rect"]
		wing = rr if i == 0 else wing.merge(rr)
	ctx["wing"] = wing
	var openings: Array = house["openings"]
	for i in openings.size():
		var op: Dictionary = openings[i]
		var problem := _opening_problem(op, ctx)
		if problem == "":
			ctx["edges"].append({"a": op["a"], "b": op["b"], "kind": op["kind"], "index": i})
		else:
			errors.append("H07: opening %d (%s, %s) is not a real traversable opening: %s"
				% [i, _name(op["a"], ctx), _name(op["b"], ctx), problem])
	return ctx


## Returns "" when the opening lies exactly on a shared boundary of its two
## spaces (or of a space and the street), with the right thickness and width.
static func _opening_problem(op: Dictionary, ctx: Dictionary) -> String:
	var r: Rect2 = op["rect"]
	var axis: String = op["axis"]
	var kind: String = op["kind"]
	if axis != "ns" and axis != "ew":
		return "unknown axis '%s'" % axis
	var thickness := r.size.y if axis == "ns" else r.size.x
	var width := r.size.x if axis == "ns" else r.size.y
	var expected := {"open": 0.0, "door": INT_WALL, "entrance": EXT_WALL}
	if not expected.has(kind):
		return "unknown opening kind '%s'" % kind
	if absf(thickness - expected[kind]) > EPS:
		return "thickness %.2f m does not match its wall (%.2f m)" % [thickness, expected[kind]]
	if width < MIN_DOOR_WIDTH - EPS:
		return "clear width %.2f m is below %.2f m" % [width, MIN_DOOR_WIDTH]
	if op["a"] == op["b"]:
		return "connects a space to itself"
	var to_street: bool = op["a"] == STREET or op["b"] == STREET
	if (kind == "entrance") != to_street:
		return "only an entrance may (and must) connect to the street"
	if not (_side_ok(r, axis, op["a"], true, ctx) and _side_ok(r, axis, op["b"], false, ctx)) \
			and not (_side_ok(r, axis, op["b"], true, ctx) and _side_ok(r, axis, op["a"], false, ctx)):
		return "does not sit on a boundary shared by its two spaces (floating or opening into a wall)"
	return ""


## Checks that space `id` (or the street) lies against the low (north/west) or
## high (south/east) face of the opening along its whole width.
static func _side_ok(r: Rect2, axis: String, id: int, low_side: bool, ctx: Dictionary) -> bool:
	var face := _face(r, axis, low_side)
	if id == STREET:
		# The outer face must lie on an edge of the actual footprint polygon.
		return _segment_on_boundary(face[0], face[1], ctx["footprint"])
	if not ctx["by_id"].has(id):
		return false
	var space: Dictionary = ctx["by_id"][id]
	var s: Rect2 = space["rect"]
	var ok := false
	if axis == "ns":
		var flush := _near(s.end.y, r.position.y) if low_side else _near(s.position.y, r.end.y)
		ok = flush and s.position.x <= r.position.x + EPS and s.end.x >= r.end.x - EPS
	else:
		var flush_x := _near(s.end.x, r.position.x) if low_side else _near(s.position.x, r.end.x)
		ok = flush_x and s.position.y <= r.position.y + EPS and s.end.y >= r.end.y - EPS
	if ok and space.has("poly"):
		ok = _segment_on_boundary(face[0], face[1], space["poly"])
	return ok


## The face of an opening rectangle that touches the low or high side space.
static func _face(r: Rect2, axis: String, low_side: bool) -> Array:
	if axis == "ns":
		var y := r.position.y if low_side else r.end.y
		return [Vector2(r.position.x, y), Vector2(r.end.x, y)]
	var x := r.position.x if low_side else r.end.x
	return [Vector2(x, r.position.y), Vector2(x, r.end.y)]


# --------------------------------------------------------------------------
# H00 — Exterior footprint: simple closed polygon with 4, 5 or 6 sides
# --------------------------------------------------------------------------

static func _check_h00(poly: PackedVector2Array, errors: Array) -> int:
	var n := poly.size()
	if n < 3:
		errors.append("H00: footprint has %d vertices; not a closed polygon" % n)
		return 0
	var sides := count_sides(poly)
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		if a.distance_to(b) <= EPS:
			errors.append("H00: footprint edge %d has zero length (duplicate or repeated closing vertex)" % i)
			continue
		var prev := poly[i - 1]
		if prev.distance_to(a) > EPS and absf((a - prev).normalized().cross((b - a).normalized())) <= 1e-6:
			errors.append("H00: footprint vertex %d joins collinear edges (redundant side)" % i)
	if absf(_signed_area(poly)) <= TILE_TOL:
		errors.append("H00: footprint has no positive area")
	for i in n:
		for j in range(i + 1, n):
			if j == i + 1 or (i == 0 and j == n - 1):
				continue   # adjacent edges share a vertex
			if Geometry2D.segment_intersects_segment(poly[i], poly[(i + 1) % n], poly[j], poly[(j + 1) % n]) != null:
				errors.append("H00: footprint edges %d and %d intersect (not a simple polygon)" % [i, j])
	if sides < MIN_SIDES or sides > MAX_SIDES:
		errors.append("H00: footprint has %d sides (required %d–%d)" % [sides, MIN_SIDES, MAX_SIDES])
	return sides


# --------------------------------------------------------------------------
# H01 — Courtyard area: exactly one open courtyard of 16.0 m² clear area
# --------------------------------------------------------------------------

static func _check_h01(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var courts: Array = ctx["courtyards"]
	if courts.size() != 1:
		errors.append("H01: expected exactly one courtyard, found %d" % courts.size())
		return
	var court: Dictionary = courts[0]
	var c: Rect2 = court["rect"]
	if c.size.x <= 0.0 or c.size.y <= 0.0:
		errors.append("H01: courtyard has non-positive dimensions")
		return
	var area := _area(court)
	if absf(area - COURTYARD_AREA) > COURTYARD_AREA_TOL:
		errors.append("H01: Courtyard area incorrect (%.3f m², required %.3f m²)" % [area, COURTYARD_AREA])
	if _outside_area(_shape(court), ctx["interior"]) > TILE_TOL:
		errors.append("H01: courtyard is not contained in the interior of the footprint")
	for s in house["spaces"]:
		if s["id"] != court["id"] and _items_overlap(court, s):
			errors.append("H01: courtyard overlaps %s" % _name(s["id"], ctx))
	for w in house["walls"]:
		if _items_overlap(court, w):
			errors.append("H01: courtyard is obstructed by a wall")
			break


# --------------------------------------------------------------------------
# H02 — Principal northern wing, oriented east–west, north of the pastas
# --------------------------------------------------------------------------

static func _check_h02(_house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	if ctx["pastas"].size() != 1:
		errors.append("H02: northern wing cannot be located without a single pastas")
		return
	var north: Array = ctx["north_rooms"]
	if north.is_empty():
		errors.append("H02: no northern wing (no rooms north of the pastas)")
		return
	var nw: Rect2 = ctx["wing"]
	var p: Rect2 = ctx["pastas"][0]["rect"]
	if not (nw.size.x > nw.size.y + EPS):
		errors.append("H02: northern wing is not oriented east–west (width %.2f m <= depth %.2f m)" % [nw.size.x, nw.size.y])
	if nw.end.y > p.position.y + EPS:
		errors.append("H02: northern wing bottom (%.2f) lies south of pastas top (%.2f)" % [nw.end.y, p.position.y])
	if ctx["courtyards"].size() == 1:
		var c: Rect2 = ctx["courtyards"][0]["rect"]
		if nw.end.y > c.position.y + EPS:
			errors.append("H02: northern wing is not north of the courtyard")
	if _outside_area(_rect_poly(nw), ctx["interior"]) > TILE_TOL:
		errors.append("H02: northern wing lies outside the footprint interior")
	var linked := false
	for r in north:
		linked = linked or _has_edge(ctx, r["id"], ctx["pastas"][0]["id"])
	if not linked:
		errors.append("H02: northern wing has no functional connection to the courtyard via the pastas")


# --------------------------------------------------------------------------
# H03 — Courtyard in the central/southern part, adjacent to the pastas
# --------------------------------------------------------------------------

static func _check_h03(_house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	if ctx["courtyards"].size() != 1:
		return  # reported by H01
	var c: Rect2 = ctx["courtyards"][0]["rect"]
	var mid: float = (ctx["bounds"] as Rect2).get_center().y
	if not (c.get_center().y > mid + EPS):
		errors.append("H03: courtyard centre (y=%.2f) is not south of the footprint midpoint (y=%.2f)" % [c.get_center().y, mid])
	if ctx["pastas"].size() == 1:
		var p: Rect2 = ctx["pastas"][0]["rect"]
		var adjacent := _near(p.end.y, c.position.y) and p.position.x <= c.position.x + EPS and p.end.x >= c.end.x - EPS
		if not adjacent:
			errors.append("H03: courtyard is not directly adjacent to the pastas along its northern edge")


# --------------------------------------------------------------------------
# H04 — Pastas: covered E–W portico between courtyard and northern rooms
# --------------------------------------------------------------------------

static func _check_h04(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	if ctx["pastas"].size() != 1:
		errors.append("H04: expected exactly one pastas, found %d" % ctx["pastas"].size())
		return
	var p: Rect2 = ctx["pastas"][0]["rect"]
	var pid: int = ctx["pastas"][0]["id"]
	if ctx["pastas"][0].has("poly"):
		errors.append("H04: pastas must be a rectangular portico")
	if p.size.y < PASTAS_MIN_DEPTH - EPS or p.size.y > PASTAS_MAX_DEPTH + EPS:
		errors.append("H04: pastas depth %.2f m outside %.1f–%.1f m" % [p.size.y, PASTAS_MIN_DEPTH, PASTAS_MAX_DEPTH])
	if not (p.size.x > p.size.y + EPS):
		errors.append("H04: pastas does not extend along an east–west axis")
	if ctx["courtyards"].size() != 1:
		return
	var c: Rect2 = ctx["courtyards"][0]["rect"]
	var cid: int = ctx["courtyards"][0]["id"]
	if not _near(p.end.y, c.position.y):
		errors.append("H04: pastas does not lie directly north of the courtyard")
	# A continuous passable opening on the shared pastas/courtyard boundary.
	var open_found := false
	for e in ctx["edges"]:
		if (e["a"] == pid and e["b"] == cid) or (e["a"] == cid and e["b"] == pid):
			open_found = true
			var seg: Rect2 = house["openings"][e["index"]]["rect"]
			for w in house["walls"]:
				var wr: Rect2 = w["rect"]
				if _span(wr.position.x, wr.end.x, seg.position.x, seg.end.x) > EPS \
						and wr.position.y < seg.end.y - EPS and wr.end.y > seg.position.y + EPS:
					errors.append("H04: a wall blocks the courtyard–pastas opening")
					break
	if not open_found:
		errors.append("H04: no continuous passable opening between courtyard and pastas")
	var reaches_north := false
	for r in ctx["north_rooms"]:
		reaches_north = reaches_north or _has_edge(ctx, r["id"], pid)
	if not reaches_north:
		errors.append("H04: pastas does not connect to any northern room")


# --------------------------------------------------------------------------
# H05 — Valid geometry: positive sizes, containment, no overlaps, no gaps
# --------------------------------------------------------------------------

static func _check_h05(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var fp: PackedVector2Array = ctx["footprint"]
	var items := _solid_items(house, ctx)
	var covered := 0.0
	for it in items:
		var r: Rect2 = it["item"]["rect"]
		if r.size.x <= EPS or r.size.y <= EPS:
			errors.append("H05: %s has zero or negative dimensions" % it["name"])
			continue
		if _outside_area(_shape(it["item"]), fp) > TILE_TOL:
			errors.append("H05: %s lies outside the footprint" % it["name"])
		covered += _area(it["item"])
	for s in house["spaces"]:
		if _outside_area(_shape(s), ctx["interior"]) > TILE_TOL:
			errors.append("H05: %s extends into or beyond the exterior walls" % _name(s["id"], ctx))
	for o in house["openings"]:
		var orr: Rect2 = o["rect"]
		if orr.size.x < -EPS or orr.size.y < -EPS or (orr.size.x <= EPS and orr.size.y <= EPS):
			errors.append("H05: opening with invalid dimensions")
	for i in items.size():
		for j in range(i + 1, items.size()):
			if _items_overlap(items[i]["item"], items[j]["item"]):
				errors.append("H05: overlap between %s and %s" % [items[i]["name"], items[j]["name"]])
	# Spaces, walls and door gaps must tile the footprint exactly (no unexplained gaps).
	var total := absf(_signed_area(fp))
	if absf(covered - total) > TILE_TOL:
		errors.append("H05: spaces and walls cover %.3f m² of a %.3f m² footprint (gaps or overlaps)" % [covered, total])


# --------------------------------------------------------------------------
# H06 — Walls and structural dimensions
# --------------------------------------------------------------------------

static func _check_h06(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var interior: PackedVector2Array = ctx["interior"]
	var walls: Array = house["walls"]
	for i in walls.size():
		var w: Dictionary = walls[i]
		var r: Rect2 = w["rect"]
		if w["kind"] == "exterior":
			# Exterior walls must lie inside the 0.50 m band between the footprint
			# and its inset; with H05 tiling this makes them exactly 0.50 m thick.
			if _overlap_area(_shape(w), interior) > TILE_TOL:
				errors.append("H06: exterior wall %d is thicker than %.2f m (intrudes into the interior)" % [i, EXT_WALL])
		elif w["kind"] == "interior":
			var t := r.size.y if w["orient"] == "h" else r.size.x
			if w.has("poly") or not (w["orient"] == "h" or w["orient"] == "v"):
				errors.append("H06: interior wall %d is not an axis-aligned wall segment" % i)
			elif absf(t - INT_WALL) > EPS:
				errors.append("H06: interior wall %d is %.2f m thick (required %.2f m)" % [i, t, INT_WALL])
			if _outside_area(_rect_poly(r), interior) > TILE_TOL:
				errors.append("H06: interior wall %d is outside the interior" % i)
		else:
			errors.append("H06: wall %d has unknown kind '%s'" % [i, w["kind"]])
	var ring_area := absf(_signed_area(ctx["footprint"])) - absf(_signed_area(interior))
	var ext_area := 0.0
	for w in walls:
		if w["kind"] == "exterior":
			ext_area += _area(w)
	for o in house["openings"]:
		if o["kind"] == "entrance":
			ext_area += (o["rect"] as Rect2).get_area()
	if absf(ext_area - ring_area) > TILE_TOL:
		errors.append("H06: exterior walls do not form a continuous %.2f m perimeter (%.2f of %.2f m²)" % [EXT_WALL, ext_area, ring_area])
	for room in ctx["rooms"]:
		var rr: Rect2 = room["rect"]
		var short_side := minf(rr.size.x, rr.size.y)
		var area := _area(room)
		if short_side < MIN_ROOM_WIDTH - EPS:
			errors.append("H06: %s is %.2f m wide (minimum %.1f m)" % [_name(room["id"], ctx), short_side, MIN_ROOM_WIDTH])
		if area < MIN_ROOM_AREA - EPS:
			errors.append("H06: %s area %.2f m² (minimum %.1f m²)" % [_name(room["id"], ctx), area, MIN_ROOM_AREA])
		if short_side > MAX_ROOM_SPAN + EPS:
			errors.append("H06: %s clear span %.2f m exceeds %.1f m" % [_name(room["id"], ctx), short_side, MAX_ROOM_SPAN])
		if room.has("poly") and not _usable_clipped_room(room["poly"], rr):
			errors.append("H06: %s is an unusable clipped shape (sliver or acute corner)" % _name(room["id"], ctx))
	for pas in ctx["passages"]:
		var pr: Rect2 = pas["rect"]
		if minf(pr.size.x, pr.size.y) < MIN_PASSAGE_WIDTH - EPS:
			errors.append("H06: entrance passage is narrower than %.1f m" % MIN_PASSAGE_WIDTH)
	# Doors must be real gaps cut into a single wall line: wall pieces of the
	# same line and thickness must flank both ends of the opening.
	var openings: Array = house["openings"]
	for i in openings.size():
		var op: Dictionary = openings[i]
		if op["kind"] == "open":
			continue
		var r: Rect2 = op["rect"]
		var horiz: bool = op["axis"] == "ns"
		var left := false
		var right := false
		for w in walls:
			if (w["orient"] == "h") != horiz or w["orient"] == "d":
				continue
			var wr: Rect2 = w["rect"]
			if horiz and _near(wr.position.y, r.position.y) and _near(wr.end.y, r.end.y):
				left = left or _near(wr.end.x, r.position.x)
				right = right or _near(wr.position.x, r.end.x)
			elif not horiz and _near(wr.position.x, r.position.x) and _near(wr.end.x, r.end.x):
				left = left or _near(wr.end.y, r.position.y)
				right = right or _near(wr.position.y, r.end.y)
		if not (left and right):
			errors.append("H06: opening %d is not cut into a continuous wall" % i)


## A clipped room must stay convex, have no corner sharper than 90° and keep
## most of its bounding box, so a slanted exterior wall leaves no sliver.
static func _usable_clipped_room(poly: PackedVector2Array, box: Rect2) -> bool:
	if not _near(_bbox(poly).position.x, box.position.x) or not _near(_bbox(poly).end.y, box.end.y) \
			or not _near(_bbox(poly).end.x, box.end.x) or not _near(_bbox(poly).position.y, box.position.y):
		return false
	var turn := 0.0
	for i in poly.size():
		var e0 := (poly[i] - poly[i - 1]).normalized()
		var e1 := (poly[(i + 1) % poly.size()] - poly[i]).normalized()
		var cr := e0.cross(e1)
		if turn != 0.0 and signf(cr) != signf(turn):
			return false   # not convex
		turn = cr if absf(cr) > 1e-6 else turn
		if e0.dot(e1) < -EPS:
			return false   # turn sharper than 90°: interior angle below 90°
	return absf(_signed_area(poly)) >= MIN_CLIPPED_ROOM_FILL * box.get_area()


# --------------------------------------------------------------------------
# H07 — Accessibility: BFS over verified openings from the street
# --------------------------------------------------------------------------

static func _check_h07(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var reached := _reachable_from_street(ctx)
	for s in house["spaces"]:
		if not reached.has(s["id"]):
			errors.append("H07: %s inaccessible from the street entrance" % _name(s["id"], ctx))


# --------------------------------------------------------------------------
# H08 — Street entrance leading to the courtyard
# --------------------------------------------------------------------------

static func _check_h08(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var side: String = house["street_side"]
	var good := 0
	for e in ctx["edges"]:
		if e["kind"] != "entrance":
			continue
		var op: Dictionary = house["openings"][e["index"]]
		var r: Rect2 = op["rect"]
		# The street must be on the named side of the opening's outer face.
		var expected_axis := "ns" if side in ["north", "south"] else "ew"
		var street_low := side in ["north", "west"]
		var face := _face(r, op["axis"], street_low)
		if op["axis"] != expected_axis or not _segment_on_boundary(face[0], face[1], ctx["footprint"]):
			errors.append("H08: entrance %d is not in the %s street wall" % [e["index"], side])
			continue
		var inner: int = e["b"] if e["a"] == STREET else e["a"]
		var kind: String = ctx["by_id"][inner]["kind"]
		var leads := kind == "courtyard"
		if kind == "passage" and ctx["courtyards"].size() == 1:
			leads = _has_edge(ctx, inner, ctx["courtyards"][0]["id"])
		if not leads:
			errors.append("H08: entrance %d does not lead to the courtyard through a passage" % e["index"])
			continue
		var blocked := false
		for w in house["walls"]:
			blocked = blocked or _items_overlap({"rect": r}, w)
		for s in house["spaces"]:
			blocked = blocked or _items_overlap({"rect": r}, s)
		if blocked:
			errors.append("H08: entrance %d is blocked by walls or room geometry" % e["index"])
			continue
		good += 1
	if good == 0:
		errors.append("H08: no valid street-facing entrance in the exterior wall")
	if ctx["courtyards"].size() == 1 and not _reachable_from_street(ctx).has(ctx["courtyards"][0]["id"]):
		errors.append("H08: courtyard is not reachable from the entrance")


# --------------------------------------------------------------------------
# H09 — Room arrangement
# --------------------------------------------------------------------------

static func _check_h09(_house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var n: int = ctx["rooms"].size()
	if n < MIN_ROOMS or n > MAX_ROOMS:
		errors.append("H09: %d enclosed rooms (required %d–%d)" % [n, MIN_ROOMS, MAX_ROOMS])
	for room in ctx["rooms"]:
		if not ROOM_TYPES.has(room.get("type", "")):
			errors.append("H09: %s has unknown function '%s'" % [_name(room["id"], ctx), room.get("type", "")])
		var opens_onto_circulation := false
		for e in ctx["edges"]:
			var other := -999
			if e["a"] == room["id"]:
				other = e["b"]
			elif e["b"] == room["id"]:
				other = e["a"]
			if ctx["by_id"].has(other) and ctx["by_id"][other]["kind"] in ["pastas", "courtyard", "passage"]:
				opens_onto_circulation = true
		if not opens_onto_circulation:
			errors.append("H09: %s does not open onto the pastas, courtyard or passage" % _name(room["id"], ctx))


# --------------------------------------------------------------------------
# H10 — Structural alignment (simplified wall-alignment check)
# --------------------------------------------------------------------------

static func _check_h10(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var interior: PackedVector2Array = ctx["interior"]
	if not ctx["north_rooms"].is_empty():
		# Northern wing: every room spans the full wing depth, so its cross walls
		# are aligned and the wing is exactly rooms + partition walls.
		var nw: Rect2 = ctx["wing"]
		var wing_area := 0.0
		for r in ctx["north_rooms"]:
			var rr: Rect2 = r["rect"]
			if r.has("poly") or not (_near(rr.position.y, nw.position.y) and _near(rr.end.y, nw.end.y)):
				errors.append("H10: %s does not span the full depth of the northern wing" % _name(r["id"], ctx))
			wing_area += rr.get_area()
		for s in house["spaces"]:
			if not ctx["north_rooms"].has(s) and _items_overlap(s, {"rect": nw}):
				errors.append("H10: %s intrudes into the northern wing" % _name(s["id"], ctx))
		for w in house["walls"]:
			if _items_overlap(w, {"rect": nw}):
				var wr: Rect2 = w["rect"]
				if w["kind"] != "interior" or w["orient"] != "v" or not (_near(wr.position.y, nw.position.y) and _near(wr.end.y, nw.end.y)):
					errors.append("H10: wall inside the northern wing is not a full-depth north–south partition")
				wing_area += _area(w)
		if absf(wing_area - nw.get_area()) > TILE_TOL:
			errors.append("H10: northern wing is not geometrically coherent (rooms and partitions cover %.2f of %.2f m²)" % [wing_area, nw.get_area()])

	# Every interior wall piece must be supported at both ends — by another wall,
	# by the door gap it continues across, or by the exterior wall band — and be
	# connected to the exterior walls through touching walls: no floating walls.
	var parts: Array = []   # interior walls followed by door/entrance gaps
	for w in house["walls"]:
		if w["kind"] == "interior":
			parts.append({"rect": w["rect"], "wall": w})
	for o in house["openings"]:
		if o["kind"] != "open":
			parts.append({"rect": o["rect"], "wall": null})
	var pastas_rect := Rect2()
	if ctx["pastas"].size() == 1:
		pastas_rect = ctx["pastas"][0]["rect"]
	for i in parts.size():
		var w = parts[i]["wall"]
		if w == null:
			continue
		var r: Rect2 = parts[i]["rect"]
		var horiz: bool = w["orient"] == "h"
		var ends := [_face(r, "ew" if horiz else "ns", true), _face(r, "ew" if horiz else "ns", false)]
		var ok := [false, false]
		for k in 2:
			ok[k] = _segment_on_boundary(ends[k][0], ends[k][1], interior)
			for j in parts.size():
				if j == i or ok[k]:
					continue
				var q: Rect2 = parts[j]["rect"]
				var p: Vector2 = ends[k][0]
				if horiz:
					ok[k] = _span(q.position.y, q.end.y, r.position.y, r.end.y) > EPS and q.position.x <= p.x + EPS and q.end.x >= p.x - EPS
				else:
					ok[k] = _span(q.position.x, q.end.x, r.position.x, r.end.x) > EPS and q.position.y <= p.y + EPS and q.end.y >= p.y - EPS
		# A wall may also terminate as an anta on the open pastas/courtyard
		# line, where it carries the portico beam.
		if not horiz and ctx["pastas"].size() == 1:
			ok[0] = ok[0] or (_near(r.position.y, pastas_rect.end.y) and r.position.x >= pastas_rect.position.x - EPS and r.end.x <= pastas_rect.end.x + EPS)
		if not (ok[0] and ok[1]):
			errors.append("H10: interior wall at (%.2f, %.2f) ends unsupported" % [r.position.x, r.position.y])
	var linked := {}
	var queue: Array = []
	for i in parts.size():
		if _rect_touches_boundary(parts[i]["rect"], interior):
			linked[i] = true
			queue.append(i)
	while not queue.is_empty():
		var i: int = queue.pop_front()
		for j in parts.size():
			if not linked.has(j) and _touch(parts[i]["rect"], parts[j]["rect"]):
				linked[j] = true
				queue.append(j)
	for i in parts.size():
		if parts[i]["wall"] != null and not linked.has(i):
			errors.append("H10: wall at (%.2f, %.2f) is a floating structural element" % [parts[i]["rect"].position.x, parts[i]["rect"].position.y])


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

static func _has_edge(ctx: Dictionary, a: int, b: int) -> bool:
	for e in ctx["edges"]:
		if (e["a"] == a and e["b"] == b) or (e["a"] == b and e["b"] == a):
			return true
	return false


static func _reachable_from_street(ctx: Dictionary) -> Dictionary:
	var seen := {STREET: true}
	var queue: Array = [STREET]
	while not queue.is_empty():
		var n: int = queue.pop_front()
		for e in ctx["edges"]:
			var other := -999
			if e["a"] == n:
				other = e["b"]
			elif e["b"] == n:
				other = e["a"]
			if other != -999 and not seen.has(other):
				seen[other] = true
				queue.append(other)
	return seen


## Every area-bearing element: spaces, walls and door gaps.
static func _solid_items(house: Dictionary, ctx: Dictionary) -> Array:
	var items: Array = []
	for s in house["spaces"]:
		items.append({"item": s, "name": _name(s["id"], ctx)})
	var walls: Array = house["walls"]
	for i in walls.size():
		items.append({"item": walls[i], "name": "wall %d" % i})
	var openings: Array = house["openings"]
	for i in openings.size():
		if openings[i]["kind"] != "open":
			items.append({"item": openings[i], "name": "opening %d" % i})
	return items


static func _name(id, ctx: Dictionary) -> String:
	if id == STREET:
		return "street"
	if not ctx["by_id"].has(id):
		return "unknown space %s" % str(id)
	var s: Dictionary = ctx["by_id"][id]
	match s["kind"]:
		"room": return "Room %d (%s)" % [id, s.get("type", "?")]
		"courtyard": return "courtyard"
		"pastas": return "pastas"
		"passage": return "entrance passage"
	return "space %d" % id


static func _near(a: float, b: float) -> bool:
	return absf(a - b) <= EPS


static func _span(a0: float, a1: float, b0: float, b1: float) -> float:
	return minf(a1, b1) - maxf(a0, b0)


static func _overlap(a: Rect2, b: Rect2) -> bool:
	return _span(a.position.x, a.end.x, b.position.x, b.end.x) > EPS \
		and _span(a.position.y, a.end.y, b.position.y, b.end.y) > EPS


## Exact overlap test for items (rect, or rect + poly). Rect pairs are compared
## directly; polygons only when their bounding boxes overlap.
static func _items_overlap(a: Dictionary, b: Dictionary) -> bool:
	if not _overlap(a["rect"], b["rect"]):
		return false
	if not a.has("poly") and not b.has("poly"):
		return true
	return _overlap_area(_shape(a), _shape(b)) > TILE_TOL * 0.1


## True when the rectangles share a boundary segment of positive length.
static func _touch(a: Rect2, b: Rect2) -> bool:
	var sx := _span(a.position.x, a.end.x, b.position.x, b.end.x)
	var sy := _span(a.position.y, a.end.y, b.position.y, b.end.y)
	return (sx >= -EPS and sy > EPS) or (sy >= -EPS and sx > EPS)


static func _shape(item: Dictionary) -> PackedVector2Array:
	return item["poly"] if item.has("poly") else _rect_poly(item["rect"])


static func _area(item: Dictionary) -> float:
	return absf(_signed_area(item["poly"])) if item.has("poly") else (item["rect"] as Rect2).get_area()


static func _rect_poly(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


static func _bbox(poly: PackedVector2Array) -> Rect2:
	var r := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		r = r.expand(p)
	return r


static func _signed_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += float(p.x) * q.y - float(q.x) * p.y
	return a * 0.5


static func _overlap_area(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var total := 0.0
	for part in Geometry2D.intersect_polygons(a, b):
		total += absf(_signed_area(part))
	return total


## Area of `poly` lying outside `container`.
static func _outside_area(poly: PackedVector2Array, container: PackedVector2Array) -> float:
	return absf(_signed_area(poly)) - _overlap_area(poly, container)


## True if segment a–b lies along a single edge of the polygon boundary.
static func _segment_on_boundary(a: Vector2, b: Vector2, poly: PackedVector2Array) -> bool:
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		if Geometry2D.get_closest_point_to_segment(a, p, q).distance_to(a) <= EPS \
				and Geometry2D.get_closest_point_to_segment(b, p, q).distance_to(b) <= EPS:
			return true
	return false


static func _rect_touches_boundary(r: Rect2, poly: PackedVector2Array) -> bool:
	var c := _rect_poly(r)
	for i in 4:
		if _segment_on_boundary(c[i], c[(i + 1) % 4], poly):
			return true
	return false
