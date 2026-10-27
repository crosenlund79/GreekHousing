extends Control
## Draws one generated house plan. Rendering only: it reads the structured
## house data and never generates or validates geometry itself.

const INK := Color(0.16, 0.13, 0.11)
const PAPER := Color(0.99, 0.98, 0.95)
const EXT_WALL_COLOR := Color(0.23, 0.18, 0.15)
const INT_WALL_COLOR := Color(0.42, 0.35, 0.29)
const SPACE_COLORS := {
	"room": Color(0.97, 0.93, 0.84),
	"courtyard": Color(0.78, 0.86, 0.66),
	"pastas": Color(0.86, 0.81, 0.71),
	"passage": Color(0.91, 0.87, 0.78),
}
const SHORT_LABELS := {
	"Domestic room": "Room", "Kitchen / hearth": "Hearth", "Storage": "Store",
	"Andron": "Andron", "Workroom": "Work",
}

var result: Dictionary = {}
var title := ""


func show_result(r: Dictionary, slot_title: String) -> void:
	result = r
	title = slot_title
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), PAPER)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.72, 0.68, 0.6), false, 1.0)
	draw_string(font, Vector2(10, 20), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, INK)
	if result.is_empty():
		return
	if not result.get("ok", false):
		_draw_failure(font)
		return
	var house: Dictionary = result["house"]
	var validation: Dictionary = house.get("validation", {})
	if not validation.get("valid", false):
		_draw_failure(font)   # never show an unvalidated house as a plan
		return

	var fp: Rect2 = house["footprint"]
	var top := 64.0
	var bottom := 58.0
	var side := 16.0
	var s := minf((size.x - 2.0 * side) / fp.size.x, (size.y - top - bottom) / fp.size.y)
	var origin := Vector2((size.x - fp.size.x * s) / 2.0, top + (size.y - top - bottom - fp.size.y * s) / 2.0)
	var to_px := func(r: Rect2) -> Rect2: return Rect2(origin + r.position * s, r.size * s)

	var by_id := {}
	for sp in house["spaces"]:
		by_id[sp["id"]] = sp
		draw_rect(to_px.call(sp["rect"]), SPACE_COLORS.get(sp["kind"], Color.WHITE))

	for op in house["openings"]:
		var r: Rect2 = to_px.call(op["rect"])
		if op["kind"] == "open":
			# Roof edge of the pastas, open to the courtyard along its length.
			draw_dashed_line(r.position, Vector2(r.end.x, r.position.y), INK, 1.5, 5.0)
			continue
		var floor_kind: String = by_id[op["a"]]["kind"] if by_id.has(op["a"]) else "room"
		draw_rect(r, SPACE_COLORS.get(floor_kind, PAPER))
		if op["kind"] == "entrance":
			var c := Vector2(r.get_center().x, r.end.y + 14.0)
			draw_line(c, Vector2(c.x, r.position.y + 2.0), Color(0.7, 0.2, 0.1), 2.0)
			draw_colored_polygon(PackedVector2Array([Vector2(c.x - 5, r.position.y + 8), Vector2(c.x + 5, r.position.y + 8), Vector2(c.x, r.position.y + 1)]), Color(0.7, 0.2, 0.1))

	for w in house["walls"]:
		draw_rect(to_px.call(w["rect"]), EXT_WALL_COLOR if w["kind"] == "exterior" else INT_WALL_COLOR)

	var fs := clampi(int(s * 0.36), 9, 14)
	for sp in house["spaces"]:
		var r: Rect2 = to_px.call(sp["rect"])
		var label := ""
		var sub := "%.1f m²" % (sp["rect"] as Rect2).get_area()
		match sp["kind"]:
			"room": label = sp["type"]
			"courtyard":
				label = "Courtyard"
				sub = "%.1f × %.1f = %.1f m²" % [sp["rect"].size.x, sp["rect"].size.y, (sp["rect"] as Rect2).get_area()]
			"pastas": label = "Pastas"
			"passage": label = "Entry"
		if font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > r.size.x - 4.0:
			label = SHORT_LABELS.get(label, label)
		if sp["kind"] == "passage":
			sub = ""
		var lines := 2 if sub != "" and r.size.y > fs * 2.6 else 1
		var y := r.get_center().y - (lines - 1) * fs * 0.55 + fs * 0.35
		draw_string(font, Vector2(r.position.x, y), label, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs, INK)
		if lines == 2:
			draw_string(font, Vector2(r.position.x, y + fs * 1.1), sub, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs - 2, Color(INK, 0.65))

	var plan := to_px.call(fp) as Rect2
	draw_string(font, Vector2(plan.position.x, plan.end.y + 26.0), "STREET", HORIZONTAL_ALIGNMENT_CENTER, plan.size.x, 10, Color(INK, 0.6))
	_draw_north_arrow(font, Vector2(size.x - 24.0, 36.0))
	_draw_valid_badge(font)
	var info := "%.2f × %.2f m · %d rooms · seed %d" % [
		fp.size.x, fp.size.y, house["spaces"].filter(func(x): return x["kind"] == "room").size(), house["seed"]]
	draw_string(font, Vector2(8, size.y - 10.0), info, HORIZONTAL_ALIGNMENT_CENTER, size.x - 16.0, 11, Color(INK, 0.75))


func _draw_north_arrow(font: Font, at: Vector2) -> void:
	draw_colored_polygon(PackedVector2Array([at + Vector2(0, -12), at + Vector2(7, 10), at + Vector2(0, 5), at + Vector2(-7, 10)]), INK)
	draw_string(font, at + Vector2(-20, 20), "N", HORIZONTAL_ALIGNMENT_CENTER, 40, 12, INK)


func _draw_valid_badge(font: Font) -> void:
	var r := Rect2(10, 30, 104, 20)
	draw_rect(r, Color(0.2, 0.55, 0.28))
	draw_string(font, Vector2(r.position.x, r.position.y + 15), "VALID H01–H10", HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 11, Color.WHITE)


func _draw_failure(font: Font) -> void:
	draw_rect(Rect2(10, 30, size.x - 20, 24), Color(0.7, 0.15, 0.12))
	draw_string(font, Vector2(10, 47), "GENERATION ERROR", HORIZONTAL_ALIGNMENT_CENTER, size.x - 20, 12, Color.WHITE)
	var y := 76.0
	draw_string(font, Vector2(12, y), "No valid house after %d attempts." % result.get("attempts", 0), HORIZONTAL_ALIGNMENT_LEFT, size.x - 24, 11, INK)
	for line in result.get("rejections", []).slice(0, 8):
		y += 16.0
		draw_string(font, Vector2(12, y), str(line).left(60), HORIZONTAL_ALIGNMENT_LEFT, size.x - 24, 10, Color(0.5, 0.1, 0.1))
