package ui

import "core:math"
import "core:fmt"
import "core:strconv"

gui_text_edit_begin :: proc(ctx: ^Gui_Context, id: Gui_Id, length: int) {
	if ctx.text_edit_id != id {
		ctx.text_edit_id = id
		ctx.text_edit_caret = length
		ctx.text_edit_anchor = length
		ctx.text_edit_scroll_x = 0
		ctx.text_edit_blink = 0
		ctx.text_edit_selecting = false
	}
}

gui_text_edit_clamp :: proc(ctx: ^Gui_Context, length: int) {
	ctx.text_edit_caret = gui_utf8_clamp_index(ctx.text_edit_caret, length)
	ctx.text_edit_anchor = gui_utf8_clamp_index(ctx.text_edit_anchor, length)
}

gui_text_edit_has_selection :: proc(ctx: ^Gui_Context) -> bool {
	return ctx.text_edit_caret != ctx.text_edit_anchor
}

gui_text_edit_selection :: proc(ctx: ^Gui_Context) -> (start, end: int) {
	if ctx.text_edit_caret < ctx.text_edit_anchor {
		return ctx.text_edit_caret, ctx.text_edit_anchor
	}
	return ctx.text_edit_anchor, ctx.text_edit_caret
}

gui_text_edit_clear_selection :: proc(ctx: ^Gui_Context) {
	ctx.text_edit_anchor = ctx.text_edit_caret
}

gui_text_edit_delete_range :: proc(buffer: []u8, length: ^int, start, end: int) -> bool {
	range_start := max(min(start, length^), 0)
	range_end := max(min(end, length^), range_start)
	if range_start >= range_end {
		return false
	}
	count := length^ - range_end
	for i in 0 ..< count {
		buffer[range_start + i] = buffer[range_end + i]
	}
	length^ -= range_end - range_start
	if length^ < len(buffer) {
		buffer[length^] = 0
	}
	return true
}

gui_text_edit_delete_selection :: proc(ctx: ^Gui_Context, buffer: []u8, length: ^int) -> bool {
	if !gui_text_edit_has_selection(ctx) {
		return false
	}
	start, end := gui_text_edit_selection(ctx)
	if gui_text_edit_delete_range(buffer, length, start, end) {
		ctx.text_edit_caret = start
		ctx.text_edit_anchor = start
		return true
	}
	return false
}

gui_text_edit_insert_bytes :: proc(ctx: ^Gui_Context, buffer: []u8, length: ^int, bytes: []u8, numeric := false) -> bool {
	if len(buffer) == 0 || len(bytes) == 0 {
		return false
	}
	changed := gui_text_edit_delete_selection(ctx, buffer, length)
	for ch in bytes {
		if ch < 32 {
			continue
		}
		if numeric && !gui_numeric_edit_accepts_char(ch) {
			continue
		}
		if length^ >= len(buffer) {
			break
		}
		for i := length^; i > ctx.text_edit_caret; i -= 1 {
			buffer[i] = buffer[i - 1]
		}
		buffer[ctx.text_edit_caret] = ch
		length^ += 1
		ctx.text_edit_caret += 1
		ctx.text_edit_anchor = ctx.text_edit_caret
		changed = true
	}
	if length^ < len(buffer) {
		buffer[length^] = 0
	}
	return changed
}

gui_text_edit_set_clipboard :: proc(ctx: ^Gui_Context, bytes: []u8) {
	ctx.clipboard_set_len = min(len(bytes), len(ctx.clipboard_set_text) - 1)
	for i in 0 ..< ctx.clipboard_set_len {
		ctx.clipboard_set_text[i] = bytes[i]
	}
	if len(ctx.clipboard_set_text) > 0 {
		ctx.clipboard_set_text[ctx.clipboard_set_len] = 0
	}
	ctx.clipboard_set_pending = ctx.clipboard_set_len > 0
}

gui_text_edit_copy_selection :: proc(ctx: ^Gui_Context, buffer: []u8) {
	if !gui_text_edit_has_selection(ctx) {
		return
	}
	start, end := gui_text_edit_selection(ctx)
	gui_text_edit_set_clipboard(ctx, buffer[start:end])
}

gui_text_edit_move_caret :: proc(ctx: ^Gui_Context, length: int, caret: int, extend: bool) {
	ctx.text_edit_caret = gui_utf8_clamp_index(caret, length)
	if !extend {
		ctx.text_edit_anchor = ctx.text_edit_caret
	}
	ctx.text_edit_blink = 0
}

gui_text_edit_is_word_char :: proc(ch: u8) -> bool {
	switch ch {
	case 'a'..='z', 'A'..='Z', '0'..='9', '_':
		return true
	}
	return false
}

gui_text_edit_prev_word_index :: proc(bytes: []u8, index: int) -> int {
	i := gui_utf8_clamp_index(index, len(bytes))
	for i > 0 {
		prev := gui_utf8_prev_index(bytes, i)
		if gui_text_edit_is_word_char(bytes[prev]) {
			break
		}
		i = prev
	}
	for i > 0 {
		prev := gui_utf8_prev_index(bytes, i)
		if !gui_text_edit_is_word_char(bytes[prev]) {
			break
		}
		i = prev
	}
	return i
}

gui_text_edit_next_word_index :: proc(bytes: []u8, index: int) -> int {
	i := gui_utf8_clamp_index(index, len(bytes))
	for i < len(bytes) {
		if gui_text_edit_is_word_char(bytes[i]) {
			break
		}
		i = gui_utf8_next_index(bytes, i)
	}
	for i < len(bytes) {
		if !gui_text_edit_is_word_char(bytes[i]) {
			break
		}
		i = gui_utf8_next_index(bytes, i)
	}
	return i
}

gui_text_edit_process :: proc(ctx: ^Gui_Context, id: Gui_Id, buffer: []u8, length: ^int, numeric := false) -> bool {
	gui_text_edit_begin(ctx, id, length^)
	gui_text_edit_clamp(ctx, length^)
	changed := false
	modifier := ctx.input.key_ctrl || ctx.input.key_super

	if ctx.input.back || ctx.input.accept {
		ctx.focused = GUI_ID_NONE
		ctx.text_edit_selecting = false
		return false
	}

	if modifier && ctx.input.key_a {
		ctx.text_edit_caret = length^
		ctx.text_edit_anchor = 0
		ctx.text_edit_blink = 0
	}
	if modifier && ctx.input.key_c {
		gui_text_edit_copy_selection(ctx, buffer[:length^])
	}
	if modifier && ctx.input.key_x {
		gui_text_edit_copy_selection(ctx, buffer[:length^])
		if gui_text_edit_delete_selection(ctx, buffer, length) {
			changed = true
		}
	}
	if modifier && ctx.input.key_v && ctx.input.clipboard_paste_len > 0 {
		changed = gui_text_edit_insert_bytes(ctx, buffer, length, ctx.input.clipboard_paste[:ctx.input.clipboard_paste_len], numeric) || changed
	}

	if ctx.input.key_home {
		gui_text_edit_move_caret(ctx, length^, 0, ctx.input.key_shift)
	}
	if ctx.input.key_end {
		gui_text_edit_move_caret(ctx, length^, length^, ctx.input.key_shift)
	}
	if ctx.input.key_left {
		if ctx.input.key_super {
			gui_text_edit_move_caret(ctx, length^, 0, ctx.input.key_shift)
		} else if ctx.input.key_ctrl {
			gui_text_edit_move_caret(ctx, length^, gui_text_edit_prev_word_index(buffer[:length^], ctx.text_edit_caret), ctx.input.key_shift)
		} else if gui_text_edit_has_selection(ctx) && !ctx.input.key_shift {
			start, _ := gui_text_edit_selection(ctx)
			gui_text_edit_move_caret(ctx, length^, start, false)
		} else {
			gui_text_edit_move_caret(ctx, length^, gui_utf8_prev_index(buffer[:length^], ctx.text_edit_caret), ctx.input.key_shift)
		}
	}
	if ctx.input.key_right {
		if ctx.input.key_super {
			gui_text_edit_move_caret(ctx, length^, length^, ctx.input.key_shift)
		} else if ctx.input.key_ctrl {
			gui_text_edit_move_caret(ctx, length^, gui_text_edit_next_word_index(buffer[:length^], ctx.text_edit_caret), ctx.input.key_shift)
		} else if gui_text_edit_has_selection(ctx) && !ctx.input.key_shift {
			_, end := gui_text_edit_selection(ctx)
			gui_text_edit_move_caret(ctx, length^, end, false)
		} else {
			gui_text_edit_move_caret(ctx, length^, gui_utf8_next_index(buffer[:length^], ctx.text_edit_caret), ctx.input.key_shift)
		}
	}

	if ctx.input.key_backspace {
		if gui_text_edit_delete_selection(ctx, buffer, length) {
			changed = true
		} else if ctx.input.key_super && ctx.text_edit_caret > 0 {
			if gui_text_edit_delete_range(buffer, length, 0, ctx.text_edit_caret) {
				ctx.text_edit_caret = 0
				ctx.text_edit_anchor = 0
				changed = true
			}
		} else if ctx.input.key_ctrl && ctx.text_edit_caret > 0 {
			prev := gui_text_edit_prev_word_index(buffer[:length^], ctx.text_edit_caret)
			if gui_text_edit_delete_range(buffer, length, prev, ctx.text_edit_caret) {
				ctx.text_edit_caret = prev
				ctx.text_edit_anchor = prev
				changed = true
			}
		} else if ctx.text_edit_caret > 0 {
			prev := gui_utf8_prev_index(buffer[:length^], ctx.text_edit_caret)
			if gui_text_edit_delete_range(buffer, length, prev, ctx.text_edit_caret) {
				ctx.text_edit_caret = prev
				ctx.text_edit_anchor = prev
				changed = true
			}
		}
	}
	if ctx.input.key_delete {
		if gui_text_edit_delete_selection(ctx, buffer, length) {
			changed = true
		} else if ctx.input.key_super && ctx.text_edit_caret < length^ {
			if gui_text_edit_delete_range(buffer, length, ctx.text_edit_caret, length^) {
				ctx.text_edit_anchor = ctx.text_edit_caret
				changed = true
			}
		} else if ctx.input.key_ctrl && ctx.text_edit_caret < length^ {
			next := gui_text_edit_next_word_index(buffer[:length^], ctx.text_edit_caret)
			if gui_text_edit_delete_range(buffer, length, ctx.text_edit_caret, next) {
				ctx.text_edit_anchor = ctx.text_edit_caret
				changed = true
			}
		} else if ctx.text_edit_caret < length^ {
			next := gui_utf8_next_index(buffer[:length^], ctx.text_edit_caret)
			if gui_text_edit_delete_range(buffer, length, ctx.text_edit_caret, next) {
				ctx.text_edit_anchor = ctx.text_edit_caret
				changed = true
			}
		}
	}
	if ctx.input.text_input_len > 0 {
		changed = gui_text_edit_insert_bytes(ctx, buffer, length, ctx.input.text_input[:ctx.input.text_input_len], numeric) || changed
	}

	gui_text_edit_clamp(ctx, length^)
	return changed
}

gui_text_edit_hit_test :: proc(ctx: ^Gui_Context, buffer: []u8, x: f32) -> int {
	best := 0
	best_distance := abs(x)
	for i in 0 ..= len(buffer) {
		if i > 0 && gui_utf8_is_continuation(buffer[i - 1]) {
			continue
		}
		width := gui_text_width(ctx, string(buffer[:i]))
		distance := abs(width - x)
		if distance < best_distance {
			best = i
			best_distance = distance
		}
	}
	return best
}

gui_text_edit_handle_mouse :: proc(ctx: ^Gui_Context, id: Gui_Id, buffer: []u8, length: int, bounds: Rect, text_pos: Vec2) {
	if ctx.input.mouse_pressed && gui_mouse_contains(ctx, bounds) {
		local_x := ctx.input.mouse_pos.x - text_pos.x + ctx.text_edit_scroll_x
		ctx.text_edit_caret = gui_text_edit_hit_test(ctx, buffer[:length], local_x)
		if !ctx.input.key_shift {
			ctx.text_edit_anchor = ctx.text_edit_caret
		}
		ctx.text_edit_selecting = true
		ctx.text_edit_blink = 0
	} else if ctx.input.mouse_down && ctx.active == id && ctx.text_edit_selecting {
		local_x := ctx.input.mouse_pos.x - text_pos.x + ctx.text_edit_scroll_x
		ctx.text_edit_caret = gui_text_edit_hit_test(ctx, buffer[:length], local_x)
		ctx.text_edit_blink = 0
	}
	if ctx.input.mouse_released {
		ctx.text_edit_selecting = false
	}
}

gui_text_edit_keep_caret_visible :: proc(ctx: ^Gui_Context, buffer: []u8, length: int, rect: Rect) {
	caret_x := gui_text_width(ctx, string(buffer[:ctx.text_edit_caret]))
	padding := f32(8)
	if caret_x - ctx.text_edit_scroll_x > rect.w - padding {
		ctx.text_edit_scroll_x = caret_x - rect.w + padding
	}
	if caret_x - ctx.text_edit_scroll_x < 0 {
		ctx.text_edit_scroll_x = caret_x
	}
	ctx.text_edit_scroll_x = max(ctx.text_edit_scroll_x, 0)
}

gui_text_edit_draw :: proc(ctx: ^Gui_Context, rect: Rect, text_pos: Vec2, buffer: []u8, length: int, placeholder: string, focused: bool, trailing_inset := f32(0)) {
	display := string(buffer[:length])
	text_color := ctx.style.text
	if length == 0 {
		display = placeholder
		text_color = ctx.style.text_muted
	}
	clip := gui_inset_edges(rect, {left = ctx.style.control_padding, top = ctx.style.control_padding, right = ctx.style.control_padding + trailing_inset, bottom = ctx.style.control_padding})
	draw_pos := Vec2{text_pos.x - ctx.text_edit_scroll_x, text_pos.y}
	if focused && length > 0 && gui_text_edit_has_selection(ctx) {
		start, end := gui_text_edit_selection(ctx)
		x0 := draw_pos.x + gui_text_width(ctx, string(buffer[:start]))
		x1 := draw_pos.x + gui_text_width(ctx, string(buffer[:end]))
		gui_rect(ctx, {x0, rect.y + ctx.style.control_padding, max(x1 - x0, 1), max(rect.h - ctx.style.control_padding * 2, 1)}, {ctx.style.accent.r, ctx.style.accent.g, ctx.style.accent.b, 0.32})
	}
	gui_text_clipped(ctx, clip, draw_pos, display, text_color)
	if focused {
		ctx.text_edit_blink += ctx.input.delta_time
		if ctx.text_edit_blink > 1.0 {
			ctx.text_edit_blink -= 1.0
		}
		if ctx.text_edit_blink < 0.55 {
			caret_x := draw_pos.x + gui_text_width(ctx, string(buffer[:ctx.text_edit_caret]))
			caret_w := max(ctx.style.border_width * 2, 2)
			caret_h := max(ctx.style.body_text_height, rect.h - ctx.style.control_padding * 2)
			caret_y := rect.y + max((rect.h - caret_h) * 0.5, 0)
			gui_rect(ctx, {caret_x, caret_y, caret_w, caret_h}, ctx.style.accent)
		}
	}
}

gui_text_field_chrome :: proc(ctx: ^Gui_Context, bounds: Rect, active, hot, focused: bool) {
	color := ctx.style.control
	border := ctx.style.panel_border
	stroke_width := ctx.style.border_width
	if focused {
		color = gui_lerp_color(ctx.style.control, ctx.style.control_hot, active ? f32(0.45) : f32(0.22))
		border = gui_apply_opacity(ctx.style.accent, 0.78)
		stroke_width = max(ctx.style.border_width * 2, 2)
	} else if active {
		color = ctx.style.control_hot
	} else if hot {
		color = ctx.style.control_hot
	}
	gui_round_rect(ctx, bounds, ctx.style.radius_control, color)
	gui_round_stroke(ctx, bounds, ctx.style.radius_control, border, stroke_width)
}

gui_text_input_clear_rect :: proc(ctx: ^Gui_Context, bounds: Rect) -> Rect {
	size := min(max(bounds.h * 0.45, f32(18)), max(bounds.h - ctx.style.control_padding * 2, f32(12)))
	x := bounds.x + bounds.w - ctx.style.control_padding * 1.5 - size
	y := bounds.y + (bounds.h - size) * 0.5
	return {x, y, size, size}
}

gui_text_input_clear_hit_rect :: proc(ctx: ^Gui_Context, bounds: Rect) -> Rect {
	size := min(max(bounds.h * 0.72, f32(28)), bounds.h)
	x := bounds.x + bounds.w - ctx.style.control_padding - size
	y := bounds.y + (bounds.h - size) * 0.5
	return {x, y, size, size}
}

gui_text_input_body_rect :: proc(bounds, clear_hit: Rect, clear_visible: bool) -> Rect {
	if !clear_visible {
		return bounds
	}
	return {bounds.x, bounds.y, max(clear_hit.x - bounds.x, 0), bounds.h}
}

gui_text_input_draw_clear_button :: proc(ctx: ^Gui_Context, rect: Rect, hot, active: bool) {
	fill := Color{1, 1, 1, 0.24}
	if active {
		fill = Color{1, 1, 1, 0.36}
	} else if hot {
		fill = Color{1, 1, 1, 0.31}
	}
	gui_ellipse(ctx, rect, fill)
	center := Vec2{rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
	size := rect.w * 0.22
	line_color := Color{0.02, 0.025, 0.035, 0.82}
	gui_line(ctx, {center.x - size, center.y - size}, {center.x + size, center.y + size}, line_color, max(ctx.style.border_width * 1.6, 2))
	gui_line(ctx, {center.x + size, center.y - size}, {center.x - size, center.y + size}, line_color, max(ctx.style.border_width * 1.6, 2))
}

gui_text_input_keyed :: proc(ctx: ^Gui_Context, label, key: string, buffer: []u8, length: ^int) -> bool {
	id := gui_make_id(ctx, key)
	bounds := gui_next_rect(ctx)
	control := gui_control(ctx, id, bounds, true)
	editing := control.focused
	if ctx.controller_explicit_activation {
		editing = gui_update_focus_edit(ctx, id, control.focused)
	}
	gui_controller_edit_text(ctx, id, buffer, length)
	changed := false

	if length^ < 0 {
		length^ = 0
	}
	if length^ > len(buffer) {
		length^ = len(buffer)
	}

	clear_visual := gui_text_input_clear_rect(ctx, bounds)
	clear_hit := gui_text_input_clear_hit_rect(ctx, bounds)
	clear_visible := length^ > 0 && (control.focused || control.hovered)
	clear_hot := clear_visible && gui_mouse_contains(ctx, clear_hit)
	clear_active := clear_hot && ctx.active == id && ctx.input.mouse_down
	clear_clicked := clear_hot && ctx.active == id && ctx.input.mouse_released
	body := gui_text_input_body_rect(bounds, clear_hit, clear_visible)
	text_pos := Vec2{bounds.x + ctx.style.control_padding * 1.5, bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0)}

	if editing {
		ctx.wants_text_input = true
		gui_text_edit_begin(ctx, id, length^)
		if clear_clicked {
			length^ = 0
			if len(buffer) > 0 {
				buffer[0] = 0
			}
			ctx.text_edit_caret = 0
			ctx.text_edit_anchor = 0
			ctx.text_edit_scroll_x = 0
			ctx.text_edit_blink = 0
			changed = true
			clear_visible = false
		} else if !(ctx.controller_explicit_activation && gui_accept_pressed(ctx)) {
			gui_text_edit_handle_mouse(ctx, id, buffer, length^, body, text_pos)
			changed = gui_text_edit_process(ctx, id, buffer, length) || changed
		}
		trailing_inset := clear_visible ? max(bounds.x + bounds.w - clear_hit.x, 0) : f32(0)
		edit_view := gui_inset_edges(bounds, {left = ctx.style.control_padding * 2, top = ctx.style.control_padding * 2, right = ctx.style.control_padding * 2 + trailing_inset, bottom = ctx.style.control_padding * 2})
		gui_text_edit_keep_caret_visible(ctx, buffer, length^, edit_view)
	} else if ctx.text_edit_id == id {
		ctx.text_edit_id = GUI_ID_NONE
		ctx.text_edit_selecting = false
	}

	gui_text_field_chrome(ctx, bounds, ctx.active == id || editing, ctx.hot == id, control.focused)
	gui_focus_or_edit_ring(ctx, id, bounds)
	trailing_inset := clear_visible ? max(bounds.x + bounds.w - clear_hit.x, 0) : f32(0)
	gui_text_edit_draw(ctx, bounds, text_pos, buffer, length^, label, editing, trailing_inset)
	if clear_visible {
		gui_text_input_draw_clear_button(ctx, clear_visual, clear_hot, clear_active)
	}
	return changed
}

gui_selector :: gui_selector_keyed
