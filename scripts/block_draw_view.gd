extends Control
## Top-down drawing area for the city block (custom _draw()).
##
## Click to place corners; click the first corner again to close the outline.
## Right-click or Backspace removes the last corner. A corner that would make
## the outline cross itself is refused. Once a block has been generated the
## view shows its house footprints and a click selects a house.
## Coordinates are the shared world metres (X east, Y south, north up).

signal polygon_closed(poly: PackedVector2Array)
signal house_clicked(index: int)
signal message(text: String)

const G := preload("res://scripts/geometry.gd")
const BG := preload("res://scripts/block_generator.gd")

const WORLD := Rect2(0, 0, 140, 80)   # drawable area, metres
const GUIDE := Rect2(25, 25, 90, 30)  # suggested block size, metres
const MARGIN := 34.0
const CLOSE_RADIUS := 12.0            # pixels around the first corner that close the outline
const PAPER := Color(0.97, 0.96, 0.92)
const GRID := Color(0.55, 0.6, 0.68, 0.25)
const GRID_MAJOR := Color(0.4, 0.47, 0.58, 0.45)
const INK := Color(0.12, 0.12, 0.16)
const BLOCK_FILL := Color(0.86, 0.80, 0.66, 0.55)
const HOUSE_FILL := Color(0.93, 0.88, 0.76)
const SELECT := Color(1.0, 0.5, 0.0)

var points := PackedVector2Array()
var closed := false
var block: Dictionary = {}
var selected := -1
var _hover := Vector2.INF
var _xf := Transform2D()


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_layout)
	_layout()


func reset() -> void:
	points = PackedVector2Array()
	closed = false
	block = {}
	selected = -1
	queue_redraw()


func show_block(b: Dictionary, sel: int) -> void:
	block = b
	selected = sel
	queue_redraw()


## Closes the outline programmatically (tests, presets).
func set_polygon(poly: PackedVector2Array) -> void:
	points = poly
	closed = true
	block = {}
	queue_redraw()


func world_to_screen(p: Vector2) -> Vector2:
	return _xf * p


func screen_to_world(p: Vector2) -> Vector2:
	return _xf.affine_inverse() * p


func _layout() -> void:
	_xf = G.fit_transform(WORLD, Rect2(Vector2.ZERO, size), MARGIN)
	queue_redraw()


# --------------------------------------------------------------------------
# Input
# --------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = event.position
		if not closed:
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed:
		grab_focus()
		if event.button_index == MOUSE_BUTTON_LEFT:
			click(event.position)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			undo()
		accept_event()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_BACKSPACE:
		undo()
		accept_event()


## Handles a left click at a screen position (also used by tests).
func click(screen_pos: Vector2) -> void:
	if closed:
		if not block.is_empty():
			var p := screen_to_world(screen_pos)
			var houses: Array = block["houses"]
			for i in houses.size():
				if G.point_in_polygon(p, houses[i]["footprint"]):
					house_clicked.emit(i)
					return
		return
	var p := screen_to_world(screen_pos).snapped(Vector2(0.05, 0.05))
	if not WORLD.has_point(p):
		return
	if points.size() >= 3 and world_to_screen(points[0]).distance_to(screen_pos) <= CLOSE_RADIUS:
		var problem := BG.check_block_polygon(points)
		if problem != "":
			message.emit("Cannot close the block: %s." % problem)
			return
		closed = true
		queue_redraw()
		polygon_closed.emit(points)
		return
	if not points.is_empty() and p.distance_to(points[-1]) < BG.MIN_BLOCK_EDGE:
		return
	if _crosses_existing(p):
		message.emit("That corner would make the outline cross itself.")
		return
	points.append(p)
	message.emit("%d corners placed. Click the first corner to close the block." % points.size() if points.size() >= 3
		else "%d corner%s placed." % [points.size(), "" if points.size() == 1 else "s"])
	queue_redraw()


func undo() -> void:
	if closed or points.is_empty():
		return
	points.remove_at(points.size() - 1)
	queue_redraw()


## True if the new edge (last corner -> p) would cross an earlier edge.
func _crosses_existing(p: Vector2) -> bool:
	if points.size() < 2:
		return false
	var a := points[-1]
	for i in points.size() - 2:
		if Geometry2D.segment_intersects_segment(a, p, points[i], points[i + 1]) != null:
			return true
	return false


# --------------------------------------------------------------------------
# Drawing
# --------------------------------------------------------------------------

func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.9, 0.89, 0.85))
	var area := Rect2(world_to_screen(WORLD.position), WORLD.size * _xf.x.x)
	draw_rect(area, PAPER)
	var s := _xf.x.x
	for gx in range(0, int(WORLD.size.x) + 1, 5):
		var major := gx % 10 == 0
		var x := world_to_screen(Vector2(gx, 0)).x
		draw_line(Vector2(x, area.position.y), Vector2(x, area.end.y), GRID_MAJOR if major else GRID, 1.0)
		if major and (s >= 5.0 or gx % 20 == 0):
			draw_string(font, Vector2(x - 12, area.position.y - 6), "%d" % gx, HORIZONTAL_ALIGNMENT_CENTER, 24, 10, INK)
	for gy in range(0, int(WORLD.size.y) + 1, 5):
		var major := gy % 10 == 0
		var y := world_to_screen(Vector2(0, gy)).y
		draw_line(Vector2(area.position.x, y), Vector2(area.end.x, y), GRID_MAJOR if major else GRID, 1.0)
		if major:
			draw_string(font, Vector2(area.position.x - 30, y + 4), "%d" % gy, HORIZONTAL_ALIGNMENT_RIGHT, 26, 10, INK)
	draw_string(font, Vector2(area.position.x, area.end.y + 16), "X (m, east) →   Y (m, south) ↓   grid 5 m", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK)
	_draw_north(font, Vector2(area.end.x - 18, area.position.y + 26))

	if closed:
		draw_colored_polygon(_xf * points, BLOCK_FILL)
	if not block.is_empty():
		var houses: Array = block["houses"]
		for i in houses.size():
			var fp: PackedVector2Array = houses[i]["footprint"]
			draw_colored_polygon(_xf * fp, HOUSE_FILL if i != selected else Color(SELECT, 0.35))
			draw_polyline(_closed(_xf * fp), INK if i != selected else SELECT, 2.0 if i != selected else 3.0)
			for sp in houses[i]["spaces"]:
				if sp["kind"] == "courtyard":
					draw_colored_polygon(_xf * G.shape(sp), Color(0.72, 0.84, 0.6))
			for op in houses[i]["openings"]:
				if op["kind"] == "entrance":
					var c := world_to_screen(G.centroid(G.shape(op)))
					draw_circle(c, 4.0, Color(0.75, 0.15, 0.1))
			var label := world_to_screen(G.centroid(fp))
			draw_string(font, label + Vector2(-20, 5), "H%d" % (i + 1), HORIZONTAL_ALIGNMENT_CENTER, 40, 14, INK)
	if points.size() >= 2:
		draw_polyline(_closed(_xf * points) if closed else _xf * points, INK, 2.5)
	for i in points.size():
		var p := world_to_screen(points[i])
		draw_circle(p, 4.0 if i > 0 else 6.0, INK if i > 0 else Color(0.1, 0.45, 0.2))
	if not closed and not points.is_empty() and _hover != Vector2.INF:
		draw_dashed_line(world_to_screen(points[-1]), _hover, Color(INK, 0.6), 1.5, 6.0)
		if points.size() >= 3 and world_to_screen(points[0]).distance_to(_hover) <= CLOSE_RADIUS:
			draw_arc(world_to_screen(points[0]), CLOSE_RADIUS, 0, TAU, 24, Color(0.1, 0.45, 0.2), 2.0)
	if points.is_empty():
		# Size guide: houses fill blocks 21–34 m deep (two rows) or 14–20 m (one row).
		var guide := Rect2(world_to_screen(GUIDE.position), GUIDE.size * s)
		draw_rect(guide, Color(0.1, 0.45, 0.2, 0.06))
		for e in [[guide.position, Vector2(guide.end.x, guide.position.y)], [Vector2(guide.end.x, guide.position.y), guide.end],
				[guide.end, Vector2(guide.position.x, guide.end.y)], [Vector2(guide.position.x, guide.end.y), guide.position]]:
			draw_dashed_line(e[0], e[1], Color(0.1, 0.45, 0.2, 0.6), 1.5, 8.0)
		draw_string(font, guide.position + Vector2(8, guide.size.y - 8), "a block of about this size works well (90 × 30 m)", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.1, 0.45, 0.2, 0.9))
		var hint := "Click to place the corners of a city block; click the first corner to close it.\nEvery edge is a street. Blocks about 70–110 m east–west and 24–34 m north–south work well."
		draw_multiline_string(font, area.position + Vector2(16, 40), hint, HORIZONTAL_ALIGNMENT_LEFT, area.size.x - 32, 14, -1, Color(INK, 0.75))


func _draw_north(font: Font, at: Vector2) -> void:
	draw_colored_polygon(PackedVector2Array([at + Vector2(0, -14), at + Vector2(7, 8), at + Vector2(-7, 8)]), INK)
	draw_string(font, at + Vector2(-10, 22), "N", HORIZONTAL_ALIGNMENT_CENTER, 20, 12, INK)


static func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := pts.duplicate()
	out.append(pts[0])
	return out
