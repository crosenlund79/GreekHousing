extends RefCounted
## City-block validator. A block is valid only if every house passes H00–H12
## (frontage measured on the block boundary) AND the block-level rules hold:
##   B00 the block polygon is simple with positive area;
##   B01 exactly 5 or 6 houses;
##   B02 every house lies inside the block;
##   B03 no two houses overlap (they may share party walls);
##   B04 no shared spaces: the block defines no spaces of its own and no
##       house's space reaches into another house;
##   B05 every house has an entrance whose outer face lies on the block
##       perimeter (a street), on at least 2.0 m of continuous frontage;
##   B06 every courtyard is private: inside its own house, touching no other;
##   B07 one shared north: no house carries a rotation, and every northern
##       wing lies north of its courtyard in the shared frame (H02).
## A set of individually valid houses is not automatically a valid block.

const V := preload("res://scripts/house_validator.gd")
const G := preload("res://scripts/geometry.gd")

const MIN_HOUSES := 5
const MAX_HOUSES := 6


static func validate_block(block: Dictionary) -> Dictionary:
	var errors: Array = []
	var poly: PackedVector2Array = block.get("polygon", PackedVector2Array())
	var houses: Array = block.get("houses", [])
	if poly.size() < 3 or G.polygon_area(poly) <= V.TILE_TOL or _crosses(poly):
		errors.append("B00: block polygon is not a simple polygon with positive area")
		return {"valid": false, "errors": errors, "residual_area": 0.0}
	if houses.size() < MIN_HOUSES or houses.size() > MAX_HOUSES:
		errors.append("B01: %d houses (required %d or %d)" % [houses.size(), MIN_HOUSES, MAX_HOUSES])
	for key in ["spaces", "walls", "openings", "shared_spaces"]:
		if block.has(key):
			errors.append("B04: the block defines its own %s (shared space)" % key)
	var built := 0.0
	for i in houses.size():
		var h: Dictionary = houses[i]
		var tag := "House %d" % (i + 1)
		if not h.has("block") or h["block"] != poly:
			errors.append("B05: %s is not checked against this block's streets" % tag)
		var v := V.validate_house(h)
		for e in v["errors"]:
			errors.append("%s · %s" % [tag, e])
		var fp: PackedVector2Array = h["footprint"]
		built += G.polygon_area(fp)
		if V._outside_area(fp, poly) > V.TILE_TOL:
			errors.append("B02: %s extends outside the block" % tag)
		if h.get("rotation", 0.0) != 0.0:
			errors.append("B07: %s is rotated; all houses share one north" % tag)
		# B05: an entrance straight onto the block perimeter, on >= 2.0 m frontage.
		var ctx := {"footprint": fp, "by_id": {}}
		for sp in h["spaces"]:
			ctx["by_id"][sp["id"]] = sp
		var on_street := false
		for op in h["openings"]:
			if op["kind"] == "entrance":
				var face := V._street_face(op, ctx)
				on_street = on_street or (not face.is_empty() and V._segment_on_boundary(face[0], face[1], poly))
		if not on_street:
			errors.append("B05: %s has no entrance on the block perimeter" % tag)
		var front := V.street_frontage(h)
		if front["edge"] < 0 or front["length"] < V.MIN_STREET_FRONTAGE - V.EPS:
			errors.append("B05: %s has less than %.1f m of continuous street frontage" % [tag, V.MIN_STREET_FRONTAGE])
		# B04 / B06: nothing of this house reaches into another house.
		for j in houses.size():
			if j == i:
				continue
			var other: PackedVector2Array = houses[j]["footprint"]
			for sp in h["spaces"]:
				if V._overlap_area(G.shape(sp), other) > V.TILE_TOL:
					errors.append("%s: %s's %s reaches into House %d" % ["B06" if sp["kind"] == "courtyard" else "B04", tag, sp["kind"], j + 1])
	for i in houses.size():
		for j in range(i + 1, houses.size()):
			if V._overlap_area(houses[i]["footprint"], houses[j]["footprint"]) > V.TILE_TOL:
				errors.append("B03: House %d and House %d overlap" % [i + 1, j + 1])
	return {"valid": errors.is_empty(), "errors": errors, "residual_area": maxf(0.0, G.polygon_area(poly) - built),
		"house_count": houses.size()}


static func _crosses(poly: PackedVector2Array) -> bool:
	var n := poly.size()
	for i in n:
		for j in range(i + 1, n):
			if j == i + 1 or (i == 0 and j == n - 1):
				continue
			if Geometry2D.segment_intersects_segment(poly[i], poly[(i + 1) % n], poly[j], poly[(j + 1) % n]) != null:
				return true
	return false
