extends RefCounted
## Hard-rule validator for generated house data (rules H00–H12).
##
## Works only on the structured house Dictionary produced by house_generator.gd
## (or built by hand in tests). It never looks at rendering, and it derives
## every checked quantity (side count, areas, wing orientation, access) from
## the geometry itself rather than from descriptive metadata.
## A house is valid only when validate_house() returns valid == true.
## Rules H00–H12; H11 forbids footprint corners between 80° and 110°, H12
## requires the entrance on a continuous street frontage of at least 2.0 m.
## Plane-geometry measurements come from geometry.gd, shared with every view.
##
## Coordinates are metres: X grows east, Y grows south, north is up.
##
## House data layout:
##   footprint:   PackedVector2Array  outer face of the exterior walls (closed implicitly)
##   street_side: String  "north" | "south" | "east" | "west"
##   spaces:   [{id:int, kind:"room"|"courtyard"|"pastas"|"passage", type:String, rect:Rect2, [poly]}]
##   walls:    [{rect:Rect2, kind:"exterior"|"interior", orient:"h"|"v"|"d", [poly]}]   ("h" = runs east–west)
##   openings: [{rect:Rect2, axis:"ns"|"ew", kind:"door"|"entrance"|"open", a:int, b:int, [poly]}]
##             axis is the direction of travel through the opening; b == STREET for the entrance.
##             An entrance through a slanted exterior wall is a quadrilateral `poly`.
##   block:    optional PackedVector2Array — the city block the house stands in;
##             when present, the street frontage (H12) is measured on its boundary.
## `rect` is the exact shape unless `poly` is given, in which case `rect` is its
## bounding box and `poly` the exact shape (clipped rooms, mitred exterior walls).

const G := preload("res://scripts/geometry.gd")

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
const MIN_CLIPPED_ROOM_FILL := 0.60   # a clipped room keeps >= 60 % of its bounding box
const MIN_CLIPPED_CORNER := 45.0      # degrees; no spiky corners where a slanted wall cuts a room
const FORBIDDEN_ANGLE_MIN := 80.0     # H11: footprint interior angles in [80°, 110°] are forbidden
const FORBIDDEN_ANGLE_MAX := 110.0
const ANGLE_EPS := 1e-6
const MIN_STREET_FRONTAGE := 2.0      # H12.1: continuous street frontage, metres
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
	_check_h11(ctx, errors)
	_check_h12(house, ctx, errors)
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


## Interior angle (degrees) at every vertex of a simple polygon; reflex
## corners are > 180°. Computed from the geometry, for H11 and the tests.
static func interior_angles(poly: PackedVector2Array) -> Array:
	return G.interior_angles(poly)


## True if an interior angle violates H11 (inside 80°–110°, inclusive).
static func forbidden_angle(a: float) -> bool:
	return a >= FORBIDDEN_ANGLE_MIN - ANGLE_EPS and a <= FORBIDDEN_ANGLE_MAX + ANGLE_EPS


## Street edges: footprint edges on the street. In a city block every edge
## of the block polygon is a street, so these are the footprint edges lying
## on the block boundary; for a standalone house, the edges on the outermost
## line of its street side.
static func street_edges(house: Dictionary) -> Array:
	var fp: PackedVector2Array = house["footprint"]
	var block: PackedVector2Array = house.get("block", PackedVector2Array())
	var box := G.bbox(fp)
	var out: Array = []
	for i in fp.size():
		var a := fp[i]
		var b := fp[(i + 1) % fp.size()]
		var on_street := false
		if not block.is_empty():
			on_street = _segment_on_boundary(a, b, block)
		else:
			match house["street_side"]:
				"south": on_street = _near(a.y, box.end.y) and _near(b.y, box.end.y)
				"north": on_street = _near(a.y, box.position.y) and _near(b.y, box.position.y)
				"east": on_street = _near(a.x, box.end.x) and _near(b.x, box.end.x)
				"west": on_street = _near(a.x, box.position.x) and _near(b.x, box.position.x)
		if on_street and a.distance_to(b) > EPS:
			out.append({"edge": i, "length": a.distance_to(b), "a": a, "b": b})
	return out


## Street frontage (H12): the street edge holding the entrance if there is
## one, else the longest street edge. Edges cannot be collinear neighbours
## (H00), so one edge is one continuous stretch.
## Returns {edge: index or -1, length, a, b}.
static func street_frontage(house: Dictionary) -> Dictionary:
	var best := {"edge": -1, "length": 0.0, "a": Vector2.ZERO, "b": Vector2.ZERO}
	var faces: Array = []
	for op in house["openings"]:
		if op["kind"] == "entrance":
			var ctx := {"footprint": house["footprint"], "by_id": {}}
			for sp in house["spaces"]:
				ctx["by_id"][sp["id"]] = sp
			var f := _street_face(op, ctx)
			if not f.is_empty():
				faces.append(f)
	for e in street_edges(house):
		var holds := faces.any(func(f): return _segment_on_boundary(f[0], f[1], PackedVector2Array([e["a"], e["b"]])))
		var best_holds: bool = best["edge"] >= 0 and faces.any(func(f): return _segment_on_boundary(f[0], f[1], PackedVector2Array([best["a"], best["b"]])))
		if (holds and not best_holds) or (holds == best_holds and e["length"] > best["length"]):
			best = e
	return best


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
	if house.has("block") and typeof(house["block"]) != TYPE_PACKED_VECTOR2_ARRAY:
		errors.append("H12: block must be a PackedVector2Array polygon")
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
	if op.has("poly"):
		return _slanted_entrance_problem(op, ctx)
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


## An entrance cut through a slanted exterior wall: a quadrilateral whose outer
## face lies on the footprint boundary, whose inner face lies on the boundary
## of the space it serves, whose two jambs run along the direction of travel,
## with the wall's thickness between the faces and a clear width >= 0.80 m.
static func _slanted_entrance_problem(op: Dictionary, ctx: Dictionary) -> String:
	if op["kind"] != "entrance":
		return "only street entrances may be cut through slanted walls"
	if not (op["a"] == STREET or op["b"] == STREET) or op["a"] == op["b"]:
		return "an entrance must join one space to the street"
	var inner: int = op["b"] if op["a"] == STREET else op["a"]
	if not ctx["by_id"].has(inner):
		return "unknown inner space"
	var poly: PackedVector2Array = op["poly"]
	if poly.size() != 4 or not _bbox(poly).is_equal_approx(op["rect"]):
		return "gap must be a quadrilateral matching its extent"
	var parts := _entrance_parts(op, ctx)
	if parts.is_empty():
		return "does not sit between the street face and the space it serves"
	var outer: Array = parts["outer"]
	var face: Array = parts["inner"]
	var jambs: Array = parts["jambs"]
	var travel := Vector2(0, 1) if op["axis"] == "ns" else Vector2(1, 0)
	for j in jambs:
		if absf((j[1] - j[0]).normalized().cross(travel)) > 1e-3:
			return "jambs do not run along the direction of travel"
	var u: Vector2 = (outer[1] - outer[0]).normalized()
	for p in face:
		if absf(absf(u.cross(p - outer[0])) - EXT_WALL) > EPS:
			return "gap is not exactly through the %.2f m exterior wall" % EXT_WALL
	var width := absf((jambs[0][0] - jambs[1][0]).dot(Vector2(1, 0) if op["axis"] == "ns" else Vector2(0, 1)))
	if width < MIN_DOOR_WIDTH - EPS:
		return "clear width %.2f m is below %.2f m" % [width, MIN_DOOR_WIDTH]
	return ""


## Splits a slanted entrance gap into its outer face (on the footprint
## boundary), inner face (on the served space's boundary) and two jambs.
## Returns {} if no such assignment exists.
static func _entrance_parts(op: Dictionary, ctx: Dictionary) -> Dictionary:
	var poly: PackedVector2Array = op["poly"]
	var inner: int = op["b"] if op["a"] == STREET else op["a"]
	if not ctx["by_id"].has(inner) or poly.size() != 4:
		return {}
	var space_shape := _shape(ctx["by_id"][inner])
	for k in 4:
		var o := [poly[k], poly[(k + 1) % 4]]
		var f := [poly[(k + 2) % 4], poly[(k + 3) % 4]]
		if _segment_on_boundary(o[0], o[1], ctx["footprint"]) and _segment_on_boundary(f[0], f[1], space_shape):
			return {"outer": o, "inner": f, "jambs": [[poly[(k + 1) % 4], poly[(k + 2) % 4]], [poly[(k + 3) % 4], poly[k]]]}
	return {}


## Outer (street) face of a verified entrance, rect or slanted.
static func _street_face(op: Dictionary, ctx: Dictionary) -> Array:
	if op.has("poly"):
		return _entrance_parts(op, ctx).get("outer", [])
	for low in [true, false]:
		var face := _face(op["rect"], op["axis"], low)
		if _segment_on_boundary(face[0], face[1], ctx["footprint"]):
			return face
	return []


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
	if court.has("poly"):
		errors.append("H01: courtyard must be an unclipped rectangle")
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
	for r in north:
		if _outside_area(_shape(r), ctx["interior"]) > TILE_TOL:
			errors.append("H02: northern wing room %d lies outside the footprint interior" % r["id"])
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
	# Where slanted exterior walls trim the pastas ends, the pastas must stay a
	# convex portico without spiky corners.
	if ctx["pastas"][0].has("poly") and _clipped_shape_problem(ctx["pastas"][0]["poly"], p, false) != "":
		errors.append("H04: pastas is an unusable clipped shape: %s" % _clipped_shape_problem(ctx["pastas"][0]["poly"], p, false))
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
			# A wall blocks the open edge if any of it lies on the edge line
			# (tested against a 2 cm strip along the edge, with real wall shapes).
			var strip := G.rect_poly(Rect2(seg.position.x, seg.position.y - 0.01, seg.size.x, 0.02))
			for w in house["walls"]:
				if _overlap(w["rect"], Rect2(seg.position.x, seg.position.y - 0.01, seg.size.x, 0.02)) and _overlap_area(_shape(w), strip) > 1e-4:
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
			if not (w["orient"] == "h" or w["orient"] == "v"):
				errors.append("H06: interior wall %d is not an axis-aligned wall segment" % i)
			elif absf(t - INT_WALL) > EPS:
				errors.append("H06: interior wall %d is %.2f m thick (required %.2f m)" % [i, t, INT_WALL])
			if w.has("poly") and not _bbox(w["poly"]).is_equal_approx(r):
				errors.append("H06: interior wall %d shape does not match its extent" % i)
			if _outside_area(_shape(w), interior) > TILE_TOL:
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
			ext_area += _area(o)
	if absf(ext_area - ring_area) > TILE_TOL:
		errors.append("H06: exterior walls do not form a continuous %.2f m perimeter (%.2f of %.2f m²)" % [EXT_WALL, ext_area, ring_area])
	for room in ctx["rooms"]:
		var rr: Rect2 = room["rect"]
		# Clear width/span of a clipped room is its minimum width across any
		# direction (rotating calipers), not its bounding box.
		var short_side := _min_width(room["poly"]) if room.has("poly") else minf(rr.size.x, rr.size.y)
		var area := _area(room)
		if short_side < MIN_ROOM_WIDTH - EPS:
			errors.append("H06: %s is %.2f m wide (minimum %.1f m)" % [_name(room["id"], ctx), short_side, MIN_ROOM_WIDTH])
		if area < MIN_ROOM_AREA - EPS:
			errors.append("H06: %s area %.2f m² (minimum %.1f m²)" % [_name(room["id"], ctx), area, MIN_ROOM_AREA])
		if short_side > MAX_ROOM_SPAN + EPS:
			errors.append("H06: %s clear span %.2f m exceeds %.1f m" % [_name(room["id"], ctx), short_side, MAX_ROOM_SPAN])
		if room.has("poly") and _clipped_shape_problem(room["poly"], rr, true) != "":
			errors.append("H06: %s is an unusable clipped shape: %s" % [_name(room["id"], ctx), _clipped_shape_problem(room["poly"], rr, true)])
	for pas in ctx["passages"]:
		var pr: Rect2 = pas["rect"]
		var pw := _min_width(pas["poly"]) if pas.has("poly") else minf(pr.size.x, pr.size.y)
		if pw < MIN_PASSAGE_WIDTH - EPS:
			errors.append("H06: entrance passage is narrower than %.1f m" % MIN_PASSAGE_WIDTH)
		if pas.has("poly") and _clipped_shape_problem(pas["poly"], pr, false) != "":
			errors.append("H06: entrance passage is an unusable clipped shape: %s" % _clipped_shape_problem(pas["poly"], pr, false))
	# Doors must be real gaps cut into a single wall line: wall pieces of the
	# same line and thickness must flank both ends of the opening.
	var openings: Array = house["openings"]
	for i in openings.size():
		var op: Dictionary = openings[i]
		if op["kind"] == "open":
			continue
		if op.has("poly"):
			# Gap in a slanted wall: both jambs must be faces of exterior wall pieces.
			var jambs: Array = _entrance_parts(op, ctx).get("jambs", [])
			var flanked: bool = jambs.size() == 2
			for j in jambs:
				flanked = flanked and walls.any(func(w): return w["kind"] == "exterior" and _segment_on_boundary(j[0], j[1], _shape(w)))
			if not flanked:
				errors.append("H06: opening %d is not cut into a continuous wall" % i)
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


## A room or pastas trimmed by a slanted exterior wall must stay convex, have
## no corner sharper than MIN_CLIPPED_CORNER, keep most of its bounding box and
## (rooms) stay at least MIN_ROOM_WIDTH wide in every direction, so the
## slanted boundary leaves no sliver. Returns "" when usable.
static func _clipped_shape_problem(poly: PackedVector2Array, box: Rect2, is_room: bool) -> String:
	if not _bbox(poly).is_equal_approx(box):
		return "shape does not match its extent"
	var orient := 0.0
	for i in poly.size():
		var e0 := poly[i] - poly[i - 1]
		var e1 := poly[(i + 1) % poly.size()] - poly[i]
		var cr := e0.normalized().cross(e1.normalized())
		if absf(cr) <= 1e-6:
			continue   # collinear point
		if orient != 0.0 and signf(cr) != orient:
			return "not convex"
		orient = signf(cr)
	for a in interior_angles(poly):
		if a < MIN_CLIPPED_CORNER - EPS:
			return "corner of %.1f° is sharper than %.0f°" % [a, MIN_CLIPPED_CORNER]
	if absf(_signed_area(poly)) < MIN_CLIPPED_ROOM_FILL * box.get_area():
		return "fills less than %d %% of its extent (sliver)" % int(MIN_CLIPPED_ROOM_FILL * 100)
	if is_room and _min_width(poly) < MIN_ROOM_WIDTH - EPS:
		return "narrower than %.1f m" % MIN_ROOM_WIDTH
	return ""


## Minimum width of a convex polygon: over all edges, the largest distance of
## any vertex from that edge's line; the smallest such value.
static func _min_width(poly: PackedVector2Array) -> float:
	var best := INF
	for i in poly.size():
		var a := poly[i]
		var u := poly[(i + 1) % poly.size()] - a
		if u.length() <= EPS:
			continue
		u = u.normalized()
		var far := 0.0
		for p in poly:
			far = maxf(far, absf(u.cross(p - a)))
		best = minf(best, far)
	return best


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
	var want: Vector2 = {"south": Vector2(0, 1), "north": Vector2(0, -1), "east": Vector2(1, 0), "west": Vector2(-1, 0)}.get(side, Vector2.ZERO)
	var good := 0
	for e in ctx["edges"]:
		if e["kind"] != "entrance":
			continue
		var op: Dictionary = house["openings"][e["index"]]
		# The outer face must be in the footprint wall facing the named street
		# side (outward normal within 60° of that direction).
		var face := _street_face(op, ctx)
		if face.is_empty() or _outward_normal(face, ctx["footprint"]).dot(want) < 0.5:
			errors.append("H08: entrance %d is not in the %s street wall" % [e["index"], side])
			continue
		# From the entrance the courtyard must be reached through circulation
		# space only (passage, pastas), never through a room.
		var inner: int = e["b"] if e["a"] == STREET else e["a"]
		if ctx["courtyards"].size() != 1 or not _reaches_through_circulation(ctx, inner, ctx["courtyards"][0]["id"]):
			errors.append("H08: entrance %d does not lead to the courtyard through a passage" % e["index"])
			continue
		var blocked := false
		for w in house["walls"]:
			blocked = blocked or _items_overlap(op, w)
		for s in house["spaces"]:
			blocked = blocked or _items_overlap(op, s)
		if blocked:
			errors.append("H08: entrance %d is blocked by walls or room geometry" % e["index"])
			continue
		good += 1
	if good == 0:
		errors.append("H08: no valid street-facing entrance in the exterior wall")
	if ctx["courtyards"].size() == 1 and not _reachable_from_street(ctx).has(ctx["courtyards"][0]["id"]):
		errors.append("H08: courtyard is not reachable from the entrance")


## BFS from space `from` to `to` through passages, the pastas and the courtyard only.
static func _reaches_through_circulation(ctx: Dictionary, from: int, to: int) -> bool:
	var ok_kinds := ["passage", "pastas", "courtyard"]
	if not ctx["by_id"].has(from) or not ctx["by_id"][from]["kind"] in ok_kinds:
		return false
	var seen := {from: true}
	var queue: Array = [from]
	while not queue.is_empty():
		var n: int = queue.pop_front()
		if n == to:
			return true
		for e in ctx["edges"]:
			var other: int = e["b"] if e["a"] == n else (e["a"] if e["b"] == n else -999)
			if ctx["by_id"].has(other) and ctx["by_id"][other]["kind"] in ok_kinds and not seen.has(other):
				seen[other] = true
				queue.append(other)
	return false


## Unit normal of a footprint boundary segment pointing out of the footprint.
static func _outward_normal(face: Array, fp: PackedVector2Array) -> Vector2:
	var n: Vector2 = (face[1] - face[0]).orthogonal().normalized()
	var mid: Vector2 = (face[0] + face[1]) / 2.0
	return -n if G.point_in_polygon(mid + n * 0.01, fp) else n


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
		# End rooms may be trimmed where a slanted exterior wall crosses the wing,
		# so the wing region is its bounding box intersected with the interior.
		# Where the street front is slanted the tops follow it, so alignment is
		# checked on the common south line; the wing region must then be exactly
		# these rooms (plus an entrance passage) and their partitions, which also
		# makes every one of them reach the exterior wall.
		var nw: Rect2 = ctx["wing"]
		var wing_area := 0.0
		var members: Array = ctx["north_rooms"] + ctx["passages"].filter(func(p): return (p["rect"] as Rect2).end.y <= nw.end.y + EPS)
		for r in members:
			var rr: Rect2 = r["rect"]
			if not _near(rr.end.y, nw.end.y) or rr.position.y > nw.position.y + MAX_ROOM_SPAN + 2.0:
				errors.append("H10: %s does not span the full depth of the northern wing" % _name(r["id"], ctx))
			wing_area += _area(r)
		for s in house["spaces"]:
			if not members.has(s) and _items_overlap(s, {"rect": nw}):
				errors.append("H10: %s intrudes into the northern wing" % _name(s["id"], ctx))
		for w in house["walls"]:
			if w["kind"] == "interior" and _items_overlap(w, {"rect": nw}):
				var wr: Rect2 = w["rect"]
				if w["orient"] != "v" or not _near(wr.end.y, nw.end.y):
					errors.append("H10: wall inside the northern wing is not a full-depth north–south partition")
				wing_area += _area(w)
		var wing_region := _overlap_area(_rect_poly(nw), interior)
		if absf(wing_area - wing_region) > TILE_TOL:
			errors.append("H10: northern wing is not geometrically coherent (rooms and partitions cover %.2f of %.2f m²)" % [wing_area, wing_region])

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
		# A wall trimmed by a slanted exterior wall ends on the interior boundary
		# with a slanted face (an edge of its poly).
		if w.has("poly"):
			var poly: PackedVector2Array = w["poly"]
			for e in poly.size():
				var a := poly[e]
				var b := poly[(e + 1) % poly.size()]
				if a.distance_to(b) > EPS and _segment_on_boundary(a, b, interior):
					var mid := (a + b) / 2.0
					var along := mid.x - r.get_center().x if horiz else mid.y - r.get_center().y
					ok[0 if along < 0.0 else 1] = true
		for k in 2:
			ok[k] = ok[k] or _segment_on_boundary(ends[k][0], ends[k][1], interior)
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
		var wall = parts[i]["wall"]
		if _touches_boundary(wall["poly"] if wall != null and wall.has("poly") else _rect_poly(parts[i]["rect"]), interior):
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
# H11 — No footprint corner between 80° and 110° (inclusive)
# --------------------------------------------------------------------------

static func _check_h11(ctx: Dictionary, errors: Array) -> void:
	var angles := interior_angles(ctx["footprint"])
	for i in angles.size():
		var a: float = angles[i]
		if forbidden_angle(a):
			errors.append("H11: footprint corner %d has an interior angle of %.2f° (80°–110° is forbidden)" % [i, a])


# --------------------------------------------------------------------------
# H12 — Direct street access; H12.1 — at least 2.0 m continuous frontage
# --------------------------------------------------------------------------

static func _check_h12(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var where := "block boundary" if house.has("block") else "%s street boundary" % house["street_side"]
	if street_edges(house).is_empty():
		errors.append("H12: footprint has no edge on the %s" % where)
		return
	# Direct access: a verified entrance whose outer face lies on a street edge.
	var front := street_frontage(house)
	var direct := false
	for e in ctx["edges"]:
		if e["kind"] == "entrance":
			var face := _street_face(house["openings"][e["index"]], ctx)
			direct = direct or (not face.is_empty() and _segment_on_boundary(face[0], face[1], PackedVector2Array([front["a"], front["b"]])))
	if not direct:
		errors.append("H12: no entrance opens directly onto the street frontage (%s)" % where)
	if front["length"] < MIN_STREET_FRONTAGE - EPS:
		errors.append("H12.1: continuous street frontage is %.2f m (minimum %.1f m)" % [front["length"], MIN_STREET_FRONTAGE])


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
	return G.shape(item)


static func _area(item: Dictionary) -> float:
	return G.item_area(item)


static func _rect_poly(r: Rect2) -> PackedVector2Array:
	return G.rect_poly(r)


static func _bbox(poly: PackedVector2Array) -> Rect2:
	return G.bbox(poly)


static func _signed_area(poly: PackedVector2Array) -> float:
	return G.signed_area(poly)


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


static func _touches_boundary(shape: PackedVector2Array, poly: PackedVector2Array) -> bool:
	for i in shape.size():
		var a := shape[i]
		var b := shape[(i + 1) % shape.size()]
		if a.distance_to(b) > EPS and _segment_on_boundary(a, b, poly):
			return true
	return false
