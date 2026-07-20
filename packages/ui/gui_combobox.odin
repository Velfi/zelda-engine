package ui

import "core:math"
import "core:fmt"
import "core:strconv"

gui_circular_progress :: proc(ctx: ^Gui_Context, label: string, value: f32) {
	bounds := gui_next_rect(ctx, height = 92)
	size := min(bounds.h - 8, bounds.w * 0.38)
	rect := Rect{bounds.x + 6, bounds.y + (bounds.h - size) * 0.5, size, size}
	gui_shader_rect(ctx, rect, .Circular_Progress, {gui_clamp01(value), 0.72, 0, 1}, ctx.style.accent)
	gui_text_clipped(ctx, {bounds.x + size + 18, bounds.y, max(bounds.w - size - 18, 0), bounds.h}, {bounds.x + size + 24, bounds.y + 28}, label, ctx.style.text)
}

gui_combobox :: gui_combobox_keyed

// Cycles a closed combobox from either navigation axis. Composite controls can
// use this with pointer-only side arrows so they still behave as one input for
// keyboard and controller focus.
gui_combobox_cycle_focused :: proc(ctx: ^Gui_Context, id: Gui_Id, current: ^int, option_count: int) -> bool {
	if option_count <= 0 || ctx.focused != id || ctx.open_panel == id {
		return false
	}
	delta := 0
	if ctx.input.nav_pressed_x < 0 || ctx.input.nav_pressed_y < 0 {
		delta = -1
	} else if ctx.input.nav_pressed_x > 0 || ctx.input.nav_pressed_y > 0 {
		delta = 1
	}
	if delta == 0 {
		return false
	}
	current^ = (current^ + delta + option_count) % option_count
	return true
}

gui_stepper_button_at :: proc(ctx: ^Gui_Context, id: Gui_Id, bounds: Rect, direction: int, enabled: bool, focusable := true) -> bool {
	control := gui_control(ctx, id, bounds, enabled, focusable)
	fill := ctx.style.control
	border := ctx.style.panel_border
	if !enabled {
		fill = ctx.style.control_disabled
	} else if ctx.active == id {
		fill = ctx.style.control_active
		border = gui_apply_opacity(ctx.style.accent, 0.64)
	} else if ctx.hot == id || control.focused {
		fill = ctx.style.control_hot
		border = gui_apply_opacity(ctx.style.text, 0.46)
	}
	gui_round_rect(ctx, bounds, ctx.style.radius_control, fill)
	gui_round_stroke(ctx, bounds, ctx.style.radius_control, border, ctx.style.border_width)
	center := Vec2{bounds.x + bounds.w * 0.5, bounds.y + bounds.h * 0.5}
	size := max(min(bounds.w, bounds.h) * 0.16, 5)
	x := size * 0.42
	if direction < 0 {
		gui_line(ctx, {center.x + x, center.y - size}, {center.x - x, center.y}, ctx.style.text_muted, ctx.style.border_width * 2)
		gui_line(ctx, {center.x - x, center.y}, {center.x + x, center.y + size}, ctx.style.text_muted, ctx.style.border_width * 2)
	} else {
		gui_line(ctx, {center.x - x, center.y - size}, {center.x + x, center.y}, ctx.style.text_muted, ctx.style.border_width * 2)
		gui_line(ctx, {center.x + x, center.y}, {center.x - x, center.y + size}, ctx.style.text_muted, ctx.style.border_width * 2)
	}
	if control.focused {
		gui_focus_ring(ctx, bounds)
	}
	return control.activated || (enabled && control.hovered && ctx.active == id && ctx.input.mouse_released)
}

// A selector with pointer-friendly previous/next buttons and a searchable
// center dropdown. In explicit controller mode, focus only identifies the
// navigation destination; Accept engages the selector before D-pad input can
// change its value. The dropdown remains available through pointer input.
gui_stepper_combobox :: proc(
	ctx: ^Gui_Context,
	label, key: string,
	current: ^int,
	options: []string,
	query_buffer: []u8,
	previous_tooltip := "Previous option",
	next_tooltip := "Next option",
) -> bool {
	if len(options) == 0 {
		return false
	}
	id := gui_make_id(ctx, key)
	row := gui_next_rect(ctx)
	current^ = max(min(current^, len(options) - 1), 0)
	value_before := current^
	arrow_w := min(max(row.h, f32(35)), row.w * 0.22)
	left := Rect{row.x, row.y, arrow_w, row.h}
	right := Rect{row.x + row.w - arrow_w, row.y, arrow_w, row.h}
	center := Rect{row.x + arrow_w, row.y, max(row.w - arrow_w * 2, 0), row.h}
	changed := false

	if gui_stepper_button_at(ctx, gui_id_child(id, "previous"), left, -1, true, false) {
		ctx.focused = id
		current^ = (current^ - 1 + len(options)) % len(options)
		changed = true
	}
	gui_tooltip(ctx, left, previous_tooltip)

	if gui_stepper_button_at(ctx, gui_id_child(id, "next"), right, 1, true, false) {
		ctx.focused = id
		current^ = (current^ + 1) % len(options)
		changed = true
	}
	gui_tooltip(ctx, right, next_tooltip)

	if ctx.controller_explicit_activation {
		editing := gui_update_focus_edit(ctx, id, ctx.focused == id)
		gui_controller_edit_int(ctx, id, current)
		if editing {
			nav_x, nav_y := gui_focused_nav_pressed(ctx, id)
			if nav_x != 0 || nav_y != 0 {
				delta := int(nav_x + nav_y)
				current^ = (current^ + delta + len(options)) % len(options)
				changed = true
			}
		}
	} else {
		changed = gui_combobox_cycle_focused(ctx, id, current, len(options)) || changed
	}

	gui_layout_begin(ctx, center, .Column, 0, center.h)
	changed = gui_combobox_keyed(ctx, label, key, current, options, query_buffer, false) || changed
	gui_layout_end(ctx)
	gui_focus_or_edit_ring(ctx, id, center)
	// Cancellation restores the snapshot inside gui_controller_edit_int. Report
	// that restoration so callers can re-apply runtime-backed selections.
	return changed || current^ != value_before
}

gui_select_chrome :: proc(ctx: ^Gui_Context, bounds: Rect, display: string, id: Gui_Id, open, focused: bool) {
	fill := ctx.style.control
	border := ctx.style.panel_border
	stroke_width := ctx.style.border_width
	if open || ctx.active == id || ctx.focus_edit_id == id {
		fill = ctx.style.control_active
		border = gui_apply_opacity(ctx.style.accent, 0.64)
		stroke_width = max(ctx.style.border_width * 2, 2)
	} else if ctx.hot == id || focused {
		fill = ctx.style.control_hot
		border = gui_apply_opacity(ctx.style.text, 0.46)
	}

	gui_shadow(ctx, bounds, ctx.style.radius_control, ctx.style.shadow_offset, ctx.style.shadow_blur * 0.72, {0, 0, 0, 0.18})
	gui_round_rect(ctx, bounds, ctx.style.radius_control, fill)
	gui_round_stroke(ctx, bounds, ctx.style.radius_control, border, stroke_width)
	text_rect := gui_inset_edges(bounds, {left = ctx.style.control_padding * 1.5, top = 0, right = bounds.h, bottom = 0})
	gui_text_clipped(ctx, text_rect, {text_rect.x, bounds.y + max((bounds.h - ctx.style.body_text_height) * 0.5, 0)}, display, ctx.style.text)
	icon_center := Vec2{bounds.x + bounds.w - bounds.h * 0.5, bounds.y + bounds.h * 0.5}
	gui_chevron(ctx, icon_center, max(bounds.h * 0.16, 5), open, ctx.style.text_muted)
}

gui_chevron :: proc(ctx: ^Gui_Context, center: Vec2, size: f32, up: bool, color: Color) {
	half := size
	y := size * 0.36
	if up {
		gui_line(ctx, {center.x - half, center.y + y}, {center.x, center.y - y}, color, ctx.style.border_width * 2)
		gui_line(ctx, {center.x, center.y - y}, {center.x + half, center.y + y}, color, ctx.style.border_width * 2)
	} else {
		gui_line(ctx, {center.x - half, center.y - y}, {center.x, center.y + y}, color, ctx.style.border_width * 2)
		gui_line(ctx, {center.x, center.y + y}, {center.x + half, center.y - y}, color, ctx.style.border_width * 2)
	}
}

gui_combo_popup_rect :: proc(ctx: ^Gui_Context, bounds: Rect, options: []string, query: string, match_count, selected_index: int) -> Rect {
	query_height := len(query) > 0 ? ctx.style.row_height : f32(0)
	visible_rows := min(max(match_count, 1), GUI_COMBO_SHORT_POPUP_ROWS)
	list_height := f32(visible_rows) * ctx.style.row_height
	width := max(bounds.w, gui_combo_popup_content_width(ctx, options))
	max_width := f32(ctx.input.window_width) > 0 ? max(f32(ctx.input.window_width) - ctx.style.spacing_1 * 2, bounds.w) : width
	width = min(width, max_width)
	popup_height := query_height + list_height

	below := Rect{bounds.x, bounds.y + bounds.h + ctx.style.spacing_1, width, popup_height}
	if ctx.input.window_height <= 0 {
		return below
	}
	margin := ctx.style.spacing_1
	viewport_h := max(f32(ctx.input.window_height) - margin * 2, 0)
	if match_count > GUI_COMBO_SHORT_POPUP_ROWS && viewport_h > 0 {
		content_height := f32(max(match_count, 1)) * ctx.style.row_height
		popup_height = min(query_height + content_height, viewport_h)
		popup_height = max(popup_height, min(query_height + ctx.style.row_height, viewport_h))
		selected_rank := gui_combo_match_rank(options, query, selected_index)
		selected_center_y := bounds.y + bounds.h * 0.5
		y := selected_center_y - query_height - (f32(selected_rank) + 0.5) * ctx.style.row_height
		return gui_overlay_nudge_into_view(ctx, {bounds.x, y, width, popup_height})
	}

	space_below := f32(ctx.input.window_height) - margin - (bounds.y + bounds.h + ctx.style.spacing_1)
	space_above := bounds.y - ctx.style.spacing_1 - margin
	if space_below < popup_height && space_above > space_below {
		above_h := min(popup_height, max(space_above, ctx.style.row_height))
		return gui_overlay_nudge_into_view(ctx, {bounds.x, bounds.y - ctx.style.spacing_1 - above_h, width, above_h})
	}
	return gui_overlay_nudge_into_view(ctx, below)
}

gui_combo_popup_content_width :: proc(ctx: ^Gui_Context, options: []string) -> f32 {
	width := f32(0)
	for option in options {
		width = max(width, gui_text_width(ctx, option))
	}
	return width + ctx.style.control_padding * 4 + gui_scrollbar_reserved_width(ctx)
}

gui_combo_match_count :: proc(options: []string, query: string) -> int {
	count := 0
	for option in options {
		if gui_string_contains_fold(option, query) {
			count += 1
		}
	}
	return count
}

gui_combo_match_rank :: proc(options: []string, query: string, selected_index: int) -> int {
	rank := 0
	for option, i in options {
		if !gui_string_contains_fold(option, query) {
			continue
		}
		if i == selected_index {
			return rank
		}
		rank += 1
	}
	return 0
}

gui_combo_scroll_highlight_into_view :: proc(ctx: ^Gui_Context, matches: []int, viewport_height: f32) {
	if ctx.combo_highlight < 0 || viewport_height <= 0 {
		return
	}
	highlight_index := -1
	for match, i in matches {
		if match == ctx.combo_highlight {
			highlight_index = i
			break
		}
	}
	if highlight_index < 0 {
		return
	}
	row_top := f32(highlight_index) * ctx.style.row_height
	row_bottom := row_top + ctx.style.row_height
	if row_top < ctx.combo_scroll {
		ctx.combo_scroll = row_top
	} else if row_bottom > ctx.combo_scroll + viewport_height {
		ctx.combo_scroll = row_bottom - viewport_height
	}
}

gui_combo_scroll_highlight_to_anchor :: proc(ctx: ^Gui_Context, matches: []int, list_viewport: Rect, bounds: Rect) {
	if ctx.combo_highlight < 0 || list_viewport.h <= 0 {
		return
	}
	highlight_index := -1
	for match, i in matches {
		if match == ctx.combo_highlight {
			highlight_index = i
			break
		}
	}
	if highlight_index < 0 {
		return
	}
	content_height := f32(len(matches)) * ctx.style.row_height
	max_scroll := max(content_height - list_viewport.h, 0)
	anchor_center_y := bounds.y + bounds.h * 0.5
	row_center := f32(highlight_index) * ctx.style.row_height + ctx.style.row_height * 0.5
	ctx.combo_scroll = min(max(row_center - (anchor_center_y - list_viewport.y), 0), max_scroll)
}

gui_combobox_keyed :: proc(ctx: ^Gui_Context, label, key: string, current: ^int, options: []string, query_buffer: []u8, focus_accept_opens := true) -> bool {
	if len(options) == 0 {
		return false
	}
	id := gui_make_id(ctx, key)
	bounds := gui_next_rect(ctx)
	current^ = max(min(current^, len(options) - 1), 0)
	changed := false
	open := ctx.open_panel == id
	opened_this_frame := false
	control := gui_control(ctx, id, bounds, true)
	accept_pressed := gui_accept_pressed(ctx)
	clicked := (focus_accept_opens && control.focused && accept_pressed) || (control.hovered && ctx.active == id && ctx.input.mouse_released)
	if open && accept_pressed {
		clicked = false
	}
	if open && clicked {
		query := gui_query_string(query_buffer)
		matches_count := gui_combo_match_count(options, query)
		popup := gui_combo_popup_rect(ctx, bounds, options, query, matches_count, current^)
		if gui_contains(popup, ctx.input.mouse_pos) {
			clicked = false
		}
	}
	if !open && control.focused && ctx.input.key_space {
		clicked = true
	}
	if clicked {
		if open {
			ctx.open_panel = GUI_ID_NONE
		} else {
			ctx.open_panel = id
			ctx.focused = id
			ctx.combo_highlight = max(min(current^, len(options) - 1), 0)
			ctx.combo_scroll = 0
			gui_clear_query(query_buffer)
			opened_this_frame = true
		}
		open = ctx.open_panel == id
	}
	if open && ctx.input.mouse_pressed && !gui_contains(bounds, ctx.input.mouse_pos) {
		query := gui_query_string(query_buffer)
		matches_count := gui_combo_match_count(options, query)
		popup := gui_combo_popup_rect(ctx, bounds, options, query, matches_count, current^)
		if !gui_contains(popup, ctx.input.mouse_pos) {
			ctx.open_panel = GUI_ID_NONE
			open = false
		}
	}

	display := label
	if current^ >= 0 && current^ < len(options) {
		display = options[current^]
	}
	gui_select_chrome(ctx, bounds, display, id, open, control.focused)

	if !open {
		return changed
	}
	ctx.wants_text_input = true

	query_changed := false
	if ctx.input.text_input_len > 0 {
		gui_append_query(query_buffer, ctx.input.text_input[:ctx.input.text_input_len])
		query_changed = true
	}
	if ctx.input.key_backspace {
		gui_pop_query(query_buffer)
		query_changed = true
	}
	if ctx.input.back {
		ctx.open_panel = GUI_ID_NONE
		return false
	}

	query := gui_query_string(query_buffer)
	if query_changed {
		ctx.combo_scroll = 0
	}
	matches := make([dynamic]int, 0, len(options))
	defer delete(matches)
	for option, i in options {
		if gui_string_contains_fold(option, query) {
			append(&matches, i)
		}
	}
	if len(matches) == 0 {
		ctx.combo_highlight = -1
	} else {
		if ctx.combo_highlight < 0 || !gui_match_contains(matches[:], ctx.combo_highlight) {
			ctx.combo_highlight = matches[0]
		}
		if !opened_this_frame && ctx.input.nav_pressed_y > 0 {
			ctx.combo_highlight = gui_next_match(matches[:], ctx.combo_highlight, 1)
		}
		if !opened_this_frame && ctx.input.nav_pressed_y < 0 {
			ctx.combo_highlight = gui_next_match(matches[:], ctx.combo_highlight, -1)
		}
		if !opened_this_frame && accept_pressed {
			current^ = ctx.combo_highlight
			ctx.open_panel = GUI_ID_NONE
			return true
		}
	}

	// Anchor long popups to the committed selection. Pointer hover and keyboard
	// navigation update combo_highlight; using that moving value for geometry
	// makes the entire popup jump beneath a stationary pointer every frame.
	popup := gui_combo_popup_rect(ctx, bounds, options, query, len(matches), current^)
	query_height := len(query) > 0 ? ctx.style.row_height : f32(0)
	list_viewport := Rect{popup.x, popup.y + query_height, popup.w, max(popup.h - query_height, 0)}
	content_height := f32(len(matches)) * ctx.style.row_height
	max_scroll := max(content_height - list_viewport.h, 0)
	if opened_this_frame && len(matches) > GUI_COMBO_SHORT_POPUP_ROWS {
		gui_combo_scroll_highlight_to_anchor(ctx, matches[:], list_viewport, bounds)
	} else {
		gui_combo_scroll_highlight_into_view(ctx, matches[:], list_viewport.h)
	}
	combo_scroll := ctx.combo_scroll
	_, _ = gui_apply_wheel_scroll(ctx, popup, &combo_scroll, max_scroll, ctx.style.row_height, ctx.scroll_depth)
	ctx.combo_scroll = combo_scroll
	ctx.combo_scroll = min(max(ctx.combo_scroll, 0), max_scroll)
	gui_record_scroll_hit(ctx, popup, ctx.combo_scroll, max_scroll, ctx.style.row_height, ctx.scroll_depth)
	gui_overlay_input_rect(ctx, popup)
	gui_set_combo_popup(ctx, id, popup, options, query)
	y := list_viewport.y - ctx.combo_scroll
	for match in matches {
		row := Rect{popup.x, y, popup.w, ctx.style.row_height}
		visible_row := y + ctx.style.row_height > list_viewport.y && y < list_viewport.y + list_viewport.h
		row_id := gui_id_child_int(id, match)
		if visible_row && !opened_this_frame && gui_pointer_enabled(ctx) && gui_contains(list_viewport, ctx.input.mouse_pos) && gui_contains(row, ctx.input.mouse_pos) {
			ctx.hot = row_id
			ctx.combo_highlight = match
			if ctx.input.mouse_released {
				current^ = match
				ctx.open_panel = GUI_ID_NONE
				changed = true
			}
		}
		y += ctx.style.row_height
		if y >= popup.y + popup.h {
			break
		}
	}
	return changed
}

gui_set_combo_popup :: proc(ctx: ^Gui_Context, id: Gui_Id, popup: Rect, options: []string, query: string) {
	ctx.combo_popup_visible = true
	ctx.combo_popup_id = id
	ctx.combo_popup_rect = popup
	ctx.combo_popup_options = options
	ctx.combo_popup_query_len = min(len(query), len(ctx.combo_popup_query))
	query_bytes := transmute([]u8)query
	for i in 0 ..< ctx.combo_popup_query_len {
		ctx.combo_popup_query[i] = query_bytes[i]
	}
	if ctx.combo_popup_query_len < len(ctx.combo_popup_query) {
		ctx.combo_popup_query[ctx.combo_popup_query_len] = 0
	}
}

gui_draw_combo_popup_overlay :: proc(ctx: ^Gui_Context) {
	if !ctx.combo_popup_visible || ctx.open_panel != ctx.combo_popup_id {
		return
	}
	popup := ctx.combo_popup_rect
	query := string(ctx.combo_popup_query[:ctx.combo_popup_query_len])
	gui_shadow(ctx, popup, ctx.style.radius_control, {0, 5}, 12, ctx.style.shadow_color)
	gui_round_rect(ctx, popup, ctx.style.radius_control, ctx.style.panel)
	gui_round_stroke(ctx, popup, ctx.style.radius_control, ctx.style.panel_border, ctx.style.border_width)
	gui_scissor_begin(ctx, popup)
	query_height := len(query) > 0 ? ctx.style.row_height : f32(0)
	if len(query) > 0 {
		query_row := Rect{popup.x, popup.y, popup.w, ctx.style.row_height}
		gui_round_rect(ctx, gui_inset(query_row, 3), ctx.style.radius_control, ctx.style.control)
		gui_text_clipped(ctx, gui_inset(query_row, 8), {query_row.x + 12, query_row.y + 6}, query, ctx.style.accent)
	}

	list_viewport := Rect{popup.x, popup.y + query_height, popup.w, max(popup.h - query_height, 0)}
	y := list_viewport.y - ctx.combo_scroll
	match_count := gui_combo_match_count(ctx.combo_popup_options, query)
	for option, match in ctx.combo_popup_options {
		if !gui_string_contains_fold(option, query) {
			continue
		}
		row := Rect{popup.x, y, popup.w, ctx.style.row_height}
		if y + ctx.style.row_height > list_viewport.y && y < list_viewport.y + list_viewport.h {
			if ctx.combo_highlight == match {
				gui_round_rect(ctx, gui_inset(row, 3), ctx.style.radius_control, ctx.style.control_hot)
			}
			text_left := row.x + ctx.style.control_padding * 1.5
			if match == ctx.combo_highlight {
				gui_rect(ctx, {row.x + 3, row.y + 7, max(ctx.style.border_width * 2, 2), max(row.h - 14, 1)}, ctx.style.accent)
			}
			gui_text_clipped(ctx, gui_inset_edges(row, {left = ctx.style.control_padding * 1.5, top = 0, right = gui_scrollbar_reserved_width(ctx) + ctx.style.control_padding, bottom = 0}), {text_left, row.y + max((row.h - ctx.style.body_text_height) * 0.5, 0)}, option, ctx.style.text)
		}
		y += ctx.style.row_height
		if y >= popup.y + popup.h {
			break
		}
	}
	if match_count == 0 {
		gui_text_clipped(ctx, gui_inset(popup, 8), {popup.x + 12, popup.y + 6}, "No matches", ctx.style.text_muted)
	}
	gui_scissor_end(ctx)
	gui_scrollbar(ctx, list_viewport, f32(match_count) * ctx.style.row_height, ctx.combo_scroll)
}

gui_collapsible_begin :: gui_collapsible_begin_keyed
