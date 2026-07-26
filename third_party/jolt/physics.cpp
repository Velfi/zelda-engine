#include <Jolt/Jolt.h>
#include <Jolt/RegisterTypes.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/OffsetCenterOfMassShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/HeightFieldShape.h>
#include <Jolt/Physics/Collision/RayCast.h>
#include <Jolt/Physics/Collision/CastResult.h>
#include <Jolt/Physics/Vehicle/VehicleConstraint.h>
#include <Jolt/Physics/Vehicle/VehicleCollisionTester.h>
#include <Jolt/Physics/Vehicle/WheeledVehicleController.h>
#include <algorithm>
#include <mutex>
#include <thread>
#include <vector>

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
    struct Vehicle {
        Ref<VehicleConstraint> constraint;
        BodyID body;
        float longitudinal_grip[4] {1.0f, 1.0f, 1.0f, 1.0f};
        float lateral_grip[4] {1.0f, 1.0f, 1.0f, 1.0f};
    };
    std::vector<Vehicle *> vehicles;
    struct HeightField {
        BodyID body;
        Ref<HeightFieldShape> shape;
    };
    std::vector<HeightField> height_fields;

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
    for (World::Vehicle *vehicle : world->vehicles) {
        world->system.RemoveStepListener(vehicle->constraint);
        world->system.RemoveConstraint(vehicle->constraint);
        delete vehicle;
    }
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
    world->height_fields.erase(
        std::remove_if(
            world->height_fields.begin(), world->height_fields.end(),
            [body](const World::HeightField &field) { return field.body == body; }
        ),
        world->height_fields.end()
    );
    if (bodies.IsAdded(body)) bodies.RemoveBody(body);
    bodies.DestroyBody(body);
}

uint32_t zelda_physics_body_add_height_field(
    World *world, const float *heights, uint32_t sample_count,
    const float *offset, const float *scale, uint32_t block_size,
    uint32_t bits_per_sample, float min_height, float max_height,
    uint64_t user_data
) {
    if (!world || !heights || !offset || !scale || sample_count < 4) {
        return BodyID::cInvalidBodyID;
    }
    HeightFieldShapeSettings settings(
        heights, vector(offset), vector(scale), sample_count
    );
    settings.mBlockSize = std::clamp(block_size, 2u, 8u);
    settings.mBitsPerSample = std::clamp(bits_per_sample, 1u, 8u);
    if (min_height < max_height) {
        settings.mMinHeightValue = min_height;
        settings.mMaxHeightValue = max_height;
    }
    ShapeSettings::ShapeResult result;
    Ref<HeightFieldShape> shape = new HeightFieldShape(settings, result);
    if (result.HasError()) return BodyID::cInvalidBodyID;
    BodyCreationSettings body_settings(
        shape, RVec3::sZero(), Quat::sIdentity(), EMotionType::Static, STATIC_LAYER
    );
    body_settings.mUserData = user_data;
    BodyID body = world->system.GetBodyInterface().CreateAndAddBody(
        body_settings, EActivation::DontActivate
    );
    if (body.IsInvalid()) return BodyID::cInvalidBodyID;
    world->height_fields.push_back({body, shape});
    return body.GetIndexAndSequenceNumber();
}

bool zelda_physics_height_field_set_heights(
    World *world, uint32_t id, uint32_t x, uint32_t y,
    uint32_t width, uint32_t height, const float *heights, uint32_t stride
) {
    if (!world || !heights || width == 0 || height == 0 || stride < width) return false;
    BodyID body = body_id(id);
    auto found = std::find_if(
        world->height_fields.begin(), world->height_fields.end(),
        [body](const World::HeightField &field) { return field.body == body; }
    );
    if (found == world->height_fields.end()) return false;
    uint32_t block_size = found->shape->GetBlockSize();
    if (x % block_size != 0 || y % block_size != 0) return false;
    if (x + width > found->shape->GetSampleCount() ||
        y + height > found->shape->GetSampleCount()) return false;
    found->shape->SetHeights(
        x, y, width, height, heights, stride, world->allocator,
        DegreesToRadians(5.0f)
    );
    world->system.GetBodyInterface().NotifyShapeChanged(
        body, Vec3::sZero(), false, EActivation::DontActivate
    );
    return true;
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

struct ZeldaVehicleSettings {
    float half_width;
    float half_height;
    float half_length;
    float mass;
    float center_of_mass_offset_y;
    float wheel_x;
    float front_wheel_z;
    float rear_wheel_z;
    float wheel_y;
    float wheel_radius;
    float wheel_width;
    float suspension_min;
    float suspension_max;
    float suspension_frequency;
    float suspension_damping;
    float max_steer_angle;
    float max_engine_torque;
    float max_brake_torque;
    float max_handbrake_torque;
    bool four_wheel_drive;
};

World::Vehicle *zelda_physics_vehicle_create(
    World *world, const ZeldaVehicleSettings *settings, const float *p, const float *q,
    uint64_t user_data
) {
    if (!world || !settings || !p || !q || settings->wheel_radius <= 0.0f) return nullptr;

    RefConst<Shape> shape = OffsetCenterOfMassShapeSettings(
        Vec3(0, settings->center_of_mass_offset_y, 0),
        new BoxShape(Vec3(settings->half_width, settings->half_height, settings->half_length))
    ).Create().Get();
    BodyCreationSettings body_settings(shape, position(p), rotation(q), EMotionType::Dynamic, MOVING_LAYER);
    body_settings.mUserData = user_data;
    body_settings.mOverrideMassProperties = EOverrideMassProperties::CalculateInertia;
    body_settings.mMassPropertiesOverride.mMass = settings->mass;
    Body *body = world->system.GetBodyInterface().CreateBody(body_settings);
    if (!body) return nullptr;
    world->system.GetBodyInterface().AddBody(body->GetID(), EActivation::Activate);

    VehicleConstraintSettings vehicle_settings;
    vehicle_settings.mMaxPitchRollAngle = DegreesToRadians(60.0f);
    const float wheel_x[4] = {
        settings->wheel_x, -settings->wheel_x,
        settings->wheel_x, -settings->wheel_x,
    };
    const float wheel_z[4] = {
        settings->front_wheel_z, settings->front_wheel_z,
        settings->rear_wheel_z, settings->rear_wheel_z,
    };
    for (uint index = 0; index < 4; ++index) {
        WheelSettingsWV *wheel = new WheelSettingsWV;
        wheel->mPosition = Vec3(wheel_x[index], settings->wheel_y, wheel_z[index]);
        wheel->mSuspensionDirection = Vec3(0, -1, 0);
        wheel->mSteeringAxis = Vec3(0, 1, 0);
        wheel->mWheelUp = Vec3(0, 1, 0);
        wheel->mWheelForward = Vec3(0, 0, 1);
        wheel->mRadius = settings->wheel_radius;
        wheel->mWidth = settings->wheel_width;
        wheel->mSuspensionMinLength = settings->suspension_min;
        wheel->mSuspensionMaxLength = settings->suspension_max;
        wheel->mSuspensionSpring.mFrequency = settings->suspension_frequency;
        wheel->mSuspensionSpring.mDamping = settings->suspension_damping;
        wheel->mMaxSteerAngle = index < 2 ? settings->max_steer_angle : 0.0f;
        wheel->mMaxBrakeTorque = settings->max_brake_torque;
        wheel->mMaxHandBrakeTorque = index >= 2 ? settings->max_handbrake_torque : 0.0f;
        vehicle_settings.mWheels.push_back(wheel);
    }

    WheeledVehicleControllerSettings *controller = new WheeledVehicleControllerSettings;
    controller->mEngine.mMaxTorque = settings->max_engine_torque;
    controller->mDifferentials.resize(settings->four_wheel_drive ? 2 : 1);
    // Rear-wheel drive by default. Four-wheel drive adds the front axle.
    controller->mDifferentials[0].mLeftWheel = 2;
    controller->mDifferentials[0].mRightWheel = 3;
    if (settings->four_wheel_drive) {
        controller->mDifferentials[0].mEngineTorqueRatio = 0.5f;
        controller->mDifferentials[1].mLeftWheel = 0;
        controller->mDifferentials[1].mRightWheel = 1;
        controller->mDifferentials[1].mEngineTorqueRatio = 0.5f;
    }
    vehicle_settings.mController = controller;
    vehicle_settings.mAntiRollBars.resize(2);
    vehicle_settings.mAntiRollBars[0].mLeftWheel = 0;
    vehicle_settings.mAntiRollBars[0].mRightWheel = 1;
    vehicle_settings.mAntiRollBars[1].mLeftWheel = 2;
    vehicle_settings.mAntiRollBars[1].mRightWheel = 3;

    World::Vehicle *vehicle = new World::Vehicle;
    vehicle->body = body->GetID();
    vehicle->constraint = new VehicleConstraint(*body, vehicle_settings);
    static_cast<WheeledVehicleController *>(vehicle->constraint->GetController())
        ->SetTireMaxImpulseCallback(
            [vehicle](uint wheel, float &longitudinal, float &lateral, float suspension,
                      float longitudinal_friction, float lateral_friction,
                      float, float, float) {
                uint index = std::min(wheel, 3u);
                longitudinal = vehicle->longitudinal_grip[index] * longitudinal_friction * suspension;
                lateral = vehicle->lateral_grip[index] * lateral_friction * suspension;
            });
    vehicle->constraint->SetVehicleCollisionTester(
        new VehicleCollisionTesterCastCylinder(MOVING_LAYER, 0.5f)
    );
    world->system.AddConstraint(vehicle->constraint);
    world->system.AddStepListener(vehicle->constraint);
    world->vehicles.push_back(vehicle);
    return vehicle;
}

void zelda_physics_vehicle_destroy(World *world, World::Vehicle *vehicle) {
    if (!world || !vehicle) return;
    world->system.RemoveStepListener(vehicle->constraint);
    world->system.RemoveConstraint(vehicle->constraint);
    BodyInterface &bodies = world->system.GetBodyInterface();
    if (bodies.IsAdded(vehicle->body)) bodies.RemoveBody(vehicle->body);
    bodies.DestroyBody(vehicle->body);
    auto found = std::find(world->vehicles.begin(), world->vehicles.end(), vehicle);
    if (found != world->vehicles.end()) world->vehicles.erase(found);
    delete vehicle;
}

void zelda_physics_vehicle_set_input(
    World *world, World::Vehicle *vehicle, float forward, float steering,
    float brake, float handbrake
) {
    if (!world || !vehicle) return;
    auto *controller = static_cast<WheeledVehicleController *>(vehicle->constraint->GetController());
    controller->SetDriverInput(
        std::clamp(forward, -1.0f, 1.0f),
        std::clamp(steering, -1.0f, 1.0f),
        std::clamp(brake, 0.0f, 1.0f),
        std::clamp(handbrake, 0.0f, 1.0f)
    );
    world->system.GetBodyInterface().ActivateBody(vehicle->body);
}

void zelda_physics_vehicle_set_transform(
    World *world, World::Vehicle *vehicle, const float *p, const float *q,
    bool reset_velocity
) {
    if (!world || !vehicle || !p || !q) return;
    BodyInterface &bodies = world->system.GetBodyInterface();
    bodies.SetPositionAndRotation(
        vehicle->body, position(p), rotation(q), EActivation::Activate
    );
    if (reset_velocity) {
        bodies.SetLinearVelocity(vehicle->body, Vec3::sZero());
        bodies.SetAngularVelocity(vehicle->body, Vec3::sZero());
    }
}

void zelda_physics_vehicle_set_grip(
    World::Vehicle *vehicle, float longitudinal, float lateral
) {
    if (!vehicle) return;
    for (uint index = 0; index < 4; ++index) {
        vehicle->longitudinal_grip[index] = std::clamp(longitudinal, 0.05f, 2.0f);
        vehicle->lateral_grip[index] = std::clamp(lateral, 0.05f, 2.0f);
    }
}

void zelda_physics_vehicle_set_wheel_grip(
    World::Vehicle *vehicle, uint32_t wheel, float longitudinal, float lateral
) {
    if (!vehicle || wheel >= 4) return;
    vehicle->longitudinal_grip[wheel] = std::clamp(longitudinal, 0.05f, 2.0f);
    vehicle->lateral_grip[wheel] = std::clamp(lateral, 0.05f, 2.0f);
}

uint32_t zelda_physics_vehicle_get_body(World::Vehicle *vehicle) {
    return vehicle ? vehicle->body.GetIndexAndSequenceNumber() : BodyID::cInvalidBodyID;
}

bool zelda_physics_vehicle_get_wheel(
    World::Vehicle *vehicle, uint32_t index, float *position_out,
    float *rotation_out, float *steer_out, float *suspension_out, bool *contact_out
) {
    if (!vehicle || index >= vehicle->constraint->GetWheels().size()) return false;
    const Wheel *wheel = vehicle->constraint->GetWheel(index);
    RMat44 transform = vehicle->constraint->GetWheelWorldTransform(
        index, Vec3::sAxisX(), Vec3::sAxisY()
    );
    RVec3 p = transform.GetTranslation();
    if (position_out) {
        position_out[0] = float(p.GetX());
        position_out[1] = float(p.GetY());
        position_out[2] = float(p.GetZ());
    }
    if (rotation_out) *rotation_out = wheel->GetRotationAngle();
    if (steer_out) *steer_out = wheel->GetSteerAngle();
    if (suspension_out) *suspension_out = wheel->GetSuspensionLength();
    if (contact_out) *contact_out = wheel->HasContact();
    return true;
}
}
