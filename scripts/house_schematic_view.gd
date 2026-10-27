extends Control
## Coordinate schematic at two levels. Block level: the drawn block outline
## (B0, B1, …), every house footprint, the party walls between plots, street
## entrances and unbuilt corner ground; click a house to select it.
## House level: a technical top-down drawing of one validated house
## with X/Y rulers, a metre grid, labelled exterior vertices (P0, P1, …), edge
## lengths, interior angles, room outlines, walls and door openings, plus a
## scrollable inspection panel. Click a room, courtyard, wall or vertex to
## inspect it.
##
## Everything is drawn straight from the house Dictionary — the same data the
## validator checked and the 3D view turns into meshes — and measured with
## geometry.gd. There is no separate schematic coordinate system: global
## coordinates are the data's own; local ones are a pure translation by the
## footprint bounding box's top-left corner.

signal house_clicked(index: int)

const G := preload("res://scripts/geometry.gd")
const V := preload("res://scripts/house_validator.gd")

const NARROW := 760.0          # below this width the panel goes under the drawing
const PANEL_WIDTH := 340.0
const MARGIN := 60.0           # room for the rulers and outer labels, pixels
const COMPACT_SCALE := 28.0    # px per metre below which on-plan labels are shortened
const PAPER := Color(0.97, 0.98, 1.0)
const GRID := Color(0.62, 0.72, 0.85, 0.35)
const GRID_MAJOR := Color(0.45, 0.58, 0.78, 0.55)
const INK := Color(0.08, 0.10, 0.16)
const DIM := Color(0.15, 0.30, 0.60)
const BAD := Color(0.8, 0.1, 0.1)
const OK := Color(0.1, 0.5, 0.2)
const SELECT := Color(1.0, 0.5, 0.0)
const FILLS := {
	"room": Color(1, 1, 1, 0.9),
	"courtyard": Color(0.70, 0.86, 0.62, 0.9),
	"pastas": Color(0.95, 0.84, 0.58, 0.9),
	"passage": Color(0.88, 0.88, 0.88, 0.9),
}

var level := "house"           # "house" or "block"
var block: Dictionary = {}
var block_selected := -1
var _bm: Dictionary = {}       # measurements of the current block (cached)
var house: Dictionary = {}
var house_label := ""
var selected: Dictionary = {}  # {} or {kind: "space"|"wall"|"vertex", index: int}
var info: RichTextLabel        # inspection panel text
var panel: ScrollContainer

var _m: Dictionary = {}        # measurements of the current house (cached)
var _xf := Transform2D()       # world (metres) -> screen (pixels)
var _plan := Rect2()


func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	panel = ScrollContainer.new()
	panel.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(panel)
	info = RichTextLabel.new()
	info.bbcode_enabled = true
	info.fit_content = true
	info.selection_enabled = true
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_font_size_override("normal_font_size", 12)
	info.add_theme_font_size_override("bold_font_size", 13)
	info.add_theme_color_override("default_color", INK)
	panel.add_child(info)
	resized.connect(_layout)


## Shows a validated house (no geometry is generated or changed). Anything
## without a passing validation result is refused.
func show_house(h: Dictionary, label: String) -> bool:
	level = "house"
	house_label = label
	if not is_same(h, house):
		house = {}
		_m = {}
		selected = {}
		if not h.is_empty() and h.get("validation", {}).get("valid", false):
			house = h
			_m = measure(h)
	_update_info()
	_layout()
	return not house.is_empty()


## Block level: the drawn block and all its houses (a validated block only).
func show_block(b: Dictionary, sel: int) -> bool:
	level = "block"
	if not is_same(b, block):
		block = {}
		_bm = {}
		if not b.is_empty() and b.get("validation", {}).get("valid", false):
			block = b
			_bm = measure_block(b)
	block_selected = sel
	_update_info()
	_layout()
	return not block.is_empty()


func world_to_screen(p: Vector2) -> Vector2:
	return _xf * p


func screen_to_world(p: Vector2) -> Vector2:
	return _xf.affine_inverse() * p


# --------------------------------------------------------------------------
# Measurements (once per house, all from the stored geometry)
# --------------------------------------------------------------------------

static func measure(h: Dictionary) -> Dictionary:
	var fp: PackedVector2Array = h["footprint"]
	var m := {
		"footprint": fp,
		"origin": G.local_origin(h),
		"bounds": G.bbox(fp),
		"angles": G.interior_angles(fp),
		"edges": G.edge_lengths(fp),
		"area": G.polygon_area(fp),
		"frontage": V.street_frontage(h),
		"spaces": [],
		"walls": [],
		"doors": [],
	}
	var openings: Array = h["openings"]
	for i in openings.size():
		var o: Dictionary = openings[i]
		var r: Rect2 = o["rect"]
		var c := r.get_center()
		var seg := [Vector2(r.position.x, c.y), Vector2(r.end.x, c.y)] if o["axis"] == "ns" \
			else [Vector2(c.x, r.position.y), Vector2(c.x, r.end.y)]
		var thickness := r.size.y if o["axis"] == "ns" else r.size.x
		if o.has("poly"):
			# Gap through a slanted wall: the segment joins the mid-points of its
			# two jambs (the edges along the direction of travel).
			var pts: PackedVector2Array = o["poly"]
			var mids: Array = []
			var face := 0.0
			for k in pts.size():
				var a := pts[k]
				var b := pts[(k + 1) % pts.size()]
				var along := absf(b.x - a.x) < 1e-3 if o["axis"] == "ns" else absf(b.y - a.y) < 1e-3
				if along:
					mids.append((a + b) / 2.0)
				else:
					face = maxf(face, a.distance_to(b))
			if mids.size() == 2:
				seg = mids
				thickness = G.polygon_area(pts) / face
		m["doors"].append({"index": i, "kind": o["kind"], "a": o["a"], "b": o["b"], "rect": r, "shape": G.shape(o), "start": seg[0], "end": seg[1],
			"width": absf((seg[1] - seg[0]).x) if o["axis"] == "ns" else absf((seg[1] - seg[0]).y), "thickness": thickness})
	for sp in h["spaces"]:
		var shape := G.shape(sp)
		m["spaces"].append({"id": sp["id"], "kind": sp["kind"], "name": space_name(sp), "shape": shape,
			"polygonal": sp.has("poly"), "rect": sp["rect"], "area": G.polygon_area(shape),
			"centroid": G.centroid(shape),
			"doors": m["doors"].filter(func(d): return d["a"] == sp["id"] or d["b"] == sp["id"])})
	var walls: Array = h["walls"]
	for i in walls.size():
		m["walls"].append(wall_axis(walls[i], i))
	return m


static func measure_block(b: Dictionary) -> Dictionary:
	var poly: PackedVector2Array = b["polygon"]
	var houses: Array = b["houses"]
	var m := {"polygon": poly, "bounds": G.bbox(poly), "angles": G.interior_angles(poly), "edges": G.edge_lengths(poly),
		"area": G.polygon_area(poly), "houses": [], "party": [], "residual": b["validation"].get("residual_area", 0.0)}
	for i in houses.size():
		var h: Dictionary = houses[i]
		var fp: PackedVector2Array = h["footprint"]
		var entrances: Array = []
		var ctx := {"footprint": fp, "by_id": {}}
		for sp in h["spaces"]:
			ctx["by_id"][sp["id"]] = sp
		for op in h["openings"]:
			if op["kind"] == "entrance":
				var face := V._street_face(op, ctx)
				if not face.is_empty():
					entrances.append(face)
		var court: Array = h["spaces"].filter(func(sp): return sp["kind"] == "courtyard")
		m["houses"].append({"index": i, "footprint": fp, "area": G.polygon_area(fp), "sides": h["validation"]["sides"],
			"angles": G.interior_angles(fp), "frontage": V.street_frontage(h), "entrances": entrances,
			"court": G.shape(court[0]) if not court.is_empty() else PackedVector2Array(),
			"court_area": G.item_area(court[0]) if not court.is_empty() else 0.0, "row": h.get("plot_kind", "")})
	# Party walls: stretches where two footprints share a boundary line.
	for i in houses.size():
		for j in range(i + 1, houses.size()):
			for seg in _shared_segments(houses[i]["footprint"], houses[j]["footprint"]):
				m["party"].append({"a": seg[0], "b": seg[1], "houses": [i, j]})
	return m


## Overlapping stretches of collinear edges of two polygons.
static func _shared_segments(p: PackedVector2Array, q: PackedVector2Array) -> Array:
	var out: Array = []
	for i in p.size():
		var a := p[i]
		var b := p[(i + 1) % p.size()]
		var u := (b - a).normalized()
		for j in q.size():
			var c := q[j]
			var d := q[(j + 1) % q.size()]
			if absf(u.cross(c - a)) > 1e-3 or absf(u.cross(d - a)) > 1e-3:
				continue   # not on the same line
			var t0 := maxf(0.0, minf(u.dot(c - a), u.dot(d - a)))
			var t1 := minf(a.distance_to(b), maxf(u.dot(c - a), u.dot(d - a)))
			if t1 - t0 > 0.01:
				out.append([a + u * t0, a + u * t1])
	return out


## Centreline start/end, thickness and length of a wall record. A mitred
## exterior quad is [outer start, outer end, inner end, inner start]; its
## thickness is measured as the inner face's distance from the outer face.
static func wall_axis(w: Dictionary, index: int) -> Dictionary:
	var r: Rect2 = w["rect"]
	var a: Vector2
	var b: Vector2
	var t: float
	if w["kind"] == "exterior" and w.has("poly") and w["poly"].size() == 4:
		var p: PackedVector2Array = w["poly"]
		a = (p[0] + p[3]) / 2.0
		b = (p[1] + p[2]) / 2.0
		t = absf((p[1] - p[0]).normalized().cross(p[3] - p[0]))
	elif w["orient"] == "h":
		a = Vector2(r.position.x, r.get_center().y)
		b = Vector2(r.end.x, r.get_center().y)
		t = r.size.y
	else:
		a = Vector2(r.get_center().x, r.position.y)
		b = Vector2(r.get_center().x, r.end.y)
		t = r.size.x
	return {"index": index, "kind": w["kind"], "start": a, "end": b, "thickness": t,
		"length": a.distance_to(b), "shape": G.shape(w), "trimmed": w["kind"] == "interior" and w.has("poly")}


static func space_name(sp: Dictionary) -> String:
	match sp["kind"]:
		"room": return "#%d %s" % [sp["id"], sp.get("type", "Room")]
		"courtyard": return "#%d Courtyard" % sp["id"]
		"pastas": return "#%d Pastas" % sp["id"]
		"passage": return "#%d Entrance passage" % sp["id"]
	return "#%d" % sp["id"]


# --------------------------------------------------------------------------
# Layout, drawing and picking
# --------------------------------------------------------------------------

func _layout() -> void:
	if size.x >= NARROW:
		panel.position = Vector2(size.x - PANEL_WIDTH, 0.0)
		panel.size = Vector2(PANEL_WIDTH, size.y)
		_plan = Rect2(Vector2.ZERO, Vector2(size.x - PANEL_WIDTH - 6.0, size.y))
	else:
		var h := maxf(120.0, size.y * 0.42)
		panel.position = Vector2(0.0, size.y - h)
		panel.size = Vector2(size.x, h)
		_plan = Rect2(Vector2.ZERO, Vector2(size.x, size.y - h - 6.0))
	if level == "block" and not _bm.is_empty():
		_xf = G.fit_transform(_bm["bounds"], _plan, MARGIN)
	elif level == "house" and not _m.is_empty():
		_xf = G.fit_transform(_m["bounds"], _plan, MARGIN)
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(_plan, PAPER)
	draw_rect(_plan, Color(INK, 0.4), false, 1.0)
	if level == "block":
		_draw_block(font)
		return
	if _m.is_empty():
		draw_string(font, _plan.position + Vector2(12, 24), "No validated house to show.", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, BAD)
		return
	_draw_grid(font)
	for sp in _m["spaces"]:
		draw_colored_polygon(_px(sp["shape"]), FILLS[sp["kind"]])
		if sp["kind"] in ["courtyard", "pastas"]:
			_hatch(sp["shape"], Color(INK, 0.18))
		draw_polyline(_closed(_px(sp["shape"])), Color(INK, 0.55), 1.0)
	for w in _m["walls"]:
		draw_colored_polygon(_px(w["shape"]), Color(0.25, 0.27, 0.32) if w["kind"] == "exterior" else Color(0.55, 0.57, 0.62))
	for d in _m["doors"]:
		if d["kind"] == "open":
			draw_dashed_line(world_to_screen(d["start"]), world_to_screen(d["end"]), Color(INK, 0.8), 1.5, 6.0)
			continue
		draw_colored_polygon(_px(d["shape"]), PAPER)
		var a := world_to_screen(d["start"])
		var b := world_to_screen(d["end"])
		draw_line(a, b, BAD, 2.0)
		var n := (b - a).orthogonal().normalized() * 4.0
		draw_line(a - n, a + n, BAD, 1.5)
		draw_line(b - n, b + n, BAD, 1.5)
		draw_string(font, (a + b) / 2.0 + n * 2.0 + Vector2(-8, 4), "D%d" % d["index"], HORIZONTAL_ALIGNMENT_LEFT, -1, 9, BAD)
	_draw_footprint(font)
	for sp in _m["spaces"]:
		# Full name and area when they fit the space, otherwise just its ID.
		var c := world_to_screen(sp["centroid"])
		var room_px := G.bbox(_px(sp["shape"])).size.x - 6.0
		var name: String = sp["name"]
		if font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x > room_px:
			name = "#%d" % sp["id"]
		_text(font, c + Vector2(0, -2), name, 11, INK)
		if font.get_string_size("00.00 m²", HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x <= room_px:
			_text(font, c + Vector2(0, 11), "%.2f m²" % sp["area"], 10, INK)
	_draw_selection()
	_draw_north(font)


func _draw_block(font: Font) -> void:
	if _bm.is_empty():
		draw_string(font, _plan.position + Vector2(12, 24), "No validated city block to show.", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, BAD)
		return
	_draw_grid(font)
	var poly: PackedVector2Array = _bm["polygon"]
	var compact := _xf.x.x < COMPACT_SCALE * 0.5
	draw_colored_polygon(_px(poly), Color(0.86, 0.82, 0.72, 0.6))   # unbuilt ground shows through
	for h in _bm["houses"]:
		var sel: bool = h["index"] == block_selected
		draw_colored_polygon(_px(h["footprint"]), Color(SELECT, 0.25) if sel else Color(1, 1, 1, 0.9))
		if not h["court"].is_empty():
			draw_colored_polygon(_px(h["court"]), FILLS["courtyard"])
			_hatch(h["court"], Color(INK, 0.18))
		draw_polyline(_closed(_px(h["footprint"])), SELECT if sel else Color(INK, 0.8), 3.0 if sel else 1.5)
	for pw in _bm["party"]:
		draw_line(world_to_screen(pw["a"]), world_to_screen(pw["b"]), Color(0.45, 0.2, 0.55), 3.0)
	draw_polyline(_closed(_px(poly)), INK, 2.5)
	for h in _bm["houses"]:
		for e in h["entrances"]:
			var a := world_to_screen(e[0])
			var b := world_to_screen(e[1])
			draw_line(a, b, BAD, 5.0)
		var c := world_to_screen(G.centroid(h["footprint"]))
		_text(font, c + Vector2(0, -2), "H%d" % (h["index"] + 1), 14, INK)
		_text(font, c + Vector2(0, 13), "%.1f m²" % h["area"], 10, INK)
	var bc := G.centroid(poly)
	for i in poly.size():
		var p := world_to_screen(poly[i])
		var out := (poly[i] - bc).normalized()
		draw_circle(p, 3.5, INK)
		_text(font, p + out * Vector2(30.0 if not compact else 12.0, 14.0) + Vector2(0, 4),
			"B%d" % i if compact else "B%d (%.2f, %.2f)" % [i, poly[i].x, poly[i].y], 11, INK)
	draw_string(font, Vector2(_plan.position.x + 26, _plan.end.y - 22), "purple = party walls · red = street entrances · grey = unbuilt corner ground",
		HORIZONTAL_ALIGNMENT_LEFT, _plan.size.x - 40, 10, DIM)
	_draw_north(font)


func _draw_grid(font: Font) -> void:
	var s := _xf.x.x
	var step := 1.0 if s >= 14.0 else (2.0 if s >= 7.0 else 5.0)
	var tl := screen_to_world(_plan.position)
	var br := screen_to_world(_plan.end)
	var x := ceilf(tl.x / step) * step
	while x <= br.x:
		var sx := world_to_screen(Vector2(x, 0)).x
		var major := is_zero_approx(fmod(absf(x), 5.0))
		draw_line(Vector2(sx, _plan.position.y + 16), Vector2(sx, _plan.end.y), GRID_MAJOR if major else GRID, 1.0)
		if major or step >= 2.0:
			draw_string(font, Vector2(sx - 15, _plan.position.y + 12), "%d" % roundi(x), HORIZONTAL_ALIGNMENT_CENTER, 30, 10, DIM)
		x += step
	var y := ceilf(tl.y / step) * step
	while y <= br.y:
		var sy := world_to_screen(Vector2(0, y)).y
		var major := is_zero_approx(fmod(absf(y), 5.0))
		draw_line(Vector2(_plan.position.x + 22, sy), Vector2(_plan.end.x, sy), GRID_MAJOR if major else GRID, 1.0)
		if major or step >= 2.0:
			draw_string(font, Vector2(_plan.position.x + 2, sy + 4), "%d" % roundi(y), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, DIM)
		y += step
	draw_string(font, Vector2(_plan.position.x + 26, _plan.position.y + 28), "X (m, east) →", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, DIM)
	draw_string(font, Vector2(_plan.position.x + 26, _plan.position.y + 42), "Y (m, south) ↓", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, DIM)
	var o := world_to_screen(Vector2.ZERO)
	if _plan.grow(-2).has_point(o):
		draw_circle(o, 3.0, DIM)
		var outline: PackedVector2Array = _m["footprint"] if not _m.is_empty() else _bm.get("polygon", PackedVector2Array())
		if not Array(outline).any(func(p): return p.distance_to(Vector2.ZERO) < 0.5):
			draw_string(font, o + Vector2(5, -4), "(0, 0)", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, DIM)
	# Scale bar: 0–1–5 m.
	var base := Vector2(_plan.position.x + 26, _plan.end.y - 12)
	draw_line(base, base + Vector2(5.0 * s, 0), INK, 2.0)
	for t in [0.0, 1.0, 5.0]:
		draw_line(base + Vector2(t * s, -4), base + Vector2(t * s, 4), INK, 1.5)
		draw_string(font, base + Vector2(t * s - 10, -6), "%d m" % roundi(t) if t > 0.0 else "0", HORIZONTAL_ALIGNMENT_CENTER, 20, 9, INK)


func _draw_footprint(font: Font) -> void:
	var fp: PackedVector2Array = _m["footprint"]
	var compact := _xf.x.x < COMPACT_SCALE   # small screens: coordinates live in the panel
	draw_polyline(_closed(_px(fp)), INK, 2.5)
	var c := G.centroid(fp)
	for i in fp.size():
		var p := world_to_screen(fp[i])
		var out := (fp[i] - c).normalized()
		draw_circle(p, 3.5, INK)
		var tag := "P%d" % i if compact else "P%d (%.2f, %.2f)" % [i, fp[i].x, fp[i].y]
		_text(font, p + out * Vector2(28.0 if not compact else 12.0, 14.0) + Vector2(0, 4), tag, 11, INK)
		var angle: float = _m["angles"][i]
		var bad := V.forbidden_angle(angle)
		_text(font, p - out * 44.0 + Vector2(0, 4), "%.1f°" % angle if compact else "%.2f°" % angle, 10, BAD if bad else OK)
		# Edge length outside the midpoint of edge i (Pi -> Pi+1).
		var a := fp[i]
		var b := fp[(i + 1) % fp.size()]
		var mid := (a + b) / 2.0
		var nrm := (b - a).orthogonal().normalized()
		if G.point_in_polygon(mid + nrm * 0.05, fp):
			nrm = -nrm
		_text(font, world_to_screen(mid) + nrm * 22.0 + Vector2(0, 4), "%.2f m" % _m["edges"][i], 10, DIM)


## Draws text centred on `at`, kept inside the drawing area.
func _text(font: Font, at: Vector2, text: String, font_size: int, color: Color) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var x := clampf(at.x - w / 2.0, _plan.position.x + 2.0, _plan.end.x - w - 2.0)
	var y := clampf(at.y, _plan.position.y + font_size + 2.0, _plan.end.y - 3.0)
	draw_string(font, Vector2(x, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _draw_selection() -> void:
	if selected.is_empty():
		return
	match selected["kind"]:
		"space":
			var sp: Dictionary = _m["spaces"][selected["index"]]
			draw_colored_polygon(_px(sp["shape"]), Color(SELECT, 0.25))
			draw_polyline(_closed(_px(sp["shape"])), SELECT, 3.0)
		"wall":
			draw_polyline(_closed(_px(_m["walls"][selected["index"]]["shape"])), SELECT, 3.0)
		"vertex":
			draw_arc(world_to_screen(_m["footprint"][selected["index"]]), 8.0, 0.0, TAU, 24, SELECT, 2.5)


func _draw_north(font: Font) -> void:
	var at := Vector2(_plan.end.x - 22, _plan.position.y + 40)
	draw_colored_polygon(PackedVector2Array([at + Vector2(0, -14), at + Vector2(7, 8), at + Vector2(-7, 8)]), INK)
	draw_string(font, at + Vector2(-10, 22), "N", HORIZONTAL_ALIGNMENT_CENTER, 20, 12, INK)


func _hatch(poly: PackedVector2Array, color: Color) -> void:
	var box := G.bbox(poly)
	var d := -box.size.y
	while d < box.size.x:
		var a := box.position + Vector2(d, 0)
		var b := a + Vector2(box.size.y, box.size.y)
		for part in Geometry2D.intersect_polyline_with_polygon(PackedVector2Array([a, b]), poly):
			draw_polyline(_px(part), color, 1.0)
		d += 0.5


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		select_at(event.position)
		accept_event()


## Selects whatever lies under a screen point: a footprint vertex (within
## 9 px), else a space, else a wall; empty space clears the selection.
func select_at(screen_pos: Vector2) -> Dictionary:
	if level == "block":
		if _bm.is_empty() or not _plan.has_point(screen_pos):
			return {}
		var wp := screen_to_world(screen_pos)
		for h in _bm["houses"]:
			if G.point_in_polygon(wp, h["footprint"]):
				block_selected = h["index"]
				_update_info()
				queue_redraw()
				house_clicked.emit(block_selected)
				return {"kind": "house", "index": block_selected}
		return {}
	if _m.is_empty() or not _plan.has_point(screen_pos):
		return selected
	selected = {}
	var p := screen_to_world(screen_pos)
	var fp: PackedVector2Array = _m["footprint"]
	for i in fp.size():
		if world_to_screen(fp[i]).distance_to(screen_pos) <= 9.0:
			selected = {"kind": "vertex", "index": i}
	if selected.is_empty():
		for i in _m["spaces"].size():
			if G.point_in_polygon(p, _m["spaces"][i]["shape"]):
				selected = {"kind": "space", "index": i}
	if selected.is_empty():
		for i in _m["walls"].size():
			if G.point_in_polygon(p, _m["walls"][i]["shape"]):
				selected = {"kind": "wall", "index": i}
	_update_info()
	queue_redraw()
	return selected


func _px(poly: PackedVector2Array) -> PackedVector2Array:
	return _xf * poly


static func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := pts.duplicate()
	out.append(pts[0])
	return out


# --------------------------------------------------------------------------
# Inspection panel
# --------------------------------------------------------------------------

func _update_info() -> void:
	info.text = inspection_text()
	panel.scroll_vertical = 0


## Full panel text (BBCode); numbers shown to two decimals, data untouched.
func inspection_text() -> String:
	if level == "block":
		return _block_text()
	if _m.is_empty():
		return "[b]%s[/b]\n[color=#c01a1a]No validated house — nothing to inspect.[/color]" % house_label
	var t := PackedStringArray()
	if not selected.is_empty():
		t.append("[b]Selected[/b]")
		t.append_array(_selected_lines())
		t.append("")
	var h := house
	var court: Array = _m["spaces"].filter(func(s): return s["kind"] == "courtyard")
	var front: Dictionary = _m["frontage"]
	var origin: Vector2 = _m["origin"]
	t.append("[b]House[/b]")
	t.append("%s · seed %d" % [house_label, h["seed"]])
	t.append("Validation: [color=#1a7f33]VALID H00–H12[/color]" if h["validation"]["valid"] else "Validation: [color=#c01a1a]INVALID[/color]")
	t.append("Exterior sides: %d (%s)" % [h["validation"]["sides"], h["shape"]])
	t.append("Footprint area: %.2f m²" % _m["area"])
	t.append("Courtyard area: %.2f m² (required 16.00)" % (court[0]["area"] if not court.is_empty() else 0.0))
	t.append("Rooms: %d" % _m["spaces"].filter(func(s): return s["kind"] == "room").size())
	t.append("Street frontage (H12.1): P%d–P%d, %.2f m (min %.1f m)" % [front["edge"], (front["edge"] + 1) % _m["footprint"].size(), front["length"], V.MIN_STREET_FRONTAGE])
	t.append("Global = house data coordinates (m). Local = global − (%.2f, %.2f), translation only." % [origin.x, origin.y])
	t.append("")
	t.append("[b]Exterior polygon[/b]")
	var fp: PackedVector2Array = _m["footprint"]
	for i in fp.size():
		var a: float = _m["angles"][i]
		var l := G.to_local(fp[i], h)
		t.append("P%d: (%.2f, %.2f) · local (%.2f, %.2f) · angle %s" % [i, fp[i].x, fp[i].y, l.x, l.y,
			("[color=#c01a1a]%.2f° H11 FAIL[/color]" if V.forbidden_angle(a) else "%.2f°") % a])
	for i in fp.size():
		t.append("Edge P%d–P%d: %.2f m" % [i, (i + 1) % fp.size(), _m["edges"][i]])
	t.append("")
	for kind in ["courtyard", "pastas", "passage", "room"]:
		for sp in _m["spaces"].filter(func(s): return s["kind"] == kind):
			t.append("[b]%s[/b]" % sp["name"])
			t.append_array(_space_lines(sp))
			t.append("")
	t.append("[b]Doors and openings[/b]")
	for d in _m["doors"]:
		t.append(_door_line(d))
	t.append("")
	t.append("[b]Walls[/b] (centreline start → end)")
	for w in _m["walls"]:
		t.append(_wall_line(w))
	return "\n".join(t)


func _block_text() -> String:
	if _bm.is_empty():
		return "[color=#c01a1a]No validated city block — nothing to inspect.[/color]"
	var t := PackedStringArray()
	var poly: PackedVector2Array = _bm["polygon"]
	if block_selected >= 0 and block_selected < _bm["houses"].size():
		t.append("[b]Selected[/b]")
		t.append_array(_house_summary(_bm["houses"][block_selected]))
		t.append("Use \"Selected House\" for its rooms, walls and doors.")
		t.append("")
	var v: Dictionary = block["validation"]
	t.append("[b]City block[/b] · seed %d" % block["seed"])
	t.append("Validation: [color=#1a7f33]VALID — block rules B00–B07 and H00–H12 for every house[/color]" if v["valid"] else "Validation: [color=#c01a1a]INVALID[/color]")
	t.append("Houses: %d · block %.2f m² · built %.2f m² · unbuilt corner ground %.2f m²" % [
		_bm["houses"].size(), _bm["area"], _bm["area"] - _bm["residual"], _bm["residual"]])
	t.append("Every block edge is a street; no shared passages, courtyards or open spaces.")
	t.append("")
	t.append("[b]Block polygon[/b] (global coordinates, m)")
	for i in poly.size():
		t.append("B%d: (%.2f, %.2f) · angle %.2f°" % [i, poly[i].x, poly[i].y, _bm["angles"][i]])
	for i in poly.size():
		t.append("Edge B%d–B%d: %.2f m" % [i, (i + 1) % poly.size(), _bm["edges"][i]])
	t.append("")
	t.append("[b]Houses[/b]")
	for h in _bm["houses"]:
		t.append_array(_house_summary(h))
		t.append("")
	t.append("[b]Party walls between plots[/b]")
	for pw in _bm["party"]:
		t.append("H%d | H%d: (%.2f, %.2f) → (%.2f, %.2f), %.2f m" % [pw["houses"][0] + 1, pw["houses"][1] + 1,
			pw["a"].x, pw["a"].y, pw["b"].x, pw["b"].y, pw["a"].distance_to(pw["b"])])
	return "\n".join(t)


func _house_summary(h: Dictionary) -> Array:
	var fp: PackedVector2Array = h["footprint"]
	var pts := PackedStringArray()
	for i in fp.size():
		pts.append("P%d (%.2f, %.2f) %.1f°" % [i, fp[i].x, fp[i].y, h["angles"][i]])
	var out: Array = ["[color=#d06000]House %d[/color] · %s · %d sides · %.2f m² · courtyard %.2f m²" % [
		h["index"] + 1, {"north": "north row", "south": "south row", "through": "single row"}.get(h["row"], ""), h["sides"], h["area"], h["court_area"]]]
	out.append("Footprint: " + ", ".join(pts))
	var f: Dictionary = h["frontage"]
	out.append("Street frontage %.2f m: (%.2f, %.2f) → (%.2f, %.2f)" % [f["length"], f["a"].x, f["a"].y, f["b"].x, f["b"].y])
	for e in h["entrances"]:
		out.append("Entrance on the block perimeter: (%.2f, %.2f) → (%.2f, %.2f), %.2f m" % [e[0].x, e[0].y, e[1].x, e[1].y, e[0].distance_to(e[1])])
	return out


func _selected_lines() -> Array:
	match selected["kind"]:
		"space":
			var sp: Dictionary = _m["spaces"][selected["index"]]
			return ["[color=#d06000]%s[/color]" % sp["name"]] + _space_lines(sp)
		"wall":
			return [_wall_line(_m["walls"][selected["index"]])]
		"vertex":
			var i: int = selected["index"]
			var fp: PackedVector2Array = _m["footprint"]
			var n := fp.size()
			return ["P%d: (%.2f, %.2f), interior angle %.2f°" % [i, fp[i].x, fp[i].y, _m["angles"][i]],
				"Edges: P%d–P%d %.2f m, P%d–P%d %.2f m" % [(i - 1 + n) % n, i, _m["edges"][(i - 1 + n) % n], i, (i + 1) % n, _m["edges"][i]]]
	return []


func _space_lines(sp: Dictionary) -> Array:
	var out: Array = []
	var r: Rect2 = sp["rect"]
	if sp["polygonal"]:
		var pts := PackedStringArray()
		for p in sp["shape"]:
			pts.append("(%.2f, %.2f)" % [p.x, p.y])
		out.append("Polygon, %d vertices: %s" % [pts.size(), ", ".join(pts)])
		out.append("Extent: (%.2f, %.2f) to (%.2f, %.2f)" % [r.position.x, r.position.y, r.end.x, r.end.y])
	else:
		out.append("Rectangle at (%.2f, %.2f) to (%.2f, %.2f)" % [r.position.x, r.position.y, r.end.x, r.end.y])
		out.append("Width × depth: %.2f × %.2f m" % [r.size.x, r.size.y])
	out.append("Area: %.2f m²%s" % [sp["area"], " (shoelace)" if sp["polygonal"] else ""])
	if sp["kind"] == "pastas":
		var court: Dictionary = _m["spaces"].filter(func(s): return s["kind"] == "courtyard")[0]
		out.append("Clear depth (N–S): %.2f m; courtyard below along y = %.2f; northern wing above, behind the wall at y = %.2f–%.2f"
			% [r.size.y, court["rect"].position.y, r.position.y - V.INT_WALL, r.position.y])
	for d in sp["doors"]:
		out.append(_door_line(d))
	return out


func _door_line(d: Dictionary) -> String:
	var names := []
	for id in [d["a"], d["b"]]:
		if id == V.STREET:
			names.append("street")
		else:
			names.append(_m["spaces"].filter(func(s): return s["id"] == id)[0]["name"])
	var kind: String = {"door": "Door", "entrance": "Entrance", "open": "Open edge"}[d["kind"]]
	return "D%d %s %s ↔ %s: (%.2f, %.2f) to (%.2f, %.2f), width %.2f m, wall %.2f m" % [d["index"], kind, names[0], names[1],
		d["start"].x, d["start"].y, d["end"].x, d["end"].y, d["width"], d["thickness"]]


func _wall_line(w: Dictionary) -> String:
	return "W%d %s: (%.2f, %.2f) → (%.2f, %.2f), %.2f m long, %.2f m thick%s" % [w["index"], w["kind"],
		w["start"].x, w["start"].y, w["end"].x, w["end"].y, w["length"], w["thickness"],
		" (end trimmed by the slanted exterior wall)" if w["trimmed"] else ""]
