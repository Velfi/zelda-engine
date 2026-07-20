package ui

import "core:encoding/json"
import "core:mem"
import "core:os"

UI_DOCUMENT_SCHEMA_VERSION :: 1
UI_DOCUMENT_ID_CAPACITY :: 64
UI_DOCUMENT_ASSET_COUNT :: 5
UI_DOCUMENT_ASSET_PATHS := [UI_DOCUMENT_ASSET_COUNT]string {
	"assets/ui/main_menu.vui.json",
	"assets/ui/options.vui.json",
	"assets/ui/controls_help.vui.json",
	"assets/ui/preset_dialog.vui.json",
	"assets/ui/simulation_shell.vui.json",
}

Ui_Document_Node_Kind :: enum u8 {
	Invalid,
	Panel,
	Text,
	Image,
	Button,
	Toggle,
	Slider,
	Numeric,
	Selector,
	Stack,
	Row,
	Grid,
	Overlay,
	Scroll,
	Anchor,
	Template,
	Slot,
}

Ui_Document_Binding_Kind :: enum u8 {
	Invalid,
	Bool,
	Integer,
	Float,
	Enum_Index,
	String,
	Image,
	Visibility,
	Enabled,
	Action,
	Slot,
}

Ui_Document_Error :: enum u8 {
	None,
	Read_Failed,
	Parse_Failed,
	Unsupported_Version,
	Missing_Document_Id,
	Missing_Node_Id,
	Duplicate_Node_Id,
	Unknown_Node_Kind,
	Unknown_Parent,
	Parent_Cycle,
	Unknown_Template,
	Template_Cycle,
	Duplicate_Binding_Id,
	Unknown_Binding_Kind,
	Unknown_Binding,
	Missing_Required_Binding,
	Binding_Type_Mismatch,
	Invalid_Constraint,
	Unknown_Required_Style_Token,
	Invalid_Breakpoint,
}

Ui_Document_Layout_Source :: struct {
	axis: string,
	width: f32,
	height: f32,
	gap: f32,
	columns: int,
	content_height: f32,
	breakpoint: string,
}

Ui_Document_Node_Source :: struct {
	id: string,
	parent: string,
	kind: string,
	text: string,
	style: string,
	binding: string,
	action: string,
	template: string,
	required_style: bool,
	layout: Ui_Document_Layout_Source,
}

Ui_Document_Binding_Source :: struct {
	id: string,
	kind: string,
	required: bool,
}

Ui_Document_Constraint_Source :: struct {
	left: string,
	relation: string,
	right: string,
	constant: f32,
	strength: string,
}

Ui_Document_Constraint_Property :: enum u8 {
	Invalid,
	X,
	Y,
	Width,
	Height,
	Left,
	Right,
	Top,
	Bottom,
	Center_X,
	Center_Y,
}

Ui_Document_Constraint :: struct {
	source: Ui_Document_Constraint_Source,
	left_node: int,
	left_property: Ui_Document_Constraint_Property,
	right_node: int,
	right_property: Ui_Document_Constraint_Property,
	right_is_viewport: bool,
}

Ui_Document_Source :: struct {
	schema_version: int,
	document_id: string,
	nodes: [dynamic]Ui_Document_Node_Source,
	bindings: [dynamic]Ui_Document_Binding_Source,
	constraints: [dynamic]Ui_Document_Constraint_Source,
	required_style_tokens: [dynamic]string,
	optional_metadata: map[string]string,
}

Ui_Document_Node :: struct {
	source: Ui_Document_Node_Source,
	kind: Ui_Document_Node_Kind,
	parent_index: int,
	template_index: int,
}

Ui_Document_Binding :: struct {
	source: Ui_Document_Binding_Source,
	kind: Ui_Document_Binding_Kind,
}

Ui_Document :: struct {
	arena: mem.Dynamic_Arena,
	source: Ui_Document_Source,
	nodes: [dynamic]Ui_Document_Node,
	bindings: [dynamic]Ui_Document_Binding,
	constraints: [dynamic]Ui_Document_Constraint,
	valid: bool,
}

Ui_Document_Assets :: struct {
	documents: [UI_DOCUMENT_ASSET_COUNT]Ui_Document,
	loaded: bool,
}

Ui_Document_Validation :: struct {
	error: Ui_Document_Error,
	index: int,
	message: string,
}

Ui_Document_Runtime_Binding :: struct {
	id: string,
	kind: Ui_Document_Binding_Kind,
	bool_value: ^bool,
	integer_value: ^int,
	float_value: ^f32,
	string_value: ^string,
	image_value: ^Gui_Image_Id,
	enum_options: []string,
	userdata: rawptr,
	draw_slot: proc(rawptr, ^Gui_Context, Rect),
	slot_content_height: f32,
}

Ui_Document_Action_State :: struct {
	ids: [64]string,
	count: int,
}

ui_document_runtime_binding :: proc(bindings: []Ui_Document_Runtime_Binding, id: string) -> (^Ui_Document_Runtime_Binding, bool) {
	for _, i in bindings {
		binding := &bindings[i]
		if binding.id == id {
			return binding, true
		}
	}
	return nil, false
}

ui_document_validate_bindings :: proc(document: ^Ui_Document, bindings: []Ui_Document_Runtime_Binding) -> Ui_Document_Validation {
	if document == nil || !document.valid {
		return {.Parse_Failed, -1, "UI document is not valid"}
	}
	for expected, i in document.bindings {
		actual, found := ui_document_runtime_binding(bindings, expected.source.id)
		if !found {
			if expected.source.required {
				return {.Missing_Required_Binding, i, "required UI binding is missing"}
			}
			continue
		}
		if actual.kind != expected.kind {
			return {.Binding_Type_Mismatch, i, "UI binding type does not match document schema"}
		}
	}
	return {}
}

ui_document_action_push :: proc(actions: ^Ui_Document_Action_State, id: string) {
	if actions == nil || len(id) == 0 || actions.count >= len(actions.ids) {
		return
	}
	actions.ids[actions.count] = id
	actions.count += 1
}

// V1 renderer deliberately keeps behavior in Odin. Documents provide stable
// structure, labels, layout roles, typed slots, and action identifiers.
ui_document_draw :: proc(document: ^Ui_Document, ctx: ^Gui_Context, bounds: Rect, bindings: []Ui_Document_Runtime_Binding, actions: ^Ui_Document_Action_State) -> Ui_Document_Validation {
	validation := ui_document_validate_bindings(document, bindings)
	if validation.error != .None {
		return validation
	}
	if actions != nil do actions.count = 0
	resolved_root := ui_document_solve_root_bounds(document, bounds)
	for node, i in document.nodes {
		if node.parent_index < 0 && node.kind != .Template {
			ui_document_draw_node(document, i, ctx, resolved_root, bindings, actions, true)
		}
	}
	return {}
}

ui_document_constraint_read :: proc(rect: Rect, property: Ui_Document_Constraint_Property) -> f32 {
	#partial switch property {
	case .X, .Left: return rect.x
	case .Y, .Top: return rect.y
	case .Width: return rect.w
	case .Height: return rect.h
	case .Right: return rect.x + rect.w
	case .Bottom: return rect.y + rect.h
	case .Center_X: return rect.x + rect.w * 0.5
	case .Center_Y: return rect.y + rect.h * 0.5
	}
	return 0
}

ui_document_constraint_write :: proc(rect: ^Rect, property: Ui_Document_Constraint_Property, value: f32) {
	#partial switch property {
	case .X, .Left: rect.x = value
	case .Y, .Top: rect.y = value
	case .Width: rect.w = max(value, 0)
	case .Height: rect.h = max(value, 0)
	case .Right: rect.x = value - rect.w
	case .Bottom: rect.y = value - rect.h
	case .Center_X: rect.x = value - rect.w * 0.5
	case .Center_Y: rect.y = value - rect.h * 0.5
	}
}

ui_document_solve_root_bounds :: proc(document: ^Ui_Document, viewport: Rect) -> Rect {
	result := viewport
	if document == nil || !document.valid do return result
	root := -1
	for node, i in document.nodes {
		if node.parent_index < 0 && node.kind != .Template {root = i; break}
	}
	if root < 0 do return result
	root_layout := document.nodes[root].source.layout
	if root_layout.width > 0 {
		result.w = min(root_layout.width, viewport.w)
		result.x = viewport.x + (viewport.w - result.w) * 0.5
	}
	if root_layout.height > 0 {
		result.h = min(root_layout.height, viewport.h)
		result.y = viewport.y + (viewport.h - result.h) * 0.5
	}
	// V1 constraints are single-property linear relations. Two deterministic
	// passes allow edge/size pairs to settle without replaying product UI code.
	for _ in 0 ..< 2 {
		for constraint in document.constraints {
			if constraint.left_node != root do continue
			right_rect := viewport
			if !constraint.right_is_viewport && constraint.right_node == root do right_rect = result
			target := ui_document_constraint_read(right_rect, constraint.right_property) + constraint.source.constant
			current := ui_document_constraint_read(result, constraint.left_property)
			switch constraint.source.relation {
			case "equal": ui_document_constraint_write(&result, constraint.left_property, target)
			case "less_equal": if current > target do ui_document_constraint_write(&result, constraint.left_property, target)
			case "greater_equal": if current < target do ui_document_constraint_write(&result, constraint.left_property, target)
			}
		}
	}
	return result
}

ui_document_draw_node :: proc(document: ^Ui_Document, index: int, ctx: ^Gui_Context, bounds: Rect, bindings: []Ui_Document_Runtime_Binding, actions: ^Ui_Document_Action_State, root := false) {
	node := &document.nodes[index]
	if !ui_document_breakpoint_matches(node.source.layout.breakpoint, bounds.w, bounds.h) do return
	visible := true
	enabled := true
	if len(node.source.binding) > 0 {
		if binding, ok := ui_document_runtime_binding(bindings, node.source.binding); ok {
			if binding.kind == .Visibility && binding.bool_value != nil do visible = binding.bool_value^
			if binding.kind == .Enabled && binding.bool_value != nil do enabled = binding.bool_value^
		}
	}
	if !visible {
		return
	}

	#partial switch node.kind {
	case .Panel:
		panel := bounds
		if !root do panel = gui_next_rect(ctx, height = node.source.layout.height > 0 ? node.source.layout.height : ctx.style.row_height * 4)
		gui_panel_begin(ctx, panel)
		ui_document_draw_children(document, index, ctx, panel, bindings, actions)
		gui_panel_end(ctx)
	case .Stack, .Row, .Grid, .Overlay, .Anchor:
		container := bounds
		if !root do container = gui_next_rect(ctx, height = node.source.layout.height > 0 ? node.source.layout.height : ctx.style.row_height * 4)
		axis := node.kind == .Row ? Gui_Axis.Row : Gui_Axis.Column
		gap := node.source.layout.gap > 0 ? node.source.layout.gap : ctx.style.spacing
		#partial switch node.kind {
		case .Grid: ctx.semantic_next_container_kind = .Grid
		case .Overlay, .Anchor: ctx.semantic_next_container_kind = .Overlay
		case .Row: ctx.semantic_next_container_kind = .Row
		case: ctx.semantic_next_container_kind = .Stack
		}
		gui_layout_begin(ctx, container, axis, gap, ctx.style.row_height)
		ui_document_draw_children(document, index, ctx, container, bindings, actions)
		gui_layout_end(ctx)
	case .Scroll:
		viewport := bounds
		if !root do viewport = gui_next_rect(ctx, height = node.source.layout.height > 0 ? node.source.layout.height : ctx.style.row_height * 4)
		content_height := node.source.layout.content_height
		if content_height <= 0 {
			for child in document.nodes {
				if child.parent_index != index || child.kind != .Slot do continue
				if binding, ok := ui_document_runtime_binding(bindings, child.source.binding); ok && binding.kind == .Slot {
					content_height = max(content_height, binding.slot_content_height)
				}
			}
		}
		if content_height <= 0 do content_height = max(viewport.h, ctx.style.row_height * f32(max(ui_document_child_count(document, index), 1)) + ctx.style.spacing * 2)
		scroll := ui_document_scroll_value(ctx, document.source.document_id, node.source.id)
		gui_scroll_begin(ctx, viewport, content_height, scroll)
		ui_document_draw_children(document, index, ctx, viewport, bindings, actions)
		gui_scroll_end(ctx)
	case .Text:
		text := node.source.text
		if binding, ok := ui_document_runtime_binding(bindings, node.source.binding); ok && binding.kind == .String && binding.string_value != nil {
			text = binding.string_value^
		}
		gui_label(ctx, text)
	case .Image:
		if binding, ok := ui_document_runtime_binding(bindings, node.source.binding); ok && binding.kind == .Image && binding.image_value != nil {
			rect := gui_next_rect(ctx, height = node.source.layout.height > 0 ? node.source.layout.height : ctx.style.row_height * 3)
			gui_image(ctx, rect, binding.image_value^, {1, 1, 1, 1})
		}
	case .Button:
		if enabled && gui_button(ctx, node.source.text, node.source.id) {
			ui_document_action_push(actions, node.source.action)
		} else if !enabled {
			gui_disabled_button(ctx, node.source.text)
		}
	case .Toggle:
		if binding, ok := ui_document_runtime_binding(bindings, node.source.binding); ok && binding.bool_value != nil {
			if gui_toggle(ctx, node.source.text, node.source.id, binding.bool_value) {
				ui_document_action_push(actions, node.source.action)
			}
		}
	case .Slider:
		if binding, ok := ui_document_runtime_binding(bindings, node.source.binding); ok && binding.float_value != nil {
			if gui_slider_f32(ctx, node.source.text, node.source.id, binding.float_value, 0, 1) {
				ui_document_action_push(actions, node.source.action)
			}
		}
	case .Numeric:
		if binding, ok := ui_document_runtime_binding(bindings, node.source.binding); ok && binding.float_value != nil {
			if gui_numeric_f32(ctx, node.source.text, node.source.id, binding.float_value, 0.1, -1000, 1000) {
				ui_document_action_push(actions, node.source.action)
			}
		}
	case .Selector:
		if binding, ok := ui_document_runtime_binding(bindings, node.source.binding); ok && binding.integer_value != nil && len(binding.enum_options) > 0 {
			if gui_selector(ctx, node.source.text, node.source.id, binding.integer_value, binding.enum_options) {
				ui_document_action_push(actions, node.source.action)
			}
		}
	case .Template:
	case .Slot:
		if binding, ok := ui_document_runtime_binding(bindings, node.source.binding); ok && binding.kind == .Slot && binding.draw_slot != nil {
			rect := bounds
			if !root {
				height := node.source.layout.height
				if height <= 0 do height = binding.slot_content_height
				if height <= 0 do height = ctx.style.row_height
				rect = gui_next_rect(ctx, height = height)
			}
			binding.draw_slot(binding.userdata, ctx, rect)
		}
	}
}

ui_document_breakpoint_valid :: proc(name: string) -> bool {
	return name == "" || name == "compact" || name == "wide" || name == "short" || name == "tall"
}

ui_document_breakpoint_matches :: proc(name: string, width, height: f32) -> bool {
	switch name {
	case "": return true
	case "compact": return width < 920
	case "wide": return width >= 920
	case "short": return height < 640
	case "tall": return height >= 640
	}
	return false
}

ui_document_draw_children :: proc(document: ^Ui_Document, parent: int, ctx: ^Gui_Context, bounds: Rect, bindings: []Ui_Document_Runtime_Binding, actions: ^Ui_Document_Action_State) {
	if parent >= 0 && parent < len(document.nodes) {
		node := &document.nodes[parent]
		if node.template_index >= 0 {
			// Template definitions are immutable subtrees. Scope expansion by the
			// instance ID so repeated instances retain distinct focus/edit state
			// without copying or mutating document nodes.
			gui_push_id(ctx, node.source.id)
			ui_document_draw_children(document, node.template_index, ctx, bounds, bindings, actions)
			gui_pop_id(ctx)
		}
	}
	for node, i in document.nodes {
		if node.parent_index == parent {
			ui_document_draw_node(document, i, ctx, bounds, bindings, actions)
		}
	}
}

ui_document_child_count :: proc(document: ^Ui_Document, parent: int) -> int {
	count := 0
	for node in document.nodes {
		if node.parent_index == parent do count += 1
	}
	return count
}

ui_document_scroll_value :: proc(ctx: ^Gui_Context, document_id, element_id: string) -> ^f32 {
	id := gui_id_child(gui_id_child(GUI_ID_NONE, document_id), element_id)
	for i in 0 ..< ctx.document_scroll_slot_count {
		if ctx.document_scroll_slots[i].id == id {
			ctx.document_scroll_slots[i].last_frame = ctx.frame_index
			return &ctx.document_scroll_slots[i].value
		}
	}
	if ctx.document_scroll_slot_count >= len(ctx.document_scroll_slots) do return &ctx.document_scroll_fallback
	index := ctx.document_scroll_slot_count
	ctx.document_scroll_slot_count += 1
	ctx.document_scroll_slots[index] = {id = id, last_frame = ctx.frame_index}
	return &ctx.document_scroll_slots[index].value
}

ui_document_node_kind :: proc(name: string) -> Ui_Document_Node_Kind {
	switch name {
	case "panel": return .Panel
	case "text": return .Text
	case "image": return .Image
	case "button": return .Button
	case "toggle": return .Toggle
	case "slider": return .Slider
	case "numeric": return .Numeric
	case "selector": return .Selector
	case "stack": return .Stack
	case "row": return .Row
	case "grid": return .Grid
	case "overlay": return .Overlay
	case "scroll": return .Scroll
	case "anchor": return .Anchor
	case "template": return .Template
	case "slot": return .Slot
	}
	return .Invalid
}

ui_document_binding_kind :: proc(name: string) -> Ui_Document_Binding_Kind {
	switch name {
	case "bool": return .Bool
	case "integer": return .Integer
	case "float": return .Float
	case "enum_index": return .Enum_Index
	case "string": return .String
	case "image": return .Image
	case "visibility": return .Visibility
	case "enabled": return .Enabled
	case "action": return .Action
	case "slot": return .Slot
	}
	return .Invalid
}

ui_document_style_token_known :: proc(name: string) -> bool {
	switch name {
	case "panel", "panel_border", "control", "control_hot", "control_active", "control_disabled", "text", "text_muted", "accent", "danger", "display", "heading", "body", "small":
		return true
	}
	return false
}

ui_document_constraint_property :: proc(name: string) -> Ui_Document_Constraint_Property {
	switch name {
	case "x": return .X
	case "y": return .Y
	case "width": return .Width
	case "height": return .Height
	case "left": return .Left
	case "right": return .Right
	case "top": return .Top
	case "bottom": return .Bottom
	case "center_x": return .Center_X
	case "center_y": return .Center_Y
	}
	return .Invalid
}

ui_document_constraint_reference :: proc(document: ^Ui_Document, reference: string, allow_viewport: bool) -> (node: int, property: Ui_Document_Constraint_Property, viewport: bool, ok: bool) {
	dot := -1
	for byte, i in reference {
		if byte == '.' do dot = i
	}
	if dot <= 0 || dot >= len(reference) - 1 do return
	owner := reference[:dot]
	property = ui_document_constraint_property(reference[dot + 1:])
	if property == .Invalid do return
	if allow_viewport && owner == "viewport" {
		viewport = true
		node = -1
		ok = true
		return
	}
	node = ui_document_find_node(document, owner)
	ok = node >= 0
	return
}

ui_document_destroy :: proc(document: ^Ui_Document) {
	if document == nil {
		return
	}
	mem.dynamic_arena_destroy(&document.arena)
	document^ = {}
}

ui_document_parse :: proc(data: []byte, out: ^Ui_Document) -> Ui_Document_Validation {
	if out == nil {
		return {.Parse_Failed, -1, "output document is nil"}
	}
	candidate: Ui_Document
	mem.dynamic_arena_init(&candidate.arena)
	allocator := mem.dynamic_arena_allocator(&candidate.arena)
	if json.unmarshal(data, &candidate.source, allocator = allocator) != nil {
		ui_document_destroy(&candidate)
		return {.Parse_Failed, -1, "invalid JSON document"}
	}
	validation := ui_document_validate_and_compile(&candidate, allocator)
	if validation.error != .None {
		ui_document_destroy(&candidate)
		return validation
	}
	ui_document_destroy(out)
	out^ = candidate
	return {}
}

ui_document_load_path :: proc(path: string, out: ^Ui_Document) -> Ui_Document_Validation {
	data, read_error := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_error != nil {
		return {.Read_Failed, -1, "could not read UI document"}
	}
	return ui_document_parse(data, out)
}

ui_document_reload_path :: proc(path: string, active: ^Ui_Document) -> Ui_Document_Validation {
	// ui_document_parse constructs and validates a complete candidate before it
	// destroys and replaces active, so failures preserve the current document.
	return ui_document_load_path(path, active)
}

ui_document_assets_load :: proc(assets: ^Ui_Document_Assets) -> Ui_Document_Validation {
	if assets == nil do return {.Parse_Failed, -1, "UI document assets are nil"}
	candidate: Ui_Document_Assets
	for path, i in UI_DOCUMENT_ASSET_PATHS {
		if result := ui_document_load_path(path, &candidate.documents[i]); result.error != .None {
			ui_document_assets_destroy(&candidate)
			result.index = i
			return result
		}
	}
	candidate.loaded = true
	ui_document_assets_destroy(assets)
	assets^ = candidate
	return {}
}

ui_document_assets_destroy :: proc(assets: ^Ui_Document_Assets) {
	if assets == nil do return
	for i in 0 ..< len(assets.documents) do ui_document_destroy(&assets.documents[i])
	assets^ = {}
}

ui_document_assets_find :: proc(assets: ^Ui_Document_Assets, document_id: string) -> (^Ui_Document, bool) {
	if assets == nil || !assets.loaded do return nil, false
	for i in 0 ..< len(assets.documents) {
		if assets.documents[i].valid && assets.documents[i].source.document_id == document_id {
			return &assets.documents[i], true
		}
	}
	return nil, false
}

ui_document_assets_reload :: proc(assets: ^Ui_Document_Assets, document_id, path: string) -> Ui_Document_Validation {
	active, found := ui_document_assets_find(assets, document_id)
	if !found || active == nil {
		return {.Missing_Document_Id, -1, "active UI document was not found"}
	}
	// Parse into an independent candidate so read, parse, or validation failure
	// cannot mutate the active immutable document.
	candidate: Ui_Document
	result := ui_document_load_path(path, &candidate)
	if result.error != .None {
		ui_document_destroy(&candidate)
		return result
	}
	if candidate.source.document_id != document_id {
		ui_document_destroy(&candidate)
		return {.Missing_Document_Id, -1, "reloaded document_id does not match target"}
	}
	ui_document_destroy(active)
	active^ = candidate
	return {}
}

ui_document_validate_and_compile :: proc(document: ^Ui_Document, allocator: mem.Allocator) -> Ui_Document_Validation {
	if document.source.schema_version != UI_DOCUMENT_SCHEMA_VERSION {
		return {.Unsupported_Version, -1, "unsupported UI document schema version"}
	}
	if len(document.source.document_id) == 0 {
		return {.Missing_Document_Id, -1, "document_id is required"}
	}
	document.nodes = make([dynamic]Ui_Document_Node, 0, len(document.source.nodes), allocator)
	for source, i in document.source.nodes {
		if len(source.id) == 0 {
			return {.Missing_Node_Id, i, "node id is required"}
		}
		for previous in document.source.nodes[:i] {
			if previous.id == source.id {
				return {.Duplicate_Node_Id, i, "node id is duplicated"}
			}
		}
		kind := ui_document_node_kind(source.kind)
		if kind == .Invalid {
			return {.Unknown_Node_Kind, i, "node kind is unknown"}
		}
		if !ui_document_breakpoint_valid(source.layout.breakpoint) {
			return {.Invalid_Breakpoint, i, "node breakpoint is unknown"}
		}
		append(&document.nodes, Ui_Document_Node{source = source, kind = kind, parent_index = -1, template_index = -1})
	}
	for node, i in document.nodes {
		if len(node.source.parent) > 0 {
			parent := ui_document_find_node(document, node.source.parent)
			if parent < 0 {
				return {.Unknown_Parent, i, "node parent is unknown"}
			}
			document.nodes[i].parent_index = parent
		}
		if len(node.source.template) > 0 {
			template := ui_document_find_node(document, node.source.template)
			if template < 0 || document.nodes[template].kind != .Template {
				return {.Unknown_Template, i, "node template is unknown"}
			}
			document.nodes[i].template_index = template
		}
	}
	for _, i in document.nodes {
		if ui_document_chain_cycles(document, i, false) {
			return {.Parent_Cycle, i, "node parent chain contains a cycle"}
		}
		if ui_document_chain_cycles(document, i, true) {
			return {.Template_Cycle, i, "template chain contains a cycle"}
		}
	}
	document.bindings = make([dynamic]Ui_Document_Binding, 0, len(document.source.bindings), allocator)
	for source, i in document.source.bindings {
		for previous in document.source.bindings[:i] {
			if previous.id == source.id {
				return {.Duplicate_Binding_Id, i, "binding id is duplicated"}
			}
		}
		kind := ui_document_binding_kind(source.kind)
		if len(source.id) == 0 || kind == .Invalid {
			return {.Unknown_Binding_Kind, i, "binding id or kind is invalid"}
		}
		append(&document.bindings, Ui_Document_Binding{source, kind})
	}
	for node, i in document.nodes {
		if len(node.source.binding) > 0 {
			binding_index := ui_document_find_binding(document, node.source.binding)
			if binding_index < 0 {
				return {.Unknown_Binding, i, "node binding is not declared"}
			}
			expected := document.bindings[binding_index].kind
			kind_matches := node.kind == .Text && expected == .String ||
			                node.kind == .Image && expected == .Image ||
			                node.kind == .Toggle && expected == .Bool ||
			                node.kind == .Slider && expected == .Float ||
			                node.kind == .Numeric && (expected == .Float || expected == .Integer) ||
			                node.kind == .Selector && expected == .Enum_Index ||
			                node.kind == .Slot && expected == .Slot ||
			                expected == .Visibility || expected == .Enabled
			if !kind_matches {
				return {.Binding_Type_Mismatch, i, "node kind and binding kind do not match"}
			}
		}
		if len(node.source.action) > 0 {
			action_index := ui_document_find_binding(document, node.source.action)
			if action_index < 0 || document.bindings[action_index].kind != .Action {
				return {.Unknown_Binding, i, "node action is not declared as an action binding"}
			}
		}
	}
	document.constraints = make([dynamic]Ui_Document_Constraint, 0, len(document.source.constraints), allocator)
	for constraint, i in document.source.constraints {
		if len(constraint.left) == 0 ||
		   (constraint.relation != "equal" && constraint.relation != "less_equal" && constraint.relation != "greater_equal") ||
		   (constraint.strength != "required" && constraint.strength != "strong" && constraint.strength != "medium" && constraint.strength != "weak") {
			return {.Invalid_Constraint, i, "constraint relation or strength is invalid"}
		}
		left_node, left_property, _, left_ok := ui_document_constraint_reference(document, constraint.left, false)
		right_node, right_property, right_viewport, right_ok := ui_document_constraint_reference(document, constraint.right, true)
		if !left_ok || !right_ok {
			return {.Invalid_Constraint, i, "constraint references an unknown node or layout property"}
		}
		append(&document.constraints, Ui_Document_Constraint{constraint, left_node, left_property, right_node, right_property, right_viewport})
	}
	for token, i in document.source.required_style_tokens {
		if !ui_document_style_token_known(token) {
			return {.Unknown_Required_Style_Token, i, "required style token is unknown"}
		}
	}
	for node, i in document.nodes {
		if node.source.required_style && !ui_document_style_token_known(node.source.style) {
			return {.Unknown_Required_Style_Token, i, "node requires an unknown style token"}
		}
	}
	document.valid = true
	return {}
}

ui_document_find_binding :: proc(document: ^Ui_Document, id: string) -> int {
	for binding, i in document.bindings {
		if binding.source.id == id {
			return i
		}
	}
	return -1
}

ui_document_find_node :: proc(document: ^Ui_Document, id: string) -> int {
	for node, i in document.nodes {
		if node.source.id == id {
			return i
		}
	}
	return -1
}

ui_document_chain_cycles :: proc(document: ^Ui_Document, start: int, template_chain: bool) -> bool {
	current := start
	for _ in 0 ..< len(document.nodes) + 1 {
		current = template_chain ? document.nodes[current].template_index : document.nodes[current].parent_index
		if current < 0 {
			return false
		}
		if current == start {
			return true
		}
	}
	return true
}
