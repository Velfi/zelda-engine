package capture

import "core:testing"

Test_State :: struct {
    initialized, fail_initialize, fail_resize, fail_screenshot: bool,
    suppress_screenshot:                                        bool,
    frames, screenshots, resizes, teardowns:                    int,
    last_viewport:                                              Viewport,
}

test_initialize :: proc(data: rawptr, config: ^Config) -> bool {
    state := cast(^Test_State)data
    state.initialized = true
    state.last_viewport = config.viewport
    return !state.fail_initialize
}

test_frame :: proc(data: rawptr, frame: int, config: ^Config) -> Screenshot_Request {
    state := cast(^Test_State)data
    state.frames += 1
    return {requested = frame == 2 && !state.suppress_screenshot}
}

test_resize :: proc(data: rawptr, viewport: Viewport) -> bool {
    state := cast(^Test_State)data
    state.resizes += 1
    state.last_viewport = viewport
    return !state.fail_resize
}

test_screenshot :: proc(data: rawptr, path: string) -> bool {
    state := cast(^Test_State)data
    state.screenshots += 1
    return !state.fail_screenshot
}

test_teardown :: proc(data: rawptr) {
    state := cast(^Test_State)data
    state.teardowns += 1
}

test_callbacks :: proc(state: ^Test_State) -> Callbacks {
    return {
        user_data = state,
        initialize = test_initialize,
        frame = test_frame,
        resize = test_resize,
        screenshot = test_screenshot,
        teardown = test_teardown,
    }
}

test_config :: proc() -> Config {
    return {
        viewport = {1280, 720},
        frame_horizon = 2,
        timeout_frames = 8,
        output_path = "capture.png",
        focus_policy = .Background,
        reduced_motion = true,
        resize_frame = -1,
    }
}

@(test)
successful_capture_and_teardown :: proc(t: ^testing.T) {
    state: Test_State
    harness: Harness
    testing.expect(t, start(&harness, test_config(), test_callbacks(&state)))
    for step(&harness) == .Running {  }
    testing.expect_value(t, harness.status, Status.Complete)
    testing.expect_value(t, state.frames, 3)
    testing.expect_value(t, state.screenshots, 1)
    finish(&harness)
    finish(&harness)
    testing.expect_value(t, state.teardowns, 1)
}

@(test)
initialization_failure_is_reported_without_teardown :: proc(t: ^testing.T) {
    state := Test_State {
        fail_initialize = true,
    }
    harness: Harness
    testing.expect(t, !start(&harness, test_config(), test_callbacks(&state)))
    testing.expect_value(t, harness.error, Error.Initialization_Failed)
    finish(&harness)
    testing.expect_value(t, state.teardowns, 0)
}

@(test)
timeout_is_reported :: proc(t: ^testing.T) {
    state := Test_State {
        suppress_screenshot = true,
    }
    harness: Harness
    config := test_config()
    config.frame_horizon = 6
    config.timeout_frames = 7
    testing.expect(t, start(&harness, config, test_callbacks(&state)))
    for step(&harness) == .Running {  }
    testing.expect_value(t, harness.error, Error.Timed_Out)
    finish(&harness)
}

@(test)
resize_is_explicit_and_failure_is_reported :: proc(t: ^testing.T) {
    state: Test_State
    harness: Harness
    config := test_config()
    config.resize_frame = 1
    config.resize_viewport = {1920, 1080}
    testing.expect(t, start(&harness, config, test_callbacks(&state)))
    _ = step(&harness)
    _ = step(&harness)
    testing.expect_value(t, state.resizes, 1)
    testing.expect_value(t, state.last_viewport, Viewport{1920, 1080})
    finish(&harness)

    state = Test_State {
        fail_resize = true,
    }
    testing.expect(t, start(&harness, config, test_callbacks(&state)))
    _ = step(&harness)
    testing.expect_value(t, step(&harness), Status.Failed)
    testing.expect_value(t, harness.error, Error.Resize_Failed)
    finish(&harness)
}

@(test)
repeated_capture_in_one_process :: proc(t: ^testing.T) {
    state: Test_State
    harness: Harness
    for run in 0 ..< 2 {
        testing.expect(t, start(&harness, test_config(), test_callbacks(&state)))
        for step(&harness) == .Running {  }
        finish(&harness)
    }
    testing.expect_value(t, state.screenshots, 2)
    testing.expect_value(t, state.teardowns, 2)
}
