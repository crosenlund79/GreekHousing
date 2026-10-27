extends Control
## Main screen: five stored, validated houses shown one at a time, as a 3D
## cutaway (default), the 2D plan or the coordinate schematic. All three views
## draw the same stored house Dictionary; switching views never regenerates or
## changes it, and the selected house stays selected.
## Navigation only changes which stored house is displayed (and rebuilds the
## 3D model for it); only "Regenerate All Houses" generates and validates new
## data. Camera rotation never regenerates or rebuilds anything.

const Generator := preload("res://scripts/house_generator.gd")
const HouseView := preload("res://scripts/house_view.gd")
const House3DView := preload("res://scripts/house_3d_view.gd")
const SchematicView := preload("res://scripts/house_schematic_view.gd")
const G := preload("res://scripts/geometry.gd")
const HOUSE_COUNT := 5

var houses: Array = []      # generate_valid_house() results, one per slot
var index := 0
var generation := 0         # number of times the five houses were (re)generated
var mode := "3d"            # "3d", "plan" or "schematic"
var view3d: SubViewportContainer
var plan_view: Control
var schematic: Control
var counter: Label
var info: Label
var status: Label
var rotate_buttons: Array = []
var plan_button: Button
var coords_button: Button
var back_button: Button


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
	title.text = "Ancient Greek House Generator"
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
	var nav := HBoxContainer.new()
	bar.add_child(nav)
	nav.add_child(_button("◀", show_previous, Vector2(44, 34), "Previous house"))
	counter = Label.new()
	counter.custom_minimum_size = Vector2(96, 34)
	counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	counter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	counter.add_theme_font_size_override("font_size", 17)
	counter.add_theme_color_override("font_color", Color(0.2, 0.16, 0.12))
	nav.add_child(counter)
	nav.add_child(_button("▶", show_next, Vector2(44, 34), "Next house"))
	var turn := HBoxContainer.new()
	bar.add_child(turn)
	rotate_buttons = [
		_button("↶ Rotate Left", rotate_left, Vector2(0, 34), "Turn the view 45° counter-clockwise"),
		_button("Rotate Right ↷", rotate_right, Vector2(0, 34), "Turn the view 45° clockwise"),
	]
	for b in rotate_buttons:
		turn.add_child(b)
	bar.add_child(_button("Regenerate All Houses", regenerate_all, Vector2(0, 34), "Generate and validate five new houses"))
	plan_button = _button("2D Plan", toggle_plan, Vector2(0, 34), "Show the 2D plan of the selected house")
	bar.add_child(plan_button)
	coords_button = _button("Show Coordinates", show_coordinates, Vector2(0, 34), "Technical schematic with coordinates of the selected house")
	bar.add_child(coords_button)
	back_button = _button("Back to 3D", back_to_3d, Vector2(0, 34), "Return to the 3D view of the selected house")
	bar.add_child(back_button)

	info = Label.new()
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_font_size_override("font_size", 13)
	root.add_child(info)

	var stage := Control.new()
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.custom_minimum_size = Vector2(200, 180)
	root.add_child(stage)
	view3d = House3DView.new()
	view3d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.add_child(view3d)
	plan_view = Control.new()
	plan_view.set_script(HouseView)
	plan_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.add_child(plan_view)
	schematic = SchematicView.new()
	schematic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.add_child(schematic)

	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_size_override("font_size", 11)
	status.add_theme_color_override("font_color", Color(0.3, 0.26, 0.22))
	root.add_child(status)

	regenerate_all()


func _button(text: String, action: Callable, min_size: Vector2, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.tooltip_text = tip
	b.pressed.connect(action)
	return b


## Generates and validates five new houses, replacing the stored ones.
func regenerate_all() -> void:
	var t0 := Time.get_ticks_usec()
	var base_seed := randi() % 1000000
	var seen := {}
	for old in houses:
		if old["ok"]:
			seen[_signature(old["house"])] = true   # new set must differ from the old one
	var fresh: Array = []
	var valid := 0
	var rejected := 0
	for i in HOUSE_COUNT:
		var result := {}
		# Re-roll (bounded) if a seed happens to repeat an existing plan.
		for k in 5:
			result = Generator.generate_valid_house(base_seed + i * 7919 + k * 104729)
			rejected += result["rejections"].size()
			if not result["ok"] or not seen.has(_signature(result["house"])):
				break
		if result["ok"]:
			seen[_signature(result["house"])] = true
			valid += 1
		fresh.append(result)
	houses = fresh
	generation += 1
	index = 0
	_show_current()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	status.text = ("%d/%d houses valid (H00–H12) · %d candidates rejected · generated, validated and built in %.1f ms · base seed %d.  "
		+ "Classical Greek pastas houses after the Olynthian type; street to the south. Walls are cut away at 0.8 m to show the plan. "
		+ "The 16 m² courtyard, footprint shapes and all dimensions are project constraints, not ancient standards.") \
		% [valid, HOUSE_COUNT, rejected, ms, base_seed]


func show_next() -> void:
	if houses.is_empty():
		return
	index = (index + 1) % houses.size()
	_show_current()


func show_previous() -> void:
	if houses.is_empty():
		return
	index = (index - 1 + houses.size()) % houses.size()
	_show_current()


func rotate_left() -> void:
	view3d.rotate_view(-1)


func rotate_right() -> void:
	view3d.rotate_view(1)


func toggle_plan() -> void:
	mode = "3d" if mode == "plan" else "plan"
	_show_current()


func show_coordinates() -> void:
	mode = "schematic"
	_show_current()


func back_to_3d() -> void:
	mode = "3d"
	_show_current()


## Displays the selected stored house. Only a validated house reaches the 3D
## view; a failed slot shows the generation error panel instead.
func _show_current() -> void:
	var result: Dictionary = houses[index]
	var valid: bool = result["ok"] and result["house"].get("validation", {}).get("valid", false)
	counter.text = "House %d / %d" % [index + 1, houses.size()]
	plan_view.show_result(result, index + 1, houses.size())
	# Each view only rebuilds when the house itself changes (show_house checks identity).
	var shown_3d: bool = valid and view3d.show_house(result["house"])
	if not valid:
		view3d.clear()
	var shown_schematic: bool = valid and schematic.show_house(result["house"], counter.text)
	view3d.visible = shown_3d and mode == "3d"
	schematic.visible = shown_schematic and mode == "schematic"
	plan_view.visible = not view3d.visible and not schematic.visible
	for b in rotate_buttons:
		b.disabled = not view3d.visible
	plan_button.visible = mode != "plan"
	coords_button.visible = mode != "schematic"
	coords_button.disabled = not valid
	back_button.visible = mode != "3d"
	if valid:
		var h: Dictionary = result["house"]
		var fp_box := G.bbox(h["footprint"])
		info.text = "VALID H00–H12 · %d exterior sides (%s) · %d rooms · %.1f × %.1f m · seed %d" % [
			h["validation"]["sides"], h["shape"], h["spaces"].filter(func(s): return s["kind"] == "room").size(),
			fp_box.size.x, fp_box.size.y, h["seed"]]
		info.add_theme_color_override("font_color", Color(0.15, 0.42, 0.2))
	else:
		info.text = "GENERATION ERROR — no valid house for this slot; nothing is displayed as a house."
		info.add_theme_color_override("font_color", Color(0.7, 0.15, 0.12))


static func _signature(house: Dictionary) -> String:
	return str(house["footprint"]) + str(house["spaces"].map(func(s): return s["rect"]))
