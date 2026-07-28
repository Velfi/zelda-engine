package ui

import "core:fmt"
import "core:math"
import "core:strconv"

gui_label :: proc(ctx: ^Gui_Context, text: string) {
    type := gui_typography(ctx.style, .Body)
    bounds := gui_next_rect(ctx, height = type.line_height)
    gui_text_clipped(
        ctx,
        bounds,
        {bounds.x + gui_space(ctx.style, .Quarter), bounds.y + gui_text_inset_y(ctx.style, .Body, bounds.h)},
        text,
        ctx.style.text_muted,
    )
}

gui_heading :: proc(ctx: ^Gui_Context, text: string) {
    type := gui_typography(ctx.style, .Heading)
    bounds := gui_next_rect(ctx, height = type.line_height)
    gui_scissor_begin(ctx, bounds)
    append(&ctx.commands, Draw_Command {
        kind       = .Text,
        rect       = {
            bounds.x + gui_space(ctx.style, .Quarter),
            bounds.y + gui_text_inset_y(ctx.style, .Heading, bounds.h),
            0,
            0,
        },
        color      = ctx.style.text,
        text       = text,
        text_scale = type.text_scale,
        text_align = .Left,
        font_kind  = type.font_kind,
    })
    gui_scissor_end(ctx)
    line_y := bounds.y + bounds.h - ctx.style.border_width
    gui_rect(ctx, {bounds.x, line_y, bounds.w, ctx.style.border_width}, {1, 1, 1, 0.20})
}

gui_text_block :: proc(ctx: ^Gui_Context, text: string, max_width: f32, color: Color) {
    type := gui_typography(ctx.style, .Body)
    inline_inset := gui_space(ctx.style, .Quarter)
    wrap_width := max(max_width - inline_inset, type.char_width)
    lines := gui_wrap_line_count(ctx, text, wrap_width)
    bounds := gui_next_rect(ctx, height = gui_text_block_height(ctx.style, .Body, lines))
    gui_scissor_begin(ctx, bounds)
    gui_text_wrapped_at(
        ctx,
        {bounds.x + inline_inset, bounds.y + gui_text_line_inset_y(ctx.style, .Body)},
        text,
        wrap_width,
        color,
    )
    gui_scissor_end(ctx)
}

gui_rhythm_spacer :: proc(ctx: ^Gui_Context, space: Gui_Space = .One) {
    gui_spacer(ctx, gui_space(ctx.style, space))
}

gui_spacer :: proc(ctx: ^Gui_Context, height: f32) {
    _ = gui_next_rect(ctx, height = height)
}

gui_disabled_button :: proc(ctx: ^Gui_Context, label: string) {
    bounds := gui_next_rect(ctx, width = gui_button_content_width(ctx, label), stretch_cross_axis = false)
    color := ctx.style.control_disabled
    text_color := Color{ctx.style.text.r * 0.55, ctx.style.text.g * 0.55, ctx.style.text.b * 0.55, 0.95}
    gui_round_rect(ctx, bounds, ctx.style.radius_control, color)
    gui_round_stroke(ctx, bounds, ctx.style.radius_control, ctx.style.panel_border, ctx.style.border_width)
    gui_text(
        ctx,
        {bounds.x + ctx.style.control_padding * 1.5, bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0)},
        label,
        text_color,
    )
}

gui_button :: gui_button_keyed

gui_button_keyed :: proc(ctx: ^Gui_Context, label, key: string) -> bool {
    id := gui_make_id(ctx, key)
    bounds := gui_next_rect(ctx, width = gui_button_content_width(ctx, label), stretch_cross_axis = false)
    return gui_button_at(ctx, id, bounds, label, true)
}

gui_button_content_width :: proc(ctx: ^Gui_Context, label: string) -> f32 {
    text_w := gui_text_width(ctx, label)
    return max(text_w + ctx.style.control_padding * 3, ctx.style.row_height)
}

gui_button_at :: proc(
    ctx: ^Gui_Context,
    id: Gui_Id,
    bounds: Rect,
    label: string,
    enabled: bool,
    pointer_focus := true,
) -> bool {
    control := gui_control(ctx, id, bounds, enabled, true, pointer_focus)

    color := ctx.style.control
    border := ctx.style.panel_border
    stroke_width := ctx.style.border_width
    text_color := enabled ? ctx.style.text : ctx.style.text_muted
    if !enabled {
        color = ctx.style.control_disabled
    } else if ctx.active == id {
        color = gui_lerp_color(ctx.style.control_hot, ctx.style.accent, 0.18)
        border = gui_apply_opacity(ctx.style.accent, 0.62)
        stroke_width = max(ctx.style.border_width * 2, 2)
    } else if ctx.hot == id || control.focused {
        color = ctx.style.control_hot
        border = control.focused ? gui_apply_opacity(ctx.style.accent, 0.78) : gui_apply_opacity(ctx.style.text, 0.46)
        if control.focused {
            stroke_width = max(ctx.style.border_width * 2, 2)
        }
    }
    if enabled && ctx.input.delta_time > 0 {
        hot_t := gui_animate_value(ctx, id, (ctx.hot == id || ctx.active == id) ? f32(1) : f32(0), 10)
        target :=
            ctx.active == id ? gui_lerp_color(ctx.style.control_hot, ctx.style.accent, 0.18) : ctx.style.control_hot
        color = gui_lerp_color(ctx.style.control, target, hot_t)
    }

    gui_shadow(
        ctx,
        bounds,
        ctx.style.radius_control,
        ctx.style.shadow_offset,
        ctx.style.shadow_blur * 0.42,
        {0, 0, 0, enabled ? f32(0.18) : f32(0.08)},
    )
    gui_round_rect(ctx, bounds, ctx.style.radius_control, color)
    gui_round_stroke(ctx, bounds, ctx.style.radius_control, border, stroke_width)
    if ctx.focused == id {
        gui_focus_ring(ctx, bounds)
    }
    inset := ctx.style.control_padding
    if len(label) > 0 {
        text_rect := gui_inset(bounds, inset)
        gui_scissor_begin(ctx, text_rect)
        gui_text_centered(ctx, text_rect, label, text_color)
        gui_scissor_end(ctx)
    }

    return control.activated || (enabled && control.hovered && ctx.active == id && ctx.input.mouse_released)
}

gui_card_button :: gui_card_button_keyed

gui_card_button_keyed :: proc(ctx: ^Gui_Context, bounds: Rect, title, key, subtitle: string, enabled := true) -> bool {
    id := gui_make_id(ctx, key)
    clicked := gui_button_at(ctx, id, bounds, "", enabled)
    title_color :=
        enabled ? ctx.style.text : Color{ctx.style.text.r * 0.55, ctx.style.text.g * 0.55, ctx.style.text.b * 0.55, 1}
    subtitle_color := enabled ? ctx.style.text_muted : Color{0.45, 0.48, 0.52, 1}
    text_rect := gui_inset(bounds, ctx.style.spacing_2)
    title_y := bounds.y + ctx.style.spacing_2
    gui_text_clipped(ctx, text_rect, {bounds.x + 16, title_y}, title, title_color)
    gui_text_clipped(ctx, text_rect, {bounds.x + 16, title_y + ctx.style.body_line_height}, subtitle, subtitle_color)
    return clicked
}

gui_toggle :: gui_toggle_keyed

gui_toggle_keyed :: proc(ctx: ^Gui_Context, label, key: string, value: ^bool) -> bool {
    return gui_switch_keyed(ctx, label, key, value)
}

gui_numeric_f32 :: gui_numeric_f32_keyed

gui_numeric_precision_scales := [5]f32{0.01, 0.1, 1, 10, 100}

Gui_Numeric_Mapping :: enum {
    Linear,
    Logarithmic,
    Symmetric_Log,
}

Gui_Numeric_Regions :: struct {
    decrement, value, increment: Rect,
}

gui_numeric_expanded :: proc(ctx: ^Gui_Context, id: Gui_Id) -> bool {
    return ctx.focus_edit_id == id || ctx.text_edit_id == id || ctx.active == id
}

gui_numeric_height :: proc(ctx: ^Gui_Context, id: Gui_Id) -> f32 {
    return(
        gui_numeric_expanded(ctx, id) ? max(ctx.style.row_height + ctx.style.small_line_height, f32(60)) : ctx.style.row_height \
    )
}

gui_numeric_regions :: proc(ctx: ^Gui_Context, bounds: Rect) -> Gui_Numeric_Regions {
    edge := min(max(ctx.style.row_height, f32(44)), bounds.w * 0.22)
    return {
        decrement = {bounds.x, bounds.y, edge, bounds.h},
        value = {bounds.x + edge, bounds.y, max(bounds.w - edge * 2, 1), bounds.h},
        increment = {bounds.x + bounds.w - edge, bounds.y, edge, bounds.h},
    }
}

gui_numeric_text_rect :: proc(ctx: ^Gui_Context, bounds: Rect, editing: bool) -> Rect {
    result := gui_inset(gui_numeric_regions(ctx, bounds).value, ctx.style.control_padding)
    if editing do result.h = min(result.h, ctx.style.body_line_height + ctx.style.spacing_1)
    return result
}

gui_numeric_draw_display :: proc(ctx: ^Gui_Context, bounds: Rect, display: string, color: Color, editing: bool) {
    text_rect := gui_numeric_text_rect(ctx, bounds, editing)
    separator := -1
    for ch, index in transmute([]u8)display {
        if ch == ':' {
            separator = index
            break
        }
    }
    baseline_y := text_rect.y + max((text_rect.h - ctx.style.body_text_height) * 0.5, 0)
    if separator > 0 && separator + 1 < len(display) {
        label := display[:separator]
        value := display[separator + 1:]
        for len(value) > 0 && value[0] == ' ' do value = value[1:]
        mid := text_rect.x + text_rect.w * 0.52
        label_rect := Rect{text_rect.x, text_rect.y, max(mid - text_rect.x - ctx.style.spacing_1, 1), text_rect.h}
        value_h := ctx.style.body_line_height
        value_y := editing ? bounds.y + max((bounds.h - value_h) * 0.5, 0) : text_rect.y
        value_rect := Rect{mid, value_y, max(text_rect.x + text_rect.w - mid, 1), value_h}
        gui_text_clipped(ctx, label_rect, {label_rect.x, baseline_y}, label, editing ? ctx.style.text_muted : color)
        gui_text_right(ctx, value_rect, value, color)
    } else {
        gui_text_clipped(ctx, text_rect, {text_rect.x, baseline_y}, display, color)
    }
}

gui_numeric_draw_step :: proc(ctx: ^Gui_Context, bounds: Rect, effective_step: string) {
    regions := gui_numeric_regions(ctx, bounds)
    meta := Rect {
        regions.value.x + ctx.style.control_padding,
        bounds.y + ctx.style.body_line_height + ctx.style.spacing_1,
        max(regions.value.w - ctx.style.control_padding * 2, 1),
        ctx.style.small_line_height,
    }
    gui_text_clipped(ctx, meta, {meta.x, meta.y}, fmt.tprintf("Step %s", effective_step), ctx.style.accent)
}

gui_numeric_pointer_step_direction :: proc(ctx: ^Gui_Context, id: Gui_Id, bounds: Rect) -> f32 {
    if ctx.active != id || !ctx.input.mouse_released || ctx.numeric_pointer_distance >= 4 {
        return 0
    }
    regions := gui_numeric_regions(ctx, bounds)
    if gui_contains(regions.decrement, ctx.input.mouse_pos) do return -1
    if gui_contains(regions.increment, ctx.input.mouse_pos) do return 1
    return 0
}

gui_numeric_pointer_value_tapped :: proc(ctx: ^Gui_Context, id: Gui_Id, bounds: Rect) -> bool {
    if ctx.active != id || !ctx.input.mouse_released || ctx.numeric_pointer_distance >= 4 {
        return false
    }
    return gui_contains(gui_numeric_regions(ctx, bounds).value, ctx.input.mouse_pos)
}

gui_numeric_pointer_track :: proc(ctx: ^Gui_Context, id: Gui_Id) {
    if ctx.active != id do return
    if ctx.input.mouse_pressed || ctx.numeric_pointer_id != id {
        ctx.numeric_pointer_id = id
        ctx.numeric_pointer_distance = 0
    }
    if ctx.input.mouse_down {
        ctx.numeric_pointer_distance += abs(ctx.mouse_delta.x) + abs(ctx.mouse_delta.y)
    }
}

gui_numeric_normalized :: proc(value, min_value, max_value: f32, mapping: Gui_Numeric_Mapping) -> f32 {
    range := max(max_value - min_value, 0.000001)
    switch mapping {
    case .Logarithmic:
        if min_value > 0 && max_value > min_value {
            return gui_clamp01(math.ln(value / min_value) / math.ln(max_value / min_value))
        }
    case .Symmetric_Log:
        extent := max(abs(min_value), abs(max_value))
        if extent > 0 {
            linear_region := max(extent * 0.01, f32(0.000001))
            mapped_extent := f32(math.log1p(f64(extent / linear_region)))
            mapped := f32(math.log1p(f64(abs(value) / linear_region))) / max(mapped_extent, f32(0.000001))
            if value < 0 do mapped = -mapped
            return gui_clamp01(mapped * 0.5 + 0.5)
        }
    case .Linear:
    }
    return gui_clamp01((value - min_value) / range)
}

gui_numeric_precision_scale :: proc(ctx: ^Gui_Context, id: Gui_Id, editing: bool) -> f32 {
    if editing && ctx.numeric_precision_id != id {
        ctx.numeric_precision_id = id
        ctx.numeric_precision_index = 2
    }
    if editing && ctx.input.secondary_pressed {
        ctx.numeric_precision_index = (ctx.numeric_precision_index + 1) % len(gui_numeric_precision_scales)
    }
    scale := f32(1)
    if editing && ctx.numeric_precision_id == id {
        scale = gui_numeric_precision_scales[ctx.numeric_precision_index]
    }
    return scale
}

gui_numeric_current_scale :: proc(ctx: ^Gui_Context, id: Gui_Id) -> f32 {
    if ctx.numeric_precision_id == id do return gui_numeric_precision_scales[ctx.numeric_precision_index]
    return 1
}

gui_numeric_context_hint :: proc(ctx: ^Gui_Context, id: Gui_Id, text_editing: bool) {
    hint := "Click the value to type it. Use +/- or drag horizontally to adjust; Shift is fine and Ctrl/Cmd is 10x."
    if text_editing {
        hint = "Type a value, then press Enter to commit or Escape to cancel."
    } else if ctx.input.active_device == .Controller {
        hint = "D-pad adjusts. Press Secondary to cycle the step: 0.01x, 0.1x, 1x, 10x, or 100x. Accept commits; Back cancels."
    } else if ctx.focus_edit_id == id {
        hint = "Arrows adjust. Press the secondary mouse button to cycle the step: 0.01x, 0.1x, 1x, 10x, or 100x. Shift is fine; Ctrl/Cmd is 10x."
    }
    gui_numeric_tooltip_for_id(ctx, id, hint, text_editing)
}

gui_numeric_track :: proc(
    ctx: ^Gui_Context,
    id: Gui_Id,
    bounds: Rect,
    value, min_value, max_value: f32,
    editing, prominent: bool,
    mapping := Gui_Numeric_Mapping.Linear,
) {
    range := max(max_value - min_value, 0.000001)
    t := gui_numeric_normalized(value, min_value, max_value, mapping)
    track_h :=
        prominent ? max(ctx.style.border_width * 3, f32(6)) : (editing ? max(ctx.style.border_width * 3, f32(5)) : max(ctx.style.border_width * 2, f32(3)))
    inset := prominent ? max(ctx.style.spacing_2, f32(9)) : ctx.style.control_padding * 1.5
    track_y := bounds.y + bounds.h - track_h - (editing ? ctx.style.spacing_1 : 0)
    track := Rect{bounds.x + inset, track_y, max(bounds.w - inset * 2, 1), track_h}
    if !prominent {
        value_region := gui_numeric_regions(ctx, bounds).value
        track.x = value_region.x + inset
        track.w = max(value_region.w - inset * 2, 1)
    }
    fill := track
    fill.w *= t
    gui_round_rect(ctx, track, track_h * 0.5, gui_apply_opacity(ctx.style.panel_border, 0.72))
    gui_round_rect(ctx, fill, track_h * 0.5, editing ? ctx.style.accent : gui_apply_opacity(ctx.style.accent, 0.58))

    // Default/centre landmark for signed ranges, plus an unmistakable thumb.
    if min_value < 0 && max_value > 0 {
        zero_x := track.x + track.w * gui_clamp01((0 - min_value) / range)
        gui_rect(
            ctx,
            {zero_x - ctx.style.border_width * 0.5, track.y - 2, ctx.style.border_width, track.h + 4},
            gui_apply_opacity(ctx.style.text, 0.48),
        )
    }
    thumb_x := track.x + track.w * t
    thumb_r := prominent ? f32(7) : (editing ? f32(4) : f32(3))
    gui_ellipse(
        ctx,
        {
            thumb_x - thumb_r - ctx.style.border_width,
            track.y + track.h * 0.5 - thumb_r - ctx.style.border_width,
            (thumb_r + ctx.style.border_width) * 2,
            (thumb_r + ctx.style.border_width) * 2,
        },
        ctx.style.panel_border,
    )
    gui_ellipse(
        ctx,
        {thumb_x - thumb_r, track.y + track.h * 0.5 - thumb_r, thumb_r * 2, thumb_r * 2},
        editing ? ctx.style.accent : ctx.style.text,
    )

    if !prominent {
        regions := gui_numeric_regions(ctx, bounds)
        left := regions.decrement
        right := regions.increment
        button_fill :=
            editing ? gui_apply_opacity(ctx.style.accent, 0.10) : gui_apply_opacity(ctx.style.control_hot, 0.34)
        gui_round_rect(ctx, left, ctx.style.radius_control, button_fill)
        gui_round_rect(ctx, right, ctx.style.radius_control, button_fill)
        cue_color := gui_apply_opacity(ctx.style.text_muted, ctx.hot == id ? f32(0.92) : f32(0.58))
        if editing do cue_color = ctx.style.text
        gui_line(
            ctx,
            {left.x + left.w, left.y + ctx.style.spacing_1},
            {left.x + left.w, left.y + left.h - ctx.style.spacing_1},
            gui_apply_opacity(ctx.style.panel_border, 0.62),
            ctx.style.border_width,
        )
        gui_line(
            ctx,
            {right.x, right.y + ctx.style.spacing_1},
            {right.x, right.y + right.h - ctx.style.spacing_1},
            gui_apply_opacity(ctx.style.panel_border, 0.62),
            ctx.style.border_width,
        )
        glyph_h := ctx.style.body_line_height
        left_glyph := Rect{left.x, left.y + max((left.h - glyph_h) * 0.5, 0), left.w, glyph_h}
        right_glyph := Rect{right.x, right.y + max((right.h - glyph_h) * 0.5, 0), right.w, glyph_h}
        gui_text_centered(ctx, left_glyph, "-", cue_color)
        gui_text_centered(ctx, right_glyph, "+", cue_color)
    }
}

gui_grouped_u32 :: proc(value: u32) -> string {
    if value >= 1_000_000_000 {
        return fmt.tprintf(
            "%d,%03d,%03d,%03d",
            value / 1_000_000_000,
            value / 1_000_000 % 1000,
            value / 1000 % 1000,
            value % 1000,
        )
    }
    if value >= 1_000_000 {
        return fmt.tprintf("%d,%03d,%03d", value / 1_000_000, value / 1000 % 1000, value % 1000)
    }
    if value >= 1000 {
        return fmt.tprintf("%d,%03d", value / 1000, value % 1000)
    }
    return fmt.tprintf("%d", value)
}

gui_numeric_u32_text_begin :: proc(ctx: ^Gui_Context, id: Gui_Id, value: u32) {
    ctx.numeric_edit_snapshot_id = id
    ctx.numeric_edit_snapshot_u32 = value
    ctx.text_edit_id = id
    text := fmt.tprintf("%d", value)
    ctx.text_edit_len = min(len(text), len(ctx.text_edit_buffer))
    copy(ctx.text_edit_buffer[:], transmute([]u8)text[:ctx.text_edit_len])
    ctx.text_edit_caret = ctx.text_edit_len
    ctx.text_edit_anchor = 0
}

gui_numeric_u32_display :: proc(label: string, value: u32, unit: string, grouped: bool) -> string {
    formatted := grouped ? gui_grouped_u32(value) : fmt.tprintf("%d", value)
    if len(unit) > 0 do return fmt.tprintf("%s: %s %s", label, formatted, unit)
    return fmt.tprintf("%s: %s", label, formatted)
}

// Exact unsigned adapter for the shared numeric control. Keyboard/touch entry
// accepts plain counts or k/M/G suffixes; adjustment never round-trips through
// f32, so every u32 value remains representable.
gui_numeric_u32 :: proc(
    ctx: ^Gui_Context,
    label, key: string,
    value: ^u32,
    min_value, max_value: u32,
    step_value := u32(1),
    enabled := true,
    unit := "",
    grouped := true,
) -> bool {
    id := gui_make_id(ctx, key)
    bounds := gui_next_rect(ctx, height = gui_numeric_height(ctx, id))
    if !enabled {
        gui_round_rect(ctx, bounds, ctx.style.radius_control, ctx.style.control_disabled)
        gui_round_stroke(ctx, bounds, ctx.style.radius_control, ctx.style.panel_border, ctx.style.border_width)
        display := gui_numeric_u32_display(label, value^, unit, grouped)
        gui_text_clipped(
            ctx,
            gui_inset(bounds, ctx.style.control_padding),
            {
                bounds.x + ctx.style.control_padding * 1.5,
                bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0),
            },
            display,
            ctx.style.text_muted,
        )
        return false
    }
    control := gui_control(ctx, id, bounds, true)
    editing_text := ctx.text_edit_id == id
    ctx.wants_text_input =
        ctx.wants_text_input || (control.focused && (!ctx.controller_explicit_activation || editing_text))
    if ctx.controller_explicit_activation {
        _ = gui_update_focus_edit(ctx, id, control.focused)
    } else if !control.focused {
        gui_focus_edit_end(ctx, id)
    }
    integer_value := int(value^)
    gui_controller_edit_int(ctx, id, &integer_value)
    changed := u32(integer_value) != value^
    if changed do value^ = u32(integer_value)
    start_text :=
        control.focused && !editing_text && !ctx.controller_explicit_activation && gui_numeric_edit_wants_text(ctx)
    if start_text {
        gui_numeric_u32_text_begin(ctx, id, value^)
    }
    clamped := false
    if editing_text || start_text {
        if ctx.input.back {
            value^ = min(max(ctx.numeric_edit_snapshot_u32, min_value), max_value)
            ctx.text_edit_id = GUI_ID_NONE
            ctx.text_edit_len = 0
        } else if ctx.input.accept {
            ctx.text_edit_id = GUI_ID_NONE
            ctx.text_edit_len = 0
        } else {
            _ = gui_text_edit_process(ctx, id, ctx.text_edit_buffer[:], &ctx.text_edit_len, false)
            parsed: u64
            valid := ctx.text_edit_len > 0
            multiplier: u64 = 1
            for ch, index in ctx.text_edit_buffer[:ctx.text_edit_len] {
                if ch >= '0' && ch <= '9' {
                    if parsed > (~u64(0) - u64(ch - '0')) / 10 {
                        valid = false
                    } else {
                        parsed = parsed * 10 + u64(ch - '0')
                    }
                } else if index == ctx.text_edit_len - 1 {
                    switch ch {
                    case 'k', 'K':
                        multiplier = 1000
                    case 'm', 'M':
                        multiplier = 1_000_000
                    case 'g', 'G':
                        multiplier = 1_000_000_000
                    case:
                        valid = false
                    }
                } else {
                    valid = false
                }
            }
            if valid {
                requested := parsed * multiplier
                next := u32(min(max(requested, u64(min_value)), u64(max_value)))
                clamped = requested < u64(min_value) || requested > u64(max_value)
                changed = changed || next != value^
                value^ = next
            }
        }
    } else if ctx.focus_edit_id == id {
        nav_x, nav_y := gui_focused_nav_pressed(ctx, id)
        direction := int(nav_x - nav_y)
        scale := gui_numeric_precision_scale(ctx, id, true)
        step := u64(max(scale, f32(1))) * u64(max(step_value, u32(1)))
        if direction != 0 {
            before := value^
            if direction < 0 {
                value^ = u32(max(i64(value^) - i64(step), i64(min_value)))
            } else {
                value^ = u32(min(u64(value^) + step, u64(max_value)))
            }
            changed = changed || value^ != before
        }
    }
    value_editing := ctx.focus_edit_id == id || ctx.active == id
    if ctx.focus_edit_id != id {
        _ = gui_numeric_precision_scale(ctx, id, value_editing)
    }
    gui_numeric_pointer_track(ctx, id)
    if ctx.active == id && ctx.input.mouse_down && !editing_text {
        delta_steps := int(ctx.input.wheel_delta + ctx.mouse_delta.x * 0.1)
        if delta_steps != 0 {
            before := value^
            precision := i64(max(gui_numeric_precision_scale(ctx, id, value_editing), f32(1)))
            delta := i64(delta_steps) * i64(max(step_value, u32(1))) * precision
            value^ = u32(min(max(i64(value^) + delta, i64(min_value)), i64(max_value)))
            changed = changed || value^ != before
        }
    }
    pointer_direction := gui_numeric_pointer_step_direction(ctx, id, bounds)
    if pointer_direction != 0 {
        before := value^
        if pointer_direction < 0 {
            value^ = u32(max(i64(value^) - i64(max(step_value, u32(1))), i64(min_value)))
        } else {
            value^ = u32(min(u64(value^) + u64(max(step_value, u32(1))), u64(max_value)))
        }
        changed = changed || value^ != before
    }
    if !editing_text && gui_numeric_pointer_value_tapped(ctx, id, bounds) {
        gui_numeric_u32_text_begin(ctx, id, value^)
        editing_text = true
    }
    gui_text_field_chrome(ctx, bounds, ctx.active == id || ctx.focus_edit_id == id, ctx.hot == id, control.focused)
    if control.focused do gui_focus_ring(ctx, bounds)
    display := gui_numeric_u32_display(label, value^, unit, grouped)
    if editing_text || start_text {
        display = string(ctx.text_edit_buffer[:ctx.text_edit_len])
    }
    if clamped {
        display = fmt.tprintf("%s  (limited)", display)
    }
    display_color := clamped ? ctx.style.danger : ctx.style.text
    gui_numeric_draw_display(ctx, bounds, display, display_color, value_editing && !editing_text)
    if value_editing && !editing_text {
        effective_step := u64(max(step_value, u32(1))) * u64(max(gui_numeric_current_scale(ctx, id), f32(1)))
        gui_numeric_draw_step(ctx, bounds, fmt.tprintf("%d", effective_step))
    }
    gui_numeric_track(
        ctx,
        id,
        bounds,
        f32(value^),
        f32(min_value),
        f32(max_value),
        value_editing && !editing_text,
        false,
    )
    gui_numeric_context_hint(ctx, id, editing_text)
    return changed
}

gui_numeric_f32_keyed :: proc(
    ctx: ^Gui_Context,
    label, key: string,
    value: ^f32,
    speed, min_value, max_value: f32,
    enabled := true,
    mapping := Gui_Numeric_Mapping.Linear,
) -> bool {
    id := gui_make_id(ctx, key)
    bounds := gui_next_rect(ctx, height = gui_numeric_height(ctx, id))
    if !enabled {
        if ctx.focused == id {
            ctx.focused = GUI_ID_NONE
        }
        if ctx.active == id {
            ctx.active = GUI_ID_NONE
        }
        if ctx.text_edit_id == id {
            ctx.text_edit_id = GUI_ID_NONE
            ctx.text_edit_len = 0
            ctx.numeric_edit_snapshot_id = GUI_ID_NONE
        }
        gui_round_rect(ctx, bounds, ctx.style.radius_control, ctx.style.control_disabled)
        gui_round_stroke(ctx, bounds, ctx.style.radius_control, ctx.style.panel_border, ctx.style.border_width)
        gui_text_clipped(
            ctx,
            gui_inset(bounds, ctx.style.control_padding),
            {
                bounds.x + ctx.style.control_padding * 1.5,
                bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0),
            },
            label,
            ctx.style.text_muted,
        )
        return false
    }
    control := gui_control(ctx, id, bounds, true)
    changed := false
    editing := ctx.text_edit_id == id
    ctx.wants_text_input =
        ctx.wants_text_input ||
        (control.focused && (!ctx.controller_explicit_activation || ctx.focus_edit_id == id || editing))
    // Controllers engage numeric fields as value editors: the D-pad adjusts
    // the value, Accept commits, and Back restores the snapshot. Text editing
    // is reserved for keyboard input so Accept cannot strand a controller user
    // in a caret editor with no way to enter digits.
    start_edit :=
        control.focused && !editing && !ctx.controller_explicit_activation && gui_numeric_edit_wants_text(ctx)
    if ctx.controller_explicit_activation {
        _ = gui_update_focus_edit(ctx, id, control.focused)
    } else {
        if control.focused && !editing && ctx.input.key_space {
            gui_focus_edit_begin(ctx, id)
        } else if !control.focused {
            gui_focus_edit_end(ctx, id)
        }
    }
    gui_controller_edit_f32(ctx, id, value)
    value_editing := ctx.focus_edit_id == id || ctx.active == id
    adjust_scale := gui_numeric_precision_scale(ctx, id, value_editing) * gui_fine_adjust_scale(ctx)
    if ctx.input.key_ctrl || ctx.input.key_super do adjust_scale *= 10
    gui_numeric_pointer_track(ctx, id)
    pointer_direction := gui_numeric_pointer_step_direction(ctx, id, bounds)
    if pointer_direction != 0 {
        before := value^
        value^ = min(max(value^ + pointer_direction * speed * adjust_scale, min_value), max_value)
        changed = changed || value^ != before
    }
    if !editing && gui_numeric_pointer_value_tapped(ctx, id, bounds) {
        gui_numeric_edit_begin(ctx, id, value^)
        editing = true
    }

    if ctx.active == id && ctx.input.mouse_down && !editing {
        delta := (ctx.input.wheel_delta * speed + ctx.mouse_delta.x * speed * 0.1) * adjust_scale
        before := value^
        value^ += delta
        if value^ < min_value do value^ = min_value
        if value^ > max_value do value^ = max_value
        changed = changed || value^ != before
        if changed && ctx.text_edit_id == id {
            gui_numeric_edit_set_value(ctx, value^)
            ctx.text_edit_caret = ctx.text_edit_len
            ctx.text_edit_anchor = 0
        }
    }
    // Value edits advance on the navigation action's initial press and repeat,
    // not every frame an axis is held. This keeps an activated control's rate
    // stable across refresh rates and gives the user time to make fine edits.
    nav_x, nav_y := gui_focused_nav_pressed(ctx, id)
    if !editing && !start_edit && (nav_x != 0 || nav_y != 0) {
        before := value^
        value^ += (nav_x - nav_y) * speed * adjust_scale
        if value^ < min_value do value^ = min_value
        if value^ > max_value do value^ = max_value
        changed = changed || value^ != before
        if ctx.text_edit_id == id {
            gui_numeric_edit_set_value(ctx, value^)
            ctx.text_edit_caret = ctx.text_edit_len
            ctx.text_edit_anchor = 0
        }
    }
    if control.focused && (editing || start_edit) {
        if start_edit && ctx.input.accept {
            if !ctx.controller_explicit_activation {
                gui_focus_edit_end(ctx, id)
            }
            gui_numeric_edit_begin(ctx, id, value^)
        } else {
            if editing {
                text_pos := Vec2 {
                    bounds.x + ctx.style.control_padding * 1.5,
                    bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0),
                }
                gui_text_edit_handle_mouse(ctx, id, ctx.text_edit_buffer[:], ctx.text_edit_len, bounds, text_pos)
            }
            edit_changed := gui_numeric_edit_f32(ctx, id, value, min_value, max_value)
            changed = changed || edit_changed
        }
    } else if ctx.text_edit_id == id {
        ctx.text_edit_id = GUI_ID_NONE
        ctx.text_edit_len = 0
        ctx.numeric_edit_snapshot_id = GUI_ID_NONE
    }

    gui_text_field_chrome(ctx, bounds, ctx.active == id || ctx.focus_edit_id == id, ctx.hot == id, control.focused)
    if control.focused do gui_focus_ring(ctx, bounds)
    display_label := label
    if ctx.text_edit_id == id {
        display_label = string(ctx.text_edit_buffer[:ctx.text_edit_len])
    }
    if control.focused && ctx.text_edit_id == id {
        gui_text_edit_keep_caret_visible(
            ctx,
            ctx.text_edit_buffer[:],
            ctx.text_edit_len,
            gui_inset(bounds, ctx.style.control_padding * 2),
        )
        gui_text_edit_draw(
            ctx,
            bounds,
            {
                bounds.x + ctx.style.control_padding * 1.5,
                bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0),
            },
            ctx.text_edit_buffer[:],
            ctx.text_edit_len,
            label,
            true,
        )
    } else {
        gui_numeric_draw_display(ctx, bounds, display_label, ctx.style.text, value_editing)
    }
    if value_editing && !editing {
        gui_numeric_draw_step(ctx, bounds, fmt.tprintf("%g", speed * adjust_scale))
    }
    gui_numeric_track(ctx, id, bounds, value^, min_value, max_value, value_editing && !editing, false, mapping)
    gui_numeric_context_hint(ctx, id, editing)
    return changed
}

gui_slider_f32 :: gui_slider_f32_keyed

gui_slider_height :: proc(ctx: ^Gui_Context) -> f32 {
    return max(ctx.style.row_height, ctx.style.body_line_height + ctx.style.spacing_2 + ctx.style.control_padding * 2)
}

gui_slider_f32_keyed :: proc(ctx: ^Gui_Context, label, key: string, value: ^f32, min, max_value: f32) -> bool {
    id := gui_make_id(ctx, key)
    bounds := gui_next_rect(ctx, height = gui_slider_height(ctx))
    changed := false
    t := gui_clamp01((value^ - min) / max(max_value - min, 0.000001))
    label_h := ctx.style.body_line_height
    handle_radius := max(ctx.style.control_padding, f32(8))
    track_inset := max(handle_radius, ctx.style.spacing_2)
    track_h := max(ctx.style.border_width * 3, f32(6))
    track := Rect {
        bounds.x + track_inset,
        bounds.y + label_h + ctx.style.spacing_2,
        max(bounds.w - track_inset * 2, 1),
        track_h,
    }
    handle := Vec2{track.x + track.w * t, track.y + track.h * 0.5}

    editing := ctx.focus_edit_id == id || ctx.active == id
    precision_scale := gui_numeric_precision_scale(ctx, id, editing)
    nav_scale := precision_scale * gui_fine_adjust_scale(ctx)
    if ctx.input.key_ctrl || ctx.input.key_super {
        precision_scale *= 10
        nav_scale *= 10
    }
    if gui_drag_handle_region(ctx, id, bounds, handle, 12) {
        pointer_scale := gui_pointer_fine_adjust_scale(ctx, id) * precision_scale
        if pointer_scale < 1 {
            value^ += ctx.mouse_delta.x / max(track.w, 1) * (max_value - min) * pointer_scale
            if value^ < min do value^ = min
            if value^ > max_value do value^ = max_value
        } else {
            t = (ctx.input.mouse_pos.x - track.x) / max(track.w, 1)
            t = gui_clamp01(t)
            value^ = min + (max_value - min) * t
        }
        changed = true
    }
    _ = gui_update_focus_edit(ctx, id, ctx.focused == id)
    gui_controller_edit_f32(ctx, id, value)
    nav_x, nav_y := gui_focused_nav_pressed(ctx, id)
    if nav_x != 0 || nav_y != 0 {
        step := (max_value - min) * 0.05 * nav_scale
        value^ += (nav_x - nav_y) * step
        if value^ < min do value^ = min
        if value^ > max_value do value^ = max_value
        changed = true
    }

    t = gui_clamp01((value^ - min) / max(max_value - min, 0.000001))
    fill := track
    fill.w *= t
    handle = Vec2{track.x + track.w * t, track.y + track.h * 0.5}

    gui_text_clipped(
        ctx,
        {bounds.x, bounds.y, bounds.w, label_h},
        {bounds.x + ctx.style.spacing_1, bounds.y + max((label_h - ctx.style.body_text_height) * 0.5, 0)},
        label,
        ctx.style.text_muted,
    )
    gui_round_rect(ctx, track, track.h * 0.5, ctx.style.control)
    gui_round_rect(ctx, fill, track.h * 0.5, editing ? ctx.style.accent : gui_apply_opacity(ctx.style.accent, 0.72))
    gui_round_stroke(ctx, track, track.h * 0.5, ctx.style.panel_border, ctx.style.border_width)
    gui_draw_handle(ctx, handle, handle_radius)
    if editing {
        badge := fmt.tprintf("STEP %gx", gui_numeric_precision_scales[ctx.numeric_precision_index])
        badge_w := gui_text_width(ctx, badge) + ctx.style.spacing_2 * 2
        badge_bounds := Rect{bounds.x + bounds.w - badge_w, bounds.y, badge_w, label_h}
        gui_round_rect(ctx, badge_bounds, badge_bounds.h * 0.5, gui_apply_opacity(ctx.style.accent, 0.18))
        gui_text_centered(ctx, badge_bounds, badge, ctx.style.accent)
    }
    gui_focus_or_edit_ring(ctx, id, bounds)

    return changed
}

gui_text_input :: gui_text_input_keyed
