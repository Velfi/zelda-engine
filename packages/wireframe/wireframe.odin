package wireframe

import "core:math"
import "core:math/linalg"

Color :: struct {
    r, g, b: u8,
}
Color_Float :: struct {
    r, g, b: f32,
}
Vertex :: struct {
    position: [3]f32,
    color:    Color_Float,
}
Edge :: struct {
    a, b: int,
}
Camera :: struct {
    position:                 [3]f32,
    right, up, forward:       [3]f32,
    focal_length, near_plane: f32,
}
Target :: struct {
    width, height: int,
    pixels:        []Color,
    depth:         []f32,
}
Screen_Vertex :: struct {
    x, y, depth: f32,
    color:       Color_Float,
    valid:       bool,
}

clamp_f32 :: proc(value, low, high: f32) -> f32 {if value < low do return low; if value > high do return high
    return value}
lerp :: proc(a, b, t: f32) -> f32 { return a + (b - a) * clamp_f32(t, 0, 1) }
abs_f32 :: proc(value: f32) -> f32 { if value < 0 do return -value; return value }
round_i32 :: proc(value: f32) -> int { if value >= 0 do return int(value + .5); return int(value - .5) }

default_camera :: proc() -> Camera {return{
        right = {1, 0, 0},
        up = {0, 1, 0},
        forward = {0, 0, -1},
        focal_length = 1,
        near_plane = .05,
    }}

target_valid :: proc(target: Target) -> bool {return(
        target.width > 0 &&
        target.height > 0 &&
        len(target.pixels) >= target.width * target.height &&
        len(target.depth) >= target.width * target.height \
    )}

clear :: proc(target: ^Target, color: Color) {
    if target == nil || !target_valid(target^) do return
    for i in 0 ..< target.width * target.height { target.pixels[i] = color; target.depth[i] = f32(1e30) }
}

project :: proc(camera: Camera, vertex: Vertex, width, height: int) -> Screen_Vertex {
    view := vertex.position - camera.position
    depth := linalg.dot(view, camera.forward)
    if depth <= max_f32(camera.near_plane, .0001) do return {}
    x := linalg.dot(view, camera.right) * camera.focal_length / depth
    y := linalg.dot(view, camera.up) * camera.focal_length / depth
    return {
        x = (x * .5 + .5) * f32(width - 1),
        y = (.5 - y * .5) * f32(height - 1),
        depth = depth,
        color = vertex.color,
        valid = true,
    }
}

draw_model :: proc(target: ^Target, camera: Camera, vertices: []Vertex, edges: []Edge) {
    if target == nil || !target_valid(target^) do return
    for edge in edges {
        if edge.a < 0 || edge.b < 0 || edge.a >= len(vertices) || edge.b >= len(vertices) do continue
        a := project(camera, vertices[edge.a], target.width, target.height)
        b := project(camera, vertices[edge.b], target.width, target.height)
        if a.valid && b.valid do draw_line(target, a, b)
    }
}

draw_line :: proc(target: ^Target, a, b: Screen_Vertex) {
    dx := b.x - a.x; dy := b.y - a.y; steps := max_i32(1, max_i32(abs_i32(round_i32(dx)), abs_i32(round_i32(dy))))
    for step in 0 ..< steps + 1 {
        t := f32(step) / f32(steps); x := round_i32(lerp(a.x, b.x, t)); y := round_i32(lerp(a.y, b.y, t))
        if x < 0 || y < 0 || x >= target.width || y >= target.height do continue
        // Perspective-correct depth interpolation: interpolate reciprocal depth.
        depth := 1 / lerp(1 / a.depth, 1 / b.depth, t); index := y * target.width + x
        if depth >= target.depth[index] do continue
        target.depth[index] = depth
        target.pixels[index] = {
            u8(clamp_f32(lerp(a.color.r, b.color.r, t), 0, 1) * 255),
            u8(clamp_f32(lerp(a.color.g, b.color.g, t), 0, 1) * 255),
            u8(clamp_f32(lerp(a.color.b, b.color.b, t), 0, 1) * 255),
        }
    }
}

max_f32 :: proc(a, b: f32) -> f32 { if a > b do return a; return b }
max_i32 :: proc(a, b: int) -> int { if a > b do return a; return b }
abs_i32 :: proc(value: int) -> int { if value < 0 do return -value; return value }
