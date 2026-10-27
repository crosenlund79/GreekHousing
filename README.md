# Ancient Greek House Generator (Godot 4 prototype)

Generates top-down plans of Classical Greek courtyard houses of the
**Olynthian pastas type**, with 4-, 5- or 6-sided exterior footprints. Every
plan shown has passed the hard-rule validator (H00–H10). If a slot cannot
produce a valid house within 10 candidates, it shows a generation error and
never shows an invalid plan.

![The five stored houses of one batch](docs/screenshot.png)

## Using the app

- On startup five different houses are generated, validated and stored; house 1 is shown.
- **◀ / ▶** show the previous / next stored house and wrap (5 → 1, 1 → 5).
  Navigation never generates anything; it only changes which stored house is drawn.
- **Regenerate All Houses** generates and validates five new houses (guaranteed
  different from the previous set), replaces the stored set and returns to house 1.
- The plan is scaled uniformly to the available area (no distortion) and
  redraws on window resize; the button row wraps on narrow windows.
- The header shows the house number, the VALID badge and the number of
  exterior sides as computed by the validator from the polygon.

## Running

- Open the folder in **Godot 4.3+** and press Play (main scene: `scenes/main.tscn`).
- Headless smoke test (seeded 4/5/6-sided houses, navigation/regeneration
  behaviour, negative validator checks; exits 1 on failure):

  ```sh
  godot --headless --path . --script res://tests/smoke_test.gd
  ```

## Layout

| File | Role |
|---|---|
| `scripts/house_generator.gd` | Builds candidates by construction, then calls the validator; bounded retries (max 10). |
| `scripts/house_validator.gd` | `validate_house(house) -> {valid, errors, sides}`; explicit checks for H00–H10 and all prototype dimensions. |
| `scripts/house_view.gd` | Single custom `_draw()` Control rendering one plan. Reads data only. |
| `scripts/main.gd` | UI: title, ◀ / ▶ navigation, counter, regenerate button; stores the five results. |
| `tests/smoke_test.gd` | Headless smoke test. |

## Geometry model

- Metres; X grows east, Y grows south, north is up. Everything inside the
  house is axis-aligned; only the exterior footprint may have a slanted side.
- **Footprint**: a polygon (`PackedVector2Array`). The exterior wall band is
  the footprint minus its 0.50 m inset; it is stored as one mitred quad per
  side (the entrance side is split around the entrance gap).
- **Spaces** (rooms, courtyard, pastas, entrance passage) are clear interior
  rectangles. **Walls** are separate rectangles (exterior 0.50 m, interior
  0.25 m). **Door openings** are rectangles cut out of a wall line, so the wall
  really has a gap. The pastas–courtyard boundary is a zero-thickness open
  edge (no wall).
- A room under a clipped corner carries an exact `poly` (its `rect` is then the
  bounding box) and its area is the polygon area.
- Spaces + walls + door gaps tile the footprint polygon exactly; the validator
  checks this (no overlaps, no gaps), so courtyard and room areas never include walls.
- Circulation is a graph: nodes are spaces plus the street; an edge exists only
  for an opening whose rectangle sits flush between the two spaces it joins.

## Footprints (rule H00)

| Sides | Shape | How it is built |
|---|---|---|
| 4 | rectangle | — |
| 5 | clipped corner | One southern corner is cut by a 45° side over a side room (never the wing, courtyard or entrance). The room keeps a convex shape with 135° corners and ≥ 75 % of its box. |
| 6 | L-shape | A rectangular notch is removed from one southern corner under a side room; the other side forms the extension holding rooms. The notch's exterior wall continues the courtyard/passage face so no sliver is created. |

An orthogonal polygon always has an even number of sides, so a 5-sided
footprint needs one slanted side. The northern wing stays rectangular and
east–west in all three shapes. The side count is drawn per house from its seed.

H00 is checked on the polygon itself: at least 3 vertices, no zero-length
edges (including a repeated closing vertex), no collinear consecutive edges,
positive area, no intersections between non-adjacent edges, and 4–6 sides.

## Generation (construction by constraints)

1. Choose 4, 5 or 6 sides (seeded) and pick a courtyard of exactly 16 m² (4×4, 3.2×5 or 5×3.2 m).
2. Pick depths for the northern wing (3.0–4.5 m) and pastas (1.5–2.5 m).
3. Lay out the southern zone as west→east strips: optional side-room strip,
   courtyard and entrance passage (either order), optional side-room strip.
   The courtyard sits directly under the pastas and runs to the south wall.
4. The northern wing and pastas span the full interior width above it.
5. Choose a room count (4–9); if it does not fit, lower it; if no legal count
   fits, discard the candidate.
6. Partition the wing into rooms with full-depth partitions; split side strips
   into one or two rooms.
7. Shape the footprint: clip a corner (5) or cut a notch (6) under a side
   strip; build the mitred exterior wall band.
8. Add doors (north rooms → pastas; side rooms → courtyard/passage or pastas;
   passage → courtyard; street → passage), then cut them out of the walls.
9. Validate. Only a house with zero errors is returned.

Generation and validation take a few milliseconds per house (≈ 15 ms for five).

## Hard rules (enforced in `house_validator.gd`)

All quantities are derived from geometry, not metadata: areas from the
shapes, the side count from the polygon, the northern wing from the rooms
lying north of the pastas, access from opening positions, containment by
polygon clipping against the actual footprint.

| Rule | Checked numerically |
|---|---|
| H00 | Footprint polygon: simple, closed, positive area, no zero-length or collinear edges, 4–6 sides. |
| H01 | Exactly one courtyard; `w*d = 16.0 ± 0.001 m²`; inside the footprint; nothing overlaps it. |
| H02 | Wing = bounding box of the rooms north of the pastas: `width > depth`, `bottom <= pastas.top`, north of the courtyard, inside the footprint; at least one wing room opens to the pastas. |
| H03 | `courtyard.center_y >` footprint bounding-box `center_y`; courtyard's north edge flush with the pastas. |
| H04 | One pastas, depth 1.5–2.5 m, E–W axis, directly north of the courtyard, verified open edge to the courtyard with no wall across it, door to a north room. |
| H05 | Positive sizes; everything inside the footprint polygon; spaces inside the exterior wall band; no pairwise overlaps; area of spaces+walls+gaps = footprint area. |
| H06 | Interior walls 0.25 m; exterior walls lie in, and exactly fill, the 0.50 m band; rooms ≥ 2.0 m wide, ≥ 5.0 m², short span ≤ 5.0 m; doors ≥ 0.80 m; every door is a gap flanked by the same wall line; clipped rooms convex, no acute corners, ≥ 75 % of their box. |
| H07 | Every opening verified geometrically; BFS from the street reaches every space. |
| H08 | Valid entrance whose outer face lies on a south edge of the footprint polygon, into a passage that opens to the courtyard (or into the courtyard); not blocked; courtyard reachable. |
| H09 | 4–9 rooms; known function; every room opens directly onto pastas, courtyard or passage. |
| H10 | North-wing rooms span the full wing depth (aligned E–W divisions) and wing = rooms + N–S partitions; every interior wall end meets another wall, a door gap or the exterior wall band, or ends as an anta on the pastas line; all interior walls connect to the exterior band. |

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
depth range, the 4–9 room count, the 4–6-sided footprints, a south street and
the H00–H10 rules are requirements of this project, not ancient standards.
Olynthian houses within a block were mostly near-rectangular; the clipped and
L-shaped footprints are project variations (irregular plots did occur in Greek
towns, but these specific shapes are not modelled on particular houses).

**Simplified engineering assumptions.** Wall thicknesses (0.50/0.25 m), minimum
room width/area, 5 m maximum clear span, 0.80 m minimum door, axis-aligned
rectangles inside the house, a 45° clipped corner, the 5 cm construction grid, and the wall-alignment test standing in
for structural analysis. Room functions are illustrative labels.

Scope: version 1 models only the later Classical pastas house. It does not
represent all Greek houses of 550–350 BCE (e.g. prostas houses, irregular or
rural houses).
