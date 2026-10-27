# Ancient Greek House Generator (Godot 4 prototype)

Generates top-down plans of Classical Greek courtyard houses of the
**Olynthian pastas type**. Each press of **Generate 5 Houses** builds five new
plans; every plan shown has passed the hard-rule validator (H01–H10). If a slot
cannot produce a valid house within 10 candidates, it shows a generation error
and never shows an invalid plan.

![Five generated plans](docs/screenshot.png)

## Running

- Open the folder in **Godot 4.3+** and press Play (main scene: `scenes/main.tscn`).
- Headless smoke test (20 seeded houses + negative validator checks; exits 1 on failure):

  ```sh
  godot --headless --path . --script res://tests/smoke_test.gd
  ```

## Layout

| File | Role |
|---|---|
| `scripts/house_generator.gd` | Builds candidates by construction, then calls the validator; bounded retries (max 10). |
| `scripts/house_validator.gd` | `validate_house(house) -> {valid, errors}`; explicit checks for H01–H10 and all prototype dimensions. |
| `scripts/house_view.gd` | `_draw()` rendering of one plan. Reads data only. |
| `scripts/main.gd` | UI: button, five views, status line. |
| `tests/smoke_test.gd` | Headless smoke test. |

## Geometry model

- Metres; X grows east, Y grows south, north is up. Everything is axis-aligned.
- **Spaces** (rooms, courtyard, pastas, entrance passage) are clear interior
  rectangles. **Walls** are separate rectangles (exterior 0.50 m, interior
  0.25 m). **Door openings** are rectangles cut out of a wall line, so the wall
  really has a gap. The pastas–courtyard boundary is a zero-thickness open
  edge (no wall).
- Spaces + walls + door gaps tile the footprint exactly; the validator checks
  this (no overlaps, no gaps), so courtyard and room areas never include walls.
- Circulation is a graph: nodes are spaces plus the street; an edge exists only
  for an opening whose rectangle sits flush between the two spaces it joins.

## Generation (construction by constraints)

1. Pick a courtyard of exactly 16 m² (4×4, 3.2×5 or 5×3.2 m).
2. Pick depths for the northern wing (3.0–4.5 m) and pastas (1.5–2.5 m).
3. Lay out the southern zone as west→east strips: optional side-room strip,
   courtyard and entrance passage (either order), optional side-room strip.
   The courtyard sits directly under the pastas and runs to the south wall.
4. The northern wing and pastas span the full interior width above it.
5. Choose a room count (4–9); if it does not fit, lower it; if no legal count
   fits, discard the candidate.
6. Partition the wing into rooms with full-depth partitions; split side strips
   into one or two rooms.
7. Add doors (north rooms → pastas; side rooms → courtyard/passage or pastas;
   passage → courtyard; street → passage), then cut them out of the walls.
8. Validate. Only a house with zero errors is returned.

Generation and validation take a few milliseconds per house.

## Hard rules (enforced in `house_validator.gd`)

| Rule | Checked numerically |
|---|---|
| H01 | Exactly one courtyard; `w*d = 16.0 ± 0.001 m²`; inside the footprint; nothing overlaps it. |
| H02 | `north_wing.width > north_wing.depth`; `north_wing.bottom <= pastas.top`; north of the courtyard; holds its rooms; at least one opens to the pastas. |
| H03 | `courtyard.center_y > building.center_y`; courtyard's north edge flush with the pastas. |
| H04 | One pastas, depth 1.5–2.5 m, E–W axis, directly north of the courtyard, verified open edge to the courtyard with no wall across it, door to a north room. |
| H05 | Positive sizes; everything inside the footprint; spaces inside the exterior walls; no pairwise overlaps; area of spaces+walls+gaps = footprint area. |
| H06 | Wall thicknesses; rooms ≥ 2.0 m wide, ≥ 5.0 m², short span ≤ 5.0 m; doors ≥ 0.80 m; every door is a gap flanked by the same wall line. |
| H07 | Every opening verified geometrically; BFS from the street reaches every space. |
| H08 | Valid entrance on the street (south) side, into a passage that opens to the courtyard (or into the courtyard); not blocked; courtyard reachable. |
| H09 | 4–9 rooms; known function; every room opens directly onto pastas, courtyard or passage. |
| H10 | North-wing rooms span the full wing depth (aligned E–W divisions) and wing = rooms + N–S partitions; every interior wall end meets another wall, a door gap, or ends as an anta on the pastas line; all walls connect to the exterior walls. |

## What is historical, what is a project rule, what is an assumption

**Archaeological evidence (Olynthos, c. 430–348 BCE).** Houses on the North
Hill were laid out in regular blocks; a typical house was entered from the
street, organised around a courtyard in the southern part, with a broad covered
portico (*pastas*) on the north side of the court opening south, and a range of
rooms behind it. Rooms opened mainly onto the court and pastas. Some houses had
an *andron* (dining room), often recognisable by an off-centre door and raised
couch border, and frequently placed near the street; many had a kitchen/hearth
room (*oikos*) in the northern range. See the
[Olynthos Project](https://sites.lsa.umich.edu/olynthos-project/olynthian-houses/)
and [House A vii 4](https://perseus-aa.github.io/items/aa_398.html). Olynthian
houses were typically much larger (around 17 × 17 m) with larger courtyards than
this prototype produces.

**Project-specific mandatory constraints.** The 16 m² courtyard, the pastas
depth range, the 4–9 room count, a south street and the H01–H10 rules are
requirements of this project, not ancient standards.

**Simplified engineering assumptions.** Wall thicknesses (0.50/0.25 m), minimum
room width/area, 5 m maximum clear span, 0.80 m minimum door, axis-aligned
rectangles, the 5 cm construction grid, and the wall-alignment test standing in
for structural analysis. Room functions are illustrative labels.

Scope: version 1 models only the later Classical pastas house. It does not
represent all Greek houses of 550–350 BCE (e.g. prostas houses, irregular or
rural houses).
