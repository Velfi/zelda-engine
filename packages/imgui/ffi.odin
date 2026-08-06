package imgui

import "base:runtime"
import "core:c"

@(private)
node_js_ctx: runtime.Context

ImNodeVec2 :: struct {
    x: f32,
    y: f32,
}

ImNodeBoolResult :: struct {
    changed: bool,
    value:   bool,
}

ImNodeI32Result :: struct {
    changed: bool,
    value:   i32,
}

ImNodeF32Result :: struct {
    changed: bool,
    value:   f32,
}

ImNodeColor4Result :: struct {
    changed: bool,
    r:       f32,
    g:       f32,
    b:       f32,
    a:       f32,
}

ImNodeBeginResult :: struct {
    visible: bool,
    open:    bool,
}

ImNodeSelectionResult :: struct {
    changed:   bool,
    selection: i32,
}

_to_vec2 :: #force_inline proc(v: ImNodeVec2) -> Vec2 {
    return {v.x, v.y}
}

_window_flags :: #force_inline proc(bits: u32) -> WindowFlags {
    return transmute(WindowFlags)(c.int(bits))
}

_child_flags :: #force_inline proc(bits: u32) -> ChildFlags {
    return transmute(ChildFlags)(c.int(bits))
}

_slider_flags :: #force_inline proc(bits: u32) -> SliderFlags {
    return transmute(SliderFlags)(c.int(bits))
}

_color_edit_flags :: #force_inline proc(bits: u32) -> ColorEditFlags {
    return transmute(ColorEditFlags)(c.int(bits))
}

@(export)
im_set_odin_ctx :: proc "c" () {
    node_js_ctx = runtime.default_context()
}

@(export)
im_free_tmp_alloc :: proc "c" () {
    context = node_js_ctx
    free_all(context.temp_allocator)
}

@(export)
__im_check_version :: proc "c" () {
    context = node_js_ctx
    CHECKVERSION()
}

@(export)
__im_create_context :: proc "c" () -> rawptr {
    context = node_js_ctx
    return cast(rawptr)CreateContext()
}

@(export)
__im_destroy_context :: proc "c" (ctx: rawptr) {
    context = node_js_ctx
    DestroyContext(cast(^Context)ctx)
}

@(export)
__im_get_current_context :: proc "c" () -> rawptr {
    context = node_js_ctx
    return cast(rawptr)GetCurrentContext()
}

@(export)
__im_set_current_context :: proc "c" (ctx: rawptr) {
    context = node_js_ctx
    SetCurrentContext(cast(^Context)ctx)
}

@(export)
__im_get_io :: proc "c" () -> rawptr {
    context = node_js_ctx
    return cast(rawptr)GetIO()
}

@(export)
__im_new_frame :: proc "c" () {
    context = node_js_ctx
    NewFrame()
}

@(export)
__im_end_frame :: proc "c" () {
    context = node_js_ctx
    EndFrame()
}

@(export)
__im_render :: proc "c" () {
    context = node_js_ctx
    Render()
}

@(export)
__im_style_colors_dark :: proc "c" () {
    context = node_js_ctx
    StyleColorsDark()
}

@(export)
__im_style_colors_light :: proc "c" () {
    context = node_js_ctx
    StyleColorsLight()
}

@(export)
__im_style_colors_classic :: proc "c" () {
    context = node_js_ctx
    StyleColorsClassic()
}

@(export)
__im_show_demo_window :: proc "c" (use_open: bool, open: bool) -> ImNodeBoolResult {
    context = node_js_ctx

    open_state := open
    p_open: ^bool
    if use_open {
        p_open = &open_state
    }

    ShowDemoWindow(p_open)

    return {changed = open_state != open, value = open_state}
}

@(export)
__im_io_add_key_event :: proc "c" (io: rawptr, key: i32, down: bool) {
    if io == nil do return
    context = node_js_ctx
    IO_AddKeyEvent(cast(^IO)io, Key(key), down)
}

@(export)
__im_io_add_mouse_pos_event :: proc "c" (io: rawptr, x, y: f32) {
    if io == nil do return
    context = node_js_ctx
    IO_AddMousePosEvent(cast(^IO)io, x, y)
}

@(export)
__im_io_add_mouse_button_event :: proc "c" (io: rawptr, button: i32, down: bool) {
    if io == nil do return
    context = node_js_ctx
    IO_AddMouseButtonEvent(cast(^IO)io, c.int(button), down)
}

@(export)
__im_io_add_mouse_wheel_event :: proc "c" (io: rawptr, wheel_x, wheel_y: f32) {
    if io == nil do return
    context = node_js_ctx
    IO_AddMouseWheelEvent(cast(^IO)io, wheel_x, wheel_y)
}

@(export)
__im_io_add_input_characters_utf8 :: proc "c" (io: rawptr, text: cstring) {
    if io == nil do return
    context = node_js_ctx
    if text == nil {
        IO_AddInputCharactersUTF8(cast(^IO)io, "")
    } else {
        IO_AddInputCharactersUTF8(cast(^IO)io, text)
    }
}

@(export)
__im_io_set_display_size :: proc "c" (io: rawptr, size: ImNodeVec2) {
    if io == nil do return
    context = node_js_ctx
    io_ref := cast(^IO)io
    io_ref.DisplaySize = _to_vec2(size)
}

@(export)
__im_begin :: proc "c" (name: cstring, use_open: bool, open: bool, window_flags: u32) -> ImNodeBeginResult {
    context = node_js_ctx

    open_state := open
    p_open: ^bool
    if use_open {
        p_open = &open_state
    }

    visible := Begin(name, p_open, _window_flags(window_flags))
    return {visible = visible, open = open_state}
}

@(export)
__im_end :: proc "c" () {
    context = node_js_ctx
    End()
}

@(export)
__im_begin_child :: proc "c" (str_id: cstring, size: ImNodeVec2, child_flags, window_flags: u32) -> bool {
    context = node_js_ctx
    return BeginChild(str_id, _to_vec2(size), _child_flags(child_flags), _window_flags(window_flags))
}

@(export)
__im_end_child :: proc "c" () {
    context = node_js_ctx
    EndChild()
}

@(export)
__im_text :: proc "c" (text: cstring) {
    context = node_js_ctx
    if text == nil {
        Text("%s", "")
    } else {
        Text("%s", text)
    }
}

@(export)
__im_text_unformatted :: proc "c" (text: cstring) {
    context = node_js_ctx
    if text == nil {
        TextUnformatted("")
    } else {
        TextUnformatted(text)
    }
}

@(export)
__im_text_disabled :: proc "c" (text: cstring) {
    context = node_js_ctx
    if text == nil {
        TextDisabled("%s", "")
    } else {
        TextDisabled("%s", text)
    }
}

@(export)
__im_separator_text :: proc "c" (text: cstring) {
    context = node_js_ctx
    if text == nil {
        SeparatorText("")
    } else {
        SeparatorText(text)
    }
}

@(export)
__im_same_line :: proc "c" (offset_from_start_x, spacing: f32) {
    context = node_js_ctx
    SameLine(offset_from_start_x, spacing)
}

@(export)
__im_button :: proc "c" (label: cstring, size: ImNodeVec2) -> bool {
    context = node_js_ctx
    label_value := label
    if label_value == nil do label_value = ""
    return Button(label_value, _to_vec2(size))
}

@(export)
__im_small_button :: proc "c" (label: cstring) -> bool {
    context = node_js_ctx
    label_value := label
    if label_value == nil do label_value = ""
    return SmallButton(label_value)
}

@(export)
__im_checkbox :: proc "c" (label: cstring, value: bool) -> ImNodeBoolResult {
    context = node_js_ctx
    label_value := label
    if label_value == nil do label_value = ""

    value_state := value
    changed := Checkbox(label_value, &value_state)
    return {changed = changed, value = value_state}
}

@(export)
__im_slider_float :: proc "c" (
    label: cstring,
    value, v_min, v_max: f32,
    format: cstring,
    flags: u32,
) -> ImNodeF32Result {
    context = node_js_ctx
    label_value := label
    if label_value == nil do label_value = ""

    value_state := value
    fmt_value := format
    if fmt_value == nil do fmt_value = "%.3f"
    changed := SliderFloat(label_value, &value_state, v_min, v_max, fmt_value, _slider_flags(flags))

    return {changed = changed, value = value_state}
}

@(export)
__im_slider_int :: proc "c" (
    label: cstring,
    value, v_min, v_max: i32,
    format: cstring,
    flags: u32,
) -> ImNodeI32Result {
    context = node_js_ctx
    label_value := label
    if label_value == nil do label_value = ""

    value_state := c.int(value)
    fmt_value := format
    if fmt_value == nil do fmt_value = "%d"
    changed := SliderInt(label_value, &value_state, c.int(v_min), c.int(v_max), fmt_value, _slider_flags(flags))

    return {changed = changed, value = i32(value_state)}
}

@(export)
__im_drag_float :: proc "c" (
    label: cstring,
    value, v_speed, v_min, v_max: f32,
    format: cstring,
    flags: u32,
) -> ImNodeF32Result {
    context = node_js_ctx
    label_value := label
    if label_value == nil do label_value = ""

    value_state := value
    fmt_value := format
    if fmt_value == nil do fmt_value = "%.3f"
    changed := DragFloat(label_value, &value_state, v_speed, v_min, v_max, fmt_value, _slider_flags(flags))

    return {changed = changed, value = value_state}
}

@(export)
__im_drag_int :: proc "c" (
    label: cstring,
    value: i32,
    v_speed: f32,
    v_min, v_max: i32,
    format: cstring,
    flags: u32,
) -> ImNodeI32Result {
    context = node_js_ctx
    label_value := label
    if label_value == nil do label_value = ""

    value_state := c.int(value)
    fmt_value := format
    if fmt_value == nil do fmt_value = "%d"
    changed := DragInt(label_value, &value_state, v_speed, c.int(v_min), c.int(v_max), fmt_value, _slider_flags(flags))

    return {changed = changed, value = i32(value_state)}
}

@(export)
__im_combo_char :: proc "c" (
    label: cstring,
    current_item: i32,
    items: [^]cstring,
    items_count, popup_max_height_in_items: i32,
) -> ImNodeI32Result {
    context = node_js_ctx
    label_value := label
    if label_value == nil do label_value = ""

    cur := c.int(current_item)
    changed := ComboChar(label_value, &cur, items, c.int(items_count), c.int(popup_max_height_in_items))
    return {changed = changed, value = i32(cur)}
}

@(export)
__im_color_edit4 :: proc "c" (label: cstring, r, g, b, a: f32, flags: u32) -> ImNodeColor4Result {
    context = node_js_ctx
    label_value := label
    if label_value == nil do label_value = ""

    color := [4]f32{r, g, b, a}
    changed := ColorEdit4(label_value, &color, _color_edit_flags(flags))

    return {changed = changed, r = color[0], g = color[1], b = color[2], a = color[3]}
}

@(export)
__im_progress_bar :: proc "c" (fraction: f32, size: ImNodeVec2, overlay: cstring) {
    context = node_js_ctx
    ProgressBar(fraction, _to_vec2(size), overlay)
}

@(export)
__im_plot_lines :: proc "c" (
    label: cstring,
    values: [^]f32,
    values_count, values_offset: i32,
    overlay: cstring,
    scale_min, scale_max: f32,
    graph_size: ImNodeVec2,
    stride: i32,
) {
    context = node_js_ctx
    label_value := label
    if label_value == nil do label_value = ""

    stride_value := c.int(stride)
    if stride_value <= 0 do stride_value = c.int(size_of(f32))
    PlotLines(
        label_value,
        values,
        c.int(values_count),
        c.int(values_offset),
        overlay,
        scale_min,
        scale_max,
        _to_vec2(graph_size),
        stride_value,
    )
}

@(export)
__im_set_scroll_here_y :: proc "c" (center_y_ratio: f32) {
    context = node_js_ctx
    SetScrollHereY(center_y_ratio)
}

@(export)
__im_push_id :: proc "c" (value: cstring) {
    context = node_js_ctx
    value_text := value
    if value_text == nil do value_text = ""
    PushID(value_text)
}

@(export)
__im_push_id_ptr :: proc "c" (value: uintptr) {
    context = node_js_ctx
    PushIDPtr(transmute(rawptr)value)
}

@(export)
__im_pop_id :: proc "c" () {
    context = node_js_ctx
    PopID()
}

@(export)
__im_begin_disabled :: proc "c" (disabled: bool) {
    context = node_js_ctx
    BeginDisabled(disabled)
}

@(export)
__im_end_disabled :: proc "c" () {
    context = node_js_ctx
    EndDisabled()
}

@(export)
__im_curve :: proc "c" (
    label: cstring,
    size: ImNodeVec2,
    maxpoints: i32,
    points: ^ImNodeVec2,
    use_selection: bool,
    selection: i32,
    range_min: ImNodeVec2,
    range_max: ImNodeVec2,
) -> ImNodeSelectionResult {
    context = node_js_ctx
    label_value := label
    if label_value == nil do label_value = ""

    selection_state := c.int(selection)
    selection_ptr: ^c.int
    if use_selection {
        selection_ptr = &selection_state
    }

    changed :=
        Curve(
            label_value,
            _to_vec2(size),
            c.int(maxpoints),
            cast(^Vec2)points,
            selection_ptr,
            _to_vec2(range_min),
            _to_vec2(range_max),
        ) !=
        0

    return {changed = changed, selection = i32(selection_state)}
}

@(export)
__im_curve_value :: proc "c" (p: f32, maxpoints: i32, points: ^ImNodeVec2) -> f32 {
    context = node_js_ctx
    return CurveValue(p, c.int(maxpoints), cast(^Vec2)points)
}

@(export)
__im_curve_value_smooth :: proc "c" (p: f32, maxpoints: i32, points: ^ImNodeVec2) -> f32 {
    context = node_js_ctx
    return CurveValueSmooth(p, c.int(maxpoints), cast(^Vec2)points)
}
