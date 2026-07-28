package render2d

Runtime_Backend :: struct {
    user_data:           rawptr,
    create:              #type proc(user_data: rawptr, width, height: i32) -> bool,
    resize:              #type proc(user_data: rawptr, width, height: i32) -> bool,
    begin_frame:         #type proc(user_data: rawptr) -> bool,
    submit_frame:        #type proc(user_data: rawptr) -> bool,
    update_texture_rgba: #type proc(user_data: rawptr, texture: Texture, pixels: []u8) -> bool,
    request_screenshot:  #type proc(user_data: rawptr, path: string) -> bool,
    destroy:             #type proc(user_data: rawptr),
}

Runtime :: struct {
    descriptor:    Renderer_Descriptor,
    backend:       Runtime_Backend,
    width, height: i32,
    initialized:   bool,
    frame_active:  bool,
}

runtime_create :: proc(
    runtime: ^Runtime,
    descriptor: Renderer_Descriptor,
    backend: Runtime_Backend,
    width, height: i32,
) -> bool {
    if runtime.initialized || !descriptor_valid(descriptor) || backend.create == nil do return false
    if width <= 0 || height <= 0 || !backend.create(backend.user_data, width, height) do return false
    runtime^ = {
        descriptor  = descriptor,
        backend     = backend,
        width       = width,
        height      = height,
        initialized = true,
    }
    return true
}

runtime_resize :: proc(runtime: ^Runtime, width, height: i32) -> bool {
    if !runtime.initialized || runtime.frame_active || width <= 0 || height <= 0 do return false
    if runtime.backend.resize != nil && !runtime.backend.resize(runtime.backend.user_data, width, height) do return false
    runtime.width, runtime.height = width, height
    return true
}

runtime_begin_frame :: proc(runtime: ^Runtime) -> bool {
    if !runtime.initialized || runtime.frame_active do return false
    if runtime.backend.begin_frame != nil && !runtime.backend.begin_frame(runtime.backend.user_data) do return false
    runtime.frame_active = true
    return true
}

runtime_submit_frame :: proc(runtime: ^Runtime) -> bool {
    if !runtime.initialized || !runtime.frame_active do return false
    ok := runtime.backend.submit_frame == nil || runtime.backend.submit_frame(runtime.backend.user_data)
    runtime.frame_active = false
    return ok
}

runtime_update_texture_rgba :: proc(runtime: ^Runtime, texture: Texture, pixels: []u8) -> bool {
    if !runtime.initialized || !texture.ready || texture.width <= 0 || texture.height <= 0 do return false
    if len(pixels) != texture.width * texture.height * 4 do return false
    return(
        runtime.backend.update_texture_rgba != nil &&
        runtime.backend.update_texture_rgba(runtime.backend.user_data, texture, pixels) \
    )
}

runtime_request_screenshot :: proc(runtime: ^Runtime, path: string) -> bool {
    return(
        runtime.initialized &&
        path != "" &&
        runtime.backend.request_screenshot != nil &&
        runtime.backend.request_screenshot(runtime.backend.user_data, path) \
    )
}

runtime_destroy :: proc(runtime: ^Runtime) {
    if !runtime.initialized do return
    if runtime.backend.destroy != nil do runtime.backend.destroy(runtime.backend.user_data)
    runtime^ = {}
}
