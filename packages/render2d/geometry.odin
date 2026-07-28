package render2d

import "core:math"

to_linear_color :: proc(c: Color) -> [4]f32 {
    channel := proc(v: u8) -> f32 {
        s := f32(v) / 255
        if s <= 0.04045 do return s / 12.92
        return math.pow((s + 0.055) / 1.055, 2.4)
    }
    return {channel(c.r), channel(c.g), channel(c.b), f32(c.a) / 255}
}

transform_point :: proc(point: Vector2, camera: Camera2D) -> Vector2 {
    zoom := camera.zoom
    if zoom == 0 do zoom = 1
    local := Vector2{point.x - camera.target.x, point.y - camera.target.y}
    if camera.rotation != 0 {
        radians := camera.rotation * math.PI / 180
        c, s := math.cos(radians), math.sin(radians)
        local = {local.x * c - local.y * s, local.x * s + local.y * c}
    }
    return {local.x * zoom + camera.offset.x, local.y * zoom + camera.offset.y}
}

append_quad :: proc(
    vertices: ^[dynamic]Vertex,
    indices: ^[dynamic]u32,
    a, b, c, d: Vector2,
    color: Color,
    uv_min := Vector2{0, 0},
    uv_max := Vector2{1, 1},
) {
    base := u32(len(vertices^))
    rgba := to_linear_color(color)
    append(vertices, Vertex{a, {uv_min.x, uv_min.y}, rgba})
    append(vertices, Vertex{b, {uv_max.x, uv_min.y}, rgba})
    append(vertices, Vertex{c, {uv_max.x, uv_max.y}, rgba})
    append(vertices, Vertex{d, {uv_min.x, uv_max.y}, rgba})
    append(indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

append_rectangle :: proc(
    vertices: ^[dynamic]Vertex,
    indices: ^[dynamic]u32,
    rect: Rectangle,
    color: Color,
    camera: ^Camera2D = nil,
) {
    a := Vector2{rect.x, rect.y}
    b := Vector2{rect.x + rect.width, rect.y}
    c := Vector2{rect.x + rect.width, rect.y + rect.height}
    d := Vector2{rect.x, rect.y + rect.height}
    if camera != nil {
        a = transform_point(a, camera^)
        b = transform_point(b, camera^)
        c = transform_point(c, camera^)
        d = transform_point(d, camera^)
    }
    append_quad(vertices, indices, a, b, c, d, color)
}

append_line :: proc(
    vertices: ^[dynamic]Vertex,
    indices: ^[dynamic]u32,
    start, finish: Vector2,
    thickness: f32,
    color: Color,
) {
    dx, dy := finish.x - start.x, finish.y - start.y
    length := math.sqrt(dx * dx + dy * dy)
    if length <= 0 || thickness <= 0 do return
    nx, ny := -dy / length * thickness * .5, dx / length * thickness * .5
    append_quad(
        vertices,
        indices,
        {start.x + nx, start.y + ny},
        {finish.x + nx, finish.y + ny},
        {finish.x - nx, finish.y - ny},
        {start.x - nx, start.y - ny},
        color,
    )
}

append_ellipse :: proc(
    vertices: ^[dynamic]Vertex,
    indices: ^[dynamic]u32,
    center, radii: Vector2,
    segments: int,
    color: Color,
) {
    if segments < 3 || radii.x <= 0 || radii.y <= 0 do return
    base := u32(len(vertices^))
    rgba := to_linear_color(color)
    append(vertices, Vertex{center, {.5, .5}, rgba})
    for i in 0 ..= segments {
        angle := f32(i) / f32(segments) * 2 * math.PI
        s, c := math.sin(angle), math.cos(angle)
        append(vertices, Vertex{{center.x + c * radii.x, center.y + s * radii.y}, {c * .5 + .5, s * .5 + .5}, rgba})
    }
    for i in 0 ..< segments {
        offset := u32(i)
        append(indices, base, base + 1 + offset, base + 2 + offset)
    }
}

intersect_clip :: proc(a, b: Rectangle) -> (Rectangle, bool) {
    x0, y0 := max(a.x, b.x), max(a.y, b.y)
    x1, y1 := min(a.x + a.width, b.x + b.width), min(a.y + a.height, b.y + b.height)
    if x1 <= x0 || y1 <= y0 do return {}, false
    return {x0, y0, x1 - x0, y1 - y0}, true
}
