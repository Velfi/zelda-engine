package planar_geometry

import "core:testing"

@(test)
segment_intersection_handles_boundaries_and_parallel_lines :: proc(t: ^testing.T) {
    boundary := segment_intersection({0, 0}, {1, 0}, {1, -1}, {1, 1}, .00001)
    testing.expect(t, boundary.found)
    testing.expect_value(t, boundary.point, [2]f32{1, 0})
    testing.expect_value(t, boundary.along_ab, f32(1))

    parallel := segment_intersection({0, 0}, {1, 0}, {0, 1}, {1, 1}, .00001)
    testing.expect(t, !parallel.found)
}

@(test)
point_segment_distance_handles_degenerate_and_clamped_segments :: proc(t: ^testing.T) {
    testing.expect_value(t, point_segment_distance_squared({3, 4}, {0, 0}, {0, 0}), f32(25))
    testing.expect_value(t, point_segment_distance_squared({2, 1}, {0, 0}, {1, 0}), f32(2))
    testing.expect_value(t, point_segment_distance_squared({.5, 2}, {0, 0}, {1, 0}), f32(4))
}

@(test)
oriented_rectangle_clearance_treats_exact_separation_as_clear :: proc(t: ^testing.T) {
    testing.expect(t, oriented_rectangles_clear({0, 0}, {2, 2}, 0, {3, 0}, {2, 2}, 0, 1))
    testing.expect(t, !oriented_rectangles_clear({0, 0}, {2, 2}, 0, {2.99, 0}, {2, 2}, 0, 1))
    testing.expect(t, !oriented_rectangles_clear({0, 0}, {2, 2}, .4, {0, 0}, {2, 2}, -.2, 0))
}

@(test)
segment_box_intersection_handles_parallel_and_degenerate_segments :: proc(t: ^testing.T) {
    testing.expect(t, segment_intersects_centered_box({-2, 0}, {2, 0}, {1, 1}, .000001))
    testing.expect(t, !segment_intersects_centered_box({-2, 2}, {2, 2}, {1, 1}, .000001))
    testing.expect(t, segment_intersects_centered_box({1, 1}, {1, 1}, {1, 1}, .000001))
    testing.expect(t, !segment_intersects_centered_box({1.01, 1}, {1.01, 1}, {1, 1}, .000001))
}
