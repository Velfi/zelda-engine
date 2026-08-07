package physics

import "core:math"
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

    for _ in 0 ..< 180 { step(world, 1.0 / 60.0, 1) }
    position, _, ok := get_transform(world, ball)
    testing.expect(t, ok)
    testing.expectf(t, position.y > 0.45 && position.y < 0.65, "expected resting y near 0.5, got %v", position.y)

    hit, ray_ok := cast_ray(world, {0, 3, 0}, {0, -1, 0}, 10)
    testing.expect(t, ray_ok)
    testing.expect(t, hit.body == ball || hit.body == floor)
}

@(test)
four_wheel_vehicle_suspends_and_moves :: proc(t: ^testing.T) {
    world := create_world(128, 1)
    testing.expect(t, world != nil)
    defer destroy_world(world)
    // Vehicle bodies and suspension queries must use the dedicated vehicle
    // layer rather than inheriting the generic moving-body collision policy.
    set_layer_mask(world, .Moving, 0xfffe)
    floor := add_box(world, {20, .5, 20}, {0, -.5, 0}, .Static)
    testing.expect(t, floor != INVALID_BODY)
    vehicle := create_vehicle(world, {
        half_width              = .7,
        half_height             = .25,
        half_length             = 1.2,
        mass                    = 700,
        center_of_mass_offset_y = -.15,
        wheel_x                 = .78,
        front_wheel_z           = .82,
        rear_wheel_z            = -.82,
        wheel_y                 = -.2,
        wheel_radius            = .32,
        wheel_width             = .24,
        suspension_min          = .08,
        suspension_max          = .3,
        suspension_frequency    = 2.4,
        suspension_damping      = .9,
        max_steer_angle         = .6,
        max_engine_torque       = 520,
        max_brake_torque        = 1100,
        max_handbrake_torque    = 1400,
    }, {0, .75, 0})
    testing.expect(t, vehicle != nil)
    for _ in 0 ..< 120 { step(world, 1.0 / 120.0, 2) }
    contact_count := 0
    for index in 0 ..< 4 {
        wheel, wheel_ok := get_wheel_state(vehicle, u32(index))
        testing.expect(t, wheel_ok)
        if wheel.contact do contact_count += 1
    }
    testing.expectf(t, contact_count >= 3, "expected at least three grounded wheels, got %v", contact_count)

    set_vehicle_input(world, vehicle, 1, 0, 0, 0)
    for _ in 0 ..< 240 { step(world, 1.0 / 120.0, 2) }

    position, _, ok := get_transform(world, vehicle_body(vehicle))
    testing.expect(t, ok)
    testing.expectf(t, position.z > 1, "expected vehicle to drive forward, got z %v", position.z)
    set_vehicle_transform(world, vehicle, {4, 2, -3}, IDENTITY_ROTATION, true)
    teleported, _, teleported_ok := get_transform(world, vehicle_body(vehicle))
    testing.expect(t, teleported_ok)
    testing.expect(t, teleported == Vec3{4, 2, -3})
    testing.expect(t, get_linear_velocity(world, vehicle_body(vehicle)) == Vec3{})
}

@(test)
vehicle_climbs_small_incline_without_sliding_off :: proc(t: ^testing.T) {
    world := create_world(128, 1)
    testing.expect(t, world != nil)
    defer destroy_world(world)

    angle := f32(8 * math.PI / 180)
    ramp_rotation := Quat{-math.sin(angle * .5), 0, 0, math.cos(angle * .5)}
    ramp := add_box(world, {5, .25, 10}, {0, 1.4, 0}, .Static, rotation = ramp_rotation)
    testing.expect(t, ramp != INVALID_BODY)

    start_z := f32(-7)
    start_y := f32(1.4 + start_z * math.tan(angle) + .75)
    vehicle := create_vehicle(world, {
        half_width              = .7,
        half_height             = .25,
        half_length             = 1.2,
        mass                    = 700,
        center_of_mass_offset_y = -.15,
        wheel_x                 = .78,
        front_wheel_z           = .82,
        rear_wheel_z            = -.82,
        wheel_y                 = -.2,
        wheel_radius            = .32,
        wheel_width             = .24,
        suspension_min          = .08,
        suspension_max          = .3,
        suspension_frequency    = 2.4,
        suspension_damping      = .9,
        max_steer_angle         = .6,
        max_engine_torque       = 520,
        max_brake_torque        = 1100,
        max_handbrake_torque    = 1400,
    }, {0, start_y, start_z})
    testing.expect(t, vehicle != nil)

    for _ in 0 ..< 120 do step(world, 1.0 / 120.0, 2)
    set_vehicle_input(world, vehicle, 1, 0, 0, 0)
    for _ in 0 ..< 360 do step(world, 1.0 / 120.0, 2)

    position, _, ok := get_transform(world, vehicle_body(vehicle))
    testing.expect(t, ok)
    testing.expectf(
        t,
        position.z > start_z + 3,
        "expected vehicle to climb incline, started at z %v and ended at z %v",
        start_z,
        position.z,
    )
    testing.expectf(t, math.abs(position.x) < 1, "expected vehicle to stay on line, got x %v", position.x)
}

@(test)
height_field_collides_and_updates :: proc(t: ^testing.T) {
    world := create_world(128, 1)
    testing.expect(t, world != nil)
    defer destroy_world(world)

    heights: [16 * 16]f32
    field := add_height_field(world, heights[:], 16, {-7.5, 0, -7.5}, {1, 1, 1}, 4, 8)
    testing.expect(t, field != INVALID_BODY)
    ball := add_sphere(world, .5, {0, 3, 0})
    for _ in 0 ..< 180 do step(world, 1.0 / 60.0, 1)
    position, _, ok := get_transform(world, ball)
    testing.expect(t, ok)
    testing.expectf(t, position.y > .45 && position.y < .65, "expected heightfield rest near .5, got %v", position.y)

    for &height in heights do height = 1
    testing.expect(t, update_height_field(world, field, 0, 0, 16, 16, heights[:], 16))
    set_transform(world, ball, {0, 3, 0})
    set_linear_velocity(world, ball, {})
    for _ in 0 ..< 180 do step(world, 1.0 / 60.0, 1)
    position, _, ok = get_transform(world, ball)
    testing.expect(t, ok)
    testing.expectf(t, position.y > 1.45 && position.y < 1.65, "expected updated rest near 1.5, got %v", position.y)
}
