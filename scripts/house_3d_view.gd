extends SubViewportContainer
## 3D cutaway view of a validated city block (all of its houses together),
## or of one validated house.
##
## Every mesh is built directly from the validated house data: one floor per
## space (its exact rectangle or clipped polygon), one floor patch per door or
## entrance gap, and one solid per wall record (BoxMesh for rectangular wall
## pieces, an extruded prism for clipped or mitred ones). Nothing is invented:
## no extra walls, no roofs, no shared spaces, and door gaps stay open because
## walls are only built where the data has wall pieces. Neighbouring houses
## stand on their own footprints; their exterior walls meet as party walls.
##
## Plan (x, y) maps to 3D (x, 0, y): X east, Z south, Y up; north is -Z.
## Walls are WALL_HEIGHT tall — a cutaway height for visibility, not a claim
## about ancient wall heights. The camera orbits the centre of the block;
## rotating never touches the model, and selecting a house only redraws the
## highlight overlay.

signal house_clicked(index: int)

const G := preload("res://scripts/geometry.gd")

const WALL_HEIGHT := 0.8
const ELEVATION := 55.0       # camera elevation above the horizon, degrees
const FOV := 32.0             # vertical field of view, degrees
const ROTATE_STEP := 45.0
const ROTATE_TIME := 0.2
const FRAME_MARGIN := 1.4     # metres around the footprint (north arrow, street marker)

const GROUND_COLOR := Color(0.50, 0.50, 0.47)
const BLOCK_COLOR := Color(0.62, 0.60, 0.55)      # unbuilt ground inside the block
const EXT_WALL_COLOR := Color(0.46, 0.33, 0.24)
const INT_WALL_COLOR := Color(0.36, 0.28, 0.22)
const GAP_COLOR := Color(0.55, 0.44, 0.34)
const MARK_COLOR := Color(0.22, 0.18, 0.15)
const ENTRANCE_COLOR := Color(0.7, 0.2, 0.1)
const SELECT_COLOR := Color(1.0, 0.55, 0.0)
const SPACE_COLORS := {
	"courtyard": Color(0.80, 0.70, 0.50),   # light earth / stone, open to the sky
	"pastas": Color(0.62, 0.55, 0.45),
	"passage": Color(0.70, 0.64, 0.55),
}
const ROOM_COLORS := {
	"Domestic room": Color(0.82, 0.78, 0.68),
	"Storage": Color(0.70, 0.74, 0.64),
	"Kitchen / hearth": Color(0.84, 0.66, 0.56),
	"Andron": Color(0.74, 0.64, 0.78),
	"Workroom": Color(0.62, 0.70, 0.78),
}

var viewport: SubViewport
var camera: Camera3D
var model: Node3D             # meshes of the shown block (or house) only
var overlay: Node3D           # selection highlight and the selected house's room labels
var block: Dictionary = {}
var houses: Array = []        # houses shown (the block's, or one house)
var house: Dictionary = {}    # the single house shown by show_house(), if any
var selected := -1
var build_count := 0          # how many times a model was built (for tests)
var yaw := 0.0                # camera bearing, degrees: 0 = south of the block, 90 = east
var center := Vector3.ZERO
var radius := 10.0
var distance := 30.0

var _target_yaw := 0.0
var _tween: Tween
var _materials := {}
var _model_layer: Node3D      # model nodes are added here (model or overlay)


func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	add_child(viewport)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.88, 0.89, 0.90)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.32
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	viewport.add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58.0, -30.0, 0.0)
	sun.light_energy = 0.55
	sun.shadow_enabled = true
	viewport.add_child(sun)
	camera = Camera3D.new()
	camera.fov = FOV
	camera.far = 2000.0
	viewport.add_child(camera)
	model = Node3D.new()
	viewport.add_child(model)
	overlay = Node3D.new()
	viewport.add_child(overlay)
	resized.connect(_update_camera)


## Shows a validated city block with all its houses, rebuilding only when the
## block changes. A block without a passing validation result is refused.
func show_block(b: Dictionary, sel := 0) -> bool:
	if is_same(b, block) and not b.is_empty():
		set_selected(sel)
		return true
	clear()
	if b.is_empty() or not b.get("validation", {}).get("valid", false):
		return false
	block = b
	houses = b["houses"]
	_build()
	build_count += 1
	_frame(b["polygon"])
	set_selected(sel)
	return true


## Shows one validated house (used by the tests and for single inspection).
func show_house(h: Dictionary) -> bool:
	if is_same(h, house) and not h.is_empty():
		return true
	clear()
	if h.is_empty() or not h.get("validation", {}).get("valid", false):
		return false
	house = h
	houses = [h]
	_build()
	build_count += 1
	_frame(h["footprint"])
	set_selected(0)
	return true


func clear() -> void:
	for layer in [model, overlay]:
		for child in layer.get_children():
			layer.remove_child(child)
			child.queue_free()
	block = {}
	house = {}
	houses = []
	selected = -1


## Highlights one house (orange outline on its walls, room labels) while the
## whole block stays visible. Only the overlay is rebuilt.
func set_selected(index: int) -> void:
	selected = index
	for child in overlay.get_children():
		overlay.remove_child(child)
		child.queue_free()
	if index < 0 or index >= houses.size():
		return
	_model_layer = overlay
	var h: Dictionary = houses[index]
	if houses.size() > 1:
		var fp: PackedVector2Array = h["footprint"]
		var inner := _inset(fp, 0.35)
		for i in fp.size():
			var j := (i + 1) % fp.size()
			_add(_slab(PackedVector2Array([fp[i], fp[j], inner[j], inner[i]]), WALL_HEIGHT + 0.02, WALL_HEIGHT + 0.02, SELECT_COLOR), "highlight", index, index)
	for sp in h["spaces"]:
		_add_label(sp, index)
	_model_layer = model


## Index of the house under a screen point (ray onto the ground), or -1.
func pick_house(screen_pos: Vector2) -> int:
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-6:
		return -1
	var t := -origin.y / dir.y
	if t < 0.0:
		return -1
	var hit := origin + dir * t
	for i in houses.size():
		if G.point_in_polygon(Vector2(hit.x, hit.z), houses[i]["footprint"]):
			return i
	return -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var i := pick_house(event.position)
		if i >= 0:
			house_clicked.emit(i)
			accept_event()


## Orbits the camera by steps × 45° around the centre (positive =
## counter-clockwise seen from above, so the scene appears to turn clockwise).
## Distance, elevation and focal point are kept; the model is not touched.
func rotate_view(steps: int, animate := true) -> void:
	_target_yaw += steps * ROTATE_STEP
	if _tween:
		_tween.kill()
	if animate and is_inside_tree():
		_tween = create_tween()
		_tween.tween_method(_set_yaw, yaw, _target_yaw, ROTATE_TIME)
	else:
		_set_yaw(_target_yaw)


func _set_yaw(value: float) -> void:
	yaw = value
	_update_camera()


func _frame(outline: PackedVector2Array) -> void:
	var b := _bbox(outline)
	center = Vector3(b.get_center().x, 0.0, b.get_center().y)
	radius = b.size.length() / 2.0 + FRAME_MARGIN
	_update_camera()


func _update_camera() -> void:
	var aspect := maxf(size.x, 1.0) / maxf(size.y, 1.0)
	var half_v := deg_to_rad(FOV / 2.0)
	var half_h := atan(tan(half_v) * aspect)
	var el := deg_to_rad(ELEVATION)
	# The scene is a low disc of `radius` around the centre (any rotation):
	# seen from the elevation it is foreshortened vertically by sin(el).
	distance = 1.04 * maxf(radius * sin(el) / tan(half_v), radius / tan(half_h)) + 0.35 * radius * cos(el)
	var az := deg_to_rad(yaw)
	var pos := center + Vector3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * distance
	camera.transform = Transform3D(Basis.looking_at(center - pos, Vector3.UP), pos)   # works before entering the tree


# --------------------------------------------------------------------------
# Model construction (from validated data only)
# --------------------------------------------------------------------------

func _build() -> void:
	_model_layer = model
	var outline: PackedVector2Array = block["polygon"] if not block.is_empty() else houses[0]["footprint"]
	var b := _bbox(outline)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = b.size + Vector2.ONE * 2.0 * (FRAME_MARGIN + 0.8)
	ground.mesh = plane
	ground.material_override = _material(GROUND_COLOR)
	ground.position = Vector3(b.get_center().x, -0.03, b.get_center().y)
	_add(ground, "ground", -1, -1)
	if not block.is_empty():
		# The block itself (unbuilt corner ground shows through), streets around it.
		_add(_slab(outline, -0.015, -0.015, BLOCK_COLOR), "block", -1, -1)
	for i in houses.size():
		_build_house(houses[i], i)
		if houses.size() > 1:
			var tag := Label3D.new()
			tag.text = "House %d" % (i + 1)
			var c := G.centroid(houses[i]["footprint"])
			tag.position = Vector3(c.x, 2.5, c.y)
			_style_label(tag, 30)
			tag.fixed_size = true
			tag.pixel_size = 0.0004
			_add(tag, "label", -1, i)
	# North arrow on the ground beyond the north face, pointing to -Z.
	var tip := Vector2(b.get_center().x, b.position.y - 1.6)
	var arrow := PackedVector2Array([tip, tip + Vector2(0.5, 1.1), tip + Vector2(0.0, 0.8), tip + Vector2(-0.5, 1.1)])
	if houses.size() > 1:
		arrow = PackedVector2Array(Array(arrow).map(func(p): return tip + (p - tip) * 3.0))
	_add(_slab(arrow, 0.005, 0.005, MARK_COLOR), "marker", -1, -1)
	var n := Label3D.new()
	n.text = "N"
	n.position = Vector3(tip.x, 0.3, tip.y - 0.35)
	_style_label(n, 40)
	if houses.size() > 1:
		n.fixed_size = true
		n.pixel_size = 0.00045
	_add(n, "label", -1, -1)


func _build_house(h: Dictionary, index: int) -> void:
	for sp in h["spaces"]:
		var color: Color = ROOM_COLORS.get(sp.get("type", ""), Color.WHITE) if sp["kind"] == "room" else SPACE_COLORS[sp["kind"]]
		_add(_slab(_shape(sp), 0.0, 0.0, color), "floor", sp["id"], index)
	var openings: Array = h["openings"]
	for i in openings.size():
		var op: Dictionary = openings[i]
		var r: Rect2 = op["rect"]
		if op["kind"] == "open":
			# Pastas roof line along the open courtyard edge: a flat floor mark only.
			var strip := Rect2(r.position.x, r.position.y - 0.04, r.size.x, 0.08)
			_add(_slab(_rect_poly(strip), 0.003, 0.003, MARK_COLOR), "marker", i, index)
			continue
		_add(_slab(_shape(op), 0.0, 0.0, GAP_COLOR), "gap", i, index)
		if op["kind"] == "entrance":
			# Arrow on the street, pointing in through the entrance.
			var c := _centroid(_shape(op))
			var inward := -1.0 if h.get("street_side", "south") == "south" else 1.0
			var base := c - Vector2(0, inward) * 1.2
			_add(_slab(PackedVector2Array([base + Vector2(0, inward) * 0.9, base + Vector2(0.45, 0), base + Vector2(-0.45, 0)]), 0.005, 0.005, ENTRANCE_COLOR), "marker", i, index)
	var walls: Array = h["walls"]
	for i in walls.size():
		var w: Dictionary = walls[i]
		var color := EXT_WALL_COLOR if w["kind"] == "exterior" else INT_WALL_COLOR
		if w.has("poly"):
			_add(_slab(w["poly"], 0.0, WALL_HEIGHT, color), "wall", i, index)
		else:
			var r: Rect2 = w["rect"]
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(r.size.x, WALL_HEIGHT, r.size.y)
			mi.mesh = box
			mi.material_override = _material(color)
			mi.position = Vector3(r.get_center().x, WALL_HEIGHT / 2.0, r.get_center().y)
			_add(mi, "wall", i, index)


func _add_label(sp: Dictionary, index: int) -> void:
	var label := Label3D.new()
	var text: String = sp.get("type", "")
	match sp["kind"]:
		"courtyard":
			text = "Courtyard\n%.1f m²" % _poly_area(_shape(sp))
		"pastas":
			text = "Pastas"
		"passage":
			text = "Entry"
	label.text = text.replace(" / ", " /\n")
	var shape := _shape(sp)
	var c := _centroid(shape)
	label.position = Vector3(c.x, 0.15, c.y)
	_style_label(label, 48)
	# Scale the text to the room: at most ~0.4 m tall, at most 80 % of its width.
	var fit_w := minf(_bbox(shape).size.x, _bbox(shape).size.y) * 0.8
	var text_px := label.font.get_multiline_string_size(label.text, HORIZONTAL_ALIGNMENT_CENTER, -1, 48).x
	label.pixel_size = minf(0.4 / 48.0, fit_w / text_px)
	_add(label, "label", sp["id"], index)


func _style_label(label: Label3D, font_size: int) -> void:
	label.font = ThemeDB.fallback_font
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.012
	label.font_size = font_size
	label.outline_size = 8
	label.modulate = Color(0.12, 0.10, 0.08)
	label.outline_modulate = Color(1, 1, 1, 0.85)
	label.no_depth_test = true


func _add(node: Node3D, role: String, ref: int, house_index: int) -> void:
	node.set_meta("role", role)
	node.set_meta("ref", ref)
	node.set_meta("house", house_index)
	(_model_layer if _model_layer != null else model).add_child(node)


static func _inset(poly: PackedVector2Array, d: float) -> PackedVector2Array:
	return preload("res://scripts/house_validator.gd").inset_polygon(poly, d)


## Prism over a plan polygon from y0 to y1 (a flat floor when y0 == y1):
## triangulated top face plus outward-facing side quads.
func _slab(poly: PackedVector2Array, y0: float, y1: float, color: Color) -> MeshInstance3D:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var tris := Geometry2D.triangulate_polygon(poly)
	for k in tris:
		verts.append(Vector3(poly[k].x, y1, poly[k].y))
		normals.append(Vector3.UP)
	if y1 > y0:
		var ccw := _signed_area(poly) > 0.0
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			var d := (b - a).normalized()
			var n2 := Vector2(d.y, -d.x) if ccw else Vector2(-d.y, d.x)
			var n := Vector3(n2.x, 0.0, n2.y)
			for p in [Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(b.x, y1, b.y),
					Vector3(a.x, y0, a.y), Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y)]:
				verts.append(p)
				normals.append(n)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _material(color)
	return mi


func _material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.95
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_materials[color] = m
	return _materials[color]


# --------------------------------------------------------------------------
# Inspection (used by the smoke test to compare meshes with the house data)
# --------------------------------------------------------------------------

## Plan outline of a floor or wall mesh, read back from the mesh itself:
## {area: top-face area (m²), points: top-face vertices (plan x, y),
##  bottom: lowest y, top: highest y}.
static func mesh_outline(mi: MeshInstance3D) -> Dictionary:
	if mi.mesh is BoxMesh:
		var s: Vector3 = (mi.mesh as BoxMesh).size
		var c := Vector2(mi.position.x, mi.position.z)
		var h := Vector2(s.x, s.z) / 2.0
		return {"area": s.x * s.z, "bottom": mi.position.y - s.y / 2.0, "top": mi.position.y + s.y / 2.0,
			"points": PackedVector2Array([c - h, c + Vector2(h.x, -h.y), c + h, c + Vector2(-h.x, h.y)])}
	var verts: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var top := -INF
	var bottom := INF
	for v in verts:
		top = maxf(top, v.y)
		bottom = minf(bottom, v.y)
	var area := 0.0
	var points := PackedVector2Array()
	for i in range(0, verts.size(), 3):
		var a := verts[i]
		var b := verts[i + 1]
		var c := verts[i + 2]
		if absf(a.y - top) < 1e-6 and absf(b.y - top) < 1e-6 and absf(c.y - top) < 1e-6:
			area += absf((b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)) / 2.0
			for v in [a, b, c]:
				if not points.has(Vector2(v.x, v.z)):
					points.append(Vector2(v.x, v.z))
	return {"area": area, "points": points, "bottom": bottom, "top": top}


static func _shape(item: Dictionary) -> PackedVector2Array:
	return G.shape(item)


static func _rect_poly(r: Rect2) -> PackedVector2Array:
	return G.rect_poly(r)


static func _bbox(poly: PackedVector2Array) -> Rect2:
	return G.bbox(poly)


static func _signed_area(poly: PackedVector2Array) -> float:
	return G.signed_area(poly)


static func _poly_area(poly: PackedVector2Array) -> float:
	return G.polygon_area(poly)


static func _centroid(poly: PackedVector2Array) -> Vector2:
	return G.centroid(poly)
