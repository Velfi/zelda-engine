package capture

// The capture harness owns sequencing only. Window creation, rendering and
// screenshot delivery remain callbacks so products can use any presentation
// backend without introducing a renderer dependency here.

Focus_Policy :: enum {
    Normal,
    Background,
}

Viewport :: struct {
    width, height: i32,
}

Error :: enum {
    None,
    Invalid_Config,
    Initialization_Failed,
    Resize_Failed,
    Screenshot_Failed,
    Timed_Out,
}

Status :: enum {
    Idle,
    Running,
    Complete,
    Failed,
    Torn_Down,
}

Config :: struct {
    viewport:        Viewport,
    frame_horizon:   int,
    timeout_frames:  int,
    output_path:     string,
    focus_policy:    Focus_Policy,
    reduced_motion:  bool,
    // Negative disables resizing.
    resize_frame:    int,
    resize_viewport: Viewport,
}

Callbacks :: struct {
    user_data:  rawptr,
    initialize: proc(user_data: rawptr, config: ^Config) -> bool,
    frame:      proc(user_data: rawptr, frame: int, config: ^Config) -> Screenshot_Request,
    resize:     proc(user_data: rawptr, viewport: Viewport) -> bool,
    screenshot: proc(user_data: rawptr, output_path: string) -> bool,
    teardown:   proc(user_data: rawptr),
}

Screenshot_Request :: struct {
    requested:   bool,
    // Empty uses Config.output_path.
    output_path: string,
}

Harness :: struct {
    config:               Config,
    callbacks:            Callbacks,
    status:               Status,
    error:                Error,
    frame_index:          int,
    screenshot_requested: bool,
    initialized:          bool,
    torn_down:            bool,
}

valid_viewport :: proc(viewport: Viewport) -> bool {
    return viewport.width > 0 && viewport.height > 0
}

start :: proc(harness: ^Harness, config: Config, callbacks: Callbacks) -> bool {
    if harness.initialized && !harness.torn_down {
        finish(harness)
    }
    harness^ = Harness {
        config    = config,
        callbacks = callbacks,
    }
    if !valid_viewport(config.viewport) ||
       config.frame_horizon < 0 ||
       config.timeout_frames <= config.frame_horizon ||
       len(config.output_path) == 0 ||
       callbacks.initialize == nil ||
       callbacks.frame == nil ||
       callbacks.screenshot == nil ||
       callbacks.teardown == nil {
        harness.status = .Failed
        harness.error = .Invalid_Config
        return false
    }
    if !callbacks.initialize(callbacks.user_data, &harness.config) {
        harness.status = .Failed
        harness.error = .Initialization_Failed
        return false
    }
    harness.initialized = true
    harness.status = .Running
    return true
}

step :: proc(harness: ^Harness) -> Status {
    if harness.status != .Running do return harness.status
    if harness.frame_index >= harness.config.timeout_frames {
        harness.status = .Failed
        harness.error = .Timed_Out
        return harness.status
    }
    if harness.frame_index == harness.config.resize_frame {
        if !valid_viewport(harness.config.resize_viewport) ||
           harness.callbacks.resize == nil ||
           !harness.callbacks.resize(harness.callbacks.user_data, harness.config.resize_viewport) {
            harness.status = .Failed
            harness.error = .Resize_Failed
            return harness.status
        }
    }
    request := harness.callbacks.frame(harness.callbacks.user_data, harness.frame_index, &harness.config)
    if request.requested {
        output_path := len(request.output_path) > 0 ? request.output_path : harness.config.output_path
        if !harness.callbacks.screenshot(harness.callbacks.user_data, output_path) {
            harness.status = .Failed
            harness.error = .Screenshot_Failed
            return harness.status
        }
        harness.screenshot_requested = true
    }
    harness.frame_index += 1
    if harness.screenshot_requested && harness.frame_index > harness.config.frame_horizon {
        harness.status = .Complete
    }
    return harness.status
}

finish :: proc(harness: ^Harness) {
    if harness.initialized && !harness.torn_down {
        harness.callbacks.teardown(harness.callbacks.user_data)
        harness.torn_down = true
    }
    if harness.status == .Idle || harness.status == .Running do harness.status = .Torn_Down
}
