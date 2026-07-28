package canvas2d

import "core:testing"

@(test)
world_resolve_covers_fixed_and_native_post_paths :: proc(t: ^testing.T) {
    testing.expect(t, !world_resolve_required(false, 854, 480, true))
    testing.expect(t, world_resolve_required(true, 854, 480, false))
    testing.expect(t, world_resolve_required(true, 0, 0, true))
    testing.expect(t, !world_resolve_required(true, 0, 0, false))
}
