# CLAUDE.md

Godot 4 (GDScript) prototype that subdivides a user-drawn city block into 5–6
Olynthian pastas-type Greek houses and shows them together in 3D.

## Commands

- Smoke test (must pass before committing):
  `godot --headless --path . --script res://tests/smoke_test.gd </dev/null` — exit code 0 = pass.
  `ERROR: Parameter "m" is null` lines are a Godot 4.3 dummy-renderer quirk when
  ArrayMeshes are freed headless; ignore them, never "fix" them by skipping checks.
- Run the app: open in Godot 4.3+ and play `scenes/main.tscn`.

## Non-negotiable rules

- Hard rules H00–H12 are absolute (H00 = 4–6-sided simple footprint polygon,
  H11 = no footprint interior angle in [80°, 110°], inclusive, H12 = entrance
  directly on the street frontage, H12.1 = frontage ≥ 2.0 m continuous), and so
  are the block rules B00–B07 (`block_validator.gd`: 5 or 6 houses, inside the
  block, no overlaps, no shared spaces/courtyards, entrances on the block
  perimeter, one shared north). Never weaken, skip or bypass a validator check
  to make generation succeed; fix the generator instead.
- The app is a city-block generator: the user draws the block polygon, every
  block edge is a street, and `block_generator.gd` subdivides it into 5 or 6
  plots (6 tried first) with one house each. Never fall back to a standalone
  house view or "House 1/5" navigation; never add shared passages, communal
  courtyards or open spaces.
- Only a block whose `validate_block` result is `valid == true` (which includes
  `validate_house` for every house) may be displayed. Failures show
  "GENERATION FAILED" with the reason and no houses.
- Attempts are bounded: `LAYOUT_ATTEMPTS = 30` per house count and
  `HOUSE_ATTEMPTS = 10` per plot (`block_generator.gd`); `MAX_ATTEMPTS = 10`
  for the standalone generator. Generation is deterministic per outline and
  seed: use the passed `RandomNumberGenerator`, never `Array.shuffle()`,
  `randf()` or `randi()`.
- Keep generation, validation and rendering separate: validators work only on
  the block/house Dictionaries; views only draw them.
- One geometry model: the block Dictionary `{polygon, houses, plots, seed,
  validation}`, houses in global coordinates (never rotated). Generator,
  validators, drawing canvas, 3D view and coordinate schematic all read it;
  measurements go through `scripts/geometry.gd` (area, edges, angles,
  point-in-polygon, local coordinates, world→screen). Never keep a second copy
  of the geometry.
- Validate against actual geometry, never metadata: side count from the polygon,
  northern wing from the rooms north of the pastas, areas from shapes,
  entrances on the block perimeter from the entrance's outer face.
- UI: "Generate City Block" / "Regenerate Houses" are the only things that
  generate (Regenerate keeps the drawn polygon); "Draw New Block" clears.
  Selecting a house, rotation and "Show Coordinates" / "Back to 3D" /
  "Block Coordinates" / "Selected House" never regenerate or rebuild the 3D
  model, and the selected house stays selected.
- The 3D view (`house_3d_view.gd`) shows all houses of the block in one model,
  built only from validated data, one floor per space, one solid per wall
  record — never invent walls or roofs. Selection only rebuilds the overlay.

## Conventions

- Metres, X east, Y south, north up. Interior geometry is axis-aligned `Rect2`;
  the footprint is a `PackedVector2Array`; items that are not rectangles (clipped
  room, mitred exterior wall quads) add an exact `poly` and keep `rect` as bbox.
- Block plots: one row ("through") or a north and a south row split by an E–W
  row line on the 5 cm grid; party walls tilted 22–42° from N–S (never 90°
  corners); block ends that do not fit stay unbuilt corner ground. North-row
  houses enter from the north street through a wing passage; south/through
  houses from the south street through a street-range passage.
- Standalone houses: north and south faces horizontal; east/west sides "slant"
  (tilt 21.5–24°) or "vee" (inward point on an E–W wall line, tilt ≥ 12°).
- Outer rooms are widened by the intrusion, then spaces/walls are clipped to
  the interior polygon. Never clip the courtyard, entrance passage or door gaps.
- Spaces, walls and door gaps tile the footprint exactly; openings are flush
  between the two spaces they join (`axis` = direction of travel).
- The generator works on an integer centimetre grid (5 cm steps) and emits metres.
- Prototype dimensions live as constants at the top of `house_validator.gd`.
- Scripts are referenced with `preload` (no `class_name`) so headless runs need no import step.
- GDScript parse errors make headless Godot wait in the debugger; run with
  `</dev/null` (or a timeout) so a broken script fails instead of hanging.
- The smoke test's UI check runs in `_process` (the tree is not live in `_initialize`).
- No external assets, plugins or test frameworks. Keep it small.
- Label historical claims vs project constraints vs engineering assumptions (see README).
