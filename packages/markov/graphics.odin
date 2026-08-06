#+vet !cast
package markov

import "core:fmt"
import "core:hash"
import "core:image"
import "core:image/png"
import "core:mem"

BACKGROUND :: transmute(i32)u32(0xff222222)

// Load a PNG image, returns (pixels, width, height, depth=1)
// Pixels are BGRA format as i32
load_bitmap :: proc(filename: string, allocator := context.allocator) -> ([]i32, [3]int, bool) {
    data, ok := read_markov_file(filename, context.temp_allocator)
    if !ok {
        return nil, {}, false
    }
    defer delete(data, context.temp_allocator)

    img, load_err := png.load_from_bytes(data, image.Options{.alpha_add_if_missing}, allocator)
    if load_err != nil || img == nil {
        return nil, {}, false
    }
    defer png.destroy(img)

    if img.width <= 0 || img.height <= 0 || img.channels != 4 || img.depth != 8 {
        return nil, {}, false
    }

    width := img.width
    height := img.height
    size := width * height
    result := make([]i32, size, allocator)
    pixels := img.pixels.buf[:]
    if len(pixels) != size * 4 {
        return nil, {}, false
    }

    for y in 0 ..< height {
        src_row := y * width * 4
        dst_row := y * width
        for x in 0 ..< width {
            src := src_row + x * 4
            r := i32(pixels[src + 0])
            g := i32(pixels[src + 1])
            b := i32(pixels[src + 2])
            a := i32(pixels[src + 3])
            result[dst_row + x] = (a << 24) | (r << 16) | (g << 8) | b
        }
    }

    return result, {width, height, 1}, true
}

// Save a PNG image from BGRA i32 pixel data
save_bitmap :: proc(data: []i32, m: [2]int, filename: string) -> bool {
    if m.x <= 0 || m.y <= 0 || len(data) != m.x * m.y {
        fmt.eprintln("ERROR: wrong image dimensions", m.x, "x", m.y)
        return false
    }

    scanlines := make([dynamic]u8, context.temp_allocator)
    for y in 0 ..< m.y {
        append(&scanlines, 0)
        for x in 0 ..< m.x {
            c := cast(u32)data[x + y * m.x]
            append(&scanlines, u8((c >> 16) & 0xff))
            append(&scanlines, u8((c >> 8) & 0xff))
            append(&scanlines, u8(c & 0xff))
            append(&scanlines, u8((c >> 24) & 0xff))
        }
    }

    compressed := png_store_compress(scanlines[:])
    defer delete(compressed)

    output := make([dynamic]u8, context.temp_allocator)
    write_png_signature(&output)

    header: [13]u8
    png_write_u32_be(header[:], 0, u32(m.x))
    png_write_u32_be(header[:], 4, u32(m.y))
    header[8] = 8
    header[9] = 6
    png_write_chunk(&output, "IHDR", header[:])
    png_write_chunk(&output, "IDAT", compressed[:])
    png_write_chunk(&output, "IEND", nil)

    return write_markov_file(filename, output[:])
}

png_write_u32_be :: proc(data: []u8, offset: int, value: u32) {
    data[offset + 0] = u8(value >> 24)
    data[offset + 1] = u8(value >> 16)
    data[offset + 2] = u8(value >> 8)
    data[offset + 3] = u8(value)
}

png_write_u32_be_dynamic :: proc(data: ^[dynamic]u8, value: u32) {
    append(data, u8(value >> 24))
    append(data, u8(value >> 16))
    append(data, u8(value >> 8))
    append(data, u8(value))
}

png_write_u16_le :: proc(data: ^[dynamic]u8, value: u16) {
    append(data, u8(value))
    append(data, u8(value >> 8))
}

png_write_chunk :: proc(output: ^[dynamic]u8, kind: string, data: []u8) {
    png_write_u32_be_dynamic(output, u32(len(data)))
    for c in transmute([]u8)kind {
        append(output, c)
    }
    for c in data {
        append(output, c)
    }

    crc := hash.crc32(transmute([]u8)kind)
    crc = hash.crc32(data, crc)
    png_write_u32_be_dynamic(output, crc)
}

write_png_signature :: proc(output: ^[dynamic]u8) {
    append(output, u8(0x89))
    append(output, 'P')
    append(output, 'N')
    append(output, 'G')
    append(output, '\r')
    append(output, '\n')
    append(output, u8(0x1a))
    append(output, '\n')
}

png_store_compress :: proc(data: []u8) -> [dynamic]u8 {
    output := make([dynamic]u8, context.temp_allocator)
    append(&output, 0x78)
    append(&output, 0x01)

    offset := 0
    for offset < len(data) {
        size := min(len(data) - offset, 65535)
        final := offset + size == len(data)
        append(&output, 1 if final else 0)
        png_write_u16_le(&output, u16(size))
        png_write_u16_le(&output, ~u16(size))
        for c in data[offset:offset + size] {
            append(&output, c)
        }
        offset += size
    }

    adler := png_adler32(data)
    png_write_u32_be_dynamic(&output, adler)
    return output
}

png_adler32 :: proc(data: []u8) -> u32 {
    a: u32 = 1
    b: u32
    for c in data {
        a = (a + u32(c)) % 65521
        b = (b + a) % 65521
    }
    return b << 16 | a
}

// Load a MagicaVoxel .vox file
load_vox :: proc(filename: string, allocator := context.allocator) -> ([]i32, [3]int, bool) {
    data, ok := read_markov_file(filename, context.temp_allocator)
    if !ok {
        return nil, {}, false
    }

    if len(data) < 8 {
        return nil, {}, false
    }

    // Check magic
    if string(data[0:4]) != "VOX " {
        return nil, {}, false
    }

    m: [3]int = {-1, -1, -1}
    result: []i32

    pos := 8 // Skip magic and version
    for pos < len(data) {
        if pos + 4 > len(data) {
            break
        }

        chunk_id := string(data[pos:pos + 4])
        pos += 4

        if chunk_id == "SIZE" {
            if pos + 8 > len(data) {
                break
            }
            pos += 8 // Skip chunk size and children size

            if pos + 12 > len(data) {
                break
            }
            m.x = int((cast(^i32)&data[pos])^)
            m.y = int((cast(^i32)&data[pos + 4])^)
            m.z = int((cast(^i32)&data[pos + 8])^)
            pos += 12
        } else if chunk_id == "XYZI" {
            if m.x <= 0 || m.y <= 0 || m.z <= 0 {
                return nil, m, false
            }

            result = make([]i32, m.x * m.y * m.z, allocator)
            for i in 0 ..< len(result) {
                result[i] = -1
            }

            pos += 8 // Skip chunk sizes

            if pos + 4 > len(data) {
                break
            }
            num_voxels := int((cast(^i32)&data[pos])^)
            pos += 4

            for _ in 0 ..< num_voxels {
                if pos + 4 > len(data) {
                    break
                }
                x := int(data[pos])
                y := int(data[pos + 1])
                z := int(data[pos + 2])
                color := i32(data[pos + 3])
                result[x + y * m.x + z * m.x * m.y] = color
                pos += 4
            }
        } else {
            // Skip unknown chunk
            if pos + 4 > len(data) {
                break
            }
            chunk_size := int((cast(^i32)&data[pos])^)
            pos += 8 + chunk_size
        }
    }

    if result == nil {
        return nil, m, false
    }
    return result, m, true
}

// Save a MagicaVoxel .vox file
save_vox :: proc(state: []u8, m: [3]int, palette: []i32, filename: string) -> bool {
    // Collect non-zero voxels
    Voxel :: struct {
        x, y, z, color: u8,
    }
    voxels := make([dynamic]Voxel, context.temp_allocator)

    for z in 0 ..< m.z {
        for y in 0 ..< m.y {
            for x in 0 ..< m.x {
                i := x + y * m.x + z * m.x * m.y
                v := state[i]
                if v != 0 {
                    append(&voxels, Voxel{u8(x), u8(y), u8(z), u8(v + 1)})
                }
            }
        }
    }

    // Build the file
    buf := make([dynamic]u8, context.temp_allocator)

    write_string :: proc(buf: ^[dynamic]u8, s: string) {
        for c in s {
            append(buf, u8(c))
        }
    }

    write_i32 :: proc(buf: ^[dynamic]u8, v: i32) {
        append(buf, u8(v & 0xff))
        append(buf, u8((v >> 8) & 0xff))
        append(buf, u8((v >> 16) & 0xff))
        append(buf, u8((v >> 24) & 0xff))
    }

    write_u8 :: proc(buf: ^[dynamic]u8, v: u8) {
        append(buf, v)
    }

    // Header
    write_string(&buf, "VOX ")
    write_i32(&buf, 150)

    // MAIN chunk
    write_string(&buf, "MAIN")
    write_i32(&buf, 0)
    write_i32(&buf, i32(1092 + len(voxels) * 4))

    // PACK chunk
    write_string(&buf, "PACK")
    write_i32(&buf, 4)
    write_i32(&buf, 0)
    write_i32(&buf, 1)

    // SIZE chunk
    write_string(&buf, "SIZE")
    write_i32(&buf, 12)
    write_i32(&buf, 0)
    write_i32(&buf, i32(m.x))
    write_i32(&buf, i32(m.y))
    write_i32(&buf, i32(m.z))

    // XYZI chunk
    write_string(&buf, "XYZI")
    write_i32(&buf, i32(4 + len(voxels) * 4))
    write_i32(&buf, 0)
    write_i32(&buf, i32(len(voxels)))

    for vox in voxels {
        write_u8(&buf, vox.x)
        write_u8(&buf, vox.y)
        write_u8(&buf, vox.z)
        write_u8(&buf, vox.color)
    }

    // RGBA chunk (palette)
    write_string(&buf, "RGBA")
    write_i32(&buf, 1024)
    write_i32(&buf, 0)

    for c in palette {
        write_u8(&buf, u8((c >> 16) & 0xff)) // R
        write_u8(&buf, u8((c >> 8) & 0xff)) // G
        write_u8(&buf, u8(c & 0xff)) // B
        write_u8(&buf, 0)
    }
    for i in len(palette) ..< 255 {
        gray := u8(0xff - i - 1)
        write_u8(&buf, gray)
        write_u8(&buf, gray)
        write_u8(&buf, gray)
        write_u8(&buf, 0xff)
    }
    write_i32(&buf, 0)

    return write_markov_file(filename, buf[:])
}

// Get ordinals from color data - maps colors to sequential indices
ords :: proc(data: []i32, allocator := context.allocator) -> ([]u8, int) {
    color_map := make(map[i32]u8, 256, context.temp_allocator)
    result := make([]u8, len(data), allocator)
    count: u8 = 0

    for i in 0 ..< len(data) {
        c := data[i]
        if c in color_map {
            result[i] = color_map[c]
        } else {
            color_map[c] = count
            result[i] = count
            count += 1
        }
    }

    return result, int(count)
}

// Render state to bitmap (2D or isometric 3D)
render :: proc(
    state: []u8,
    m: [3]int,
    colors: []i32,
    pixelsize: int,
    margin: int,
    allocator := context.allocator,
) -> (
    []i32,
    [2]int,
) {
    if m.z == 1 {
        return bitmap_render(state, m, colors, pixelsize, margin, allocator)
    } else {
        return isometric_render(state, m, colors, pixelsize, margin, allocator)
    }
}

// 2D bitmap render
bitmap_render :: proc(
    state: []u8,
    m: [3]int,
    colors: []i32,
    pixelsize: int,
    margin: int,
    allocator := context.allocator,
) -> (
    []i32,
    [2]int,
) {
    width := margin + m.x * pixelsize
    height := m.y * pixelsize

    bitmap := make([]i32, width * height, allocator)
    for i in 0 ..< len(bitmap) {
        bitmap[i] = BACKGROUND
    }

    dx := 0
    dy := 0

    for y in 0 ..< m.y {
        for x in 0 ..< m.x {
            c := colors[state[x + y * m.x]]
            for py in 0 ..< pixelsize {
                for px in 0 ..< pixelsize {
                    sx := dx + x * pixelsize + px
                    sy := dy + y * pixelsize + py
                    if sx >= 0 && sx < width - margin && sy >= 0 && sy < height {
                        bitmap[margin + sx + sy * width] = c
                    }
                }
            }
        }
    }

    return bitmap, {width, height}
}

// Isometric voxel for rendering
Render_Voxel :: struct {
    color: i32,
    pos:   [3]int,
    edges: [8]bool,
}

// Sprite for isometric rendering (cached per block size)
Sprite :: struct {
    cube:   []i32,
    edges:  [8][]i32,
    width:  int,
    height: int,
}

sprite_cache: map[int]Sprite

make_sprite :: proc(size: int, allocator := context.allocator) -> Sprite {
    if size in sprite_cache {
        return sprite_cache[size]
    }

    width := 2 * size
    height := 2 * size - 1

    c1 :: 215
    c2 :: 143
    c3 :: 71
    black :: 0
    transparent :: -1

    texture :: proc(width, height, size: int, f: proc(x, y, size: int) -> i32, allocator: mem.Allocator) -> []i32 {
        result := make([]i32, width * height, allocator)
        for j in 0 ..< height {
            for i in 0 ..< width {
                result[i + j * width] = f(i - size + 1, size - j - 1, size)
            }
        }
        return result
    }

    cube_f :: proc(x, y, size: int) -> i32 {
        if 2 * y - x >= 2 * size || 2 * y + x > 2 * size || 2 * y - x < -2 * size || 2 * y + x <= -2 * size {
            return -1 // transparent
        } else if x > 0 && 2 * y < x {
            return c3
        } else if x <= 0 && 2 * y <= -x {
            return c2
        } else {
            return c1
        }
    }

    sprite: Sprite
    sprite.width = width
    sprite.height = height
    sprite.cube = texture(width, height, size, cube_f, allocator)

    sprite.edges[0] = texture(width, height, size, proc(x, y, size: int) -> i32 {
            return x == 1 && y <= 0 ? c1 : -1
        }, allocator)
    sprite.edges[1] = texture(width, height, size, proc(x, y, size: int) -> i32 {
            return x == 0 && y <= 0 ? c1 : -1
        }, allocator)
    sprite.edges[2] = texture(width, height, size, proc(x, y, size: int) -> i32 {
            return x == 1 - size && 2 * y < size && 2 * y >= -size ? 0 : -1
        }, allocator)
    sprite.edges[3] = texture(width, height, size, proc(x, y, size: int) -> i32 {
            return x <= 0 && y == x / 2 + size - 1 ? 0 : -1
        }, allocator)
    sprite.edges[4] = texture(width, height, size, proc(x, y, size: int) -> i32 {
            return x == size && 2 * y < size && 2 * y >= -size ? 0 : -1
        }, allocator)
    sprite.edges[5] = texture(width, height, size, proc(x, y, size: int) -> i32 {
            return x > 0 && y == -(x + 1) / 2 + size ? 0 : -1
        }, allocator)
    sprite.edges[6] = texture(width, height, size, proc(x, y, size: int) -> i32 {
            return x > 0 && y == (x + 1) / 2 - size ? 0 : -1
        }, allocator)
    sprite.edges[7] = texture(width, height, size, proc(x, y, size: int) -> i32 {
            return x <= 0 && y == -x / 2 - size + 1 ? 0 : -1
        }, allocator)

    sprite_cache[size] = sprite
    return sprite
}

// 3D isometric render
isometric_render :: proc(
    state: []u8,
    m: [3]int,
    colors: []i32,
    blocksize: int,
    margin: int,
    allocator := context.allocator,
) -> (
    []i32,
    [2]int,
) {
    mx, my, mz := m.x, m.y, m.z

    // Group voxels by layer
    num_layers := mx + my + mz - 2
    voxels := make([][dynamic]Render_Voxel, num_layers, context.temp_allocator)
    visible_voxels := make([][dynamic]Render_Voxel, num_layers, context.temp_allocator)
    for i in 0 ..< num_layers {
        voxels[i] = make([dynamic]Render_Voxel, context.temp_allocator)
        visible_voxels[i] = make([dynamic]Render_Voxel, context.temp_allocator)
    }

    visible := make([]bool, mx * my * mz, context.temp_allocator)

    for z in 0 ..< mz {
        for y in 0 ..< my {
            for x in 0 ..< mx {
                i := x + y * mx + z * mx * my
                value := state[i]
                visible[i] = value != 0
                if value != 0 {
                    append(&voxels[x + y + z], Render_Voxel{colors[value], {x, y, z}, {}})
                }
            }
        }
    }

    // Determine visible voxels and their edges
    hash := make([][]bool, mx + my - 1, context.temp_allocator)
    for i in 0 ..< len(hash) {
        hash[i] = make([]bool, mx + my + 2 * mz - 3, context.temp_allocator)
    }

    for i := num_layers - 1; i >= 0; i -= 1 {
        for &vox in voxels[i] {
            x, y, z := vox.pos.x, vox.pos.y, vox.pos.z
            u := x - y + my - 1
            v := x + y - 2 * z + 2 * mz - 2

            if !hash[u][v] {
                vis_x := x == 0 || !visible[(x - 1) + y * mx + z * mx * my]
                vis_y := y == 0 || !visible[x + (y - 1) * mx + z * mx * my]
                vis_z := z == 0 || !visible[x + y * mx + (z - 1) * mx * my]

                vox.edges[0] = y == my - 1 || !visible[x + (y + 1) * mx + z * mx * my]
                vox.edges[1] = x == mx - 1 || !visible[x + 1 + y * mx + z * mx * my]
                vox.edges[2] = vis_x || (y != my - 1 && visible[x - 1 + (y + 1) * mx + z * mx * my])
                vox.edges[3] = vis_x || (z != mz - 1 && visible[x - 1 + y * mx + (z + 1) * mx * my])
                vox.edges[4] = vis_y || (x != mx - 1 && visible[x + 1 + (y - 1) * mx + z * mx * my])
                vox.edges[5] = vis_y || (z != mz - 1 && visible[x + (y - 1) * mx + (z + 1) * mx * my])
                vox.edges[6] = vis_z || (x != mx - 1 && visible[x + 1 + y * mx + (z - 1) * mx * my])
                vox.edges[7] = vis_z || (y != my - 1 && visible[x + (y + 1) * mx + (z - 1) * mx * my])

                append(&visible_voxels[i], vox)
                hash[u][v] = true
            }
        }
    }

    // Calculate output dimensions
    fit_width := (mx + my) * blocksize
    fit_height := ((mx + my) / 2 + mz) * blocksize
    width := fit_width + 2 * blocksize
    height := fit_height + 2 * blocksize

    screen := make([]i32, (margin + width) * height, allocator)
    for i in 0 ..< len(screen) {
        screen[i] = BACKGROUND
    }

    sprite := make_sprite(blocksize)

    blit :: proc(screen: []i32, screen_w, margin: int, sprite_data: []i32, sw, sh: int, x, y: int, rgb: [3]u8) {
        for dy in 0 ..< sh {
            for dx in 0 ..< sw {
                grayscale := sprite_data[dx + dy * sw]
                if grayscale < 0 {
                    continue
                }
                r := u8(f32(rgb[0]) * f32(grayscale) / 256.0)
                g := u8(f32(rgb[1]) * f32(grayscale) / 256.0)
                b := u8(f32(rgb[2]) * f32(grayscale) / 256.0)
                X := x + dx
                Y := y + dy
                if margin + X >= 0 && X < screen_w - margin && Y >= 0 && Y < len(screen) / screen_w {
                    screen[margin + X + Y * screen_w] = transmute(i32)(u32(0xff) << 24 |
                        u32(r) << 16 |
                        u32(g) << 8 |
                        u32(b))
                }
            }
        }
    }

    for i in 0 ..< num_layers {
        for &vox in visible_voxels[i] {
            u := blocksize * (vox.pos.x - vox.pos.y)
            v := (blocksize * (vox.pos.x + vox.pos.y) / 2 - blocksize * vox.pos.z)
            posx := width / 2 + u - blocksize
            posy := (height - fit_height) / 2 + (mz - 1) * blocksize + v

            rgb: [3]u8 = {u8((vox.color >> 16) & 0xff), u8((vox.color >> 8) & 0xff), u8(vox.color & 0xff)}

            blit(screen, margin + width, margin, sprite.cube, sprite.width, sprite.height, posx, posy, rgb)
            for j in 0 ..< 8 {
                if vox.edges[j] {
                    blit(screen, margin + width, margin, sprite.edges[j], sprite.width, sprite.height, posx, posy, rgb)
                }
            }
        }
    }

    return screen, {margin + width, height}
}
