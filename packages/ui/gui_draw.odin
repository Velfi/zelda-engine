package ui

import "core:math"
import "core:fmt"
import "core:time"

gui_rect :: proc(ctx: ^Gui_Context, rect: Rect, color: Color) {
	append(&ctx.commands, Draw_Command{kind = .Filled_Rect, rect = rect, color = color})
}

gui_rect_blend :: proc(ctx: ^Gui_Context, rect: Rect, color: Color, blend: Gui_Blend_Mode) {
	append(&ctx.commands, Draw_Command{kind = .Filled_Rect, rect = rect, color = color, blend = blend})
}

gui_stroke :: proc(ctx: ^Gui_Context, rect: Rect, color: Color) {
	append(&ctx.commands, Draw_Command{kind = .Stroked_Rect, rect = rect, color = color, stroke_width = ctx.style.border_width})
}

gui_round_rect :: proc(ctx: ^Gui_Context, rect: Rect, radius: f32, color: Color) {
	append(&ctx.commands, Draw_Command{kind = .Filled_Rounded_Rect, rect = rect, color = color, radius = radius})
}

gui_round_stroke :: proc(ctx: ^Gui_Context, rect: Rect, radius: f32, color: Color, width: f32) {
	append(&ctx.commands, Draw_Command{kind = .Stroked_Rounded_Rect, rect = rect, color = color, radius = radius, stroke_width = width})
}

gui_gradient_rect :: proc(ctx: ^Gui_Context, rect: Rect, top, bottom: Color) {
	append(&ctx.commands, Draw_Command{kind = .Gradient_Rect, rect = rect, color = top, color_2 = bottom})
}

gui_horizontal_gradient_rect :: proc(ctx: ^Gui_Context, rect: Rect, left, right: Color) {
	append(&ctx.commands, Draw_Command{kind = .Horizontal_Gradient_Rect, rect = rect, color = left, color_2 = right})
}

gui_gradient_round_rect :: proc(ctx: ^Gui_Context, rect: Rect, radius: f32, top, bottom: Color) {
	append(&ctx.commands, Draw_Command{kind = .Gradient_Rect, rect = rect, color = top, color_2 = bottom, radius = radius})
}

gui_shader_rect :: proc(ctx: ^Gui_Context, rect: Rect, kind: Gui_Shader_Kind, params: Color, tint: Color) {
	append(&ctx.commands, Draw_Command{kind = .Shader_Rect, rect = rect, color = tint, shader_kind = kind, shader_params = params})
}

gui_quad :: proc(ctx: ^Gui_Context, p0, p1, p2, p3: Vec2, color: Color) {
	append(&ctx.commands, Draw_Command{kind = .Filled_Quad, p0 = p0, p1 = p1, p2 = p2, p3 = p3, color = color})
}

gui_rotated_rect :: proc(ctx: ^Gui_Context, rect: Rect, angle_radians: f32, color: Color) {
	center := Vec2{rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
	p0 := gui_rotate_point({rect.x, rect.y}, center, angle_radians)
	p1 := gui_rotate_point({rect.x + rect.w, rect.y}, center, angle_radians)
	p2 := gui_rotate_point({rect.x + rect.w, rect.y + rect.h}, center, angle_radians)
	p3 := gui_rotate_point({rect.x, rect.y + rect.h}, center, angle_radians)
	gui_quad(ctx, p0, p1, p2, p3, color)
}

gui_line :: proc(ctx: ^Gui_Context, p0, p1: Vec2, color: Color, width: f32) {
	append(&ctx.commands, Draw_Command{kind = .Line, p0 = p0, p1 = p1, color = color, stroke_width = max(width, 1)})
}

gui_ellipse :: proc(ctx: ^Gui_Context, rect: Rect, color: Color) {
	append(&ctx.commands, Draw_Command{kind = .Filled_Ellipse, rect = rect, color = color})
}

gui_ellipse_stroke :: proc(ctx: ^Gui_Context, rect: Rect, color: Color, width: f32) {
	append(&ctx.commands, Draw_Command{kind = .Stroked_Ellipse, rect = rect, color = color, stroke_width = max(width, 1)})
}

gui_image :: proc(ctx: ^Gui_Context, rect: Rect, image_id: Gui_Image_Id, tint: Color) {
	gui_image_filtered(ctx, rect, image_id, tint, {brightness = 1, contrast = 1})
}

gui_image_uv :: proc(ctx: ^Gui_Context, rect: Rect, image_id: Gui_Image_Id, tint: Color, uv: Rect) {
	gui_image_uv_filtered(ctx, rect, image_id, tint, uv, {brightness = 1, contrast = 1})
}

gui_image_filtered :: proc(ctx: ^Gui_Context, rect: Rect, image_id: Gui_Image_Id, tint: Color, filter: Gui_Image_Filter) {
	gui_image_uv_filtered(ctx, rect, image_id, tint, {0, 0, 1, 1}, filter)
}

gui_image_uv_filtered :: proc(ctx: ^Gui_Context, rect: Rect, image_id: Gui_Image_Id, tint: Color, uv: Rect, filter: Gui_Image_Filter) {
	gui_image_uv_filtered_blend(ctx, rect, image_id, tint, uv, filter, .Alpha)
}

gui_image_uv_filtered_blend :: proc(ctx: ^Gui_Context, rect: Rect, image_id: Gui_Image_Id, tint: Color, uv: Rect, filter: Gui_Image_Filter, blend: Gui_Blend_Mode) {
	normalized := filter
	if normalized.brightness == 0 {
		normalized.brightness = 1
	}
	if normalized.contrast == 0 {
		normalized.contrast = 1
	}
	append(&ctx.commands, Draw_Command{kind = .Image, rect = rect, rect_2 = uv, color = tint, image_id = image_id, image_filter = normalized, blend = blend})
}

gui_backdrop_blur_rect :: proc(ctx: ^Gui_Context, rect: Rect, tint: Color, blur: f32) {
	filter := Gui_Image_Filter{brightness = 1.04, contrast = 0.96, grayscale = 0, blur = blur}
	append(&ctx.commands, Draw_Command{kind = .Backdrop_Blur_Rect, rect = rect, color = tint, image_filter = filter})
}

gui_default_glass_style :: proc(ctx: ^Gui_Context, radius: f32) -> Gui_Glass_Style {
	r := radius
	if r <= 0 {
		r = ctx.style.radius_panel
	}
	return {
		// Keep bright simulations from washing out white controls and labels.
		tint = {0.07, 0.09, 0.11, 0.68},
		radius = r,
		thickness = max(ctx.style.rhythm * 0.18, f32(7)),
		roughness = 0.50,
		bevel = max(ctx.style.border_width * 5, f32(5)),
		ior = 1.46,
		dispersion = 0.90,
		border = 0.32,
		highlight = 0.36,
	}
}

gui_refractive_glass_rect :: proc(ctx: ^Gui_Context, rect: Rect, style: Gui_Glass_Style) {
	if rect.w <= 0 || rect.h <= 0 {
		return
	}
	glass := style
	if glass.radius < 0 {
		glass.radius = 0
	}
	if glass.thickness <= 0 {
		glass.thickness = max(ctx.style.rhythm * 0.18, f32(7))
	}
	if glass.bevel <= 0 {
		glass.bevel = max(ctx.style.border_width * 5, f32(5))
	}
	if glass.ior <= 0 {
		glass.ior = 1.46
	}
	if glass.dispersion < 0 {
		glass.dispersion = 0
	}
	glass.roughness = gui_clamp01(glass.roughness)
	glass.border = gui_clamp01(glass.border)
	glass.highlight = gui_clamp01(glass.highlight)
	append(&ctx.commands, Draw_Command{kind = .Refractive_Glass_Rect, rect = rect, color = glass.tint, glass_style = glass})
}

gui_focus_ring :: proc(ctx: ^Gui_Context, rect: Rect) {
	outer := gui_inset(rect, -ctx.style.focus_ring_width)
	gui_round_stroke(ctx, outer, ctx.style.radius_control + ctx.style.focus_ring_width, gui_apply_opacity(ctx.style.accent, 0.86), ctx.style.focus_ring_width)
}

// Focus is an outer ring: the control is a navigation destination. Activation
// adds a strong inner ring: directional or text input is currently captured by
// this control, and Accept/Back will commit/cancel that editing session.
gui_focus_or_edit_ring :: proc(ctx: ^Gui_Context, id: Gui_Id, rect: Rect) {
	if ctx.focused != id {
		return
	}
	gui_focus_ring(ctx, rect)
	if ctx.focus_edit_id == id || ctx.active == id {
		inner_width := max(ctx.style.border_width * 2, f32(2))
		inner := gui_inset(rect, inner_width * 0.75)
		gui_round_stroke(ctx, inner, max(ctx.style.radius_control - inner_width * 0.5, 0), ctx.style.accent, inner_width)
	}
}

gui_box :: proc(ctx: ^Gui_Context, rect: Rect, style: Gui_Box_Style) {
	opacity := style.opacity
	if opacity <= 0 {
		opacity = 1
	}
	if style.shadow_blur > 0 && style.shadow_color.a > 0 {
		gui_shadow(ctx, rect, style.radius, style.shadow_offset, style.shadow_blur, gui_apply_opacity(style.shadow_color, opacity))
	}
	if style.gradient {
		append(&ctx.commands, Draw_Command{kind = .Gradient_Rect, rect = rect, color = gui_apply_opacity(style.fill, opacity), color_2 = gui_apply_opacity(style.fill_to, opacity), radius = style.radius, blend = style.blend})
	} else if style.fill.a > 0 {
		append(&ctx.commands, Draw_Command{kind = .Filled_Rounded_Rect, rect = rect, color = gui_apply_opacity(style.fill, opacity), radius = style.radius, blend = style.blend})
	}
	if style.border_width > 0 && style.border.a > 0 {
		gui_round_stroke(ctx, rect, style.radius, gui_apply_opacity(style.border, opacity), style.border_width)
	}
}

gui_shadow :: proc(ctx: ^Gui_Context, rect: Rect, radius: f32, offset: Vec2, blur: f32, color: Color) {
	if blur <= 0 || color.a <= 0 {
		return
	}
	steps := 5
	for i in 0 ..< steps {
		t := f32(i + 1) / f32(steps)
		spread := blur * t
		alpha := color.a * (1 - t) * 0.42
		shadow_rect := Rect{rect.x + offset.x - spread, rect.y + offset.y - spread, rect.w + spread * 2, rect.h + spread * 2}
		gui_round_rect(ctx, shadow_rect, radius + spread, Color{color.r, color.g, color.b, alpha})
	}
}

gui_apply_opacity :: proc(color: Color, opacity: f32) -> Color {
	return {color.r, color.g, color.b, color.a * gui_clamp01(opacity)}
}

gui_lighten :: proc(color: Color, amount: f32) -> Color {
	t := gui_clamp01(amount)
	return {
		color.r + (1 - color.r) * t,
		color.g + (1 - color.g) * t,
		color.b + (1 - color.b) * t,
		color.a,
	}
}

gui_darken :: proc(color: Color, amount: f32) -> Color {
	t := 1 - gui_clamp01(amount)
	return {color.r * t, color.g * t, color.b * t, color.a}
}

gui_lerp_f32 :: proc(a, b, t: f32) -> f32 {
	x := gui_clamp01(t)
	return a + (b - a) * x
}

gui_lerp_color :: proc(a, b: Color, t: f32) -> Color {
	x := gui_clamp01(t)
	return {
		gui_lerp_f32(a.r, b.r, x),
		gui_lerp_f32(a.g, b.g, x),
		gui_lerp_f32(a.b, b.b, x),
		gui_lerp_f32(a.a, b.a, x),
	}
}

gui_lerp_vec2 :: proc(a, b: Vec2, t: f32) -> Vec2 {
	x := gui_clamp01(t)
	return {
		gui_lerp_f32(a.x, b.x, x),
		gui_lerp_f32(a.y, b.y, x),
	}
}

gui_animate_towards :: proc(current, target, speed, delta_time: f32) -> f32 {
	if speed <= 0 {
		return target
	}
	t := 1 - gui_pow_approx(0.5, speed * max(delta_time, 0))
	return gui_lerp_f32(current, target, t)
}

gui_animate_value :: proc(ctx: ^Gui_Context, id: Gui_Id, target, speed: f32) -> f32 {
	slot := gui_animation_slot(ctx, id)
	if slot == nil {
		return target
	}
	if slot.last_frame == 0 {
		slot.value = target
	} else {
		slot.value = gui_animate_towards(slot.value, target, speed, ctx.input.delta_time)
	}
	slot.last_frame = ctx.frame_index
	return slot.value
}

gui_animation_slot :: proc(ctx: ^Gui_Context, id: Gui_Id) -> ^Gui_Animation_Slot {
	free_index := -1
	oldest_index := 0
	oldest_frame := ctx.animation_slots[0].last_frame
	for i in 0 ..< len(ctx.animation_slots) {
		slot := &ctx.animation_slots[i]
		if slot.id == id {
			return slot
		}
		if slot.id == GUI_ID_NONE && free_index < 0 {
			free_index = i
		}
		if slot.last_frame < oldest_frame {
			oldest_frame = slot.last_frame
			oldest_index = i
		}
	}
	index := free_index
	if index < 0 {
		index = oldest_index
	}
	ctx.animation_slots[index] = {id = id, value = 0, last_frame = 0}
	return &ctx.animation_slots[index]
}

gui_pow_approx :: proc(base, exponent: f32) -> f32 {
	if exponent <= 0 {
		return 1
	}
	result := f32(1)
	steps := int(min(max(exponent * 8, 1), 64))
	step_base := 1 + (base - 1) / f32(steps)
	for _ in 0 ..< steps {
		result *= step_base
	}
	return result
}

gui_text :: proc(ctx: ^Gui_Context, pos: Vec2, text: string, color: Color) {
	gui_text_font(ctx, pos, text, color, .Body, ctx.style.text_scale)
}

gui_text_font :: proc(ctx: ^Gui_Context, pos: Vec2, text: string, color: Color, font_kind: Gui_Font_Kind, text_scale: f32) {
	append(&ctx.commands, Draw_Command{
		kind = .Text,
		rect = {pos.x, pos.y, 0, 0},
		color = color,
		text = text,
		text_scale = text_scale,
		text_align = .Left,
		font_kind = font_kind,
	})
}

gui_text_wrapped_at :: proc(ctx: ^Gui_Context, pos: Vec2, text: string, max_width: f32, color: Color) {
	if max_width <= 0 {
		gui_text(ctx, pos, text, color)
		return
	}
	lines := make([dynamic]Gui_Text_Line, 0, 16)
	defer delete(lines)
	gui_text_wrap_lines(ctx, text, max_width, &lines)

	y := pos.y
	for line in lines {
		if line.end > line.start {
			gui_text(ctx, {pos.x, y}, text[line.start:line.end], color)
		}
		y += ctx.style.body_line_height
	}
}

gui_text_aligned :: proc(ctx: ^Gui_Context, rect: Rect, text: string, color: Color, align: Text_Align) {
	gui_text_aligned_font(ctx, rect, text, color, align, .Body, ctx.style.text_scale)
}

gui_text_aligned_font :: proc(ctx: ^Gui_Context, rect: Rect, text: string, color: Color, align: Text_Align, font_kind: Gui_Font_Kind, text_scale: f32) {
	append(&ctx.commands, Draw_Command{
		kind = .Text,
		rect = rect,
		color = color,
		text = text,
		text_scale = text_scale,
		text_align = align,
		font_kind = font_kind,
	})
}

gui_text_aligned_scaled :: proc(ctx: ^Gui_Context, rect: Rect, text: string, color: Color, align: Text_Align, scale: f32) {
	append(&ctx.commands, Draw_Command{
		kind = .Text,
		rect = rect,
		color = color,
		text = text,
		text_scale = max(ctx.style.text_scale * scale, 0.5),
		text_align = align,
		font_kind = scale >= 1.45 ? Gui_Font_Kind.Display : Gui_Font_Kind.Body,
	})
}

gui_text_clipped :: proc(ctx: ^Gui_Context, rect: Rect, pos: Vec2, text: string, color: Color) {
	gui_scissor_begin(ctx, rect)
	gui_text(ctx, pos, text, color)
	gui_scissor_end(ctx)
}

gui_text_centered :: proc(ctx: ^Gui_Context, rect: Rect, text: string, color: Color) {
	gui_text_aligned(ctx, rect, text, color, .Center)
}

gui_text_right :: proc(ctx: ^Gui_Context, rect: Rect, text: string, color: Color) {
	gui_text_aligned(ctx, rect, text, color, .Right)
}

gui_tooltip_place :: proc(ctx: ^Gui_Context, bounds: Rect, text: string, from_hover: bool) {
	if len(text) == 0 {
		return
	}
	padding := f32(8)
	viewport_w := ctx.input.window_width > 0 ? f32(ctx.input.window_width) : f32(1280)
	// Keep tooltips wide enough for a useful number of characters when text is
	// enlarged. A fixed pixel cap made accessibility-sized help text grow taller
	// than short windows and get cut off.
	readable_w := ctx.style.body_char_width * 34 + padding * 2
	max_w := min(max(viewport_w * 0.5, f32(240)), max(f32(420), readable_w))
	w := min(gui_text_width(ctx, text) + padding * 2, max_w)
	w = max(w, min(f32(220), max_w))
	wrap_w := max(w - padding * 2, ctx.style.body_char_width)
	lines := gui_wrap_line_count(ctx, text, wrap_w)
	h := f32(lines) * ctx.style.body_line_height + padding * 2
	x := bounds.x + bounds.w + ctx.style.spacing_1
	y := bounds.y
	if from_hover {
		x = ctx.input.mouse_pos.x + 14
		y = ctx.input.mouse_pos.y + 18
	} else if ctx.input.window_width > 0 && x + w > f32(ctx.input.window_width) - ctx.style.spacing_1 {
		x = bounds.x - w - ctx.style.spacing_1
	}
	ctx.tooltip_visible = true
	ctx.tooltip_from_hover = from_hover
	ctx.tooltip_rect = gui_overlay_nudge_into_view(ctx, {x, y, w, h})
	ctx.tooltip_text = text
	ctx.tooltip_numeric_controls = false
	ctx.tooltip_numeric_text_editing = false
}

gui_tooltip :: proc(ctx: ^Gui_Context, bounds: Rect, text: string) {
	if len(text) == 0 || !gui_mouse_contains(ctx, bounds) {
		return
	}
	gui_tooltip_place(ctx, bounds, text, true)
}

// Contextual help follows both pointer hover and keyboard/controller focus.
// Pointer help wins when a focused control and a hovered control differ.
gui_tooltip_for_id :: proc(ctx: ^Gui_Context, id: Gui_Id, text: string) {
	if len(text) == 0 || (ctx.hot != id && ctx.focused != id) {
		return
	}
	item, ok := gui_find_spatial_item(ctx, id)
	if !ok || !item.visible {
		return
	}
	if ctx.hot == id {
		gui_tooltip_place(ctx, item.bounds, text, true)
	} else if !ctx.tooltip_visible || !ctx.tooltip_from_hover {
		gui_tooltip_place(ctx, item.bounds, text, false)
	}
}

gui_numeric_tooltip_for_id :: proc(ctx: ^Gui_Context, id: Gui_Id, text: string, text_editing: bool) {
	gui_tooltip_for_id(ctx, id, text)
	if ctx.tooltip_visible && ctx.tooltip_text == text {
		ctx.tooltip_numeric_controls = true
		ctx.tooltip_numeric_text_editing = text_editing
		item, ok := gui_find_spatial_item(ctx, id)
		if ok && item.visible {
			gap := ctx.style.spacing_1
			rect := ctx.tooltip_rect
			// Numeric help is a persistent control legend, not a small hover label.
			// Anchor it to the field so pointer movement cannot leave it covering
			// the field or unrelated rows. Prefer above, then below when needed.
			rect.x = item.bounds.x
			rect.y = item.bounds.y - rect.h - gap
			if rect.y < gap {
				rect.y = item.bounds.y + item.bounds.h + gap
			}
			ctx.tooltip_rect = gui_overlay_nudge_into_view(ctx, rect)
		}
	}
}

gui_hint_keycap :: proc(ctx: ^Gui_Context, x: ^f32, y, h: f32, label: string) {
	w := gui_text_width(ctx, label) + ctx.style.spacing_2
	rect := Rect{x^, y, w, h}
	gui_round_rect(ctx, rect, ctx.style.radius_control * 0.55, gui_apply_opacity(ctx.style.control_hot, 0.75))
	gui_round_stroke(ctx, rect, ctx.style.radius_control * 0.55, ctx.style.panel_border, ctx.style.border_width)
	gui_text_centered(ctx, rect, label, ctx.style.text)
	x^ += w + ctx.style.spacing_1
}

gui_hint_label :: proc(ctx: ^Gui_Context, x: ^f32, y, h: f32, label: string, gap := true) {
	w := gui_text_width(ctx, label)
	gui_text_clipped(ctx, {x^, y, w, h}, {x^, y + max((h - ctx.style.body_text_height) * 0.5, 0)}, label, ctx.style.text_muted)
	x^ += w + (gap ? ctx.style.spacing_2 : 0)
}

gui_numeric_tooltip_controller_icon :: proc(ctx: ^Gui_Context, x: ^f32, y, size: f32, slot: int) {
	count := f32(UI_KENNEY_INPUT_ICON_COUNT)
	index := int(ctx.input.controller_prompt_style) * UI_KENNEY_INPUT_ICONS_PER_STYLE + slot
	gui_image_uv_filtered(ctx, {x^, y, size, size}, Gui_Image_Id(UI_KENNEY_INPUT_ATLAS_TEXTURE_ID), ctx.style.text, {f32(index) / count, 0, 1 / count, 1}, {brightness = 1, contrast = 1})
	x^ += size + ctx.style.spacing_1
}

gui_draw_numeric_tooltip_controls :: proc(ctx: ^Gui_Context, content: Rect) {
	line_h := max(ctx.style.body_line_height, f32(18))
	y := content.y
	if ctx.tooltip_numeric_text_editing {
		x := content.x
		gui_hint_keycap(ctx, &x, y, line_h, "Enter")
		gui_hint_label(ctx, &x, y, line_h, "Commit")
		gui_hint_keycap(ctx, &x, y, line_h, "Esc")
		gui_hint_label(ctx, &x, y, line_h, "Cancel", false)
		return
	}
	if ctx.input.active_device == .Controller {
		// Atlas slots: D-pad, shoulders, South, East, left stick.
		x := content.x
		gui_numeric_tooltip_controller_icon(ctx, &x, y, line_h, 0)
		gui_hint_label(ctx, &x, y, line_h, "Adjust")
		secondary_slot := ctx.input.controller_south_is_accept ? 4 : 3
		gui_numeric_tooltip_controller_icon(ctx, &x, y, line_h, secondary_slot)
		gui_hint_label(ctx, &x, y, line_h, "Cycle step", false)
		y += line_h + ctx.style.spacing_1
		x = content.x
		gui_numeric_tooltip_controller_icon(ctx, &x, y, line_h, 5)
		gui_hint_label(ctx, &x, y, line_h, "Fine")
		accept_slot := ctx.input.controller_south_is_accept ? 3 : 4
		gui_numeric_tooltip_controller_icon(ctx, &x, y, line_h, accept_slot)
		gui_hint_label(ctx, &x, y, line_h, "Commit")
		gui_hint_label(ctx, &x, y, line_h, "0.01x  0.1x  1x  10x  100x", false)
		return
	}
	x := content.x
	gui_hint_keycap(ctx, &x, y, line_h, "-/+")
	gui_hint_label(ctx, &x, y, line_h, "Adjust")
	gui_hint_keycap(ctx, &x, y, line_h, "Drag")
	gui_hint_label(ctx, &x, y, line_h, "Adjust")
	gui_hint_keycap(ctx, &x, y, line_h, "RMB")
	gui_hint_label(ctx, &x, y, line_h, "Cycle step", false)
	y += line_h + ctx.style.spacing_1
	x = content.x
	gui_hint_keycap(ctx, &x, y, line_h, "Shift")
	gui_hint_label(ctx, &x, y, line_h, "Fine")
	gui_hint_keycap(ctx, &x, y, line_h, "Ctrl/Cmd")
	gui_hint_label(ctx, &x, y, line_h, "10x")
	gui_hint_label(ctx, &x, y, line_h, "0.01x  0.1x  1x  10x  100x", false)
}

gui_draw_tooltip_overlay :: proc(ctx: ^Gui_Context) {
	if !ctx.tooltip_visible {
		return
	}
	rect := ctx.tooltip_rect
	gui_shadow(ctx, rect, ctx.style.radius_control, {0, 4}, 12, ctx.style.shadow_color)
	gui_round_rect(ctx, rect, ctx.style.radius_control, {0.02, 0.025, 0.035, 0.96})
	gui_round_stroke(ctx, rect, ctx.style.radius_control, ctx.style.panel_border, ctx.style.border_width)
	content := gui_inset(rect, 8)
	gui_scissor_begin(ctx, content)
	if ctx.tooltip_numeric_controls {
		gui_draw_numeric_tooltip_controls(ctx, content)
	} else {
		gui_text_wrapped_at(ctx, {content.x, content.y}, ctx.tooltip_text, content.w, ctx.style.text)
	}
	gui_scissor_end(ctx)
}

gui_notice :: proc(ctx: ^Gui_Context, text: string, seconds := f32(3.2)) {
	bytes := transmute([]u8)text
	ctx.notice_text_len = min(len(bytes), len(ctx.notice_text))
	copy(ctx.notice_text[:ctx.notice_text_len], bytes[:ctx.notice_text_len])
	ctx.notice_seconds = max(seconds, 0)
}

gui_draw_notice_overlay :: proc(ctx: ^Gui_Context) {
	if ctx.notice_text_len <= 0 || ctx.notice_seconds <= 0 || ctx.input.window_width <= 0 || ctx.input.window_height <= 0 {
		return
	}
	text := string(ctx.notice_text[:ctx.notice_text_len])
	padding := f32(10)
	max_w := min(max(f32(ctx.input.window_width) * 0.48, f32(280)), f32(560))
	w := min(gui_text_width(ctx, text) + padding * 2, max_w)
	w = max(w, min(f32(260), max_w))
	wrap_w := max(w - padding * 2, ctx.style.body_char_width)
	lines := gui_wrap_line_count(ctx, text, wrap_w)
	h := f32(lines) * ctx.style.body_line_height + padding * 2
	rect := Rect{
		(f32(ctx.input.window_width) - w) * 0.5,
		max(ctx.style.row_height + ctx.style.spacing_3 * 2, f32(72)),
		w,
		h,
	}
	alpha := min(max(ctx.notice_seconds / 0.24, 0), 1)
	gui_shadow(ctx, rect, ctx.style.radius_control, {0, 4}, 14, gui_apply_opacity(ctx.style.shadow_color, alpha))
	gui_round_rect(ctx, rect, ctx.style.radius_control, {0.025, 0.032, 0.045, 0.96 * alpha})
	gui_round_stroke(ctx, rect, ctx.style.radius_control, gui_apply_opacity(ctx.style.accent, 0.72 * alpha), max(ctx.style.border_width, f32(1)))
	content := gui_inset(rect, padding)
	// Wrapped notice text already stays inside the content width. Avoid clipping it
	// to the metric line box because font descenders can extend a pixel below it.
	gui_text_wrapped_at(ctx, {content.x, content.y}, text, content.w, gui_apply_opacity(ctx.style.text, alpha))
}

gui_contains :: proc(rect: Rect, p: Vec2) -> bool {
	return p.x >= rect.x &&
	       p.y >= rect.y &&
	       p.x < rect.x + rect.w &&
	       p.y < rect.y + rect.h
}

gui_contains_circle :: proc(center, p: Vec2, radius: f32) -> bool {
	dx := p.x - center.x
	dy := p.y - center.y
	return dx * dx + dy * dy <= radius * radius
}

gui_rect_intersection :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}

gui_overlay_nudge_into_view :: proc(ctx: ^Gui_Context, rect: Rect) -> Rect {
	if ctx.input.window_width <= 0 || ctx.input.window_height <= 0 {
		return rect
	}
	margin := ctx.style.spacing_1
	viewport := Rect{margin, margin, max(f32(ctx.input.window_width) - margin * 2, 0), max(f32(ctx.input.window_height) - margin * 2, 0)}
	if viewport.w <= 0 || viewport.h <= 0 {
		return rect
	}

	out := rect
	if out.w > viewport.w {
		out.w = viewport.w
	}
	if out.h > viewport.h {
		out.h = viewport.h
	}
	if out.x + out.w > viewport.x + viewport.w {
		out.x = viewport.x + viewport.w - out.w
	}
	if out.y + out.h > viewport.y + viewport.h {
		out.y = viewport.y + viewport.h - out.h
	}
	if out.x < viewport.x {
		out.x = viewport.x
	}
	if out.y < viewport.y {
		out.y = viewport.y
	}
	return out
}

gui_mouse_in_input_clip :: proc(ctx: ^Gui_Context) -> bool {
	if !gui_pointer_enabled(ctx) {
		return false
	}
	if gui_mouse_occluded_by_overlay(ctx) {
		return false
	}
	if ctx.input_clip_depth == 0 {
		return true
	}
	return gui_contains(ctx.input_clip_stack[ctx.input_clip_depth - 1], ctx.input.mouse_pos)
}

gui_mouse_occluded_by_overlay :: proc(ctx: ^Gui_Context) -> bool {
	if ctx.overlay_input_depth > 0 {
		return false
	}
	for i in 0 ..< ctx.overlay_input_rect_count {
		if gui_contains(ctx.overlay_input_rects[i], ctx.input.mouse_pos) {
			return true
		}
	}
	for i in 0 ..< ctx.next_overlay_input_rect_count {
		if gui_contains(ctx.next_overlay_input_rects[i], ctx.input.mouse_pos) {
			return true
		}
	}
	return false
}

gui_pointer_enabled :: proc(ctx: ^Gui_Context) -> bool {
	return ctx.input.pointer_enabled || ctx.input.active_device == .Mouse_Keyboard
}

gui_mouse_contains :: proc(ctx: ^Gui_Context, rect: Rect) -> bool {
	return gui_mouse_in_input_clip(ctx) && gui_contains(rect, ctx.input.mouse_pos)
}

gui_mouse_contains_circle :: proc(ctx: ^Gui_Context, center: Vec2, radius: f32) -> bool {
	return gui_mouse_in_input_clip(ctx) && gui_contains_circle(center, ctx.input.mouse_pos, radius)
}

gui_clamp01 :: proc(v: f32) -> f32 {
	if v < 0 do return 0
	if v > 1 do return 1
	return v
}

gui_fine_adjust_active :: proc(ctx: ^Gui_Context) -> bool {
	if ctx.input.key_shift {
		return true
	}
	if ctx.input.active_device == .Controller {
		// D-pad navigation arrives at full magnitude. A deliberately light stick
		// tilt stays below that magnitude, giving controllers a second speed
		// without consuming another button.
		magnitude := max(abs(ctx.input.nav_x), abs(ctx.input.nav_y))
		return magnitude > 0.05 && magnitude < 0.86
	}
	return false
}

gui_fine_adjust_scale :: proc(ctx: ^Gui_Context) -> f32 {
	return gui_fine_adjust_active(ctx) ? f32(0.2) : f32(1)
}

// Once fine mode is engaged during a pointer drag, keep it engaged until the
// button is released. Releasing Shift mid-drag must not snap an absolute
// slider or pad to the pointer position.
gui_pointer_fine_adjust_scale :: proc(ctx: ^Gui_Context, id: Gui_Id) -> f32 {
	if ctx.input.mouse_down && ctx.active == id && ctx.input.key_shift {
		ctx.fine_pointer_drag_id = id
	}
	return ctx.fine_pointer_drag_id == id ? f32(0.2) : f32(1)
}
