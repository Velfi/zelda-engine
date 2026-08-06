#+build !js
package example

import mk "../.."

WALL :: 0
FLOOR :: 1
DOOR :: 2

// model_no_letters_demo shows the direct procedural API with no symbolic letters.
model_no_letters_demo :: proc() -> mk.Proc_Node {
    return mk.one(
        mk.kattr(.values, mk.values_count(3)),
        mk.kattr(.origin, true),
        mk.kattr(.in_, mk.in_exact_layer([]int{WALL, mk.IN_ANY})),
        mk.kattr(.out, mk.out_exact_layer([]int{FLOOR, mk.OUT_KEEP})),
        mk.kattr(.steps, 1),
    )
}
