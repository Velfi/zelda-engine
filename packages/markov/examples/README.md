# Procedural Markov Examples

This folder contains procedural (non-XML) equivalents for all models in `../models/*.xml`.

## Files

- `procedural_models_generated.odin`: generated procedural model trees.
- `procedural_catalog_generated.odin`: generated default sizes/steps and model list.
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

- `mk.node(mk.Proc_Tag, ...)` (or `mk.node("tag-name", ...)`).
- `mk.kattr(mk.Proc_Key, value)` for typed keyed attrs.
- `mk.attr(string_key, value)` for custom attrs not in `Proc_Key`.
- `mk.pattern_rows(...)` and `mk.pattern_layers(...)` helpers for rules.

Example:

```odin
model :: proc() -> mk.Proc_Node {
    return mk.node(
        mk.Proc_Tag.one,
        []mk.Proc_Attr{
            mk.kattr(.values, "BRGW"),
            mk.kattr(.origin, true),
            mk.kattr(.in_, mk.pattern_rows("RBB")),
            mk.kattr(.out, mk.pattern_rows("GGR")),
        },
    )
}
```
