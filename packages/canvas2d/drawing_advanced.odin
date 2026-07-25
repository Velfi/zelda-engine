package canvas2d

import "core:image"
import _ "core:image/png"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
import engine "zelda_engine:engine"
import resources "zelda_engine:render_resources"
import ui "zelda_engine:ui"

DrawEllipseRingHatched :: proc(
	center: Vector2,
	outer_radius_x, outer_radius_y, inner_radius_x, inner_radius_y: f32,
	color: Color,
	config := default_hatch,
	segments: int = 64,
	rotation: f32 = 0,
	outer_irregularity: f32 = 0,
	inner_irregularity: f32 = 0,
	phase: f32 = 0,
) {
	invalid :=
		outer_radius_x <= 0 ||
		outer_radius_y <= 0 ||
		inner_radius_x <= 0 ||
		inner_radius_y <= 0 ||
		inner_radius_x >= outer_radius_x ||
		inner_radius_y >= outer_radius_y ||
		segments < 3
	if invalid do return
	cos_rotation, sin_rotation := f32(math.cos(f64(rotation))), f32(math.sin(f64(rotation)))
	for i in 0 ..< segments {
		a := f32(i) * 2 * math.PI / f32(segments)
		b := f32(i + 1) * 2 * math.PI / f32(segments)
		cos_a, sin_a := f32(math.cos(f64(a))), f32(math.sin(f64(a)))
		cos_b, sin_b := f32(math.cos(f64(b))), f32(math.sin(f64(b)))
		outer_warp_a :=
			1 +
			f32(math.sin(f64(a * 3 + phase))) * outer_irregularity +
			f32(math.sin(f64(a * 5 - phase * .7))) * outer_irregularity * .45
		outer_warp_b :=
			1 +
			f32(math.sin(f64(b * 3 + phase))) * outer_irregularity +
			f32(math.sin(f64(b * 5 - phase * .7))) * outer_irregularity * .45
		inner_phase := phase + .9
		inner_warp_a :=
			1 +
			f32(math.sin(f64(a * 3 + inner_phase))) * inner_irregularity +
			f32(math.sin(f64(a * 5 - inner_phase * .7))) * inner_irregularity * .45
		inner_warp_b :=
			1 +
			f32(math.sin(f64(b * 3 + inner_phase))) * inner_irregularity +
			f32(math.sin(f64(b * 5 - inner_phase * .7))) * inner_irregularity * .45
		outer_a := Vector2 {
			outer_radius_x * cos_a * outer_warp_a,
			outer_radius_y * sin_a * outer_warp_a,
		}
		outer_b := Vector2 {
			outer_radius_x * cos_b * outer_warp_b,
			outer_radius_y * sin_b * outer_warp_b,
		}
		inner_a := Vector2 {
			inner_radius_x * cos_a * inner_warp_a,
			inner_radius_y * sin_a * inner_warp_a,
		}
		inner_b := Vector2 {
			inner_radius_x * cos_b * inner_warp_b,
			inner_radius_y * sin_b * inner_warp_b,
		}
		base_fade := clamp(config.edge_softness, f32(0), f32(.45))
		// Rings expose two cut boundaries, so their fade is carried by mesh alpha
		// rather than the filled-shape radial shader mask. Vary the fade depth along
		// each authored irregular edge to keep annuli from ending in two perfectly
		// even airbrushed bands. Outer and inner wear use different phase families;
		// both remain deterministic and interpolate continuously between segments.
		edge_wear := clamp(max(outer_irregularity, inner_irregularity) * 6, f32(0), f32(1))
		outer_fade_a := clamp(
			base_fade * (1 + f32(math.sin(f64(a * 7 + phase * .83))) * edge_wear * .34),
			f32(0),
			f32(.45),
		)
		outer_fade_b := clamp(
			base_fade * (1 + f32(math.sin(f64(b * 7 + phase * .83))) * edge_wear * .34),
			f32(0),
			f32(.45),
		)
		inner_fade_a := clamp(
			base_fade * (1 + f32(math.sin(f64(a * 5 - phase * 1.17 + 1.3))) * edge_wear * .34),
			f32(0),
			f32(.45),
		)
		inner_fade_b := clamp(
			base_fade * (1 + f32(math.sin(f64(b * 5 - phase * 1.17 + 1.3))) * edge_wear * .34),
			f32(0),
			f32(.45),
		)
		outer_mid_a := Vector2 {
			outer_a.x + (inner_a.x - outer_a.x) * outer_fade_a,
			outer_a.y + (inner_a.y - outer_a.y) * outer_fade_a,
		}
		outer_mid_b := Vector2 {
			outer_b.x + (inner_b.x - outer_b.x) * outer_fade_b,
			outer_b.y + (inner_b.y - outer_b.y) * outer_fade_b,
		}
		inner_mid_a := Vector2 {
			outer_a.x + (inner_a.x - outer_a.x) * (1 - inner_fade_a),
			outer_a.y + (inner_a.y - outer_a.y) * (1 - inner_fade_a),
		}
		inner_mid_b := Vector2 {
			outer_b.x + (inner_b.x - outer_b.x) * (1 - inner_fade_b),
			outer_b.y + (inner_b.y - outer_b.y) * (1 - inner_fade_b),
		}
		p_outer_a := transform(
			{
				center.x + outer_a.x * cos_rotation - outer_a.y * sin_rotation,
				center.y + outer_a.x * sin_rotation + outer_a.y * cos_rotation,
			},
		)
		p_outer_b := transform(
			{
				center.x + outer_b.x * cos_rotation - outer_b.y * sin_rotation,
				center.y + outer_b.x * sin_rotation + outer_b.y * cos_rotation,
			},
		)
		p_outer_mid_a := transform(
			{
				center.x + outer_mid_a.x * cos_rotation - outer_mid_a.y * sin_rotation,
				center.y + outer_mid_a.x * sin_rotation + outer_mid_a.y * cos_rotation,
			},
		)
		p_outer_mid_b := transform(
			{
				center.x + outer_mid_b.x * cos_rotation - outer_mid_b.y * sin_rotation,
				center.y + outer_mid_b.x * sin_rotation + outer_mid_b.y * cos_rotation,
			},
		)
		p_inner_mid_a := transform(
			{
				center.x + inner_mid_a.x * cos_rotation - inner_mid_a.y * sin_rotation,
				center.y + inner_mid_a.x * sin_rotation + inner_mid_a.y * cos_rotation,
			},
		)
		p_inner_mid_b := transform(
			{
				center.x + inner_mid_b.x * cos_rotation - inner_mid_b.y * sin_rotation,
				center.y + inner_mid_b.x * sin_rotation + inner_mid_b.y * cos_rotation,
			},
		)
		p_inner_a := transform(
			{
				center.x + inner_a.x * cos_rotation - inner_a.y * sin_rotation,
				center.y + inner_a.x * sin_rotation + inner_a.y * cos_rotation,
			},
		)
		p_inner_b := transform(
			{
				center.x + inner_b.x * cos_rotation - inner_b.y * sin_rotation,
				center.y + inner_b.x * sin_rotation + inner_b.y * cos_rotation,
			},
		)
		inner_u := inner_radius_x / outer_radius_x * .5
		inner_v := inner_radius_y / outer_radius_y * .5
		outer_uv_a := Vector2{.5 + cos_a * .5, .5 + sin_a * .5}
		outer_uv_b := Vector2{.5 + cos_b * .5, .5 + sin_b * .5}
		inner_uv_a := Vector2{.5 + cos_a * inner_u, .5 + sin_a * inner_v}
		inner_uv_b := Vector2{.5 + cos_b * inner_u, .5 + sin_b * inner_v}
		outer_mid_uv_a := Vector2 {
			outer_uv_a.x + (inner_uv_a.x - outer_uv_a.x) * outer_fade_a,
			outer_uv_a.y + (inner_uv_a.y - outer_uv_a.y) * outer_fade_a,
		}
		outer_mid_uv_b := Vector2 {
			outer_uv_b.x + (inner_uv_b.x - outer_uv_b.x) * outer_fade_b,
			outer_uv_b.y + (inner_uv_b.y - outer_uv_b.y) * outer_fade_b,
		}
		inner_mid_uv_a := Vector2 {
			outer_uv_a.x + (inner_uv_a.x - outer_uv_a.x) * (1 - inner_fade_a),
			outer_uv_a.y + (inner_uv_a.y - outer_uv_a.y) * (1 - inner_fade_a),
		}
		inner_mid_uv_b := Vector2 {
			outer_uv_b.x + (inner_uv_b.x - outer_uv_b.x) * (1 - inner_fade_b),
			outer_uv_b.y + (inner_uv_b.y - outer_uv_b.y) * (1 - inner_fade_b),
		}
		base := u32(len(state.vertices))
		t := to_color(color)
		boundary_t := t
		if base_fade > 0 do boundary_t[3] = 0
		append(
			&state.vertices,
			Vertex{p_outer_a, outer_uv_a, boundary_t},
			Vertex{p_outer_b, outer_uv_b, boundary_t},
			Vertex{p_outer_mid_a, outer_mid_uv_a, t},
			Vertex{p_outer_mid_b, outer_mid_uv_b, t},
			Vertex{p_inner_mid_a, inner_mid_uv_a, t},
			Vertex{p_inner_mid_b, inner_mid_uv_b, t},
			Vertex{p_inner_a, inner_uv_a, boundary_t},
			Vertex{p_inner_b, inner_uv_b, boundary_t},
		)
		first := u32(len(state.indices))
		append(
			&state.indices,
			base,
			base + 1,
			base + 3,
			base,
			base + 3,
			base + 2,
			base + 2,
			base + 3,
			base + 5,
			base + 2,
			base + 5,
			base + 4,
			base + 4,
			base + 5,
			base + 7,
			base + 4,
			base + 7,
			base + 6,
		)
		ring_config := config
		// The annular mesh now supplies distance to both actual boundaries.
		// Disable the filled-shape radial fade, which only understands the outer
		// ellipse and would soften one side of the ring twice.
		ring_config.edge_softness = 0
		append_batch(first, 18, -1, ring_config)
	}
}
CheckCollisionPointRec :: proc(p: Vector2, r: Rectangle) -> bool {return(
		p.x >= r.x &&
		p.x <= r.x + r.width &&
		p.y >= r.y &&
		p.y <= r.y + r.height \
	)}
LoadFontEx :: proc(path: cstring, size: i32, codepoints: [^]rune, count: i32) -> Font {return{
		state.initialized,
	}}
FontAdvanceEm :: proc() -> f32 {return state.font_advance_em}
UnloadFont :: proc(font: Font) {}
font_glyph_slot :: proc(ch: rune) -> int {
	if ch >= FONT_FIRST && ch <= FONT_LAST do return int(ch) - FONT_FIRST
	for fallback, index in FONT_FALLBACK_RUNES do if ch == fallback do return FONT_COUNT + index
	switch ch {case '·':
		return int('|') - FONT_FIRST; case '–', '—', '−':
		return int('-') - FONT_FIRST; case '←', '‹':
		return int('<') - FONT_FIRST; case '→', '›':
		return int('>') - FONT_FIRST; case '‘', '’':
		return int('\'') - FONT_FIRST; case '“', '”':
		return int('"') - FONT_FIRST}
	return int('?') - FONT_FIRST
}
MeasureTextEx :: proc(font: Font, text: cstring, size, spacing: f32) -> Vector2 {count := 0; for _ in string(text) do count += 1
	// Measurement is in logical UI units; atlas oversampling must not alter layout.
	return{f32(count) * (size * FontAdvanceEm() + spacing), max(size, f32(32))}}
DrawTextEx :: proc(
	font: Font,
	text: cstring,
	position: Vector2,
	size, spacing: f32,
	color: Color,
) {
	value := string(text)
	scale := size / f32(FONT_CELL_H)
	cursor := position.x
	for ch in value {
		glyph := font_glyph_slot(ch)
		col := glyph % FONT_COLUMNS
		row := glyph / FONT_COLUMNS
		uv0 := Vector2 {
			f32(col * FONT_CELL_W) / f32(state.texture_width),
			f32(row * FONT_CELL_H) / f32(state.texture_height),
		}
		uv1 := Vector2 {
			f32((col + 1) * FONT_CELL_W) / f32(state.texture_width),
			f32((row + 1) * FONT_CELL_H) / f32(state.texture_height),
		}
		r := Rectangle{cursor, position.y, FONT_CELL_W * scale, FONT_CELL_H * scale}
		a := transform({r.x, r.y})
		b := transform({r.x + r.width, r.y})
		c := transform({r.x + r.width, r.y + r.height})
		d := transform({r.x, r.y + r.height})
		quad(a, b, c, d, color, uv0, uv1, 0)
		cursor += size * FontAdvanceEm() + spacing}}
DrawIcon :: proc(index: int, destination: Rectangle, color := Color{255, 255, 255, 255}) {
	if index < 0 || index >= ICON_COLUMNS * ICON_ROWS || state.icon_width <= 0 do return
	col, row := index % ICON_COLUMNS, index / ICON_COLUMNS
	cell_w, cell_h := f32(state.icon_width) / ICON_COLUMNS, f32(state.icon_height) / ICON_ROWS
	uv0 := Vector2 {
		f32(col) * cell_w / f32(state.texture_width),
		(f32(state.icon_y) + f32(row) * cell_h) / f32(state.texture_height),
	}
	uv1 := Vector2 {
		f32(col + 1) * cell_w / f32(state.texture_width),
		(f32(state.icon_y) + f32(row + 1) * cell_h) / f32(state.texture_height),
	}
	a := transform({destination.x, destination.y})
	b := transform({destination.x + destination.width, destination.y})
	c := transform({destination.x + destination.width, destination.y + destination.height})
	d := transform({destination.x, destination.y + destination.height})
	quad(a, b, c, d, color, uv0, uv1, 0)
}

LoadTexture :: proc(path: string) -> Texture {
	if !state.initialized || state.texture_count >= MAX_TEXTURES do return {}
	id := state.texture_count
	if !resources.texture_load_file(&state.ctx, path, &state.textures[id]) do return {}
	texture := &state.textures[id]
	ii := vk.DescriptorImageInfo {
		imageView   = texture.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	si := vk.DescriptorImageInfo {
		sampler = texture.sampler,
	}
	writes := [2]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = state.descriptors[id],
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &ii,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = state.descriptors[id],
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .SAMPLER,
			pImageInfo = &si,
		},
	}
	vk.UpdateDescriptorSets(state.ctx.device, 2, raw_data(writes[:]), 0, nil)
	state.texture_count += 1
	return {id = id, width = int(texture.width), height = int(texture.height), ready = true}
}

CreateDynamicTextureRGBA :: proc(width, height: int, pixels: []u8) -> Texture {
	if !state.initialized || state.texture_count >= MAX_TEXTURES || width <= 0 || height <= 0 do return {}
	id := state.texture_count
	if !resources.texture_upload_rgba8(&state.ctx, pixels, width, height, &state.textures[id], {address_mode = .CLAMP_TO_EDGE, linear_color = true}) do return {}
	texture := &state.textures[id]
	ii := vk.DescriptorImageInfo {
		imageView   = texture.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	si := vk.DescriptorImageInfo {
		sampler = texture.sampler,
	}
	writes := [2]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = state.descriptors[id],
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &ii,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = state.descriptors[id],
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .SAMPLER,
			pImageInfo = &si,
		},
	}
	vk.UpdateDescriptorSets(state.ctx.device, 2, raw_data(writes[:]), 0, nil)
	byte_count := width * height * 4
	state.dynamic_pixels[id] = make([dynamic]u8, byte_count)
	copy(state.dynamic_pixels[id][:], pixels[:byte_count])
	for frame in 0 ..< engine.MAX_FRAMES_IN_FLIGHT {if !engine.vk_create_host_buffer(&state.ctx, vk.DeviceSize(byte_count), {.TRANSFER_SRC}, &state.dynamic_staging[id][frame]) do return {}}
	state.texture_count += 1
	return {id = id, width = width, height = height, ready = true}
}

UpdateDynamicTextureRGBA :: proc(texture: Texture, pixels: []u8) -> bool {
	if !state.initialized || !texture.ready || texture.id <= 0 || texture.id >= state.texture_count || len(pixels) < texture.width * texture.height * 4 do return false
	byte_count := texture.width * texture.height * 4
	if len(state.dynamic_pixels[texture.id]) != byte_count do return false
	copy(
		state.dynamic_pixels[texture.id][:],
		pixels[:byte_count],
	); state.dynamic_pending[texture.id] = true
	return true
}

DrawTexturePro :: proc(
	texture: Texture,
	source, destination: Rectangle,
	tint := Color{255, 255, 255, 255},
) {
	if !texture.ready || texture.id <= 0 || texture.id >= state.texture_count || texture.width <= 0 || texture.height <= 0 do return
	uv0 := Vector2{source.x / f32(texture.width), source.y / f32(texture.height)}
	uv1 := Vector2 {
		(source.x + source.width) / f32(texture.width),
		(source.y + source.height) / f32(texture.height),
	}
	a := transform({destination.x, destination.y})
	b := transform({destination.x + destination.width, destination.y})
	c := transform({destination.x + destination.width, destination.y + destination.height})
	d := transform({destination.x, destination.y + destination.height})
	quad(a, b, c, d, tint, uv0, uv1, texture.id)
}
DrawTextureProRotated :: proc(
	texture: Texture,
	source, destination: Rectangle,
	rotation: f32,
	tint := Color{255, 255, 255, 255},
) {
	if !texture.ready || texture.id < 0 || texture.id >= state.texture_count do return
	uv0 := Vector2 {
		source.x / f32(texture.width),
		source.y / f32(texture.height),
	}; uv1 := Vector2{(source.x + source.width) / f32(texture.width), (source.y + source.height) / f32(texture.height)}
	cx :=
		destination.x +
		destination.width *
			.5; cy := destination.y + destination.height * .5; hw := destination.width * .5; hh := destination.height * .5; c := f32(math.cos(f64(rotation))); s := f32(math.sin(f64(rotation)))
	rotate_point :: proc(x, y, cx, cy, c, s: f32) -> Vector2 {return{
			cx + x * c - y * s,
			cy + x * s + y * c,
		}}
	a := transform(
		rotate_point(-hw, -hh, cx, cy, c, s),
	); b := transform(rotate_point(hw, -hh, cx, cy, c, s)); cc := transform(rotate_point(hw, hh, cx, cy, c, s)); d := transform(rotate_point(-hw, hh, cx, cy, c, s)); quad(a, b, cc, d, tint, uv0, uv1, texture.id)
}
DrawTextureProHatched :: proc(
	texture: Texture,
	source, destination: Rectangle,
	config := default_hatch,
	tint := Color{255, 255, 255, 255},
) {
	if !texture.ready || texture.id <= 0 || texture.id >= state.texture_count || texture.width <= 0 || texture.height <= 0 do return
	uv0 := Vector2{source.x / f32(texture.width), source.y / f32(texture.height)}
	uv1 := Vector2 {
		(source.x + source.width) / f32(texture.width),
		(source.y + source.height) / f32(texture.height),
	}
	a := transform({destination.x, destination.y})
	b := transform({destination.x + destination.width, destination.y})
	c := transform({destination.x + destination.width, destination.y + destination.height})
	d := transform({destination.x, destination.y + destination.height})
	quad(a, b, c, d, tint, uv0, uv1, texture.id, config)
}
TakeScreenshot :: proc(path: cstring) {
	// Screenshot readback is completed by a later presented frame. Callers often
	// pass a temporary cstring, so retain our own copy until delivery completes.
	if len(state.capture_path) > 0 do delete(state.capture_path)
	state.capture_path = strings.clone_from_cstring(path)
	state.capture_requested = true
	state.capture_started = time.tick_now()
}
SetWorldPass :: proc(callback: World_Pass_Callback, user_data: rawptr = nil) {state.world_pass =
		callback
	state.world_pass_user_data = user_data}

SetUIPass :: proc(callback: Ui_Pass_Callback, user_data: rawptr = nil) {state.ui_pass =
		callback
	state.ui_pass_user_data = user_data}

ensure_depth_attachment :: proc() -> bool {
	extent := state.ctx.swapchain_extent
	if state.world_render_width > 0 && state.world_render_height > 0 {
		extent = {state.world_render_width, state.world_render_height}
	}
	if state.depth.width == extent.width && state.depth.height == extent.height && state.depth.view != vk.ImageView(0) do return true
	_ = vk.DeviceWaitIdle(
		state.ctx.device,
	)
	resources.image_destroy(&state.depth, &state.ctx)
	created := resources.depth_create(&state.ctx, extent.width, extent.height, &state.depth)
	state.depth_initialized = false
	return created
}

ensure_world_scene :: proc() -> bool {
	if state.world_render_width == 0 || state.world_render_height == 0 do return true
	if state.world_scene.width == state.world_render_width &&
	   state.world_scene.height == state.world_render_height &&
	   state.world_scene.view != vk.ImageView(0) {
		return true
	}
	_ = vk.DeviceWaitIdle(state.ctx.device)
	resources.image_destroy(&state.world_scene, &state.ctx)
	state.world_scene_sample_ready = false
	created := resources.image_create(
		&state.ctx,
		state.world_render_width,
		state.world_render_height,
		state.ctx.swapchain_format,
		{.COLOR_ATTACHMENT, .SAMPLED},
		{.COLOR},
		{._1},
		&state.world_scene,
		"fixed-resolution world scene",
	)
	if !created do return false
	sampler_info := vk.SamplerCreateInfo {
		sType = .SAMPLER_CREATE_INFO,
		magFilter = .LINEAR,
		minFilter = .LINEAR,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		maxLod = 0,
	}
	if vk.CreateSampler(state.ctx.device, &sampler_info, nil, &state.world_scene.sampler) != .SUCCESS {
		resources.image_destroy(&state.world_scene, &state.ctx)
		return false
	}
	engine.vk_set_debug_name(&state.ctx, .SAMPLER, auto_cast state.world_scene.sampler, "canvas world scene sampler")
	image_info := vk.DescriptorImageInfo {
		imageView = state.world_scene.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	sampler := vk.DescriptorImageInfo {sampler = state.world_scene.sampler}
	writes := [2]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = state.descriptors[MAX_TEXTURES - 2],
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &image_info,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = state.descriptors[MAX_TEXTURES - 2],
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .SAMPLER,
			pImageInfo = &sampler,
		},
	}
	vk.UpdateDescriptorSets(state.ctx.device, 2, raw_data(writes[:]), 0, nil)
	return true
}

ensure_hdr_scene :: proc() -> bool {
	extent := state.ctx.swapchain_extent
	if state.hdr_scene.width == extent.width && state.hdr_scene.height == extent.height && state.hdr_scene.view != vk.ImageView(0) do return true
	_ = vk.DeviceWaitIdle(state.ctx.device)
	resources.image_destroy(&state.hdr_scene, &state.ctx)
	if !resources.image_create(&state.ctx, extent.width, extent.height, .R16G16B16A16_SFLOAT, {.COLOR_ATTACHMENT, .SAMPLED}, {.COLOR}, {._1}, &state.hdr_scene, "stellar HDR scene") do return false
	sampler_info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .LINEAR,
		minFilter    = .LINEAR,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		maxLod       = 0,
	}
	if vk.CreateSampler(state.ctx.device, &sampler_info, nil, &state.hdr_scene.sampler) !=
	   .SUCCESS {resources.image_destroy(&state.hdr_scene, &state.ctx); return false}
	engine.vk_set_debug_name(&state.ctx, .SAMPLER, auto_cast state.hdr_scene.sampler, "canvas HDR scene sampler")
	ii := vk.DescriptorImageInfo {
		imageView   = state.hdr_scene.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	si := vk.DescriptorImageInfo {
		sampler = state.hdr_scene.sampler,
	}
	writes := [2]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = state.descriptors[MAX_TEXTURES - 1],
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &ii,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = state.descriptors[MAX_TEXTURES - 1],
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .SAMPLER,
			pImageInfo = &si,
		},
	}
	vk.UpdateDescriptorSets(state.ctx.device, 2, raw_data(writes[:]), 0, nil)
	return true
}
