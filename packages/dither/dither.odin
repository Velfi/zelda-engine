package dither

import "core:math"

Mode :: enum {
    Off,
    Bayer,
    Blue_Noise,
    Matriax_8,
}

mode_label :: proc(mode: Mode) -> cstring {
    switch mode {
    case .Off:
        return "OFF"
    case .Bayer:
        return "BAYER"
    case .Blue_Noise:
        return "BLUE"
    case .Matriax_8:
        return "MATRIAX 8"
    }
    return "OFF"
}

adjust_mode :: proc(mode: Mode, direction: int) -> Mode {
    return Mode(clamp(int(mode) + direction, 0, 3))
}

next_mode :: proc(mode: Mode) -> Mode {
    return Mode((int(mode) + 1) % 4)
}

wrap_angle :: proc(angle: f32) -> f32 {
    return math.atan2(math.sin(angle), math.cos(angle))
}

pattern_offset :: proc(accumulated_angle, field_of_view: f32, viewport_pixels, pattern_size: int) -> int {
    if field_of_view <= .0001 || viewport_pixels <= 0 || pattern_size <= 0 do return 0
    raw := int(math.round(f64(f32(viewport_pixels) * accumulated_angle / field_of_view)))
    return ((raw % pattern_size) + pattern_size) % pattern_size
}

pixel_phase_delta :: proc(rotation_delta, field_of_view: f32, viewport_pixels: int) -> f32 {
    if field_of_view <= .0001 || viewport_pixels <= 0 do return 0
    return f32(viewport_pixels) * rotation_delta / field_of_view
}

wrap_pixel_phase :: proc(phase: f32, pattern_size: int) -> int {
    if pattern_size <= 0 do return 0
    rounded := int(math.round(f64(phase)))
    return ((rounded % pattern_size) + pattern_size) % pattern_size
}
