extends Control
## Ancient Greek city-block generator: main screen and workflow.
##
## 1. Draw the block outline (click corners, click the first corner to close).
## 2. "Generate City Block" subdivides it into 5 or 6 plots, builds a house in
##    each and validates every house (H00–H12) and the whole block (B00–B07).
## 3. All houses are shown together in one 3D cutaway; click a house to select
##    it (the others stay visible). Rotate the camera with the buttons.
## 4. "Show Coordinates" opens the coordinate schematic: block level, or the
##    selected house. "Regenerate Houses" builds a new block in the same outline.
## Every view reads the same block Dictionary; switching views never
## regenerates anything, and only "VALID" blocks are ever displayed.

const BG := preload("res://scripts/block_generator.gd")
const DrawView := preload("res://scripts/block_draw_view.gd")
const House3DView := preload("res://scripts/house_3d_view.gd")
const SchematicView := preload("res://scripts/house_schematic_view.gd")

var mode := "draw"             # "draw", "3d" or "schematic"
var schematic_level := "block" # "block" or "house"
var polygon := PackedVector2Array()
var block: Dictionary = {}     # the current validated block (or {})
var selected := 0              # selected house index
var generation := 0            # number of blocks generated (for tests)
var last_reason := ""

var draw_view: Control
var view3d: SubViewportContainer
var schematic: Control
var info: Label
var status: Label
var buttons := {}


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.93, 0.91, 0.86)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 8)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var title := Label.new()
	title.text = "Ancient Greek City Block Generator"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.2, 0.16, 0.12))
	root.add_child(title)

	# Wraps onto several lines on narrow windows.
	var bar := HFlowContainer.new()
	bar.alignment = FlowContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("h_separation", 8)
	bar.add_theme_constant_override("v_separation", 6)
	root.add_child(bar)
	for spec in [
			["draw", "Draw New Block", draw_new_block, "Clear and draw a new block outline"],
			["generate", "Generate City Block", generate_pressed, "Subdivide the drawn block into 5 or 6 houses"],
			["regenerate", "Regenerate Houses", regenerate_pressed, "A new set of houses in the same block"],
			["left", "↶ Rotate Left", rotate_left, "Turn the view 45° counter-clockwise"],
			["right", "Rotate Right ↷", rotate_right, "Turn the view 45° clockwise"],
			["coords", "Show Coordinates", show_coordinates, "Coordinate schematic of the block and the selected house"],
			["back", "Back to 3D", back_to_3d, "Return to the 3D city view"],
			["level_block", "Block Coordinates", show_block_coordinates, "Block outline, plots, party walls and entrances"],
			["level_house", "Selected House", show_house_coordinates, "Rooms, walls and doors of the selected house"]]:
		var b := Button.new()
		b.text = spec[1]
		b.custom_minimum_size = Vector2(0, 34)
		b.tooltip_text = spec[3]
		b.pressed.connect(spec[2])
		bar.add_child(b)
		buttons[spec[0]] = b

	info = Label.new()
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_font_size_override("font_size", 13)
	root.add_child(info)

	var stage := Control.new()
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.custom_minimum_size = Vector2(200, 180)
	root.add_child(stage)
	draw_view = DrawView.new()
	draw_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	draw_view.polygon_closed.connect(_on_polygon_closed)
	draw_view.house_clicked.connect(select_house)
	draw_view.message.connect(func(t): _set_info(t, false))
	stage.add_child(draw_view)
	view3d = House3DView.new()
	view3d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view3d.house_clicked.connect(select_house)
	stage.add_child(view3d)
	schematic = SchematicView.new()
	schematic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	schematic.house_clicked.connect(select_house)
	stage.add_child(schematic)

	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_size_override("font_size", 11)
	status.add_theme_color_override("font_color", Color(0.3, 0.26, 0.22))
	status.text = ("Classical Greek pastas houses after the Olynthian type, built together in one block; every block edge is a street. "
		+ "Walls are cut away at 0.8 m to show the plans. The 16 m² courtyard, footprint rules and all dimensions are project constraints, not ancient standards.")
	root.add_child(status)

	draw_new_block()


# --------------------------------------------------------------------------
# Workflow
# --------------------------------------------------------------------------

func draw_new_block() -> void:
	polygon = PackedVector2Array()
	block = {}
	selected = 0
	view3d.clear()
	draw_view.reset()
	mode = "draw"
	_set_info("Click to place the corners of the block; click the first corner to close it.", false)
	_refresh()


## Called when the drawn outline is closed (by the canvas, or by tests).
func _on_polygon_closed(poly: PackedVector2Array) -> void:
	polygon = poly
	var problem := BG.check_block_polygon(poly)
	if problem != "":
		_set_info("This block cannot be used: %s." % problem, true)
	else:
		_set_info("Block closed: %d corners, %.0f m². Press \"Generate City Block\"." % [poly.size(), BG.G.polygon_area(poly)], false)
	_refresh()


func generate_pressed() -> void:
	await _generate_after_frame()


func regenerate_pressed() -> void:
	await _generate_after_frame()


func _generate_after_frame() -> void:
	_set_info("Generating and validating the city block…", false)
	await get_tree().process_frame
	generate(randi() % 1000000)


## Subdivides the drawn polygon, builds and validates the block. Only a block
## that passes every check is kept and shown; otherwise the reason is shown.
func generate(block_seed: int) -> bool:
	if polygon.size() < 3 or BG.check_block_polygon(polygon) != "":
		return false
	var t0 := Time.get_ticks_usec()
	var res := BG.generate_block(polygon, block_seed)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	generation += 1
	if not res["ok"]:
		block = {}
		view3d.clear()
		last_reason = res["reason"]
		mode = "draw"
		draw_view.show_block({}, -1)
		_set_info("GENERATION FAILED — %s. Try \"Regenerate Houses\" or draw a broader block (long sides roughly east–west)." % res["reason"], true)
		_refresh()
		return false
	block = res["block"]
	selected = 0
	draw_view.show_block(block, selected)
	view3d.show_block(block, selected)
	mode = "3d"
	_set_info("", false)
	_refresh()
	status.text = "%d houses generated and validated in %.0f ms (%d layouts tried, seed %d). " % [block["houses"].size(), ms, res["attempts"], block_seed] \
		+ "Every block edge is a street; each house has its own entrance on it. Walls cut away at 0.8 m; dimensions are project constraints."
	return true


func select_house(index: int) -> void:
	if block.is_empty() or index < 0 or index >= block["houses"].size():
		return
	selected = index
	view3d.set_selected(index)
	draw_view.show_block(block, index)
	_refresh()


func rotate_left() -> void:
	view3d.rotate_view(-1)


func rotate_right() -> void:
	view3d.rotate_view(1)


func show_coordinates() -> void:
	if block.is_empty():
		return
	mode = "schematic"
	_refresh()


func back_to_3d() -> void:
	if block.is_empty():
		return
	mode = "3d"
	_refresh()


func show_block_coordinates() -> void:
	schematic_level = "block"
	show_coordinates()


func show_house_coordinates() -> void:
	schematic_level = "house"
	show_coordinates()


# --------------------------------------------------------------------------
# Display
# --------------------------------------------------------------------------

func _refresh() -> void:
	var has_block := not block.is_empty()
	var closed: bool = draw_view.closed and BG.check_block_polygon(polygon) == ""
	if mode != "draw" and not has_block:
		mode = "draw"
	draw_view.visible = mode == "draw"
	view3d.visible = mode == "3d"
	schematic.visible = mode == "schematic"
	if mode == "schematic":
		if schematic_level == "block":
			schematic.show_block(block, selected)
		else:
			schematic.show_house(block["houses"][selected], "House %d of %d" % [selected + 1, block["houses"].size()])
	buttons["generate"].disabled = not closed or has_block
	buttons["regenerate"].disabled = not closed
	buttons["left"].disabled = mode != "3d"
	buttons["right"].disabled = mode != "3d"
	buttons["coords"].visible = mode != "schematic"
	buttons["coords"].disabled = not has_block
	buttons["back"].visible = mode == "schematic" or (mode == "draw" and has_block)
	buttons["level_block"].visible = mode == "schematic"
	buttons["level_house"].visible = mode == "schematic"
	buttons["level_block"].disabled = schematic_level == "block"
	buttons["level_house"].disabled = schematic_level == "house"
	if has_block and info.get_meta("sticky", false) == false:
		var v: Dictionary = block["validation"]
		var h: Dictionary = block["houses"][selected]
		info.text = "VALID CITY BLOCK · %d houses (B00–B07, H00–H12 each) · selected: House %d — %d sides, %.1f m², courtyard 16.0 m², entrance on the %s street" % [
			block["houses"].size(), selected + 1, h["validation"]["sides"], BG.G.polygon_area(h["footprint"]), h["street_side"]]
		if v["residual_area"] > 1.0:
			info.text += " · unbuilt corner ground %.0f m²" % v["residual_area"]
		info.add_theme_color_override("font_color", Color(0.15, 0.42, 0.2))


func _set_info(text: String, error: bool) -> void:
	info.set_meta("sticky", text != "")
	if text != "":
		info.text = text
		info.add_theme_color_override("font_color", Color(0.7, 0.15, 0.12) if error else Color(0.2, 0.16, 0.12))
	else:
		info.set_meta("sticky", false)
