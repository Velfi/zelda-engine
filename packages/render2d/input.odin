package render2d

Mouse_Button :: enum {
    Left,
    Middle,
    Right,
    Count,
}

Button_State :: struct {
    down:     bool,
    pressed:  bool,
    released: bool,
}

Input_State :: struct {
    mouse_position, mouse_delta: Vector2,
    mouse_buttons:               [Mouse_Button.Count]Button_State,
    wheel:                       f32,
    pinch_scale:                 f32,
    focused:                     bool,
}

begin_input_frame :: proc(input: ^Input_State) {
    input.mouse_delta = {}
    input.wheel = 0
    input.pinch_scale = 1
    for &button in input.mouse_buttons {
        button.pressed = false
        button.released = false
    }
}

set_mouse_button :: proc(input: ^Input_State, button: Mouse_Button, down: bool) {
    assert(button != .Count)
    state := &input.mouse_buttons[button]
    if state.down == down do return
    state.down = down
    state.pressed = down
    state.released = !down
}
