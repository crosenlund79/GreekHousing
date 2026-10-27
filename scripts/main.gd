extends Control
## Main screen: five stored, validated houses shown one at a time.
## Navigation only changes which stored house is displayed; only
## "Regenerate All Houses" generates (and validates) new data.

const Generator := preload("res://scripts/house_generator.gd")
const HouseView := preload("res://scripts/house_view.gd")
const HOUSE_COUNT := 5

var houses: Array = []      # generate_valid_house() results, one per slot
var index := 0
var generation := 0         # number of times the five houses were (re)generated
var view: Control
var counter: Label
var status: Label


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.93, 0.91, 0.86)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var title := Label.new()
	title.text = "Ancient Greek House Generator"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.2, 0.16, 0.12))
	root.add_child(title)

	# Wraps onto two lines on narrow windows.
	var bar := HFlowContainer.new()
	bar.alignment = FlowContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("h_separation", 10)
	bar.add_theme_constant_override("v_separation", 6)
	root.add_child(bar)
	var prev := _button("◀", show_previous, Vector2(48, 34))
	prev.tooltip_text = "Previous house"
	bar.add_child(prev)
	counter = Label.new()
	counter.custom_minimum_size = Vector2(96, 34)
	counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	counter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	counter.add_theme_font_size_override("font_size", 17)
	counter.add_theme_color_override("font_color", Color(0.2, 0.16, 0.12))
	bar.add_child(counter)
	var next := _button("▶", show_next, Vector2(48, 34))
	next.tooltip_text = "Next house"
	bar.add_child(next)
	bar.add_child(_button("Regenerate All Houses", regenerate_all, Vector2(200, 34)))

	view = Control.new()
	view.set_script(HouseView)
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.custom_minimum_size = Vector2(200, 200)
	root.add_child(view)

	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_size_override("font_size", 12)
	status.add_theme_color_override("font_color", Color(0.3, 0.26, 0.22))
	root.add_child(status)

	regenerate_all()


func _button(text: String, action: Callable, min_size: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
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
	status.text = ("%d/%d houses valid (H00–H10) · %d candidates rejected · generated and validated in %.1f ms · base seed %d.  "
		+ "Classical Greek pastas houses after the Olynthian type; street to the south. "
		+ "The 16 m² courtyard and all dimensions are project constraints, not ancient standards.") \
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


func _show_current() -> void:
	counter.text = "House %d / %d" % [index + 1, houses.size()]
	view.show_result(houses[index], index + 1, houses.size())


static func _signature(house: Dictionary) -> String:
	return str(house["footprint"]) + str(house["spaces"].map(func(s): return s["rect"]))
