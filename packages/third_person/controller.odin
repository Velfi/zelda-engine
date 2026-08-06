package third_person

import "core:math"

// Vec3 uses a conventional right-handed game-space: Y is up and a yaw of zero
// faces down -Z. Collision remains the caller's responsibility; feed the
// collision result into Input.grounded each frame before calling step.
Vec3 :: [3]f32

Input :: struct {
    move_x, move_y:     f32,
    run_toggle_pressed: bool,
    jump_pressed:       bool,
    jump_held:          bool,
    grounded:           bool,
    camera_yaw_radians: f32,
    ground_normal:      Vec3,
}

Config :: struct {
    move_speed:             f32,
    run_speed:              f32,
    ground_acceleration:    f32,
    ground_deceleration:    f32,
    run_acceleration:       f32,
    run_deceleration:       f32,
    run_steering_speed:     f32,
    drift_min_speed:        f32,
    drift_charge_seconds:   f32,
    boost_speed:            f32,
    boost_acceleration:     f32,
    boost_duration:         f32,
    reversal_braking:       f32,
    reversal_speed:         f32,
    facing_turn_speed:      f32,
    air_acceleration:       f32,
    jump_speed:             f32,
    gravity:                f32,
    slope_gravity_scale:    f32,
    max_slope_acceleration: f32,
}

State :: struct {
    position, velocity: Vec3,
    facing_yaw_radians: f32,
    grounded:           bool,
    turn_amount:        f32,
    brake_amount:       f32,
    ground_normal:      Vec3,
    running:            bool,
    drifting:           bool,
    drift_charge:       f32,
    boost_seconds:      f32,
}

Camera :: struct {
    yaw_radians, pitch_radians: f32,
    distance, height:           f32,
}

Camera_Pose :: struct {
    position, target: Vec3,
}

Camera_Slot :: enum u8 {
    Player,
    Inspection,
    Cutaway,
    Count,
}

Camera_System :: struct {
    poses:  [Camera_Slot.Count]Camera_Pose,
    active: Camera_Slot,
}

@(no_instrumentation)
camera_system :: #force_inline proc(player_pose: Camera_Pose) -> Camera_System {
    return {poses = {player_pose, player_pose, player_pose}, active = .Player}
}

camera_set_pose :: proc(system: ^Camera_System, slot: Camera_Slot, pose: Camera_Pose) {
    if system == nil || slot == .Count do return
    system.poses[slot] = pose
}

camera_set_active :: proc(system: ^Camera_System, slot: Camera_Slot) {
    if system == nil || slot == .Count do return
    system.active = slot
}

camera_active_pose :: proc(system: ^Camera_System) -> Camera_Pose {
    if system == nil do return {}
    return system.poses[system.active]
}

// camera_look_at creates a view from an explicit eye position and target.
// It is useful for authored viewpoints, inspection tools, and screenshots
// where an orbit camera's yaw/pitch are less expressive than world points.
camera_look_at :: proc(position, target: Vec3) -> Camera_Pose {
    return {position = position, target = target}
}

// camera_near places the camera at a caller-supplied offset from a thing and
// aims at that thing. The offset is world-space on purpose: callers can use
// authored positions for a runway, vehicle, NPC, or landmark without needing
// to know the camera's orbit conventions.
camera_near :: proc(target, offset: Vec3) -> Camera_Pose {
    return camera_look_at(target + offset, target)
}

default_config :: proc() -> Config {
    return {
        move_speed = 5.5,
        run_speed = 10,
        ground_acceleration = 18,
        ground_deceleration = 10,
        run_acceleration = 8,
        run_deceleration = 4.5,
        run_steering_speed = 2.15,
        drift_min_speed = 7,
        drift_charge_seconds = .9,
        boost_speed = 13.5,
        boost_acceleration = 28,
        boost_duration = .85,
        reversal_braking = 28,
        reversal_speed = 1.25,
        facing_turn_speed = 12,
        air_acceleration = 10,
        jump_speed = 7,
        gravity = 20,
        slope_gravity_scale = .35,
        max_slope_acceleration = 8,
    }
}

default_camera :: proc() -> Camera { return {pitch_radians = .35, distance = 4, height = 1.5} }

// look applies raw mouse/stick deltas to the orbit camera. Keeping the clamp
// here makes the controller safe to use from any presentation layer.
look :: proc(camera: ^Camera, yaw_delta, pitch_delta, sensitivity: f32) {
    if camera == nil do return
    camera.yaw_radians += yaw_delta * sensitivity
    camera.pitch_radians = clamp(camera.pitch_radians + pitch_delta * sensitivity, -.85, 1.2)
}

// step updates desired motion and, by default, integrates the standalone
// controller position. Physics-backed callers disable integration and let
// their character sweep own all continuous movement.
step :: proc(state: ^State, input: Input, config: Config, delta_seconds: f32, integrate_position: bool = true) {
    if state == nil || delta_seconds <= 0 do return

    move_x := clamp(input.move_x, -1, 1)
    move_y := clamp(input.move_y, -1, 1)
    length_squared := move_x * move_x + move_y * move_y
    move_amount := math.sqrt(length_squared)
    if length_squared > 1 {
        inverse_length := 1 / math.sqrt(length_squared)
        move_x *= inverse_length
        move_y *= inverse_length
        move_amount = 1
    }
    if input.run_toggle_pressed do state.running = !state.running

    // Rotate local stick/WASD input by the orbit camera's yaw.
    forward := Vec3{-math.sin(input.camera_yaw_radians), 0, -math.cos(input.camera_yaw_radians)}
    right := Vec3{math.cos(input.camera_yaw_radians), 0, -math.sin(input.camera_yaw_radians)}
    direction := Vec3{forward.x * move_y + right.x * move_x, 0, forward.z * move_y + right.z * move_x}
    desired_direction := horizontal_normalize(direction)
    old_velocity := Vec3{state.velocity.x, 0, state.velocity.z}
    old_speed := horizontal_length(old_velocity)
    old_direction := horizontal_normalize(old_velocity)
    state.ground_normal = valid_ground_normal(input.ground_normal)

    // Shift-run + Space is a kart-style drift gesture: the initial press hops,
    // holding charges a mini-turbo, and releasing converts that charge into a
    // short boost. Turning charges faster, but a straight hold still works.
    if input.jump_pressed && state.running && move_amount > .0001 && old_speed >= max_f32(config.drift_min_speed, 0) {
        state.drifting = true
        state.drift_charge = 0
    }
    if state.drifting {
        if input.jump_held && state.running {
            charge_rate := f32(.35) + math.abs(move_x) * .65
            state.drift_charge = clamp(
                state.drift_charge + charge_rate * delta_seconds / max_f32(config.drift_charge_seconds, f32(.01)),
                0,
                1,
            )
        } else {
            if state.drift_charge >= .25 {
                charge_strength := clamp((state.drift_charge - .25) / .75, 0, 1)
                duration_scale := f32(.55) + charge_strength * .45
                state.boost_seconds = max_f32(state.boost_seconds, max_f32(config.boost_duration, 0) * duration_scale)
            }
            state.drifting = false
            state.drift_charge = 0
        }
    }
    boosting := state.boost_seconds > 0

    braking_target: f32
    turn_acceleration_scale := max_f32(config.ground_acceleration, f32(.1))
    if input.grounded {
        has_input := move_amount > .0001
        running := (state.running || boosting) && has_input
        active_speed := running ? config.run_speed : config.move_speed
        if boosting do active_speed = max_f32(config.boost_speed, active_speed)
        active_acceleration := running ? config.run_acceleration : config.ground_acceleration
        if boosting do active_acceleration = max_f32(config.boost_acceleration, active_acceleration)
        if has_input do turn_acceleration_scale = max_f32(active_acceleration, f32(.1))
        active_deceleration := state.running ? config.run_deceleration : config.ground_deceleration
        reversing := false
        if has_input && old_speed > max_f32(config.reversal_speed, .01) {
            reversing = horizontal_dot(old_direction, desired_direction) < -.5
        }

        if reversing {
            state.velocity = horizontal_move_towards(
                state.velocity,
                {},
                max_f32(config.reversal_braking, 0) * delta_seconds,
            )
            braking_target = 1
        } else if has_input {
            target_direction := desired_direction
            if running && old_speed > max_f32(config.reversal_speed, .01) {
                target_direction = horizontal_rotate_towards(
                    old_direction,
                    desired_direction,
                    max_f32(config.run_steering_speed, 0) * delta_seconds,
                )
            }
            target_velocity := target_direction * max_f32(active_speed, 0) * move_amount
            state.velocity = horizontal_move_towards(
                state.velocity,
                target_velocity,
                max_f32(active_acceleration, 0) * delta_seconds,
            )
        } else {
            state.velocity = horizontal_move_towards(
                state.velocity,
                {},
                max_f32(active_deceleration, 0) * delta_seconds,
            )
            if old_speed > .01 {
                braking_speed := state.running ? config.run_speed : config.move_speed
                braking_target = clamp(old_speed / max_f32(braking_speed, f32(.1)), 0, 1)
            }
        }

        slope_acceleration := grounded_slope_acceleration(state.ground_normal, config)
        state.velocity.x += slope_acceleration.x * delta_seconds
        state.velocity.z += slope_acceleration.z * delta_seconds
        // Let a released run coast down instead of snapping immediately to the
        // walk-speed cap. Acceleration/deceleration still pulls it toward the
        // active target speed each frame.
        speed_limit := max_f32(max_f32(active_speed, 0), old_speed)
        state.velocity = horizontal_limit(state.velocity, speed_limit)
    } else {
        air_speed := boosting ? config.boost_speed : config.move_speed
        air_acceleration := boosting ? config.boost_acceleration : config.air_acceleration
        target_velocity := desired_direction * max_f32(air_speed, 0) * move_amount
        state.velocity = horizontal_move_towards(
            state.velocity,
            target_velocity,
            max_f32(air_acceleration, 0) * delta_seconds,
        )
    }

    new_horizontal_velocity := Vec3{state.velocity.x, 0, state.velocity.z}
    new_speed := horizontal_length(new_horizontal_velocity)
    acceleration_delta :=
        Vec3{new_horizontal_velocity.x - old_velocity.x, 0, new_horizontal_velocity.z - old_velocity.z} / delta_seconds
    turn_target: f32
    if input.grounded && old_speed > .1 {
        motion_right := Vec3{-old_direction.z, 0, old_direction.x}
        turn_target = clamp(horizontal_dot(acceleration_delta, motion_right) / turn_acceleration_scale, -1, 1)
    }
    signal_rate := f32(10) * delta_seconds
    state.turn_amount = approach(state.turn_amount, turn_target, signal_rate)
    state.brake_amount = approach(state.brake_amount, braking_target, signal_rate)

    if input.grounded {
        state.grounded = true
        if state.velocity.y < 0 do state.velocity.y = 0
        if input.jump_pressed {
            state.velocity.y = config.jump_speed
            state.grounded = false
        }
    } else {
        state.grounded = false
        state.velocity.y -= config.gravity * delta_seconds
    }

    facing_direction: Vec3
    if (state.running || boosting) && move_amount > .0001 && input.grounded {
        // A running mouse points into the requested turn while its travel
        // direction catches up more slowly, producing a readable drift angle.
        facing_direction = desired_direction
    } else if new_speed > max_f32(config.reversal_speed, .01) {
        facing_direction = horizontal_normalize(new_horizontal_velocity)
    } else if move_amount > .0001 {
        facing_direction = desired_direction
    }
    if horizontal_length(facing_direction) > .0001 {
        target_yaw := math.atan2(-facing_direction.x, -facing_direction.z)
        state.facing_yaw_radians = angle_move_towards(
            state.facing_yaw_radians,
            target_yaw,
            max_f32(config.facing_turn_speed, 0) * delta_seconds,
        )
    }
    if integrate_position do state.position = state.position + state.velocity * delta_seconds
    state.boost_seconds = max_f32(state.boost_seconds - delta_seconds, 0)
    if move_amount <= .0001 && new_speed <= .1 {
        state.running = false
        state.drifting = false
        state.drift_charge = 0
    }
}

// resolve_ground_contact keeps an already-grounded controller attached to the
// sampled surface after horizontal movement. Without that adhesion, descending
// terrain leaves the controller at the previous frame's height for one or more
// frames, making it alternate between grounded and falling. An intentional
// jump remains airborne because step clears State.grounded before this runs.
resolve_ground_contact :: proc(state: ^State, ground_height: f32) {
    if state == nil do return
    if state.grounded || state.position.y <= ground_height {
        state.position.y = ground_height
        state.grounded = true
        if state.velocity.y < 0 do state.velocity.y = 0
    }
}

// camera_pose returns an orbit-camera placement looking at the character's
// upper body. Clamp pitch while collecting look input to avoid a pole flip.
camera_pose :: proc(character_position: Vec3, camera: Camera) -> Camera_Pose {
    pitch := clamp(camera.pitch_radians, -.85, 1.2)
    horizontal_distance := camera.distance * math.cos(pitch)
    target := character_position + Vec3{0, camera.height, 0}
    return {
        position = Vec3 {
            target.x + math.sin(camera.yaw_radians) * horizontal_distance,
            target.y + math.sin(pitch) * camera.distance,
            target.z + math.cos(camera.yaw_radians) * horizontal_distance,
        },
        target = target,
    }
}

// follow_camera tracks target translation exactly and eases only the camera's
// offset from that target. Smoothing both world-space points makes a moving
// target drag the camera through its old positions, which can appear as a
// back-and-forth wobble when vehicle motion is stepped independently.
follow_camera :: proc(current: Camera_Pose, desired: Camera_Pose, sharpness, delta_seconds: f32) -> Camera_Pose {
    if delta_seconds <= 0 do return current
    t := clamp(sharpness * delta_seconds, 0, 1)
    current_offset := current.position - current.target
    desired_offset := desired.position - desired.target
    return {
        position = desired.target + current_offset + (desired_offset - current_offset) * t,
        target = desired.target,
    }
}

// camera_above_height applies a caller-supplied collision floor while
// preserving the authored look target. Terrain sampling remains product code.
camera_above_height :: proc(pose: Camera_Pose, ground_height, clearance: f32) -> Camera_Pose {
    result := pose
    result.position.y = max_f32(result.position.y, ground_height + max_f32(clearance, 0))
    return result
}

@(no_instrumentation)
clamp :: #force_inline proc(value, lower, upper: f32) -> f32 {if value < lower do return lower; if value > upper do return upper
    return value}
approach :: proc(current, target, maximum_delta: f32) -> f32 {if current < target do return min_f32(current + maximum_delta, target)
    return max_f32(current - maximum_delta, target)}
horizontal_length :: proc(value: Vec3) -> f32 {
    return math.sqrt(value.x * value.x + value.z * value.z)
}
horizontal_dot :: proc(a, b: Vec3) -> f32 { return a.x * b.x + a.z * b.z }
horizontal_normalize :: proc(value: Vec3) -> Vec3 {
    length := horizontal_length(value)
    if length <= .0001 do return {}
    return Vec3{value.x / length, 0, value.z / length}
}
horizontal_rotate_towards :: proc(current, target: Vec3, maximum_radians: f32) -> Vec3 {
    if horizontal_length(current) <= .0001 do return horizontal_normalize(target)
    if horizontal_length(target) <= .0001 do return horizontal_normalize(current)
    current_yaw := math.atan2(-current.x, -current.z)
    target_yaw := math.atan2(-target.x, -target.z)
    yaw := angle_move_towards(current_yaw, target_yaw, max_f32(maximum_radians, 0))
    return Vec3{-math.sin(yaw), 0, -math.cos(yaw)}
}
horizontal_move_towards :: proc(current, target: Vec3, maximum_delta: f32) -> Vec3 {
    delta := Vec3{target.x - current.x, 0, target.z - current.z}
    distance := horizontal_length(delta)
    if distance <= maximum_delta || distance <= .0001 {
        return Vec3{target.x, current.y, target.z}
    }
    amount := maximum_delta / distance
    return Vec3{current.x + delta.x * amount, current.y, current.z + delta.z * amount}
}
horizontal_limit :: proc(value: Vec3, maximum: f32) -> Vec3 {
    speed := horizontal_length(value)
    if speed <= maximum || speed <= .0001 do return value
    amount := maximum / speed
    return Vec3{value.x * amount, value.y, value.z * amount}
}
valid_ground_normal :: proc(value: Vec3) -> Vec3 {
    length_squared := value.x * value.x + value.y * value.y + value.z * value.z
    if length_squared <= .0001 || value.y <= .1 do return Vec3{0, 1, 0}
    inverse_length := 1 / math.sqrt(length_squared)
    result := value * inverse_length
    if result.y <= .1 do return Vec3{0, 1, 0}
    return result
}
grounded_slope_acceleration :: proc(normal: Vec3, config: Config) -> Vec3 {
    amount := max_f32(config.gravity, 0) * max_f32(config.slope_gravity_scale, 0) * normal.y
    result := Vec3{normal.x * amount, 0, normal.z * amount}
    return horizontal_limit(result, max_f32(config.max_slope_acceleration, 0))
}
angle_move_towards :: proc(current, target, maximum_delta: f32) -> f32 {
    difference := target - current
    for difference > math.PI do difference -= math.PI * 2
    for difference < -math.PI do difference += math.PI * 2
    if math.abs(difference) <= maximum_delta do return target
    if difference > 0 do return current + maximum_delta
    return current - maximum_delta
}
@(no_instrumentation)
min_f32 :: #force_inline proc(a, b: f32) -> f32 { if a < b do return a; return b }
@(no_instrumentation)
max_f32 :: #force_inline proc(a, b: f32) -> f32 { if a > b do return a; return b }
