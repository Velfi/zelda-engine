package ui

Gui_Focus_Layer :: enum u8 {
	Canvas,
	Utility_Rail,
	Control_Deck,
	Panel,
	Active_Control,
	Child_Region,
	Modal,
}

GUI_FOCUS_LAYER_COUNT :: int(Gui_Focus_Layer.Modal) + 1
MAX_GUI_FOCUS_LAYER_STACK :: 8

Gui_Focus_Ownership :: struct {
	owners: [GUI_FOCUS_LAYER_COUNT]Gui_Id,
	active_layer: Gui_Focus_Layer,
	active_owner: Gui_Id,
	stack_layers: [MAX_GUI_FOCUS_LAYER_STACK]Gui_Focus_Layer,
	stack_owners: [MAX_GUI_FOCUS_LAYER_STACK]Gui_Id,
	stack_count: int,
}

gui_focus_owner_claim :: proc(ctx: ^Gui_Context, layer: Gui_Focus_Layer, owner: Gui_Id) {
	if ctx == nil do return
	ctx.focus_ownership.owners[int(layer)] = owner
	ctx.focus_ownership.active_layer = layer
	ctx.focus_ownership.active_owner = owner
}

gui_focus_owner_release :: proc(ctx: ^Gui_Context, layer: Gui_Focus_Layer, owner: Gui_Id = GUI_ID_NONE) {
	if ctx == nil do return
	index := int(layer)
	if owner != GUI_ID_NONE && ctx.focus_ownership.owners[index] != owner do return
	ctx.focus_ownership.owners[index] = GUI_ID_NONE
	if ctx.focus_ownership.active_layer == layer {
		ctx.focus_ownership.active_owner = GUI_ID_NONE
		for candidate := index - 1; candidate >= 0; candidate -= 1 {
			if ctx.focus_ownership.owners[candidate] != GUI_ID_NONE {
				ctx.focus_ownership.active_layer = Gui_Focus_Layer(candidate)
				ctx.focus_ownership.active_owner = ctx.focus_ownership.owners[candidate]
				break
			}
		}
	}
}

gui_focus_owner_push_modal :: proc(ctx: ^Gui_Context, owner: Gui_Id) {
	if ctx == nil do return
	state := &ctx.focus_ownership
	if state.active_layer == .Modal && state.active_owner == owner do return
	if state.stack_count < len(state.stack_layers) {
		state.stack_layers[state.stack_count] = state.active_layer
		state.stack_owners[state.stack_count] = state.active_owner
		state.stack_count += 1
	}
	gui_focus_owner_claim(ctx, .Modal, owner)
}

gui_focus_owner_pop_modal :: proc(ctx: ^Gui_Context) {
	if ctx == nil do return
	state := &ctx.focus_ownership
	if state.owners[int(Gui_Focus_Layer.Modal)] == GUI_ID_NONE do return
	state.owners[int(Gui_Focus_Layer.Modal)] = GUI_ID_NONE
	if state.stack_count > 0 {
		state.stack_count -= 1
		state.active_layer = state.stack_layers[state.stack_count]
		state.active_owner = state.stack_owners[state.stack_count]
	} else {
		state.active_layer = .Canvas
		state.active_owner = state.owners[int(Gui_Focus_Layer.Canvas)]
	}
}

gui_focus_owner :: proc(ctx: ^Gui_Context, layer: Gui_Focus_Layer) -> Gui_Id {
	if ctx == nil do return GUI_ID_NONE
	return ctx.focus_ownership.owners[int(layer)]
}
