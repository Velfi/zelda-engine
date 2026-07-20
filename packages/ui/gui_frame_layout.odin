package ui

import "core:math"
import "core:fmt"
import "core:strconv"
import "core:sync"
import "core:time"

gui_default_style :: proc() -> Gui_Style {
	return {
		bg = {0.0, 0.0, 0.0, 0.0},
		panel = {0.08, 0.10, 0.12, 0.56},
		panel_border = {1.0, 1.0, 1.0, 0.22},
		control = {1.0, 1.0, 1.0, 0.12},
		control_hot = {1.0, 1.0, 1.0, 0.24},
		control_active = {0.86, 0.92, 1.0, 0.28},
		control_disabled = {1.0, 1.0, 1.0, 0.07},
		text = {1.0, 1.0, 1.0, 0.90},
		text_muted = {1.0, 1.0, 1.0, 0.70},
		accent = {0.86, 0.92, 1.0, 1.0},
		danger = {0.937, 0.267, 0.267, 1.0},
		spacing = 12,
		spacing_1 = 4,
		spacing_2 = 8,
		spacing_3 = 12,
		spacing_4 = 18,
		rhythm = 40,
		display_text_height = 90,
		display_line_height = 112,
		display_char_width = 56,
		display_text_scale = 5.625,
		heading_text_height = 45,
		heading_line_height = 56,
		heading_char_width = 28,
		heading_text_scale = 2.8125,
		body_text_height = 30,
		body_line_height = 38,
		body_char_width = 18.75,
		body_text_scale = 1.875,
		small_text_height = 22.5,
		small_line_height = 30,
		small_char_width = 14.0625,
		small_text_scale = 1.40625,
		control_padding = 8,
		margin = 16,
		section_gap = 40,
		scrollbar_width = 6,
		scrollbar_gutter = 8,
		focus_ring_width = 2,
		row_height = 44,
		text_height = 32,
		char_width = 20,
		text_scale = 2.0,
		panel_padding = 8,
		radius_panel = 4,
		radius_control = 4,
		border_width = 1,
		shadow_blur = 8,
		shadow_offset = {0, 2},
		shadow_color = {0, 0, 0, 0.30},
	}
}

gui_style_scaled :: proc(base: Gui_Style, scale: f32) -> Gui_Style {
	s := min(max(scale, 0.5), 3.0)
	style := base
	style.spacing *= s
	style.spacing_1 *= s
	style.spacing_2 *= s
	style.spacing_3 *= s
	style.spacing_4 *= s
	style.rhythm *= s
	style.display_text_height *= s
	style.display_line_height *= s
	style.display_char_width *= s
	style.display_text_scale *= s
	style.heading_text_height *= s
	style.heading_line_height *= s
	style.heading_char_width *= s
	style.heading_text_scale *= s
	style.body_text_height *= s
	style.body_line_height *= s
	style.body_char_width *= s
	style.body_text_scale *= s
	style.small_text_height *= s
	style.small_line_height *= s
	style.small_char_width *= s
	style.small_text_scale *= s
	style.control_padding *= s
	style.margin *= s
	style.section_gap *= s
	style.scrollbar_width *= s
	style.scrollbar_gutter *= s
	style.focus_ring_width *= s
	style.row_height *= s
	style.text_height *= s
	style.char_width *= s
	style.text_scale *= s
	style.panel_padding *= s
	style.radius_panel *= s
	style.radius_control *= s
	style.border_width *= s
	style.shadow_blur *= s
	style.shadow_offset.x *= s
	style.shadow_offset.y *= s
	return style
}

gui_snap :: proc(v: f32) -> f32 {
	return math.floor(v + 0.5)
}

gui_h_fraction :: proc(viewport_height, denominator: f32) -> f32 {
	return viewport_height / max(denominator, 1)
}

gui_style_text_scale_for_height :: proc(height: f32) -> f32 {
	return height / GUI_FONT_LOGICAL_HEIGHT
}

gui_style_for_viewport :: proc(base: Gui_Style, width, height, ui_scale: f32) -> Gui_Style {
	_ = width
	viewport_h := max(height, 480)
	scale := min(max(ui_scale, 0.5), 3.0)
	style := base

	display_h := gui_snap(gui_h_fraction(viewport_h, 12) * scale)
	heading_h := gui_snap(gui_h_fraction(viewport_h, 24) * scale)
	body_h := gui_snap(gui_h_fraction(viewport_h, 36) * scale)
	small_h := gui_snap(gui_h_fraction(viewport_h, 48) * scale)

	body_line := gui_snap(body_h * 1.25)
	heading_line := gui_snap(max(heading_h * 1.25, body_line))
	display_line := gui_snap(max(display_h * 1.15, heading_line))
	small_line := gui_snap(max(small_h * 1.25, body_line * 0.75))
	rhythm := body_line

	style.display_text_height = display_h
	style.display_line_height = display_line
	style.display_text_scale = gui_style_text_scale_for_height(display_h)
	style.display_char_width = base.char_width * style.display_text_scale / base.text_scale

	style.heading_text_height = heading_h
	style.heading_line_height = heading_line
	style.heading_text_scale = gui_style_text_scale_for_height(heading_h)
	style.heading_char_width = base.char_width * style.heading_text_scale / base.text_scale

	style.body_text_height = body_h
	style.body_line_height = body_line
	style.body_text_scale = gui_style_text_scale_for_height(body_h)
	style.body_char_width = base.char_width * style.body_text_scale / base.text_scale

	style.small_text_height = small_h
	style.small_line_height = small_line
	style.small_text_scale = gui_style_text_scale_for_height(small_h)
	style.small_char_width = base.char_width * style.small_text_scale / base.text_scale

	style.rhythm = rhythm
	style.spacing_1 = gui_snap(rhythm * 0.25)
	style.spacing_2 = gui_snap(rhythm * 0.5)
	style.spacing_3 = rhythm
	style.spacing_4 = gui_snap(rhythm * 1.5)
	style.spacing = style.spacing_2
	style.section_gap = style.spacing_3
	style.control_padding = style.spacing_1
	style.margin = style.spacing_2
	style.panel_padding = style.spacing_2
	style.row_height = gui_snap(body_line + style.control_padding * 2)
	style.text_height = style.body_text_height
	style.char_width = style.body_char_width
	style.text_scale = style.body_text_scale
	style.radius_panel = max(gui_snap(rhythm * 0.10), 3)
	style.radius_control = max(gui_snap(rhythm * 0.10), 3)
	style.border_width = min(max(gui_snap(rhythm * 0.03), 1), 3)
	style.scrollbar_width = min(max(gui_snap(rhythm * 0.15), 4), 12)
	style.scrollbar_gutter = min(max(gui_snap(rhythm * 0.20), 6), 16)
	style.focus_ring_width = min(max(gui_snap(rhythm * 0.05), 2), 5)
	style.shadow_blur = gui_snap(rhythm * 0.25)
	style.shadow_offset = {0, gui_snap(rhythm * 0.08)}
	return style
}

gui_init :: proc(ctx: ^Gui_Context) {
	ctx.spare_commands = make([dynamic]Draw_Command, 0, 256)
	ctx.commands = ctx.spare_commands
	ctx.paint_commands = make([dynamic]Draw_Command, 0, 256)
	ctx.style = gui_default_style()
	sync.once_do(&gui_text_shaper_once, gui_init_text_shaper)
}

gui_destroy :: proc(ctx: ^Gui_Context) {
	if ctx.paint_publish_pending {
		ctx.spare_commands = ctx.commands
	}
	delete(ctx.paint_commands)
	delete(ctx.spare_commands)
}

gui_init_text_shaper :: proc() {
	body_ready := vo_textshape_init(i32(Gui_Font_Kind.Body), GUI_BODY_FONT_PATH, GUI_FONT_LOGICAL_HEIGHT) != 0
	display_ready := vo_textshape_init(i32(Gui_Font_Kind.Display), GUI_DISPLAY_FONT_PATH, GUI_FONT_LOGICAL_HEIGHT) != 0
	sim_start_ready := vo_textshape_init(i32(Gui_Font_Kind.SimStart), GUI_SIM_START_FONT_PATH, GUI_FONT_LOGICAL_HEIGHT) != 0
	gui_text_shaper_font_ready[int(Gui_Font_Kind.Body)] = body_ready
	gui_text_shaper_font_ready[int(Gui_Font_Kind.Display)] = display_ready
	gui_text_shaper_font_ready[int(Gui_Font_Kind.SimStart)] = sim_start_ready
	gui_text_shaper_ready = body_ready || display_ready || sim_start_ready
}

gui_font_kind_ready :: proc(font_kind: Gui_Font_Kind) -> bool {
	index := int(font_kind)
	return index >= 0 && index < len(gui_text_shaper_font_ready) && gui_text_shaper_font_ready[index]
}

gui_effective_font_kind :: proc(font_kind: Gui_Font_Kind) -> Gui_Font_Kind {
	if gui_font_kind_ready(font_kind) {
		return font_kind
	}
	if font_kind != .Body && gui_font_kind_ready(.Body) {
		return .Body
	}
	return font_kind
}

gui_begin_frame :: proc(ctx: ^Gui_Context, input: Input_State) {
	if ctx.paint_publish_pending {
		// A diagnostic/test caller may begin a replacement frame without
		// publishing the previous draft. Preserve the possibly reallocated
		// dynamic-array header before clearing that draft buffer.
		ctx.spare_commands = ctx.commands
	}
	ctx.commands = ctx.spare_commands
	ctx.paint_publish_pending = true
	gui_profile_reset()
	clear(&ctx.commands)
	frame_input := input
	raw_mouse_released := frame_input.mouse_released
	ctx.scroll_drag_release_pending = ctx.scroll_drag_id != GUI_ID_NONE && raw_mouse_released
	if ctx.scroll_drag_release_pending && ctx.scroll_drag_consumed {
		// A completed scroll gesture must not also activate the control that
		// received the initial press.
		frame_input.mouse_released = false
	}
	if ctx.scroll_drag_id != GUI_ID_NONE && !frame_input.mouse_down && !raw_mouse_released {
		ctx.scroll_drag_id = GUI_ID_NONE
		ctx.scroll_drag_consumed = false
		ctx.scroll_drag_release_pending = false
	}
	gui_input_apply_keyboard_fallbacks(&frame_input, ctx.input)
	if frame_input.mouse_button == 2 || frame_input.mouse_button == 3 {
		// Regular widgets only capture the primary pointer. Secondary input stays
		// available through its semantic fields, while middle mouse remains an
		// application-level camera gesture and cannot click or drag UI controls.
		frame_input.mouse_down = false
		frame_input.mouse_pressed = false
		frame_input.mouse_released = false
	}
	ctx.previous_input = ctx.input
	// Controller focus is navigational until the user explicitly accepts an
	// editable control. Mouse and keyboard retain their direct-manipulation
	// conventions (click-to-drag, focused text entry, arrow-key editing).
	ctx.controller_explicit_activation = frame_input.active_device == .Controller
	if ctx.mouse_initialized {
		ctx.mouse_delta = {frame_input.mouse_pos.x - ctx.mouse_prev_pos.x, frame_input.mouse_pos.y - ctx.mouse_prev_pos.y}
	} else {
		ctx.mouse_delta = {}
		ctx.mouse_initialized = true
	}
	if frame_input.mouse_pressed {
		ctx.mouse_delta = {}
	}
	ctx.mouse_prev_pos = frame_input.mouse_pos
	ctx.input = frame_input
	ctx.hot = GUI_ID_NONE
	ctx.focus_order_next = 0
	ctx.focus_moved = false
	ctx.focus_edit_seen = false
	ctx.wants_text_input = false
	ctx.spatial_item_count = 0
	ctx.next_interaction_rect_count = 0
	ctx.interaction_snapshot_misses = 0
	gui_semantic_begin_frame(ctx)
	ctx.spatial_group_depth = 0
	ctx.focus_scope = GUI_ID_NONE
	ctx.focus_scope_active = false
	ctx.combo_popup_visible = false
	ctx.tooltip_visible = false
	ctx.tooltip_from_hover = false
	ctx.tooltip_numeric_controls = false
	ctx.tooltip_numeric_text_editing = false
	if ctx.notice_seconds > 0 {
		// Notices must remain transient even when a host redraw supplies a zero
		// delta (for example, an event-driven redraw or a resumed window).
		notice_delta := frame_input.delta_time > 0 ? frame_input.delta_time : f32(1.0 / 60.0)
		ctx.notice_seconds = max(ctx.notice_seconds - notice_delta, 0)
		if ctx.notice_seconds <= 0 {
			ctx.notice_text_len = 0
		}
	}
	ctx.layout_depth = 0
	ctx.input_clip_depth = 0
	ctx.next_overlay_input_rect_count = 0
	ctx.overlay_input_depth = 0
	ctx.scroll_depth = 0
	ctx.scroll_measure_count = 0
	ctx.scroll_focus_record_count = 0
	ctx.wheel_scroll_consumed = false
	ctx.wheel_scroll_depth = -1
	ctx.wheel_scroll_target_depth = -1
	if frame_input.wheel_delta != 0 {
		for i in 0 ..< ctx.scroll_hit_count {
			hit := ctx.scroll_hits[i]
			if gui_contains(hit.viewport, frame_input.mouse_pos) {
				scroll := min(max(hit.scroll, 0), hit.max_scroll)
				next_scroll := min(max(scroll - frame_input.wheel_delta * hit.step, 0), hit.max_scroll)
				if next_scroll != scroll && hit.depth >= ctx.wheel_scroll_target_depth {
					ctx.wheel_scroll_target_depth = hit.depth
				}
			}
		}
	}
	ctx.next_scroll_hit_count = 0
	ctx.id_depth = 0
	ctx.debug_registered_id_count = 0
	ctx.debug_duplicate_id_count = 0
	ctx.frame_index += 1
}

gui_input_apply_keyboard_fallbacks :: proc(input: ^Input_State, previous: Input_State) {
	if input.nav_x == 0 {
		if input.key_right {
			input.nav_x += 1
		}
		if input.key_left {
			input.nav_x -= 1
		}
	}
	if input.nav_y == 0 {
		if input.key_down {
			input.nav_y += 1
		}
		if input.key_up {
			input.nav_y -= 1
		}
	}
	if input.nav_pressed_x == 0 {
		if input.key_right && !previous.key_right {
			input.nav_pressed_x += 1
		}
		if input.key_left && !previous.key_left {
			input.nav_pressed_x -= 1
		}
	}
	if input.nav_pressed_y == 0 {
		if input.key_down && !previous.key_down {
			input.nav_pressed_y += 1
		}
		if input.key_up && !previous.key_up {
			input.nav_pressed_y -= 1
		}
	}
	input.accept = input.accept || input.key_enter
	input.back = input.back || input.key_escape
	input.focus_next = input.focus_next || (input.key_tab && !input.key_shift)
	input.focus_prev = input.focus_prev || (input.key_tab && input.key_shift)
	input.primary_down = input.primary_down || (input.mouse_down && input.mouse_button != 2 && input.mouse_button != 3)
	input.primary_pressed = input.primary_pressed || (input.mouse_pressed && input.mouse_button != 2 && input.mouse_button != 3)
	input.primary_released = input.primary_released || (input.mouse_released && input.mouse_button != 2 && input.mouse_button != 3)
	input.secondary_down = input.secondary_down || (input.mouse_down && input.mouse_button == 3)
	input.secondary_pressed = input.secondary_pressed || (input.mouse_pressed && input.mouse_button == 3)
	input.secondary_released = input.secondary_released || (input.mouse_released && input.mouse_button == 3)
}

gui_profile_reset :: proc() {
	gui_profile = {}
}

gui_profile_snapshot :: proc() -> Gui_Profile_Snapshot {
	return gui_profile
}

gui_end_frame :: proc(ctx: ^Gui_Context) {
	gui_draw_combo_popup_overlay(ctx)
	// A combobox can disappear when its containing tab or panel changes.  Its
	// popup ID must not survive that transition: controller Back treats any
	// open panel as the widget's responsibility, so a stale ID would prevent
	// the containing tab from ever closing.
	if ctx.open_panel != GUI_ID_NONE && !ctx.combo_popup_visible {
		ctx.open_panel = GUI_ID_NONE
	}
	gui_draw_notice_overlay(ctx)
	gui_draw_tooltip_overlay(ctx)
	gui_semantic_finalize(ctx)
	if ctx.paint_publish_pending {
		completed := ctx.paint_commands
		ctx.paint_commands = ctx.commands
		ctx.commands = ctx.paint_commands
		ctx.spare_commands = completed
		ctx.paint_publish_pending = false
	}
	ctx.overlay_input_rect_count = ctx.next_overlay_input_rect_count
	for i in 0 ..< ctx.overlay_input_rect_count {
		ctx.overlay_input_rects[i] = ctx.next_overlay_input_rects[i]
	}
	ctx.scroll_hit_count = ctx.next_scroll_hit_count
	for i in 0 ..< ctx.scroll_hit_count {
		ctx.scroll_hits[i] = ctx.next_scroll_hits[i]
	}
	ctx.interaction_rect_count = ctx.next_interaction_rect_count
	for i in 0 ..< ctx.interaction_rect_count {
		ctx.interaction_rects[i] = ctx.next_interaction_rects[i]
	}
	if ctx.input.mouse_down == false {
		ctx.active = GUI_ID_NONE
		ctx.fine_pointer_drag_id = GUI_ID_NONE
	}
	if ctx.focus_edit_id != GUI_ID_NONE && ctx.input.back {
		cancelled_id := ctx.focus_edit_id
		ctx.focus_edit_id = GUI_ID_NONE
		gui_focus_owner_release(ctx, .Active_Control, cancelled_id)
		if ctx.controller_armed_id == cancelled_id {
			ctx.controller_armed_id = GUI_ID_NONE
		}
		gui_controller_edit_clear_snapshot(ctx, cancelled_id)
	}
	if ctx.focus_edit_id != GUI_ID_NONE && (!ctx.focus_edit_seen || ctx.focused != ctx.focus_edit_id || !gui_spatial_item_registered(ctx, ctx.focus_edit_id)) {
		abandoned_id := ctx.focus_edit_id
		ctx.focus_edit_id = GUI_ID_NONE
		gui_focus_owner_release(ctx, .Active_Control, abandoned_id)
		if ctx.controller_armed_id == abandoned_id {
			ctx.controller_armed_id = GUI_ID_NONE
		}
		gui_controller_edit_clear_snapshot(ctx, abandoned_id)
	}
	gui_enforce_focus_scope(ctx)
	gui_apply_tab_navigation(ctx)
	gui_apply_spatial_navigation(ctx)
	// A wheel gesture is an explicit request to move the viewport.  Do not let
	// focus reveal snap it back toward the currently hovered/focused control.
	if ctx.focus_moved && !ctx.wheel_scroll_consumed {
		gui_reveal_focused_item(ctx)
	}
	if ctx.focused != GUI_ID_NONE && !gui_spatial_item_registered(ctx, ctx.focused) {
		stale_id := ctx.focused
		if ctx.text_edit_id == ctx.focused {
			ctx.text_edit_id = GUI_ID_NONE
			ctx.text_edit_len = 0
			ctx.text_edit_selecting = false
		}
		ctx.focused = GUI_ID_NONE
		ctx.focus_edit_id = GUI_ID_NONE
		gui_focus_owner_release(ctx, .Active_Control, stale_id)
		ctx.controller_armed_id = GUI_ID_NONE
		gui_controller_edit_clear_snapshot(ctx, stale_id)
	}
}

gui_spatial_group_begin :: proc(ctx: ^Gui_Context, key: string, options := Gui_Spatial_Group_Options{enabled = true}) {
	if ctx.spatial_group_depth >= MAX_GUI_SPATIAL_GROUP_DEPTH {
		return
	}
	parent_enabled := true
	if ctx.spatial_group_depth > 0 {
		parent_enabled = ctx.spatial_groups[ctx.spatial_group_depth - 1].enabled
	}
	ctx.spatial_groups[ctx.spatial_group_depth] = {
		id = gui_make_id(ctx, key),
		enabled = parent_enabled && options.enabled,
	}
	ctx.spatial_group_depth += 1
}

gui_spatial_group_end :: proc(ctx: ^Gui_Context) {
	if ctx.spatial_group_depth > 0 {
		ctx.spatial_group_depth -= 1
	}
}

gui_focus_scope_trap_current :: proc(ctx: ^Gui_Context) {
	if ctx.spatial_group_depth <= 0 {
		return
	}
	group := ctx.spatial_groups[ctx.spatial_group_depth - 1]
	if group.enabled {
		ctx.focus_scope = group.id
		ctx.focus_scope_active = true
		gui_focus_owner_push_modal(ctx, group.id)
	}
}

gui_focus_scope_release :: proc(ctx: ^Gui_Context) {
	ctx.focus_scope = GUI_ID_NONE
	ctx.focus_scope_active = false
	gui_focus_owner_pop_modal(ctx)
}

gui_focus_editing :: proc(ctx: ^Gui_Context, id: Gui_Id) -> bool {
	if ctx.focus_edit_id == id {
		ctx.focus_edit_seen = true
	}
	return ctx.focus_edit_id == id
}

gui_focus_edit_begin :: proc(ctx: ^Gui_Context, id: Gui_Id) {
	ctx.focus_edit_id = id
	ctx.focus_edit_seen = true
	gui_focus_owner_claim(ctx, .Active_Control, id)
}

gui_focus_edit_end :: proc(ctx: ^Gui_Context, id: Gui_Id) {
	if ctx.focus_edit_id == id {
		ctx.focus_edit_id = GUI_ID_NONE
		gui_focus_owner_release(ctx, .Active_Control, id)
	}
}

gui_begin_panel :: proc(ctx: ^Gui_Context, bounds: Rect) {
	ctx.next_cursor = {bounds.x + ctx.style.spacing, bounds.y + ctx.style.spacing}
	ctx.content_width = bounds.w - ctx.style.spacing * 2
	gui_rect(ctx, bounds, ctx.style.panel)
	gui_stroke(ctx, bounds, ctx.style.panel_border)
}

gui_panel_begin :: proc(ctx: ^Gui_Context, bounds: Rect) {
	gui_shadow(ctx, bounds, ctx.style.radius_panel, ctx.style.shadow_offset, ctx.style.shadow_blur, ctx.style.shadow_color)
	// A stable scrim keeps controls legible over bright, high-frequency
	// simulations while the refractive layer preserves the glass character.
	gui_round_rect(ctx, bounds, ctx.style.radius_panel, ctx.style.panel)
	gui_refractive_glass_rect(ctx, bounds, gui_default_glass_style(ctx, ctx.style.radius_panel))
	gui_round_stroke(ctx, bounds, ctx.style.radius_panel, ctx.style.panel_border, ctx.style.border_width)
	ctx.semantic_next_container_kind = .Panel
	gui_layout_begin(ctx, gui_inset(bounds, ctx.style.panel_padding), .Column, ctx.style.spacing, ctx.style.row_height)
}

gui_panel_end :: proc(ctx: ^Gui_Context) {
	gui_layout_end(ctx)
}

gui_layout_begin :: proc(ctx: ^Gui_Context, bounds: Rect, axis: Gui_Axis, gap, item_height: f32) {
	gui_layout_begin_ex(ctx, bounds, axis, gap, item_height, {}, .Stretch)
}

gui_layout_begin_ex :: proc(ctx: ^Gui_Context, bounds: Rect, axis: Gui_Axis, gap, item_height: f32, padding: Gui_Edge_Insets, align_cross: Gui_Align) {
	if ctx.layout_depth >= MAX_GUI_LAYOUT_DEPTH {
		return
	}
	content := gui_inset_edges(bounds, padding)
	ctx.layout_stack[ctx.layout_depth] = {
		bounds = content,
		cursor = {content.x, content.y},
		axis = axis,
		content_width = content.w,
		content_height = content.h,
		gap = gap,
		item_height = item_height,
		padding = padding,
		align_cross = align_cross,
	}
	ctx.layout_depth += 1
	kind := ctx.semantic_next_container_kind
	if kind == .None do kind = axis == .Row ? .Row : .Stack
	ctx.semantic_next_container_kind = .None
	gui_semantic_container_begin(ctx, kind, bounds)
	ctx.next_cursor = {content.x, content.y}
	ctx.content_width = content.w
}

gui_layout_end :: proc(ctx: ^Gui_Context) {
	if ctx.layout_depth <= 0 {
		return
	}
	ctx.layout_depth -= 1
	gui_semantic_container_end(ctx)
	if ctx.layout_depth > 0 {
		parent := &ctx.layout_stack[ctx.layout_depth - 1]
		ctx.next_cursor = parent.cursor
		ctx.content_width = parent.content_width
	}
}

gui_next_rect :: proc(ctx: ^Gui_Context, width := f32(-1), height := f32(-1), stretch_cross_axis := true) -> Rect {
	if ctx.layout_depth == 0 {
		return gui_next_row(ctx, width, height)
	}

	frame := &ctx.layout_stack[ctx.layout_depth - 1]
	w := width
	h := height
	if w <= 0 {
		w = frame.content_width
	}
	if h <= 0 {
		h = frame.item_height
	}

	rect := Rect{frame.cursor.x, frame.cursor.y, w, h}
	if frame.axis == .Column {
		switch frame.align_cross {
		case .Start:
		case .Center:
			rect.x = frame.bounds.x + max((frame.content_width - w) * 0.5, 0)
		case .End:
			rect.x = frame.bounds.x + max(frame.content_width - w, 0)
		case .Stretch:
			if stretch_cross_axis {
				rect.w = frame.content_width
			}
		}
	} else {
		switch frame.align_cross {
		case .Start:
		case .Center:
			rect.y = frame.bounds.y + max((frame.content_height - h) * 0.5, 0)
		case .End:
			rect.y = frame.bounds.y + max(frame.content_height - h, 0)
		case .Stretch:
			if stretch_cross_axis {
				rect.h = frame.content_height
			}
		}
	}
	switch frame.axis {
	case .Column:
		frame.cursor.y += h + frame.gap
	case .Row:
		frame.cursor.x += w + frame.gap
	}
	ctx.next_cursor = frame.cursor
	ctx.content_width = frame.content_width
	return rect
}

gui_row_begin :: proc(ctx: ^Gui_Context, height: f32) {
	row := gui_next_rect(ctx, height = height)
	ctx.semantic_next_container_kind = .Row
	gui_layout_begin(ctx, row, .Row, ctx.style.spacing, height)
}

gui_row_end :: proc(ctx: ^Gui_Context) {
	gui_layout_end(ctx)
}

gui_grid_begin :: proc(ctx: ^Gui_Context, bounds: Rect, columns: int, gap: f32) -> Gui_Grid {
	return {bounds = bounds, columns = max(columns, 1), gap = gap, index = 0}
}

Gui_Grid :: struct {
	bounds: Rect,
	columns: int,
	gap: f32,
	index: int,
}

gui_grid_next :: proc(grid: ^Gui_Grid, height: f32) -> Rect {
	col := grid.index % grid.columns
	row := grid.index / grid.columns
	width := (grid.bounds.w - grid.gap * f32(grid.columns - 1)) / f32(grid.columns)
	x := grid.bounds.x + f32(col) * (width + grid.gap)
	y := grid.bounds.y + f32(row) * (height + grid.gap)
	grid.index += 1
	return {x, y, width, height}
}

gui_breakpoint :: proc(width: f32) -> Gui_Breakpoint {
	if width < 640 {
		return .Compact
	}
	if width < 1024 {
		return .Medium
	}
	if width < 1440 {
		return .Expanded
	}
	return .Wide
}

gui_responsive_columns :: proc(width: f32, min_column_width: f32, max_columns: int, gap: f32) -> int {
	if min_column_width <= 0 {
		return max(max_columns, 1)
	}
	columns := int((width + gap) / (min_column_width + gap))
	return max(min(columns, max(max_columns, 1)), 1)
}

gui_distribute_equal :: proc(out: []Rect, bounds: Rect, axis: Gui_Axis, gap: f32, distribution: Gui_Distribution) {
	count := len(out)
	if count == 0 {
		return
	}
	total_gap := gap * f32(max(count - 1, 0))
	if distribution == .Space_Between && count > 1 {
		total_gap = 0
	}
	if axis == .Row {
		item_w := max((bounds.w - total_gap) / f32(count), 0)
		actual_gap := gap
		if distribution == .Space_Between && count > 1 {
			actual_gap = max((bounds.w - item_w * f32(count)) / f32(count - 1), 0)
		}
		x := bounds.x
		if distribution == .Center {
			x += max((bounds.w - item_w * f32(count) - actual_gap * f32(count - 1)) * 0.5, 0)
		} else if distribution == .End {
			x += max(bounds.w - item_w * f32(count) - actual_gap * f32(count - 1), 0)
		}
		for i in 0 ..< count {
			out[i] = {x + f32(i) * (item_w + actual_gap), bounds.y, item_w, bounds.h}
		}
	} else {
		item_h := max((bounds.h - total_gap) / f32(count), 0)
		actual_gap := gap
		if distribution == .Space_Between && count > 1 {
			actual_gap = max((bounds.h - item_h * f32(count)) / f32(count - 1), 0)
		}
		y := bounds.y
		if distribution == .Center {
			y += max((bounds.h - item_h * f32(count) - actual_gap * f32(count - 1)) * 0.5, 0)
		} else if distribution == .End {
			y += max(bounds.h - item_h * f32(count) - actual_gap * f32(count - 1), 0)
		}
		for i in 0 ..< count {
			out[i] = {bounds.x, y + f32(i) * (item_h + actual_gap), bounds.w, item_h}
		}
	}
}

gui_anchor_rect :: proc(parent: Rect, anchor: Gui_Anchor, offset: Gui_Edge_Insets, fallback_size: Vec2) -> Rect {
	x0 := parent.x + parent.w * anchor.left + offset.left
	y0 := parent.y + parent.h * anchor.top + offset.top
	x1 := parent.x + parent.w * anchor.right - offset.right
	y1 := parent.y + parent.h * anchor.bottom - offset.bottom
	w := x1 - x0
	h := y1 - y0
	if anchor.left == anchor.right {
		w = fallback_size.x
	}
	if anchor.top == anchor.bottom {
		h = fallback_size.y
	}
	return {x0, y0, max(w, 0), max(h, 0)}
}
