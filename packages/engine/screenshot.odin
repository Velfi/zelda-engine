package engine

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:hash"
import "core:image"
import qoi "core:image/qoi"
import "core:sync"
import vk "vendor:vulkan"

MAX_SCREENSHOT_BYTES :: 256 * 1024 * 1024

Screenshot_State :: struct {
    mutex:              sync.Mutex,
    rgba:               []u8,
    width:              u32,
    height:             u32,
    format:             vk.Format,
    sequence:           u64,
    last_capture_frame: u64,
    capture_requested:  bool,
    ready:              bool,
}

screenshot_state_destroy :: proc(state: ^Screenshot_State) {
    sync.mutex_lock(&state.mutex)
    if state.rgba != nil {
        delete(state.rgba)
    }
    state.rgba = nil
    state.ready = false
    state.capture_requested = false
    sync.mutex_unlock(&state.mutex)
}

screenshot_state_request_capture :: proc(state: ^Screenshot_State) {
    sync.mutex_lock(&state.mutex)
    state.capture_requested = true
    sync.mutex_unlock(&state.mutex)
}

screenshot_state_should_capture :: proc(state: ^Screenshot_State, frame_index, refresh_interval_frames: u64) -> bool {
    sync.mutex_lock(&state.mutex)
    defer sync.mutex_unlock(&state.mutex)

    if !state.ready || state.capture_requested {
        return true
    }
    if refresh_interval_frames > 0 && frame_index >= state.last_capture_frame + refresh_interval_frames {
        return true
    }
    return false
}

screenshot_state_publish_from_gpu_rgba :: proc(
    state: ^Screenshot_State,
    pixels: []u8,
    width, height: u32,
    format: vk.Format,
    frame_index: u64,
) -> bool {
    if width == 0 || height == 0 {
        return false
    }

    pixel_count := int(width * height)
    if len(pixels) < pixel_count * 4 {
        return false
    }

    needed := pixel_count * 4
    if needed > MAX_SCREENSHOT_BYTES {
        return false
    }

    sync.mutex_lock(&state.mutex)
    defer sync.mutex_unlock(&state.mutex)

    if len(state.rgba) != needed {
        if state.rgba != nil {
            delete(state.rgba)
        }
        state.rgba = make([]u8, needed)
    }

    copy(state.rgba, pixels[:needed])
    state.width = width
    state.height = height
    state.format = format
    state.sequence += 1
    state.last_capture_frame = frame_index
    state.capture_requested = false
    state.ready = true
    return true
}

screenshot_state_copy_qoi :: proc(
    state: ^Screenshot_State,
    allocator := context.allocator,
) -> (
    data: []u8,
    width, height: u32,
    sequence: u64,
    ok: bool,
) {
    return screenshot_state_copy_qoi_sized(state, 0, 0, 1, allocator)
}

screenshot_state_copy_qoi_sized :: proc(
    state: ^Screenshot_State,
    max_width, max_height: u32,
    scale: f32,
    allocator := context.allocator,
) -> (
    data: []u8,
    width, height: u32,
    sequence: u64,
    ok: bool,
) {
    return screenshot_state_copy_qoi_resized(state, max_width, max_height, scale, 0, 0, allocator)
}

screenshot_state_copy_qoi_resized :: proc(
    state: ^Screenshot_State,
    max_width, max_height: u32,
    scale: f32,
    output_width, output_height: u32,
    allocator := context.allocator,
) -> (
    data: []u8,
    width, height: u32,
    sequence: u64,
    ok: bool,
) {
    return screenshot_state_copy_encoded_resized(
        state,
        max_width,
        max_height,
        scale,
        output_width,
        output_height,
        .QOI,
        allocator,
    )
}

screenshot_state_copy_png :: proc(
    state: ^Screenshot_State,
    allocator := context.allocator,
) -> (
    data: []u8,
    width, height: u32,
    sequence: u64,
    ok: bool,
) {
    return screenshot_state_copy_png_sized(state, 0, 0, 1, allocator)
}

screenshot_state_copy_png_sized :: proc(
    state: ^Screenshot_State,
    max_width, max_height: u32,
    scale: f32,
    allocator := context.allocator,
) -> (
    data: []u8,
    width, height: u32,
    sequence: u64,
    ok: bool,
) {
    return screenshot_state_copy_png_resized(state, max_width, max_height, scale, 0, 0, allocator)
}

screenshot_state_copy_png_resized :: proc(
    state: ^Screenshot_State,
    max_width, max_height: u32,
    scale: f32,
    output_width, output_height: u32,
    allocator := context.allocator,
) -> (
    data: []u8,
    width, height: u32,
    sequence: u64,
    ok: bool,
) {
    return screenshot_state_copy_encoded_resized(
        state,
        max_width,
        max_height,
        scale,
        output_width,
        output_height,
        .PNG,
        allocator,
    )
}

Screenshot_Encoding :: enum {
    QOI,
    PNG,
}

screenshot_state_copy_encoded_resized :: proc(
    state: ^Screenshot_State,
    max_width, max_height: u32,
    scale: f32,
    output_width, output_height: u32,
    encoding: Screenshot_Encoding,
    allocator := context.allocator,
) -> (
    data: []u8,
    width, height: u32,
    sequence: u64,
    ok: bool,
) {
    sync.mutex_lock(&state.mutex)
    defer sync.mutex_unlock(&state.mutex)
    if !state.ready || len(state.rgba) == 0 {
        return
    }

    source_width := state.width
    source_height := state.height
    source_pixel_count := int(source_width * source_height)
    if len(state.rgba) < source_pixel_count * 4 {
        return
    }

    target_width, target_height := screenshot_scaled_dimensions(
        source_width,
        source_height,
        max_width,
        max_height,
        scale,
        output_width,
        output_height,
    )

    pixel_count := int(target_width * target_height)
    alloc_err: runtime.Allocator_Error
    rgb: []image.RGB_Pixel
    rgb, alloc_err = make([]image.RGB_Pixel, pixel_count, allocator)
    if alloc_err != nil {
        return
    }
    defer delete(rgb, allocator)

    for y in 0 ..< target_height {
        source_y := min((u64(y) * u64(source_height)) / u64(target_height), u64(source_height - 1))
        for x in 0 ..< target_width {
            source_x := min((u64(x) * u64(source_width)) / u64(target_width), u64(source_width - 1))
            src_i := int((source_y * u64(source_width) + source_x) * 4)
            dst_i := int(u64(y) * u64(target_width) + u64(x))
            #partial switch state.format {
            case .B8G8R8A8_UNORM, .B8G8R8A8_SRGB:
                rgb[dst_i] = {state.rgba[src_i + 2], state.rgba[src_i + 1], state.rgba[src_i + 0]}
            case:
                rgb[dst_i] = {state.rgba[src_i + 0], state.rgba[src_i + 1], state.rgba[src_i + 2]}
            }
        }
    }

    img, image_ok := image.pixels_to_image(rgb, int(target_width), int(target_height))
    if !image_ok {
        return
    }

    out: bytes.Buffer
    defer bytes.buffer_destroy(&out)
    switch encoding {
    case .QOI:
        if qoi.save_to_buffer(&out, &img, allocator = allocator) != nil {
            return
        }
    case .PNG:
        if !screenshot_encode_png(&out, rgb, target_width, target_height, allocator) {
            return
        }
    }
    if len(out.buf) > MAX_SCREENSHOT_BYTES {
        return
    }

    data, alloc_err = make([]u8, len(out.buf), allocator)
    if alloc_err != nil {
        return
    }
    copy(data, out.buf[:])
    width = target_width
    height = target_height
    sequence = state.sequence
    ok = true
    return
}

screenshot_png_write_u32_be :: proc(out: ^bytes.Buffer, value: u32) -> bool {
    data := [4]u8{u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value)}
    n, err := bytes.buffer_write(out, data[:])
    return err == nil && n == len(data)
}

screenshot_png_write_chunk :: proc(out: ^bytes.Buffer, chunk_type: string, data: []u8) -> bool {
    if len(chunk_type) != 4 || !screenshot_png_write_u32_be(out, u32(len(data))) {
        return false
    }
    crc_start := len(out.buf)
    if n, err := bytes.buffer_write_string(out, chunk_type); err != nil || n != len(chunk_type) {
        return false
    }
    if n, err := bytes.buffer_write(out, data); err != nil || n != len(data) {
        return false
    }
    return screenshot_png_write_u32_be(out, hash.crc32(out.buf[crc_start:]))
}

screenshot_encode_png :: proc(
    out: ^bytes.Buffer,
    rgb: []image.RGB_Pixel,
    width, height: u32,
    allocator := context.allocator,
) -> bool {
    row_bytes := int(width) * 3
    raw_size := int(height) * (row_bytes + 1)
    raw, raw_err := make([]u8, raw_size, allocator)
    if raw_err != nil {
        return false
    }
    defer delete(raw, allocator)
    for y in 0 ..< int(height) {
        row_start := y * (row_bytes + 1)
        raw[row_start] = 0
        for x in 0 ..< int(width) {
            pixel := rgb[y * int(width) + x]
            dst := row_start + 1 + x * 3
            raw[dst + 0] = pixel.r
            raw[dst + 1] = pixel.g
            raw[dst + 2] = pixel.b
        }
    }

    zlib_capacity := 2 + raw_size + ((raw_size + 65534) / 65535) * 5 + 4
    zlib: bytes.Buffer
    bytes.buffer_init_allocator(&zlib, 0, zlib_capacity, allocator)
    defer bytes.buffer_destroy(&zlib)
    _, _ = bytes.buffer_write(&zlib, []u8{0x78, 0x01})
    remaining := raw
    for len(remaining) > 0 {
        block_size := min(len(remaining), 65535)
        final := block_size == len(remaining)
        length := u16(block_size)
        header := [5]u8{final ? 1 : 0, u8(length), u8(length >> 8), u8(~length), u8((~length) >> 8)}
        _, _ = bytes.buffer_write(&zlib, header[:])
        _, _ = bytes.buffer_write(&zlib, remaining[:block_size])
        remaining = remaining[block_size:]
    }
    if len(raw) == 0 {
        _, _ = bytes.buffer_write(&zlib, []u8{1, 0, 0, 0xff, 0xff})
    }
    if !screenshot_png_write_u32_be(&zlib, hash.adler32(raw)) {
        return false
    }

    if n, err := bytes.buffer_write(out, []u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}); err != nil || n != 8 {
        return false
    }
    ihdr := [13]u8 {
        u8(width >> 24),
        u8(width >> 16),
        u8(width >> 8),
        u8(width),
        u8(height >> 24),
        u8(height >> 16),
        u8(height >> 8),
        u8(height),
        8,
        2,
        0,
        0,
        0,
    }
    srgb_rendering_intent := [1]u8{0}
    return(
        screenshot_png_write_chunk(out, "IHDR", ihdr[:]) &&
        screenshot_png_write_chunk(out, "sRGB", srgb_rendering_intent[:]) &&
        screenshot_png_write_chunk(out, "IDAT", zlib.buf[:]) &&
        screenshot_png_write_chunk(out, "IEND", nil) \
    )
}

screenshot_scaled_dimensions :: proc(
    source_width, source_height, max_width, max_height: u32,
    scale: f32,
    output_width := u32(0),
    output_height := u32(0),
) -> (
    target_width, target_height: u32,
) {
    if output_width > 0 && output_height > 0 {
        return output_width, output_height
    }
    if output_width > 0 {
        ratio := f32(output_width) / f32(max(source_width, 1))
        return output_width, u32(max(f32(source_height) * ratio, 1))
    }
    if output_height > 0 {
        ratio := f32(output_height) / f32(max(source_height, 1))
        return u32(max(f32(source_width) * ratio, 1)), output_height
    }

    output_scale := scale
    if output_scale <= 0 {
        output_scale = 1
    }
    target_width = u32(max(f32(source_width) * output_scale, 1))
    target_height = u32(max(f32(source_height) * output_scale, 1))
    if max_width > 0 && target_width > max_width {
        ratio := f32(max_width) / f32(target_width)
        target_width = max_width
        target_height = u32(max(f32(target_height) * ratio, 1))
    }
    if max_height > 0 && target_height > max_height {
        ratio := f32(max_height) / f32(target_height)
        target_height = max_height
        target_width = u32(max(f32(target_width) * ratio, 1))
    }
    target_width = min(max(target_width, 1), source_width)
    target_height = min(max(target_height, 1), source_height)
    return
}
