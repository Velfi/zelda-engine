package physics

when ODIN_OS == .Windows {
    foreign import bridge "../../third_party/jolt/zelda_physics.lib"
} else when ODIN_OS == .Darwin {
    foreign import bridge "../../third_party/jolt/libzelda_physics.dylib"
} else {
    foreign import bridge "../../third_party/jolt/libzelda_physics.so"
}

Vec3 :: [3]f32
Quat :: [4]f32
IDENTITY_ROTATION :: Quat{0, 0, 0, 1}
INVALID_BODY :: Body_ID(0xffff_ffff)

Motion_Type :: enum i32 {
    Static,
    Kinematic,
    Dynamic,
}

Object_Layer :: enum u16 {
    Static_World,
    Moving,
    Character,
    Vehicle,
    Boat,
    Prop,
    Soft_Body,
    Sensor,
    Character_Proxy,
}

Ground_State :: enum u32 {
    On_Ground,
    On_Steep_Ground,
    Not_Supported,
    In_Air,
}

Body_ID :: distinct u32
World :: distinct rawptr
Vehicle :: distinct rawptr
Character :: distinct rawptr

Character_State :: struct {
    position:    Vec3,
    velocity:    Vec3,
    ground_normal: Vec3,
    ground_state: Ground_State,
    ground_body: Body_ID,
}

World_Stats :: struct {
    body_count:        u32,
    active_body_count: u32,
    soft_body_count:   u32,
}

Contact_Kind :: enum u32 {
    Added,
    Persisted,
}

Contact_Event :: struct {
    body_a, body_b:           Body_ID,
    user_data_a, user_data_b: u64,
    position, normal:         Vec3,
    kind:                     Contact_Kind,
}

Ray_Hit :: struct {
    body:     Body_ID,
    fraction: f32,
    position: Vec3,
    normal:   Vec3,
}

Vehicle_Settings :: struct {
    half_width, half_height, half_length: f32,
    mass, center_of_mass_offset_y:        f32,
    wheel_x, front_wheel_z, rear_wheel_z: f32,
    wheel_y, wheel_radius, wheel_width:   f32,
    suspension_min, suspension_max:       f32,
    suspension_frequency:                 f32,
    suspension_damping:                   f32,
    max_steer_angle:                      f32,
    max_engine_torque:                    f32,
    max_brake_torque:                     f32,
    max_handbrake_torque:                 f32,
    four_wheel_drive:                     bool,
}

Wheel_State :: struct {
    position:           Vec3,
    rotation, steering: f32,
    suspension:         f32,
    contact:            bool,
}

@(default_calling_convention = "c")
foreign bridge {
    zelda_physics_world_create :: proc(max_bodies, worker_threads: u32) -> World ---
    zelda_physics_world_destroy :: proc(world: World) ---
    zelda_physics_world_step :: proc(world: World, delta_time: f32, collision_steps: u32) ---
    zelda_physics_world_set_gravity :: proc(world: World, gravity: ^Vec3) ---
    zelda_physics_world_set_layer_mask :: proc(world: World, layer: Object_Layer, mask: u16) ---
    zelda_physics_world_get_stats :: proc(world: World, body_count, active_body_count, soft_body_count: ^u32) ---
    zelda_physics_world_drain_contacts :: proc(world: World, events: ^Contact_Event, capacity: u32) -> u32 ---
    zelda_physics_body_add_box :: proc(world: World, half_extent, position: ^Vec3, rotation: ^Quat, motion: Motion_Type, mass: f32, user_data: u64) -> Body_ID ---
    zelda_physics_body_add_sphere :: proc(world: World, radius: f32, position: ^Vec3, rotation: ^Quat, motion: Motion_Type, mass: f32, user_data: u64) -> Body_ID ---
    zelda_physics_body_add_capsule :: proc(world: World, half_height, radius: f32, position: ^Vec3, rotation: ^Quat, motion: Motion_Type, mass: f32, user_data: u64) -> Body_ID ---
    zelda_physics_body_add_box_layered :: proc(world: World, half_extent, position: ^Vec3, rotation: ^Quat, motion: Motion_Type, mass: f32, user_data: u64, layer: Object_Layer, friction, restitution: f32, sensor: bool) -> Body_ID ---
    zelda_physics_body_add_capsule_layered :: proc(world: World, half_height, radius: f32, position: ^Vec3, rotation: ^Quat, motion: Motion_Type, mass: f32, user_data: u64, layer: Object_Layer, friction, restitution: f32, sensor: bool) -> Body_ID ---
    zelda_physics_body_add_mesh :: proc(world: World, vertices: ^f32, vertex_count: u32, indices: ^u32, triangle_count: u32, position: ^Vec3, rotation: ^Quat, user_data: u64, layer: Object_Layer, friction, restitution: f32) -> Body_ID ---
    zelda_physics_body_add_height_field :: proc(world: World, heights: ^f32, sample_count: u32, offset, scale: ^Vec3, block_size, bits_per_sample: u32, min_height, max_height: f32, user_data: u64) -> Body_ID ---
    zelda_physics_height_field_set_heights :: proc(world: World, body: Body_ID, x, y, width, height: u32, heights: ^f32, stride: u32) -> bool ---
    zelda_physics_body_remove :: proc(world: World, body: Body_ID) ---
    zelda_physics_body_get_transform :: proc(world: World, body: Body_ID, position: ^Vec3, rotation: ^Quat) -> bool ---
    zelda_physics_body_set_transform :: proc(world: World, body: Body_ID, position: ^Vec3, rotation: ^Quat, activate: bool) ---
    zelda_physics_body_get_linear_velocity :: proc(world: World, body: Body_ID, velocity: ^Vec3) ---
    zelda_physics_body_set_linear_velocity :: proc(world: World, body: Body_ID, velocity: ^Vec3) ---
    zelda_physics_body_add_force :: proc(world: World, body: Body_ID, force: ^Vec3) ---
    zelda_physics_body_add_impulse :: proc(world: World, body: Body_ID, impulse: ^Vec3) ---
    zelda_physics_body_move_kinematic :: proc(world: World, body: Body_ID, position: ^Vec3, rotation: ^Quat, delta_time: f32) ---
    zelda_physics_body_set_angular_velocity :: proc(world: World, body: Body_ID, velocity: ^Vec3) ---
    zelda_physics_body_get_user_data :: proc(world: World, body: Body_ID) -> u64 ---
    zelda_physics_character_create :: proc(world: World, half_height, radius: f32, position: ^Vec3, max_slope_angle, mass, max_strength: f32, user_data: u64) -> Character ---
    zelda_physics_character_destroy :: proc(world: World, character: Character) ---
    zelda_physics_character_set_position :: proc(character: Character, position: ^Vec3) ---
    zelda_physics_character_step :: proc(world: World, character: Character, velocity: ^Vec3, delta_time: f32, gravity: ^Vec3, step_up, step_down: f32, out_position, out_velocity, out_normal: ^Vec3, out_ground_state: ^Ground_State, out_ground_body: ^Body_ID) -> bool ---
    zelda_physics_soft_strand_add :: proc(world: World, points: ^f32, inverse_masses: ^f32, count: u32, stretch_compliance, bend_compliance: f32, iterations: u32, damping, gravity_factor, vertex_radius, friction: f32, user_data: u64, layer: Object_Layer) -> Body_ID ---
    zelda_physics_soft_strand_set_root :: proc(world: World, body: Body_ID, root: ^Vec3, delta_time: f32, teleport: bool) -> bool ---
    zelda_physics_soft_strand_set_attachment :: proc(world: World, body: Body_ID, root, tangent: ^Vec3, delta_time: f32, teleport: bool) -> bool ---
    zelda_physics_soft_strand_get_points :: proc(world: World, body: Body_ID, points: ^f32, count: u32) -> bool ---
    zelda_physics_soft_strand_set_points :: proc(world: World, body: Body_ID, points: ^f32, count: u32, reset_velocity: bool) -> bool ---
    zelda_physics_world_cast_ray :: proc(world: World, origin, direction: ^Vec3, max_distance: f32, out_body: ^Body_ID, out_fraction: ^f32, out_position, out_normal: ^Vec3) -> bool ---
    zelda_physics_world_cast_ray_layer :: proc(world: World, origin, direction: ^Vec3, max_distance: f32, layer: Object_Layer, out_body: ^Body_ID, out_fraction: ^f32, out_position, out_normal: ^Vec3) -> bool ---
    zelda_physics_world_cast_ray_filtered :: proc(world: World, origin, direction: ^Vec3, max_distance: f32, layer_mask: u16, ignored_body: Body_ID, out_body: ^Body_ID, out_fraction: ^f32, out_position, out_normal: ^Vec3) -> bool ---
    zelda_physics_vehicle_create :: proc(world: World, settings: ^Vehicle_Settings, position: ^Vec3, rotation: ^Quat, user_data: u64) -> Vehicle ---
    zelda_physics_vehicle_destroy :: proc(world: World, vehicle: Vehicle) ---
    zelda_physics_vehicle_set_input :: proc(world: World, vehicle: Vehicle, forward, steering, brake, handbrake: f32) ---
    zelda_physics_vehicle_set_transform :: proc(world: World, vehicle: Vehicle, position: ^Vec3, rotation: ^Quat, reset_velocity: bool) ---
    zelda_physics_vehicle_set_grip :: proc(vehicle: Vehicle, longitudinal, lateral: f32) ---
    zelda_physics_vehicle_set_wheel_grip :: proc(vehicle: Vehicle, wheel: u32, longitudinal, lateral: f32) ---
    zelda_physics_vehicle_get_body :: proc(vehicle: Vehicle) -> Body_ID ---
    zelda_physics_vehicle_get_wheel :: proc(vehicle: Vehicle, index: u32, position: ^Vec3, rotation, steering, suspension: ^f32, contact: ^bool) -> bool ---
}

create_world :: proc(max_bodies: u32 = 65_536, worker_threads: u32 = 0) -> World {
    return zelda_physics_world_create(max_bodies, worker_threads)
}

destroy_world :: proc(world: World) { zelda_physics_world_destroy(world) }
step :: proc(world: World, delta_time: f32, collision_steps: u32 = 1) {zelda_physics_world_step(
        world,
        delta_time,
        collision_steps,
    )}
set_gravity :: proc(world: World, gravity: Vec3) {value := gravity
    zelda_physics_world_set_gravity(world, &value)}
set_layer_mask :: proc(world: World, layer: Object_Layer, mask: u16) {
    zelda_physics_world_set_layer_mask(world, layer, mask)
}
get_world_stats :: proc(world: World) -> (stats: World_Stats) {
    zelda_physics_world_get_stats(
        world, &stats.body_count, &stats.active_body_count, &stats.soft_body_count,
    )
    return
}
drain_contacts :: proc(world: World, events: []Contact_Event) -> int {
    if len(events) == 0 do return 0
    return int(zelda_physics_world_drain_contacts(world, raw_data(events), u32(len(events))))
}

add_box :: proc(
    world: World,
    half_extent, position: Vec3,
    motion := Motion_Type.Dynamic,
    mass: f32 = 1,
    rotation := IDENTITY_ROTATION,
    user_data: u64 = 0,
) -> Body_ID {
    extent_value, position_value, rotation_value := half_extent, position, rotation
    return zelda_physics_body_add_box(world, &extent_value, &position_value, &rotation_value, motion, mass, user_data)
}
add_sphere :: proc(
    world: World,
    radius: f32,
    position: Vec3,
    motion := Motion_Type.Dynamic,
    mass: f32 = 1,
    rotation := IDENTITY_ROTATION,
    user_data: u64 = 0,
) -> Body_ID {
    position_value, rotation_value := position, rotation
    return zelda_physics_body_add_sphere(world, radius, &position_value, &rotation_value, motion, mass, user_data)
}
add_capsule :: proc(
    world: World,
    half_height, radius: f32,
    position: Vec3,
    motion := Motion_Type.Dynamic,
    mass: f32 = 1,
    rotation := IDENTITY_ROTATION,
    user_data: u64 = 0,
) -> Body_ID {
    position_value, rotation_value := position, rotation
    return zelda_physics_body_add_capsule(
        world,
        half_height,
        radius,
        &position_value,
        &rotation_value,
        motion,
        mass,
        user_data,
    )
}

add_box_layered :: proc(
    world: World,
    half_extent, position: Vec3,
    motion := Motion_Type.Static,
    mass: f32 = 0,
    rotation := IDENTITY_ROTATION,
    user_data: u64 = 0,
    layer := Object_Layer.Static_World,
    friction: f32 = .5,
    restitution: f32 = 0,
    sensor := false,
) -> Body_ID {
    extent_value, position_value, rotation_value := half_extent, position, rotation
    return zelda_physics_body_add_box_layered(
        world, &extent_value, &position_value, &rotation_value, motion, mass,
        user_data, layer, friction, restitution, sensor,
    )
}

add_capsule_layered :: proc(
    world: World,
    half_height, radius: f32,
    position: Vec3,
    motion := Motion_Type.Dynamic,
    mass: f32 = 1,
    rotation := IDENTITY_ROTATION,
    user_data: u64 = 0,
    layer := Object_Layer.Moving,
    friction: f32 = .5,
    restitution: f32 = 0,
    sensor := false,
) -> Body_ID {
    position_value, rotation_value := position, rotation
    return zelda_physics_body_add_capsule_layered(
        world, half_height, radius, &position_value, &rotation_value, motion,
        mass, user_data, layer, friction, restitution, sensor,
    )
}

add_static_mesh :: proc(
    world: World,
    vertices: []Vec3,
    indices: []u32,
    position: Vec3 = {},
    rotation: Quat = IDENTITY_ROTATION,
    user_data: u64 = 0,
    layer := Object_Layer.Static_World,
    friction: f32 = .5,
    restitution: f32 = 0,
) -> Body_ID {
    if len(vertices) < 3 || len(indices) < 3 || len(indices) % 3 != 0 {
        return INVALID_BODY
    }
    position_value, rotation_value := position, rotation
    return zelda_physics_body_add_mesh(
        world, &vertices[0][0], u32(len(vertices)), raw_data(indices),
        u32(len(indices) / 3), &position_value, &rotation_value, user_data,
        layer, friction, restitution,
    )
}

add_height_field :: proc(
    world: World,
    heights: []f32,
    sample_count: u32,
    offset, scale: Vec3,
    block_size: u32 = 4,
    bits_per_sample: u32 = 8,
    min_height: f32 = -256,
    max_height: f32 = 256,
    user_data: u64 = 0,
) -> Body_ID {
    if len(heights) < int(sample_count * sample_count) do return INVALID_BODY
    offset_value, scale_value := offset, scale
    return zelda_physics_body_add_height_field(
        world,
        raw_data(heights),
        sample_count,
        &offset_value,
        &scale_value,
        block_size,
        bits_per_sample,
        min_height,
        max_height,
        user_data,
    )
}

update_height_field :: proc(
    world: World,
    body: Body_ID,
    x, y, width, height: u32,
    heights: []f32,
    stride: u32,
) -> bool {
    if len(heights) < int(stride * height) do return false
    return zelda_physics_height_field_set_heights(world, body, x, y, width, height, raw_data(heights), stride)
}
remove_body :: proc(world: World, body: Body_ID) { zelda_physics_body_remove(world, body) }

get_transform :: proc(world: World, body: Body_ID) -> (position: Vec3, rotation: Quat, ok: bool) {
    ok = zelda_physics_body_get_transform(world, body, &position, &rotation)
    return
}
set_transform :: proc(world: World, body: Body_ID, position: Vec3, rotation := IDENTITY_ROTATION, activate := true) {
    position_value, rotation_value := position, rotation
    zelda_physics_body_set_transform(world, body, &position_value, &rotation_value, activate)
}
get_linear_velocity :: proc(world: World, body: Body_ID) -> (velocity: Vec3) {
    zelda_physics_body_get_linear_velocity(world, body, &velocity)
    return
}
set_linear_velocity :: proc(world: World, body: Body_ID, velocity: Vec3) {value := velocity
    zelda_physics_body_set_linear_velocity(world, body, &value)}
add_force :: proc(world: World, body: Body_ID, force: Vec3) {value := force
    zelda_physics_body_add_force(world, body, &value)}
add_impulse :: proc(world: World, body: Body_ID, impulse: Vec3) {value := impulse
    zelda_physics_body_add_impulse(world, body, &value)}

move_kinematic :: proc(world: World, body: Body_ID, position: Vec3, rotation: Quat, delta_time: f32) {
    position_value, rotation_value := position, rotation
    zelda_physics_body_move_kinematic(world, body, &position_value, &rotation_value, delta_time)
}
set_angular_velocity :: proc(world: World, body: Body_ID, velocity: Vec3) {
    value := velocity
    zelda_physics_body_set_angular_velocity(world, body, &value)
}
get_user_data :: proc(world: World, body: Body_ID) -> u64 {
    return zelda_physics_body_get_user_data(world, body)
}

create_character :: proc(
    world: World,
    half_height, radius: f32,
    position: Vec3,
    max_slope_angle: f32,
    mass: f32 = 1,
    max_strength: f32 = 100,
    user_data: u64 = 0,
) -> Character {
    value := position
    return zelda_physics_character_create(
        world, half_height, radius, &value, max_slope_angle, mass, max_strength, user_data,
    )
}
destroy_character :: proc(world: World, character: Character) {
    zelda_physics_character_destroy(world, character)
}
set_character_position :: proc(character: Character, position: Vec3) {
    value := position
    zelda_physics_character_set_position(character, &value)
}
step_character :: proc(
    world: World,
    character: Character,
    velocity: Vec3,
    delta_time: f32,
    gravity: Vec3 = {0, -9.81, 0},
    step_up: f32 = .25,
    step_down: f32 = .30,
) -> (state: Character_State, ok: bool) {
    velocity_value, gravity_value := velocity, gravity
    ok = zelda_physics_character_step(
        world, character, &velocity_value, delta_time, &gravity_value,
        step_up, step_down, &state.position, &state.velocity,
        &state.ground_normal, &state.ground_state, &state.ground_body,
    )
    return
}

add_soft_strand :: proc(
    world: World,
    points: []Vec3,
    inverse_masses: []f32,
    stretch_compliance, bend_compliance: f32,
    iterations: u32,
    damping, gravity_factor, vertex_radius, friction: f32,
    user_data: u64 = 0,
    layer := Object_Layer.Soft_Body,
) -> Body_ID {
    if len(points) < 3 || len(inverse_masses) != len(points) do return INVALID_BODY
    return zelda_physics_soft_strand_add(
        world,
        &points[0][0],
        raw_data(inverse_masses),
        u32(len(points)),
        stretch_compliance,
        bend_compliance,
        iterations,
        damping,
        gravity_factor,
        vertex_radius,
        friction,
        user_data,
        layer,
    )
}

set_soft_strand_root :: proc(
    world: World,
    body: Body_ID,
    root: Vec3,
    delta_time: f32,
    teleport := false,
) -> bool {
    value := root
    return zelda_physics_soft_strand_set_root(world, body, &value, delta_time, teleport)
}

set_soft_strand_attachment :: proc(
    world: World,
    body: Body_ID,
    root, tangent: Vec3,
    delta_time: f32,
    teleport := false,
) -> bool {
    root_value, tangent_value := root, tangent
    return zelda_physics_soft_strand_set_attachment(
        world, body, &root_value, &tangent_value, delta_time, teleport,
    )
}

get_soft_strand_points :: proc(world: World, body: Body_ID, points: []Vec3) -> bool {
    if len(points) == 0 do return false
    return zelda_physics_soft_strand_get_points(world, body, &points[0][0], u32(len(points)))
}

set_soft_strand_points :: proc(
    world: World,
    body: Body_ID,
    points: []Vec3,
    reset_velocity := false,
) -> bool {
    if len(points) == 0 do return false
    return zelda_physics_soft_strand_set_points(
        world,
        body,
        &points[0][0],
        u32(len(points)),
        reset_velocity,
    )
}

cast_ray :: proc(world: World, origin, direction: Vec3, max_distance: f32) -> (hit: Ray_Hit, ok: bool) {
    origin_value, direction_value := origin, direction
    ok = zelda_physics_world_cast_ray(
        world,
        &origin_value,
        &direction_value,
        max_distance,
        &hit.body,
        &hit.fraction,
        &hit.position,
        &hit.normal,
    )
    return
}

cast_ray_layer :: proc(
    world: World,
    origin, direction: Vec3,
    max_distance: f32,
    layer: Object_Layer,
) -> (hit: Ray_Hit, ok: bool) {
    origin_value, direction_value := origin, direction
    ok = zelda_physics_world_cast_ray_layer(
        world, &origin_value, &direction_value, max_distance, layer,
        &hit.body, &hit.fraction, &hit.position, &hit.normal,
    )
    return
}

cast_ray_filtered :: proc(
    world: World,
    origin, direction: Vec3,
    max_distance: f32,
    layer_mask: u16,
    ignored_body: Body_ID = INVALID_BODY,
) -> (hit: Ray_Hit, ok: bool) {
    origin_value, direction_value := origin, direction
    ok = zelda_physics_world_cast_ray_filtered(
        world, &origin_value, &direction_value, max_distance, layer_mask, ignored_body,
        &hit.body, &hit.fraction, &hit.position, &hit.normal,
    )
    return
}

create_vehicle :: proc(
    world: World,
    settings: Vehicle_Settings,
    position: Vec3,
    rotation := IDENTITY_ROTATION,
    user_data: u64 = 0,
) -> Vehicle {
    settings_value, position_value, rotation_value := settings, position, rotation
    return zelda_physics_vehicle_create(world, &settings_value, &position_value, &rotation_value, user_data)
}

destroy_vehicle :: proc(world: World, vehicle: Vehicle) { zelda_physics_vehicle_destroy(world, vehicle) }
set_vehicle_input :: proc(world: World, vehicle: Vehicle, forward, steering, brake, handbrake: f32) {
    zelda_physics_vehicle_set_input(world, vehicle, forward, steering, brake, handbrake)
}
set_vehicle_transform :: proc(
    world: World,
    vehicle: Vehicle,
    position: Vec3,
    rotation := IDENTITY_ROTATION,
    reset_velocity := true,
) {
    position_value, rotation_value := position, rotation
    zelda_physics_vehicle_set_transform(world, vehicle, &position_value, &rotation_value, reset_velocity)
}
set_vehicle_grip :: proc(vehicle: Vehicle, longitudinal, lateral: f32) {
    zelda_physics_vehicle_set_grip(vehicle, longitudinal, lateral)
}
set_vehicle_wheel_grip :: proc(vehicle: Vehicle, wheel: u32, longitudinal, lateral: f32) {
    zelda_physics_vehicle_set_wheel_grip(vehicle, wheel, longitudinal, lateral)
}
vehicle_body :: proc(vehicle: Vehicle) -> Body_ID { return zelda_physics_vehicle_get_body(vehicle) }
get_wheel_state :: proc(vehicle: Vehicle, index: u32) -> (state: Wheel_State, ok: bool) {
    ok = zelda_physics_vehicle_get_wheel(
        vehicle,
        index,
        &state.position,
        &state.rotation,
        &state.steering,
        &state.suspension,
        &state.contact,
    )
    return
}
