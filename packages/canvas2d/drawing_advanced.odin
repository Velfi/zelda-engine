package canvas2d

import "core:image"
import _ "core:image/png"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
import engine "zelda_engine:engine"
import resources "zelda_engine:render_resources"
import ui "zelda_engine:ui"

DrawEllipseRingHatched :: proc(
    center: Vector2,
    outer_radius_x, outer_radius_y, inner_radius_x, inner_radius_y: f32,
    color: Color,
    config := default_hatch,
    segments: int = 64,
    rotation: f32 = 0,
    outer_irregularity: f32 = 0,
    inner_irregularity: f32 = 0,
    phase: f32 = 0,
) {
    invalid :=
        outer_radius_x <= 0 ||
        outer_radius_y <= 0 ||
        inner_radius_x <= 0 ||
        inner_radius_y <= 0 ||
        inner_radius_x >= outer_radius_x ||
        inner_radius_y >= outer_radius_y ||
        segments < 3
    if invalid do return
    cos_rotation, sin_rotation := f32(math.cos(f64(rotation))), f32(math.sin(f64(rotation)))
    for i in 0 ..< segments {
        a := f32(i) * 2 * math.PI / f32(segments)
        b := f32(i + 1) * 2 * math.PI / f32(segments)
        cos_a, sin_a := f32(math.cos(f64(a))), f32(math.sin(f64(a)))
        cos_b, sin_b := f32(math.cos(f64(b))), f32(math.sin(f64(b)))
        outer_warp_a :=
            1 +
            f32(math.sin(f64(a * 3 + phase))) * outer_irregularity +
            f32(math.sin(f64(a * 5 - phase * .7))) * outer_irregularity * .45
        outer_warp_b :=
            1 +
            f32(math.sin(f64(b * 3 + phase))) * outer_irregularity +
            f32(math.sin(f64(b * 5 - phase * .7))) * outer_irregularity * .45
        inner_phase := phase + .9
        inner_warp_a :=
            1 +
            f32(math.sin(f64(a * 3 + inner_phase))) * inner_irregularity +
            f32(math.sin(f64(a * 5 - inner_phase * .7))) * inner_irregularity * .45
        inner_warp_b :=
            1 +
            f32(math.sin(f64(b * 3 + inner_phase))) * inner_irregularity +
            f32(math.sin(f64(b * 5 - inner_phase * .7))) * inner_irregularity * .45
        outer_a := Vector2{outer_radius_x * cos_a * outer_warp_a, outer_radius_y * sin_a * outer_warp_a}
        outer_b := Vector2{outer_radius_x * cos_b * outer_warp_b, outer_radius_y * sin_b * outer_warp_b}
        inner_a := Vector2{inner_radius_x * cos_a * inner_warp_a, inner_radius_y * sin_a * inner_warp_a}
        inner_b := Vector2{inner_radius_x * cos_b * inner_warp_b, inner_radius_y * sin_b * inner_warp_b}
        base_fade := clamp(config.edge_softness, f32(0), f32(.45))
        // Rings expose two cut boundaries, so their fade is carried by mesh alpha
        // rather than the filled-shape radial shader mask. Vary the fade depth along
        // each authored irregular edge to keep annuli from ending in two perfectly
        // even airbrushed bands. Outer and inner wear use different phase families;
        // both remain deterministic and interpolate continuously between segments.
        edge_wear := clamp(max(outer_irregularity, inner_irregularity) * 6, f32(0), f32(1))
        outer_fade_a := clamp(
            base_fade * (1 + f32(math.sin(f64(a * 7 + phase * .83))) * edge_wear * .34),
            f32(0),
            f32(.45),
        )
        outer_fade_b := clamp(
            base_fade * (1 + f32(math.sin(f64(b * 7 + phase * .83))) * edge_wear * .34),
            f32(0),
            f32(.45),
        )
        inner_fade_a := clamp(
            base_fade * (1 + f32(math.sin(f64(a * 5 - phase * 1.17 + 1.3))) * edge_wear * .34),
            f32(0),
            f32(.45),
        )
        inner_fade_b := clamp(
            base_fade * (1 + f32(math.sin(f64(b * 5 - phase * 1.17 + 1.3))) * edge_wear * .34),
            f32(0),
            f32(.45),
        )
        outer_mid_a := Vector2 {
            outer_a.x + (inner_a.x - outer_a.x) * outer_fade_a,
            outer_a.y + (inner_a.y - outer_a.y) * outer_fade_a,
        }
        outer_mid_b := Vector2 {
            outer_b.x + (inner_b.x - outer_b.x) * outer_fade_b,
            outer_b.y + (inner_b.y - outer_b.y) * outer_fade_b,
        }
        inner_mid_a := Vector2 {
            outer_a.x + (inner_a.x - outer_a.x) * (1 - inner_fade_a),
            outer_a.y + (inner_a.y - outer_a.y) * (1 - inner_fade_a),
        }
        inner_mid_b := Vector2 {
            outer_b.x + (inner_b.x - outer_b.x) * (1 - inner_fade_b),
            outer_b.y + (inner_b.y - outer_b.y) * (1 - inner_fade_b),
        }
        p_outer_a := transform(
            {
                center.x + outer_a.x * cos_rotation - outer_a.y * sin_rotation,
                center.y + outer_a.x * sin_rotation + outer_a.y * cos_rotation,
            },
        )
        p_outer_b := transform(
            {
                center.x + outer_b.x * cos_rotation - outer_b.y * sin_rotation,
                center.y + outer_b.x * sin_rotation + outer_b.y * cos_rotation,
            },
        )
        p_outer_mid_a := transform(
            {
                center.x + outer_mid_a.x * cos_rotation - outer_mid_a.y * sin_rotation,
                center.y + outer_mid_a.x * sin_rotation + outer_mid_a.y * cos_rotation,
            },
        )
        p_outer_mid_b := transform(
            {
                center.x + outer_mid_b.x * cos_rotation - outer_mid_b.y * sin_rotation,
                center.y + outer_mid_b.x * sin_rotation + outer_mid_b.y * cos_rotation,
            },
        )
        p_inner_mid_a := transform(
            {
                center.x + inner_mid_a.x * cos_rotation - inner_mid_a.y * sin_rotation,
                center.y + inner_mid_a.x * sin_rotation + inner_mid_a.y * cos_rotation,
            },
        )
        p_inner_mid_b := transform(
            {
                center.x + inner_mid_b.x * cos_rotation - inner_mid_b.y * sin_rotation,
                center.y + inner_mid_b.x * sin_rotation + inner_mid_b.y * cos_rotation,
            },
        )
        p_inner_a := transform(
            {
                center.x + inner_a.x * cos_rotation - inner_a.y * sin_rotation,
                center.y + inner_a.x * sin_rotation + inner_a.y * cos_rotation,
            },
        )
        p_inner_b := transform(
            {
                center.x + inner_b.x * cos_rotation - inner_b.y * sin_rotation,
                center.y + inner_b.x * sin_rotation + inner_b.y * cos_rotation,
            },
        )
        inner_u := inner_radius_x / outer_radius_x * .5
        inner_v := inner_radius_y / outer_radius_y * .5
        outer_uv_a := Vector2{.5 + cos_a * .5, .5 + sin_a * .5}
        outer_uv_b := Vector2{.5 + cos_b * .5, .5 + sin_b * .5}
        inner_uv_a := Vector2{.5 + cos_a * inner_u, .5 + sin_a * inner_v}
        inner_uv_b := Vector2{.5 + cos_b * inner_u, .5 + sin_b * inner_v}
        outer_mid_uv_a := Vector2 {
            outer_uv_a.x + (inner_uv_a.x - outer_uv_a.x) * outer_fade_a,
            outer_uv_a.y + (inner_uv_a.y - outer_uv_a.y) * outer_fade_a,
        }
        outer_mid_uv_b := Vector2 {
            outer_uv_b.x + (inner_uv_b.x - outer_uv_b.x) * outer_fade_b,
            outer_uv_b.y + (inner_uv_b.y - outer_uv_b.y) * outer_fade_b,
        }
        inner_mid_uv_a := Vector2 {
            outer_uv_a.x + (inner_uv_a.x - outer_uv_a.x) * (1 - inner_fade_a),
            outer_uv_a.y + (inner_uv_a.y - outer_uv_a.y) * (1 - inner_fade_a),
        }
        inner_mid_uv_b := Vector2 {
            outer_uv_b.x + (inner_uv_b.x - outer_uv_b.x) * (1 - inner_fade_b),
            outer_uv_b.y + (inner_uv_b.y - outer_uv_b.y) * (1 - inner_fade_b),
        }
        base := u32(len(state.vertices))
        t := to_color(color)
        boundary_t := t
        if base_fade > 0 do boundary_t[3] = 0
        append(
            &state.vertices,
            Vertex{p_outer_a, outer_uv_a, boundary_t},
            Vertex{p_outer_b, outer_uv_b, boundary_t},
            Vertex{p_outer_mid_a, outer_mid_uv_a, t},
            Vertex{p_outer_mid_b, outer_mid_uv_b, t},
            Vertex{p_inner_mid_a, inner_mid_uv_a, t},
            Vertex{p_inner_mid_b, inner_mid_uv_b, t},
            Vertex{p_inner_a, inner_uv_a, boundary_t},
            Vertex{p_inner_b, inner_uv_b, boundary_t},
        )
        first := u32(len(state.indices))
        append(
            &state.indices,
            base,
            base + 1,
            base + 3,
            base,
            base + 3,
            base + 2,
            base + 2,
            base + 3,
            base + 5,
            base + 2,
            base + 5,
            base + 4,
            base + 4,
            base + 5,
            base + 7,
            base + 4,
            base + 7,
            base + 6,
        )
        ring_config := config
        // The annular mesh now supplies distance to both actual boundaries.
        // Disable the filled-shape radial fade, which only understands the outer
        // ellipse and would soften one side of the ring twice.
        ring_config.edge_softness = 0
        append_batch(first, 18, -1, ring_config)
    }
}
@(no_instrumentation)
CheckCollisionPointRec :: #force_inline proc(p: Vector2, r: Rectangle) -> bool {return(
        p.x >= r.x &&
        p.x <= r.x + r.width &&
        p.y >= r.y &&
        p.y <= r.y + r.height \
    )}
LoadFontEx :: proc(path: cstring, size: i32, codepoints: [^]rune, count: i32) -> Font {
    return {ready = state.initialized}
}
DisplayFont :: proc() -> Font { return {ready = state.initialized, display = true} }
@(no_instrumentation)
FontAdvanceEm :: #force_inline proc(font := Font{}) -> f32 {
    return state.font_advance_em[font.display ? 1 : 0][int('M') - FONT_FIRST]
}
@(no_instrumentation)
font_advance_em :: #force_inline proc(font: Font, ch: rune) -> f32 {
    slot := font_glyph_slot(ch)
    if slot < 0 || slot >= FONT_COUNT do slot = int('?') - FONT_FIRST
    return state.font_advance_em[font.display ? 1 : 0][slot]
}
@(no_instrumentation)
font_kind :: #force_inline proc(font: Font) -> ui.Gui_Font_Kind {
    return font.display ? .Display : .Body
}
@(no_instrumentation)
font_shape_scale :: #force_inline proc(size: f32) -> f32 {
    // Atlas storage can grow to preserve bearings and descenders without
    // changing the authored text size.
    return size / ui.GUI_FONT_LOGICAL_HEIGHT * f32(FONT_RASTER_H) / f32(FONT_LOGICAL_CELL_H)
}
UnloadFont :: proc(font: Font) {  }
@(no_instrumentation)
font_glyph_slot :: #force_inline proc(ch: rune) -> int {
    if ch >= FONT_FIRST && ch <= FONT_LAST do return int(ch) - FONT_FIRST
    for fallback, index in FONT_FALLBACK_RUNES do if ch == fallback do return FONT_COUNT + index
    switch ch {case '·':
        return int('|') - FONT_FIRST; case '–', '—', '−':
        return int('-') - FONT_FIRST; case '←', '‹':
        return int('<') - FONT_FIRST; case '→', '›':
        return int('>') - FONT_FIRST; case '‘', '’':
        return int('\'') - FONT_FIRST; case '“', '”':
        return int('"') - FONT_FIRST}
    return int('?') - FONT_FIRST
}
@(no_instrumentation)
MeasureTextEx :: #force_inline proc(font: Font, text: cstring, size, spacing: f32) -> Vector2 {
    return MeasureTextExDirection(font, text, size, spacing, .Auto)
}

MeasureFontMetrics :: proc(font: Font, size: f32) -> Font_Metrics {
    index := font.display ? 1 : 0
    metrics := state.font_metrics_em[index]
    if metrics.ascent <= 0 || metrics.descent < 0 {
        metrics = {.82, .18, 0}
    }
    return {
        ascent = metrics.ascent * size,
        descent = metrics.descent * size,
        line_gap = metrics.line_gap * size,
    }
}

TextBlockCenteredY :: proc(font: Font, bounds: Rectangle, size, line_height: f32, line_count: int) -> f32 {
    if line_count <= 0 do return bounds.y
    block_height := f32(line_count) * line_height
    metrics := MeasureFontMetrics(font, size)
    metric_height := metrics.ascent + metrics.descent
    baseline_in_line := max((line_height - metric_height) * .5, 0) + metrics.ascent
    // DrawTextEx currently accepts a line-box top and derives its baseline at
    // 0.82 em internally. Keep that implementation detail inside canvas2d.
    draw_baseline_offset := size * .82
    return bounds.y + (bounds.height - block_height) * .5 + baseline_in_line - draw_baseline_offset
}
MeasureTextExDirection :: proc(
    font: Font,
    text: cstring,
    size, spacing: f32,
    direction: Text_Direction,
) -> Vector2 {
    value := string(text)
    if len(value) == 0 do return {0, max(size, f32(32))}
    shaped := make([]ui.Gui_Shaped_Glyph, len(value), context.temp_allocator)
    count := ui.gui_font_shape_text_direction(
        font_kind(font),
        transmute([]u8)value,
        font_shape_scale(size),
        ui.Text_Direction(direction),
        shaped,
    )
    if count > 0 {
        width := f32(0)
        for glyph in shaped[:count] do width += glyph.x_advance
        return {width + f32(max(count - 1, 0)) * spacing, max(size, f32(32))}
    }
    width := f32(0)
    rune_count := 0
    for ch in value {
        width += size * font_advance_em(font, ch)
        rune_count += 1
    }
    return {width + f32(max(rune_count - 1, 0)) * spacing, max(size, f32(32))}
}
DrawTextEx :: proc(font: Font, text: cstring, position: Vector2, size, spacing: f32, color: Color) {
    DrawTextExDirection(font, text, position, size, spacing, color, .Auto)
}
DrawTextExDirection :: proc(
    font: Font,
    text: cstring,
    position: Vector2,
    size, spacing: f32,
    color: Color,
    direction: Text_Direction,
) {
    value := string(text)
    if len(value) == 0 do return
    scale := size / f32(FONT_LOGICAL_CELL_H)
    cursor := position.x
    shaped := make([]ui.Gui_Shaped_Glyph, len(value), context.temp_allocator)
    count := ui.gui_font_shape_text_direction(
        font_kind(font),
        transmute([]u8)value,
        font_shape_scale(size),
        ui.Text_Direction(direction),
        shaped,
    )
    if count <= 0 {
        for ch in value {
            glyph := font_glyph_slot(ch)
            col := glyph % FONT_COLUMNS
            row := glyph / FONT_COLUMNS + (font.display ? FONT_ROWS : 0)
            uv0 := Vector2 {
                f32(col * state.font_cell_width) / f32(state.texture_width),
                f32(row * state.font_cell_height) / f32(state.texture_height),
            }
            uv1 := Vector2 {
                f32((col + 1) * state.font_cell_width) / f32(state.texture_width),
                f32((row + 1) * state.font_cell_height) / f32(state.texture_height),
            }
            r := Rectangle{
                cursor - f32(state.font_origin_x) * scale,
                position.y,
                f32(state.font_cell_width) * scale,
                f32(state.font_cell_height) * scale,
            }
            a := transform({r.x, r.y})
            b := transform({r.x + r.width, r.y})
            c := transform({r.x + r.width, r.y + r.height})
            d := transform({r.x, r.y + r.height})
            quad(a, b, c, d, color, uv0, uv1, 0)
            cursor += size * font_advance_em(font, ch) + spacing
        }
        return
    }
    for shaped_glyph in shaped[:count] {
        tier := glyph_tier_for_size(size)
        entry, cached := glyph_cache_load({
            face_id = shaped_glyph.face_id,
            tier = u16(tier),
            glyph_id = shaped_glyph.glyph_id,
        })
        // Glyph zero is the selected face's deterministic monochrome
        // replacement outline when rasterization or allocation fails.
        if !cached && shaped_glyph.glyph_id != 0 {
            entry, cached = glyph_cache_load({
                face_id = shaped_glyph.face_id,
                tier = u16(tier),
                glyph_id = 0,
            })
        }
        if !cached {
            cursor += shaped_glyph.x_advance + spacing
            continue
        }
        page := state.glyph_pages[int(entry.page)]
        uv0 := Vector2 {
            f32(entry.x) / GLYPH_ATLAS_PAGE_SIZE,
            f32(entry.y) / GLYPH_ATLAS_PAGE_SIZE,
        }
        uv1 := Vector2 {
            f32(entry.x + entry.width) / GLYPH_ATLAS_PAGE_SIZE,
            f32(entry.y + entry.height) / GLYPH_ATLAS_PAGE_SIZE,
        }
        glyph_scale := size / f32(tier)
        baseline := position.y + size * .82
        r := Rectangle {
            cursor + shaped_glyph.x_offset + f32(entry.left) * glyph_scale,
            baseline - shaped_glyph.y_offset - f32(entry.top) * glyph_scale,
            f32(entry.width) * glyph_scale,
            f32(entry.height) * glyph_scale,
        }
        if entry.width > 0 && entry.height > 0 {
            a := transform({r.x, r.y})
            b := transform({r.x + r.width, r.y})
            c := transform({r.x + r.width, r.y + r.height})
            d := transform({r.x, r.y + r.height})
            quad(a, b, c, d, color, uv0, uv1, page.id)
        }
        cursor += shaped_glyph.x_advance + spacing
    }
}

text_wrapped_lines :: proc(
    font: Font,
    value: string,
    size, spacing, max_width: f32,
    direction: Text_Direction,
    lines: ^[dynamic]Text_Wrapped_Line,
) {
    paragraph_start := 0
    for paragraph_start <= len(value) {
        paragraph_end := paragraph_start
        for paragraph_end < len(value) && value[paragraph_end] != '\n' do paragraph_end += 1
        if paragraph_start == paragraph_end {
            append(lines, Text_Wrapped_Line{paragraph_start, paragraph_end})
        } else {
            line_start := paragraph_start
            for line_start < paragraph_end {
                cursor := line_start
                best := line_start
                for cursor < paragraph_end {
                    step := ui.gui_text_next_line_break(transmute([]u8)value[cursor:paragraph_end])
                    candidate := min(cursor + step, paragraph_end)
                    measured := MeasureTextExDirection(
                        font,
                        fmt.ctprintf("%s", value[line_start:candidate]),
                        size,
                        spacing,
                        direction,
                    )
                    if measured.x > max_width && best > line_start do break
                    if measured.x > max_width {
                        forced := line_start
                        for forced < candidate {
                            glyph_step := ui.gui_text_next_grapheme(transmute([]u8)value[forced:candidate])
                            next := forced + glyph_step
                            forced_size := MeasureTextExDirection(
                                font,
                                fmt.ctprintf("%s", value[line_start:next]),
                                size,
                                spacing,
                                direction,
                            )
                            if forced_size.x > max_width && forced > line_start do break
                            forced = next
                        }
                        best = max(
                            forced,
                            line_start + ui.gui_text_next_grapheme(
                                transmute([]u8)value[line_start:paragraph_end],
                            ),
                        )
                        break
                    }
                    best = candidate
                    cursor = candidate
                }
                if best <= line_start do best = paragraph_end
                end := best
                for end > line_start && value[end - 1] == ' ' do end -= 1
                append(lines, Text_Wrapped_Line{line_start, end})
                line_start = best
                for line_start < paragraph_end && value[line_start] == ' ' do line_start += 1
            }
        }
        if paragraph_end >= len(value) do break
        paragraph_start = paragraph_end + 1
    }
}

LayoutTextWrappedEx :: proc(
    font: Font,
    text: cstring,
    size, spacing, max_width: f32,
    direction: Text_Direction,
    lines: ^[dynamic]Text_Wrapped_Line,
) {
    if lines == nil do return
    clear(lines)
    value := string(text)
    if len(value) == 0 do return
    text_wrapped_lines(font, value, size, spacing, max_width, direction, lines)
}

MeasureTextWrappedEx :: proc(
    font: Font,
    text: cstring,
    size, spacing, max_width, line_height: f32,
    direction: Text_Direction = .Auto,
) -> Text_Wrap_Result {
    value := string(text)
    if len(value) == 0 do return {}
    lines := make([dynamic]Text_Wrapped_Line, 0, 8, context.temp_allocator)
    text_wrapped_lines(font, value, size, spacing, max_width, direction, &lines)
    width: f32
    for line in lines {
        measured := MeasureTextExDirection(
            font,
            fmt.ctprintf("%s", value[line.start:line.end]),
            size,
            spacing,
            direction,
        )
        width = max(width, measured.x)
    }
    return {{min(width, max_width), f32(len(lines)) * line_height}, len(lines)}
}

DrawTextWrappedEx :: proc(
    font: Font,
    text: cstring,
    bounds: Rectangle,
    size, spacing, line_height: f32,
    color: Color,
    direction: Text_Direction = .Auto,
) -> Text_Wrap_Result {
    value := string(text)
    if len(value) == 0 do return {}
    lines := make([dynamic]Text_Wrapped_Line, 0, 8, context.temp_allocator)
    text_wrapped_lines(font, value, size, spacing, bounds.width, direction, &lines)
    visible := min(len(lines), max(int(bounds.height / line_height), 0))
    width: f32
    for line, index in lines[:visible] {
        line_text := fmt.ctprintf("%s", value[line.start:line.end])
        measured := MeasureTextExDirection(font, line_text, size, spacing, direction)
        width = max(width, measured.x)
        DrawTextExDirection(
            font,
            line_text,
            {bounds.x, bounds.y + f32(index) * line_height},
            size,
            spacing,
            color,
            direction,
        )
    }
    return {{min(width, bounds.width), f32(visible) * line_height}, visible}
}

// Centers the typographic line box, not the particular string's ink bounds.
// This keeps labels with ascenders, descenders, and different scripts aligned
// to the same baseline while still centering a wrapped block as a whole.
DrawTextWrappedCenteredEx :: proc(
    font: Font,
    text: cstring,
    bounds: Rectangle,
    size, spacing, line_height: f32,
    color: Color,
    direction: Text_Direction = .Auto,
) -> Text_Wrap_Result {
    measured := MeasureTextWrappedEx(font, text, size, spacing, bounds.width, line_height, direction)
    if measured.line_count <= 0 || line_height <= 0 do return {}
    visible := min(measured.line_count, max(int(bounds.height / line_height), 1))
    block_height := f32(visible) * line_height
    centered := bounds
    centered.y = TextBlockCenteredY(font, bounds, size, line_height, visible)
    centered.height = block_height
    return DrawTextWrappedEx(font, text, centered, size, spacing, line_height, color, direction)
}

DrawIcon :: proc(index: int, destination: Rectangle, color := Color{255, 255, 255, 255}) {
    if index < 0 || index >= ICON_COLUMNS * ICON_ROWS || state.icon_width <= 0 do return
    col, row := index % ICON_COLUMNS, index / ICON_COLUMNS
    cell_w, cell_h := f32(state.icon_width) / ICON_COLUMNS, f32(state.icon_height) / ICON_ROWS
    uv0 := Vector2 {
        f32(col) * cell_w / f32(state.texture_width),
        (f32(state.icon_y) + f32(row) * cell_h) / f32(state.texture_height),
    }
    uv1 := Vector2 {
        f32(col + 1) * cell_w / f32(state.texture_width),
        (f32(state.icon_y) + f32(row + 1) * cell_h) / f32(state.texture_height),
    }
    a := transform({destination.x, destination.y})
    b := transform({destination.x + destination.width, destination.y})
    c := transform({destination.x + destination.width, destination.y + destination.height})
    d := transform({destination.x, destination.y + destination.height})
    quad(a, b, c, d, color, uv0, uv1, 0)
}

LoadTexture :: proc(path: string) -> Texture {
    if !state.initialized {
        fmt.eprintln("canvas texture load before initialization: ", path)
        return {}
    }
    loaded: resources.Image
    // Startup can load many large atlases before the frame temp arena resets.
    // Decode through the general allocator so image.destroy releases each
    // source image immediately after its GPU upload.
    if !resources.texture_load_file(&state.ctx, path, &loaded, allocator = context.allocator) {
        fmt.eprintln("canvas texture upload failed: ", path)
        return {}
    }
    id, slot_ready := texture_slot_append()
    if !slot_ready {
        fmt.eprintln("canvas texture descriptor allocation failed: ", path)
        resources.image_destroy(&loaded, &state.ctx)
        return {}
    }
    state.textures[id] = loaded
    texture := &state.textures[id]
    ii := vk.DescriptorImageInfo {
        imageView   = texture.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
    si := vk.DescriptorImageInfo {
        sampler = texture.sampler,
    }
    writes := [2]vk.WriteDescriptorSet {
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.texture_descriptors[id],
            dstBinding = 0,
            descriptorCount = 1,
            descriptorType = .SAMPLED_IMAGE,
            pImageInfo = &ii,
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.texture_descriptors[id],
            dstBinding = 1,
            descriptorCount = 1,
            descriptorType = .SAMPLER,
            pImageInfo = &si,
        },
    }
    vk.UpdateDescriptorSets(state.ctx.device, 2, raw_data(writes[:]), 0, nil)
    return {id = id, width = int(texture.width), height = int(texture.height), ready = true}
}

CreateDynamicTextureRGBA :: proc(width, height: int, pixels: []u8) -> Texture {
    if (!state.initialized && !state.backend_initializing) || width <= 0 || height <= 0 do return {}
    loaded: resources.Image
    if !resources.texture_upload_rgba8(&state.ctx, pixels, width, height, &loaded, {address_mode = .CLAMP_TO_EDGE, linear_color = true}) do return {}
    id, slot_ready := texture_slot_append()
    if !slot_ready {
        resources.image_destroy(&loaded, &state.ctx)
        return {}
    }
    state.textures[id] = loaded
    texture := &state.textures[id]
    ii := vk.DescriptorImageInfo {
        imageView   = texture.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
    si := vk.DescriptorImageInfo {
        sampler = texture.sampler,
    }
    writes := [2]vk.WriteDescriptorSet {
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.texture_descriptors[id],
            dstBinding = 0,
            descriptorCount = 1,
            descriptorType = .SAMPLED_IMAGE,
            pImageInfo = &ii,
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.texture_descriptors[id],
            dstBinding = 1,
            descriptorCount = 1,
            descriptorType = .SAMPLER,
            pImageInfo = &si,
        },
    }
    vk.UpdateDescriptorSets(state.ctx.device, 2, raw_data(writes[:]), 0, nil)
    byte_count := width * height * 4
    state.dynamic_pixels[id] = make([dynamic]u8, byte_count)
    copy(state.dynamic_pixels[id][:], pixels[:byte_count])
    state.dynamic_bytes_per_pixel[id] = 4
    for frame in 0 ..< engine.MAX_FRAMES_IN_FLIGHT { if !engine.vk_create_host_buffer(&state.ctx, vk.DeviceSize(byte_count), {.TRANSFER_SRC}, &state.dynamic_staging[id][frame]) do return {} }
    return {id = id, width = width, height = height, ready = true}
}

UpdateDynamicTextureRGBA :: proc(texture: Texture, pixels: []u8) -> bool {
    if !state.initialized || !texture.ready || texture.id <= 0 || texture.id >= state.texture_count || len(pixels) < texture.width * texture.height * 4 do return false
    byte_count := texture.width * texture.height * 4
    if len(state.dynamic_pixels[texture.id]) != byte_count do return false
    copy(state.dynamic_pixels[texture.id][:], pixels[:byte_count])
    state.dynamic_dirty[texture.id] = {0, 0, f32(texture.width), f32(texture.height)}
    state.dynamic_pending[texture.id] = true
    return true
}

create_dynamic_texture_r8 :: proc(width, height: int, pixels: []u8) -> Texture {
    if state == nil || (!state.initialized && !state.backend_initializing) ||
       width <= 0 || height <= 0 || len(pixels) < width * height {
        return {}
    }
    loaded: resources.Image
    if !resources.texture_upload_r8(
        &state.ctx,
        pixels,
        width,
        height,
        &loaded,
    ) {
        return {}
    }
    id, slot_ready := texture_slot_append()
    if !slot_ready {
        resources.image_destroy(&loaded, &state.ctx)
        return {}
    }
    state.textures[id] = loaded
    texture := &state.textures[id]
    ii := vk.DescriptorImageInfo{imageView = texture.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    si := vk.DescriptorImageInfo{sampler = texture.sampler}
    writes := [2]vk.WriteDescriptorSet {
        {
            sType = .WRITE_DESCRIPTOR_SET, dstSet = state.texture_descriptors[id], dstBinding = 0,
            descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &ii,
        },
        {
            sType = .WRITE_DESCRIPTOR_SET, dstSet = state.texture_descriptors[id], dstBinding = 1,
            descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &si,
        },
    }
    vk.UpdateDescriptorSets(state.ctx.device, 2, raw_data(writes[:]), 0, nil)
    byte_count := width * height
    state.dynamic_pixels[id] = make([dynamic]u8, byte_count)
    copy(state.dynamic_pixels[id][:], pixels[:byte_count])
    state.dynamic_bytes_per_pixel[id] = 1
    for frame in 0 ..< engine.MAX_FRAMES_IN_FLIGHT {
        if !engine.vk_create_host_buffer(
            &state.ctx,
            vk.DeviceSize(byte_count),
            {.TRANSFER_SRC},
            &state.dynamic_staging[id][frame],
        ) {
            return {}
        }
    }
    return {id = id, width = width, height = height, ready = true}
}

update_dynamic_texture_r8_region :: proc(texture: Texture, pixels: []u8, region: Rectangle) -> bool {
    if !state.initialized || !texture.ready || texture.id <= 0 ||
       texture.id >= state.texture_count || state.dynamic_bytes_per_pixel[texture.id] != 1 {
        return false
    }
    x := clamp(int(region.x), 0, texture.width)
    y := clamp(int(region.y), 0, texture.height)
    right := clamp(int(region.x + region.width), x, texture.width)
    bottom := clamp(int(region.y + region.height), y, texture.height)
    width, height := right - x, bottom - y
    if width <= 0 || height <= 0 || len(pixels) < width * height do return false
    for row in 0 ..< height {
        destination := (y + row) * texture.width + x
        source := row * width
        copy(state.dynamic_pixels[texture.id][destination:destination + width], pixels[source:source + width])
    }
    dirty := &state.dynamic_dirty[texture.id]
    if !state.dynamic_pending[texture.id] {
        dirty^ = {f32(x), f32(y), f32(width), f32(height)}
    } else {
        dirty_right := max(dirty.x + dirty.width, f32(right))
        dirty_bottom := max(dirty.y + dirty.height, f32(bottom))
        dirty.x = min(dirty.x, f32(x))
        dirty.y = min(dirty.y, f32(y))
        dirty.width = dirty_right - dirty.x
        dirty.height = dirty_bottom - dirty.y
    }
    state.dynamic_pending[texture.id] = true
    return true
}

DrawTexturePro :: proc(texture: Texture, source, destination: Rectangle, tint := Color{255, 255, 255, 255}) {
    if !texture.ready || texture.id <= 0 || texture.id >= state.texture_count || texture.width <= 0 || texture.height <= 0 do return
    uv0 := Vector2{source.x / f32(texture.width), source.y / f32(texture.height)}
    uv1 := Vector2{(source.x + source.width) / f32(texture.width), (source.y + source.height) / f32(texture.height)}
    a := transform({destination.x, destination.y})
    b := transform({destination.x + destination.width, destination.y})
    c := transform({destination.x + destination.width, destination.y + destination.height})
    d := transform({destination.x, destination.y + destination.height})
    quad(a, b, c, d, tint, uv0, uv1, texture.id)
}
DrawTextureProRotated :: proc(
    texture: Texture,
    source, destination: Rectangle,
    rotation: f32,
    tint := Color{255, 255, 255, 255},
) {
    if !texture.ready || texture.id < 0 || texture.id >= state.texture_count do return
    uv0 := Vector2 {
        source.x / f32(texture.width),
        source.y / f32(texture.height),
    }; uv1 := Vector2{(source.x + source.width) / f32(texture.width), (source.y + source.height) / f32(texture.height)}
    cx :=
        destination.x +
        destination.width *
            .5; cy := destination.y + destination.height * .5; hw := destination.width * .5; hh := destination.height * .5; c := f32(math.cos(f64(rotation))); s := f32(math.sin(f64(rotation)))
    rotate_point :: proc(x, y, cx, cy, c, s: f32) -> Vector2 { return {cx + x * c - y * s, cy + x * s + y * c} }
    a := transform(
        rotate_point(-hw, -hh, cx, cy, c, s),
    ); b := transform(rotate_point(hw, -hh, cx, cy, c, s)); cc := transform(rotate_point(hw, hh, cx, cy, c, s)); d := transform(rotate_point(-hw, hh, cx, cy, c, s)); quad(a, b, cc, d, tint, uv0, uv1, texture.id)
}
DrawTextureProHatched :: proc(
    texture: Texture,
    source, destination: Rectangle,
    config := default_hatch,
    tint := Color{255, 255, 255, 255},
) {
    if !texture.ready || texture.id <= 0 || texture.id >= state.texture_count || texture.width <= 0 || texture.height <= 0 do return
    uv0 := Vector2{source.x / f32(texture.width), source.y / f32(texture.height)}
    uv1 := Vector2{(source.x + source.width) / f32(texture.width), (source.y + source.height) / f32(texture.height)}
    a := transform({destination.x, destination.y})
    b := transform({destination.x + destination.width, destination.y})
    c := transform({destination.x + destination.width, destination.y + destination.height})
    d := transform({destination.x, destination.y + destination.height})
    quad(a, b, c, d, tint, uv0, uv1, texture.id, config)
}
TakeScreenshot :: proc(path: cstring) {
    // Screenshot readback is completed by a later presented frame. Callers often
    // pass a temporary cstring, so retain our own copy until delivery completes.
    if len(state.capture_path) > 0 do delete(state.capture_path)
    state.capture_path = strings.clone_from_cstring(path)
    state.capture_requested = true
    state.capture_started = time.tick_now()
}
SetWorldPass :: proc(callback: World_Pass_Callback, user_data: rawptr = nil) {state.world_pass = callback
    state.world_pass_user_data = user_data}

SetWorldPrePass :: proc(callback: World_Pass_Callback, user_data: rawptr = nil) {
    state.world_pre_pass = callback
    state.world_pre_pass_user_data = user_data
}

SetWorldMaskPass :: proc(callback: World_Mask_Pass_Callback, user_data: rawptr = nil) {
    state.world_mask_pass = callback
    state.world_mask_pass_user_data = user_data
}

SetWorldMaskActive :: proc(active: bool) {
    state.world_mask_active = active
}

SetUIPass :: proc(callback: Ui_Pass_Callback, user_data: rawptr = nil) {state.ui_pass = callback
    state.ui_pass_user_data = user_data}

world_resolve_required :: proc(
    has_world_pass: bool,
    fixed_width, fixed_height: u32,
    post_process_enabled: bool,
) -> bool {
    return has_world_pass && ((fixed_width > 0 && fixed_height > 0) || post_process_enabled)
}

world_scene_extent :: proc() -> vk.Extent2D {
    if state.world_render_width > 0 && state.world_render_height > 0 {
        return {state.world_render_width, state.world_render_height}
    }
    return state.ctx.swapchain_extent
}

ensure_depth_attachment :: proc() -> bool {
    extent := world_scene_extent()
    requested := max(state.world_sample_count_requested, 1)
    effective := u32(1)
    if requested >= 4 && WorldSampleCountSupported(4) {
        effective = 4
    } else if requested >= 2 && WorldSampleCountSupported(2) {
        effective = 2
    }
    msaa_valid := effective == 1 ||
        (state.world_msaa_depth.width == extent.width && state.world_msaa_depth.height == extent.height &&
         state.world_msaa_depth.view != vk.ImageView(0) && state.world_sample_count_effective == effective)
    if state.depth.width == extent.width && state.depth.height == extent.height && state.depth.view != vk.ImageView(0) && msaa_valid do return true
    replacement_depth, replacement_msaa_depth: resources.Image
    created := resources.depth_create(&state.ctx, extent.width, extent.height, &replacement_depth)
    if created {
        sampler_info := vk.SamplerCreateInfo {
            sType = .SAMPLER_CREATE_INFO,
            magFilter = .NEAREST,
            minFilter = .NEAREST,
            addressModeU = .CLAMP_TO_EDGE,
            addressModeV = .CLAMP_TO_EDGE,
            addressModeW = .CLAMP_TO_EDGE,
            maxLod = 0,
        }
        if vk.CreateSampler(state.ctx.device, &sampler_info, nil, &replacement_depth.sampler) != .SUCCESS {
            resources.image_destroy(&replacement_depth, &state.ctx)
            return false
        }
        engine.vk_set_debug_name(&state.ctx, .SAMPLER, auto_cast replacement_depth.sampler, "canvas world depth sampler")
        if effective > 1 {
            samples := effective == 4 ? vk.SampleCountFlags{._4} : vk.SampleCountFlags{._2}
            if !resources.depth_create(&state.ctx, extent.width, extent.height, &replacement_msaa_depth, samples) {
                resources.image_destroy(&replacement_depth, &state.ctx)
                return false
            }
        }
    }
    if !created do return false
    _ = vk.DeviceWaitIdle(state.ctx.device)
    resources.image_destroy(&state.depth, &state.ctx)
    resources.image_destroy(&state.world_msaa_depth, &state.ctx)
    resources.image_destroy(&state.world_mask, &state.ctx)
    resources.image_destroy(&state.world_msaa_mask, &state.ctx)
    resources.image_destroy(&state.world_msaa_color, &state.ctx)
    state.depth = replacement_depth
    state.world_msaa_depth = replacement_msaa_depth
    state.world_sample_count_effective = effective
    state.depth_initialized = false
    state.depth_sample_ready = false
    state.world_mask_sample_ready = false
    state.world_msaa_color_initialized = false
    return true
}

ensure_world_mask_attachment :: proc() -> bool {
    if state.world_mask_pass == nil do return true
    extent := world_scene_extent()
    samples: vk.SampleCountFlags = {._1}
    if state.world_sample_count_effective == 2 do samples = {._2}
    if state.world_sample_count_effective == 4 do samples = {._4}
    msaa_required := state.world_sample_count_effective > 1
    valid := state.world_mask.width == extent.width && state.world_mask.height == extent.height &&
        state.world_mask.view != vk.ImageView(0)
    msaa_valid := !msaa_required ||
        (state.world_msaa_mask.width == extent.width && state.world_msaa_mask.height == extent.height &&
         state.world_msaa_mask.view != vk.ImageView(0))
    if valid && msaa_valid do return true

    mask, msaa_mask: resources.Image
    if !resources.image_create(
        &state.ctx,
        extent.width,
        extent.height,
        .R8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
        {.COLOR},
        {._1},
        &mask,
        "canvas world mask",
    ) {
        return false
    }
    sampler_info := vk.SamplerCreateInfo {
        sType = .SAMPLER_CREATE_INFO,
        magFilter = .NEAREST,
        minFilter = .NEAREST,
        addressModeU = .CLAMP_TO_EDGE,
        addressModeV = .CLAMP_TO_EDGE,
        addressModeW = .CLAMP_TO_EDGE,
        maxLod = 0,
    }
    if vk.CreateSampler(state.ctx.device, &sampler_info, nil, &mask.sampler) != .SUCCESS {
        resources.image_destroy(&mask, &state.ctx)
        return false
    }
    engine.vk_set_debug_name(&state.ctx, .SAMPLER, auto_cast mask.sampler, "canvas world mask sampler")
    if msaa_required && !resources.image_create(
        &state.ctx,
        extent.width,
        extent.height,
        .R8_UNORM,
        {.COLOR_ATTACHMENT},
        {.COLOR},
        samples,
        &msaa_mask,
        "canvas multisampled world mask",
    ) {
        resources.image_destroy(&mask, &state.ctx)
        return false
    }
    _ = vk.DeviceWaitIdle(state.ctx.device)
    resources.image_destroy(&state.world_mask, &state.ctx)
    resources.image_destroy(&state.world_msaa_mask, &state.ctx)
    state.world_mask = mask
    state.world_msaa_mask = msaa_mask
    state.world_mask_sample_ready = false
    return true
}

ensure_world_msaa_color :: proc(extent: vk.Extent2D, format: vk.Format) -> bool {
    if state.world_sample_count_effective <= 1 do return true
    target := &state.world_msaa_color
    if target.width == extent.width && target.height == extent.height && target.format == format && target.view != vk.ImageView(0) do return true
    samples := state.world_sample_count_effective == 4 ? vk.SampleCountFlags{._4} : vk.SampleCountFlags{._2}
    replacement: resources.Image
    if !resources.image_create(
        &state.ctx,
        extent.width,
        extent.height,
        format,
        {.COLOR_ATTACHMENT},
        {.COLOR},
        samples,
        &replacement,
        "canvas multisampled world color",
    ) {
        return false
    }
    _ = vk.DeviceWaitIdle(state.ctx.device)
    resources.image_destroy(target, &state.ctx)
    target^ = replacement
    state.world_msaa_color_initialized = false
    return true
}

ensure_world_scene :: proc() -> bool {
    fixed_world := state.world_render_width > 0 && state.world_render_height > 0
    if !fixed_world && !state.world_post_process_enabled do return true
    extent := world_scene_extent()
    if state.world_scene.width == extent.width &&
       state.world_scene.height == extent.height &&
       state.world_scene.view != vk.ImageView(0) {
        return true
    }
    _ = vk.DeviceWaitIdle(state.ctx.device)
    resources.image_destroy(&state.world_scene, &state.ctx)
    state.world_scene_sample_ready = false
    created := resources.image_create(
        &state.ctx,
        extent.width,
        extent.height,
        state.ctx.swapchain_format,
        {.COLOR_ATTACHMENT, .SAMPLED},
        {.COLOR},
        {._1},
        &state.world_scene,
        "world post-process scene",
    )
    if !created do return false
    sampler_info := vk.SamplerCreateInfo {
        sType        = .SAMPLER_CREATE_INFO,
        magFilter    = .LINEAR,
        minFilter    = .LINEAR,
        addressModeU = .CLAMP_TO_EDGE,
        addressModeV = .CLAMP_TO_EDGE,
        addressModeW = .CLAMP_TO_EDGE,
        maxLod       = 0,
    }
    if vk.CreateSampler(state.ctx.device, &sampler_info, nil, &state.world_scene.sampler) != .SUCCESS {
        resources.image_destroy(&state.world_scene, &state.ctx)
        return false
    }
    engine.vk_set_debug_name(&state.ctx, .SAMPLER, auto_cast state.world_scene.sampler, "canvas world scene sampler")
    image_info := vk.DescriptorImageInfo {
        imageView   = state.world_scene.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
    sampler := vk.DescriptorImageInfo {
        sampler = state.world_scene.sampler,
    }
    depth_image_info := vk.DescriptorImageInfo {
        imageView = state.depth.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
    depth_sampler := vk.DescriptorImageInfo {sampler = state.depth.sampler}
    aux0_id := clamp(state.world_post_aux_texture_ids[0], 0, max(state.texture_count - 1, 0))
    aux1_id := clamp(state.world_post_aux_texture_ids[1], 0, max(state.texture_count - 1, 0))
    aux0_image := vk.DescriptorImageInfo {imageView = state.textures[aux0_id].view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    aux0_sampler := vk.DescriptorImageInfo {sampler = state.textures[aux0_id].sampler}
    aux1_image := vk.DescriptorImageInfo {imageView = state.textures[aux1_id].view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    aux1_sampler := vk.DescriptorImageInfo {sampler = state.textures[aux1_id].sampler}
    writes := [8]vk.WriteDescriptorSet {
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.post_descriptors[WORLD_POST_SCENE_DESCRIPTOR],
            dstBinding = 0,
            descriptorCount = 1,
            descriptorType = .SAMPLED_IMAGE,
            pImageInfo = &image_info,
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.post_descriptors[WORLD_POST_SCENE_DESCRIPTOR],
            dstBinding = 1,
            descriptorCount = 1,
            descriptorType = .SAMPLER,
            pImageInfo = &sampler,
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.post_descriptors[WORLD_POST_SCENE_DESCRIPTOR],
            dstBinding = 2,
            descriptorCount = 1,
            descriptorType = .SAMPLED_IMAGE,
            pImageInfo = &depth_image_info,
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.post_descriptors[WORLD_POST_SCENE_DESCRIPTOR],
            dstBinding = 3,
            descriptorCount = 1,
            descriptorType = .SAMPLER,
            pImageInfo = &depth_sampler,
        },
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[WORLD_POST_SCENE_DESCRIPTOR], dstBinding = 4, descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &aux0_image},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[WORLD_POST_SCENE_DESCRIPTOR], dstBinding = 5, descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &aux0_sampler},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[WORLD_POST_SCENE_DESCRIPTOR], dstBinding = 6, descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &aux1_image},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[WORLD_POST_SCENE_DESCRIPTOR], dstBinding = 7, descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &aux1_sampler},
    }
    vk.UpdateDescriptorSets(state.ctx.device, 8, raw_data(writes[:]), 0, nil)
    update_world_post_descriptor(WORLD_POST_SCENE_DESCRIPTOR, &state.world_scene, &state.world_scene)
    return true
}

world_post_resolution_extent :: proc(source: vk.Extent2D, resolution: World_Post_Resolution) -> vk.Extent2D {
    divisor: u32 = 1
    if resolution == .Half do divisor = 2
    if resolution == .Quarter do divisor = 4
    return {max(source.width / divisor, 1), max(source.height / divisor, 1)}
}

ensure_world_post_ping :: proc(index: int, extent: vk.Extent2D) -> bool {
    target := &state.world_post_ping[index]
    if target.width == extent.width && target.height == extent.height && target.view != vk.ImageView(0) do return true
    _ = vk.DeviceWaitIdle(state.ctx.device)
    resources.image_destroy(target, &state.ctx)
    state.world_post_ping_sample_ready[index] = false
    name := index == 0 ? "canvas world post ping 0" : "canvas world post ping 1"
    if !resources.image_create(&state.ctx, extent.width, extent.height, state.ctx.swapchain_format, {.COLOR_ATTACHMENT, .SAMPLED}, {.COLOR}, {._1}, target, name) do return false
    sampler_info := vk.SamplerCreateInfo{sType = .SAMPLER_CREATE_INFO, magFilter = .LINEAR, minFilter = .LINEAR, addressModeU = .CLAMP_TO_EDGE, addressModeV = .CLAMP_TO_EDGE, addressModeW = .CLAMP_TO_EDGE, maxLod = 0}
    if vk.CreateSampler(state.ctx.device, &sampler_info, nil, &target.sampler) != .SUCCESS {
        resources.image_destroy(target, &state.ctx)
        return false
    }
    sampler_name := index == 0 ? "canvas world post ping sampler 0" : "canvas world post ping sampler 1"
    engine.vk_set_debug_name(&state.ctx, .SAMPLER, auto_cast target.sampler, sampler_name)
    return true
}

update_world_post_descriptor :: proc(descriptor_index: int, source: ^resources.Image, original: ^resources.Image = nil) {
    original_image_source := original
    if original_image_source == nil do original_image_source = source
    source_image := vk.DescriptorImageInfo{imageView = source.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    source_sampler := vk.DescriptorImageInfo{sampler = source.sampler}
    depth_image := vk.DescriptorImageInfo{imageView = state.depth.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    depth_sampler := vk.DescriptorImageInfo{sampler = state.depth.sampler}
    aux0_id := clamp(state.world_post_aux_texture_ids[0], 0, max(state.texture_count - 1, 0))
    aux1_id := clamp(state.world_post_aux_texture_ids[1], 0, max(state.texture_count - 1, 0))
    aux0_image := vk.DescriptorImageInfo{imageView = state.textures[aux0_id].view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    aux0_sampler := vk.DescriptorImageInfo{sampler = state.textures[aux0_id].sampler}
    aux1_image := vk.DescriptorImageInfo{imageView = state.textures[aux1_id].view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    aux1_sampler := vk.DescriptorImageInfo{sampler = state.textures[aux1_id].sampler}
    original_image := vk.DescriptorImageInfo{imageView = original_image_source.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    original_sampler := vk.DescriptorImageInfo{sampler = original_image_source.sampler}
    mask_source := &state.world_mask
    if mask_source.view == vk.ImageView(0) do mask_source = &state.textures[0]
    mask_image := vk.DescriptorImageInfo{imageView = mask_source.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    mask_sampler := vk.DescriptorImageInfo{sampler = mask_source.sampler}
    writes := [12]vk.WriteDescriptorSet{
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 0, descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &source_image},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 1, descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &source_sampler},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 2, descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &depth_image},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 3, descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &depth_sampler},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 4, descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &aux0_image},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 5, descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &aux0_sampler},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 6, descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &aux1_image},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 7, descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &aux1_sampler},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 8, descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &original_image},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 9, descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &original_sampler},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 10, descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &mask_image},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[descriptor_index], dstBinding = 11, descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &mask_sampler},
    }
    vk.UpdateDescriptorSets(state.ctx.device, 12, raw_data(writes[:]), 0, nil)
}

ensure_hdr_scene :: proc() -> bool {
    extent := state.ctx.swapchain_extent
    if state.hdr_scene.width == extent.width && state.hdr_scene.height == extent.height && state.hdr_scene.view != vk.ImageView(0) do return true
    _ = vk.DeviceWaitIdle(state.ctx.device)
    resources.image_destroy(&state.hdr_scene, &state.ctx)
    if !resources.image_create(&state.ctx, extent.width, extent.height, .R16G16B16A16_SFLOAT, {.COLOR_ATTACHMENT, .SAMPLED}, {.COLOR}, {._1}, &state.hdr_scene, "stellar HDR scene") do return false
    sampler_info := vk.SamplerCreateInfo {
        sType        = .SAMPLER_CREATE_INFO,
        magFilter    = .LINEAR,
        minFilter    = .LINEAR,
        addressModeU = .CLAMP_TO_EDGE,
        addressModeV = .CLAMP_TO_EDGE,
        addressModeW = .CLAMP_TO_EDGE,
        maxLod       = 0,
    }
    if vk.CreateSampler(state.ctx.device, &sampler_info, nil, &state.hdr_scene.sampler) !=
       .SUCCESS { resources.image_destroy(&state.hdr_scene, &state.ctx); return false }
    engine.vk_set_debug_name(&state.ctx, .SAMPLER, auto_cast state.hdr_scene.sampler, "canvas HDR scene sampler")
    ii := vk.DescriptorImageInfo {
        imageView   = state.hdr_scene.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
    si := vk.DescriptorImageInfo {
        sampler = state.hdr_scene.sampler,
    }
    depth_image_info := vk.DescriptorImageInfo {imageView = state.depth.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    depth_sampler := vk.DescriptorImageInfo {sampler = state.depth.sampler}
    aux0_id := clamp(state.world_post_aux_texture_ids[0], 0, max(state.texture_count - 1, 0))
    aux1_id := clamp(state.world_post_aux_texture_ids[1], 0, max(state.texture_count - 1, 0))
    aux0_image := vk.DescriptorImageInfo {imageView = state.textures[aux0_id].view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    aux0_sampler := vk.DescriptorImageInfo {sampler = state.textures[aux0_id].sampler}
    aux1_image := vk.DescriptorImageInfo {imageView = state.textures[aux1_id].view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
    aux1_sampler := vk.DescriptorImageInfo {sampler = state.textures[aux1_id].sampler}
    writes := [8]vk.WriteDescriptorSet {
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.post_descriptors[WORLD_POST_HDR_DESCRIPTOR],
            dstBinding = 0,
            descriptorCount = 1,
            descriptorType = .SAMPLED_IMAGE,
            pImageInfo = &ii,
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.post_descriptors[WORLD_POST_HDR_DESCRIPTOR],
            dstBinding = 1,
            descriptorCount = 1,
            descriptorType = .SAMPLER,
            pImageInfo = &si,
        },
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[WORLD_POST_HDR_DESCRIPTOR], dstBinding = 2, descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &depth_image_info},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[WORLD_POST_HDR_DESCRIPTOR], dstBinding = 3, descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &depth_sampler},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[WORLD_POST_HDR_DESCRIPTOR], dstBinding = 4, descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &aux0_image},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[WORLD_POST_HDR_DESCRIPTOR], dstBinding = 5, descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &aux0_sampler},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[WORLD_POST_HDR_DESCRIPTOR], dstBinding = 6, descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &aux1_image},
        {sType = .WRITE_DESCRIPTOR_SET, dstSet = state.post_descriptors[WORLD_POST_HDR_DESCRIPTOR], dstBinding = 7, descriptorCount = 1, descriptorType = .SAMPLER, pImageInfo = &aux1_sampler},
    }
    vk.UpdateDescriptorSets(state.ctx.device, 8, raw_data(writes[:]), 0, nil)
    update_world_post_descriptor(WORLD_POST_HDR_DESCRIPTOR, &state.hdr_scene, &state.hdr_scene)
    return true
}
