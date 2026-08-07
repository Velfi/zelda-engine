package canvas2d

import "core:testing"

@(test)
glyph_cache_uses_smallest_non_upscaled_tier :: proc(t: ^testing.T) {
    testing.expect_value(t, glyph_tier_for_size(1), 32)
    testing.expect_value(t, glyph_tier_for_size(32), 32)
    testing.expect_value(t, glyph_tier_for_size(33), 64)
    testing.expect_value(t, glyph_tier_for_size(65), 128)
}

@(test)
glyph_cache_evicts_only_unpinned_lru_slots :: proc(t: ^testing.T) {
    prior := state
    defer { state = prior }
    local := new(State)
    defer free(local)
    state = local
    state.glyph_frame = 20
    start, count := glyph_page_slot_range(0)
    for index in start ..< start + count {
        state.glyph_entries[index] = {
            occupied     = true,
            last_used    = u64(index + 100),
            pinned_until = state.glyph_frame + 2,
        }
    }
    testing.expect_value(t, glyph_cache_choose_slot(32), -1)

    first := &state.glyph_entries[start + 8]
    second := &state.glyph_entries[start + 12]
    first.pinned_until = state.glyph_frame - 1
    first.last_used = 9
    second.pinned_until = state.glyph_frame - 1
    second.last_used = 3
    testing.expect_value(t, glyph_cache_choose_slot(32), start + 12)
}
