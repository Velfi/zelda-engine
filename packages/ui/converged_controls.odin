package ui

// Small renderer-neutral layouts used by products whose themed controls are
// drawn by a presentation adapter rather than Gui_Context.

Text_Fit :: struct {
    paint_size:     f32,
    visible_glyphs: int,
    ellipsized:     bool,
}

gui_monospace_text_fit :: proc(
    glyph_count: int,
    available_width, requested_size, minimum_size, advance_em, spacing: f32,
) -> Text_Fit {
    count := max(glyph_count, 0)
    size := max(requested_size, minimum_size)
    if count == 0 do return {paint_size = size}
    measured := f32(count) * size * advance_em + f32(max(count - 1, 0)) * spacing
    if measured > available_width {
        size = max((available_width / f32(count) - spacing) / max(advance_em, 0.0001), minimum_size)
    }
    fits := max(int((available_width + spacing) / max(size * advance_em + spacing, 0.0001)), 0)
    return {paint_size = size, visible_glyphs = min(count, fits), ellipsized = fits < count}
}

gui_progress_fill_rect :: proc(bounds: Rect, value: f32) -> Rect {
    return {bounds.x, bounds.y, bounds.w * gui_clamp01(value), bounds.h}
}

gui_loading_segment_rect :: proc(bounds: Rect, phase: f32, fraction := f32(0.22), minimum_width := f32(24)) -> Rect {
    segment_width := max(bounds.w * fraction, minimum_width)
    x := bounds.x + gui_clamp01(phase) * (bounds.w + segment_width) - segment_width
    start := max(x, bounds.x)
    finish := min(x + segment_width, bounds.x + bounds.w)
    return {start, bounds.y, max(finish - start, 0), bounds.h}
}

gui_tab_rect :: proc(bounds: Rect, count, index: int) -> Rect {
    if count <= 0 do return {}
    width := bounds.w / f32(count)
    return {bounds.x + f32(clamp(index, 0, count - 1)) * width, bounds.y, width, bounds.h}
}

gui_selection_mark_pixel :: proc(px, py, size: int, selected, radio: bool) -> bool {
    n := clamp(size, 6, 16)
    if px < 0 || py < 0 || px >= n || py >= n do return false
    if radio {
        center := f32(n) / 2
        outer_radius := (f32(n) - 1) / 2
        stroke := max(f32(1), f32(n) / 7)
        inner_radius := max(outer_radius - stroke, f32(0))
        dot_radius := max(f32(1), f32(n) / 5)
        dx := f32(px) + .5 - center
        dy := f32(py) + .5 - center
        distance_squared := dx * dx + dy * dy
        return(
            distance_squared <= outer_radius * outer_radius && distance_squared >= inner_radius * inner_radius ||
            selected && distance_squared <= dot_radius * dot_radius \
        )
    }
    if px == 0 || py == 0 || px == n - 1 || py == n - 1 do return true
    if !selected do return false
    pivot := max(2, n / 3)
    stroke := n >= 12 ? 3 : 2
    target_y := -1
    if px >= 1 && px <= pivot do target_y = n / 2 + px - 1
    if px >= pivot && px <= n - 2 do target_y = n - 2 - (px - pivot)
    return target_y >= 0 && py <= target_y && py > target_y - stroke
}
