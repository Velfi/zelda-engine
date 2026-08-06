package example

import mk ".."

WALL :: 0
FLOOR :: 1
DOOR :: 2

// model_no_letters_demo shows the direct procedural API with no symbolic letters.
model_no_letters_demo :: proc() -> mk.Proc_Node {
    return mk.node(
        mk.Proc_Tag.one,
        []mk.Proc_Attr {
            mk.kattr(.values, mk.values_count(3)),
            mk.kattr(.origin, true),
            mk.kattr(.in_, mk.match_layer(mk.match_row(mk.one_of(mk.sym(WALL)), mk.any()))),
            mk.kattr(.out, mk.write_layer(mk.write_row(mk.sym(FLOOR), mk.keep()))),
            mk.kattr(.steps, 1),
        },
    )
}
