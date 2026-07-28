package gltf

import "core:math"
import "core:strings"
import cgltf "zelda_engine:cgltf"
import zmath "zelda_engine:math"

Vec3 :: struct {
    x, y, z: f32,
}

Vec2 :: zmath.Vec2

Glb_Primitive_Range :: struct {
    first, count, texture: int,
    base_color:            [4]f32,
}

Glb_Mesh :: struct {
    vertices:          [dynamic]Vec3,
    texcoords:         [dynamic]Vec2,
    indices:           [dynamic]u32,
    primitives:        [dynamic]Glb_Primitive_Range,
    metallic_factors:  [dynamic]f32,
    roughness_factors: [dynamic]f32,
    min, max:          Vec3,
    ready:             bool,
}

glb_mesh_destroy :: proc(mesh: ^Glb_Mesh, allocator := context.allocator) {
    if mesh == nil do return
    delete(mesh.vertices)
    delete(mesh.texcoords)
    delete(mesh.indices)
    delete(mesh.primitives)
    delete(mesh.metallic_factors)
    delete(mesh.roughness_factors)
    mesh^ = {}
}

gltf_identity :: proc() -> [16]f32 {
    return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
}

gltf_transform_point :: proc(transform: [16]f32, point: Vec3) -> Vec3 {
    return {
        transform[0] * point.x + transform[4] * point.y + transform[8] * point.z + transform[12],
        transform[1] * point.x + transform[5] * point.y + transform[9] * point.z + transform[13],
        transform[2] * point.x + transform[6] * point.y + transform[10] * point.z + transform[14],
    }
}

gltf_position_accessor :: proc(primitive: ^cgltf.primitive) -> ^cgltf.accessor {
    if primitive == nil do return nil
    for attribute in primitive.attributes {
        if attribute.type == .position do return attribute.data
    }
    return nil
}

gltf_texcoord_accessor :: proc(primitive: ^cgltf.primitive) -> ^cgltf.accessor {
    if primitive == nil do return nil
    for attribute in primitive.attributes {
        if attribute.type == .texcoord && attribute.index == 0 do return attribute.data
    }
    return nil
}

gltf_append_primitive :: proc(primitive: ^cgltf.primitive, transform: [16]f32, result: ^Glb_Mesh) -> bool {
    if primitive == nil || primitive.type != .triangles do return true

    position := gltf_position_accessor(primitive)
    if position == nil || position.type != .vec3 do return true
    if position.count == 0 do return true

    vertex_count := int(position.count)
    positions := make([]f32, vertex_count * 3, context.temp_allocator)
    if cgltf.accessor_unpack_floats(position, raw_data(positions), uint(len(positions))) != uint(len(positions)) {
        return false
    }

    texcoord := gltf_texcoord_accessor(primitive)
    texcoords := make([]f32, vertex_count * 2, context.temp_allocator)
    if texcoord != nil && texcoord.type == .vec2 && texcoord.count == position.count {
        if cgltf.accessor_unpack_floats(texcoord, raw_data(texcoords), uint(len(texcoords))) != uint(len(texcoords)) {
            return false
        }
    }

    base_vertex := u32(len(result.vertices))
    first_index := len(result.indices)
    for vertex_index in 0 ..< vertex_count {
        local := Vec3 {
            positions[vertex_index * 3 + 0],
            positions[vertex_index * 3 + 1],
            positions[vertex_index * 3 + 2],
        }
        vertex := gltf_transform_point(transform, local)
        append(&result.vertices, vertex)
        append(&result.texcoords, Vec2{texcoords[vertex_index * 2], texcoords[vertex_index * 2 + 1]})
        result.min = {min(result.min.x, vertex.x), min(result.min.y, vertex.y), min(result.min.z, vertex.z)}
        result.max = {max(result.max.x, vertex.x), max(result.max.y, vertex.y), max(result.max.z, vertex.z)}
    }

    if primitive.indices == nil {
        for index in 0 ..< vertex_count {
            append(&result.indices, base_vertex + u32(index))
        }
    } else {
        if primitive.indices.type != .scalar do return false
        for index in 0 ..< int(primitive.indices.count) {
            local_index := cgltf.accessor_read_index(primitive.indices, uint(index))
            if local_index >= uint(vertex_count) do return false
            append(&result.indices, base_vertex + u32(local_index))
        }
    }

    base_color: [4]f32 = {1, 1, 1, 1}
    metallic, roughness := f32(1), f32(1)
    if primitive.material != nil {
        material := primitive.material
        pbr := material.pbr_metallic_roughness
        base_color = pbr.base_color_factor
        metallic, roughness = pbr.metallic_factor, pbr.roughness_factor
    }
    append(&result.primitives, Glb_Primitive_Range {
        first      = first_index,
        count      = len(result.indices) - first_index,
        texture    = -1,
        base_color = base_color,
    })
    append(&result.metallic_factors, metallic)
    append(&result.roughness_factors, roughness)
    return true
}

gltf_append_node :: proc(node: ^cgltf.node, result: ^Glb_Mesh) -> bool {
    if node == nil do return true
    transform: [16]f32
    cgltf.node_transform_world(node, raw_data(transform[:]))
    if node.mesh != nil {
        for &primitive in node.mesh.primitives {
            if !gltf_append_primitive(&primitive, transform, result) do return false
        }
    }
    for child in node.children {
        if !gltf_append_node(child, result) do return false
    }
    return true
}

glb_load :: proc(path: string, allocator := context.allocator) -> (Glb_Mesh, bool) {
    result: Glb_Mesh
    load_ok := false
    defer if !load_ok do glb_mesh_destroy(&result, allocator)
    path_cstr, path_error := strings.clone_to_cstring(path, context.temp_allocator)
    if path_error != nil do return result, false

    options: cgltf.options
    data, parse_result := cgltf.parse_file(options, path_cstr)
    if parse_result != .success || data == nil do return result, false
    defer cgltf.free(data)
    if cgltf.load_buffers(options, data, path_cstr) != .success do return result, false

    result.vertices = make([dynamic]Vec3, 0, 1024, allocator)
    result.texcoords = make([dynamic]Vec2, 0, 1024, allocator)
    result.indices = make([dynamic]u32, 0, 3072, allocator)
    result.primitives = make([dynamic]Glb_Primitive_Range, 0, 32, allocator)
    result.metallic_factors = make([dynamic]f32, 0, 32, allocator)
    result.roughness_factors = make([dynamic]f32, 0, 32, allocator)
    result.min = {math.inf_f32(1), math.inf_f32(1), math.inf_f32(1)}
    result.max = {math.inf_f32(-1), math.inf_f32(-1), math.inf_f32(-1)}

    if len(data.nodes) == 0 {
        identity := gltf_identity()
        for &mesh in data.meshes {
            for &primitive in mesh.primitives {
                if !gltf_append_primitive(&primitive, identity, &result) do return {}, false
            }
        }
    } else if data.scene != nil {
        for node in data.scene.nodes {
            if !gltf_append_node(node, &result) do return {}, false
        }
    } else {
        for &node in data.nodes {
            if node.parent == nil && !gltf_append_node(&node, &result) do return {}, false
        }
    }

    result.ready = glb_mesh_ready(&result)
    load_ok = result.ready
    return result, result.ready
}

glb_mesh_ready :: proc(mesh: ^Glb_Mesh) -> bool {
    return mesh != nil && len(mesh.vertices) > 0 && len(mesh.indices) >= 3 && len(mesh.indices) % 3 == 0
}
