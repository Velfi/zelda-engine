package canvas2d

import "core:math"
import ui "zelda_engine:ui"

glyph_page_cell :: proc(page: int) -> int {
    switch page {
    case 0:
        return GLYPH_ATLAS_CELL_32
    case 1:
        return GLYPH_ATLAS_CELL_64
    }
    return GLYPH_ATLAS_CELL_128
}

glyph_page_tier :: proc(page: int) -> int {
    switch page {
    case 0:
        return 32
    case 1:
        return 64
    }
    return 128
}

glyph_page_slot_range :: proc(page: int) -> (start, count: int) {
    switch page {
    case 0:
        return 0, GLYPH_ATLAS_SLOTS_32
    case 1:
        return GLYPH_ATLAS_SLOTS_32, GLYPH_ATLAS_SLOTS_64
    case 2:
        return GLYPH_ATLAS_SLOTS_32 + GLYPH_ATLAS_SLOTS_64, GLYPH_ATLAS_SLOTS_128
    case 3:
        return GLYPH_ATLAS_SLOTS_32 + GLYPH_ATLAS_SLOTS_64 + GLYPH_ATLAS_SLOTS_128, GLYPH_ATLAS_SLOTS_128
    }
    return 0, 0
}

glyph_tier_for_size :: proc(size: f32) -> int {
    requested := int(math.ceil(max(size, f32(1))))
    if requested <= 32 do return 32
    if requested <= 64 do return 64
    return 128
}

glyph_cache_init :: proc() -> bool {
    state.glyph_lookup = make(map[Glyph_Cache_Key]int, GLYPH_CACHE_SLOT_COUNT)
    empty := make([]u8, GLYPH_ATLAS_PAGE_SIZE * GLYPH_ATLAS_PAGE_SIZE, context.temp_allocator)
    for page in 0 ..< GLYPH_ATLAS_PAGE_COUNT {
        texture := create_dynamic_texture_r8(GLYPH_ATLAS_PAGE_SIZE, GLYPH_ATLAS_PAGE_SIZE, empty)
        if !texture.ready do return false
        state.glyph_pages[page] = texture
    }
    return true
}

glyph_cache_destroy :: proc() {
    delete(state.glyph_lookup)
    state.glyph_lookup = nil
}

glyph_cache_page_for_tier :: proc(tier, alternate: int) -> int {
    switch tier {
    case 32:
        return 0
    case 64:
        return 1
    }
    return 2 + clamp(alternate, 0, 1)
}

glyph_cache_choose_slot :: proc(tier: int) -> int {
    page_count := tier == 128 ? 2 : 1
    chosen := -1
    oldest := ~u64(0)
    for page_offset in 0 ..< page_count {
        page := glyph_cache_page_for_tier(tier, page_offset)
        start, count := glyph_page_slot_range(page)
        for index in start ..< start + count {
            entry := &state.glyph_entries[index]
            if !entry.occupied do return index
            if entry.pinned_until < state.glyph_frame && entry.last_used < oldest {
                chosen = index
                oldest = entry.last_used
            }
        }
    }
    return chosen
}

glyph_cache_load :: proc(key: Glyph_Cache_Key) -> (^Glyph_Cache_Entry, bool) {
    if index, found := state.glyph_lookup[key]; found {
        entry := &state.glyph_entries[index]
        entry.last_used = state.glyph_frame
        entry.pinned_until = state.glyph_frame + 2
        return entry, true
    }

    slot := glyph_cache_choose_slot(int(key.tier))
    if slot < 0 {
        state.glyph_cache_failures += 1
        return nil, false
    }
    entry := &state.glyph_entries[slot]
    if entry.occupied {
        delete_key(&state.glyph_lookup, entry.key)
        state.glyph_cache_evictions += 1
    }
    page := 0
    for candidate in 0 ..< GLYPH_ATLAS_PAGE_COUNT {
        start, count := glyph_page_slot_range(candidate)
        if slot >= start && slot < start + count {
            page = candidate
            break
        }
    }
    start, _ := glyph_page_slot_range(page)
    cell := glyph_page_cell(page)
    columns := GLYPH_ATLAS_PAGE_SIZE / cell
    local := slot - start
    cell_x := local % columns * cell
    cell_y := local / columns * cell

    metrics: ui.Gui_Raster_Glyph
    scratch := make([]u8, cell * cell, context.temp_allocator)
    rendered := ui.gui_font_rasterize_glyph(key.face_id, key.glyph_id, int(key.tier), scratch, &metrics)
    needed := int(metrics.width * metrics.height)
    if rendered < 0 {
        needed = -rendered
        if needed > len(scratch) {
            state.glyph_cache_failures += 1
            return nil, false
        }
        rendered = ui.gui_font_rasterize_glyph(key.face_id, key.glyph_id, int(key.tier), scratch[:needed], &metrics)
    }
    if rendered < 0 ||
       metrics.width > i32(cell - GLYPH_ATLAS_PADDING * 2) ||
       metrics.height > i32(cell - GLYPH_ATLAS_PADDING * 2) {
        state.glyph_cache_failures += 1
        return nil, false
    }

    cell_pixels := make([]u8, cell * cell, context.temp_allocator)
    for row in 0 ..< int(metrics.height) {
        source := row * int(metrics.width)
        destination := (row + GLYPH_ATLAS_PADDING) * cell + GLYPH_ATLAS_PADDING
        copy(cell_pixels[destination:destination + int(metrics.width)], scratch[source:source + int(metrics.width)])
    }
    if !update_dynamic_texture_r8_region(
        state.glyph_pages[page],
        cell_pixels,
        {f32(cell_x), f32(cell_y), f32(cell), f32(cell)},
    ) {
        state.glyph_cache_failures += 1
        return nil, false
    }

    generation := entry.generation + 1
    entry^ = {
        key          = key,
        occupied     = true,
        page         = u8(page),
        generation   = generation,
        x            = i32(cell_x + GLYPH_ATLAS_PADDING),
        y            = i32(cell_y + GLYPH_ATLAS_PADDING),
        width        = metrics.width,
        height       = metrics.height,
        left         = metrics.left,
        top          = metrics.top,
        last_used    = state.glyph_frame,
        pinned_until = state.glyph_frame + 2,
    }
    state.glyph_lookup[key] = slot
    state.glyph_cache_misses += 1
    return entry, true
}
