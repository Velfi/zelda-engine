package canvas2d

import "core:fmt"
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

upload_dynamic_textures :: proc(ctx: ^engine.Vk_Context, frame: engine.Vk_Frame) {
    marker := gfx_profile_begin(.Dynamic_Uploads)
    defer gfx_profile_end(.Dynamic_Uploads, marker)
    // Dynamic texture transfers share the frame command buffer. Queue ordering
    // keeps prior fragment reads ahead of these writes, while per-frame staging
    // buffers avoid both QueueWaitIdle and reuse of in-flight host memory.
    for id in 1 ..< state.texture_count {
        if !state.dynamic_pending[id] do continue
        image := &state.textures[id]
        staging := &state.dynamic_staging[id][frame.frame_index]
        bytes_per_pixel := max(state.dynamic_bytes_per_pixel[id], 1)
        byte_count := int(image.width * image.height) * bytes_per_pixel
        if staging.handle == vk.Buffer(0) || len(state.dynamic_pixels[id]) < byte_count do continue
        mem.copy_non_overlapping(staging.mapped, raw_data(state.dynamic_pixels[id][:]), byte_count)
        dirty := state.dynamic_dirty[id]
        x := clamp(int(dirty.x), 0, int(image.width))
        y := clamp(int(dirty.y), 0, int(image.height))
        width := clamp(int(dirty.width), 1, int(image.width) - x)
        height := clamp(int(dirty.height), 1, int(image.height) - y)
        render2d.metrics_record_upload(&state.metrics, u64(width * height * bytes_per_pixel))
        engine.vk_cmd_image_barrier2(
            ctx,
            frame.command_buffer,
            image.image,
            {.FRAGMENT_SHADER},
            {.TRANSFER},
            {.SHADER_READ},
            {.TRANSFER_WRITE},
            .SHADER_READ_ONLY_OPTIMAL,
            .TRANSFER_DST_OPTIMAL,
        )
        region := vk.BufferImageCopy {
            bufferOffset = vk.DeviceSize((y * int(image.width) + x) * bytes_per_pixel),
            bufferRowLength = image.width,
            bufferImageHeight = image.height,
            imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
            imageOffset = {i32(x), i32(y), 0},
            imageExtent = {u32(width), u32(height), 1},
        }
        vk.CmdCopyBufferToImage(frame.command_buffer, staging.handle, image.image, .TRANSFER_DST_OPTIMAL, 1, &region)
        engine.vk_cmd_image_barrier2(
            ctx,
            frame.command_buffer,
            image.image,
            {.TRANSFER},
            {.FRAGMENT_SHADER},
            {.TRANSFER_WRITE},
            {.SHADER_READ},
            .TRANSFER_DST_OPTIMAL,
            .SHADER_READ_ONLY_OPTIMAL,
        )
        state.dynamic_pending[id] = false
        state.dynamic_dirty[id] = {}
    }
}

@(no_instrumentation)
batch_scissor_rect :: #force_inline proc(batch: Batch, extent: vk.Extent2D) -> vk.Rect2D {
    result := vk.Rect2D {
        extent = extent,
    }
    if !batch.clip_enabled do return result
    framebuffer_width := f32(max(state.framebuffer_width, 1))
    framebuffer_height := f32(max(state.framebuffer_height, 1))
    logical_width := f32(max(state.width, 1))
    logical_height := f32(max(state.height, 1))
    x0 := i32(clamp(batch.clip.x / logical_width * framebuffer_width, f32(0), framebuffer_width))
    y0 := i32(clamp(batch.clip.y / logical_height * framebuffer_height, f32(0), framebuffer_height))
    x1 := i32(clamp((batch.clip.x + batch.clip.width) / logical_width * framebuffer_width, f32(0), framebuffer_width))
    y1 := i32(
        clamp((batch.clip.y + batch.clip.height) / logical_height * framebuffer_height, f32(0), framebuffer_height),
    )
    result.offset = {x0, y0}
    result.extent = {u32(max(x1 - x0, 0)), u32(max(y1 - y0, 0))}
    return result
}

@(no_instrumentation)
batch_push_constants :: #force_inline proc(batch: ^Batch) -> Push {
    texture_mode := f32(batch.texture >= 0 ? 1 : 0)
    for page in state.glyph_pages {
        if page.ready && batch.texture == page.id {
            texture_mode = 2
            break
        }
    }
    push := Push {
        viewport      = {
            f32(state.width),
            f32(state.height),
            f32(state.framebuffer_width),
            f32(state.framebuffer_height),
        },
        texture_hatch = {texture_mode, 0, 0, 0},
    }
    if state.renderer_descriptor.encode_batch_payload != nil {
        destination := mem.slice_ptr(cast([^]u8)&push, size_of(Push))
        _ = state.renderer_descriptor.encode_batch_payload(
            destination,
            rawptr(batch),
            state.renderer_descriptor.user_data,
        )
    }
    return push
}

world_post_push_constants :: proc(source, composite, target: vk.Extent2D, pass_index: int = 0, pass_count: int = 1) -> Push {
    push := Push{}
    if state.renderer_descriptor.encode_world_post_push != nil {
        destination := mem.slice_ptr(cast([^]u8)&push, size_of(Push))
        post_context := render2d.World_Post_Context {
            source_extent    = {source.width, source.height},
            composite_extent = {composite.width, composite.height},
            target_extent    = {target.width, target.height},
            pass_index       = u32(pass_index),
            pass_count       = u32(pass_count),
        }
        if pass_index >= 0 && pass_index < state.world_post_pass_count {
            post_context.pass_parameters = state.world_post_passes[pass_index].parameters
        }
        _ = state.renderer_descriptor.encode_world_post_push(
            destination,
            post_context,
            state.renderer_descriptor.user_data,
        )
    }
    return push
}

resolve_hdr_scene :: proc(ctx: ^engine.Vk_Context, frame: engine.Vk_Frame, extent: vk.Extent2D) {
    marker := gfx_profile_begin(.HDR_Resolve)
    defer gfx_profile_end(.HDR_Resolve, marker)
    engine.vk_cmd_image_barrier2(
        ctx,
        frame.command_buffer,
        state.hdr_scene.image,
        {.COLOR_ATTACHMENT_OUTPUT},
        {.FRAGMENT_SHADER},
        {.COLOR_ATTACHMENT_WRITE},
        {.SHADER_READ},
        .COLOR_ATTACHMENT_OPTIMAL,
        .SHADER_READ_ONLY_OPTIMAL,
    )
    engine.vk_cmd_begin_swapchain_render_pass_load(ctx, frame)
    viewport := vk.Viewport {
        width    = f32(extent.width),
        height   = f32(extent.height),
        minDepth = 0,
        maxDepth = 1,
    }
    scissor := vk.Rect2D {
        extent = extent,
    }
    vk.CmdSetViewport(frame.command_buffer, 0, 1, &viewport)
    vk.CmdSetScissor(frame.command_buffer, 0, 1, &scissor)
    vk.CmdBindPipeline(frame.command_buffer, .GRAPHICS, state.post_pipeline)
    vk.CmdBindDescriptorSets(
        frame.command_buffer,
        .GRAPHICS,
        state.post_pipeline_layout,
        0,
        1,
        &state.post_descriptors[WORLD_POST_HDR_DESCRIPTOR],
        0,
        nil,
    )
    post_push := Push {
        viewport      = {f32(state.width), f32(state.height), f32(extent.width), f32(extent.height)},
        texture_hatch = {f32(screen_effect), 0, 0, 0},
        hatch_shape   = {f32(GetTime()), screen_effect_reduced_motion ? 1 : 0, 0, 0},
    }
    vk.CmdPushConstants(
        frame.command_buffer,
        state.post_pipeline_layout,
        {.VERTEX, .FRAGMENT},
        0,
        u32(size_of(post_push)),
        &post_push,
    )
    vk.CmdDraw(frame.command_buffer, 3, 1, 0, 0)
    render2d.metrics_record_draw(&state.metrics)
    engine.vk_cmd_end_swapchain_render_pass(frame)
}

record_screenshot_readback :: proc(
    ctx: ^engine.Vk_Context,
    frame: engine.Vk_Frame,
    image: vk.Image,
    extent: vk.Extent2D,
) -> (
    bool,
    u64,
) {
    do_capture := state.capture_requested && ctx.swapchain_supports_transfer_src
    marker: u64
    if state.capture_requested && !ctx.swapchain_supports_transfer_src {
        fmt.eprintf("screenshot capture: swapchain does not support TRANSFER_SRC\n")
    }
    if do_capture {
        marker = gfx_profile_begin(.Screenshot_Readback)
        byte_count := vk.DeviceSize(extent.width) * vk.DeviceSize(extent.height) * 4
        if state.capture_buffer.size < byte_count {
            engine.vk_destroy_buffer(ctx, &state.capture_buffer)
            if !engine.vk_create_host_buffer(ctx, byte_count, {.TRANSFER_DST}, &state.capture_buffer) {
                fmt.eprintf("screenshot capture: could not allocate %d-byte readback buffer\n", byte_count)
                do_capture = false
            }
        }
    }
    if do_capture {
        engine.vk_cmd_image_barrier2(
            ctx,
            frame.command_buffer,
            image,
            {.COLOR_ATTACHMENT_OUTPUT},
            {.TRANSFER},
            {.COLOR_ATTACHMENT_WRITE},
            {.TRANSFER_READ},
            .COLOR_ATTACHMENT_OPTIMAL,
            .TRANSFER_SRC_OPTIMAL,
        )
        region := vk.BufferImageCopy {
            imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
            imageExtent = {extent.width, extent.height, 1},
        }
        vk.CmdCopyImageToBuffer(
            frame.command_buffer,
            image,
            .TRANSFER_SRC_OPTIMAL,
            state.capture_buffer.handle,
            1,
            &region,
        )
        engine.vk_cmd_image_barrier2(
            ctx,
            frame.command_buffer,
            image,
            {.TRANSFER},
            {.BOTTOM_OF_PIPE},
            {.TRANSFER_READ},
            {},
            .TRANSFER_SRC_OPTIMAL,
            .PRESENT_SRC_KHR,
        )
    } else {
        engine.vk_cmd_image_barrier2(
            ctx,
            frame.command_buffer,
            image,
            {.COLOR_ATTACHMENT_OUTPUT},
            {.BOTTOM_OF_PIPE},
            {.COLOR_ATTACHMENT_WRITE},
            {},
            .COLOR_ATTACHMENT_OPTIMAL,
            .PRESENT_SRC_KHR,
        )
    }
    return do_capture, marker
}

record_world_mask_pass :: proc(
    ctx: ^engine.Vk_Context,
    frame: engine.Vk_Frame,
    extent: vk.Extent2D,
    logical_extent: [2]i32,
) {
    if state.world_mask_pass == nil || !state.world_mask_active do return
    msaa_active := state.world_sample_count_effective > 1
    samples: vk.SampleCountFlags = {._1}
    if state.world_sample_count_effective == 2 do samples = {._2}
    if state.world_sample_count_effective == 4 do samples = {._4}
    color_target := msaa_active ? &state.world_msaa_mask : &state.world_mask
    color_target_ready := !msaa_active && state.world_mask_sample_ready
    old_layout := color_target_ready ? vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL : vk.ImageLayout.UNDEFINED
    engine.vk_cmd_image_barrier2(
        ctx,
        frame.command_buffer,
        color_target.image,
        color_target_ready ? vk.PipelineStageFlags2{.FRAGMENT_SHADER} : vk.PipelineStageFlags2{.TOP_OF_PIPE},
        {.COLOR_ATTACHMENT_OUTPUT},
        color_target_ready ? vk.AccessFlags2{.SHADER_READ} : vk.AccessFlags2{},
        {.COLOR_ATTACHMENT_WRITE},
        old_layout,
        .COLOR_ATTACHMENT_OPTIMAL,
    )
    if msaa_active {
        engine.vk_cmd_image_barrier2(
            ctx,
            frame.command_buffer,
            state.world_mask.image,
            state.world_mask_sample_ready ? vk.PipelineStageFlags2{.FRAGMENT_SHADER} : vk.PipelineStageFlags2{.TOP_OF_PIPE},
            {.COLOR_ATTACHMENT_OUTPUT},
            state.world_mask_sample_ready ? vk.AccessFlags2{.SHADER_READ} : vk.AccessFlags2{},
            {.COLOR_ATTACHMENT_WRITE},
            state.world_mask_sample_ready ? vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL : vk.ImageLayout.UNDEFINED,
            .COLOR_ATTACHMENT_OPTIMAL,
        )
    }
    clear := vk.ClearValue{color = {float32 = {0, 0, 0, 0}}}
    color_attachment := vk.RenderingAttachmentInfo {
        sType = .RENDERING_ATTACHMENT_INFO,
        imageView = color_target.view,
        imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
        loadOp = .CLEAR,
        storeOp = .STORE,
        clearValue = clear,
    }
    if msaa_active {
        color_attachment.resolveMode = {.AVERAGE}
        color_attachment.resolveImageView = state.world_mask.view
        color_attachment.resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL
    }
    depth_attachment := vk.RenderingAttachmentInfo {
        sType = .RENDERING_ATTACHMENT_INFO,
        imageView = msaa_active ? state.world_msaa_depth.view : state.depth.view,
        imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
        loadOp = .LOAD,
        storeOp = .STORE,
    }
    rendering := vk.RenderingInfo {
        sType = .RENDERING_INFO,
        renderArea = {extent = extent},
        layerCount = 1,
        colorAttachmentCount = 1,
        pColorAttachments = &color_attachment,
        pDepthAttachment = &depth_attachment,
    }
    vk.CmdBeginRendering(frame.command_buffer, &rendering)
    mask_context := World_Mask_Pass_Context {
        ctx = ctx,
        frame = frame,
        color_view = color_target.view,
        color_format = .R8_UNORM,
        depth_view = depth_attachment.imageView,
        framebuffer_extent = extent,
        logical_extent = logical_extent,
        sample_count = samples,
    }
    state.world_mask_pass(&mask_context, state.world_mask_pass_user_data)
    vk.CmdEndRendering(frame.command_buffer)
    engine.vk_cmd_image_barrier2(
        ctx,
        frame.command_buffer,
        state.world_mask.image,
        {.COLOR_ATTACHMENT_OUTPUT},
        {.FRAGMENT_SHADER},
        {.COLOR_ATTACHMENT_WRITE},
        {.SHADER_READ},
        .COLOR_ATTACHMENT_OPTIMAL,
        .SHADER_READ_ONLY_OPTIMAL,
    )
    state.world_mask_sample_ready = true
}

record_world_post_chain :: proc(ctx: ^engine.Vk_Context, frame: engine.Vk_Frame, source_extent, swap_extent: vk.Extent2D, clear: vk.ClearValue) {
    pass_count := max(state.world_post_pass_count, 1)
    source := &state.world_scene
    current_extent := source_extent
    for pass_index in 0 ..< pass_count - 1 {
        ping_index := pass_index & 1
        target := &state.world_post_ping[ping_index]
        target_extent := vk.Extent2D{target.width, target.height}
        old_layout := state.world_post_ping_sample_ready[ping_index] ? vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL : vk.ImageLayout.UNDEFINED
        engine.vk_cmd_image_barrier2(ctx, frame.command_buffer, target.image, {.FRAGMENT_SHADER}, {.COLOR_ATTACHMENT_OUTPUT}, {.SHADER_READ}, {.COLOR_ATTACHMENT_WRITE}, old_layout, .COLOR_ATTACHMENT_OPTIMAL)
        engine.vk_cmd_begin_rendering(ctx, frame.command_buffer, target.view, target_extent, .COLOR_ATTACHMENT_OPTIMAL, .CLEAR, .STORE, clear)
        viewport := vk.Viewport{width = f32(target_extent.width), height = f32(target_extent.height), minDepth = 0, maxDepth = 1}
        scissor := vk.Rect2D{extent = target_extent}
        vk.CmdSetViewport(frame.command_buffer, 0, 1, &viewport)
        vk.CmdSetScissor(frame.command_buffer, 0, 1, &scissor)
        descriptor_index := WORLD_POST_PING_DESCRIPTOR_BASE + ping_index
        update_world_post_descriptor(descriptor_index, source, &state.world_scene)
        vk.CmdBindPipeline(frame.command_buffer, .GRAPHICS, state.post_pipeline)
        vk.CmdBindDescriptorSets(frame.command_buffer, .GRAPHICS, state.post_pipeline_layout, 0, 1, &state.post_descriptors[descriptor_index], 0, nil)
        push := world_post_push_constants(current_extent, target_extent, target_extent, pass_index, pass_count)
        vk.CmdPushConstants(frame.command_buffer, state.post_pipeline_layout, {.VERTEX, .FRAGMENT}, 0, u32(size_of(push)), &push)
        vk.CmdDraw(frame.command_buffer, 3, 1, 0, 0)
        engine.vk_cmd_end_swapchain_render_pass(frame)
        engine.vk_cmd_image_barrier2(ctx, frame.command_buffer, target.image, {.COLOR_ATTACHMENT_OUTPUT}, {.FRAGMENT_SHADER}, {.COLOR_ATTACHMENT_WRITE}, {.SHADER_READ}, .COLOR_ATTACHMENT_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)
        state.world_post_ping_sample_ready[ping_index] = true
        source = target
        current_extent = target_extent
    }

    engine.vk_cmd_begin_rendering(ctx, frame.command_buffer, ctx.swapchain_image_views[frame.image_index], swap_extent, .COLOR_ATTACHMENT_OPTIMAL, .CLEAR, .STORE, clear)
    window_aspect := f32(swap_extent.width) / f32(max(swap_extent.height, 1))
    world_aspect := f32(source_extent.width) / f32(max(source_extent.height, 1))
    composite_width, composite_height := f32(swap_extent.width), f32(swap_extent.height)
    if window_aspect > world_aspect do composite_width = composite_height * world_aspect
    if window_aspect <= world_aspect do composite_height = composite_width / world_aspect
    viewport := vk.Viewport{x = (f32(swap_extent.width) - composite_width) * .5, y = (f32(swap_extent.height) - composite_height) * .5, width = composite_width, height = composite_height, minDepth = 0, maxDepth = 1}
    scissor := vk.Rect2D{offset = {i32(viewport.x), i32(viewport.y)}, extent = {u32(composite_width), u32(composite_height)}}
    vk.CmdSetViewport(frame.command_buffer, 0, 1, &viewport)
    vk.CmdSetScissor(frame.command_buffer, 0, 1, &scissor)
    descriptor_index := WORLD_POST_SCENE_DESCRIPTOR
    if pass_count > 1 {
        update_world_post_descriptor(descriptor_index, source, &state.world_scene)
    }
    vk.CmdBindPipeline(frame.command_buffer, .GRAPHICS, state.post_pipeline)
    vk.CmdBindDescriptorSets(frame.command_buffer, .GRAPHICS, state.post_pipeline_layout, 0, 1, &state.post_descriptors[descriptor_index], 0, nil)
    composite_extent := vk.Extent2D{u32(composite_width), u32(composite_height)}
    push := world_post_push_constants(current_extent, composite_extent, swap_extent, pass_count - 1, pass_count)
    vk.CmdPushConstants(frame.command_buffer, state.post_pipeline_layout, {.VERTEX, .FRAGMENT}, 0, u32(size_of(push)), &push)
    vk.CmdDraw(frame.command_buffer, 3, 1, 0, 0)
    engine.vk_cmd_end_swapchain_render_pass(frame)
}

publish_screenshot_readback :: proc(
    ctx: ^engine.Vk_Context,
    extent: vk.Extent2D,
    do_capture: bool,
    frame_ended: bool,
    marker: u64,
) {
    defer if marker != 0 do gfx_profile_end(.Screenshot_Readback, marker)
    if !do_capture || !frame_ended do return
    _ = vk.DeviceWaitIdle(ctx.device)
    byte_count := int(extent.width * extent.height * 4)
    pointer := cast([^]u8)state.capture_buffer.mapped
    pixels := pointer[:byte_count]
    if engine.screenshot_state_publish_from_gpu_rgba(
        &state.capture_state,
        pixels,
        extent.width,
        extent.height,
        ctx.swapchain_format,
        1,
    ) {
        data, _, _, _, encoded := engine.screenshot_state_copy_png(&state.capture_state, context.temp_allocator)
        if !encoded {
            fmt.eprintf("screenshot capture: PNG encoding failed for %dx%d readback\n", extent.width, extent.height)
            return
        }
        if write_error := os.write_entire_file(state.capture_path, data); write_error != nil {
            fmt.eprintf("screenshot capture: could not write %q: %v\n", state.capture_path, write_error)
            return
        }
        {
            state.capture_requested = false
            delete(state.capture_path)
            state.capture_path = ""
            render2d.metrics_record_screenshot(
                &state.metrics,
                time.duration_seconds(time.tick_since(state.capture_started)) * 1000,
            )
        }
    } else {
        fmt.eprintf("screenshot capture: rejected %dx%d GPU readback\n", extent.width, extent.height)
    }
}

EndDrawing :: proc() {
    // Callers may submit a loading frame immediately after InitWindow. If the
    // backend could not initialize, leave that frame inert instead of invoking
    // unloaded Vulkan device procedures through a nil context.
    if state == nil || !state.initialized || state.ctx.device == nil do return
    defer gfx_profile_end(.Frame, state.gfx_frame_signpost)
    defer render2d.metrics_end_frame(&state.metrics)
    render2d.metrics_record_batches(&state.metrics, u64(len(state.batches)))
    ui.gui_end_frame(&state.gui); ctx := &state.ctx
    // World composition resolves before the native UI pass, so the legacy
    // whole-frame HDR path must not wrap both layers together.
    fixed_world_configured := state.world_pass != nil && state.world_render_width > 0 && state.world_render_height > 0
    world_resolve_configured := world_resolve_required(
        state.world_pass != nil,
        state.world_render_width,
        state.world_render_height,
        state.world_post_process_enabled,
    )
    hdr_active := !world_resolve_configured && screen_effect != .None
    if !world_resolve_configured {
        for batch in state.batches do if batch.effect.hdr_required { hdr_active = ensure_hdr_scene(); break }
    }
    if hdr_active && state.hdr_scene.image == vk.Image(0) do hdr_active = ensure_hdr_scene()
    if ctx.needs_swapchain_recreate {w, h: i32
        sdl.GetWindowSizeInPixels(state.window, &w, &h)
        if w > 0 &&
           h >
               0 { if engine.vk_recreate_swapchain(ctx, w, h) && state.world_pass != nil do _ = ensure_depth_attachment() }
        return}
    if state.world_pass != nil && !ensure_depth_attachment() do return
    if state.world_pass != nil && !ensure_world_mask_attachment() do return
    if state.world_pass != nil && !ensure_world_scene() do return
    if world_resolve_configured && state.world_post_pass_count > 1 {
        source_extent := world_scene_extent()
        intermediate_count := min(state.world_post_pass_count - 1, 2)
        for index in 0 ..< intermediate_count {
            target_extent := world_post_resolution_extent(source_extent, state.world_post_passes[index].resolution)
            if !ensure_world_post_ping(index, target_extent) do return
        }
    }
    world_extent := ctx.swapchain_extent
    if fixed_world_configured do world_extent = {state.world_render_width, state.world_render_height}
    world_color_format := world_resolve_configured ? ctx.swapchain_format : (hdr_active ? vk.Format.R16G16B16A16_SFLOAT : ctx.swapchain_format)
    if state.world_pass != nil && !ensure_world_msaa_color(world_extent, world_color_format) do return
    msaa_active := state.world_sample_count_effective > 1
    acquire_marker := gfx_profile_begin(.Acquire_Frame)
    frame, ok := engine.vk_begin_frame(ctx)
    gfx_profile_end(.Acquire_Frame, acquire_marker)
    if !ok do return
    detailed_gfx := gfx_detailed_profile_enabled()
    frame_setup_marker: u64
    if detailed_gfx do frame_setup_marker = gfx_profile_begin(.Frame_Setup)
    upload_dynamic_textures(ctx, frame)
    extent := ctx.swapchain_extent
    world_resolve := world_resolve_configured
    image := ctx.swapchain_images[frame.image_index]
    swapchain_old_layout := vk.ImageLayout.PRESENT_SRC_KHR
    if !ctx.swapchain_image_initialized[frame.image_index] {
        swapchain_old_layout = .UNDEFINED
    }
    engine.vk_cmd_image_barrier2(
        ctx,
        frame.command_buffer,
        image,
        {.COLOR_ATTACHMENT_OUTPUT},
        {.COLOR_ATTACHMENT_OUTPUT},
        {},
        {.COLOR_ATTACHMENT_WRITE},
        swapchain_old_layout,
        .COLOR_ATTACHMENT_OPTIMAL,
    )
    ctx.swapchain_image_initialized[frame.image_index] = true
    if state.world_pass != nil {
        depth_src_stage := vk.PipelineStageFlags2{.TOP_OF_PIPE}
        depth_src_access := vk.AccessFlags2{}
        depth_old_layout := vk.ImageLayout.UNDEFINED
        if state.depth_sample_ready {
            depth_src_stage = {.FRAGMENT_SHADER}
            depth_src_access = {.SHADER_READ}
            depth_old_layout = .SHADER_READ_ONLY_OPTIMAL
        } else if state.depth_initialized {
            depth_src_stage = {.LATE_FRAGMENT_TESTS}
            depth_src_access = {.DEPTH_STENCIL_ATTACHMENT_WRITE}
            depth_old_layout = .DEPTH_ATTACHMENT_OPTIMAL
        }
        engine.vk_cmd_image_barrier2(
            ctx,
            frame.command_buffer,
            state.depth.image,
            depth_src_stage,
            {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
            depth_src_access,
            {.DEPTH_STENCIL_ATTACHMENT_WRITE},
            depth_old_layout,
            .DEPTH_ATTACHMENT_OPTIMAL,
            {.DEPTH},
        )
        if msaa_active {
            engine.vk_cmd_image_barrier2(
                ctx,
                frame.command_buffer,
                state.world_msaa_depth.image,
                state.depth_initialized ? vk.PipelineStageFlags2{.LATE_FRAGMENT_TESTS} : vk.PipelineStageFlags2{.TOP_OF_PIPE},
                {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
                state.depth_initialized ? vk.AccessFlags2{.DEPTH_STENCIL_ATTACHMENT_WRITE} : vk.AccessFlags2{},
                {.DEPTH_STENCIL_ATTACHMENT_WRITE},
                state.depth_initialized ? vk.ImageLayout.DEPTH_ATTACHMENT_OPTIMAL : vk.ImageLayout.UNDEFINED,
                .DEPTH_ATTACHMENT_OPTIMAL,
                {.DEPTH},
            )
            engine.vk_cmd_image_barrier2(
                ctx,
                frame.command_buffer,
                state.world_msaa_color.image,
                state.world_msaa_color_initialized ? vk.PipelineStageFlags2{.COLOR_ATTACHMENT_OUTPUT} : vk.PipelineStageFlags2{.TOP_OF_PIPE},
                {.COLOR_ATTACHMENT_OUTPUT},
                state.world_msaa_color_initialized ? vk.AccessFlags2{.COLOR_ATTACHMENT_WRITE} : vk.AccessFlags2{},
                {.COLOR_ATTACHMENT_WRITE},
                state.world_msaa_color_initialized ? vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL : vk.ImageLayout.UNDEFINED,
                .COLOR_ATTACHMENT_OPTIMAL,
            )
            state.world_msaa_color_initialized = true
        }
        state.depth_initialized = true
        state.depth_sample_ready = false
    }
    if world_resolve {
        engine.vk_cmd_image_barrier2(
            ctx,
            frame.command_buffer,
            state.world_scene.image,
            state.world_scene_sample_ready ? vk.PipelineStageFlags2{.FRAGMENT_SHADER} : vk.PipelineStageFlags2{.TOP_OF_PIPE},
            {.COLOR_ATTACHMENT_OUTPUT},
            state.world_scene_sample_ready ? vk.AccessFlags2{.SHADER_READ} : vk.AccessFlags2{},
            {.COLOR_ATTACHMENT_WRITE},
            state.world_scene_sample_ready ? vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL : vk.ImageLayout.UNDEFINED,
            .COLOR_ATTACHMENT_OPTIMAL,
        )
    }
    color_clear := vk.ClearValue {
        color = {
            float32 = {
                srgb_channel_to_linear(state.clear.r),
                srgb_channel_to_linear(state.clear.g),
                srgb_channel_to_linear(state.clear.b),
                f32(state.clear.a) / 255,
            },
        },
    }; depth_clear := vk.ClearValue {
        depthStencil = {depth = 1},
    }
    if hdr_active do engine.vk_cmd_image_barrier2(ctx, frame.command_buffer, state.hdr_scene.image, {.TOP_OF_PIPE}, {.COLOR_ATTACHMENT_OUTPUT}, {}, {.COLOR_ATTACHMENT_WRITE}, .UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL)
    color_attachment := vk.RenderingAttachmentInfo {
        sType       = .RENDERING_ATTACHMENT_INFO,
        imageView   = msaa_active ? state.world_msaa_color.view : (world_resolve ? state.world_scene.view : (hdr_active ? state.hdr_scene.view : ctx.swapchain_image_views[frame.image_index])),
        imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
        loadOp      = .CLEAR,
        storeOp     = .STORE,
        clearValue  = color_clear,
    }
    if msaa_active {
        color_attachment.resolveMode = {.AVERAGE}
        color_attachment.resolveImageView = world_resolve ? state.world_scene.view : (hdr_active ? state.hdr_scene.view : ctx.swapchain_image_views[frame.image_index])
        color_attachment.resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL
    }
    depth_attachment := vk.RenderingAttachmentInfo {
        sType       = .RENDERING_ATTACHMENT_INFO,
        imageView   = msaa_active ? state.world_msaa_depth.view : state.depth.view,
        imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
        loadOp      = .CLEAR,
        storeOp     = .STORE,
        clearValue  = depth_clear,
    }
    if msaa_active {
        depth_attachment.resolveMode = {.MIN}
        depth_attachment.resolveImageView = state.depth.view
        depth_attachment.resolveImageLayout = .DEPTH_ATTACHMENT_OPTIMAL
    }
    rendering := vk.RenderingInfo {
        sType = .RENDERING_INFO,
        renderArea = {extent = world_extent},
        layerCount = 1,
        colorAttachmentCount = 1,
        pColorAttachments = &color_attachment,
        pDepthAttachment = state.world_pass != nil ? &depth_attachment : nil,
    }
    sdl.GetWindowSize(state.window, &state.width, &state.height)
    sdl.GetWindowSizeInPixels(state.window, &state.framebuffer_width, &state.framebuffer_height)
    world_context := World_Pass_Context {
        ctx                = ctx,
        frame              = frame,
        color_view         = color_attachment.imageView,
        color_format       = world_color_format,
        depth_view         = depth_attachment.imageView,
        framebuffer_extent = world_extent,
        logical_extent     = {state.width, state.height},
        sample_count       = msaa_active ? (state.world_sample_count_effective == 4 ? vk.SampleCountFlags{._4} : vk.SampleCountFlags{._2}) : vk.SampleCountFlags{._1},
    }
    if detailed_gfx do gfx_profile_end(.Frame_Setup, frame_setup_marker)
    if state.world_pre_pass != nil {
        state.world_pre_pass(&world_context, state.world_pre_pass_user_data)
    }
    vk.CmdBeginRendering(frame.command_buffer, &rendering)
    world_marker := gfx_profile_begin(.World_Pass)
    if state.world_pass != nil {
        state.world_pass(&world_context, state.world_pass_user_data)
    }
    gfx_profile_end(.World_Pass, world_marker)
    vk.CmdEndRendering(frame.command_buffer)
    if world_resolve {
        record_world_mask_pass(ctx, frame, world_extent, {state.width, state.height})
        engine.vk_cmd_image_barrier2(
            ctx,
            frame.command_buffer,
            state.depth.image,
            {.LATE_FRAGMENT_TESTS},
            {.FRAGMENT_SHADER},
            {.DEPTH_STENCIL_ATTACHMENT_WRITE},
            {.SHADER_READ},
            .DEPTH_ATTACHMENT_OPTIMAL,
            .SHADER_READ_ONLY_OPTIMAL,
            {.DEPTH},
        )
        state.depth_sample_ready = true
        composite_marker: u64
        if detailed_gfx do composite_marker = gfx_profile_begin(.World_Composite)
        engine.vk_cmd_image_barrier2(
            ctx,
            frame.command_buffer,
            state.world_scene.image,
            {.COLOR_ATTACHMENT_OUTPUT},
            {.FRAGMENT_SHADER},
            {.COLOR_ATTACHMENT_WRITE},
            {.SHADER_READ},
            .COLOR_ATTACHMENT_OPTIMAL,
            .SHADER_READ_ONLY_OPTIMAL,
        )
        state.world_scene_sample_ready = true
        record_world_post_chain(ctx, frame, world_extent, extent, color_clear)
        if detailed_gfx do gfx_profile_end(.World_Composite, composite_marker)
    }
    engine.vk_cmd_image_barrier2(
        ctx,
        frame.command_buffer,
        image,
        {.COLOR_ATTACHMENT_OUTPUT},
        {.COLOR_ATTACHMENT_OUTPUT},
        {.COLOR_ATTACHMENT_WRITE},
        {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
        .COLOR_ATTACHMENT_OPTIMAL,
        .COLOR_ATTACHMENT_OPTIMAL,
    )
    if hdr_active {
        hdr_attachment := vk.RenderingAttachmentInfo {
            sType       = .RENDERING_ATTACHMENT_INFO,
            imageView   = state.hdr_scene.view,
            imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
            loadOp      = .LOAD,
            storeOp     = .STORE,
            clearValue  = color_clear,
        }
        hdr_rendering := vk.RenderingInfo {
            sType = .RENDERING_INFO,
            renderArea = {extent = extent},
            layerCount = 1,
            colorAttachmentCount = 1,
            pColorAttachments = &hdr_attachment,
        }
        vk.CmdBeginRendering(frame.command_buffer, &hdr_rendering)
    } else { engine.vk_cmd_begin_swapchain_render_pass_load(ctx, frame) }
    ui_marker := gfx_profile_begin(.UI_Pass)
    engine.gpu_profiler_begin_pass(ctx, frame.command_buffer, frame, .Ui_Overlay)
    if detailed_gfx do engine.vk_cmd_label_begin(ctx, frame.command_buffer, "UI Geometry")
    if len(state.vertices) > 0 {vb := &state.vertex[frame.frame_index]; ib := &state.index[frame.frame_index]
        upload_marker: u64
        if detailed_gfx do upload_marker = gfx_profile_begin(.UI_Buffer_Upload)
        mem.copy_non_overlapping(vb.mapped, raw_data(state.vertices[:]), len(state.vertices) * size_of(Vertex))
        mem.copy_non_overlapping(ib.mapped, raw_data(state.indices[:]), len(state.indices) * size_of(u32))
        if detailed_gfx do gfx_profile_end(.UI_Buffer_Upload, upload_marker)
        setup_marker: u64
        if detailed_gfx do setup_marker = gfx_profile_begin(.UI_Command_Setup)
        viewport := vk.Viewport {
            width    = f32(extent.width),
            height   = f32(extent.height),
            minDepth = 0,
            maxDepth = 1,
        }
        scissor := vk.Rect2D {
            extent = extent,
        }
        vk.CmdSetViewport(frame.command_buffer, 0, 1, &viewport)
        vk.CmdSetScissor(frame.command_buffer, 0, 1, &scissor)
        vk.CmdBindPipeline(frame.command_buffer, .GRAPHICS, hdr_active ? state.hdr_pipeline : state.pipeline)
        offset := vk.DeviceSize(0)
        vk.CmdBindVertexBuffers(frame.command_buffer, 0, 1, &vb.handle, &offset)
        vk.CmdBindIndexBuffer(frame.command_buffer, ib.handle, 0, .UINT32)
        sdl.GetWindowSize(state.window, &state.width, &state.height)
        sdl.GetWindowSizeInPixels(state.window, &state.framebuffer_width, &state.framebuffer_height)
        vk.CmdBindDescriptorSets(
            frame.command_buffer,
            .GRAPHICS,
            state.ui_pipeline_layout,
            0,
            1,
            &state.texture_descriptors[0],
            0,
            nil,
        )
        if detailed_gfx do gfx_profile_end(.UI_Command_Setup, setup_marker)
        for &batch in state.batches {
            batch_marker := Gfx_Profile_Marker.UI_Ordinary_Draw
            batch_label: cstring = "UI Draw"
            batch_signpost: u64
            if detailed_gfx {
                batch_signpost = gfx_profile_begin(batch_marker)
                engine.vk_cmd_label_begin(ctx, frame.command_buffer, batch_label)
            }
            batch_scissor := batch_scissor_rect(batch, extent)
            vk.CmdSetScissor(frame.command_buffer, 0, 1, &batch_scissor)
            if batch.texture >= 0 do vk.CmdBindDescriptorSets(frame.command_buffer, .GRAPHICS, state.ui_pipeline_layout, 0, 1, &state.texture_descriptors[batch.texture], 0, nil)
            push := batch_push_constants(&batch)
            vk.CmdPushConstants(
                frame.command_buffer,
                state.ui_pipeline_layout,
                {.VERTEX, .FRAGMENT},
                0,
                u32(size_of(push)),
                &push,
            )
            vk.CmdDrawIndexed(frame.command_buffer, batch.count, 1, batch.first, 0, 0)
            render2d.metrics_record_draw(&state.metrics)
            if detailed_gfx {
                engine.vk_cmd_label_end(ctx, frame.command_buffer)
                gfx_profile_end(batch_marker, batch_signpost)
            }
        }}
    if detailed_gfx do engine.vk_cmd_label_end(ctx, frame.command_buffer)
    if state.ui_pass != nil {
        ui_context := Ui_Pass_Context {
            ctx                = ctx,
            frame              = frame,
            color_view         = hdr_active ? state.hdr_scene.view : ctx.swapchain_image_views[frame.image_index],
            color_format       = hdr_active ? vk.Format.R16G16B16A16_SFLOAT : ctx.swapchain_format,
            framebuffer_extent = extent,
            logical_extent     = {state.width, state.height},
        }
        state.ui_pass(&ui_context, state.ui_pass_user_data)
    }
    engine.gpu_profiler_end_pass(ctx, frame.command_buffer, frame, .Ui_Overlay)
    engine.vk_cmd_end_swapchain_render_pass(frame)
    gfx_profile_end(.UI_Pass, ui_marker)
    if hdr_active do resolve_hdr_scene(ctx, frame, extent)
    do_capture, capture_marker := record_screenshot_readback(ctx, frame, image, extent)
    present_marker := gfx_profile_begin(.Submit_And_Present)
    ended := engine.vk_end_frame(ctx, frame)
    gfx_profile_end(.Submit_And_Present, present_marker)
    publish_screenshot_readback(ctx, extent, do_capture, ended, capture_marker)
}
