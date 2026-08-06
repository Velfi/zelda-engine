# Procedural Markov Examples

This folder contains procedural (non-XML) equivalents for all models in `../models/*.xml`.

## Files

- `procedural_models_registry_generated.odin`: generated model-name dispatch.
- `procedural_model_*_generated.odin`: one generated file per model tree.
- `procedural_catalog_shared_generated.odin`: generated shared model catalog types and names.
- `procedural_catalog_registry_generated.odin`: generated catalog dispatch.
- `procedural_catalog_model_*_generated.odin`: one generated catalog file per model.
- `main.odin`: drift-based viewer for browsing/running procedural models.
- `gen_procedural.py`: generator script that rebuilds the generated Odin files from XML sources.

## Run

From `/Users/wolfie/pjs/catermujo/rt/markov`:

```bash
odin run examples
```

Start from a specific model:

```bash
odin run examples -- Basic
```

## Controls

- `Left/Right`: previous/next model
- `N`: next seed
- `Space`: random seed
- `R`: rerun current model
- `Up/Down`: increase/decrease step cap

## Regenerate

```bash
python3 examples/gen_procedural.py
```

## Typed Procedural API

In `/Users/wolfie/pjs/catermujo/rt/markov/procedural.odin`:

- `mk.node(mk.Proc_Tag, attrs, children)` (or `mk.node("tag-name", attrs, children)`).
- Item-based tag wrappers: `mk.one(...)`, `mk.all(...)`, `mk.prl(...)`, `mk.sequence(...)`, `mk.markov_node(...)`, `mk.wfc_node(...)`, `mk.union_node(...)`, `mk.observe_node(...)`, etc.
  You can mix attrs and child nodes directly in one call.
- Rule wrapper: `mk.rule(in, out, ...)`.
- `mk.kattr(mk.Proc_Key, value)` for typed keyed attrs.
- `mk.attr(string_key, value)` for custom attrs not in `Proc_Key`.
- `mk.values_count(n)` for value-domain size without letter alphabets.
- Direct rule builders: `mk.match_row/layer/layers` and `mk.write_row/layer/layers`.
  For enum-driven exact grids, use `mk.match_layer_enum` / `mk.write_layer_enum`
  and `mk.match_layers_enum` / `mk.write_layers_enum`.
- Exact-grid sugar: `mk.in_exact_layer/layers` and `mk.out_exact_layer/layers`.
  Use `mk.IN_ANY` for input wildcards and `mk.OUT_KEEP` for unchanged output cells.
- Symbol helpers: `mk.sym(i)`, `mk.one_of(...)`, `mk.any()`, `mk.keep()`.
- Direct symmetry bitset constants: `mk.SYMMETRY_2D_*` and `mk.SYMMETRY_3D_*` (wrap with `mk.symmetry_mask(...)`, or use builders `mk.symmetry_2d(...)` / `mk.symmetry_3d(...)`).

The generated examples in this folder now default to this no-letter API.

Parser-based compatibility is still available if needed (`mk.layer`, `mk.pattern_layers`, `mk.symbols`), but it is optional.

Example:

```odin
model :: proc() -> mk.Proc_Node {
    return mk.one(
        mk.kattr(.values, mk.values_count(4)),
        mk.kattr(.origin, true),
        mk.kattr(.in_, mk.in_exact_layer(
            []int{1, 0, 0},
        )),
        mk.kattr(.out, mk.out_exact_layer(
            []int{2, 2, 1},
        )),
    )
}
```

No-letter fully procedural style:

```odin
WALL  :: 0
FLOOR :: 1
DOOR  :: 2

model_no_letters :: proc() -> mk.Proc_Node {
    return mk.one(
        mk.kattr(.values, mk.values_count(3)),
        mk.kattr(.in_, mk.in_exact_layer(
            []int{WALL, mk.IN_ANY},
        )),
        mk.kattr(.out, mk.out_exact_layer(
            []int{FLOOR, mk.OUT_KEEP},
        )),
    )
}
```

Enum-row shorthand for exact patterns:

```odin
Tile :: enum int {
    wall = 0,
    floor = 1,
    door = 2,
}

model_enum_rows :: proc() -> mk.Proc_Node {
    return mk.one(
        mk.kattr(.values, mk.values_count(3)),
        mk.kattr(.in_, mk.in_exact_layer(
            []Tile{.wall, .wall, .floor},
        )),
        mk.kattr(.out, mk.out_exact_layer(
            []Tile{.floor, .door, .floor},
        )),
    )
}
```

For wildcard/keep behavior, keep using explicit wave/write cells via `mk.match_row(...)` and `mk.write_row(...)`.
