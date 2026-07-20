package ui

import "core:math"
import "core:fmt"
import "core:strconv"
import "core:sync"
import "core:time"

gui_restore_ancestor_wheel_scrolls :: proc(ctx: ^Gui_Context, depth: int) {
	if !ctx.wheel_scroll_consumed || depth <= ctx.wheel_scroll_depth {
		return
	}
	for i in 0 ..< ctx.scroll_depth {
		frame := &ctx.scroll_stack[i]
		if frame.wheel_consumed && frame.target_scroll != nil {
			frame.target_scroll^ = frame.previous_scroll
			frame.scroll = frame.previous_scroll
			frame.wheel_consumed = false
		}
	}
}

gui_record_scroll_hit :: proc(ctx: ^Gui_Context, viewport: Rect, scroll, max_scroll, step: f32, depth: int) {
	if ctx.next_scroll_hit_count >= MAX_GUI_SCROLL_HITS {
		return
	}
	ctx.next_scroll_hits[ctx.next_scroll_hit_count] = {
		viewport = viewport,
		scroll = scroll,
		max_scroll = max_scroll,
		step = step,
		depth = depth,
	}
	ctx.next_scroll_hit_count += 1
}

gui_apply_wheel_scroll :: proc(ctx: ^Gui_Context, viewport: Rect, scroll: ^f32, max_scroll, step: f32, depth: int) -> (previous_scroll: f32, consumed: bool) {
	previous_scroll = min(max(scroll^, 0), max_scroll)
	scroll^ = previous_scroll
	if !gui_contains(viewport, ctx.input.mouse_pos) || ctx.input.wheel_delta == 0 {
		return
	}
	if ctx.wheel_scroll_target_depth >= 0 && depth != ctx.wheel_scroll_target_depth {
		return
	}
	if ctx.wheel_scroll_consumed && depth <= ctx.wheel_scroll_depth {
		return
	}

	next_scroll := min(max(scroll^ - ctx.input.wheel_delta * step, 0), max_scroll)
	if next_scroll == scroll^ {
		return
	}

	gui_restore_ancestor_wheel_scrolls(ctx, depth)
	scroll^ = next_scroll
	ctx.wheel_scroll_consumed = true
	ctx.wheel_scroll_depth = depth
	consumed = true
	return
}

gui_scroll_begin :: proc(ctx: ^Gui_Context, viewport: Rect, content_height: f32, scroll: ^f32) {
	gui_scroll_begin_internal(ctx, viewport, content_height, scroll, false, true)
}

gui_scroll_begin_draggable :: proc(ctx: ^Gui_Context, viewport: Rect, content_height: f32, scroll: ^f32) {
	gui_scroll_begin_internal(ctx, viewport, content_height, scroll, true, true)
}

// Native wheel scrolling follows SDL's high-resolution deltas directly. This is
// appropriate for reading surfaces where macOS already supplies smooth trackpad
// motion and a second easing layer would make the content trail the gesture.
gui_scroll_begin_native :: proc(ctx: ^Gui_Context, viewport: Rect, content_height: f32, scroll: ^f32) {
	gui_scroll_begin_internal(ctx, viewport, content_height, scroll, false, false)
}

gui_scroll_begin_internal :: proc(ctx: ^Gui_Context, viewport: Rect, content_height: f32, scroll: ^f32, draggable, animate: bool) {
	max_scroll := max(content_height - viewport.h, 0)
	previous_scroll, consumed_wheel := gui_apply_wheel_scroll(ctx, viewport, scroll, max_scroll, 32, ctx.scroll_depth)
	scroll^ = min(max(scroll^, 0), max_scroll)
	gui_record_scroll_hit(ctx, viewport, scroll^, max_scroll, 32, ctx.scroll_depth)
	scroll_id := gui_id_child_int(gui_make_id(ctx, "scroll"), ctx.scroll_depth)
	direct_scroll := false
	if draggable && max_scroll > 0 && gui_pointer_enabled(ctx) {
		if ctx.input.mouse_pressed && gui_contains(viewport, ctx.input.mouse_pos) {
			ctx.scroll_drag_id = scroll_id
			ctx.scroll_drag_start_pos = ctx.input.mouse_pos
			ctx.scroll_drag_start_scroll = scroll^
			ctx.scroll_drag_consumed = false
		}
		if ctx.scroll_drag_id == scroll_id && (ctx.input.mouse_down || ctx.scroll_drag_release_pending) {
			delta_y := ctx.input.mouse_pos.y - ctx.scroll_drag_start_pos.y
			threshold := max(ctx.style.spacing_1 * 1.5, f32(6))
			if ctx.scroll_drag_consumed || abs(delta_y) >= threshold {
				ctx.scroll_drag_consumed = true
				scroll^ = min(max(ctx.scroll_drag_start_scroll - delta_y, 0), max_scroll)
				direct_scroll = true
				ctx.active = GUI_ID_NONE
			}
			if ctx.scroll_drag_release_pending {
				ctx.scroll_drag_id = GUI_ID_NONE
				ctx.scroll_drag_consumed = false
				ctx.scroll_drag_release_pending = false
			}
		}
	}
	visible_scroll := scroll^
	if animate && ctx.input.delta_time > 0 {
		slot := gui_animation_slot(ctx, scroll_id)
		if slot != nil {
			if direct_scroll {
				slot.value = scroll^
			} else if slot.last_frame == 0 {
				slot.value = min(max(previous_scroll, 0), max_scroll)
			}
			if !direct_scroll {
				slot.value = gui_animate_towards(slot.value, scroll^, 18, ctx.input.delta_time)
			}
			slot.value = min(max(slot.value, 0), max_scroll)
			slot.last_frame = ctx.frame_index
			visible_scroll = slot.value
		}
	}

	focus_record := -1
	if ctx.scroll_focus_record_count < MAX_GUI_SCROLL_FOCUS_RECORDS {
		focus_record = ctx.scroll_focus_record_count
		parent := -1
		if ctx.scroll_depth > 0 {
			parent = ctx.scroll_stack[ctx.scroll_depth - 1].focus_record
		}
		ctx.scroll_focus_records[focus_record] = {
			viewport = viewport,
			scroll = visible_scroll,
			max_scroll = max_scroll,
			target_scroll = scroll,
			animation_id = scroll_id,
			parent = parent,
		}
		ctx.scroll_focus_record_count += 1
	}

	if ctx.scroll_depth < MAX_GUI_SCROLL_DEPTH {
		ctx.scroll_stack[ctx.scroll_depth] = {
			viewport = viewport,
			content_height = content_height,
			scroll = visible_scroll,
			previous_scroll = previous_scroll,
			target_scroll = scroll,
			wheel_consumed = consumed_wheel,
			focus_record = focus_record,
		}
		ctx.scroll_depth += 1
	}

	gui_scissor_begin(ctx, viewport)
	gui_input_clip_begin(ctx, viewport)
	content_w := gui_scrollbar_content_width(ctx, viewport, content_height)
	content := Rect{viewport.x, viewport.y - visible_scroll, content_w, max(content_height, viewport.h)}
	ctx.semantic_next_container_kind = .Scroll_Area
	gui_layout_begin(ctx, content, .Column, ctx.style.spacing, ctx.style.row_height)
}

gui_scroll_end :: proc(ctx: ^Gui_Context) {
	if ctx.layout_depth > 0 {
		layout := ctx.layout_stack[ctx.layout_depth - 1]
		ctx.last_scroll_used_height = max(layout.cursor.y - layout.bounds.y - layout.gap, 0)
	}
	gui_layout_end(ctx)
	gui_input_clip_end(ctx)
	gui_scissor_end(ctx)

	if ctx.scroll_depth <= 0 {
		return
	}
	ctx.scroll_depth -= 1
	frame := ctx.scroll_stack[ctx.scroll_depth]
	ctx.last_scroll_declared_height = frame.content_height
	if ctx.scroll_measure_count < len(ctx.scroll_measure_declared) {
		ctx.scroll_measure_declared[ctx.scroll_measure_count] = frame.content_height
		ctx.scroll_measure_used[ctx.scroll_measure_count] = ctx.last_scroll_used_height
		ctx.scroll_measure_count += 1
	}
	gui_scroll_edge_fades(ctx, frame.viewport, frame.content_height, frame.scroll)
	gui_scrollbar(ctx, frame.viewport, frame.content_height, frame.scroll)
}

gui_scroll_edge_fades :: proc(ctx: ^Gui_Context, viewport: Rect, content_height, scroll: f32) {
	max_scroll := max(content_height - viewport.h, 0)
	if max_scroll <= 0 || viewport.h <= 0 || viewport.w <= 0 {
		return
	}
	fade_h := min(min(max(ctx.style.rhythm * 0.55, 8), 18), viewport.h * 0.5)
	if fade_h <= 0 {
		return
	}

	edge := Color{0, 0, 0, 0.34}
	clear := Color{0, 0, 0, 0}
	if scroll > 0.5 {
		gui_gradient_rect(ctx, {viewport.x, viewport.y, viewport.w, fade_h}, edge, clear)
	}
	if scroll < max_scroll - 0.5 {
		gui_gradient_rect(ctx, {viewport.x, viewport.y + viewport.h - fade_h, viewport.w, fade_h}, clear, edge)
	}
}

gui_translate :: proc(rect: Rect, delta: Vec2) -> Rect {
	return {rect.x + delta.x, rect.y + delta.y, rect.w, rect.h}
}

gui_scale_from_center :: proc(rect: Rect, scale: f32) -> Rect {
	w := rect.w * scale
	h := rect.h * scale
	return {rect.x + (rect.w - w) * 0.5, rect.y + (rect.h - h) * 0.5, w, h}
}

gui_rotate_point :: proc(point, origin: Vec2, angle_radians: f32) -> Vec2 {
	c := math.cos(angle_radians)
	s := math.sin(angle_radians)
	x := point.x - origin.x
	y := point.y - origin.y
	return {origin.x + x * c - y * s, origin.y + x * s + y * c}
}

gui_rect_bottom :: proc(rect: Rect) -> f32 {
	return rect.y + rect.h
}

gui_rect_center :: proc(rect: Rect) -> Vec2 {
	return {rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
}

gui_current_spatial_group :: proc(ctx: ^Gui_Context) -> Gui_Spatial_Group {
	if ctx.spatial_group_depth > 0 {
		return ctx.spatial_groups[ctx.spatial_group_depth - 1]
	}
	return {id = GUI_ID_NONE, enabled = true}
}

gui_spatial_bounds_visible :: proc(ctx: ^Gui_Context, bounds: Rect) -> bool {
	if bounds.w <= 0 || bounds.h <= 0 {
		return false
	}
	if ctx.input_clip_depth <= 0 {
		return true
	}
	clip := gui_rect_intersection(bounds, ctx.input_clip_stack[ctx.input_clip_depth - 1])
	return clip.w > 0 && clip.h > 0
}

gui_register_spatial_item :: proc(ctx: ^Gui_Context, id: Gui_Id, bounds: Rect, enabled: bool) {
	if id == GUI_ID_NONE || ctx.spatial_item_count >= MAX_GUI_SPATIAL_ITEMS {
		return
	}
	group := gui_current_spatial_group(ctx)
	item_focusable := enabled && group.enabled
	item_visible := item_focusable && gui_spatial_bounds_visible(ctx, bounds)
	scroll_owner := -1
	if ctx.scroll_depth > 0 {
		scroll_owner = ctx.scroll_stack[ctx.scroll_depth - 1].focus_record
	}
	ctx.spatial_items[ctx.spatial_item_count] = {
		id = id,
		bounds = bounds,
		group = group.id,
		order = ctx.focus_order_next,
		enabled = item_visible,
		focusable = item_focusable,
		visible = item_visible,
		scroll_owner = scroll_owner,
	}
	ctx.spatial_item_count += 1
	ctx.focus_order_next += 1
}

gui_find_spatial_item :: proc(ctx: ^Gui_Context, id: Gui_Id) -> (Gui_Spatial_Item, bool) {
	for i in 0 ..< ctx.spatial_item_count {
		item := ctx.spatial_items[i]
		if item.id == id && item.focusable {
			return item, true
		}
	}
	return {}, false
}

gui_spatial_item_registered :: proc(ctx: ^Gui_Context, id: Gui_Id) -> bool {
	for i in 0 ..< ctx.spatial_item_count {
		if ctx.spatial_items[i].id == id {
			return true
		}
	}
	return false
}

gui_spatial_candidate_score :: proc(current, candidate: Rect, dir_x, dir_y: f32) -> (valid: bool, forward, perpendicular: f32, overlap: bool) {
	current_center := gui_rect_center(current)
	candidate_center := gui_rect_center(candidate)
	epsilon := f32(0.001)
	if dir_x > 0 {
		forward = candidate_center.x - current_center.x
		perpendicular = math.abs(candidate_center.y - current_center.y)
		overlap = candidate.y < current.y + current.h && candidate.y + candidate.h > current.y
	} else if dir_x < 0 {
		forward = current_center.x - candidate_center.x
		perpendicular = math.abs(candidate_center.y - current_center.y)
		overlap = candidate.y < current.y + current.h && candidate.y + candidate.h > current.y
	} else if dir_y > 0 {
		forward = candidate_center.y - current_center.y
		perpendicular = math.abs(candidate_center.x - current_center.x)
		overlap = candidate.x < current.x + current.w && candidate.x + candidate.w > current.x
	} else if dir_y < 0 {
		forward = current_center.y - candidate_center.y
		perpendicular = math.abs(candidate_center.x - current_center.x)
		overlap = candidate.x < current.x + current.w && candidate.x + candidate.w > current.x
	} else {
		return false, 0, 0, false
	}
	valid = forward > epsilon
	return
}

gui_apply_spatial_navigation :: proc(ctx: ^Gui_Context) {
	if ctx.focus_moved || ctx.focused == GUI_ID_NONE || ctx.text_edit_id != GUI_ID_NONE || ctx.open_panel != GUI_ID_NONE || ctx.focus_edit_id != GUI_ID_NONE {
		return
	}
	dir_x := ctx.input.nav_pressed_x
	dir_y := ctx.input.nav_pressed_y
	if dir_x == 0 && dir_y == 0 {
		return
	}
	if math.abs(dir_x) >= math.abs(dir_y) {
		dir_y = 0
		dir_x = dir_x > 0 ? f32(1) : f32(-1)
	} else {
		dir_x = 0
		dir_y = dir_y > 0 ? f32(1) : f32(-1)
	}
	current, ok := gui_find_spatial_item(ctx, ctx.focused)
	if !ok {
		return
	}
	best_id := GUI_ID_NONE
	best_forward := f32(0)
	best_perpendicular := f32(0)
	best_overlap := false
	best_order := 0
	for i in 0 ..< ctx.spatial_item_count {
		item := ctx.spatial_items[i]
		if !item.focusable || item.id == current.id || item.group != current.group {
			continue
		}
		// Clipping alone must not make a long scroll panel unreachable, but an
		// arbitrary scissor remains a hard navigation boundary.
		if !item.visible && (current.scroll_owner < 0 || item.scroll_owner != current.scroll_owner) {
			continue
		}
		valid, forward, perpendicular, overlap := gui_spatial_candidate_score(current.bounds, item.bounds, dir_x, dir_y)
		if !valid {
			continue
		}
		better := best_id == GUI_ID_NONE
		if !better && overlap != best_overlap {
			better = overlap
		}
		if !better && overlap == best_overlap && forward < best_forward {
			better = true
		}
		if !better && overlap == best_overlap && forward == best_forward && perpendicular < best_perpendicular {
			better = true
		}
		if !better && overlap == best_overlap && forward == best_forward && perpendicular == best_perpendicular && item.order < best_order {
			better = true
		}
		if better {
			best_id = item.id
			best_forward = forward
			best_perpendicular = perpendicular
			best_overlap = overlap
			best_order = item.order
		}
	}
	if best_id != GUI_ID_NONE {
		ctx.focused = best_id
		ctx.focus_moved = true
	}
}

gui_tab_item_candidate :: proc(item: Gui_Spatial_Item, group: Gui_Id, scoped: bool) -> bool {
	if !item.focusable || (!item.visible && item.scroll_owner < 0) {
		return false
	}
	return !scoped || item.group == group
}

gui_apply_tab_navigation :: proc(ctx: ^Gui_Context) {
	if ctx.focus_moved || (!ctx.input.focus_next && !ctx.input.focus_prev) || ctx.focus_edit_id != GUI_ID_NONE || ctx.open_panel != GUI_ID_NONE {
		return
	}

	current, has_current := gui_find_spatial_item(ctx, ctx.focused)
	group := GUI_ID_NONE
	scoped := has_current
	if ctx.focus_scope_active {
		group = ctx.focus_scope
		scoped = true
		if !has_current || current.group != group {
			has_current = false
		}
	} else if has_current {
		group = current.group
	}

	first := Gui_Spatial_Item{}
	last := Gui_Spatial_Item{}
	next := Gui_Spatial_Item{}
	previous := Gui_Spatial_Item{}
	has_first, has_last, has_next, has_previous: bool
	for i in 0 ..< ctx.spatial_item_count {
		item := ctx.spatial_items[i]
		if !gui_tab_item_candidate(item, group, scoped) {
			continue
		}
		if !has_first || item.order < first.order {
			first = item
			has_first = true
		}
		if !has_last || item.order > last.order {
			last = item
			has_last = true
		}
		if has_current && item.order > current.order && (!has_next || item.order < next.order) {
			next = item
			has_next = true
		}
		if has_current && item.order < current.order && (!has_previous || item.order > previous.order) {
			previous = item
			has_previous = true
		}
	}

	target := GUI_ID_NONE
	if ctx.input.focus_prev {
		if has_previous {
			target = previous.id
		} else if has_last {
			target = last.id
		}
	} else if has_next {
		target = next.id
	} else if has_first {
		target = first.id
	}
	if target != GUI_ID_NONE {
		ctx.focused = target
		ctx.focus_moved = true
	}
}

gui_enforce_focus_scope :: proc(ctx: ^Gui_Context) {
	if !ctx.focus_scope_active {
		return
	}
	current, ok := gui_find_spatial_item(ctx, ctx.focused)
	if ok && gui_tab_item_candidate(current, ctx.focus_scope, true) {
		return
	}
	for i in 0 ..< ctx.spatial_item_count {
		item := ctx.spatial_items[i]
		if gui_tab_item_candidate(item, ctx.focus_scope, true) {
			ctx.focused = item.id
			ctx.focus_moved = true
			return
		}
	}
}

gui_reveal_focused_item :: proc(ctx: ^Gui_Context) {
	if ctx.focused == GUI_ID_NONE {
		return
	}
	item, ok := gui_find_spatial_item(ctx, ctx.focused)
	if !ok || item.scroll_owner < 0 {
		return
	}

	reveal_bounds := item.bounds
	owner := item.scroll_owner
	for depth := 0; owner >= 0 && owner < ctx.scroll_focus_record_count && depth < MAX_GUI_SCROLL_DEPTH; depth += 1 {
		record := &ctx.scroll_focus_records[owner]
		padding := min(max(ctx.style.border_width * 3, f32(4)), record.viewport.h * 0.2)
		top := record.viewport.y + padding
		bottom := record.viewport.y + record.viewport.h - padding
		delta := f32(0)
		if reveal_bounds.h > max(bottom - top, 0) {
			delta = reveal_bounds.y - top
		} else if reveal_bounds.y < top {
			delta = reveal_bounds.y - top
		} else if reveal_bounds.y + reveal_bounds.h > bottom {
			delta = reveal_bounds.y + reveal_bounds.h - bottom
		}

		if delta != 0 && record.target_scroll != nil {
			target := min(max(record.scroll + delta, 0), record.max_scroll)
			record.target_scroll^ = target
			record.scroll = target
			if ctx.input.delta_time > 0 {
				slot := gui_animation_slot(ctx, record.animation_id)
				if slot != nil {
					slot.value = target
					slot.last_frame = ctx.frame_index
				}
			}
		}

		reveal_bounds = record.viewport
		owner = record.parent
	}
}

gui_control :: proc(ctx: ^Gui_Context, id: Gui_Id, bounds: Rect, enabled := true, focusable := true, pointer_focus := true, interact_during_transition := false) -> Gui_Control {
	_ = gui_semantic_emit(ctx, .Control, id, bounds, enabled, focusable)
	if enabled && focusable {
		gui_register_focusable(ctx, id, bounds)
	}

	interaction_bounds, snapshot_found := gui_interaction_snapshot_bounds(ctx, id)
	if !snapshot_found {
		ctx.interaction_snapshot_misses += 1
		// Bootstrap frames have no completed geometry to consult. Current
		// geometry is already final for explicit immediate rectangles, so retain
		// the long-standing first-frame behavior. Once a snapshot exists, a new
		// ID is suppressed until it has completed layout once.
		if ctx.interaction_rect_count == 0 {
			interaction_bounds = bounds
			snapshot_found = true
		}
	}
	gui_interaction_snapshot_record(ctx, id, bounds, enabled)
	discontinuous := snapshot_found && gui_interaction_rect_discontinuous(interaction_bounds, bounds)
	hovered := enabled && snapshot_found && (!discontinuous || interact_during_transition) && !gui_semantic_id_was_unstable(ctx, id) && gui_mouse_contains(ctx, interaction_bounds)
	if hovered {
		ctx.hot = id
		if ctx.input.mouse_pressed {
			ctx.active = id
			if focusable && pointer_focus {
				ctx.focused = id
			}
		}
	}

	focused := enabled && ctx.focused == id
	nav_x, nav_y: f32
	if focused {
		nav_x = ctx.input.nav_x
		nav_y = ctx.input.nav_y
	}

	return {
		id = id,
		bounds = bounds,
		enabled = enabled,
		hovered = hovered,
		focused = focused,
		activated = focused && gui_accept_pressed(ctx),
		nav_x = nav_x,
		nav_y = nav_y,
	}
}

gui_interaction_rect_discontinuous :: proc(previous, current: Rect) -> bool {
	position_delta := max(abs(previous.x - current.x), abs(previous.y - current.y))
	size_delta := max(abs(previous.w - current.w), abs(previous.h - current.h))
	position_limit := max(min(max(previous.w, 0), max(previous.h, 0)) * 0.25, f32(8))
	size_limit := max(max(previous.w, previous.h) * 0.25, f32(8))
	return position_delta > position_limit || size_delta > size_limit
}

gui_interaction_snapshot_bounds :: proc(ctx: ^Gui_Context, id: Gui_Id) -> (Rect, bool) {
	for i in 0 ..< ctx.interaction_rect_count {
		record := ctx.interaction_rects[i]
		if record.id == id && record.enabled {
			return record.bounds, true
		}
	}
	return {}, false
}

gui_interaction_snapshot_record :: proc(ctx: ^Gui_Context, id: Gui_Id, bounds: Rect, enabled: bool) {
	if ctx.next_interaction_rect_count >= len(ctx.next_interaction_rects) {
		return
	}
	ctx.next_interaction_rects[ctx.next_interaction_rect_count] = {id, bounds, enabled}
	ctx.next_interaction_rect_count += 1
}

gui_focused_nav :: proc(ctx: ^Gui_Context, id: Gui_Id) -> (nav_x, nav_y: f32) {
	if ctx.focused != id || ctx.focus_edit_id != id {
		return 0, 0
	}
	nav_x = ctx.input.nav_x
	nav_y = ctx.input.nav_y
	return
}

gui_key_up_pressed :: proc(ctx: ^Gui_Context) -> bool {
	return ctx.input.nav_pressed_y < 0
}

gui_key_down_pressed :: proc(ctx: ^Gui_Context) -> bool {
	return ctx.input.nav_pressed_y > 0
}

gui_accept_pressed :: proc(ctx: ^Gui_Context) -> bool {
	return ctx.input.accept_pressed || (ctx.input.accept && !ctx.previous_input.accept)
}

gui_focused_nav_pressed :: proc(ctx: ^Gui_Context, id: Gui_Id) -> (nav_x, nav_y: f32) {
	if ctx.focused != id || ctx.focus_edit_id != id {
		return 0, 0
	}
	nav_x = ctx.input.nav_pressed_x
	nav_y = ctx.input.nav_pressed_y
	return
}

gui_key_left_pressed :: proc(ctx: ^Gui_Context) -> bool {
	return ctx.input.nav_pressed_x < 0
}

gui_key_right_pressed :: proc(ctx: ^Gui_Context) -> bool {
	return ctx.input.nav_pressed_x > 0
}
