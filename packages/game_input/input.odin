package game_input

import "core:math"

Device :: enum {
    Mouse_Keyboard,
    Controller,
}

Controller_Style :: enum {
    Generic,
    Xbox,
    PlayStation,
    Nintendo,
}

Face_Button :: enum {
    South,
    East,
    West,
    North,
}

AXIS_COUNT :: 6
AXIS_ACTIVITY_THRESHOLD :: f32(.22)
MENU_AXIS_PRESS_THRESHOLD :: f32(.58)
MENU_AXIS_RELEASE_THRESHOLD :: f32(.32)
MENU_REPEAT_DELAY :: f32(.34)
MENU_REPEAT_INTERVAL :: f32(.11)

Sample :: struct {
    now_seconds:       f64,
    controller_found:  bool,
    keyboard_activity: bool,
    mouse_activity:    bool,
    button_activity:   bool,
    axes:              [AXIS_COUNT]f32,
}

Update_Result :: struct {
    device_changed:          bool,
    controller_connected:    bool,
    controller_disconnected: bool,
    pause_for_disconnect:    bool,
}

Axis_Repeater :: struct {
    direction:    int,
    held_seconds: f32,
    next_repeat:  f32,
}

State :: struct {
    active_device:              Device,
    controller_style:           Controller_Style,
    controller_was_found:       bool,
    last_mouse_keyboard_second: f64,
    last_controller_second:     f64,
    previous_axes:              [AXIS_COUNT]f32,
    menu_horizontal:            Axis_Repeater,
    menu_vertical:              Axis_Repeater,
}

default_state :: proc() -> State {
    return {active_device = .Mouse_Keyboard, controller_style = .Generic}
}

controller_active :: proc(state: ^State) -> bool {
    return state != nil && state.active_device == .Controller && state.controller_was_found
}

update :: proc(state: ^State, sample: Sample) -> Update_Result {
    result: Update_Result
    if state == nil do return result

    result.controller_connected = !state.controller_was_found && sample.controller_found
    result.controller_disconnected = state.controller_was_found && !sample.controller_found
    result.pause_for_disconnect = result.controller_disconnected && state.active_device == .Controller

    controller_activity := sample.button_activity
    if sample.controller_found {
        for axis in sample.axes {
            if math.abs(axis) >= AXIS_ACTIVITY_THRESHOLD {
                controller_activity = true
            }
        }
    }

    mouse_keyboard_activity := sample.keyboard_activity || sample.mouse_activity
    previous_device := state.active_device
    if mouse_keyboard_activity do state.last_mouse_keyboard_second = sample.now_seconds
    if controller_activity do state.last_controller_second = sample.now_seconds

    if mouse_keyboard_activity && !controller_activity {
        state.active_device = .Mouse_Keyboard
    } else if controller_activity && !mouse_keyboard_activity {
        state.active_device = .Controller
    } else if mouse_keyboard_activity && controller_activity {
        if state.last_controller_second > state.last_mouse_keyboard_second {
            state.active_device = .Controller
        } else if state.last_mouse_keyboard_second > state.last_controller_second {
            state.active_device = .Mouse_Keyboard
        }
    }
    if !sample.controller_found && state.active_device == .Controller {
        state.active_device = .Mouse_Keyboard
    }

    state.controller_was_found = sample.controller_found
    state.previous_axes = sample.axes
    result.device_changed = previous_device != state.active_device
    return result
}

menu_steps :: proc(state: ^State, horizontal, vertical, delta_seconds: f32) -> (x, y: int) {
    if state == nil do return
    x = axis_repeat_step(&state.menu_horizontal, horizontal, delta_seconds)
    y = axis_repeat_step(&state.menu_vertical, vertical, delta_seconds)
    return
}

@(no_instrumentation)
reset_menu_repeat :: #force_inline proc(state: ^State) {
    if state == nil do return
    state.menu_horizontal = {}
    state.menu_vertical = {}
}

axis_repeat_step :: proc(repeater: ^Axis_Repeater, value, delta_seconds: f32) -> int {
    if repeater == nil do return 0
    direction := 0
    if value <= -MENU_AXIS_PRESS_THRESHOLD {
        direction = -1
    } else if value >= MENU_AXIS_PRESS_THRESHOLD {
        direction = 1
    } else if math.abs(value) <= MENU_AXIS_RELEASE_THRESHOLD {
        repeater^ = {}
        return 0
    } else {
        direction = repeater.direction
    }

    if direction == 0 do return 0
    if direction != repeater.direction {
        repeater.direction = direction
        repeater.held_seconds = 0
        repeater.next_repeat = MENU_REPEAT_DELAY
        return direction
    }

    repeater.held_seconds += max(delta_seconds, f32(0))
    if repeater.held_seconds < repeater.next_repeat do return 0
    repeater.next_repeat += MENU_REPEAT_INTERVAL
    return direction
}

face_button_label :: proc(style: Controller_Style, button: Face_Button) -> cstring {
    switch style {
    case .Xbox:
        switch button {
        case .South:
            return "A"
        case .East:
            return "B"
        case .West:
            return "X"
        case .North:
            return "Y"
        }
    case .PlayStation:
        switch button {
        case .South:
            return "CROSS"
        case .East:
            return "CIRCLE"
        case .West:
            return "SQUARE"
        case .North:
            return "TRIANGLE"
        }
    case .Nintendo:
        switch button {
        case .South:
            return "B"
        case .East:
            return "A"
        case .West:
            return "Y"
        case .North:
            return "X"
        }
    case .Generic:
        switch button {
        case .South:
            return "SOUTH"
        case .East:
            return "EAST"
        case .West:
            return "WEST"
        case .North:
            return "NORTH"
        }
    }
    return "BUTTON"
}
