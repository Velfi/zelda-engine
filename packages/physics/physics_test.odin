package physics

import "core:testing"

@(test)
falling_body_lands_on_floor :: proc(t: ^testing.T) {
    world := create_world(128, 1)
    testing.expect(t, world != nil)
    defer destroy_world(world)

    floor := add_box(world, {10, 0.5, 10}, {0, -0.5, 0}, .Static)
    ball := add_sphere(world, 0.5, {0, 4, 0})
    testing.expect(t, floor != INVALID_BODY)
    testing.expect(t, ball != INVALID_BODY)

    for _ in 0..<180 { step(world, 1.0 / 60.0, 1) }
    position, _, ok := get_transform(world, ball)
    testing.expect(t, ok)
    testing.expectf(t, position.y > 0.45 && position.y < 0.65, "expected resting y near 0.5, got %v", position.y)

    hit, ray_ok := cast_ray(world, {0, 3, 0}, {0, -1, 0}, 10)
    testing.expect(t, ray_ok)
    testing.expect(t, hit.body == ball || hit.body == floor)
}
