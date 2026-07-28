package ui

import "core:testing"

@(test)
image_contain_and_cover_preserve_aspect :: proc(t: ^testing.T) {
    contained := gui_image_contain_rect({10, 20, 100, 100}, {200, 100})
    testing.expect(t, contained == Rect{10, 45, 100, 50})
    uv := gui_image_cover_uv({0, 0, 100, 100}, {200, 100})
    testing.expect(t, uv == Rect{0.25, 0, 0.5, 1})
    portrait_uv := gui_image_cover_uv({0, 0, 200, 100}, {100, 200})
    testing.expect(t, portrait_uv == Rect{0, 0.375, 1, 0.25})
}

@(test)
rectangle_and_overlay_geometry_handles_edges :: proc(t: ^testing.T) {
    testing.expect(t, gui_rect_normalized({8, 9}, {2, 3}) == Rect{2, 3, 6, 6})
    testing.expect(t, gui_rects_overlap({0, 0, 10, 10}, {9, 9, 3, 3}))
    testing.expect(t, !gui_rects_overlap({0, 0, 10, 10}, {12, 12, 3, 3}))
    testing.expect(t, gui_segment_intersects_rect({-5, 5}, {15, 5}, {0, 0, 10, 10}))
    testing.expect(t, !gui_segment_intersects_rect({-5, -5}, {-1, -1}, {0, 0, 10, 10}))
    placed := gui_place_overlay({40, 2, 20, 10}, {30, 20}, {0, 0, 100, 100})
    testing.expect(t, placed == Rect{35, 18, 30, 20})
}

@(test)
spotlight_layout_excludes_clipped_focus_regions :: proc(t: ^testing.T) {
    cells: [GUI_SPOTLIGHT_MAX_CELLS]Rect
    testing.expect_value(t, gui_spotlight_layout(nil, {0, 0, 1280, 720}, 0, &cells), 1)
    count := gui_spotlight_layout([]Rect{{100, 100, 200, 100}}, {0, 0, 1280, 720}, 0, &cells)
    testing.expect_value(t, count, 8)
    for cell in cells[:count] do testing.expect(t, !gui_rects_overlap(cell, {101, 101, 198, 98}))
    clipped := gui_spotlight_layout([]Rect{{-50, -50, 100, 100}}, {0, 0, 1280, 720}, 0, &cells)
    testing.expect(t, clipped > 0)
}

@(test)
triangle_commands_preserve_vertex_colors :: proc(t: ^testing.T) {
    ctx: Gui_Context
    ctx.commands = make([dynamic]Draw_Command)
    defer delete(ctx.commands)
    gui_triangle(&ctx, {0, 0}, {1, 0}, {0, 1}, {1, 0, 0, 1})
    gui_triangle_colors(&ctx, {0, 0}, {1, 0}, {0, 1}, {1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1})
    testing.expect(t, ctx.commands[0].kind == .Filled_Triangle)
    testing.expect(t, ctx.commands[1].kind == .Gradient_Triangle)
    testing.expect(t, ctx.commands[1].color_3 == Color{0, 0, 1, 1})
}

@(test)
cubic_endpoints_and_tangents_are_stable :: proc(t: ^testing.T) {
    a, b, c, d := Vec2{1, 2}, Vec2{3, 4}, Vec2{7, 8}, Vec2{9, 10}
    testing.expect(t, gui_cubic_point(a, b, c, d, 0) == a)
    testing.expect(t, gui_cubic_point(a, b, c, d, 1) == d)
    testing.expect(t, gui_cubic_segment_count(a, b, c, d) == 8)
    start := gui_cubic_tangent(a, b, c, d, 0)
    end := gui_cubic_tangent(a, b, c, d, 1)
    testing.expect(t, start == Vec2{6, 6})
    testing.expect(t, end == Vec2{6, 6})
}

@(test)
curve_hit_testing_uses_shared_geometry :: proc(t: ^testing.T) {
    a, b, c, d := Vec2{0, 0}, Vec2{25, 0}, Vec2{75, 0}, Vec2{100, 0}
    testing.expect(t, gui_cubic_hit({50, 3}, a, b, c, d, 4))
    testing.expect(t, !gui_cubic_hit({50, 9}, a, b, c, d, 4))
    points := [3]Vec2{{0, 0}, {50, 50}, {100, 0}}
    testing.expect(t, gui_smooth_path_hit({50, 50}, points[:], 1))
    testing.expect(t, !gui_smooth_path_hit({}, nil))
}

@(test)
cubic_drawing_emits_renderer_neutral_lines :: proc(t: ^testing.T) {
    ctx: Gui_Context
    ctx.commands = make([dynamic]Draw_Command)
    defer delete(ctx.commands)
    gui_cubic(&ctx, {0, 0}, {20, 0}, {80, 100}, {100, 100}, {1, 1, 1, 1}, 2, 6)
    testing.expect(t, len(ctx.commands) == 6)
    for command in ctx.commands {
        testing.expect(t, command.kind == .Line)
        testing.expect(t, command.stroke_width == 2)
    }
}
