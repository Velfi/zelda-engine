package canvas2d

import "core:math"
import "core:testing"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
import engine "zelda_engine:engine"

characterization_begin :: proc() {
    if state == nil do state = new(State)
    state^ = {}
    state.vertices = make([dynamic]Vertex, 0, 256)
    state.indices = make([dynamic]u32, 0, 384)
    state.batches = make([dynamic]Batch, 0, 32)
    state.texture_count = 4
    state.running = true
    state.mouse_pinch_scale = 1
}

characterization_end :: proc() {
    delete(state.vertices)
    delete(state.indices)
    delete(state.batches)
    if len(state.capture_path) > 0 do delete(state.capture_path)
    state^ = {}
}

expect_vector_near :: proc(t: ^testing.T, actual, expected: Vector2) {
    testing.expectf(t, math.abs(actual.x - expected.x) < .0001, "x: expected %.4f, got %.4f", expected.x, actual.x)
    testing.expectf(t, math.abs(actual.y - expected.y) < .0001, "y: expected %.4f, got %.4f", expected.y, actual.y)
}

@(test)
screenshot_path_is_owned_until_asynchronous_delivery :: proc(t: ^testing.T) {
    characterization_begin()
    defer characterization_end()

    path := [?]u8{'c', 'a', 'p', 't', 'u', 'r', 'e', '.', 'p', 'n', 'g', 0}
    TakeScreenshot(cast(cstring)&path[0])
    path[0] = 'X'

    testing.expect_value(t, state.capture_path, "capture.png")
    testing.expect(t, state.capture_requested)
}

@(test)
screenshot_gpu_pixels_encode_as_png :: proc(t: ^testing.T) {
    screenshot: engine.Screenshot_State
    defer engine.screenshot_state_destroy(&screenshot)
    pixels := [8]u8{0x10, 0x20, 0x30, 0xff, 0xe0, 0xd0, 0xc0, 0xff}
    testing.expect(t, engine.screenshot_state_publish_from_gpu_rgba(&screenshot, pixels[:], 2, 1, .B8G8R8A8_UNORM, 1))
    data, width, height, _, encoded := engine.screenshot_state_copy_png(&screenshot)
    defer if data != nil do delete(data)
    testing.expect(t, encoded)
    testing.expect_value(t, width, u32(2))
    testing.expect_value(t, height, u32(1))
    testing.expect(t, len(data) >= 8)
    if len(data) >= 8 {
        signature := [8]u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}
        for value, index in signature {
            testing.expect_value(t, data[index], value)
        }
    }
}

expect_indices :: proc(t: ^testing.T, expected: []u32) {
    testing.expect_value(t, len(state.indices), len(expected))
    for value, i in expected {
        if i >= len(state.indices) do return
        testing.expectf(t, state.indices[i] == value, "index %d: expected %d, got %d", i, value, state.indices[i])
    }
}

@(test)
plain_rectangles_and_lines_generate_stable_geometry_and_batches :: proc(t: ^testing.T) {
    characterization_begin()
    defer characterization_end()

    DrawRectangleRec({10, 20, 30, 40}, {255, 128, 0, 255})
    DrawLineEx({0, 0}, {10, 0}, 4, {255, 255, 255, 255})

    testing.expect_value(t, len(state.vertices), 8)
    expect_indices(t, []u32{0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7})
    testing.expect_value(t, len(state.batches), 1)
    testing.expect_value(t, state.batches[0].count, u32(12))
    expect_vector_near(t, state.vertices[0].position, {10, 20})
    expect_vector_near(t, state.vertices[2].position, {40, 60})
    expect_vector_near(t, state.vertices[4].position, {0, 2})
    expect_vector_near(t, state.vertices[6].position, {10, -2})
}

@(test)
circles_and_ellipses_generate_deterministic_triangle_fans :: proc(t: ^testing.T) {
    characterization_begin()
    defer characterization_end()

    DrawCircleV({5, 7}, 3, {255, 255, 255, 255})
    DrawEllipseHatched({20, 30}, 8, 4, {180, 180, 180, 255}, segments = 8, rotation = math.PI / 2)

    testing.expect_value(t, len(state.vertices), 16 * 3 + 8 * 3)
    testing.expect_value(t, len(state.indices), 16 * 3 + 8 * 3)
    testing.expect_value(t, len(state.batches), 2)
    testing.expect_value(t, state.batches[0].count, u32(48))
    testing.expect_value(t, state.batches[1].count, u32(24))
    first_indices := [?]u32{0, 1, 2, 3, 4, 5}
    for value, i in first_indices do testing.expect_value(t, state.indices[i], value)
    expect_vector_near(t, state.vertices[0].position, {5, 7})
    expect_vector_near(t, state.vertices[1].position, {8, 7})
    expect_vector_near(t, state.vertices[49].position, {20, 38})
}

@(test)
textured_quads_clipping_and_camera_transforms_are_characterized :: proc(t: ^testing.T) {
    characterization_begin()
    defer characterization_end()

    BeginMode2D({offset = {100, 50}, target = {10, 20}, zoom = 2})
    BeginScissorMode({11, 22, 4, 5})
    DrawTexturePro({id = 2, width = 64, height = 32, ready = true}, {16, 8, 32, 16}, {12, 23, 6, 7})
    EndScissorMode()
    EndMode2D()

    testing.expect_value(t, len(state.vertices), 4)
    expect_indices(t, []u32{0, 1, 2, 0, 2, 3})
    testing.expect_value(t, len(state.batches), 1)
    batch := state.batches[0]
    testing.expect(t, batch.clip_enabled)
    testing.expect_value(t, batch.clip, Rectangle{102, 54, 8, 10})
    testing.expect_value(t, batch.texture, 2)
    expect_vector_near(t, state.vertices[0].position, {104, 56})
    expect_vector_near(t, state.vertices[2].position, {116, 70})
    expect_vector_near(t, state.vertices[0].uv, {.25, .25})
    expect_vector_near(t, state.vertices[2].uv, {.75, .75})
}

@(test)
sdl_mouse_keyboard_pinch_and_frame_edges_translate_deterministically :: proc(t: ^testing.T) {
    characterization_begin()
    defer characterization_end()

    input_begin_frame()
    button_down: sdl.Event
    button_down.type = .MOUSE_BUTTON_DOWN
    button_down.button.button = 1
    button_down.button.x = 23
    button_down.button.y = 41
    translate_sdl_event(&button_down)
    key_down: sdl.Event
    key_down.type = .KEY_DOWN
    key_down.key.scancode = .RETURN
    translate_sdl_event(&key_down)
    pinch: sdl.Event
    pinch.type = .PINCH_UPDATE
    pinch.pinch.scale = 1.25
    translate_sdl_event(&pinch)
    pinch.pinch.scale = .8
    translate_sdl_event(&pinch)

    testing.expect(t, IsMouseButtonDown(.LEFT))
    testing.expect(t, IsMouseButtonPressed(.LEFT))
    testing.expect(t, IsKeyDown(.ENTER))
    testing.expect(t, IsKeyPressed(.ENTER))
    testing.expectf(t, math.abs(GetMousePinchScale() - 1) < .0001, "composed pinch scale should be 1")

    button_up := button_down
    button_up.type = .MOUSE_BUTTON_UP
    translate_sdl_event(&button_up)
    key_up := key_down
    key_up.type = .KEY_UP
    translate_sdl_event(&key_up)
    testing.expect(t, IsMouseButtonPressed(.LEFT))
    testing.expect(t, IsMouseButtonReleased(.LEFT))
    testing.expect(t, !IsMouseButtonDown(.LEFT))
    testing.expect(t, !IsKeyDown(.ENTER))

    input_begin_frame()
    testing.expect(t, !IsMouseButtonPressed(.LEFT))
    testing.expect(t, !IsMouseButtonReleased(.LEFT))
    testing.expect(t, !IsKeyPressed(.ENTER))
    testing.expect_value(t, GetMousePinchScale(), f32(1))
}

@(test)
sdl_focus_loss_releases_held_mouse_and_keyboard_input :: proc(t: ^testing.T) {
    characterization_begin()
    defer characterization_end()

    input_begin_frame()
    button_down: sdl.Event
    button_down.type = .MOUSE_BUTTON_DOWN
    button_down.button.button = 1
    translate_sdl_event(&button_down)
    key_down: sdl.Event
    key_down.type = .KEY_DOWN
    key_down.key.scancode = .RETURN
    translate_sdl_event(&key_down)

    focus_lost: sdl.Event
    focus_lost.type = .WINDOW_FOCUS_LOST
    translate_sdl_event(&focus_lost)

    testing.expect(t, IsMouseButtonPressed(.LEFT))
    testing.expect(t, IsMouseButtonReleased(.LEFT))
    testing.expect(t, !IsMouseButtonDown(.LEFT))
    testing.expect(t, IsKeyPressed(.ENTER))
    testing.expect(t, !IsKeyDown(.ENTER))
}

@(test)
sdl_text_input_and_composition_are_copied_for_the_frame :: proc(t: ^testing.T) {
    characterization_begin()
    defer characterization_end()

    input_begin_frame()
    committed := [?]u8{'c', 'a', 'f', 0xc3, 0xa9, 0}
    text_event: sdl.Event
    text_event.type = .TEXT_INPUT
    text_event.text.text = cast(cstring)&committed[0]
    translate_sdl_event(&text_event)
    testing.expect_value(t, GetTextInput(), "café")

    composing := [?]u8{0xe7, 0x8c, 0xab, 0}
    edit_event: sdl.Event
    edit_event.type = .TEXT_EDITING
    edit_event.edit.text = cast(cstring)&composing[0]
    edit_event.edit.start = 1
    edit_event.edit.length = 2
    translate_sdl_event(&edit_event)
    composition := GetTextInputComposition()
    testing.expect_value(t, composition.text, "猫")
    testing.expect_value(t, composition.start, 1)
    testing.expect_value(t, composition.selection_length, 2)

    input_begin_frame()
    testing.expect_value(t, GetTextInput(), "")
    testing.expect_value(t, GetTextInputComposition().text, "猫")
}

@(test)
sdl_gamepad_buttons_and_ui_focus_navigation_are_characterized :: proc(t: ^testing.T) {
    characterization_begin()
    defer characterization_end()

    // Translation only compares this opaque handle; no SDL function dereferences
    // it in the button-event path.
    state.gamepad = transmute(^sdl.Gamepad)(uintptr(1))
    state.gamepad_id = 17
    gamepad_down: sdl.Event
    gamepad_down.type = .GAMEPAD_BUTTON_DOWN
    gamepad_down.gbutton.which = 17
    gamepad_down.gbutton.button = u8(sdl.GamepadButton.SOUTH)
    translate_sdl_event(&gamepad_down)
    testing.expect(t, IsGamepadButtonDown(.South))
    testing.expect(t, IsGamepadButtonPressed(.South))
    input_begin_frame()
    testing.expect(t, IsGamepadButtonDown(.South))
    testing.expect(t, !IsGamepadButtonPressed(.South))
    gamepad_up := gamepad_down
    gamepad_up.type = .GAMEPAD_BUTTON_UP
    translate_sdl_event(&gamepad_up)
    testing.expect(t, !IsGamepadButtonDown(.South))

    tab: sdl.Event
    tab.type = .KEY_DOWN
    tab.key.scancode = .TAB
    translate_sdl_event(&tab)
    shift: sdl.Event
    shift.type = .KEY_DOWN
    shift.key.scancode = .LSHIFT
    translate_sdl_event(&shift)
    BeginDrawing()
    testing.expect(t, state.gui.input.key_tab)
    testing.expect(t, state.gui.input.key_shift)
    FocusButton(41)
    testing.expect_value(t, state.gui.focused, 42)
    focused := ButtonBehavior(41, {0, 0, 40, 20}, true)
    testing.expect(t, focused.focused)
    state.gamepad = nil
}

@(test)
opaque_effect_quads_preserve_consumer_payload_and_hdr_metadata :: proc(t: ^testing.T) {
    characterization_begin()
    defer characterization_end()
    payload_value := [4]u32{11, 22, 33, 44}
    effect := EffectPayload(77, &payload_value, true)
    DrawEffectQuad({10, 20, 30, 40}, {255, 255, 255, 255}, effect)
    testing.expect_value(t, len(state.vertices), 4)
    testing.expect_value(t, len(state.indices), 6)
    testing.expect_value(t, len(state.batches), 1)
    testing.expect_value(t, state.batches[0].effect.kind, u32(77))
    testing.expect_value(t, state.batches[0].effect.size, size_of(payload_value))
    testing.expect(t, state.batches[0].effect.hdr_required)
    actual := cast(^[4]u32)raw_data(state.batches[0].effect.bytes[:])
    testing.expect_value(t, actual^, payload_value)
}
