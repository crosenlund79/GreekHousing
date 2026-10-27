extends RefCounted
## Hard-rule validator for generated house data (rules H01–H10).
##
## Works only on the structured house Dictionary produced by house_generator.gd
## (or built by hand in tests). It never looks at rendering. A house is valid
## only when validate_house() returns {"valid": true, "errors": []}.
##
## Coordinates are metres: X grows east, Y grows south, north is up.
## All rectangles are axis-aligned Rect2 values.
##
## House data layout:
##   footprint:   Rect2   outer face of the exterior walls
##   north_wing:  Rect2   clear interior extent of the principal northern wing
##   street_side: String  "north" | "south" | "east" | "west"
##   spaces:   [{id:int, kind:"room"|"courtyard"|"pastas"|"passage", type:String, zone:String, rect:Rect2}]
##   walls:    [{rect:Rect2, kind:"exterior"|"interior", orient:"h"|"v"}]   ("h" = runs east–west)
##   openings: [{rect:Rect2, axis:"ns"|"ew", kind:"door"|"entrance"|"open", a:int, b:int}]
##             axis is the direction of travel through the opening; b == STREET for the entrance.

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
const ROOM_TYPES := ["Domestic room", "Storage", "Kitchen / hearth", "Andron", "Workroom"]

const STREET := -1
const EPS := 0.001        # 1 mm positional tolerance
const TILE_TOL := 0.01    # m² tolerance for the gap (tiling) check


static func validate_house(house: Dictionary) -> Dictionary:
	var errors: Array = []
	if not _check_structure(house, errors):
		return {"valid": false, "errors": errors}
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
	return {"valid": errors.is_empty(), "errors": errors}


# --------------------------------------------------------------------------
# Structure and shared context
# --------------------------------------------------------------------------

static func _check_structure(house: Dictionary, errors: Array) -> bool:
	for key in ["footprint", "north_wing", "street_side", "spaces", "walls", "openings"]:
		if not house.has(key):
			errors.append("H05: malformed house data, missing '%s'" % key)
	if not errors.is_empty():
		return false
	if typeof(house["footprint"]) != TYPE_RECT2 or typeof(house["north_wing"]) != TYPE_RECT2:
		errors.append("H05: footprint and north_wing must be Rect2")
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


## Collects spaces by kind and resolves which openings are physically real.
## Only geometrically verified openings become edges of the circulation graph.
static func _build_context(house: Dictionary, errors: Array) -> Dictionary:
	var ctx := {
		"by_id": {}, "rooms": [], "courtyards": [], "pastas": [], "passages": [],
		"edges": [],          # [{a, b, kind, index}] for verified openings only
		"interior": (house["footprint"] as Rect2).grow(-EXT_WALL),
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
	var openings: Array = house["openings"]
	for i in openings.size():
		var op: Dictionary = openings[i]
		var problem := _opening_problem(op, ctx["by_id"], house["footprint"])
		if problem == "":
			ctx["edges"].append({"a": op["a"], "b": op["b"], "kind": op["kind"], "index": i})
		else:
			errors.append("H07: opening %d (%s, %s) is not a real traversable opening: %s"
				% [i, _name(op["a"], ctx), _name(op["b"], ctx), problem])
	return ctx


## Returns "" when the opening lies exactly on a shared boundary of its two
## spaces (or of a space and the street), with the right thickness and width.
static func _opening_problem(op: Dictionary, by_id: Dictionary, footprint: Rect2) -> String:
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
	if not (_side_ok(r, axis, op["a"], true, by_id, footprint) and _side_ok(r, axis, op["b"], false, by_id, footprint)) \
			and not (_side_ok(r, axis, op["b"], true, by_id, footprint) and _side_ok(r, axis, op["a"], false, by_id, footprint)):
		return "does not sit on a boundary shared by its two spaces (floating or opening into a wall)"
	return ""


## Checks that space `id` lies flush against the low (north/west) or high
## (south/east) face of the opening and fully spans the opening's width.
static func _side_ok(r: Rect2, axis: String, id: int, low_side: bool, by_id: Dictionary, fp: Rect2) -> bool:
	if id == STREET:
		var inside := _contains(fp, r)
		if axis == "ns":
			return inside and (_near(r.position.y, fp.position.y) if low_side else _near(r.end.y, fp.end.y))
		return inside and (_near(r.position.x, fp.position.x) if low_side else _near(r.end.x, fp.end.x))
	if not by_id.has(id):
		return false
	var s: Rect2 = by_id[id]["rect"]
	if axis == "ns":
		var flush := _near(s.end.y, r.position.y) if low_side else _near(s.position.y, r.end.y)
		return flush and s.position.x <= r.position.x + EPS and s.end.x >= r.end.x - EPS
	var flush_x := _near(s.end.x, r.position.x) if low_side else _near(s.position.x, r.end.x)
	return flush_x and s.position.y <= r.position.y + EPS and s.end.y >= r.end.y - EPS


# --------------------------------------------------------------------------
# H01 — Courtyard area: exactly one open courtyard of 16.0 m² clear area
# --------------------------------------------------------------------------

static func _check_h01(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var courts: Array = ctx["courtyards"]
	if courts.size() != 1:
		errors.append("H01: expected exactly one courtyard, found %d" % courts.size())
		return
	var c: Rect2 = courts[0]["rect"]
	if c.size.x <= 0.0 or c.size.y <= 0.0:
		errors.append("H01: courtyard has non-positive dimensions")
		return
	var area := c.size.x * c.size.y
	if absf(area - COURTYARD_AREA) > COURTYARD_AREA_TOL:
		errors.append("H01: Courtyard area incorrect (%.3f m², required %.3f m²)" % [area, COURTYARD_AREA])
	if not _contains(ctx["interior"], c):
		errors.append("H01: courtyard is not contained in the interior of the footprint")
	for s in house["spaces"]:
		if s["id"] != courts[0]["id"] and _overlap(c, s["rect"]):
			errors.append("H01: courtyard overlaps %s" % _name(s["id"], ctx))
	for w in house["walls"]:
		if _overlap(c, w["rect"]):
			errors.append("H01: courtyard is obstructed by a wall")
			break


# --------------------------------------------------------------------------
# H02 — Principal northern wing, oriented east–west, north of the pastas
# --------------------------------------------------------------------------

static func _check_h02(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var nw: Rect2 = house["north_wing"]
	if nw.size.x <= 0.0 or nw.size.y <= 0.0:
		errors.append("H02: northern wing has non-positive dimensions")
		return
	if not (nw.size.x > nw.size.y + EPS):
		errors.append("H02: northern wing is not oriented east–west (width %.2f m <= depth %.2f m)" % [nw.size.x, nw.size.y])
	if not _contains(ctx["interior"], nw):
		errors.append("H02: northern wing lies outside the footprint interior")
	if ctx["pastas"].size() == 1:
		var p: Rect2 = ctx["pastas"][0]["rect"]
		if nw.end.y > p.position.y + EPS:
			errors.append("H02: northern wing bottom (%.2f) lies south of pastas top (%.2f)" % [nw.end.y, p.position.y])
	if ctx["courtyards"].size() == 1:
		var c: Rect2 = ctx["courtyards"][0]["rect"]
		if nw.end.y > c.position.y + EPS:
			errors.append("H02: northern wing is not north of the courtyard")
	var north_rooms := _north_rooms(ctx)
	if north_rooms.is_empty():
		errors.append("H02: northern wing contains no rooms")
	for r in north_rooms:
		if not _contains(nw, r["rect"]):
			errors.append("H02: %s is assigned to the northern wing but lies outside it" % _name(r["id"], ctx))
	if ctx["pastas"].size() == 1:
		var pid: int = ctx["pastas"][0]["id"]
		var linked := false
		for r in north_rooms:
			if _has_edge(ctx, r["id"], pid):
				linked = true
		if not linked:
			errors.append("H02: northern wing has no functional connection to the courtyard via the pastas")


# --------------------------------------------------------------------------
# H03 — Courtyard in the central/southern part, adjacent to the pastas
# --------------------------------------------------------------------------

static func _check_h03(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	if ctx["courtyards"].size() != 1:
		return  # reported by H01
	var c: Rect2 = ctx["courtyards"][0]["rect"]
	var fp: Rect2 = house["footprint"]
	if not (c.get_center().y > fp.get_center().y + EPS):
		errors.append("H03: courtyard centre (y=%.2f) is not south of the building midpoint (y=%.2f)" % [c.get_center().y, fp.get_center().y])
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
	for r in _north_rooms(ctx):
		if _has_edge(ctx, r["id"], pid):
			reaches_north = true
	if not reaches_north:
		errors.append("H04: pastas does not connect to any northern room")


# --------------------------------------------------------------------------
# H05 — Valid geometry: positive sizes, containment, no overlaps, no gaps
# --------------------------------------------------------------------------

static func _check_h05(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var fp: Rect2 = house["footprint"]
	if fp.size.x <= 0.0 or fp.size.y <= 0.0:
		errors.append("H05: footprint has non-positive dimensions")
		return
	var items := _solid_items(house, ctx)
	var covered := 0.0
	for it in items:
		var r: Rect2 = it["rect"]
		if r.size.x <= EPS or r.size.y <= EPS:
			errors.append("H05: %s has zero or negative dimensions" % it["name"])
		if not _contains(fp, r):
			errors.append("H05: %s lies outside the footprint" % it["name"])
		covered += r.get_area()
	for s in house["spaces"]:
		if not _contains(ctx["interior"], s["rect"]):
			errors.append("H05: %s extends into or beyond the exterior walls" % _name(s["id"], ctx))
	for o in house["openings"]:
		var orr: Rect2 = o["rect"]
		if orr.size.x < -EPS or orr.size.y < -EPS or (orr.size.x <= EPS and orr.size.y <= EPS):
			errors.append("H05: opening with invalid dimensions")
	for i in items.size():
		for j in range(i + 1, items.size()):
			if _overlap(items[i]["rect"], items[j]["rect"]):
				errors.append("H05: overlap between %s and %s" % [items[i]["name"], items[j]["name"]])
	# Spaces, walls and door gaps must tile the footprint exactly (no unexplained gaps).
	if absf(covered - fp.get_area()) > TILE_TOL:
		errors.append("H05: spaces and walls cover %.3f m² of a %.3f m² footprint (gaps or overlaps)" % [covered, fp.get_area()])


# --------------------------------------------------------------------------
# H06 — Walls and structural dimensions
# --------------------------------------------------------------------------

static func _check_h06(house: Dictionary, ctx: Dictionary, errors: Array) -> void:
	var interior: Rect2 = ctx["interior"]
	var walls: Array = house["walls"]
	for i in walls.size():
		var w: Dictionary = walls[i]
		var r: Rect2 = w["rect"]
		var t := r.size.y if w["orient"] == "h" else r.size.x
		if w["kind"] == "exterior":
			if absf(t - EXT_WALL) > EPS:
				errors.append("H06: exterior wall %d is %.2f m thick (required %.2f m)" % [i, t, EXT_WALL])
			if _overlap(r, interior):
				errors.append("H06: exterior wall %d intrudes into the interior" % i)
		elif w["kind"] == "interior":
			if absf(t - INT_WALL) > EPS:
				errors.append("H06: interior wall %d is %.2f m thick (required %.2f m)" % [i, t, INT_WALL])
			if not _contains(interior, r):
				errors.append("H06: interior wall %d is outside the interior" % i)
		else:
			errors.append("H06: wall %d has unknown kind '%s'" % [i, w["kind"]])
	for room in ctx["rooms"]:
		var rr: Rect2 = room["rect"]
		var short_side := minf(rr.size.x, rr.size.y)
		if short_side < MIN_ROOM_WIDTH - EPS:
			errors.append("H06: %s is %.2f m wide (minimum %.1f m)" % [_name(room["id"], ctx), short_side, MIN_ROOM_WIDTH])
		if rr.get_area() < MIN_ROOM_AREA - EPS:
			errors.append("H06: %s area %.2f m² (minimum %.1f m²)" % [_name(room["id"], ctx), rr.get_area(), MIN_ROOM_AREA])
		if short_side > MAX_ROOM_SPAN + EPS:
			errors.append("H06: %s clear span %.2f m exceeds %.1f m" % [_name(room["id"], ctx), short_side, MAX_ROOM_SPAN])
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
			if (w["orient"] == "h") != horiz:
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
	var fp: Rect2 = house["footprint"]
	var side: String = house["street_side"]
	var good := 0
	for e in ctx["edges"]:
		if e["kind"] != "entrance":
			continue
		var op: Dictionary = house["openings"][e["index"]]
		var r: Rect2 = op["rect"]
		var on_street := false
		match side:
			"south": on_street = op["axis"] == "ns" and _near(r.end.y, fp.end.y)
			"north": on_street = op["axis"] == "ns" and _near(r.position.y, fp.position.y)
			"east": on_street = op["axis"] == "ew" and _near(r.end.x, fp.end.x)
			"west": on_street = op["axis"] == "ew" and _near(r.position.x, fp.position.x)
		if not on_street:
			errors.append("H08: entrance %d does not face the %s street" % [e["index"], side])
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
			blocked = blocked or _overlap(r, w["rect"])
		for s in house["spaces"]:
			blocked = blocked or _overlap(r, s["rect"])
		if blocked:
			errors.append("H08: entrance %d is blocked by walls or room geometry" % e["index"])
			continue
		good += 1
	if good == 0:
		errors.append("H08: no valid street-facing entrance")
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
	var nw: Rect2 = house["north_wing"]
	# Northern wing: every room spans the full wing depth, so its cross walls
	# are aligned and the wing is exactly rooms + partition walls.
	var wing_area := 0.0
	for r in _north_rooms(ctx):
		var rr: Rect2 = r["rect"]
		if not (_near(rr.position.y, nw.position.y) and _near(rr.end.y, nw.end.y)):
			errors.append("H10: %s does not span the full depth of the northern wing" % _name(r["id"], ctx))
		wing_area += rr.get_area()
	for s in house["spaces"]:
		if s.get("zone", "") != "north" and _overlap(s["rect"], nw):
			errors.append("H10: %s intrudes into the northern wing" % _name(s["id"], ctx))
	for w in house["walls"]:
		var wr: Rect2 = w["rect"]
		if _overlap(wr, nw):
			if not _contains(nw, wr) or w["orient"] != "v" or not (_near(wr.position.y, nw.position.y) and _near(wr.end.y, nw.end.y)):
				errors.append("H10: wall inside the northern wing is not a full-depth north–south partition")
			wing_area += wr.get_area()
	if absf(wing_area - nw.get_area()) > TILE_TOL:
		errors.append("H10: northern wing is not geometrically coherent (rooms and partitions cover %.2f of %.2f m²)" % [wing_area, nw.get_area()])

	# Every interior wall piece must be supported at both ends (by another wall
	# or by the door gap it continues across) and be connected to the exterior
	# walls through touching walls — no floating or dangling walls.
	var parts: Array = []   # walls followed by door/entrance gaps
	for w in house["walls"]:
		parts.append({"rect": w["rect"], "wall": w})
	for o in house["openings"]:
		if o["kind"] != "open":
			parts.append({"rect": o["rect"], "wall": null})
	for i in parts.size():
		var w = parts[i]["wall"]
		if w == null or w["kind"] != "interior":
			continue
		var r: Rect2 = parts[i]["rect"]
		var start_ok := false
		var end_ok := false
		for j in parts.size():
			if i == j:
				continue
			var q: Rect2 = parts[j]["rect"]
			if w["orient"] == "h":
				var y_ov := _span(q.position.y, q.end.y, r.position.y, r.end.y) > EPS
				start_ok = start_ok or (y_ov and q.position.x <= r.position.x + EPS and q.end.x >= r.position.x - EPS)
				end_ok = end_ok or (y_ov and q.position.x <= r.end.x + EPS and q.end.x >= r.end.x - EPS)
			else:
				var x_ov := _span(q.position.x, q.end.x, r.position.x, r.end.x) > EPS
				start_ok = start_ok or (x_ov and q.position.y <= r.position.y + EPS and q.end.y >= r.position.y - EPS)
				end_ok = end_ok or (x_ov and q.position.y <= r.end.y + EPS and q.end.y >= r.end.y - EPS)
		# A wall may also terminate as an anta on the open pastas/courtyard
		# line, where it carries the portico beam.
		if w["orient"] == "v" and ctx["pastas"].size() == 1:
			var p: Rect2 = ctx["pastas"][0]["rect"]
			start_ok = start_ok or (_near(r.position.y, p.end.y) and r.position.x >= p.position.x - EPS and r.end.x <= p.end.x + EPS)
		if not (start_ok and end_ok):
			errors.append("H10: interior wall at (%.2f, %.2f) ends unsupported" % [r.position.x, r.position.y])
	var linked := {}
	var queue: Array = []
	for i in parts.size():
		if parts[i]["wall"] != null and parts[i]["wall"]["kind"] == "exterior":
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

static func _north_rooms(ctx: Dictionary) -> Array:
	return ctx["rooms"].filter(func(r): return r.get("zone", "") == "north")


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


## Every solid (area-bearing) element: spaces, walls and door gaps.
static func _solid_items(house: Dictionary, ctx: Dictionary) -> Array:
	var items: Array = []
	for s in house["spaces"]:
		items.append({"rect": s["rect"], "name": _name(s["id"], ctx)})
	var walls: Array = house["walls"]
	for i in walls.size():
		items.append({"rect": walls[i]["rect"], "name": "wall %d" % i})
	var openings: Array = house["openings"]
	for i in openings.size():
		if openings[i]["kind"] != "open":
			items.append({"rect": openings[i]["rect"], "name": "opening %d" % i})
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


## True when the rectangles share a boundary segment of positive length.
static func _touch(a: Rect2, b: Rect2) -> bool:
	var sx := _span(a.position.x, a.end.x, b.position.x, b.end.x)
	var sy := _span(a.position.y, a.end.y, b.position.y, b.end.y)
	return (sx >= -EPS and sy > EPS) or (sy >= -EPS and sx > EPS)


static func _contains(outer: Rect2, inner: Rect2) -> bool:
	return inner.position.x >= outer.position.x - EPS and inner.position.y >= outer.position.y - EPS \
		and inner.end.x <= outer.end.x + EPS and inner.end.y <= outer.end.y + EPS
