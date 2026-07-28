package ui

import "core:testing"

@(test)
converged_control_layouts_are_bounded :: proc(t: ^testing.T) {
    fit := gui_monospace_text_fit(20, 80, 18, 12, .6, 1)
    testing.expect(t, fit.paint_size >= 12)
    testing.expect(t, fit.ellipsized)
    progress := gui_progress_fill_rect({10, 20, 100, 8}, 1.5)
    testing.expect_value(t, progress.w, f32(100))
    loading := gui_loading_segment_rect({10, 20, 100, 8}, 0)
    testing.expect(t, loading.x >= 10 && loading.x + loading.w <= 110)
    tab := gui_tab_rect({0, 0, 90, 20}, 3, 2)
    testing.expect_value(t, tab, Rect{60, 0, 30, 20})
}
