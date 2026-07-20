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

Body_ID :: distinct u32
World :: distinct rawptr

Ray_Hit :: struct {
    body:     Body_ID,
    fraction: f32,
    position: Vec3,
}

@(default_calling_convention = "c")
foreign bridge {
    zelda_physics_world_create :: proc(max_bodies, worker_threads: u32) -> World ---
    zelda_physics_world_destroy :: proc(world: World) ---
    zelda_physics_world_step :: proc(world: World, delta_time: f32, collision_steps: u32) ---
    zelda_physics_world_set_gravity :: proc(world: World, gravity: ^Vec3) ---
    zelda_physics_body_add_box :: proc(world: World, half_extent, position: ^Vec3, rotation: ^Quat, motion: Motion_Type, mass: f32, user_data: u64) -> Body_ID ---
    zelda_physics_body_add_sphere :: proc(world: World, radius: f32, position: ^Vec3, rotation: ^Quat, motion: Motion_Type, mass: f32, user_data: u64) -> Body_ID ---
    zelda_physics_body_add_capsule :: proc(world: World, half_height, radius: f32, position: ^Vec3, rotation: ^Quat, motion: Motion_Type, mass: f32, user_data: u64) -> Body_ID ---
    zelda_physics_body_remove :: proc(world: World, body: Body_ID) ---
    zelda_physics_body_get_transform :: proc(world: World, body: Body_ID, position: ^Vec3, rotation: ^Quat) -> bool ---
    zelda_physics_body_set_transform :: proc(world: World, body: Body_ID, position: ^Vec3, rotation: ^Quat, activate: bool) ---
    zelda_physics_body_get_linear_velocity :: proc(world: World, body: Body_ID, velocity: ^Vec3) ---
    zelda_physics_body_set_linear_velocity :: proc(world: World, body: Body_ID, velocity: ^Vec3) ---
    zelda_physics_body_add_force :: proc(world: World, body: Body_ID, force: ^Vec3) ---
    zelda_physics_body_add_impulse :: proc(world: World, body: Body_ID, impulse: ^Vec3) ---
    zelda_physics_world_cast_ray :: proc(world: World, origin, direction: ^Vec3, max_distance: f32, out_body: ^Body_ID, out_fraction: ^f32, out_position: ^Vec3) -> bool ---
}

create_world :: proc(max_bodies: u32 = 65_536, worker_threads: u32 = 0) -> World {
    return zelda_physics_world_create(max_bodies, worker_threads)
}

destroy_world :: proc(world: World) { zelda_physics_world_destroy(world) }
step :: proc(world: World, delta_time: f32, collision_steps: u32 = 1) { zelda_physics_world_step(world, delta_time, collision_steps) }
set_gravity :: proc(world: World, gravity: Vec3) { value := gravity; zelda_physics_world_set_gravity(world, &value) }

add_box :: proc(world: World, half_extent, position: Vec3, motion := Motion_Type.Dynamic, mass: f32 = 1, rotation := IDENTITY_ROTATION, user_data: u64 = 0) -> Body_ID {
    extent_value, position_value, rotation_value := half_extent, position, rotation
    return zelda_physics_body_add_box(world, &extent_value, &position_value, &rotation_value, motion, mass, user_data)
}
add_sphere :: proc(world: World, radius: f32, position: Vec3, motion := Motion_Type.Dynamic, mass: f32 = 1, rotation := IDENTITY_ROTATION, user_data: u64 = 0) -> Body_ID {
    position_value, rotation_value := position, rotation
    return zelda_physics_body_add_sphere(world, radius, &position_value, &rotation_value, motion, mass, user_data)
}
add_capsule :: proc(world: World, half_height, radius: f32, position: Vec3, motion := Motion_Type.Dynamic, mass: f32 = 1, rotation := IDENTITY_ROTATION, user_data: u64 = 0) -> Body_ID {
    position_value, rotation_value := position, rotation
    return zelda_physics_body_add_capsule(world, half_height, radius, &position_value, &rotation_value, motion, mass, user_data)
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
set_linear_velocity :: proc(world: World, body: Body_ID, velocity: Vec3) { value := velocity; zelda_physics_body_set_linear_velocity(world, body, &value) }
add_force :: proc(world: World, body: Body_ID, force: Vec3) { value := force; zelda_physics_body_add_force(world, body, &value) }
add_impulse :: proc(world: World, body: Body_ID, impulse: Vec3) { value := impulse; zelda_physics_body_add_impulse(world, body, &value) }

cast_ray :: proc(world: World, origin, direction: Vec3, max_distance: f32) -> (hit: Ray_Hit, ok: bool) {
    origin_value, direction_value := origin, direction
    ok = zelda_physics_world_cast_ray(world, &origin_value, &direction_value, max_distance, &hit.body, &hit.fraction, &hit.position)
    return
}
