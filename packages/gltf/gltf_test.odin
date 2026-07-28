package gltf

import "core:testing"

@(test)
planar_mesh_is_ready :: proc(t: ^testing.T) {
    mesh := Glb_Mesh {
        vertices = make([dynamic]Vec3, 3),
        indices  = make([dynamic]u32, 3),
        min      = {0, 0, 0},
        max      = {1, 0, 1},
    }
    defer delete(mesh.vertices)
    defer delete(mesh.indices)
    testing.expect(t, glb_mesh_ready(&mesh))
}

@(test)
incomplete_mesh_is_not_ready :: proc(t: ^testing.T) {
    mesh := Glb_Mesh {
        vertices = make([dynamic]Vec3, 3),
        indices  = make([dynamic]u32, 2),
    }
    defer delete(mesh.vertices)
    defer delete(mesh.indices)
    testing.expect(t, !glb_mesh_ready(&mesh))
}
