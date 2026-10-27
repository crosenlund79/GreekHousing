extends Control
## Main screen: one button and five independently generated, validated plans.

const Generator := preload("res://scripts/house_generator.gd")
const HouseView := preload("res://scripts/house_view.gd")
const HOUSE_COUNT := 5

var views: Array = []
var status: Label


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.93, 0.91, 0.86)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 12)
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 16)
	root.add_child(bar)
	var button := Button.new()
	button.text = "Generate 5 Houses"
	button.custom_minimum_size = Vector2(190, 36)
	button.pressed.connect(_generate)
	bar.add_child(button)
	status = Label.new()
	status.add_theme_color_override("font_color", Color(0.2, 0.17, 0.14))
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(status)

	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 10)
	root.add_child(row)
	for i in HOUSE_COUNT:
		var view := Control.new()
		view.set_script(HouseView)
		view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		view.custom_minimum_size = Vector2(220, 320)
		row.add_child(view)
		views.append(view)

	var note := Label.new()
	note.text = "Classical Greek pastas houses after the Olynthian type (c. 430–348 BCE). " \
		+ "Street to the south. 16 m² courtyard and all dimensions are project constraints, not ancient standards. " \
		+ "Every plan shown passed validator rules H01–H10."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 12)
	note.add_theme_color_override("font_color", Color(0.3, 0.26, 0.22))
	root.add_child(note)

	_generate()


func _generate() -> void:
	var t0 := Time.get_ticks_usec()
	var base_seed := randi() % 1000000
	var seen := {}
	var valid := 0
	var rejected := 0
	for i in HOUSE_COUNT:
		var result := {}
		# Re-roll (bounded) if a seed happens to repeat an earlier plan.
		for k in 5:
			result = Generator.generate_valid_house(base_seed + i * 7919 + k * 104729)
			rejected += result["rejections"].size()
			if not result["ok"] or not seen.has(_signature(result["house"])):
				break
		if result["ok"]:
			seen[_signature(result["house"])] = true
			valid += 1
		views[i].show_result(result, "House %d" % (i + 1))
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	status.text = "%d/%d houses valid · %d candidates rejected · generated and validated in %.1f ms · base seed %d" \
		% [valid, HOUSE_COUNT, rejected, ms, base_seed]


static func _signature(house: Dictionary) -> String:
	return str(house["spaces"].map(func(s): return s["rect"]))
