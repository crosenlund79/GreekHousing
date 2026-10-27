# CLAUDE.md

Godot 4 (GDScript) prototype that generates Olynthian pastas-type Greek house plans.

## Commands

- Smoke test (must pass before committing):
  `godot --headless --path . --script res://tests/smoke_test.gd </dev/null` — exit code 0 = pass.
  `ERROR: Parameter "m" is null` lines are a Godot 4.3 dummy-renderer quirk when
  ArrayMeshes are freed headless; ignore them, never "fix" them by skipping checks.
- Run the app: open in Godot 4.3+ and play `scenes/main.tscn`.

## Non-negotiable rules

- Hard rules H00–H11 are absolute (H00 = 4–6-sided simple footprint polygon,
  H11 = no footprint interior angle in [80°, 110°], inclusive). Never weaken, skip or bypass a validator
  check to make generation succeed; fix the generator instead.
- Only houses for which `house_validator.gd::validate_house` returns
  `valid == true` may be displayed as plans. Failures show an error slot.
- Retries are bounded (`MAX_ATTEMPTS = 10` in `house_generator.gd`).
- Keep generation, validation and rendering separate: the validator works only on
  the house Dictionary; `house_view.gd` only draws it.
- Validate against actual geometry, never metadata: side count from the polygon,
  northern wing from the rooms north of the pastas, areas from shapes.
- UI: five houses are generated at startup and on "Regenerate All Houses" only.
  ◀ / ▶ just change `main.index` (wrapping) and rebuild the 3D model of the
  selected house; they must never regenerate. Rotation only moves the camera.
- The 3D view (`house_3d_view.gd`) builds meshes only from validated data
  (`validation.valid`), one floor per space, one solid per wall record — never
  invent walls or roofs. Only the selected house's meshes exist.

## Conventions

- Metres, X east, Y south, north up. Interior geometry is axis-aligned `Rect2`;
  the footprint is a `PackedVector2Array`; items that are not rectangles (clipped
  room, mitred exterior wall quads) add an exact `poly` and keep `rect` as bbox.
- North and south faces stay horizontal; east/west sides are "slant" (one side,
  tilt 21.5–24°) or "vee" (inward point on an E–W wall line, tilt ≥ 12°).
  4 = slant+slant, 5 = vee+slant, 6 = vee+vee. Outer rooms are widened by the
  intrusion, then spaces/walls are clipped to the interior polygon. Never clip
  the courtyard, entrance passage or door gaps.
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
