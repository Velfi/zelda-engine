#include <Jolt/Jolt.h>
#include <Jolt/RegisterTypes.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/RayCast.h>
#include <Jolt/Physics/Collision/CastResult.h>
#include <algorithm>
#include <mutex>
#include <thread>

using namespace JPH;

namespace {
constexpr ObjectLayer STATIC_LAYER = 0;
constexpr ObjectLayer MOVING_LAYER = 1;
constexpr uint LAYER_COUNT = 2;
constexpr BroadPhaseLayer STATIC_BP(0);
constexpr BroadPhaseLayer MOVING_BP(1);

class BroadPhaseLayers final : public BroadPhaseLayerInterface {
public:
    uint GetNumBroadPhaseLayers() const override { return 2; }
    BroadPhaseLayer GetBroadPhaseLayer(ObjectLayer layer) const override {
        return layer == STATIC_LAYER ? STATIC_BP : MOVING_BP;
    }
};

class ObjectVsBroadPhase final : public ObjectVsBroadPhaseLayerFilter {
public:
    bool ShouldCollide(ObjectLayer layer, BroadPhaseLayer broad) const override {
        return layer == MOVING_LAYER || broad == MOVING_BP;
    }
};

class ObjectPairs final : public ObjectLayerPairFilter {
public:
    bool ShouldCollide(ObjectLayer a, ObjectLayer b) const override {
        return a == MOVING_LAYER || b == MOVING_LAYER;
    }
};

struct World {
    BroadPhaseLayers broad_phase_layers;
    ObjectVsBroadPhase object_vs_broad_phase;
    ObjectPairs object_pairs;
    TempAllocatorImpl allocator;
    JobSystemThreadPool jobs;
    PhysicsSystem system;

    World(uint max_bodies, uint max_pairs, uint max_constraints, uint temp_bytes, uint workers)
        : allocator(temp_bytes),
          jobs(cMaxPhysicsJobs, cMaxPhysicsBarriers, workers) {
        system.Init(max_bodies, 0, max_pairs, max_constraints,
                    broad_phase_layers, object_vs_broad_phase, object_pairs);
    }
};

std::mutex init_mutex;
uint world_count = 0;

void acquire_jolt() {
    std::lock_guard<std::mutex> lock(init_mutex);
    if (world_count++ == 0) {
        RegisterDefaultAllocator();
        Factory::sInstance = new Factory();
        RegisterTypes();
    }
}

void release_jolt() {
    std::lock_guard<std::mutex> lock(init_mutex);
    if (--world_count == 0) {
        UnregisterTypes();
        delete Factory::sInstance;
        Factory::sInstance = nullptr;
    }
}

inline BodyID body_id(uint32_t value) { return BodyID(value); }
inline RVec3 position(const float *v) { return RVec3(v[0], v[1], v[2]); }
inline Vec3 vector(const float *v) { return Vec3(v[0], v[1], v[2]); }
inline Quat rotation(const float *q) { return Quat(q[0], q[1], q[2], q[3]); }

uint32_t add_body(World *world, const ShapeSettings &shape, const float *p,
                  const float *q, int motion, float mass, uint64_t user_data) {
    ShapeSettings::ShapeResult result = shape.Create();
    if (result.HasError()) return BodyID::cInvalidBodyID;
    EMotionType type = motion == 0 ? EMotionType::Static :
                       motion == 1 ? EMotionType::Kinematic : EMotionType::Dynamic;
    BodyCreationSettings settings(result.Get(), position(p), rotation(q), type,
                                  type == EMotionType::Static ? STATIC_LAYER : MOVING_LAYER);
    settings.mUserData = user_data;
    if (type == EMotionType::Dynamic && mass > 0.0f) {
        settings.mOverrideMassProperties = EOverrideMassProperties::CalculateInertia;
        settings.mMassPropertiesOverride.mMass = mass;
    }
    BodyID id = world->system.GetBodyInterface().CreateAndAddBody(
        settings, type == EMotionType::Static ? EActivation::DontActivate : EActivation::Activate);
    return id.GetIndexAndSequenceNumber();
}
} // namespace

extern "C" {
World *zelda_physics_world_create(uint32_t max_bodies, uint32_t workers) {
    if (max_bodies == 0) max_bodies = 65536;
    if (workers == 0) {
        unsigned available = std::thread::hardware_concurrency();
        workers = std::max(1u, available > 1 ? available - 1 : 1u);
    }
    acquire_jolt();
    return new World(max_bodies, max_bodies, std::max(1024u, max_bodies / 2),
                     10u * 1024u * 1024u, workers);
}

void zelda_physics_world_destroy(World *world) {
    if (!world) return;
    delete world;
    release_jolt();
}

void zelda_physics_world_step(World *world, float delta_time, uint32_t collision_steps) {
    if (!world || delta_time <= 0.0f) return;
    world->system.Update(delta_time, std::max(1u, collision_steps),
                         &world->allocator, &world->jobs);
}

void zelda_physics_world_set_gravity(World *world, const float *gravity) {
    if (world && gravity) world->system.SetGravity(vector(gravity));
}

uint32_t zelda_physics_body_add_box(World *world, const float *half_extent,
                                    const float *p, const float *q, int motion,
                                    float mass, uint64_t user_data) {
    if (!world || !half_extent || !p || !q || half_extent[0] <= 0 || half_extent[1] <= 0 || half_extent[2] <= 0)
        return BodyID::cInvalidBodyID;
    BoxShapeSettings shape(vector(half_extent));
    return add_body(world, shape, p, q, motion, mass, user_data);
}

uint32_t zelda_physics_body_add_sphere(World *world, float radius, const float *p,
                                       const float *q, int motion, float mass, uint64_t user_data) {
    if (!world || !p || !q || radius <= 0) return BodyID::cInvalidBodyID;
    SphereShapeSettings shape(radius);
    return add_body(world, shape, p, q, motion, mass, user_data);
}

uint32_t zelda_physics_body_add_capsule(World *world, float half_height, float radius,
                                        const float *p, const float *q, int motion,
                                        float mass, uint64_t user_data) {
    if (!world || !p || !q || half_height <= 0 || radius <= 0) return BodyID::cInvalidBodyID;
    CapsuleShapeSettings shape(half_height, radius);
    return add_body(world, shape, p, q, motion, mass, user_data);
}

void zelda_physics_body_remove(World *world, uint32_t id) {
    if (!world || id == BodyID::cInvalidBodyID) return;
    BodyInterface &bodies = world->system.GetBodyInterface();
    BodyID body = body_id(id);
    if (bodies.IsAdded(body)) bodies.RemoveBody(body);
    bodies.DestroyBody(body);
}

bool zelda_physics_body_get_transform(World *world, uint32_t id, float *p, float *q) {
    if (!world || !p || !q) return false;
    RVec3 pos;
    Quat rot;
    world->system.GetBodyInterface().GetPositionAndRotation(body_id(id), pos, rot);
    p[0] = float(pos.GetX()); p[1] = float(pos.GetY()); p[2] = float(pos.GetZ());
    q[0] = rot.GetX(); q[1] = rot.GetY(); q[2] = rot.GetZ(); q[3] = rot.GetW();
    return true;
}

void zelda_physics_body_set_transform(World *world, uint32_t id, const float *p,
                                      const float *q, bool activate) {
    if (world && p && q) world->system.GetBodyInterface().SetPositionAndRotation(
        body_id(id), position(p), rotation(q), activate ? EActivation::Activate : EActivation::DontActivate);
}

void zelda_physics_body_get_linear_velocity(World *world, uint32_t id, float *velocity) {
    if (!world || !velocity) return;
    Vec3 v = world->system.GetBodyInterface().GetLinearVelocity(body_id(id));
    v.StoreFloat3(reinterpret_cast<Float3 *>(velocity));
}

void zelda_physics_body_set_linear_velocity(World *world, uint32_t id, const float *velocity) {
    if (world && velocity) world->system.GetBodyInterface().SetLinearVelocity(body_id(id), vector(velocity));
}

void zelda_physics_body_add_force(World *world, uint32_t id, const float *force) {
    if (world && force) world->system.GetBodyInterface().AddForce(body_id(id), vector(force));
}

void zelda_physics_body_add_impulse(World *world, uint32_t id, const float *impulse) {
    if (world && impulse) world->system.GetBodyInterface().AddImpulse(body_id(id), vector(impulse));
}

bool zelda_physics_world_cast_ray(World *world, const float *origin, const float *direction,
                                  float max_distance, uint32_t *out_body, float *out_fraction,
                                  float *out_position) {
    if (!world || !origin || !direction || max_distance <= 0) return false;
    RRayCast ray(position(origin), vector(direction).Normalized() * max_distance);
    RayCastResult hit;
    if (!world->system.GetNarrowPhaseQuery().CastRay(ray, hit)) return false;
    if (out_body) *out_body = hit.mBodyID.GetIndexAndSequenceNumber();
    if (out_fraction) *out_fraction = hit.mFraction;
    if (out_position) {
        RVec3 p = ray.GetPointOnRay(hit.mFraction);
        out_position[0] = float(p.GetX()); out_position[1] = float(p.GetY()); out_position[2] = float(p.GetZ());
    }
    return true;
}
}
