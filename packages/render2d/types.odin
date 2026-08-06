package render2d

// Product-neutral data shared by renderer implementations and consumers.
// Serializable visual presets and effect-specific payloads belong to consumers.

Vector2 :: struct {
    x, y: f32,
}

Rectangle :: struct {
    x, y, width, height: f32,
}

Color :: struct {
    r, g, b, a: u8,
}

Texture :: struct {
    id:            int,
    width, height: int,
    ready:         bool,
}

Camera2D :: struct {
    offset, target: Vector2,
    rotation, zoom: f32,
}

Vertex :: struct {
    position, uv: Vector2,
    color:        [4]f32,
}

Primitive_Kind :: enum {
    Solid,
    Textured,
}

Batch :: struct {
    first_index, index_count: int,
    texture_id:               int,
    clip:                     Rectangle,
    clip_enabled:             bool,
    kind:                     Primitive_Kind,
    // Consumer-defined bytes interpreted by the selected pipeline contract.
    effect_payload:           []u8,
}

Shader_Module_Descriptor :: struct {
    // Source identity is resolved through the engine shader manifest first.
    source_path:        string,
    stage:              Shader_Stage,
    entry_point:        string,
    fallback_base_path: string,
}

Shader_Stage :: enum {
    Vertex,
    Fragment,
    Compute,
}

Pipeline_Descriptor :: struct {
    vertex:               Shader_Module_Descriptor,
    fragment:             Shader_Module_Descriptor,
    post_vertex:          Shader_Module_Descriptor,
    post_fragment:        Shader_Module_Descriptor,
    push_constant_size:   int,
    batch_payload_size:   int,
    post_process_enabled: bool,
}

World_Post_Context :: struct {
    source_extent:    [2]u32,
    composite_extent: [2]u32,
    target_extent:    [2]u32,
    pass_index:       u32,
    pass_count:       u32,
    pass_parameters:  [4]f32,
}

Renderer_Descriptor :: struct {
    pipeline:               Pipeline_Descriptor,
    user_data:              rawptr,
    encode_batch_payload:   #type proc(destination: []u8, batch_data: rawptr, user_data: rawptr) -> bool,
    encode_world_post_push: #type proc(destination: []u8, post_context: World_Post_Context, user_data: rawptr) -> bool,
}

descriptor_valid :: proc(descriptor: Renderer_Descriptor) -> bool {
    pipeline := descriptor.pipeline
    if pipeline.push_constant_size < 0 || pipeline.batch_payload_size < 0 do return false
    if pipeline.vertex.stage != .Vertex || pipeline.fragment.stage != .Fragment do return false
    if pipeline.vertex.entry_point == "" || pipeline.fragment.entry_point == "" do return false
    if pipeline.vertex.source_path == "" && pipeline.vertex.fallback_base_path == "" do return false
    if pipeline.fragment.source_path == "" && pipeline.fragment.fallback_base_path == "" do return false
    if pipeline.post_process_enabled {
        if pipeline.post_vertex.stage != .Vertex || pipeline.post_fragment.stage != .Fragment do return false
        if pipeline.post_vertex.source_path == "" && pipeline.post_vertex.fallback_base_path == "" do return false
        if pipeline.post_fragment.source_path == "" && pipeline.post_fragment.fallback_base_path == "" do return false
    }
    return true
}

Ownership :: enum {
    Borrowed,
    Owned,
}

Resource_Ownership :: struct {
    window:               Ownership,
    vulkan_context:       Ownership,
    textures:             Ownership,
    depth_hdr_targets:    Ownership,
    ui_context:           Ownership,
    transient_buffers:    Ownership,
    consumer_effect_data: Ownership,
}
