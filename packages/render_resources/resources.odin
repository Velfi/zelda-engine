package render_resources

import "core:image"
import _ "core:image/png"
import "core:mem"
import vk "vendor:vulkan"
import engine "zelda_engine:engine"

Image :: struct {
    image:         vk.Image,
    memory:        vk.DeviceMemory,
    view:          vk.ImageView,
    sampler:       vk.Sampler,
    format:        vk.Format,
    width, height: u32,
}

Sampler_Options :: struct {
    address_mode: vk.SamplerAddressMode,
    linear_color: bool,
}

image_destroy :: proc(image: ^Image, ctx: ^engine.Vk_Context) {
    if image.sampler != vk.Sampler(0) do vk.DestroySampler(ctx.device, image.sampler, nil)
    if image.view != vk.ImageView(0) do vk.DestroyImageView(ctx.device, image.view, nil)
    if image.image != vk.Image(0) do vk.DestroyImage(ctx.device, image.image, nil)
    if image.memory != vk.DeviceMemory(0) do vk.FreeMemory(ctx.device, image.memory, nil)
    image^ = {}
}

image_create :: proc(
    ctx: ^engine.Vk_Context,
    width, height: u32,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    aspect: vk.ImageAspectFlags,
    samples: vk.SampleCountFlags,
    out: ^Image,
    allocation_name := "renderer image",
) -> bool {
    out^ = {}
    info := vk.ImageCreateInfo {
        sType         = .IMAGE_CREATE_INFO,
        imageType     = .D2,
        format        = format,
        extent        = {width, height, 1},
        mipLevels     = 1,
        arrayLayers   = 1,
        samples       = samples,
        tiling        = .OPTIMAL,
        usage         = usage,
        sharingMode   = .EXCLUSIVE,
        initialLayout = .UNDEFINED,
    }
    if vk.CreateImage(ctx.device, &info, nil, &out.image) != .SUCCESS do return false
    engine.vk_set_debug_name(ctx, .IMAGE, auto_cast out.image, allocation_name)
    requirements: vk.MemoryRequirements
    vk.GetImageMemoryRequirements(ctx.device, out.image, &requirements)
    memory_type, found := engine.vk_find_memory_type(ctx, requirements.memoryTypeBits, {.DEVICE_LOCAL})
    if !found { image_destroy(out, ctx); return false }
    allocation := vk.MemoryAllocateInfo {
        sType           = .MEMORY_ALLOCATE_INFO,
        allocationSize  = requirements.size,
        memoryTypeIndex = memory_type,
    }
    if !engine.vk_allocate_memory_checked(
        ctx,
        &allocation,
        allocation_name,
        &out.memory,
    ) { image_destroy(out, ctx); return false }
    if vk.BindImageMemory(ctx.device, out.image, out.memory, 0) != .SUCCESS { image_destroy(out, ctx); return false }
    view_info := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = out.image,
        viewType = .D2,
        format = format,
        subresourceRange = {aspectMask = aspect, baseMipLevel = 0, levelCount = 1, baseArrayLayer = 0, layerCount = 1},
    }
    if vk.CreateImageView(ctx.device, &view_info, nil, &out.view) != .SUCCESS { image_destroy(out, ctx); return false }
    engine.vk_set_debug_name(ctx, .IMAGE_VIEW, auto_cast out.view, allocation_name)
    out.format = format
    out.width = width
    out.height = height
    return true
}

image_array_create :: proc(
    ctx: ^engine.Vk_Context,
    width, height, layers: u32,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    aspect: vk.ImageAspectFlags,
    view_type: vk.ImageViewType,
    cube_compatible: bool,
    out: ^Image,
    allocation_name := "renderer image array",
) -> bool {
    out^ = {}
    flags: vk.ImageCreateFlags
    if cube_compatible do flags = {.CUBE_COMPATIBLE}
    info := vk.ImageCreateInfo {
        sType         = .IMAGE_CREATE_INFO,
        flags         = flags,
        imageType     = .D2,
        format        = format,
        extent        = {width, height, 1},
        mipLevels     = 1,
        arrayLayers   = layers,
        samples       = {._1},
        tiling        = .OPTIMAL,
        usage         = usage,
        sharingMode   = .EXCLUSIVE,
        initialLayout = .UNDEFINED,
    }
    if vk.CreateImage(ctx.device, &info, nil, &out.image) != .SUCCESS do return false
    engine.vk_set_debug_name(ctx, .IMAGE, auto_cast out.image, allocation_name)
    requirements: vk.MemoryRequirements; vk.GetImageMemoryRequirements(ctx.device, out.image, &requirements)
    memory_type, found := engine.vk_find_memory_type(
        ctx,
        requirements.memoryTypeBits,
        {.DEVICE_LOCAL},
    ); if !found { image_destroy(out, ctx); return false }
    allocation := vk.MemoryAllocateInfo {
        sType           = .MEMORY_ALLOCATE_INFO,
        allocationSize  = requirements.size,
        memoryTypeIndex = memory_type,
    }
    if !engine.vk_allocate_memory_checked(
        ctx,
        &allocation,
        allocation_name,
        &out.memory,
    ) { image_destroy(out, ctx); return false }
    if vk.BindImageMemory(ctx.device, out.image, out.memory, 0) != .SUCCESS { image_destroy(out, ctx); return false }
    view_info := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = out.image,
        viewType = view_type,
        format = format,
        subresourceRange = {
            aspectMask = aspect,
            baseMipLevel = 0,
            levelCount = 1,
            baseArrayLayer = 0,
            layerCount = layers,
        },
    }
    if vk.CreateImageView(ctx.device, &view_info, nil, &out.view) != .SUCCESS { image_destroy(out, ctx); return false }
    engine.vk_set_debug_name(ctx, .IMAGE_VIEW, auto_cast out.view, allocation_name)
    out.format = format; out.width = width; out.height = height
    return true
}

depth_create :: proc(
    ctx: ^engine.Vk_Context,
    width, height: u32,
    out: ^Image,
    samples: vk.SampleCountFlags = {._1},
) -> bool {
    return image_create(
        ctx,
        width,
        height,
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT},
        {.DEPTH},
        samples,
        out,
        "renderer depth",
    )
}

texture_upload_rgba8 :: proc(
    ctx: ^engine.Vk_Context,
    pixels: []u8,
    width, height: int,
    out: ^Image,
    options := Sampler_Options{address_mode = .REPEAT},
) -> bool {
    if width <= 0 || height <= 0 || len(pixels) < width * height * 4 do return false
    staging: engine.Vk_Buffer
    if !engine.vk_create_host_buffer(ctx, vk.DeviceSize(width * height * 4), {.TRANSFER_SRC}, &staging) do return false
    defer engine.vk_destroy_buffer(ctx, &staging)
    mem.copy_non_overlapping(staging.mapped, raw_data(pixels), width * height * 4)
    format: vk.Format = .R8G8B8A8_SRGB; if options.linear_color do format = .R8G8B8A8_UNORM
    if !image_create(ctx, u32(width), u32(height), format, {.TRANSFER_DST, .SAMPLED}, {.COLOR}, {._1}, out, "renderer texture") do return false
    cmd, ok := engine.vk_begin_upload_commands(ctx)
    if !ok { image_destroy(out, ctx); return false }
    engine.vk_cmd_image_barrier2(
        ctx,
        cmd,
        out.image,
        {.TOP_OF_PIPE},
        {.TRANSFER},
        {},
        {.TRANSFER_WRITE},
        .UNDEFINED,
        .TRANSFER_DST_OPTIMAL,
    )
    region := vk.BufferImageCopy {
        imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
        imageExtent = {u32(width), u32(height), 1},
    }
    vk.CmdCopyBufferToImage(cmd, staging.handle, out.image, .TRANSFER_DST_OPTIMAL, 1, &region)
    engine.vk_cmd_image_barrier2(
        ctx,
        cmd,
        out.image,
        {.TRANSFER},
        {.FRAGMENT_SHADER},
        {.TRANSFER_WRITE},
        {.SHADER_READ},
        .TRANSFER_DST_OPTIMAL,
        .SHADER_READ_ONLY_OPTIMAL,
    )
    if !engine.vk_submit_upload_commands(ctx) { image_destroy(out, ctx); return false }
    // World surfaces are commonly viewed obliquely and at non-integral pixel
    // scales. Nearest filtering made floor, wall, and roof patterns crawl as the
    // camera moved. Keep the existing single-level upload for now, but sample it
    // linearly; UI pixel art has its own upload path and is unaffected.
    sampler_info := vk.SamplerCreateInfo {
        sType        = .SAMPLER_CREATE_INFO,
        magFilter    = .LINEAR,
        minFilter    = .LINEAR,
        mipmapMode   = .LINEAR,
        addressModeU = options.address_mode,
        addressModeV = options.address_mode,
        addressModeW = options.address_mode,
        minLod       = 0,
        maxLod       = 0,
    }
    if vk.CreateSampler(ctx.device, &sampler_info, nil, &out.sampler) !=
       .SUCCESS { image_destroy(out, ctx); return false }
    engine.vk_set_debug_name(ctx, .SAMPLER, auto_cast out.sampler, "renderer texture sampler")
    return true
}

texture_upload_r8 :: proc(
    ctx: ^engine.Vk_Context,
    pixels: []u8,
    width, height: int,
    out: ^Image,
    options := Sampler_Options{address_mode = .CLAMP_TO_EDGE, linear_color = true},
) -> bool {
    if width <= 0 || height <= 0 || len(pixels) < width * height do return false
    staging: engine.Vk_Buffer
    if !engine.vk_create_host_buffer(ctx, vk.DeviceSize(width * height), {.TRANSFER_SRC}, &staging) do return false
    defer engine.vk_destroy_buffer(ctx, &staging)
    mem.copy_non_overlapping(staging.mapped, raw_data(pixels), width * height)
    if !image_create(
        ctx,
        u32(width),
        u32(height),
        .R8_UNORM,
        {.TRANSFER_DST, .SAMPLED},
        {.COLOR},
        {._1},
        out,
        "renderer alpha texture",
    ) {
        return false
    }
    cmd, ok := engine.vk_begin_upload_commands(ctx)
    if !ok { image_destroy(out, ctx); return false }
    engine.vk_cmd_image_barrier2(
        ctx, cmd, out.image, {.TOP_OF_PIPE}, {.TRANSFER}, {}, {.TRANSFER_WRITE},
        .UNDEFINED, .TRANSFER_DST_OPTIMAL,
    )
    region := vk.BufferImageCopy {
        imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
        imageExtent = {u32(width), u32(height), 1},
    }
    vk.CmdCopyBufferToImage(cmd, staging.handle, out.image, .TRANSFER_DST_OPTIMAL, 1, &region)
    engine.vk_cmd_image_barrier2(
        ctx, cmd, out.image, {.TRANSFER}, {.FRAGMENT_SHADER}, {.TRANSFER_WRITE}, {.SHADER_READ},
        .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL,
    )
    if !engine.vk_submit_upload_commands(ctx) { image_destroy(out, ctx); return false }
    sampler_info := vk.SamplerCreateInfo {
        sType = .SAMPLER_CREATE_INFO,
        magFilter = .LINEAR,
        minFilter = .LINEAR,
        mipmapMode = .NEAREST,
        addressModeU = options.address_mode,
        addressModeV = options.address_mode,
        addressModeW = options.address_mode,
        minLod = 0,
        maxLod = 0,
    }
    if vk.CreateSampler(ctx.device, &sampler_info, nil, &out.sampler) != .SUCCESS {
        image_destroy(out, ctx)
        return false
    }
    engine.vk_set_debug_name(ctx, .SAMPLER, auto_cast out.sampler, "renderer alpha texture sampler")
    return true
}

// texture_load_file decodes a supported image and uploads it as an RGBA texture.
// File selection and asset lifetime remain consumer policy; this helper owns only
// the reusable decode-to-GPU transfer step.
texture_load_file :: proc(
    ctx: ^engine.Vk_Context,
    path: string,
    out: ^Image,
    options := Sampler_Options{address_mode = .CLAMP_TO_EDGE},
    allocator := context.temp_allocator,
) -> bool {
    decoded, decode_error := image.load(path, {.alpha_add_if_missing}, allocator)
    if decode_error != nil || decoded == nil do return false
    defer image.destroy(decoded, allocator)
    return texture_upload_rgba8(ctx, decoded.pixels.buf[:], decoded.width, decoded.height, out, options)
}
