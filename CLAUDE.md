# CLAUDE.md

Godot 4 (GDScript) prototype that generates Olynthian pastas-type Greek house plans.

## Commands

- Smoke test (must pass before committing):
  `godot --headless --path . --script res://tests/smoke_test.gd` — exit code 0 = pass.
- Run the app: open in Godot 4.3+ and play `scenes/main.tscn`.

## Non-negotiable rules

- Hard rules H01–H10 are absolute. Never weaken, skip or bypass a validator
  check to make generation succeed; fix the generator instead.
- Only houses for which `house_validator.gd::validate_house` returns
  `valid == true` may be displayed as plans. Failures show an error slot.
- Retries are bounded (`MAX_ATTEMPTS = 10` in `house_generator.gd`).
- Keep generation, validation and rendering separate: the validator works only on
  the house Dictionary; `house_view.gd` only draws it.

## Conventions

- Metres, X east, Y south, north up, axis-aligned `Rect2`.
- Spaces, walls and door gaps tile the footprint exactly; openings are flush
  between the two spaces they join (`axis` = direction of travel).
- The generator works on an integer centimetre grid (5 cm steps) and emits metres.
- Prototype dimensions live as constants at the top of `house_validator.gd`.
- Scripts are referenced with `preload` (no `class_name`) so headless runs need no import step.
- No external assets, plugins or test frameworks. Keep it small.
- Label historical claims vs project constraints vs engineering assumptions (see README).
