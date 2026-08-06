package render2d

import sdl "vendor:sdl3"

SDL_Window_Config :: struct {
    resizable:     bool,
    high_dpi:      bool,
    not_focusable: bool,
}

SDL_Window_Runtime :: struct {
    handle:   ^sdl.Window,
    owns_sdl: bool,
}

sdl_window_create :: proc(
    runtime: ^SDL_Window_Runtime,
    width, height: i32,
    title: cstring,
    config: SDL_Window_Config,
) -> bool {
    if runtime.handle != nil || width <= 0 || height <= 0 do return false
    when ODIN_OS == .Darwin {
        if config.not_focusable do _ = sdl.SetHint(sdl.HINT_MAC_BACKGROUND_APP, "1")
    }
    if !sdl.Init({.VIDEO, .EVENTS, .GAMEPAD}) do return false
    runtime.owns_sdl = true
    flags := sdl.WindowFlags{.VULKAN}
    if config.resizable do flags += {.RESIZABLE}
    if config.high_dpi do flags += {.HIGH_PIXEL_DENSITY}
    if config.not_focusable do flags += {.NOT_FOCUSABLE}
    runtime.handle = sdl.CreateWindow(title, width, height, flags)
    if runtime.handle == nil {
        sdl.Quit()
        runtime^ = {}
        return false
    }
    return true
}

sdl_window_destroy :: proc(runtime: ^SDL_Window_Runtime) {
    if runtime.handle != nil do sdl.DestroyWindow(runtime.handle)
    if runtime.owns_sdl do sdl.Quit()
    runtime^ = {}
}

sdl_window_set_minimum_size :: proc(runtime: ^SDL_Window_Runtime, width, height: i32) -> bool {
    return runtime.handle != nil && sdl.SetWindowMinimumSize(runtime.handle, width, height)
}

sdl_window_set_size :: proc(runtime: ^SDL_Window_Runtime, width, height: i32) -> bool {
    return runtime.handle != nil && sdl.SetWindowSize(runtime.handle, width, height)
}

sdl_window_size :: proc(runtime: ^SDL_Window_Runtime) -> (width, height: i32, ok: bool) {
    if runtime.handle == nil do return
    ok = sdl.GetWindowSize(runtime.handle, &width, &height)
    return
}

sdl_window_pixel_size :: proc(runtime: ^SDL_Window_Runtime) -> (width, height: i32, ok: bool) {
    if runtime.handle == nil do return
    ok = sdl.GetWindowSizeInPixels(runtime.handle, &width, &height)
    return
}

SDL_SCANCODE_COUNT :: 512
SDL_MOUSE_BUTTON_COUNT :: 3
SDL_GAMEPAD_BUTTON_COUNT :: 32

SDL_Input_State :: struct {
    mouse:                         Vector2,
    mouse_delta:                   Vector2,
    mouse_wheel:                   f32,
    mouse_wheel_delta:             Vector2,
    mouse_pinch_scale:             f32,
    mouse_down:                    [SDL_MOUSE_BUTTON_COUNT]bool,
    mouse_pressed:                 [SDL_MOUSE_BUTTON_COUNT]bool,
    mouse_released:                [SDL_MOUSE_BUTTON_COUNT]bool,
    keys_pressed:                  [SDL_SCANCODE_COUNT]bool,
    keys_down:                     [SDL_SCANCODE_COUNT]bool,
    gamepad:                       ^sdl.Gamepad,
    gamepad_id:                    sdl.JoystickID,
    gamepad_down, gamepad_pressed: [SDL_GAMEPAD_BUTTON_COUNT]bool,
    quit_requested:                bool,
    resize_requested:              bool,
}

sdl_input_begin_frame :: proc(input: ^SDL_Input_State) {
    input.mouse_pressed = {}
    input.mouse_released = {}
    input.mouse_delta = {}
    input.mouse_wheel = 0
    input.mouse_wheel_delta = {}
    input.mouse_pinch_scale = 1
    input.keys_pressed = {}
    input.gamepad_pressed = {}
    input.resize_requested = false
    // SDL events provide press/release edges, but a held button may have no
    // subsequent event. Sample the authoritative state every frame so tools
    // that paint or drag continue between motion events.
    buttons := sdl.GetMouseState(&input.mouse.x, &input.mouse.y)
    input.mouse_down[0] = .LEFT in buttons
    input.mouse_down[1] = .MIDDLE in buttons
    input.mouse_down[2] = .RIGHT in buttons
}

sdl_mouse_button_index :: proc(button: u8) -> int {
    switch button {
    case 1:
        return 0
    case 2:
        return 1
    case 3:
        return 2
    }
    return -1
}

sdl_process_event :: proc(input: ^SDL_Input_State, event: ^sdl.Event) {
    #partial switch event.type {
    case .QUIT:
        input.quit_requested = true
    case .WINDOW_PIXEL_SIZE_CHANGED:
        input.resize_requested = true
    case .MOUSE_MOTION:
        input.mouse = {event.motion.x, event.motion.y}
        input.mouse_delta.x += event.motion.xrel
        input.mouse_delta.y += event.motion.yrel
    case .MOUSE_WHEEL:
        input.mouse_wheel += event.wheel.y
        input.mouse_wheel_delta.x += event.wheel.x
        input.mouse_wheel_delta.y += event.wheel.y
    case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
        index := sdl_mouse_button_index(event.button.button)
        if index >= 0 {
            down := event.type == .MOUSE_BUTTON_DOWN
            input.mouse = {event.button.x, event.button.y}
            input.mouse_down[index] = down
            if down {
                input.mouse_pressed[index] = true
            } else {
                input.mouse_released[index] = true
            }
        }
    case .WINDOW_FOCUS_LOST:
        for index in 0 ..< len(input.mouse_down) {
            if input.mouse_down[index] do input.mouse_released[index] = true
        }
        input.mouse_down = {}
        input.keys_down = {}
    case .PINCH_UPDATE:
        input.mouse_pinch_scale *= event.pinch.scale
    case .KEY_DOWN, .KEY_UP:
        index := int(event.key.scancode)
        if index >= 0 && index < len(input.keys_down) {
            down := event.type == .KEY_DOWN
            input.keys_down[index] = down
            if down && !event.key.repeat do input.keys_pressed[index] = true
        }
    case .GAMEPAD_ADDED:
        if input.gamepad == nil {
            input.gamepad = sdl.OpenGamepad(event.gdevice.which)
            if input.gamepad != nil do input.gamepad_id = event.gdevice.which
        }
    case .GAMEPAD_REMOVED:
        if input.gamepad != nil && event.gdevice.which == input.gamepad_id {
            sdl.CloseGamepad(input.gamepad)
            input.gamepad = nil
            input.gamepad_id = 0
            input.gamepad_down = {}
        }
    case .GAMEPAD_BUTTON_DOWN, .GAMEPAD_BUTTON_UP:
        if input.gamepad != nil && event.gbutton.which == input.gamepad_id {
            index := int(event.gbutton.button)
            if index >= 0 && index < len(input.gamepad_down) {
                down := event.type == .GAMEPAD_BUTTON_DOWN
                input.gamepad_down[index] = down
                if down do input.gamepad_pressed[index] = true
            }
        }
    }
}

sdl_input_destroy :: proc(input: ^SDL_Input_State) {
    if input.gamepad != nil do sdl.CloseGamepad(input.gamepad)
    input^ = {}
}
