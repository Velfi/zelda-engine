package ui

import "core:math"
import "core:fmt"
import "core:strconv"
import "core:sync"
import "core:time"

gui_controller_edit_clear_snapshot :: proc(ctx: ^Gui_Context, id: Gui_Id) {
	if ctx.controller_snapshot_id == id {
		ctx.controller_snapshot_id = GUI_ID_NONE
		ctx.controller_snapshot_kind = .None
	}
	if ctx.controller_cancel_id == id {
		ctx.controller_cancel_id = GUI_ID_NONE
	}
}

gui_controller_edit_f32 :: proc(ctx: ^Gui_Context, id: Gui_Id, value: ^f32) {
	if ctx.controller_cancel_id == id && ctx.controller_snapshot_id == id && ctx.controller_snapshot_kind == .Float {
		value^ = ctx.controller_snapshot_f32
		gui_controller_edit_clear_snapshot(ctx, id)
		return
	}
	if ctx.focus_edit_id == id && ctx.controller_snapshot_id != id {
		ctx.controller_snapshot_id = id
		ctx.controller_snapshot_kind = .Float
		ctx.controller_snapshot_f32 = value^
	}
}

gui_controller_edit_int :: proc(ctx: ^Gui_Context, id: Gui_Id, value: ^int) {
	if ctx.controller_cancel_id == id && ctx.controller_snapshot_id == id && ctx.controller_snapshot_kind == .Integer {
		value^ = ctx.controller_snapshot_int
		gui_controller_edit_clear_snapshot(ctx, id)
		return
	}
	if ctx.focus_edit_id == id && ctx.controller_snapshot_id != id {
		ctx.controller_snapshot_id = id
		ctx.controller_snapshot_kind = .Integer
		ctx.controller_snapshot_int = value^
	}
}

gui_controller_edit_bool :: proc(ctx: ^Gui_Context, id: Gui_Id, value: ^bool) {
	if ctx.controller_cancel_id == id && ctx.controller_snapshot_id == id && ctx.controller_snapshot_kind == .Boolean {
		value^ = ctx.controller_snapshot_bool
		gui_controller_edit_clear_snapshot(ctx, id)
		return
	}
	if ctx.focus_edit_id == id && ctx.controller_snapshot_id != id {
		ctx.controller_snapshot_id = id
		ctx.controller_snapshot_kind = .Boolean
		ctx.controller_snapshot_bool = value^
	}
}

gui_controller_edit_text :: proc(ctx: ^Gui_Context, id: Gui_Id, buffer: []u8, length: ^int) {
	if ctx.controller_cancel_id == id && ctx.controller_snapshot_id == id && ctx.controller_snapshot_kind == .Text {
		length^ = min(ctx.controller_snapshot_text_len, len(buffer))
		for i in 0 ..< length^ {
			buffer[i] = ctx.controller_snapshot_text[i]
		}
		if length^ < len(buffer) {
			buffer[length^] = 0
		}
		gui_controller_edit_clear_snapshot(ctx, id)
		return
	}
	if ctx.focus_edit_id == id && ctx.controller_snapshot_id != id {
		ctx.controller_snapshot_id = id
		ctx.controller_snapshot_kind = .Text
		ctx.controller_snapshot_text_len = min(length^, min(len(buffer), len(ctx.controller_snapshot_text)))
		for i in 0 ..< ctx.controller_snapshot_text_len {
			ctx.controller_snapshot_text[i] = buffer[i]
		}
	}
}

gui_controller_edit_vec2 :: proc(ctx: ^Gui_Context, id: Gui_Id, value: ^Vec2) {
	if ctx.controller_cancel_id == id && ctx.controller_snapshot_id == id && ctx.controller_snapshot_kind == .Vec2 {
		value^ = ctx.controller_snapshot_vec2
		gui_controller_edit_clear_snapshot(ctx, id)
		return
	}
	if ctx.focus_edit_id == id && ctx.controller_snapshot_id != id {
		ctx.controller_snapshot_id = id
		ctx.controller_snapshot_kind = .Vec2
		ctx.controller_snapshot_vec2 = value^
	}
}

gui_controller_edit_hsv :: proc(ctx: ^Gui_Context, id: Gui_Id, value: ^Hsv_Color) {
	if ctx.controller_cancel_id == id && ctx.controller_snapshot_id == id && ctx.controller_snapshot_kind == .Hsv {
		value^ = ctx.controller_snapshot_hsv
		gui_controller_edit_clear_snapshot(ctx, id)
		return
	}
	if ctx.focus_edit_id == id && ctx.controller_snapshot_id != id {
		ctx.controller_snapshot_id = id
		ctx.controller_snapshot_kind = .Hsv
		ctx.controller_snapshot_hsv = value^
	}
}

gui_update_focus_edit :: proc(ctx: ^Gui_Context, id: Gui_Id, focused: bool) -> bool {
	if !focused {
		if ctx.controller_armed_id == id {
			ctx.controller_armed_id = GUI_ID_NONE
		}
		gui_controller_edit_clear_snapshot(ctx, id)
		gui_focus_edit_end(ctx, id)
		return false
	}
	if ctx.controller_explicit_activation {
		if ctx.focus_edit_id == id {
			if gui_accept_pressed(ctx) || ctx.input.back {
				if ctx.input.back {
					ctx.controller_cancel_id = id
				} else {
					gui_controller_edit_clear_snapshot(ctx, id)
				}
				gui_focus_edit_end(ctx, id)
				ctx.controller_armed_id = GUI_ID_NONE
				return false
			}
			ctx.focus_edit_seen = true
			return true
		}
		if gui_accept_pressed(ctx) {
			gui_focus_edit_begin(ctx, id)
			ctx.controller_armed_id = id
			ctx.focus_edit_seen = true
			return true
		}
		return false
	}
	if ctx.focus_edit_id == id {
		if gui_accept_pressed(ctx) || ctx.input.back {
			if ctx.input.back {
				ctx.controller_cancel_id = id
			} else {
				gui_controller_edit_clear_snapshot(ctx, id)
			}
			gui_focus_edit_end(ctx, id)
			return false
		}
		ctx.focus_edit_seen = true
		return true
	}
	if gui_accept_pressed(ctx) || ctx.input.key_space {
		gui_focus_edit_begin(ctx, id)
	}
	if ctx.focus_edit_id == id {
		ctx.focus_edit_seen = true
	}
	return ctx.focus_edit_id == id
}

gui_register_focusable :: proc(ctx: ^Gui_Context, id: Gui_Id, bounds := Rect{}) {
	gui_debug_register_interactive_id(ctx, id)
	if bounds.w > 0 && bounds.h > 0 {
		gui_register_spatial_item(ctx, id, bounds, true)
	}
}

gui_button_behavior :: proc(ctx: ^Gui_Context, id: Gui_Id, bounds: Rect, enabled: bool) -> bool {
	control := gui_control(ctx, id, bounds, enabled)
	// Buttons, toggles, checkboxes, and radio choices are immediate actions.
	// Explicit engagement is reserved for controls with an editable value or
	// nested interaction mode (sliders, selectors, text fields, canvases).
	if ctx.controller_explicit_activation && control.focused && gui_accept_pressed(ctx) {
		return true
	}
	return control.activated || (enabled && control.hovered && ctx.active == id && ctx.input.mouse_released)
}

gui_drag_region :: proc(ctx: ^Gui_Context, id: Gui_Id, bounds: Rect) -> bool {
	control := gui_control(ctx, id, bounds, true)
	_ = control
	return ctx.active == id && ctx.input.mouse_down
}

gui_drag_handle_region :: proc(ctx: ^Gui_Context, id: Gui_Id, bounds: Rect, handle: Vec2, handle_radius: f32) -> bool {
	gui_register_focusable(ctx, id, bounds)
	hovered := gui_mouse_contains(ctx, bounds) || gui_mouse_contains_circle(ctx, handle, handle_radius)
	if hovered {
		ctx.hot = id
		if ctx.input.mouse_pressed {
			ctx.active = id
			ctx.focused = id
		}
	}
	return ctx.active == id && ctx.input.mouse_down
}

gui_debug_register_interactive_id :: proc(ctx: ^Gui_Context, id: Gui_Id) {
	if id == GUI_ID_NONE {
		return
	}
	for i in 0 ..< ctx.debug_registered_id_count {
		if ctx.debug_registered_ids[i] == id {
			ctx.debug_duplicate_id_count += 1
			return
		}
	}
	if ctx.debug_registered_id_count < len(ctx.debug_registered_ids) {
		ctx.debug_registered_ids[ctx.debug_registered_id_count] = id
		ctx.debug_registered_id_count += 1
	}
}

gui_rect_point_to_normalized :: proc(rect: Rect, point: Vec2) -> Vec2 {
	return {
		gui_clamp01((point.x - rect.x) / max(rect.w, 1)),
		gui_clamp01((point.y - rect.y) / max(rect.h, 1)),
	}
}

gui_normalized_to_rect_point :: proc(rect: Rect, value: Vec2) -> Vec2 {
	return {
		rect.x + rect.w * gui_clamp01(value.x),
		rect.y + rect.h * gui_clamp01(value.y),
	}
}

gui_vec2_to_normalized :: proc(value, min_value, max_value: Vec2) -> Vec2 {
	return {
		gui_clamp01((value.x - min_value.x) / max(max_value.x - min_value.x, 0.000001)),
		gui_clamp01((value.y - min_value.y) / max(max_value.y - min_value.y, 0.000001)),
	}
}

gui_vec2_from_normalized :: proc(value, min_value, max_value: Vec2) -> Vec2 {
	n := Vec2{gui_clamp01(value.x), gui_clamp01(value.y)}
	return {
		min_value.x + (max_value.x - min_value.x) * n.x,
		min_value.y + (max_value.y - min_value.y) * n.y,
	}
}

gui_draw_handle :: proc(ctx: ^Gui_Context, center: Vec2, radius: f32) {
	rect := Rect{center.x - radius, center.y - radius, radius * 2, radius * 2}
	gui_ellipse(ctx, rect, ctx.style.text)
	gui_ellipse_stroke(ctx, rect, ctx.style.panel_border, ctx.style.border_width)
	gui_ellipse_stroke(ctx, gui_inset(rect, -ctx.style.focus_ring_width), ctx.style.accent, ctx.style.focus_ring_width)
}

gui_draw_checker_grid :: proc(ctx: ^Gui_Context, rect: Rect) {
	cols := 8
	rows := 6
	for y in 0 ..< rows {
		for x in 0 ..< cols {
			t := ((x + y) % 2 == 0) ? f32(0.16) : f32(0.23)
			color := Color{t, t + 0.015, t + 0.025, 1}
			gui_rect(ctx, {
				rect.x + rect.w * f32(x) / f32(cols),
				rect.y + rect.h * f32(y) / f32(rows),
				rect.w / f32(cols) + 1,
				rect.h / f32(rows) + 1,
			}, color)
		}
	}
}

gui_wrap01 :: proc(v: f32) -> f32 {
	result := v
	for result < 0 {
		result += 1
	}
	for result >= 1 {
		result -= 1
	}
	return result
}

gui_hue_from_delta :: proc(delta: Vec2) -> f32 {
	angle := math.atan2(delta.y, delta.x)
	if angle < 0 {
		angle += GUI_TAU
	}
	return gui_wrap01(angle / GUI_TAU)
}

gui_hsv_to_rgb :: proc(hsv: Hsv_Color) -> Color {
	h := gui_wrap01(hsv.h) * 6
	s := gui_clamp01(hsv.s)
	v := gui_clamp01(hsv.v)
	c := v * s
	x := c * (1 - abs((h - f32(int(h / 2) * 2)) - 1))
	m := v - c
	r, g, b: f32
	if h < 1 {
		r, g, b = c, x, 0
	} else if h < 2 {
		r, g, b = x, c, 0
	} else if h < 3 {
		r, g, b = 0, c, x
	} else if h < 4 {
		r, g, b = 0, x, c
	} else if h < 5 {
		r, g, b = x, 0, c
	} else {
		r, g, b = c, 0, x
	}
	return {r + m, g + m, b + m, gui_clamp01(hsv.a)}
}

gui_rgb_to_hsv :: proc(color: Color) -> Hsv_Color {
	r := gui_clamp01(color.r)
	g := gui_clamp01(color.g)
	b := gui_clamp01(color.b)
	max_c := max(max(r, g), b)
	min_c := min(min(r, g), b)
	delta := max_c - min_c
	h := f32(0)
	if delta > 0.000001 {
		if max_c == r {
			h = ((g - b) / delta)
			if h < 0 {
				h += 6
			}
		} else if max_c == g {
			h = (b - r) / delta + 2
		} else {
			h = (r - g) / delta + 4
		}
		h /= 6
	}
	s := max_c <= 0 ? f32(0) : delta / max_c
	return {gui_wrap01(h), gui_clamp01(s), gui_clamp01(max_c), gui_clamp01(color.a)}
}

gui_clear_query :: proc(buffer: []u8) {
	if len(buffer) > 0 {
		buffer[0] = 0
	}
}

gui_query_len :: proc(buffer: []u8) -> int {
	n := 0
	for n < len(buffer) && buffer[n] != 0 {
		n += 1
	}
	return n
}

gui_query_string :: proc(buffer: []u8) -> string {
	n := gui_query_len(buffer)
	return string(buffer[:n])
}

gui_append_query :: proc(buffer: []u8, text: []u8) {
	n := gui_query_len(buffer)
	for ch in text {
		if ch == 0 || n >= len(buffer) - 1 {
			break
		}
		buffer[n] = ch
		n += 1
	}
	if len(buffer) > 0 {
		buffer[n] = 0
	}
}

gui_pop_query :: proc(buffer: []u8) {
	n := gui_query_len(buffer)
	if n > 0 {
		buffer[n - 1] = 0
	}
}

gui_string_contains_fold :: proc(haystack, needle: string) -> bool {
	h := transmute([]u8)haystack
	n := transmute([]u8)needle
	if len(n) == 0 {
		return true
	}
	if len(n) > len(h) {
		return false
	}
	for start in 0 ..= len(h) - len(n) {
		matched := true
		for i in 0 ..< len(n) {
			if gui_ascii_fold(h[start + i]) != gui_ascii_fold(n[i]) {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

gui_ascii_fold :: proc(ch: u8) -> u8 {
	if ch >= 'A' && ch <= 'Z' {
		return ch + ('a' - 'A')
	}
	return ch
}

gui_next_match :: proc(matches: []int, current, direction: int) -> int {
	if len(matches) == 0 {
		return -1
	}
	index := 0
	for i in 0 ..< len(matches) {
		if matches[i] == current {
			index = i
			break
		}
	}
	index += direction
	if index < 0 {
		index = len(matches) - 1
	}
	if index >= len(matches) {
		index = 0
	}
	return matches[index]
}

gui_match_contains :: proc(matches: []int, value: int) -> bool {
	for match in matches {
		if match == value {
			return true
		}
	}
	return false
}

gui_numeric_edit_f32 :: proc(ctx: ^Gui_Context, id: Gui_Id, value: ^f32, min_value, max_value: f32) -> bool {
	if ctx.input.back {
		if ctx.numeric_edit_snapshot_id == id {
			value^ = ctx.numeric_edit_snapshot_value
		}
		ctx.numeric_edit_snapshot_id = GUI_ID_NONE
		ctx.text_edit_id = GUI_ID_NONE
		ctx.text_edit_len = 0
		return false
	}
	if ctx.input.accept {
		ctx.numeric_edit_snapshot_id = GUI_ID_NONE
		ctx.text_edit_id = GUI_ID_NONE
		ctx.text_edit_len = 0
		return false
	}

	if ctx.text_edit_id != id {
		gui_numeric_edit_begin(ctx, id, value^)
	}
	edited := gui_text_edit_process(ctx, id, ctx.text_edit_buffer[:], &ctx.text_edit_len, true)

	if ctx.text_edit_len == 0 {
		return edited
	}
	parsed, ok := strconv.parse_f32(string(ctx.text_edit_buffer[:ctx.text_edit_len]))
	if !ok {
		return edited
	}
	clamped := min(max(parsed, min_value), max_value)
	if value^ == clamped {
		return edited
	}
	value^ = clamped
	return true
}

gui_numeric_edit_begin :: proc(ctx: ^Gui_Context, id: Gui_Id, value: f32) {
	if ctx.numeric_edit_snapshot_id != id {
		ctx.numeric_edit_snapshot_id = id
		ctx.numeric_edit_snapshot_value = value
	}
	ctx.text_edit_id = id
	gui_numeric_edit_set_value(ctx, value)
	ctx.text_edit_caret = ctx.text_edit_len
	ctx.text_edit_anchor = 0
	ctx.text_edit_scroll_x = 0
	ctx.text_edit_blink = 0
	ctx.text_edit_selecting = false
}

gui_numeric_edit_wants_text :: proc(ctx: ^Gui_Context) -> bool {
	modifier := ctx.input.key_ctrl || ctx.input.key_super
	if ctx.input.text_input_len > 0 {
		return true
	}
	if ctx.input.accept || ctx.input.key_backspace || ctx.input.key_delete {
		return true
	}
	if modifier && (ctx.input.key_a || ctx.input.key_v || ctx.input.key_x || ctx.input.key_c) {
		return true
	}
	return false
}

gui_numeric_edit_set_value :: proc(ctx: ^Gui_Context, value: f32) {
	buf: [64]u8
	text := fmt.bprintf(buf[:], "%.3f", value)
	ctx.text_edit_len = min(len(text), len(ctx.text_edit_buffer))
	copy(ctx.text_edit_buffer[:], transmute([]u8)text[:ctx.text_edit_len])
	for ctx.text_edit_len > 0 && ctx.text_edit_buffer[ctx.text_edit_len - 1] == '0' {
		ctx.text_edit_len -= 1
	}
	if ctx.text_edit_len > 0 && ctx.text_edit_buffer[ctx.text_edit_len - 1] == '.' {
		ctx.text_edit_len -= 1
	}
}

gui_numeric_edit_accepts_char :: proc(ch: u8) -> bool {
	switch ch {
	case '0'..='9', '-', '+', '.', 'e', 'E':
		return true
	}
	return false
}

gui_utf8_is_continuation :: proc(ch: u8) -> bool {
	return (ch & 0xC0) == 0x80
}

gui_utf8_clamp_index :: proc(index, length: int) -> int {
	return max(min(index, length), 0)
}

gui_utf8_prev_index :: proc(bytes: []u8, index: int) -> int {
	cursor := max(min(index, len(bytes)), 0)
	if cursor <= 0 {
		return 0
	}
	cursor -= 1
	for cursor > 0 && gui_utf8_is_continuation(bytes[cursor]) {
		cursor -= 1
	}
	return cursor
}

gui_utf8_next_index :: proc(bytes: []u8, index: int) -> int {
	cursor := max(min(index, len(bytes)), 0)
	if cursor >= len(bytes) {
		return len(bytes)
	}
	cursor += 1
	for cursor < len(bytes) && gui_utf8_is_continuation(bytes[cursor]) {
		cursor += 1
	}
	return cursor
}

gui_push_id :: proc(ctx: ^Gui_Context, key: string) {
	if ctx.id_depth >= MAX_GUI_ID_DEPTH {
		return
	}
	ctx.id_stack[ctx.id_depth] = gui_make_id(ctx, key)
	ctx.id_depth += 1
}

gui_push_id_int :: proc(ctx: ^Gui_Context, key: int) {
	if ctx.id_depth >= MAX_GUI_ID_DEPTH {
		return
	}
	ctx.id_stack[ctx.id_depth] = gui_make_id_int(ctx, key)
	ctx.id_depth += 1
}

gui_push_id_ptr :: proc(ctx: ^Gui_Context, key: rawptr) {
	if ctx.id_depth >= MAX_GUI_ID_DEPTH {
		return
	}
	ctx.id_stack[ctx.id_depth] = gui_make_id_ptr(ctx, key)
	ctx.id_depth += 1
}

gui_pop_id :: proc(ctx: ^Gui_Context) {
	if ctx.id_depth > 0 {
		ctx.id_depth -= 1
	}
}

gui_current_id :: proc(ctx: ^Gui_Context) -> Gui_Id {
	if ctx.id_depth <= 0 {
		return GUI_ID_NONE
	}
	return ctx.id_stack[ctx.id_depth - 1]
}

gui_make_id :: proc(ctx: ^Gui_Context, key: string) -> Gui_Id {
	hash := gui_id_seed(ctx)
	hash = gui_hash_byte(hash, 's')
	for ch in transmute([]u8)key {
		hash = gui_hash_byte(hash, ch)
	}
	return gui_id_finish(hash)
}

gui_make_id_int :: proc(ctx: ^Gui_Context, key: int) -> Gui_Id {
	hash := gui_id_seed(ctx)
	hash = gui_hash_byte(hash, 'i')
	return gui_id_finish(gui_hash_u64(hash, u64(key)))
}

gui_make_id_ptr :: proc(ctx: ^Gui_Context, key: rawptr) -> Gui_Id {
	hash := gui_id_seed(ctx)
	hash = gui_hash_byte(hash, 'p')
	return gui_id_finish(gui_hash_u64(hash, u64(uintptr(key))))
}

gui_id_index :: proc(ctx: ^Gui_Context, key: string, index: int) -> Gui_Id {
	return gui_id_child_int(gui_make_id(ctx, key), index)
}

gui_id_child :: proc(parent: Gui_Id, key: string) -> Gui_Id {
	hash := gui_hash_byte(u64(parent), 'c')
	for ch in transmute([]u8)key {
		hash = gui_hash_byte(hash, ch)
	}
	return gui_id_finish(hash)
}

gui_id_child_int :: proc(parent: Gui_Id, key: int) -> Gui_Id {
	hash := gui_hash_byte(u64(parent), 'n')
	return gui_id_finish(gui_hash_u64(hash, u64(key)))
}

gui_id_seed :: proc(ctx: ^Gui_Context) -> u64 {
	parent := gui_current_id(ctx)
	if parent == GUI_ID_NONE {
		return 14695981039346656037
	}
	return u64(parent)
}

gui_hash_byte :: proc(hash: u64, ch: u8) -> u64 {
	return (hash ~ u64(ch)) * 1099511628211
}

gui_hash_u64 :: proc(hash: u64, value: u64) -> u64 {
	h := hash
	v := value
	for _ in 0 ..< 8 {
		h = gui_hash_byte(h, u8(v & 0xff))
		v >>= 8
	}
	return h
}

gui_id_finish :: proc(hash: u64) -> Gui_Id {
	h := hash
	if h == 0 {
		h = 1
	}
	return Gui_Id(h)
}
