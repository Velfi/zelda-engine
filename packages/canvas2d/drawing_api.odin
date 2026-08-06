package canvas2d

import "core:image"
import _ "core:image/png"
import "core:math"
import "core:mem"
import "core:os"
import "core:time"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
import engine "zelda_engine:engine"
import render2d "zelda_engine:render2d"
import resources "zelda_engine:render_resources"
import ui "zelda_engine:ui"

SetConfigFlags :: proc(flags: ConfigFlags) { state_ensure().config_flags = flags }
SetBodyFontPath :: proc(path: cstring) -> bool { return ui.gui_set_body_font_path(path) }
SetDisplayFontPath :: proc(path: cstring) -> bool { return ui.gui_set_display_font_path(path) }
AddBodyFontFallbackPath :: proc(path: cstring) -> bool {
    return ui.gui_add_font_fallback_path(.Body, path)
}
AddDisplayFontFallbackPath :: proc(path: cstring) -> bool {
    return ui.gui_add_font_fallback_path(.Display, path)
}
TextNextGrapheme :: proc(text: string) -> int {
    return ui.gui_text_next_grapheme(transmute([]u8)text)
}
TextPreviousGrapheme :: proc(text: string, offset: int) -> int {
    return ui.gui_text_previous_grapheme(transmute([]u8)text, offset)
}
TextNextWord :: proc(text: string) -> int {
    return ui.gui_text_next_word(transmute([]u8)text)
}
TextNextLineBreak :: proc(text: string) -> int {
    return ui.gui_text_next_line_break(transmute([]u8)text)
}
SetVSyncEnabled :: proc(enabled: bool) {
    canvas := state_ensure()
    if enabled {
        canvas.config_flags += {.VSYNC_HINT}
    } else {
        canvas.config_flags -= {.VSYNC_HINT}
    }
    engine.vk_set_vsync_enabled(&canvas.ctx, enabled)
}
InitWindow :: proc(width, height: i32, title: cstring) -> bool {
    state_ensure()
    if state.initialized {
        vk.load_proc_addresses(cast(rawptr)sdl.Vulkan_GetVkGetInstanceProcAddr())
        vk.load_proc_addresses(state.ctx.instance)
        vk.load_proc_addresses(state.ctx.device)
        state.running = true
        return true
    }
    state.width = width; state.height = height
    state.running = true
    state.start = time.tick_now()
    when ODIN_OS == .Darwin {
        if os.get_env("SDL_VULKAN_LIBRARY", context.temp_allocator) == "" {
            if _, err := os.stat("/opt/homebrew/lib/libvulkan.1.dylib", context.temp_allocator); err == nil do _ = os.set_env("SDL_VULKAN_LIBRARY", "/opt/homebrew/lib/libvulkan.1.dylib")
        }
        // A non-focusable capture window must not activate the application either.
        // SDL's window flag alone prevents window focus, but macOS can still bring
        // the application to the foreground while initializing its video backend.
        if .WINDOW_NOT_FOCUSABLE in state.config_flags do _ = sdl.SetHint(sdl.HINT_MAC_BACKGROUND_APP, "1")
    }
    if executable_dir, err := os.get_executable_directory(context.temp_allocator); err == nil && os.is_dir(executable_dir) do _ = os.chdir(executable_dir)
    window_config := render2d.SDL_Window_Config {
        resizable     = .WINDOW_RESIZABLE in state.config_flags,
        high_dpi      = .WINDOW_HIGHDPI in state.config_flags,
        not_focusable = .WINDOW_NOT_FOCUSABLE in state.config_flags,
    }
    if !render2d.sdl_window_create(&state.platform_window, width, height, title, window_config) do return false
    state.window = state.platform_window.handle
    state.initialized = backend_init()
    state.running = state.initialized
    return state.initialized
}
CloseWindow :: proc() { if state != nil do backend_destroy() }
DestroyPersistentState :: proc() {
    if state == nil do return
    backend_destroy()
    free(state)
    state = nil
}
SetWindowMinSize :: proc(width, height: i32) {_ = render2d.sdl_window_set_minimum_size(
        &state.platform_window,
        width,
        height,
    )}
SetWindowSize :: proc(width, height: i32) { _ = render2d.sdl_window_set_size(&state.platform_window, width, height) }
SetTargetFPS :: proc(fps: i32) {  }
GetScreenWidth :: proc() -> i32 {if width, height, ok := render2d.sdl_window_size(&state.platform_window); ok do state.width, state.height = width, height
    return state.width}
GetScreenHeight :: proc() -> i32 {if width, height, ok := render2d.sdl_window_size(&state.platform_window); ok do state.width, state.height = width, height
    return state.height}
GetWorldRenderSize :: proc() -> (width, height: i32) {
    if state.world_render_width > 0 && state.world_render_height > 0 {
        return i32(state.world_render_width), i32(state.world_render_height)
    }
    return GetScreenWidth(), GetScreenHeight()
}
GetTime :: proc() -> f64 {
    if state == nil do return 0
    return time.duration_seconds(time.tick_since(state.start))
}
GetGpuFrameTimeMs :: proc() -> (ms: f64, available: bool) {
    sample := engine.gpu_profiler_last_sample(&state.ctx)
    return sample.frame_ms, sample.supported && sample.enabled && sample.valid
}

draw_effect_quad_points :: proc(a, b, c, d: Vector2, color: Color, effect: Effect_Payload, texture := Texture{}) {
    if effect.size <= 0 ||
       effect.size > MAX_EFFECT_PAYLOAD_SIZE ||
       len(state.vertices) + 4 > MAX_VERTICES ||
       len(state.indices) + 6 > MAX_INDICES {
        return
    }
    ta, tb, tc, td := transform(a), transform(b), transform(c), transform(d)
    base := u32(len(state.vertices))
    t := to_color(color)
    append(&state.vertices, Vertex{ta, {0, 0}, t}, Vertex{tb, {1, 0}, t}, Vertex{tc, {1, 1}, t}, Vertex{td, {0, 1}, t})
    first := u32(len(state.indices))
    append(&state.indices, base, base + 1, base + 2, base, base + 2, base + 3)
    texture_id := -1
    if texture.ready do texture_id = texture.id
    append_batch(first, 6, texture_id, HATCH_DISABLED, effect)
}

draw_effect_quad :: proc(bounds: Rectangle, color: Color, effect: Effect_Payload, texture := Texture{}) {
    if bounds.width <= 0 || bounds.height <= 0 do return
    draw_effect_quad_points(
        {bounds.x, bounds.y},
        {bounds.x + bounds.width, bounds.y},
        {bounds.x + bounds.width, bounds.y + bounds.height},
        {bounds.x, bounds.y + bounds.height},
        color,
        effect,
        texture,
    )
}
GetRenderMetrics :: proc() -> render2d.Frame_Metrics { return state.metrics.last }
@(no_instrumentation)
GetMousePosition :: #force_inline proc() -> Vector2 { return state.mouse }
GetWorldMousePosition :: proc() -> (position: Vector2, inside: bool) {
    if state.world_render_width == 0 || state.world_render_height == 0 {
        return state.mouse, true
    }
    window_width := f32(max(GetScreenWidth(), 1))
    window_height := f32(max(GetScreenHeight(), 1))
    world_width := f32(state.world_render_width)
    world_height := f32(state.world_render_height)
    scale := min(window_width / world_width, window_height / world_height)
    viewport_width := world_width * scale
    viewport_height := world_height * scale
    viewport_x := (window_width - viewport_width) * .5
    viewport_y := (window_height - viewport_height) * .5
    position = {(state.mouse.x - viewport_x) / scale, (state.mouse.y - viewport_y) / scale}
    inside =
        state.mouse.x >= viewport_x &&
        state.mouse.y >= viewport_y &&
        state.mouse.x < viewport_x + viewport_width &&
        state.mouse.y < viewport_y + viewport_height
    return
}
GetMouseDelta :: proc() -> Vector2 { return state.mouse_delta }
GetMouseWheelMove :: proc() -> f32 { return state.mouse_wheel }
GetMouseWheelMoveV :: proc() -> Vector2 { return state.mouse_wheel_delta }
GetMousePinchScale :: proc() -> f32 { return state.mouse_pinch_scale }
IsMouseButtonPressed :: proc(button: MouseButton) -> bool {assert(button != .COUNT); return(
        state.mouse_pressed[int(button)] \
    )}
// Claims a pointer activation so lower-priority input handlers do not also
// respond to the same click during the current frame.
ConsumeMouseButtonPressed :: proc(button: MouseButton) {assert(button != .COUNT)
    state.mouse_pressed[int(button)] = false}
IsMouseButtonDown :: proc(button: MouseButton) -> bool {assert(button != .COUNT); return state.mouse_down[int(button)]}
IsMouseButtonReleased :: proc(button: MouseButton) -> bool {assert(button != .COUNT); return(
        state.mouse_released[int(button)] \
    )}
@(no_instrumentation)
keyboard_key_scancodes :: #force_inline proc(key: KeyboardKey) -> (primary, alternate: sdl.Scancode) {assert(
        key != .COUNT,
    )
    switch
    key {
    case .ESCAPE:
        return .ESCAPE, .UNKNOWN
    case .ENTER:
        return .RETURN, .KP_ENTER
    case .TAB:
        return .TAB, .UNKNOWN
    case .LEFT_SHIFT:
        return .LSHIFT, .UNKNOWN
    case .RIGHT_SHIFT:
        return .RSHIFT, .UNKNOWN
    case .BACKSPACE:
        return .BACKSPACE, .UNKNOWN
    case .W:
        return .W, .UNKNOWN
    case .A:
        return .A, .UNKNOWN
    case .B:
        return .B, .UNKNOWN
    case .C:
        return .C, .UNKNOWN
    case .D:
        return .D, .UNKNOWN
    case .E:
        return .E, .UNKNOWN
    case .F:
        return .F, .UNKNOWN
    case .G:
        return .G, .UNKNOWN
    case .H:
        return .H, .UNKNOWN
    case .I:
        return .I, .UNKNOWN
    case .J:
        return .J, .UNKNOWN
    case .K:
        return .K, .UNKNOWN
    case .L:
        return .L, .UNKNOWN
    case .M:
        return .M, .UNKNOWN
    case .N:
        return .N, .UNKNOWN
    case .O:
        return .O, .UNKNOWN
    case .P:
        return .P, .UNKNOWN
    case .S:
        return .S, .UNKNOWN
    case .Q:
        return .Q, .UNKNOWN
    case .R:
        return .R, .UNKNOWN
    case .T:
        return .T, .UNKNOWN
    case .U:
        return .U, .UNKNOWN
    case .V:
        return .V, .UNKNOWN
    case .Y:
        return .Y, .UNKNOWN
    case .Z:
        return .Z, .UNKNOWN
    case .X:
        return .X, .UNKNOWN
    case .UP:
        return .UP, .UNKNOWN
    case .DOWN:
        return .DOWN, .UNKNOWN
    case .LEFT:
        return .LEFT, .UNKNOWN
    case .RIGHT:
        return .RIGHT, .UNKNOWN
    case .LEFT_BRACKET:
        return .LEFTBRACKET, .UNKNOWN
    case .RIGHT_BRACKET:
        return .RIGHTBRACKET, .UNKNOWN
    case .ONE:
        return ._1, .KP_1
    case .TWO:
        return ._2, .KP_2
    case .THREE:
        return ._3, .KP_3
    case .FOUR:
        return ._4, .KP_4
    case .SPACE:
        return .SPACE, .UNKNOWN
    case .COUNT:
        unreachable()
    }
    unreachable()}
@(no_instrumentation)
IsKeyPressed :: #force_inline proc(key: KeyboardKey) -> bool {primary, alternate := keyboard_key_scancodes(key)
    return state.keys_pressed[int(primary)] || alternate != .UNKNOWN && state.keys_pressed[int(alternate)]}
// Adds a product-supplied key activation to the current input frame. This is
// useful for on-screen controls that mirror physical keyboard actions.
InjectKeyPressed :: proc(key: KeyboardKey) {primary, _ := keyboard_key_scancodes(key)
    state.keys_pressed[int(primary)] = true}
@(no_instrumentation)
IsKeyDown :: #force_inline proc(key: KeyboardKey) -> bool {primary, alternate := keyboard_key_scancodes(key)
    return state.keys_down[int(primary)] || alternate != .UNKNOWN && state.keys_down[int(alternate)]}
gamepad_sdl_button :: proc(button: Gamepad_Button) -> sdl.GamepadButton {switch button {case .South:
        return .SOUTH; case .East:
        return .EAST; case .West:
        return .WEST; case .North:
        return .NORTH; case .Left_Shoulder:
        return .LEFT_SHOULDER; case .Right_Shoulder:
        return .RIGHT_SHOULDER; case .Dpad_Up:
        return .DPAD_UP; case .Dpad_Down:
        return .DPAD_DOWN; case .Dpad_Left:
        return .DPAD_LEFT; case .Dpad_Right:
        return .DPAD_RIGHT; case .Back:
        return .BACK; case .Start:
        return .START; case .Count:
        unreachable()}
    unreachable()}
GamepadAvailable :: proc() -> bool { return state.gamepad != nil }
IsGamepadButtonDown :: proc(button: Gamepad_Button) -> bool {return(
        button != .Count &&
        state.gamepad_down[int(button)] \
    )}
IsGamepadButtonPressed :: proc(button: Gamepad_Button) -> bool {return(
        button != .Count &&
        state.gamepad_pressed[int(button)] \
    )}
GetGamepadAxis :: proc(axis: Gamepad_Axis) -> f32 {
    if state.gamepad == nil do return 0
    sdl_axis: sdl.GamepadAxis; switch axis {case .Left_X:
        sdl_axis = .LEFTX; case .Left_Y:
        sdl_axis = .LEFTY; case .Right_X:
        sdl_axis = .RIGHTX; case .Right_Y:
        sdl_axis = .RIGHTY; case .Left_Trigger:
        sdl_axis = .LEFT_TRIGGER; case .Right_Trigger:
        sdl_axis = .RIGHT_TRIGGER}
    return clamp(f32(sdl.GetGamepadAxis(state.gamepad, sdl_axis)) / 32767, -1, 1)
}
FocusButton :: proc(id: int) { state.gui.focused = ui.Gui_Id(id + 1) }

input_begin_frame :: proc() {
    state.text_input_length = 0
    render2d.sdl_input_begin_frame(&state.platform_input)
    state.mouse_down = state.platform_input.mouse_down
    state.mouse_pressed = state.platform_input.mouse_pressed
    state.mouse_released = state.platform_input.mouse_released
    state.mouse_delta = state.platform_input.mouse_delta
    state.mouse_wheel = state.platform_input.mouse_wheel
    state.mouse_wheel_delta = state.platform_input.mouse_wheel_delta
    state.mouse_pinch_scale = state.platform_input.mouse_pinch_scale
    state.keys_pressed = state.platform_input.keys_pressed
    state.gamepad_pressed = {}
}

translate_sdl_event :: proc(e: ^sdl.Event) {
    #partial switch e.type {
    case .TEXT_INPUT:
        text := string(e.text.text)
        remaining := len(state.text_input) - state.text_input_length
        count := min(len(text), remaining)
        if count > 0 {
            copy(state.text_input[state.text_input_length:], transmute([]u8)text[:count])
            state.text_input_length += count
        }
    case .TEXT_EDITING:
        state.text_composition = {}
        text := string(e.edit.text)
        state.text_composition_length = min(len(text), len(state.text_composition))
        if state.text_composition_length > 0 {
            copy(
                state.text_composition[:state.text_composition_length],
                transmute([]u8)text[:state.text_composition_length],
            )
        }
        state.text_composition_start = int(e.edit.start)
        state.text_composition_selection_length = int(e.edit.length)
    }
    // Seed the adapter from compatibility state while callers migrate.
    state.platform_input.gamepad = state.gamepad
    state.platform_input.gamepad_id = state.gamepad_id
    render2d.sdl_process_event(&state.platform_input, e)
    p := &state.platform_input
    state.mouse = p.mouse
    state.mouse_delta = p.mouse_delta
    state.mouse_wheel = p.mouse_wheel
    state.mouse_wheel_delta = p.mouse_wheel_delta
    state.mouse_pinch_scale = p.mouse_pinch_scale
    state.mouse_down = p.mouse_down
    state.mouse_pressed = p.mouse_pressed
    state.mouse_released = p.mouse_released
    state.keys_down = p.keys_down
    state.keys_pressed = p.keys_pressed
    state.gamepad = p.gamepad
    state.gamepad_id = p.gamepad_id
    for button in Gamepad_Button {
        if button == .Count do continue
        raw := int(gamepad_sdl_button(button))
        state.gamepad_down[int(button)] = p.gamepad_down[raw]
        state.gamepad_pressed[int(button)] = p.gamepad_pressed[raw]
    }
    if p.quit_requested do state.running = false
    if p.resize_requested do state.ctx.needs_swapchain_recreate = true
}

Text_Input_Composition :: struct {
    text:             string,
    start:            int,
    selection_length: int,
}

StartTextInput :: proc() -> bool {
    if state == nil || state.window == nil do return false
    return sdl.StartTextInput(state.window)
}

StopTextInput :: proc() -> bool {
    if state == nil || state.window == nil do return false
    state.text_composition_length = 0
    return sdl.StopTextInput(state.window)
}

SetTextInputArea :: proc(bounds: Rectangle, cursor: int) -> bool {
    if state == nil || state.window == nil do return false
    area := sdl.Rect{i32(bounds.x), i32(bounds.y), i32(bounds.width), i32(bounds.height)}
    return sdl.SetTextInputArea(state.window, &area, i32(cursor))
}

GetTextInput :: proc() -> string {
    if state == nil do return ""
    return string(state.text_input[:state.text_input_length])
}

GetTextInputComposition :: proc() -> Text_Input_Composition {
    if state == nil do return {}
    return {
        text = string(state.text_composition[:state.text_composition_length]),
        start = state.text_composition_start,
        selection_length = state.text_composition_selection_length,
    }
}

WindowShouldClose :: proc() -> bool {
    input_begin_frame()
    e: sdl.Event
    for sdl.PollEvent(&e) do translate_sdl_event(&e)
    return !state.running}

BeginDrawing :: proc() {
    state.glyph_frame += 1
    render2d.metrics_begin_frame(&state.metrics)
    state.gfx_frame_signpost = gfx_profile_begin(.Frame)
    clear(&state.vertices); clear(&state.indices); clear(&state.batches)
    state.camera_active = false
    state.clip_enabled = false
    state.clip = {}
    input := ui.Input_State {
        window_width    = state.width,
        window_height   = state.height,
        mouse_pos       = {state.mouse.x, state.mouse.y},
        mouse_down      = state.mouse_down[int(MouseButton.LEFT)],
        mouse_pressed   = state.mouse_pressed[int(MouseButton.LEFT)],
        mouse_released  = state.mouse_released[int(MouseButton.LEFT)],
        key_tab         = IsKeyPressed(.TAB),
        key_shift       = IsKeyDown(.LEFT_SHIFT) || IsKeyDown(.RIGHT_SHIFT),
        key_enter       = IsKeyPressed(.ENTER),
        accept          = IsKeyPressed(.ENTER),
        accept_pressed  = IsKeyPressed(.ENTER),
        active_device   = .Mouse_Keyboard,
        pointer_enabled = true,
    }
    ui.gui_begin_frame(&state.gui, input)}
ClearBackground :: proc(color: Color) { state.clear = color }
BeginMode2D :: proc(camera: Camera2D) {state.camera = camera; state.camera_active = true
    state.gui.input.mouse_pos = {
        (state.mouse.x - camera.offset.x) / camera.zoom + camera.target.x,
        (state.mouse.y - camera.offset.y) / camera.zoom + camera.target.y,
    }}
EndMode2D :: proc() { state.camera_active = false }
BeginScissorMode :: proc(r: Rectangle) {
    a := transform({r.x, r.y})
    b := transform({r.x + r.width, r.y + r.height})
    state.clip = {min(a.x, b.x), min(a.y, b.y), math.abs(b.x - a.x), math.abs(b.y - a.y)}
    state.clip_enabled = true
}
EndScissorMode :: proc() { state.clip_enabled = false; state.clip = {} }
ButtonBehavior :: proc(id: int, r: Rectangle, enabled: bool) -> Button_Interaction {gui_id := ui.Gui_Id(id + 1)
    activated := ui.gui_button_behavior(&state.gui, gui_id, {r.x, r.y, r.width, r.height}, enabled)
    return {activated, state.gui.hot == gui_id, state.gui.focused == gui_id}}
DrawRectangle :: proc(x, y, width, height: i32, color: Color) {rect({f32(x), f32(y), f32(width), f32(height)}, color)}
DrawRectangleRec :: proc(r: Rectangle, color: Color) { rect(r, color) }
// A material-space quad for projected procedural geometry. UVs remain attached
// to the supplied corners while the hatch offset/rotation can be aligned to a
// projected surface tangent by the caller.
DrawQuadHatched :: proc(a, b, c, d: Vector2, color: Color, config := default_hatch) {
    // The shader's edge-softness term is radial in UV space and belongs to
    // circular primitives. Passing it through here clips an arbitrary face to an
    // inscribed disc, leaving the corners of otherwise valid polygons bare.
    quad_config := config
    quad_config.edge_softness = 0
    quad(transform(a), transform(b), transform(c), transform(d), color, {0, 0}, {1, 1}, -1, quad_config)
}
DrawRectangleRounded :: proc(r: Rectangle, roundness: f32, segments: i32, color: Color) { rect(r, color) }
DrawRectangleRoundedLinesEx :: proc(r: Rectangle, roundness: f32, segments: i32, thickness: f32, color: Color) {rect(
        {r.x, r.y, r.width, thickness},
        color,
    )
    rect({r.x, r.y + r.height - thickness, r.width, thickness}, color)
    rect({r.x, r.y, thickness, r.height}, color)
    rect({r.x + r.width - thickness, r.y, thickness, r.height}, color)}
DrawLineEx :: proc(a, b: Vector2, thickness: f32, color: Color) {d := Vector2{b.x - a.x, b.y - a.y}
    length := f32(math.sqrt(f64(d.x * d.x + d.y * d.y)))
    if length <= 0 do return
    n := Vector2{-d.y / length * thickness * .5, d.x / length * thickness * .5}
    quad(
        transform({a.x + n.x, a.y + n.y}),
        transform({b.x + n.x, b.y + n.y}),
        transform({b.x - n.x, b.y - n.y}),
        transform({a.x - n.x, a.y - n.y}),
        color,
    )}
DrawRibbonHatched :: proc(points: []Vector2, half_widths: []f32, color: Color, config := default_hatch) {
    point_count := len(points)
    if point_count < 2 || len(half_widths) != point_count do return
    for i in 0 ..< point_count - 1 {
        previous_a := i > 0 ? points[i - 1] : points[i]
        next_a := points[i + 1]
        previous_b := points[i]
        next_b := i + 2 < point_count ? points[i + 2] : points[i + 1]
        tangent_a := Vector2{next_a.x - previous_a.x, next_a.y - previous_a.y}
        tangent_b := Vector2{next_b.x - previous_b.x, next_b.y - previous_b.y}
        length_a := f32(math.sqrt(f64(tangent_a.x * tangent_a.x + tangent_a.y * tangent_a.y)))
        length_b := f32(math.sqrt(f64(tangent_b.x * tangent_b.x + tangent_b.y * tangent_b.y)))
        if length_a <= 1.0e-5 || length_b <= 1.0e-5 do continue
        normal_a := Vector2{-tangent_a.y / length_a * half_widths[i], tangent_a.x / length_a * half_widths[i]}
        normal_b := Vector2{-tangent_b.y / length_b * half_widths[i + 1], tangent_b.x / length_b * half_widths[i + 1]}
        u0 := f32(i) / f32(point_count - 1)
        u1 := f32(i + 1) / f32(point_count - 1)
        quad(
            transform({points[i].x + normal_a.x, points[i].y + normal_a.y}),
            transform({points[i + 1].x + normal_b.x, points[i + 1].y + normal_b.y}),
            transform({points[i + 1].x - normal_b.x, points[i + 1].y - normal_b.y}),
            transform({points[i].x - normal_a.x, points[i].y - normal_a.y}),
            color,
            {u0, 0},
            {u1, 1},
            -1,
            config,
        )
    }
}
DrawCircleV :: proc(center: Vector2, radius: f32, color: Color) {segments := 16; c := transform(center)
    for i := 0; i < segments; i += 1 {
        a := f32(i) * 2 * math.PI / f32(segments)
        b := f32(i + 1) * 2 * math.PI / f32(segments)
        p1 := transform({center.x + radius * f32(math.cos(f64(a))), center.y + radius * f32(math.sin(f64(a)))})
        p2 := transform({center.x + radius * f32(math.cos(f64(b))), center.y + radius * f32(math.sin(f64(b)))})
        base := u32(len(state.vertices))
        t := to_color(color)
        append(&state.vertices, Vertex{c, {}, t}, Vertex{p1, {}, t}, Vertex{p2, {}, t})
        first := u32(len(state.indices))
        append(&state.indices, base, base + 1, base + 2)
        append_batch(first, 3, -1)}}
DrawCircleHatched :: proc(center: Vector2, radius: f32, color: Color, config := default_hatch, segments: int = 64) {
    if radius <= 0 || segments < 3 do return
    c := transform(center)
    for i in 0 ..< segments {
        a := f32(i) * 2 * math.PI / f32(segments)
        b := f32(i + 1) * 2 * math.PI / f32(segments)
        cos_a, sin_a := f32(math.cos(f64(a))), f32(math.sin(f64(a)))
        cos_b, sin_b := f32(math.cos(f64(b))), f32(math.sin(f64(b)))
        p1 := transform({center.x + radius * cos_a, center.y + radius * sin_a})
        p2 := transform({center.x + radius * cos_b, center.y + radius * sin_b})
        base := u32(len(state.vertices))
        t := to_color(color)
        append(
            &state.vertices,
            Vertex{c, {.5, .5}, t},
            Vertex{p1, {.5 + cos_a * .5, .5 + sin_a * .5}, t},
            Vertex{p2, {.5 + cos_b * .5, .5 + sin_b * .5}, t},
        )
        first := u32(len(state.indices))
        append(&state.indices, base, base + 1, base + 2)
        append_batch(first, 3, -1, config)
    }
}
DrawEllipseHatched :: proc(
    center: Vector2,
    radius_x, radius_y: f32,
    color: Color,
    config := default_hatch,
    segments: int = 64,
    rotation: f32 = 0,
    irregularity: f32 = 0,
    phase: f32 = 0,
) {
    if radius_x <= 0 || radius_y <= 0 || segments < 3 do return
    c := transform(center)
    cos_rotation, sin_rotation := f32(math.cos(f64(rotation))), f32(math.sin(f64(rotation)))
    for i in 0 ..< segments {
        a := f32(i) * 2 * math.PI / f32(segments)
        b := f32(i + 1) * 2 * math.PI / f32(segments)
        cos_a, sin_a := f32(math.cos(f64(a))), f32(math.sin(f64(a)))
        cos_b, sin_b := f32(math.cos(f64(b))), f32(math.sin(f64(b)))
        warp_a :=
            1 +
            f32(math.sin(f64(a * 3 + phase))) * irregularity +
            f32(math.sin(f64(a * 5 - phase * .7))) * irregularity * .45
        warp_b :=
            1 +
            f32(math.sin(f64(b * 3 + phase))) * irregularity +
            f32(math.sin(f64(b * 5 - phase * .7))) * irregularity * .45
        local_a := Vector2{radius_x * cos_a * warp_a, radius_y * sin_a * warp_a}
        local_b := Vector2{radius_x * cos_b * warp_b, radius_y * sin_b * warp_b}
        p1 := transform(
            {
                center.x + local_a.x * cos_rotation - local_a.y * sin_rotation,
                center.y + local_a.x * sin_rotation + local_a.y * cos_rotation,
            },
        )
        p2 := transform(
            {
                center.x + local_b.x * cos_rotation - local_b.y * sin_rotation,
                center.y + local_b.x * sin_rotation + local_b.y * cos_rotation,
            },
        )
        base := u32(len(state.vertices))
        t := to_color(color)
        append(
            &state.vertices,
            Vertex{c, {.5, .5}, t},
            Vertex{p1, {.5 + cos_a * .5, .5 + sin_a * .5}, t},
            Vertex{p2, {.5 + cos_b * .5, .5 + sin_b * .5}, t},
        )
        first := u32(len(state.indices))
        append(&state.indices, base, base + 1, base + 2)
        append_batch(first, 3, -1, config)
    }
}
