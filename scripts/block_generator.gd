extends RefCounted
## City-block generator: subdivides one user-drawn block polygon into 5 or 6
## house plots and builds a complete house in every plot.
##
## Every edge of the block is a public street. The block is cut by one
## east–west row line into a north row and a south row (or, for a shallow
## block, used as a single row). Each row is divided by straight party walls,
## tilted 22–42° from north–south (H11 forbids right-angled corners), into
## plots that run from the row line to the street. Neighbouring plots share
## the party-wall line exactly; north-row and south-row plots share the row
## line. Each plot therefore has its own street frontage, where its entrance
## is cut; there are no shared passages, courtyards or open spaces.
## North is the same for every house (no house is rotated).
##
## Every house is checked with house_validator.gd (H00–H12, frontage measured
## on the block boundary) and the whole block with block_validator.gd; only a
## block passing both is returned. Six houses are tried first, then five.

const V := preload("res://scripts/house_validator.gd")
const G := preload("res://scripts/geometry.gd")
const H := preload("res://scripts/house_generator.gd")
const BV := preload("res://scripts/block_validator.gd")

const LAYOUT_ATTEMPTS := 30     # subdivisions tried per house count
const HOUSE_ATTEMPTS := 10      # house layouts tried per plot
const MIN_BLOCK_AREA := 600.0   # m²
const MIN_BLOCK_EDGE := 1.0     # m
const PARTY_TILT := Vector2(22.0, 42.0)    # degrees from north–south (room corners stay >= 46°)
# Street-to-street (or street-to-row-line) depths each house type can fill, m.
const ONE_ROW_DEPTH := Vector2(13.5, 20.5)
const NORTH_DEPTH := Vector2(9.2, 16.0)
const SOUTH_DEPTH := Vector2(11.6, 18.5)
const MIN_HOUSE_WIDTH := 12.5              # along the row line, m
const MIN_PLOT_WIDTH := 11.0               # anywhere across the plot's depth, m
const MAX_HOUSE_WIDTH := 22.0              # along the row line, m
const MAX_EDGE_SKEW := 44.0                # plot edges within this of north–south or east–west

static var _why := ""


## "" when the drawn polygon can be used as a block, else the reason.
static func check_block_polygon(poly: PackedVector2Array) -> String:
	if poly.size() < 3:
		return "a block needs at least 3 corners"
	for i in poly.size():
		if poly[i].distance_to(poly[(i + 1) % poly.size()]) < MIN_BLOCK_EDGE:
			return "edge %d is shorter than %.1f m" % [i, MIN_BLOCK_EDGE]
	if self_intersecting(poly):
		return "the outline crosses itself"
	if G.polygon_area(poly) < MIN_BLOCK_AREA:
		return "the block is too small (%.0f m², at least %.0f m²)" % [G.polygon_area(poly), MIN_BLOCK_AREA]
	return ""


static func self_intersecting(poly: PackedVector2Array) -> bool:
	var n := poly.size()
	for i in n:
		for j in range(i + 1, n):
			if j == i + 1 or (i == 0 and j == n - 1):
				continue
			if Geometry2D.segment_intersects_segment(poly[i], poly[(i + 1) % n], poly[j], poly[(j + 1) % n]) != null:
				return true
	return false


## Builds and validates a city block. Returns {ok, block, attempts, reason}.
static func generate_block(poly: PackedVector2Array, block_seed: int) -> Dictionary:
	var problem := check_block_polygon(poly)
	if problem != "":
		return {"ok": false, "block": {}, "attempts": 0, "reason": problem}
	var reasons := {}
	var attempts := 0
	for count in [6, 5]:
		for attempt in LAYOUT_ATTEMPTS:
			attempts += 1
			var rng := RandomNumberGenerator.new()
			rng.seed = hash([block_seed, count, attempt])
			var plots := subdivide(rng, poly, count)
			if plots.is_empty():
				_count(reasons, _why)
				continue
			var houses: Array = []
			for i in plots.size():
				var h := _house_for_plot(rng, plots[i], poly)
				if h.is_empty():
					break
				h["number"] = i + 1
				h["seed"] = block_seed
				houses.append(h)
			if houses.size() != plots.size():
				_count(reasons, "house %d: %s" % [houses.size() + 1, _why])
				continue
			var block := {"polygon": poly, "houses": houses, "plots": plots, "seed": block_seed, "attempt": attempts}
			var check := BV.validate_block(block)
			if check["valid"]:
				block["validation"] = check
				return {"ok": true, "block": block, "attempts": attempts, "reason": ""}
			_count(reasons, "block check: %s" % check["errors"][0])
	var keys := reasons.keys()
	keys.sort_custom(func(a, b): return reasons[a] > reasons[b])
	var summary := "; ".join(keys.slice(0, 3).map(func(k): return "%s (%d×)" % [k, reasons[k]]))
	return {"ok": false, "block": {}, "attempts": attempts,
		"reason": "no valid block of 6 or 5 houses after %d layouts — most common: %s" % [attempts, summary]}


static func _count(reasons: Dictionary, why: String) -> void:
	reasons[why] = reasons.get(why, 0) + 1


static func _house_for_plot(rng: RandomNumberGenerator, plot: Dictionary, poly: PackedVector2Array) -> Dictionary:
	var last := ""
	for k in HOUSE_ATTEMPTS:
		var h := H.build_in_plot(rng, plot["footprint"], poly, plot["kind"])
		if h.is_empty():
			last = H._failure
			continue
		var v := V.validate_house(h)
		if v["valid"]:
			h["validation"] = v
			return h
		last = v["errors"][0]
	_why = last
	return {}


# --------------------------------------------------------------------------
# Subdivision
# --------------------------------------------------------------------------

## Cuts the block into `count` plots: [{footprint, kind, row}] or [] (reason in _why).
static func subdivide(rng: RandomNumberGenerator, poly: PackedVector2Array, count: int) -> Array:
	var box := G.bbox(poly)
	# Street-to-street depth profile every 1.5 m across the block.
	var xs: Array = []
	var x := box.position.x + 0.75
	while x < box.end.x - 0.75:
		xs.append(x)
		x += 1.5
	var tops: Array = xs.map(func(v): return H._y_range(poly, v).x)
	var bottoms: Array = xs.map(func(v): return H._y_range(poly, v).y)
	# Options: one row, or a row line y; each with the longest stretch of the
	# block where every house depth fits. Houses are built only there; the
	# block's ends beyond it stay unbuilt corner ground.
	var per_row := ceili(count / 2.0)
	var options: Array = []   # [row line y or null, x_from, x_to]
	var run := _longest_run(xs, func(i): return _in(bottoms[i] - tops[i], ONE_ROW_DEPTH))
	if run.y - run.x >= count * (MIN_HOUSE_WIDTH + 1.0):
		options.append([null, run.x, run.y])
	var y := snappedf(tops.min() + NORTH_DEPTH.x, 0.05)
	while y <= bottoms.max() - SOUTH_DEPTH.x:
		var yy := y
		run = _longest_run(xs, func(i): return _in(yy - tops[i], NORTH_DEPTH) and _in(bottoms[i] - yy, SOUTH_DEPTH))
		if run.y - run.x >= per_row * (MIN_HOUSE_WIDTH + 1.0):
			options.append([yy, run.x, run.y])
		y += 0.25
	if options.is_empty():
		_why = "no stretch of the block is the right depth for %d houses (one row %.0f–%.0f m deep, or two rows %.0f–%.0f m)" % [
			count, ONE_ROW_DEPTH.x, ONE_ROW_DEPTH.y, NORTH_DEPTH.x + SOUTH_DEPTH.x, NORTH_DEPTH.y + SOUTH_DEPTH.y]
		return []
	# Prefer row lines that keep the north row shallow (wings at most ~5 m deep).
	var shallow := options.filter(func(o): return o[0] == null or o[0] - tops.min() <= NORTH_DEPTH.x + 4.0)
	var pool: Array = shallow if not shallow.is_empty() and rng.randf() < 0.8 else options
	var choice: Array = pool[rng.randi() % pool.size()]
	var span := Vector2(choice[1], choice[2])
	if choice[0] == null:
		return _split_row(rng, poly, box.get_center().y, count, "through", "single row", span)
	var y_s: float = snappedf(choice[0], 0.05)   # row line on the 5 cm grid
	var north := _single(Geometry2D.intersect_polygons(poly, G.rect_poly(Rect2(box.position.x - 1.0, box.position.y - 1.0, box.size.x + 2.0, y_s - box.position.y + 1.0))))
	var south := _single(Geometry2D.intersect_polygons(poly, G.rect_poly(Rect2(box.position.x - 1.0, y_s, box.size.x + 2.0, box.end.y - y_s + 1.0))))
	if north.is_empty() or south.is_empty():
		_why = "the row line splits the block into several pieces"
		return []
	# Share the houses by what each row can hold within the stretch.
	var cap_n := mini(_capacity(north, y_s, true), floori((span.y - span.x) / (MIN_HOUSE_WIDTH + 1.0)))
	var cap_s := mini(_capacity(south, y_s, false), floori((span.y - span.x) / (MIN_HOUSE_WIDTH + 1.0)))
	var splits: Array = []
	for kn in range(1, count):
		if kn <= cap_n and count - kn <= cap_s:
			splits.append(kn)
	if splits.is_empty():
		_why = "rows hold only %d + %d houses" % [cap_n, cap_s]
		return []
	splits.sort_custom(func(p, q): return absi(2 * p - count) < absi(2 * q - count))   # balanced first
	var k_north: int = splits[0] if rng.randf() < 0.7 or splits.size() == 1 else splits[1]
	var plots := _split_row(rng, north, y_s, k_north, "north", "north row", span)
	if plots.is_empty():
		return []
	var south_plots := _split_row(rng, south, y_s, count - k_north, "south", "south row", span)
	return [] if south_plots.is_empty() else plots + south_plots


static func _in(v: float, r: Vector2) -> bool:
	return v >= r.x and v <= r.y


## Longest contiguous x-interval of the samples where ok(i) holds.
static func _longest_run(xs: Array, ok: Callable) -> Vector2:
	var best := Vector2.ZERO
	var start := -1
	for i in xs.size() + 1:
		var good: bool = i < xs.size() and ok.call(i)
		if good and start < 0:
			start = i
		elif not good and start >= 0:
			if xs[i - 1] - xs[start] > best.y - best.x:
				best = Vector2(xs[start], xs[i - 1])
			start = -1
	return best


## Rough number of houses a row can hold: its width on the row line and
## at a quarter of its depth from the street, whichever is less.
static func _capacity(region: PackedVector2Array, y_ref: float, north: bool) -> int:
	var box := G.bbox(region)
	var y_street := box.position.y + 0.25 * box.size.y if north else box.end.y - 0.25 * box.size.y
	var w1 := H._x_range(region, y_ref - 0.01 if north else y_ref + 0.01)
	var w2 := H._x_range(region, y_street)
	return floori(minf(w1.y - w1.x, w2.y - w2.x) / (MIN_HOUSE_WIDTH + 1.0))


## Divides one row into k plots by tilted party-wall lines through points on
## the reference line y_ref. Plots are built west to east; each party wall's
## position and tilt are chosen so the plot it closes passes the H00/H11
## screen. At the two ends the plot first tries to reach the block's own end;
## if a block corner there would break H11, a tilted end wall is set in
## instead and the corner ground stays unbuilt (it borders the street only).
static func _split_row(rng: RandomNumberGenerator, region: PackedVector2Array, y_ref: float, k: int, kind: String, row: String, span: Vector2) -> Array:
	var full := H._x_range(region, y_ref - 0.01 if kind == "north" else y_ref + 0.01)
	# Houses stay within the stretch of the right depth; an end of the row
	# reaches the block's own end only if the stretch does.
	var xr := Vector2(maxf(full.x, span.x), minf(full.y, span.y))
	if xr.y - xr.x > k * MAX_HOUSE_WIDTH:
		# Too long for k houses: keep them together in the middle of the stretch.
		var mid := (xr.x + xr.y) / 2.0
		xr = Vector2(mid - k * MAX_HOUSE_WIDTH / 2.0, mid + k * MAX_HOUSE_WIDTH / 2.0)
	var open_w := xr.x - full.x < 1.0
	var open_e := full.y - xr.y < 1.0
	if xr.y - xr.x < k * MIN_HOUSE_WIDTH:
		_why = "%s too short for %d houses (%.1f m)" % [row, k, xr.y - xr.x]
		return []
	var box := G.bbox(region)
	var y0 := box.position.y - 0.05
	var y1 := box.end.y + 0.05
	var nominal := (xr.y - xr.x) / k
	# End walls first, so the middle party walls share out what is left.
	var west = _choose_end(rng, region, xr, 1.0, nominal, y_ref, y0, y1, open_w)
	var east = _choose_end(rng, region, xr, -1.0, nominal, y_ref, y0, y1, open_e)
	if typeof(west) == TYPE_STRING or typeof(east) == TYPE_STRING:
		_why = "%s: no legal end wall at the %s end" % [row, "west" if typeof(west) == TYPE_STRING else "east"]
		return []
	var a: float = xr.x if west == null else west[0]
	var b: float = xr.y if east == null else east[0]
	if b - a < k * MIN_HOUSE_WIDTH:
		_why = "%s too short for %d houses once its ends are trimmed" % [row, k]
		return []
	var plots: Array = []
	var left = west
	for j in k:
		var rights: Array = [east]
		if j < k - 1:
			rights = []
			var from_x: float = _line_x(left, y_ref, y_ref, a).x if left != null else a
			var target := (b - from_x) / (k - j)
			# Parallel party walls first (parallelogram plots keep their width).
			var lean: float = signf(left[1]) if left != null else 0.0
			for f in [0.0, -0.06, 0.06, -0.12, 0.12, -0.2, 0.2]:
				var x: float = from_x + target * (1.0 + f)
				if x - from_x >= MIN_HOUSE_WIDTH and b - x >= (k - j - 1) * MIN_HOUSE_WIDTH:
					var ts := _tilts(rng)
					# Same leaning as the previous wall first, then the gentlest tilt.
					ts.sort_custom(func(p, q): return (signf(p) == lean and signf(q) != lean) or (signf(p) == signf(q) and absf(p) < absf(q)))
					for t in ts:
						rights.append([x, t])
		var found := false
		for r in rights:
			var fp := _plot_between(region, left, r, y_ref, y0, y1)
			# The east end wall has no neighbour beyond it, so only H11 for this
			# plot applies there; party walls between plots must suit both sides.
			if not fp.is_empty() and _plot_problem(fp) == "" and (j == k - 1 or _shared_corners_ok(fp, r, y_ref)) and _wide_enough(fp):
				if j == k - 2:
					# Look ahead: the last plot, up to the end wall, must work too.
					var last := _plot_between(region, r, east, y_ref, y0, y1)
					if last.is_empty() or _plot_problem(last) != "" or not _wide_enough(last):
						continue
				plots.append({"footprint": fp, "kind": kind, "row": row})
				left = r
				found = true
				break
		if not found:
			_why = "%s plot %d: no party-wall position gives legal corners" % [row, j + 1]
			return []
	return plots


## End wall for one end of a row (dir +1 west, -1 east): none if the block's
## own end makes a legal plot, else the nearest tilted wall 0.5–12 m in from
## the end that does (the corner ground beyond it stays unbuilt). Returns the
## line, null (no wall) or "fail".
static func _choose_end(rng: RandomNumberGenerator, region: PackedVector2Array, xr: Vector2, dir: float, nominal: float, y_ref: float, y0: float, y1: float, may_open: bool):
	var x_end := xr.x if dir > 0.0 else xr.y
	var candidates: Array = []
	var d := rng.randf_range(0.0, 2.0)
	while d <= minf(12.0, nominal):
		for t in _tilts(rng):
			candidates.append([x_end + dir * d, t])
		d += 0.5
	# Half the layouts first try reaching the block's own end, half start with
	# an end wall — so retries explore both when a corner plot cannot hold a house.
	if may_open:
		if rng.randf() < 0.5:
			candidates.push_front(null)
		else:
			candidates.append(null)
	for c in candidates:
		var start: float = x_end if c == null else c[0]
		for t in _tilts(rng):
			var inner := [start + dir * nominal, t]
			var fp := _plot_between(region, c, inner, y_ref, y0, y1) if dir > 0.0 else _plot_between(region, inner, c, y_ref, y0, y1)
			if not fp.is_empty() and _plot_problem(fp) == "":
				return c
	return "fail"


## A plot must stay house-wide over its whole depth (sampled at 20/50/80 %).
static func _wide_enough(fp: PackedVector2Array) -> bool:
	var box := G.bbox(fp)
	for f in [0.2, 0.5, 0.8]:
		var xr := H._x_range(fp, box.position.y + f * box.size.y)
		if xr.y - xr.x < MIN_PLOT_WIDTH:
			return false
	return true


## A party wall is shared: where it meets a street, this plot's corner and the
## neighbour's add up to 180°, so both are legal under H11 only if this one is
## below 70° or above 110°.
static func _shared_corners_ok(fp: PackedVector2Array, line, y_ref: float) -> bool:
	if line == null:
		return true
	var a := _line_x(line, y_ref, y_ref - 100.0, 0.0)
	var b := _line_x(line, y_ref, y_ref + 100.0, 0.0)
	var angles := V.interior_angles(fp)
	for i in fp.size():
		var p := fp[i]
		if Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p) < 1e-3:
			if absf(p.y - y_ref) > 1e-3 and angles[i] >= 70.0 - 0.5 and angles[i] <= 110.0 + 0.5:
				return false
	return true


## Candidate tilts, gentlest first (both leanings at each step, random order).
static func _tilts(rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for t in [22.0, 25.0, 28.0, 31.0, 34.0, 37.0, 40.0]:
		var pair := [t + rng.randf_range(0.0, 2.0), -t - rng.randf_range(0.0, 2.0)]
		if rng.randf() < 0.5:   # seeded (Array.shuffle uses the global RNG)
			pair.reverse()
		out.append_array(pair)
	return out


## Plot between two party lines (null = open towards that end), or [] if the lines cross.
static func _plot_between(region: PackedVector2Array, l, r, y_ref: float, y0: float, y1: float) -> PackedVector2Array:
	var a := _line_x(l, y_ref, y0, -1e4)
	var b := _line_x(r, y_ref, y0, 1e4)
	var c := _line_x(r, y_ref, y1, 1e4)
	var d := _line_x(l, y_ref, y1, -1e4)
	if a.x >= b.x or d.x >= c.x:
		return PackedVector2Array()
	return _clean(_single(Geometry2D.intersect_polygons(region, PackedVector2Array([a, b, c, d]))))


## Point of a party line (or of an open end) at height y.
static func _line_x(line, y_ref: float, y: float, open_x: float) -> Vector2:
	if line == null:
		return Vector2(open_x, y)
	return Vector2(line[0] + (y - y_ref) * tan(deg_to_rad(line[1])), y)


static func _tilt(rng: RandomNumberGenerator) -> float:
	return rng.randf_range(PARTY_TILT.x, PARTY_TILT.y) * (1.0 if rng.randf() < 0.5 else -1.0)


## Quick H00/H11 screen of a plot before a house is built in it.
static func _plot_problem(fp: PackedVector2Array) -> String:
	if fp.size() < 3:
		return "empty plot"
	if fp.size() < V.MIN_SIDES or fp.size() > V.MAX_SIDES:
		return "%d sides" % fp.size()
	for a in V.interior_angles(fp):
		if V.forbidden_angle(a):
			return "corner of %.1f°" % a
	# Rooms are axis-aligned: an edge more than 45° off both axes would cut a
	# room corner sharper than the H06 sliver rule allows.
	for i in fp.size():
		var d := (fp[(i + 1) % fp.size()] - fp[i]).abs()
		var off := rad_to_deg(atan2(minf(d.x, d.y), maxf(d.x, d.y)))
		if off > MAX_EDGE_SKEW:
			return "edge %d runs %.0f° off the axes" % [i, off]
	if G.polygon_area(fp) < 120.0:
		return "too small"
	for i in fp.size():
		if fp[i].distance_to(fp[(i + 1) % fp.size()]) < 1.5:
			return "edge %d shorter than 1.5 m" % i
	for a in V.interior_angles(fp):
		if a < V.MIN_CLIPPED_CORNER + 1.0:
			return "corner of %.1f° would leave a room corner under %.0f°" % [a, V.MIN_CLIPPED_CORNER]
	return ""


static func _single(parts: Array) -> PackedVector2Array:
	return parts[0] if parts.size() == 1 else PackedVector2Array()


## Drops repeated and collinear vertices left by polygon clipping.
static func _clean(poly: PackedVector2Array) -> PackedVector2Array:
	var pts := poly
	var changed := true
	while changed and pts.size() >= 3:
		changed = false
		for i in pts.size():
			var p0 := pts[i - 1]
			var p1 := pts[i]
			var p2 := pts[(i + 1) % pts.size()]
			if p0.distance_to(p1) < 0.005 or absf((p1 - p0).normalized().cross((p2 - p1).normalized())) < 1e-4:
				pts.remove_at(i)
				changed = true
				break
	return pts
