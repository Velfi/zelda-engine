package ui

Gui_Semantic_Node_Kind :: enum u8 {
	None,
	Stack,
	Row,
	Grid,
	Overlay,
	Panel,
	Scroll_Area,
	Control,
}

Gui_Semantic_Node :: struct {
	kind: Gui_Semantic_Node_Kind,
	id: Gui_Id,
	parent: int,
	first_child: int,
	next_sibling: int,
	bounds: Rect,
	enabled: bool,
	focusable: bool,
	unstable: bool,
}

Gui_Semantic_Diagnostics :: struct {
	node_count: int,
	layout_passes: int,
	unstable_node_count: int,
	overflowed: bool,
}

MAX_GUI_SEMANTIC_NODES :: 1024
MAX_GUI_SEMANTIC_DEPTH :: 32
MAX_GUI_UNSTABLE_IDS :: 64
GUI_LAYOUT_RETRY_LIMIT :: 2

gui_semantic_begin_frame :: proc(ctx: ^Gui_Context) {
	ctx.semantic_node_count = 0
	ctx.semantic_depth = 0
	ctx.semantic_next_container_kind = .None
	ctx.semantic_diagnostics = {}
}

gui_semantic_emit :: proc(ctx: ^Gui_Context, kind: Gui_Semantic_Node_Kind, id: Gui_Id, bounds: Rect, enabled, focusable: bool) -> int {
	if ctx.semantic_node_count >= len(ctx.semantic_nodes) {
		ctx.semantic_diagnostics.overflowed = true
		return -1
	}
	index := ctx.semantic_node_count
	parent := ctx.semantic_depth > 0 ? ctx.semantic_stack[ctx.semantic_depth - 1] : -1
	ctx.semantic_nodes[index] = {kind = kind, id = id, parent = parent, first_child = -1, next_sibling = -1, bounds = bounds, enabled = enabled, focusable = focusable}
	ctx.semantic_node_count += 1
	if parent >= 0 {
		if ctx.semantic_nodes[parent].first_child < 0 {
			ctx.semantic_nodes[parent].first_child = index
		} else {
			sibling := ctx.semantic_nodes[parent].first_child
			for ctx.semantic_nodes[sibling].next_sibling >= 0 do sibling = ctx.semantic_nodes[sibling].next_sibling
			ctx.semantic_nodes[sibling].next_sibling = index
		}
	}
	return index
}

gui_semantic_container_begin :: proc(ctx: ^Gui_Context, kind: Gui_Semantic_Node_Kind, bounds: Rect, id: Gui_Id = GUI_ID_NONE) {
	index := gui_semantic_emit(ctx, kind, id, bounds, true, false)
	if index >= 0 && ctx.semantic_depth < len(ctx.semantic_stack) {
		ctx.semantic_stack[ctx.semantic_depth] = index
		ctx.semantic_depth += 1
	}
}

gui_semantic_container_end :: proc(ctx: ^Gui_Context) {
	if ctx.semantic_depth > 0 do ctx.semantic_depth -= 1
}

gui_semantic_id_was_unstable :: proc(ctx: ^Gui_Context, id: Gui_Id) -> bool {
	for candidate in ctx.semantic_unstable_ids[:ctx.semantic_unstable_id_count] {
		if candidate == id do return true
	}
	return false
}

gui_semantic_finalize :: proc(ctx: ^Gui_Context) {
	ctx.next_semantic_unstable_id_count = 0
	passes := 1
	for retry in 0 ..< GUI_LAYOUT_RETRY_LIMIT {
		ctx.next_semantic_unstable_id_count = 0
		unstable := 0
		for i in 0 ..< ctx.semantic_node_count {
			node := &ctx.semantic_nodes[i]
			valid := node.bounds.x == node.bounds.x && node.bounds.y == node.bounds.y && node.bounds.w >= 0 && node.bounds.h >= 0
			node.unstable = !valid
			if !valid {
				unstable += 1
				if node.id != GUI_ID_NONE && ctx.next_semantic_unstable_id_count < len(ctx.next_semantic_unstable_ids) {
					ctx.next_semantic_unstable_ids[ctx.next_semantic_unstable_id_count] = node.id
					ctx.next_semantic_unstable_id_count += 1
				}
			}
		}
		if unstable == 0 do break
		passes = retry + 2
	}
	ctx.semantic_diagnostics.node_count = ctx.semantic_node_count
	ctx.semantic_diagnostics.layout_passes = min(passes, GUI_LAYOUT_RETRY_LIMIT)
	ctx.semantic_diagnostics.unstable_node_count = ctx.next_semantic_unstable_id_count
	ctx.semantic_unstable_id_count = ctx.next_semantic_unstable_id_count
	for i in 0 ..< ctx.semantic_unstable_id_count do ctx.semantic_unstable_ids[i] = ctx.next_semantic_unstable_ids[i]
	for i in 0 ..< ctx.next_interaction_rect_count {
		if gui_semantic_id_was_unstable(ctx, ctx.next_interaction_rects[i].id) do ctx.next_interaction_rects[i].enabled = false
	}
}

gui_semantic_diagnostics :: proc(ctx: ^Gui_Context) -> Gui_Semantic_Diagnostics {
	return ctx.semantic_diagnostics
}
