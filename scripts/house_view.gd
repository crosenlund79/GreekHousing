extends Control
## Draws one generated house plan. Rendering only: it reads the structured
## house data and never generates or validates geometry itself.
## The plan is scaled uniformly to fit the control, so it never distorts.

const INK := Color(0.16, 0.13, 0.11)
const PAPER := Color(0.99, 0.98, 0.95)
const EXT_WALL_COLOR := Color(0.23, 0.18, 0.15)
const INT_WALL_COLOR := Color(0.42, 0.35, 0.29)
const ENTRANCE_COLOR := Color(0.7, 0.2, 0.1)
const SPACE_COLORS := {
	"room": Color(0.97, 0.93, 0.84),
	"courtyard": Color(0.78, 0.86, 0.66),
	"pastas": Color(0.86, 0.81, 0.71),
	"passage": Color(0.91, 0.87, 0.78),
}
const SHORT_LABELS := {
	"Domestic room": "Room", "Kitchen / hearth": "Hearth", "Storage": "Store",
	"Andron": "Andron", "Workroom": "Work", "Courtyard": "Court",
}

var result: Dictionary = {}
var house_number := 0
var house_count := 0

var _scale := 1.0
var _origin := Vector2.ZERO


func _ready() -> void:
	resized.connect(queue_redraw)


func show_result(r: Dictionary, number: int, count: int) -> void:
	result = r
	house_number = number
	house_count = count
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), PAPER)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.72, 0.68, 0.6), false, 1.0)
	if result.is_empty():
		return
	var heading := "House %d / %d" % [house_number, house_count]
	if not result.get("ok", false) or not result["house"].get("validation", {}).get("valid", false):
		_draw_heading(font, heading, "")
		_draw_failure(font)   # never show an unvalidated house as a plan
		return
	var house: Dictionary = result["house"]
	var sides: int = house["validation"]["sides"]   # derived from geometry by the validator
	_draw_heading(font, heading, "%d exterior sides · %s" % [sides, house["shape"]])

	var fp: PackedVector2Array = house["footprint"]
	var bounds := _bbox(fp)
	var top := 58.0
	var bottom := 66.0
	var side := 40.0
	var avail := Vector2(size.x - 2.0 * side, size.y - top - bottom)
	if avail.x < 40.0 or avail.y < 40.0:
		return
	_scale = minf(avail.x / bounds.size.x, avail.y / bounds.size.y)
	_origin = Vector2(side, top) + (avail - bounds.size * _scale) / 2.0 - bounds.position * _scale

	var by_id := {}
	for sp in house["spaces"]:
		by_id[sp["id"]] = sp
		_fill(sp, SPACE_COLORS.get(sp["kind"], Color.WHITE))

	for op in house["openings"]:
		var r := _px(op["rect"])
		if op["kind"] == "open":
			# Roof edge of the pastas, open to the courtyard along its length.
			draw_dashed_line(r.position, Vector2(r.end.x, r.position.y), INK, 1.5, 6.0)
			continue
		var floor_kind: String = by_id[op["a"]]["kind"] if by_id.has(op["a"]) else "room"
		draw_rect(r, SPACE_COLORS.get(floor_kind, PAPER))

	for w in house["walls"]:
		_fill(w, EXT_WALL_COLOR if w["kind"] == "exterior" else INT_WALL_COLOR)

	for op in house["openings"]:
		if op["kind"] == "entrance":
			var r := _px(op["rect"])
			var tip := Vector2(r.get_center().x, r.position.y + 2.0)
			draw_line(Vector2(tip.x, r.end.y + 18.0), tip + Vector2(0, 6), ENTRANCE_COLOR, 2.5)
			draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-6, 9), tip + Vector2(6, 9)]), ENTRANCE_COLOR)

	_draw_labels(font, house)
	var plan := Rect2(_origin + bounds.position * _scale, bounds.size * _scale)
	draw_string(font, Vector2(plan.position.x, plan.end.y + 30.0), "STREET", HORIZONTAL_ALIGNMENT_CENTER, plan.size.x, 11, Color(INK, 0.6))
	_draw_north_arrow(font, Vector2(size.x - 24.0, 72.0))
	var rooms: int = house["spaces"].filter(func(x): return x["kind"] == "room").size()
	var info := "%.2f × %.2f m · footprint %.1f m² · %d rooms · seed %d" % [
		bounds.size.x, bounds.size.y, _poly_area(fp), rooms, house["seed"]]
	draw_string(font, Vector2(8, size.y - 10.0), info, HORIZONTAL_ALIGNMENT_CENTER, size.x - 16.0, 12, Color(INK, 0.75))


func _draw_heading(font: Font, heading: String, detail: String) -> void:
	draw_string(font, Vector2(12, 26), heading, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, INK)
	var x := 12.0 + font.get_string_size(heading, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x + 14.0
	if detail != "":
		var badge := Rect2(x, 10, 112, 22)
		draw_rect(badge, Color(0.2, 0.55, 0.28))
		draw_string(font, Vector2(badge.position.x, 26), "VALID H00–H11", HORIZONTAL_ALIGNMENT_CENTER, badge.size.x, 12, Color.WHITE)
		draw_string(font, Vector2(12, 48), detail, HORIZONTAL_ALIGNMENT_LEFT, size.x - 60.0, 13, Color(INK, 0.8))


func _draw_labels(font: Font, house: Dictionary) -> void:
	var fs := clampi(int(_scale * 0.32), 9, 16)
	for sp in house["spaces"]:
		var r := _px(sp["rect"])
		var label := ""
		var sub := "%.1f m²" % _space_area(sp)
		match sp["kind"]:
			"room": label = sp["type"]
			"courtyard":
				label = "Courtyard"
				sub = "%.1f × %.1f = %.1f m²" % [sp["rect"].size.x, sp["rect"].size.y, _space_area(sp)]
			"pastas": label = "Pastas"
			"passage":
				label = "Entry"
				sub = ""
		if font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > r.size.x - 4.0:
			label = SHORT_LABELS.get(label, label)
		if sub != "" and font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 2).x > r.size.x - 4.0:
			sub = "%.1f m²" % _space_area(sp)
		var lines := 2 if sub != "" and r.size.y > fs * 2.8 else 1
		var y := r.get_center().y - (lines - 1) * fs * 0.55 + fs * 0.35
		draw_string(font, Vector2(r.position.x, y), label, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs, INK)
		if lines == 2:
			draw_string(font, Vector2(r.position.x, y + fs * 1.15), sub, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs - 2, Color(INK, 0.65))


func _draw_north_arrow(font: Font, at: Vector2) -> void:
	draw_colored_polygon(PackedVector2Array([at + Vector2(0, -14), at + Vector2(8, 12), at + Vector2(0, 6), at + Vector2(-8, 12)]), INK)
	draw_string(font, at + Vector2(-20, -18), "N", HORIZONTAL_ALIGNMENT_CENTER, 40, 13, INK)


func _draw_failure(font: Font) -> void:
	draw_rect(Rect2(10, 40, size.x - 20, 26), Color(0.7, 0.15, 0.12))
	draw_string(font, Vector2(10, 58), "GENERATION ERROR — no valid house", HORIZONTAL_ALIGNMENT_CENTER, size.x - 20, 13, Color.WHITE)
	var y := 90.0
	draw_string(font, Vector2(12, y), "Rejected %d candidates (%d-sided footprint requested)." % [result.get("attempts", 0), result.get("sides", 0)], HORIZONTAL_ALIGNMENT_LEFT, size.x - 24, 12, INK)
	for line in result.get("rejections", []).slice(0, 10):
		y += 18.0
		draw_string(font, Vector2(12, y), str(line).left(140), HORIZONTAL_ALIGNMENT_LEFT, size.x - 24, 11, Color(0.5, 0.1, 0.1))


func _fill(item: Dictionary, color: Color) -> void:
	if item.has("poly"):
		var pts := PackedVector2Array()
		for p in item["poly"]:
			pts.append(_origin + p * _scale)
		draw_colored_polygon(pts, color)
	else:
		draw_rect(_px(item["rect"]), color)


func _px(r: Rect2) -> Rect2:
	return Rect2(_origin + r.position * _scale, r.size * _scale)


func _space_area(sp: Dictionary) -> float:
	return _poly_area(sp["poly"]) if sp.has("poly") else (sp["rect"] as Rect2).get_area()


static func _poly_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		a += poly[i].cross(poly[(i + 1) % poly.size()])
	return absf(a) * 0.5


static func _bbox(poly: PackedVector2Array) -> Rect2:
	var r := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		r = r.expand(p)
	return r
