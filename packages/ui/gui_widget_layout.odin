package ui

import "core:math"
import "core:fmt"
import "core:strconv"

gui_collapsible_begin_keyed :: proc(ctx: ^Gui_Context, label, key: string, open: ^bool) -> bool {
	id := gui_make_id(ctx, key)
	bounds := gui_next_rect(ctx)
	control := gui_control(ctx, id, bounds, true)
	if (control.focused && (gui_accept_pressed(ctx) || ctx.input.key_space)) || (control.hovered && ctx.active == id && ctx.input.mouse_released) {
		open^ = !open^
	}
	gui_expander_chrome(ctx, bounds, label, id, open^, control.focused)
	return open^
}

gui_expander_chrome :: proc(ctx: ^Gui_Context, bounds: Rect, label: string, id: Gui_Id, open, focused: bool) {
	fill := Color{0, 0, 0, 0}
	border := ctx.style.panel_border
	label_color := ctx.style.text
	if open {
		fill = gui_apply_opacity(ctx.style.control, 0.72)
		border = gui_apply_opacity(ctx.style.accent, 0.45)
		label_color = ctx.style.text
	}
	if ctx.hot == id || focused {
		fill = ctx.style.control_hot
		border = gui_apply_opacity(ctx.style.text, 0.46)
	}
	if ctx.active == id {
		fill = ctx.style.control_active
		border = gui_apply_opacity(ctx.style.accent, 0.64)
	}
	if fill.a > 0 {
		gui_round_rect(ctx, bounds, ctx.style.radius_control, fill)
	}
	gui_round_stroke(ctx, bounds, ctx.style.radius_control, border, ctx.style.border_width)
	if open {
		gui_rect(ctx, {bounds.x + 3, bounds.y + 7, max(ctx.style.border_width * 2, 2), max(bounds.h - 14, 1)}, ctx.style.accent)
	}
	t := open ? f32(1) : f32(0)
	if ctx.input.delta_time > 0 {
		t = gui_animate_value(ctx, gui_id_child(id, "expander-open"), t, 16)
	}
	icon_center := Vec2{bounds.x + ctx.style.control_padding * 2.1, bounds.y + bounds.h * 0.5}
	icon_color := (ctx.hot == id || focused || open) ? ctx.style.accent : ctx.style.text_muted
	gui_expander_chevron(ctx, icon_center, max(bounds.h * 0.16, 5), t, icon_color)
	text_x := bounds.x + ctx.style.control_padding * 4
	text_rect := gui_inset_edges(bounds, {left = ctx.style.control_padding * 4, top = 0, right = ctx.style.control_padding, bottom = 0})
	gui_text_clipped(ctx, text_rect, {text_x, bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0)}, label, label_color)
	if focused {
		gui_focus_ring(ctx, bounds)
	}
}

gui_expander_chevron :: proc(ctx: ^Gui_Context, center: Vec2, size, t: f32, color: Color) {
	x := gui_clamp01(t)
	closed_a := Vec2{center.x - size * 0.35, center.y - size}
	closed_b := Vec2{center.x + size * 0.45, center.y}
	closed_c := Vec2{center.x - size * 0.35, center.y + size}
	open_a := Vec2{center.x - size, center.y - size * 0.35}
	open_b := Vec2{center.x, center.y + size * 0.45}
	open_c := Vec2{center.x + size, center.y - size * 0.35}
	a := gui_lerp_vec2(closed_a, open_a, x)
	b := gui_lerp_vec2(closed_b, open_b, x)
	c := gui_lerp_vec2(closed_c, open_c, x)
	gui_line(ctx, a, b, color, ctx.style.border_width * 2)
	gui_line(ctx, b, c, color, ctx.style.border_width * 2)
}

gui_scissor_begin :: proc(ctx: ^Gui_Context, rect: Rect) {
	append(&ctx.commands, Draw_Command{kind = .Scissor_Begin, rect = rect})
}

gui_scissor_end :: proc(ctx: ^Gui_Context) {
	append(&ctx.commands, Draw_Command{kind = .Scissor_End})
}

gui_input_clip_begin :: proc(ctx: ^Gui_Context, rect: Rect) {
	if ctx.input_clip_depth >= MAX_GUI_CLIP_DEPTH {
		return
	}
	clip := rect
	if ctx.input_clip_depth > 0 {
		clip = gui_rect_intersection(ctx.input_clip_stack[ctx.input_clip_depth - 1], rect)
	}
	ctx.input_clip_stack[ctx.input_clip_depth] = clip
	ctx.input_clip_depth += 1
}

gui_input_clip_end :: proc(ctx: ^Gui_Context) {
	if ctx.input_clip_depth > 0 {
		ctx.input_clip_depth -= 1
	}
}

gui_overlay_input_rect :: proc(ctx: ^Gui_Context, rect: Rect) {
	if rect.w <= 0 || rect.h <= 0 || ctx.next_overlay_input_rect_count >= MAX_GUI_OVERLAY_INPUT_RECTS {
		return
	}
	ctx.next_overlay_input_rects[ctx.next_overlay_input_rect_count] = rect
	ctx.next_overlay_input_rect_count += 1
}

gui_overlay_input_begin :: proc(ctx: ^Gui_Context, rect: Rect) {
	gui_overlay_input_rect(ctx, rect)
	ctx.overlay_input_depth += 1
}

gui_overlay_input_end :: proc(ctx: ^Gui_Context) {
	if ctx.overlay_input_depth > 0 {
		ctx.overlay_input_depth -= 1
	}
}

gui_overlay_input_cancel :: proc(ctx: ^Gui_Context) {
	gui_overlay_input_end(ctx)
	if ctx.next_overlay_input_rect_count > 0 {
		ctx.next_overlay_input_rect_count -= 1
	}
}

gui_scrollbar :: proc(ctx: ^Gui_Context, viewport: Rect, content_height, scroll: f32) {
	if content_height <= viewport.h || viewport.h <= 0 {
		return
	}
	track_w := ctx.style.scrollbar_width
	track_margin := ctx.style.border_width * 2
	track := Rect{viewport.x + viewport.w - track_w - track_margin, viewport.y + track_margin, track_w, max(viewport.h - track_margin * 2, 0)}
	if track.h <= 0 {
		return
	}
	thumb_h := max(track.h * (viewport.h / max(content_height, 1)), ctx.style.rhythm * 0.5)
	thumb_h = min(thumb_h, track.h)
	max_scroll := max(content_height - viewport.h, 1)
	thumb_range := max(track.h - thumb_h, 0)
	thumb_y := track.y + thumb_range * gui_clamp01(scroll / max_scroll)
	thumb := Rect{track.x, thumb_y, track.w, thumb_h}
	gui_round_rect(ctx, track, track.w * 0.5, gui_apply_opacity(ctx.style.control, 0.55))
	gui_round_rect(ctx, thumb, thumb.w * 0.5, gui_apply_opacity(ctx.style.text_muted, 0.70))
}

gui_scrollbar_reserved_width :: proc(ctx: ^Gui_Context) -> f32 {
	return ctx.style.scrollbar_width + ctx.style.scrollbar_gutter + ctx.style.border_width * 2
}

gui_scrollbar_content_width :: proc(ctx: ^Gui_Context, viewport: Rect, content_height: f32) -> f32 {
	if content_height <= viewport.h || viewport.h <= 0 {
		return viewport.w
	}
	return max(viewport.w - gui_scrollbar_reserved_width(ctx), 0)
}

gui_next_row :: proc(ctx: ^Gui_Context, width := f32(-1), height := f32(-1)) -> Rect {
	w := width
	h := height
	if w <= 0 {
		w = ctx.content_width
	}
	if h <= 0 {
		h = ctx.style.row_height
	}
	bounds := Rect {
		x = ctx.next_cursor.x,
		y = ctx.next_cursor.y,
		w = w,
		h = h,
	}
	ctx.next_cursor.y += h + ctx.style.spacing
	return bounds
}
