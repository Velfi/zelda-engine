package render2d

import "core:testing"

@(test)
geometry_generation_is_deterministic :: proc(t: ^testing.T) {
    vertices: [dynamic]Vertex
    indices: [dynamic]u32
    defer delete(vertices)
    defer delete(indices)
    append_rectangle(&vertices, &indices, {2, 3, 4, 5}, {255, 255, 255, 255})
    testing.expect_value(t, len(vertices), 4)
    testing.expect_value(t, len(indices), 6)
    testing.expect_value(t, vertices[0].position, Vector2{2, 3})
    testing.expect_value(t, vertices[2].position, Vector2{6, 8})
    expected := [6]u32{0, 1, 2, 0, 2, 3}
    for value, index in indices {
        if index >= len(expected) do break
        testing.expect_value(t, value, expected[index])
    }

    append_line(&vertices, &indices, {0, 0}, {4, 0}, 2, {255, 0, 0, 255})
    testing.expect_value(t, len(vertices), 8)
    testing.expect_value(t, len(indices), 12)

    append_ellipse(&vertices, &indices, {10, 20}, {4, 2}, 8, {0, 255, 0, 255})
    testing.expect_value(t, len(vertices), 18)
    testing.expect_value(t, len(indices), 36)
}

@(test)
camera_clip_and_input_transitions :: proc(t: ^testing.T) {
    camera := Camera2D {
        offset = {10, 20},
        target = {1, 2},
        zoom   = 2,
    }
    testing.expect_value(t, transform_point({3, 5}, camera), Vector2{14, 26})
    clip, visible := intersect_clip({0, 0, 10, 10}, {5, 7, 10, 10})
    testing.expect(t, visible)
    testing.expect_value(t, clip, Rectangle{5, 7, 5, 3})

    input := Input_State{}
    begin_input_frame(&input)
    testing.expect_value(t, input.pinch_scale, f32(1))
    set_mouse_button(&input, .Left, true)
    testing.expect(t, input.mouse_buttons[Mouse_Button.Left].down)
    testing.expect(t, input.mouse_buttons[Mouse_Button.Left].pressed)
    begin_input_frame(&input)
    testing.expect(t, !input.mouse_buttons[Mouse_Button.Left].pressed)
    set_mouse_button(&input, .Left, false)
    testing.expect(t, input.mouse_buttons[Mouse_Button.Left].released)
}

@(test)
renderer_descriptor_requires_consumer_shader_contract :: proc(t: ^testing.T) {
    descriptor := Renderer_Descriptor {
        pipeline = {
            vertex = {
                source_path = "consumer/ui.slang",
                stage = .Vertex,
                entry_point = "vertex_main",
                fallback_base_path = "consumer/ui.vert",
            },
            fragment = {
                source_path = "consumer/ui.slang",
                stage = .Fragment,
                entry_point = "fragment_main",
                fallback_base_path = "consumer/ui.frag",
            },
            push_constant_size = 112,
        },
    }
    testing.expect(t, descriptor_valid(descriptor))
    descriptor.pipeline.fragment.entry_point = ""
    testing.expect(t, !descriptor_valid(descriptor))
}

Mock_World_Post_State :: struct {
    called: bool,
    ctx:    World_Post_Context,
}

mock_world_post_push :: proc(destination: []u8, post_context: World_Post_Context, user_data: rawptr) -> bool {
    state := cast(^Mock_World_Post_State)user_data
    state.called = true
    state.ctx = post_context
    return len(destination) == 112
}

@(test)
world_post_callback_receives_all_extents :: proc(t: ^testing.T) {
    state: Mock_World_Post_State
    descriptor := Renderer_Descriptor {
        user_data              = &state,
        encode_world_post_push = mock_world_post_push,
    }
    payload: [112]u8
    ctx := World_Post_Context {
        source_extent    = {854, 480},
        composite_extent = {1280, 720},
        target_extent    = {1440, 900},
        pass_index       = 1,
        pass_count       = 3,
        pass_parameters  = {1, 2, 3, 4},
    }
    testing.expect(t, descriptor.encode_world_post_push(payload[:], ctx, descriptor.user_data))
    testing.expect(t, state.called)
    testing.expect_value(t, state.ctx, ctx)
}

Mock_Backend_State :: struct {
    created, resized, begun, submitted, texture_updated, screenshot, destroyed: bool,
}

mock_create :: proc(data: rawptr, width, height: i32) -> bool {
    state := cast(^Mock_Backend_State)data
    state.created = width > 0 && height > 0
    return state.created
}
mock_resize :: proc(data: rawptr, width, height: i32) -> bool {state := cast(^Mock_Backend_State)data; state.resized =
        true
    return true}
mock_begin :: proc(data: rawptr) -> bool { state := cast(^Mock_Backend_State)data; state.begun = true; return true }
mock_submit :: proc(data: rawptr) -> bool { state := cast(^Mock_Backend_State)data; state.submitted = true; return(
        true \
    ) }
mock_texture :: proc(data: rawptr, texture: Texture, pixels: []u8) -> bool {state := cast(^Mock_Backend_State)data
    state.texture_updated = true
    return true}
mock_screenshot :: proc(data: rawptr, path: string) -> bool {state := cast(^Mock_Backend_State)data
    state.screenshot = true
    return true}
mock_destroy :: proc(data: rawptr) { state := cast(^Mock_Backend_State)data; state.destroyed = true }

@(test)
runtime_lifecycle_resize_submission_texture_and_teardown :: proc(t: ^testing.T) {
    state: Mock_Backend_State
    descriptor := Renderer_Descriptor {
        pipeline = {vertex = {"v", .Vertex, "main", "v"}, fragment = {"f", .Fragment, "main", "f"}},
    }
    backend := Runtime_Backend {
        user_data           = &state,
        create              = mock_create,
        resize              = mock_resize,
        begin_frame         = mock_begin,
        submit_frame        = mock_submit,
        update_texture_rgba = mock_texture,
        request_screenshot  = mock_screenshot,
        destroy             = mock_destroy,
    }
    runtime: Runtime
    testing.expect(t, runtime_create(&runtime, descriptor, backend, 640, 360))
    testing.expect(t, runtime_resize(&runtime, 1280, 720))
    testing.expect(t, runtime_begin_frame(&runtime))
    testing.expect(t, runtime_submit_frame(&runtime))
    pixels: [16]u8
    testing.expect(t, runtime_update_texture_rgba(&runtime, {1, 2, 2, true}, pixels[:]))
    testing.expect(t, runtime_request_screenshot(&runtime, "capture.png"))
    runtime_destroy(&runtime)
    testing.expect(t, state.created && state.resized && state.begun && state.submitted)
    testing.expect(t, state.texture_updated && state.screenshot && state.destroyed)
}

@(test)
metrics_publish_only_completed_frame :: proc(t: ^testing.T) {
    metrics: Metrics
    metrics_begin_frame(&metrics)
    metrics_record_batches(&metrics, 3)
    metrics_record_draw(&metrics, 4)
    metrics_record_upload(&metrics, 4096)
    testing.expect_value(t, metrics.last.draw_calls, u64(0))
    metrics_end_frame(&metrics)
    testing.expect_value(t, metrics.last.draw_calls, u64(4))
    testing.expect_value(t, metrics.last.batches, u64(3))
    testing.expect_value(t, metrics.last.upload_bytes, u64(4096))
}
