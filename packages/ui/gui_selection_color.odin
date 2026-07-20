package ui

import "core:math"
import "core:fmt"
import "core:strconv"

gui_selector_keyed :: proc(ctx: ^Gui_Context, label, key: string, current: ^int, options: []string) -> bool {
	if len(options) == 0 {
		return false
	}
	id := gui_make_id(ctx, key)
	bounds := gui_next_rect(ctx)
	current^ = max(min(current^, len(options) - 1), 0)
	arrow_w := min(max(bounds.h, f32(35)), bounds.w * 0.22)
	left := Rect{bounds.x, bounds.y, arrow_w, bounds.h}
	right := Rect{bounds.x + bounds.w - arrow_w, bounds.y, arrow_w, bounds.h}
	center := Rect{bounds.x + arrow_w, bounds.y, max(bounds.w - arrow_w * 2, 0), bounds.h}
	changed := false

	// The arrows are pointer affordances. Keeping them out of controller focus
	// makes the selector one coherent control: confirm to edit, D-pad to change.
	if gui_stepper_button_at(ctx, gui_id_child(id, "left"), left, -1, true, false) {
		ctx.focused = id
		current^ = (current^ - 1 + len(options)) % len(options)
		changed = true
	}
	gui_tooltip(ctx, left, "Previous option")
	center_control := gui_control(ctx, id, center, true)
	if center_control.hovered && ctx.active == id && ctx.input.mouse_released {
		current^ = (current^ + 1) % len(options)
		changed = true
	}
	if gui_stepper_button_at(ctx, gui_id_child(id, "right"), right, 1, true, false) {
		ctx.focused = id
		current^ = (current^ + 1) % len(options)
		changed = true
	}
	gui_tooltip(ctx, right, "Next option")
	editing := gui_update_focus_edit(ctx, id, ctx.focused == id)
	nav_x, nav_y: f32
	if editing {
		nav_x, nav_y = gui_focused_nav_pressed(ctx, id)
	} else if !ctx.controller_explicit_activation && center_control.focused && (ctx.input.nav_pressed_x != 0 || ctx.input.nav_pressed_y != 0) {
		gui_focus_edit_begin(ctx, id)
		ctx.focus_moved = true
		nav_x = ctx.input.nav_pressed_x
		nav_y = ctx.input.nav_pressed_y
	}
	// Capture before applying the first keyboard navigation step. Keyboard
	// arrows may engage a selector and change it in the same frame.
	gui_controller_edit_int(ctx, id, current)
	if nav_x != 0 || nav_y != 0 {
		delta := int(nav_x + nav_y)
		current^ = (current^ + delta + len(options)) % len(options)
		changed = true
	}
	center_fill := ctx.style.control
	if ctx.hot == id || ctx.focused == id {
		center_fill = {1, 1, 1, 0.15}
	}
	gui_rect(ctx, center, center_fill)
	gui_stroke(ctx, {center.x, center.y, center.w, center.h}, ctx.style.panel_border)
	text_y := center.y + max((center.h - ctx.style.body_text_height) * 0.5, 0)
	gui_text_clipped(ctx, gui_inset(center, 8), {center.x + 12, text_y}, label, ctx.style.text)
	gui_focus_or_edit_ring(ctx, id, center)
	return changed
}

gui_checkbox :: gui_checkbox_keyed

gui_checkbox_keyed :: proc(ctx: ^Gui_Context, label, key: string, value: ^bool) -> bool {
	id := gui_make_id(ctx, key)
	bounds := gui_next_rect(ctx)
	box_size := min(bounds.h - 10, f32(26))
	box := Rect{bounds.x + 8, bounds.y + (bounds.h - box_size) * 0.5, box_size, box_size}
	clicked := gui_button_behavior(ctx, id, bounds, true)
	if clicked {
		value^ = !value^
	}

	fill := ctx.style.control
	border := ctx.style.panel_border
	if ctx.hot == id {
		fill = ctx.style.control_hot
	}
	if ctx.active == id {
		fill = ctx.style.control_active
	}
	if value^ {
		fill = ctx.style.accent
		border = gui_apply_opacity(ctx.style.accent, 0.88)
		if ctx.hot == id || ctx.focused == id {
			fill = gui_lighten(ctx.style.accent, 0.08)
		}
		if ctx.active == id {
			fill = gui_lighten(ctx.style.accent, 0.14)
		}
	}
	gui_round_rect(ctx, box, 4, fill)
	gui_round_stroke(ctx, box, 4, border, ctx.style.border_width)
	if value^ {
		check_color := Color{1, 1, 1, 0.95}
		gui_line(ctx, {box.x + box.w * 0.23, box.y + box.h * 0.52}, {box.x + box.w * 0.43, box.y + box.h * 0.72}, check_color, max(ctx.style.border_width * 2, 2))
		gui_line(ctx, {box.x + box.w * 0.43, box.y + box.h * 0.72}, {box.x + box.w * 0.78, box.y + box.h * 0.28}, check_color, max(ctx.style.border_width * 2, 2))
	}
	if ctx.focused == id {
		gui_focus_ring(ctx, bounds)
	}
	gui_text_clipped(ctx, gui_inset_edges(bounds, {left = box_size + 20, top = 0, right = 8, bottom = 0}), {bounds.x + box_size + 24, bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0)}, label, ctx.style.text)
	return clicked
}

gui_switch :: gui_switch_keyed

gui_switch_keyed :: proc(ctx: ^Gui_Context, label, key: string, value: ^bool) -> bool {
	id := gui_make_id(ctx, key)
	bounds := gui_next_rect(ctx)
	track_h := min(max(bounds.h * 0.64, f32(28)), max(bounds.h - ctx.style.control_padding, f32(24)))
	track_w := max(track_h * 1.85, f32(54))
	track := Rect{bounds.x + 8, bounds.y + (bounds.h - track_h) * 0.5, track_w, track_h}
	clicked := gui_button_behavior(ctx, id, bounds, true)
	gui_controller_edit_bool(ctx, id, value)
	if clicked {
		value^ = !value^
	}

	t := value^ ? f32(1) : f32(0)
	if ctx.input.delta_time > 0 {
		t = gui_animate_value(ctx, gui_id_child(id, "switch-track"), t, 14)
	}
	track_color := gui_lerp_color(ctx.style.control, ctx.style.accent, t)
	track_border := ctx.style.panel_border
	if value^ {
		track_border = gui_apply_opacity(ctx.style.accent, 0.78)
	}
	if ctx.hot == id {
		track_color = value^ ? gui_lighten(ctx.style.accent, 0.08) : ctx.style.control_hot
	}
	if ctx.active == id {
		track_color = value^ ? gui_lighten(ctx.style.accent, 0.14) : ctx.style.control_active
	}
	gui_round_rect(ctx, track, track.h * 0.5, track_color)
	gui_round_stroke(ctx, track, track.h * 0.5, track_border, ctx.style.border_width)
	knob_padding := max(track.h * 0.14, f32(4))
	knob_size := max(track.h - knob_padding * 2, f32(12))
	knob_x := track.x + knob_padding + (track.w - knob_size - knob_padding * 2) * t
	knob := Rect{knob_x, track.y + knob_padding, knob_size, knob_size}
	gui_shadow(ctx, knob, knob_size * 0.5, {0, max(ctx.style.border_width, f32(1))}, ctx.style.shadow_blur * 0.35, {0, 0, 0, 0.26})
	gui_ellipse(ctx, knob, Color{1, 1, 1, 0.96})
	gui_ellipse_stroke(ctx, knob, gui_apply_opacity(ctx.style.panel_border, 0.68), ctx.style.border_width)
	if ctx.focused == id {
		gui_focus_ring(ctx, bounds)
	}
	label_left := track.x + track.w + ctx.style.spacing_2
	gui_text_clipped(ctx, gui_inset_edges(bounds, {left = label_left - bounds.x, top = 0, right = 8, bottom = 0}), {label_left, bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0)}, label, ctx.style.text)
	return clicked
}

gui_radio :: gui_radio_keyed

gui_radio_keyed :: proc(ctx: ^Gui_Context, label, key: string, selected: bool) -> bool {
	id := gui_make_id(ctx, key)
	bounds := gui_next_rect(ctx)
	size := min(bounds.h - 10, f32(26))
	circle := Rect{bounds.x + 8, bounds.y + (bounds.h - size) * 0.5, size, size}
	clicked := gui_button_behavior(ctx, id, bounds, true)
	fill := ctx.style.control
	border := ctx.style.panel_border
	if ctx.hot == id {
		fill = ctx.style.control_hot
	}
	if ctx.active == id {
		fill = ctx.style.control_active
	}
	if selected {
		border = gui_apply_opacity(ctx.style.accent, 0.88)
		if ctx.hot == id || ctx.focused == id {
			fill = gui_lerp_color(ctx.style.control, ctx.style.control_hot, 0.55)
		}
	}
	gui_ellipse(ctx, circle, fill)
	gui_ellipse_stroke(ctx, circle, border, selected ? max(ctx.style.border_width * 2, 2) : ctx.style.border_width)
	if selected {
		gui_ellipse(ctx, gui_inset(circle, max(size * 0.30, f32(6))), ctx.style.accent)
	}
	if ctx.focused == id {
		gui_focus_ring(ctx, bounds)
	}
	gui_text_clipped(ctx, gui_inset_edges(bounds, {left = size + 20, top = 0, right = 8, bottom = 0}), {bounds.x + size + 24, bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0)}, label, ctx.style.text)
	return clicked
}

gui_radio_group :: gui_radio_group_keyed

gui_radio_group_keyed :: proc(ctx: ^Gui_Context, label, key: string, current: ^int, options: []string) -> bool {
	if len(options) == 0 {
		return false
	}
	changed := false
	gui_label(ctx, label)
	group_id := gui_make_id(ctx, key)
	start_index := ctx.layout_depth > 0 ? ctx.layout_stack[ctx.layout_depth - 1].cursor : ctx.next_cursor
	group_bounds := Rect{start_index.x, start_index.y, 0, 0}
	row_bounds: [64]Rect
	option_count := min(len(options), len(row_bounds))
	for option, i in options {
		id := gui_id_child_int(group_id, i)
		bounds := gui_next_rect(ctx)
		if i < option_count {
			row_bounds[i] = bounds
		}
		if i == 0 {
			group_bounds = bounds
		} else {
			right := max(group_bounds.x + group_bounds.w, bounds.x + bounds.w)
			bottom := max(group_bounds.y + group_bounds.h, bounds.y + bounds.h)
			group_bounds.x = min(group_bounds.x, bounds.x)
			group_bounds.y = min(group_bounds.y, bounds.y)
			group_bounds.w = right - group_bounds.x
			group_bounds.h = bottom - group_bounds.y
		}
		size := min(bounds.h - 10, f32(24))
		circle := Rect{bounds.x + 8, bounds.y + (bounds.h - size) * 0.5, size, size}
		hovered := gui_mouse_contains(ctx, bounds)
		if hovered {
			ctx.hot = id
			if ctx.input.mouse_pressed {
				ctx.active = group_id
				ctx.focused = group_id
			}
		}
		clicked := hovered && ctx.active == group_id && ctx.input.mouse_released
		if clicked && current^ != i {
			current^ = i
			ctx.focused = group_id
			changed = true
		}
		fill := ctx.style.control
		border := ctx.style.panel_border
		if ctx.hot == id {
			fill = ctx.style.control_hot
		}
		if ctx.active == group_id {
			fill = ctx.style.control_active
		}
		if current^ == i {
			border = gui_apply_opacity(ctx.style.accent, 0.88)
			if ctx.hot == id || ctx.focused == group_id {
				fill = gui_lerp_color(ctx.style.control, ctx.style.control_hot, 0.55)
			}
		}
		gui_ellipse(ctx, circle, fill)
		gui_ellipse_stroke(ctx, circle, border, current^ == i ? max(ctx.style.border_width * 2, 2) : ctx.style.border_width)
		if current^ == i {
			gui_ellipse(ctx, gui_inset(circle, max(size * 0.30, f32(6))), ctx.style.accent)
		}
		gui_text_clipped(ctx, gui_inset_edges(bounds, {left = size + 20, top = 0, right = 8, bottom = 0}), {bounds.x + size + 24, bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0)}, option, ctx.style.text)
	}
	group_control := gui_control(ctx, group_id, group_bounds, true)
	editing := group_control.focused
	if ctx.controller_explicit_activation {
		editing = gui_update_focus_edit(ctx, group_id, group_control.focused)
		gui_controller_edit_int(ctx, group_id, current)
	}
	if group_control.activated && !ctx.controller_explicit_activation {
		current^ = (current^ + 1) % len(options)
		changed = true
	}
	if editing {
		nav_delta := int(ctx.input.nav_pressed_x + ctx.input.nav_pressed_y)
		if nav_delta != 0 {
			next := (current^ + nav_delta + len(options)) % len(options)
			if next != current^ {
				current^ = next
				changed = true
			}
		}
	}
	if group_control.focused {
		focus_bounds := group_bounds
		if current^ >= 0 && current^ < option_count {
			focus_bounds = row_bounds[current^]
		}
		gui_focus_or_edit_ring(ctx, group_id, focus_bounds)
	}
	return changed
}

gui_area_slider_f32 :: gui_area_slider_f32_keyed

gui_area_slider_f32_keyed :: proc(ctx: ^Gui_Context, label, key: string, value: ^Vec2, min_value, max_value: Vec2) -> bool {
	bounds := gui_next_rect(ctx, height = 160)
	gui_text_clipped(ctx, {bounds.x, bounds.y, bounds.w, ctx.style.row_height}, {bounds.x + 2, bounds.y + 4}, label, ctx.style.text)
	area := Rect{bounds.x, bounds.y + ctx.style.row_height, bounds.w, max(bounds.h - ctx.style.row_height, 1)}
	return gui_area_slider_f32_at(ctx, gui_make_id(ctx, key), area, value, min_value, max_value)
}

gui_area_slider_f32_at :: proc(ctx: ^Gui_Context, id: Gui_Id, area: Rect, value: ^Vec2, min_value, max_value: Vec2) -> bool {
	changed := false
	normalized := gui_vec2_to_normalized(value^, min_value, max_value)
	handle := gui_normalized_to_rect_point(area, normalized)
	if gui_drag_handle_region(ctx, id, area, handle, 10) {
		normalized := gui_rect_point_to_normalized(area, ctx.input.mouse_pos)
		value^ = gui_vec2_from_normalized(normalized, min_value, max_value)
		changed = true
	}
	_ = gui_update_focus_edit(ctx, id, ctx.focused == id)
	gui_controller_edit_vec2(ctx, id, value)
	nav_x, nav_y := gui_focused_nav_pressed(ctx, id)
	if nav_x != 0 || nav_y != 0 {
		step := Vec2{(max_value.x - min_value.x) * 0.05, (max_value.y - min_value.y) * 0.05}
		value^.x += nav_x * step.x
		value^.y += nav_y * step.y
		if value^.x < min_value.x do value^.x = min_value.x
		if value^.x > max_value.x do value^.x = max_value.x
		if value^.y < min_value.y do value^.y = min_value.y
		if value^.y > max_value.y do value^.y = max_value.y
		changed = true
	}
	gui_draw_checker_grid(ctx, area)
	gui_round_stroke(ctx, area, ctx.style.radius_control, ctx.style.panel_border, ctx.style.border_width)
	normalized = gui_vec2_to_normalized(value^, min_value, max_value)
	handle = gui_normalized_to_rect_point(area, normalized)
	gui_draw_handle(ctx, handle, 7)
	gui_focus_or_edit_ring(ctx, id, area)
	return changed
}

gui_hue_wheel :: proc(ctx: ^Gui_Context, label, key: string, hsv: ^Hsv_Color) -> bool {
	bounds := gui_next_rect(ctx, height = 176)
	gui_text_clipped(ctx, {bounds.x, bounds.y, bounds.w, ctx.style.row_height}, {bounds.x + 2, bounds.y + 4}, label, ctx.style.text)
	wheel := Rect{bounds.x, bounds.y + ctx.style.row_height, bounds.w, bounds.h - ctx.style.row_height}
	return gui_hue_wheel_at(ctx, gui_make_id(ctx, key), wheel, hsv)
}

gui_hue_wheel_at :: proc(ctx: ^Gui_Context, id: Gui_Id, bounds: Rect, hsv: ^Hsv_Color) -> bool {
	gui_register_focusable(ctx, id, bounds)
	center := Vec2{bounds.x + bounds.w * 0.5, bounds.y + bounds.h * 0.5}
	outer := max(min(bounds.w, bounds.h) * 0.5 - 6, 1)
	inner := max(outer - 18, 1)
	segments := 48
	_ = segments
	gui_shader_rect(ctx, {center.x - outer, center.y - outer, outer * 2, outer * 2}, .Hue_Wheel, {inner / outer, 1, 0, hsv.a}, {1, 1, 1, 1})
	gui_ellipse_stroke(ctx, {center.x - outer, center.y - outer, outer * 2, outer * 2}, ctx.style.panel_border, 1)
	gui_ellipse_stroke(ctx, {center.x - inner, center.y - inner, inner * 2, inner * 2}, ctx.style.panel_border, 1)

	changed := false
	h := gui_wrap01(hsv.h)
	angle := h * GUI_TAU
	handle := Vec2{center.x + math.cos(angle) * ((inner + outer) * 0.5), center.y + math.sin(angle) * ((inner + outer) * 0.5)}
	delta := Vec2{ctx.input.mouse_pos.x - center.x, ctx.input.mouse_pos.y - center.y}
	dist := math.sqrt(delta.x * delta.x + delta.y * delta.y)
	hovered := gui_mouse_in_input_clip(ctx) && ((dist >= inner && dist <= outer) || gui_contains_circle(handle, ctx.input.mouse_pos, 10))
	if hovered {
		ctx.hot = id
		if ctx.input.mouse_pressed {
			ctx.active = id
			ctx.focused = id
		}
	}
	if ctx.active == id && ctx.input.mouse_down {
		hsv.h = gui_hue_from_delta(delta)
		changed = true
	}
	_ = gui_update_focus_edit(ctx, id, ctx.focused == id)
	gui_controller_edit_hsv(ctx, id, hsv)
	nav_x, nav_y := gui_focused_nav_pressed(ctx, id)
	if nav_x != 0 || nav_y != 0 {
		hsv.h = gui_wrap01(hsv.h + (nav_x - nav_y) * 0.01)
		changed = true
	}
	h = gui_wrap01(hsv.h)
	angle = h * GUI_TAU
	handle = Vec2{center.x + math.cos(angle) * ((inner + outer) * 0.5), center.y + math.sin(angle) * ((inner + outer) * 0.5)}
	gui_draw_handle(ctx, handle, 7)
	gui_focus_or_edit_ring(ctx, id, bounds)
	return changed
}

gui_sv_grid :: proc(ctx: ^Gui_Context, label, key: string, hsv: ^Hsv_Color) -> bool {
	bounds := gui_next_rect(ctx, height = 158)
	gui_text_clipped(ctx, {bounds.x, bounds.y, bounds.w, ctx.style.row_height}, {bounds.x + 2, bounds.y + 4}, label, ctx.style.text)
	grid := Rect{bounds.x, bounds.y + ctx.style.row_height, bounds.w, bounds.h - ctx.style.row_height}
	return gui_sv_grid_at(ctx, gui_make_id(ctx, key), grid, hsv)
}

gui_sv_grid_at :: proc(ctx: ^Gui_Context, id: Gui_Id, grid: Rect, hsv: ^Hsv_Color) -> bool {
	hue_color := gui_hsv_to_rgb({h = hsv.h, s = 1, v = 1, a = 1})
	hue_color.a = gui_clamp01(hsv.a)
	gui_shader_rect(ctx, grid, .SV_Grid, {}, hue_color)
	changed := false
	handle := gui_normalized_to_rect_point(grid, {gui_clamp01(hsv.s), 1 - gui_clamp01(hsv.v)})
	if gui_drag_handle_region(ctx, id, grid, handle, 10) {
		n := gui_rect_point_to_normalized(grid, ctx.input.mouse_pos)
		hsv.s = n.x
		hsv.v = 1 - n.y
		changed = true
	}
	_ = gui_update_focus_edit(ctx, id, ctx.focused == id)
	gui_controller_edit_hsv(ctx, id, hsv)
	nav_x, nav_y := gui_focused_nav_pressed(ctx, id)
	if nav_x != 0 || nav_y != 0 {
		hsv.s = gui_clamp01(hsv.s + nav_x * 0.05)
		hsv.v = gui_clamp01(hsv.v - nav_y * 0.05)
		changed = true
	}
	gui_round_stroke(ctx, grid, ctx.style.radius_control, ctx.style.panel_border, ctx.style.border_width)
	handle = gui_normalized_to_rect_point(grid, {gui_clamp01(hsv.s), 1 - gui_clamp01(hsv.v)})
	gui_draw_handle(ctx, handle, 7)
	gui_focus_or_edit_ring(ctx, id, grid)
	return changed
}

gui_alpha_slider :: proc(ctx: ^Gui_Context, label, key: string, hsv: ^Hsv_Color) -> bool {
	bounds := gui_next_rect(ctx, height = ctx.style.row_height)
	id := gui_make_id(ctx, key)
	changed := false
	track := gui_inset_edges(bounds, {left = 0, top = 8, right = 0, bottom = 8})
	base := gui_hsv_to_rgb({h = hsv.h, s = hsv.s, v = hsv.v, a = 1})
	gui_shader_rect(ctx, track, .Alpha_Ramp, {0, 0, 0, 1}, base)
	x := track.x + track.w * gui_clamp01(hsv.a)
	handle := Vec2{x, track.y + track.h * 0.5}
	if gui_drag_handle_region(ctx, id, bounds, handle, 10) {
		hsv.a = gui_rect_point_to_normalized(bounds, ctx.input.mouse_pos).x
		changed = true
	}
	_ = gui_update_focus_edit(ctx, id, ctx.focused == id)
	gui_controller_edit_hsv(ctx, id, hsv)
	nav_x, nav_y := gui_focused_nav_pressed(ctx, id)
	if nav_x != 0 || nav_y != 0 {
		hsv.a = gui_clamp01(hsv.a + (nav_x - nav_y) * 0.05)
		changed = true
	}
	gui_round_stroke(ctx, track, track.h * 0.5, ctx.style.panel_border, ctx.style.border_width)
	x = track.x + track.w * gui_clamp01(hsv.a)
	gui_draw_handle(ctx, {x, track.y + track.h * 0.5}, 6)
	gui_text_clipped(ctx, gui_inset(bounds, 6), {bounds.x + 10, bounds.y + 6}, label, ctx.style.text)
	gui_focus_or_edit_ring(ctx, id, bounds)
	return changed
}

gui_color_picker_hsv :: gui_color_picker_hsv_keyed

gui_color_picker_hsv_keyed :: proc(ctx: ^Gui_Context, label, key: string, hsv: ^Hsv_Color) -> bool {
	changed := false
	gui_heading(ctx, label)
	gui_push_id(ctx, key)
	changed = gui_hue_wheel(ctx, "Hue", "hue", hsv) || changed
	changed = gui_sv_grid(ctx, "Saturation / Value", "sv", hsv) || changed
	changed = gui_alpha_slider(ctx, "Alpha", "alpha", hsv) || changed
	gui_pop_id(ctx)
	swatch := gui_next_rect(ctx, height = 42)
	gui_box(ctx, swatch, {
		fill = gui_hsv_to_rgb(hsv^),
		border = ctx.style.panel_border,
		radius = ctx.style.radius_control,
		border_width = ctx.style.border_width,
	})
	return changed
}
