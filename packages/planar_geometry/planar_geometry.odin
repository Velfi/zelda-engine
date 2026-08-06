package planar_geometry

import "core:math"
import "core:math/linalg"

Segment_Intersection :: struct {
    point:    [2]f32,
    along_ab: f32,
    along_cd: f32,
    found:    bool,
}

segment_intersection :: proc(a, b, c, d: [2]f32, parallel_epsilon: f32) -> Segment_Intersection {
    result: Segment_Intersection
    ab, cd := b - a, d - c
    denominator := ab[0] * cd[1] - ab[1] * cd[0]
    if math.abs(denominator) <= parallel_epsilon do return result
    ac := c - a
    result.along_ab = (ac[0] * cd[1] - ac[1] * cd[0]) / denominator
    result.along_cd = (ac[0] * ab[1] - ac[1] * ab[0]) / denominator
    result.point = a + ab * result.along_ab
    result.found = true
    return result
}

point_segment_distance_squared :: proc(point, a, b: [2]f32, degenerate_epsilon_squared: f32 = .000001) -> f32 {
    segment := b - a
    length_squared := linalg.dot(segment, segment)
    if length_squared <= degenerate_epsilon_squared do return linalg.dot(point - a, point - a)
    along := clamp(linalg.dot(point - a, segment) / length_squared, f32(0), f32(1))
    offset := point - (a + segment * along)
    return linalg.dot(offset, offset)
}

oriented_rectangles_clear :: proc(
    a_center: [2]f32,
    a_size: [2]f32,
    a_rotation: f32,
    b_center: [2]f32,
    b_size: [2]f32,
    b_rotation: f32,
    separation: f32,
) -> bool {
    a_tangent := [2]f32{f32(math.cos(f64(a_rotation))), f32(math.sin(f64(a_rotation)))}
    a_normal := [2]f32{-a_tangent[1], a_tangent[0]}
    b_tangent := [2]f32{f32(math.cos(f64(b_rotation))), f32(math.sin(f64(b_rotation)))}
    b_normal := [2]f32{-b_tangent[1], b_tangent[0]}
    delta := b_center - a_center
    axes := [4][2]f32{a_tangent, a_normal, b_tangent, b_normal}
    for axis in axes {
        center_distance := math.abs(linalg.dot(delta, axis))
        a_extent :=
            math.abs(linalg.dot(a_tangent, axis)) * a_size[0] * .5 +
            math.abs(linalg.dot(a_normal, axis)) * a_size[1] * .5
        b_extent :=
            math.abs(linalg.dot(b_tangent, axis)) * b_size[0] * .5 +
            math.abs(linalg.dot(b_normal, axis)) * b_size[1] * .5
        if center_distance >= a_extent + b_extent + separation do return true
    }
    return false
}

segment_intersects_centered_box :: proc(start, finish, half_extents: [2]f32, parallel_epsilon: f32) -> bool {
    direction := finish - start
    entry, exit := f32(0), f32(1)
    for axis in 0 ..< 2 {
        if math.abs(direction[axis]) <= parallel_epsilon {
            if math.abs(start[axis]) > half_extents[axis] do return false
            continue
        }
        near := (-half_extents[axis] - start[axis]) / direction[axis]
        far := (half_extents[axis] - start[axis]) / direction[axis]
        if near > far do near, far = far, near
        entry = max(entry, near)
        exit = min(exit, far)
        if entry > exit do return false
    }
    return true
}
