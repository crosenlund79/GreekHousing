extends RefCounted
## Shared plane-geometry helpers used by the validator, the 2D plan, the
## coordinate schematic and the 3D view, so every view measures the one house
## Dictionary the same way. Metres; X east, Y south.
##
## A geometry "item" is a space, wall or opening Dictionary: its exact shape is
## `poly` when present, otherwise its `rect`.


## Shoelace formula (positive when counter-clockwise in a y-up frame).
static func signed_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += float(p.x) * q.y - float(q.x) * p.y
	return a * 0.5


static func polygon_area(poly: PackedVector2Array) -> float:
	return absf(signed_area(poly))


## Length of edge i, from vertex i to vertex i + 1 (closing edge last).
static func edge_lengths(poly: PackedVector2Array) -> Array:
	var out: Array = []
	for i in poly.size():
		out.append(poly[i].distance_to(poly[(i + 1) % poly.size()]))
	return out


## Interior angle (degrees) at every vertex of a simple polygon; reflex
## corners are > 180°.
static func interior_angles(poly: PackedVector2Array) -> Array:
	var orient := 1.0 if signed_area(poly) > 0.0 else -1.0
	var out: Array = []
	for i in poly.size():
		var e0 := poly[i] - poly[i - 1]
		var e1 := poly[(i + 1) % poly.size()] - poly[i]
		var turn := rad_to_deg(atan2(e0.cross(e1), e0.dot(e1)))
		out.append(180.0 - turn * orient)
	return out


## Crossing-number test; points exactly on an edge may go either way.
static func point_in_polygon(p: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	for i in poly.size():
		var a := poly[i]
		var b := poly[i - 1]
		if (a.y > p.y) != (b.y > p.y) and p.x < a.x + (b.x - a.x) * (p.y - a.y) / (b.y - a.y):
			inside = not inside
	return inside


static func bbox(poly: PackedVector2Array) -> Rect2:
	var r := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		r = r.expand(p)
	return r


static func centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / poly.size()


static func rect_poly(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


## Exact outline of a space, wall or opening.
static func shape(item: Dictionary) -> PackedVector2Array:
	return item["poly"] if item.has("poly") else rect_poly(item["rect"])


## Exact area of a space, wall or opening.
static func item_area(item: Dictionary) -> float:
	return polygon_area(item["poly"]) if item.has("poly") else (item["rect"] as Rect2).get_area()


## Local house coordinates: a pure translation so that the top-left corner of
## the footprint's bounding box is (0, 0). No rotation or scaling.
static func local_origin(house: Dictionary) -> Vector2:
	return bbox(house["footprint"]).position


static func to_local(p: Vector2, house: Dictionary) -> Vector2:
	return p - local_origin(house)


## Uniform world (metres) → screen (pixels) transform fitting `world` inside
## `screen` with `margin` pixels, centred, without distortion.
static func fit_transform(world: Rect2, screen: Rect2, margin: float) -> Transform2D:
	var avail := screen.size - Vector2.ONE * 2.0 * margin
	var s := maxf(0.001, minf(avail.x / world.size.x, avail.y / world.size.y))
	var offset := screen.position + Vector2.ONE * margin + (avail - world.size * s) / 2.0 - world.position * s
	return Transform2D(Vector2(s, 0.0), Vector2(0.0, s), offset)
