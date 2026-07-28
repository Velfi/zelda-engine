package canvas2d

// Product-neutral immediate 2D canvas backed by zelda-engine's Vulkan context.
// Consumer shaders define effect payload semantics and presentation policy.

import "core:image"
import _ "core:image/png"
import "core:math"
import "core:mem"
import "core:os"
import "core:time"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
import engine "zelda_engine:engine"
import render2d "zelda_engine:render2d"
import resources "zelda_engine:render_resources"
import ui "zelda_engine:ui"
SetRendererDescriptor :: proc(descriptor: render2d.Renderer_Descriptor) -> bool {
    if !render2d.descriptor_valid(descriptor) do return false
    state.renderer_descriptor = descriptor
    return true
}

shader_stage :: proc(stage: render2d.Shader_Stage) -> engine.Shader_Stage {
    switch stage {
    case .Vertex:
        return .Vertex
    case .Fragment:
        return .Fragment
    case .Compute:
        return .Compute
    }
    unreachable()
}

load_consumer_shader :: proc(
    ctx: ^engine.Vk_Context,
    descriptor: render2d.Shader_Module_Descriptor,
    out: ^engine.Vk_Shader_Module,
) -> bool {
    return engine.vk_load_shader_module_with_fallback(
        ctx,
        descriptor.source_path,
        descriptor.fallback_base_path,
        shader_stage(descriptor.stage),
        descriptor.entry_point,
        out,
    )
}

@(no_instrumentation)
to_color :: #force_inline proc(c: Color) -> [4]f32 { return{
        f32(c.r) / 255,
        f32(c.g) / 255,
        f32(c.b) / 255,
        f32(c.a) / 255,
    } }

srgb_channel_to_linear :: proc(channel: u8) -> f32 {
    c := f32(channel) / 255
    if c <= 0.04045 do return c / 12.92
    return math.pow((c + 0.055) / 1.055, 2.4)
}
@(no_instrumentation)
transform :: #force_inline proc(p: Vector2) -> Vector2 {if !state.camera_active do return p; c := state.camera
    return {(p.x - c.target.x) * c.zoom + c.offset.x, (p.y - c.target.y) * c.zoom + c.offset.y}}

@(no_instrumentation)
append_batch :: #force_inline proc(
    first, count: u32,
    texture: int,
    hatch := HATCH_DISABLED,
    effect := Effect_Payload{},
) {
    if len(state.batches) > 0 {
        last := &state.batches[len(state.batches) - 1]
        if last.texture == texture &&
           last.hatch == hatch &&
           last.effect == effect &&
           last.clip_enabled == state.clip_enabled &&
           (!state.clip_enabled || last.clip == state.clip) &&
           last.first + last.count == first {
            last.count += count
            return
        }
    }
    append(&state.batches, Batch {
        first        = first,
        count        = count,
        texture      = texture,
        hatch        = hatch,
        effect       = effect,
        clip_enabled = state.clip_enabled,
        clip         = state.clip,
    })}
@(no_instrumentation)
quad :: #force_inline proc(
    a, b, c, d: Vector2,
    color: Color,
    uv0 := Vector2{},
    uv1 := Vector2{1, 1},
    texture := -1,
    hatch := HATCH_DISABLED,
) {if len(state.vertices) + 4 > MAX_VERTICES do return; base := u32(len(state.vertices)); t := to_color(color)
    append(
        &state.vertices,
        Vertex{a, {uv0.x, uv0.y}, t},
        Vertex{b, {uv1.x, uv0.y}, t},
        Vertex{c, {uv1.x, uv1.y}, t},
        Vertex{d, {uv0.x, uv1.y}, t},
    )
    first := u32(len(state.indices))
    append(&state.indices, base, base + 1, base + 2, base, base + 2, base + 3)
    append_batch(first, 6, texture, hatch)}
rect :: proc(r: Rectangle, color: Color) {a := transform({r.x, r.y}); b := transform({r.x + r.width, r.y})
    c := transform({r.x + r.width, r.y + r.height})
    d := transform({r.x, r.y + r.height})
    quad(a, b, c, d, color)}
backend_destroy :: proc() {
    if state == nil do return
    if !state.initialized {
        render2d.sdl_input_destroy(&state.platform_input)
        render2d.sdl_window_destroy(&state.platform_window)
        state^ = {}
        return
    }
    render2d.sdl_input_destroy(
        &state.platform_input,
    ); state.gamepad = nil; if state.ctx.device != nil do _ = vk.DeviceWaitIdle(state.ctx.device)
    if state.pipeline != vk.Pipeline(0) do vk.DestroyPipeline(state.ctx.device, state.pipeline, nil)
    if state.hdr_pipeline != vk.Pipeline(0) do vk.DestroyPipeline(state.ctx.device, state.hdr_pipeline, nil)
    if state.post_pipeline != vk.Pipeline(0) do vk.DestroyPipeline(state.ctx.device, state.post_pipeline, nil)
    if state.pipeline_layout != vk.PipelineLayout(0) do vk.DestroyPipelineLayout(state.ctx.device, state.pipeline_layout, nil)
    if state.descriptor_pool != vk.DescriptorPool(0) do vk.DestroyDescriptorPool(state.ctx.device, state.descriptor_pool, nil)
    if state.descriptor_layout != vk.DescriptorSetLayout(0) do vk.DestroyDescriptorSetLayout(state.ctx.device, state.descriptor_layout, nil)
    glyph_cache_destroy()
    for i in 0 ..< state.texture_count do resources.image_destroy(&state.textures[i], &state.ctx)
    for i in 0 ..< MAX_TEXTURES {
        for frame in 0 ..< engine.MAX_FRAMES_IN_FLIGHT do engine.vk_destroy_buffer(&state.ctx, &state.dynamic_staging[i][frame])
        delete(state.dynamic_pixels[i])}
    resources.image_destroy(&state.depth, &state.ctx)
    resources.image_destroy(&state.world_scene, &state.ctx)
    resources.image_destroy(&state.hdr_scene, &state.ctx)
    for i in 0 ..< engine.MAX_FRAMES_IN_FLIGHT {
        engine.vk_destroy_buffer(&state.ctx, &state.vertex[i])
        engine.vk_destroy_buffer(&state.ctx, &state.index[i])}
    ui.gui_destroy(&state.gui)
    delete(state.vertices)
    delete(state.indices)
    delete(state.batches)
    if len(state.capture_path) > 0 do delete(state.capture_path)
    engine.vk_destroy_buffer(&state.ctx, &state.capture_buffer)
    engine.screenshot_state_destroy(&state.capture_state)
    engine.vk_context_destroy(&state.ctx)
    render2d.sdl_window_destroy(&state.platform_window)
    state.window = nil
    state^ = {}}
upload_font :: proc() -> bool {ui.gui_init(&state.gui)
    // Read advances from the same loaded faces and scale used to rasterize
    // their atlases. This keeps layout correct when either asset changes.
    shaped: [1]ui.Gui_Shaped_Glyph
    font_pixel_height := FONT_RASTER_H
    font_kinds := [2]ui.Gui_Font_Kind{ui.Gui_Font_Kind.Body, ui.Gui_Font_Kind.Display}
    for font_kind, index in font_kinds {
        for ch in FONT_FIRST ..= FONT_LAST {
            probe := [1]u8{u8(ch)}
            shaped_count := ui.gui_font_shape_text(
                font_kind,
                probe[:],
                f32(font_pixel_height) / ui.GUI_FONT_LOGICAL_HEIGHT,
                shaped[:],
            )
            state.font_advance_em[index][ch - FONT_FIRST] =
                shaped_count == 1 ? shaped[0].x_advance / f32(FONT_LOGICAL_CELL_H) : f32(.57)
        }
    }

    bounds: ui.Gui_Glyph_Bounds
    if !ui.gui_font_ascii_glyph_bounds(.Body, FONT_FIRST, FONT_LAST, font_pixel_height, &bounds) do return false
    display_bounds: ui.Gui_Glyph_Bounds
    if !ui.gui_font_ascii_glyph_bounds(.Display, FONT_FIRST, FONT_LAST, font_pixel_height, &display_bounds) do return false
    bounds.min_x = min(bounds.min_x, display_bounds.min_x)
    bounds.max_x = max(bounds.max_x, display_bounds.max_x)
    bounds.ascent = max(bounds.ascent, display_bounds.ascent)
    bounds.descent = max(bounds.descent, display_bounds.descent)

    for ch in FONT_FALLBACK_RUNES {
        is_symbol := ch == '◆' || ch == '◇' || ch == '✓' || ch == '✕' || ch == '⚠'
        fallback_height := is_symbol ? 36 : font_pixel_height
        fallback_kinds := is_symbol ? font_kinds[1:] : font_kinds[:]
        for fallback_kind in fallback_kinds {
            fallback_bounds: ui.Gui_Glyph_Bounds
            if !ui.gui_font_ascii_glyph_bounds(
                fallback_kind,
                int(ch),
                int(ch),
                fallback_height,
                &fallback_bounds,
            ) {
                return false
            }
            bounds.min_x = min(bounds.min_x, fallback_bounds.min_x)
            bounds.max_x = max(bounds.max_x, fallback_bounds.max_x)
            bounds.ascent = max(bounds.ascent, fallback_bounds.ascent)
            bounds.descent = max(bounds.descent, fallback_bounds.descent)
        }
    }

    // One transparent texel is insufficient with linear filtering at fractional
    // positions. Derive all remaining geometry from the loaded faces.
    padding := 2
    state.font_origin_x = padding - int(bounds.min_x)
    state.font_baseline = padding + int(bounds.ascent)
    state.font_cell_width = int(bounds.max_x - bounds.min_x) + padding * 2
    state.font_cell_height = int(bounds.ascent + bounds.descent) + padding * 2
    state.font_atlas_width = state.font_cell_width * FONT_COLUMNS
    state.font_atlas_height = state.font_cell_height * FONT_ROWS

    font_plane_bytes := state.font_atlas_width * state.font_atlas_height * 4
    font_pixels := make([]u8, font_plane_bytes * 2, context.temp_allocator)
    body_pixels := font_pixels[:font_plane_bytes]
    display_pixels := font_pixels[font_plane_bytes:]
    body_rendered := ui.gui_font_render_ascii_atlas(
        .Body, FONT_FIRST, FONT_LAST, font_pixel_height,
        state.font_cell_width, state.font_cell_height, FONT_COLUMNS,
        state.font_origin_x, state.font_baseline, body_pixels,
    )
    if !body_rendered do return false
    display_rendered := ui.gui_font_render_ascii_atlas(
        .Display, FONT_FIRST, FONT_LAST, font_pixel_height,
        state.font_cell_width, state.font_cell_height, FONT_COLUMNS,
        state.font_origin_x, state.font_baseline, display_pixels,
    )
    if !display_rendered do return false
    fallback_cell := make([]u8, state.font_cell_width * state.font_cell_height * 4, context.temp_allocator)
    for ch, fallback_index in FONT_FALLBACK_RUNES {
        is_symbol := ch == '◆' || ch == '◇' || ch == '✓' || ch == '✕' || ch == '⚠'
        fallback_height := is_symbol ? 36 : font_pixel_height
        slot := FONT_COUNT + fallback_index
        cell_x := slot % FONT_COLUMNS * state.font_cell_width
        cell_y := slot / FONT_COLUMNS * state.font_cell_height
        for plane in 0 ..< 2 {
            fallback_kind := is_symbol ? ui.Gui_Font_Kind.Display : font_kinds[plane]
            fallback_rendered := ui.gui_font_render_ascii_atlas(
                fallback_kind, int(ch), int(ch), fallback_height,
                state.font_cell_width, state.font_cell_height, 1,
                state.font_origin_x, state.font_baseline, fallback_cell,
            )
            if !fallback_rendered do return false
            for y in 0 ..< state.font_cell_height {
                destination := plane * font_plane_bytes +
                    (cell_y + y) * state.font_atlas_width * 4 +
                    cell_x * 4
                source := y * state.font_cell_width * 4
                copy(
                    font_pixels[destination:],
                    fallback_cell[source:source + state.font_cell_width * 4],
                )
            }
        }
    }
    icons, icon_error := image.load(
        "assets/icons/ui-icon-atlas-garden.png",
        {.alpha_add_if_missing},
        context.temp_allocator,
    )
    if icon_error != nil || icons == nil do return false
    defer image.destroy(icons, context.temp_allocator)
    width := max(state.font_atlas_width, icons.width)
    font_atlas_height := state.font_atlas_height * 2
    height := font_atlas_height + icons.height
    pixels := make([]u8, width * height * 4, context.temp_allocator)
    for y in 0 ..< font_atlas_height do copy(
        pixels[y * width * 4:],
        font_pixels[y * state.font_atlas_width * 4:(y + 1) * state.font_atlas_width * 4],
    )
    for y in 0 ..< icons.height do copy(pixels[(font_atlas_height + y) * width * 4:], icons.pixels.buf[y * icons.width * 4:(y + 1) * icons.width * 4])
    state.texture_width, state.texture_height = width, height
    state.icon_y, state.icon_width, state.icon_height = font_atlas_height, icons.width, icons.height
    return resources.texture_upload_rgba8(
        &state.ctx,
        pixels,
        width,
        height,
        &state.textures[0],
        {address_mode = .CLAMP_TO_EDGE},
    )}

backend_create_pipelines :: proc(
    ctx: ^engine.Vk_Context,
    layout: vk.PipelineLayout,
    pipeline, hdr_pipeline, post_pipeline: ^vk.Pipeline,
) -> bool {
    vert, frag: engine.Vk_Shader_Module
    if !load_consumer_shader(ctx, state.renderer_descriptor.pipeline.vertex, &vert) do return false
    defer engine.vk_destroy_shader_module(ctx, &vert)
    if !load_consumer_shader(ctx, state.renderer_descriptor.pipeline.fragment, &frag) do return false
    defer engine.vk_destroy_shader_module(ctx, &frag)
    stages := [2]vk.PipelineShaderStageCreateInfo {
        {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vert.handle, pName = "main"},
        {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = frag.handle, pName = "main"},
    }
    binding := vk.VertexInputBindingDescription {
        stride    = u32(size_of(Vertex)),
        inputRate = .VERTEX,
    }
    attrs := [3]vk.VertexInputAttributeDescription {
        {location = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, position))},
        {location = 1, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, uv))},
        {location = 2, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Vertex, color))},
    }
    vi := vk.PipelineVertexInputStateCreateInfo {
        sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount   = 1,
        pVertexBindingDescriptions      = &binding,
        vertexAttributeDescriptionCount = 3,
        pVertexAttributeDescriptions    = raw_data(attrs[:]),
    }
    ia := vk.PipelineInputAssemblyStateCreateInfo {
        sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }
    vp := vk.PipelineViewportStateCreateInfo {
        sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        scissorCount  = 1,
    }
    rs := vk.PipelineRasterizationStateCreateInfo {
        sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        cullMode    = {},
        frontFace   = .COUNTER_CLOCKWISE,
        lineWidth   = 1,
    }
    ms := vk.PipelineMultisampleStateCreateInfo {
        sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }
    ca := vk.PipelineColorBlendAttachmentState {
        blendEnable         = true,
        srcColorBlendFactor = .SRC_ALPHA,
        dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
        colorBlendOp        = .ADD,
        srcAlphaBlendFactor = .ONE,
        dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
        alphaBlendOp        = .ADD,
        colorWriteMask      = {.R, .G, .B, .A},
    }
    cb := vk.PipelineColorBlendStateCreateInfo {
        sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments    = &ca,
    }
    ds := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
    di := vk.PipelineDynamicStateCreateInfo {
        sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = 2,
        pDynamicStates    = raw_data(ds[:]),
    }
    rendering := engine.vk_pipeline_rendering_info(&ctx.swapchain_format)
    info := vk.GraphicsPipelineCreateInfo {
        sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext               = &rendering,
        stageCount          = 2,
        pStages             = raw_data(stages[:]),
        pVertexInputState   = &vi,
        pInputAssemblyState = &ia,
        pViewportState      = &vp,
        pRasterizationState = &rs,
        pMultisampleState   = &ms,
        pColorBlendState    = &cb,
        pDynamicState       = &di,
        layout              = layout,
    }
    if vk.CreateGraphicsPipelines(ctx.device, vk.PipelineCache(0), 1, &info, nil, pipeline) != .SUCCESS do return false
    engine.vk_set_debug_name(ctx, .PIPELINE, auto_cast pipeline^, "canvas graphics pipeline")
    hdr_format := vk.Format.R16G16B16A16_SFLOAT
    hdr_rendering := engine.vk_pipeline_rendering_info(&hdr_format)
    info.pNext = &hdr_rendering
    if vk.CreateGraphicsPipelines(ctx.device, vk.PipelineCache(0), 1, &info, nil, hdr_pipeline) != .SUCCESS do return false
    engine.vk_set_debug_name(ctx, .PIPELINE, auto_cast hdr_pipeline^, "canvas HDR pipeline")
    post_vert, post_frag: engine.Vk_Shader_Module
    if !load_consumer_shader(ctx, state.renderer_descriptor.pipeline.post_vertex, &post_vert) do return false
    defer engine.vk_destroy_shader_module(ctx, &post_vert)
    if !load_consumer_shader(ctx, state.renderer_descriptor.pipeline.post_fragment, &post_frag) do return false
    defer engine.vk_destroy_shader_module(ctx, &post_frag)
    post_stages := [2]vk.PipelineShaderStageCreateInfo {
        {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = post_vert.handle, pName = "main"},
        {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = post_frag.handle, pName = "main"},
    }
    empty_vi := vk.PipelineVertexInputStateCreateInfo {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    }
    post_ca := ca
    post_ca.blendEnable = false
    post_cb := cb
    post_cb.pAttachments = &post_ca
    post_rendering := engine.vk_pipeline_rendering_info(&ctx.swapchain_format)
    info.pNext = &post_rendering
    info.pStages = raw_data(post_stages[:])
    info.pVertexInputState = &empty_vi
    info.pColorBlendState = &post_cb
    if vk.CreateGraphicsPipelines(ctx.device, vk.PipelineCache(0), 1, &info, nil, post_pipeline) != .SUCCESS do return false
    engine.vk_set_debug_name(ctx, .PIPELINE, auto_cast post_pipeline^, "canvas post-process pipeline")
    return true
}

ReloadShaders :: proc() -> bool {
    if !state.initialized || state.ctx.device == nil do return false
    _ = vk.DeviceWaitIdle(state.ctx.device)
    next, next_hdr, next_post: vk.Pipeline
    if !backend_create_pipelines(&state.ctx, state.pipeline_layout, &next, &next_hdr, &next_post) {
        if next != vk.Pipeline(0) do vk.DestroyPipeline(state.ctx.device, next, nil)
        if next_hdr != vk.Pipeline(0) do vk.DestroyPipeline(state.ctx.device, next_hdr, nil)
        if next_post != vk.Pipeline(0) do vk.DestroyPipeline(state.ctx.device, next_post, nil)
        return false
    }
    old, old_hdr, old_post := state.pipeline, state.hdr_pipeline, state.post_pipeline
    state.pipeline, state.hdr_pipeline, state.post_pipeline = next, next_hdr, next_post
    if old != vk.Pipeline(0) do vk.DestroyPipeline(state.ctx.device, old, nil)
    if old_hdr != vk.Pipeline(0) do vk.DestroyPipeline(state.ctx.device, old_hdr, nil)
    if old_post != vk.Pipeline(0) do vk.DestroyPipeline(state.ctx.device, old_post, nil)
    return true
}

backend_init :: proc() -> bool {
    if !render2d.descriptor_valid(state.renderer_descriptor) do return false
    ctx := &state.ctx
    vsync_enabled := .VSYNC_HINT in state.config_flags
    if !engine.vk_context_init(ctx, state.window, state.width, state.height, .7, true, vsync_enabled) do return false
    if !resources.depth_create(ctx, ctx.swapchain_extent.width, ctx.swapchain_extent.height, &state.depth) do return false
    state.vertices = make(
        [dynamic]Vertex,
        0,
        8192,
    ); state.indices = make([dynamic]u32, 0, 12288); state.batches = make([dynamic]Batch, 0, 64)
    for i in 0 ..< engine.MAX_FRAMES_IN_FLIGHT { if !engine.vk_create_host_buffer(ctx, vk.DeviceSize(MAX_VERTICES * size_of(Vertex)), {.VERTEX_BUFFER}, &state.vertex[i]) do return false; if !engine.vk_create_host_buffer(ctx, vk.DeviceSize(MAX_INDICES * size_of(u32)), {.INDEX_BUFFER}, &state.index[i]) do return false }
    bindings := [2]vk.DescriptorSetLayoutBinding {
        {binding = 0, descriptorType = .SAMPLED_IMAGE, descriptorCount = 1, stageFlags = {.FRAGMENT}},
        {binding = 1, descriptorType = .SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
    }; li := vk.DescriptorSetLayoutCreateInfo {
        sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = 2,
        pBindings    = raw_data(bindings[:]),
    }; if vk.CreateDescriptorSetLayout(ctx.device, &li, nil, &state.descriptor_layout) != .SUCCESS do return false
    engine.vk_set_debug_name(
        ctx,
        .DESCRIPTOR_SET_LAYOUT,
        auto_cast state.descriptor_layout,
        "canvas descriptor set layout",
    )
    ps := [2]vk.DescriptorPoolSize {
        {type = .SAMPLED_IMAGE, descriptorCount = MAX_TEXTURES},
        {type = .SAMPLER, descriptorCount = MAX_TEXTURES},
    }; pi := vk.DescriptorPoolCreateInfo {
        sType         = .DESCRIPTOR_POOL_CREATE_INFO,
        maxSets       = MAX_TEXTURES,
        poolSizeCount = 2,
        pPoolSizes    = raw_data(ps[:]),
    }; if vk.CreateDescriptorPool(ctx.device, &pi, nil, &state.descriptor_pool) != .SUCCESS do return false
    engine.vk_set_debug_name(ctx, .DESCRIPTOR_POOL, auto_cast state.descriptor_pool, "canvas descriptor pool")
    ai := vk.DescriptorSetAllocateInfo {
        sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool     = state.descriptor_pool,
        descriptorSetCount = MAX_TEXTURES,
        pSetLayouts        = nil,
    }; layouts: [MAX_TEXTURES]vk.DescriptorSetLayout; for &layout in layouts do layout = state.descriptor_layout; ai.pSetLayouts = raw_data(layouts[:]); if vk.AllocateDescriptorSets(ctx.device, &ai, raw_data(state.descriptors[:])) != .SUCCESS do return false
    for &descriptor in state.descriptors do engine.vk_set_debug_name(ctx, .DESCRIPTOR_SET, auto_cast descriptor, "canvas descriptor set")
    if !upload_font() do return false; ii := vk.DescriptorImageInfo {
        imageView   = state.textures[0].view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }; si := vk.DescriptorImageInfo {
        sampler = state.textures[0].sampler,
    }; writes := [2]vk.WriteDescriptorSet {
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.descriptors[0],
            dstBinding = 0,
            descriptorCount = 1,
            descriptorType = .SAMPLED_IMAGE,
            pImageInfo = &ii,
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = state.descriptors[0],
            dstBinding = 1,
            descriptorCount = 1,
            descriptorType = .SAMPLER,
            pImageInfo = &si,
        },
    }; vk.UpdateDescriptorSets(ctx.device, 2, raw_data(writes[:]), 0, nil); state.texture_count = 1
    if !glyph_cache_init() do return false
    pr := vk.PushConstantRange {
        stageFlags = {.VERTEX, .FRAGMENT},
        size       = u32(size_of(Push)),
    }; pli := vk.PipelineLayoutCreateInfo {
        sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount         = 1,
        pSetLayouts            = &state.descriptor_layout,
        pushConstantRangeCount = 1,
        pPushConstantRanges    = &pr,
    }; if vk.CreatePipelineLayout(ctx.device, &pli, nil, &state.pipeline_layout) != .SUCCESS do return false
    engine.vk_set_debug_name(ctx, .PIPELINE_LAYOUT, auto_cast state.pipeline_layout, "canvas pipeline layout")
    vert, frag: engine.Vk_Shader_Module
    if !load_consumer_shader(ctx, state.renderer_descriptor.pipeline.vertex, &vert) do return false
    defer engine.vk_destroy_shader_module(ctx, &vert)
    if !load_consumer_shader(ctx, state.renderer_descriptor.pipeline.fragment, &frag) do return false
    defer engine.vk_destroy_shader_module(ctx, &frag)
    stages := [2]vk.PipelineShaderStageCreateInfo {
        {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vert.handle, pName = "main"},
        {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = frag.handle, pName = "main"},
    }; binding := vk.VertexInputBindingDescription {
        stride    = u32(size_of(Vertex)),
        inputRate = .VERTEX,
    }; attrs := [3]vk.VertexInputAttributeDescription {
        {location = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, position))},
        {location = 1, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, uv))},
        {location = 2, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Vertex, color))},
    }; vi := vk.PipelineVertexInputStateCreateInfo {
        sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount   = 1,
        pVertexBindingDescriptions      = &binding,
        vertexAttributeDescriptionCount = 3,
        pVertexAttributeDescriptions    = raw_data(attrs[:]),
    }; ia := vk.PipelineInputAssemblyStateCreateInfo {
        sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }; vp := vk.PipelineViewportStateCreateInfo {
        sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        scissorCount  = 1,
    }; rs := vk.PipelineRasterizationStateCreateInfo {
        sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        cullMode    = {},
        frontFace   = .COUNTER_CLOCKWISE,
        lineWidth   = 1,
    }; ms := vk.PipelineMultisampleStateCreateInfo {
        sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }; ca := vk.PipelineColorBlendAttachmentState {
        blendEnable         = true,
        srcColorBlendFactor = .SRC_ALPHA,
        dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
        colorBlendOp        = .ADD,
        srcAlphaBlendFactor = .ONE,
        dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
        alphaBlendOp        = .ADD,
        colorWriteMask      = {.R, .G, .B, .A},
    }; cb := vk.PipelineColorBlendStateCreateInfo {
        sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments    = &ca,
    }; ds := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}; di := vk.PipelineDynamicStateCreateInfo {
        sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = 2,
        pDynamicStates    = raw_data(ds[:]),
    }; rendering := engine.vk_pipeline_rendering_info(&ctx.swapchain_format); info := vk.GraphicsPipelineCreateInfo {
        sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext               = &rendering,
        stageCount          = 2,
        pStages             = raw_data(stages[:]),
        pVertexInputState   = &vi,
        pInputAssemblyState = &ia,
        pViewportState      = &vp,
        pRasterizationState = &rs,
        pMultisampleState   = &ms,
        pColorBlendState    = &cb,
        pDynamicState       = &di,
        layout              = state.pipeline_layout,
    }
    if vk.CreateGraphicsPipelines(ctx.device, vk.PipelineCache(0), 1, &info, nil, &state.pipeline) != .SUCCESS do return false
    engine.vk_set_debug_name(ctx, .PIPELINE, auto_cast state.pipeline, "canvas graphics pipeline")
    hdr_format := vk.Format.R16G16B16A16_SFLOAT
    hdr_rendering := engine.vk_pipeline_rendering_info(&hdr_format)
    info.pNext = &hdr_rendering
    if vk.CreateGraphicsPipelines(ctx.device, vk.PipelineCache(0), 1, &info, nil, &state.hdr_pipeline) != .SUCCESS do return false
    engine.vk_set_debug_name(ctx, .PIPELINE, auto_cast state.hdr_pipeline, "canvas HDR pipeline")
    post_vert, post_frag: engine.Vk_Shader_Module
    if !load_consumer_shader(ctx, state.renderer_descriptor.pipeline.post_vertex, &post_vert) do return false
    defer engine.vk_destroy_shader_module(ctx, &post_vert)
    if !load_consumer_shader(ctx, state.renderer_descriptor.pipeline.post_fragment, &post_frag) do return false
    defer engine.vk_destroy_shader_module(ctx, &post_frag)
    post_stages := [2]vk.PipelineShaderStageCreateInfo {
        {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = post_vert.handle, pName = "main"},
        {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = post_frag.handle, pName = "main"},
    }
    empty_vi := vk.PipelineVertexInputStateCreateInfo {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    }
    post_ca := ca; post_ca.blendEnable = false
    post_cb := cb; post_cb.pAttachments = &post_ca
    post_rendering := engine.vk_pipeline_rendering_info(&ctx.swapchain_format)
    info.pNext = &post_rendering; info.pStages = raw_data(post_stages[:]); info.pVertexInputState = &empty_vi; info.pColorBlendState = &post_cb
    if vk.CreateGraphicsPipelines(ctx.device, vk.PipelineCache(0), 1, &info, nil, &state.post_pipeline) != .SUCCESS do return false
    engine.vk_set_debug_name(ctx, .PIPELINE, auto_cast state.post_pipeline, "canvas post-process pipeline")
    return true
}
