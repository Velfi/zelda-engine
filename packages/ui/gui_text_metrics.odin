package ui

import "core:time"

gui_measure_text :: proc(ctx: ^Gui_Context, text: string) -> Vec2 {
	return {gui_text_width(ctx, text), ctx.style.text_height}
}

gui_wrap_line_count :: proc(ctx: ^Gui_Context, text: string, max_width: f32) -> int {
	if max_width <= 0 {
		return 1
	}
	lines := make([dynamic]Gui_Text_Line, 0, 16)
	defer delete(lines)
	gui_text_wrap_lines(ctx, text, max_width, &lines)
	return max(len(lines), 1)
}

gui_text_wrap_lines :: proc(ctx: ^Gui_Context, text: string, max_width: f32, lines: ^[dynamic]Gui_Text_Line) {
	profile_start := time.tick_now()
	defer {
		gui_profile.wrap_calls += 1
		gui_profile.wrap_seconds += time.duration_seconds(time.tick_diff(profile_start, time.tick_now()))
	}
	bytes := transmute([]u8)text
	if len(bytes) == 0 {
		append(lines, Gui_Text_Line{})
		return
	}

	paragraph_start := 0
	for paragraph_start <= len(bytes) {
		paragraph_end := paragraph_start
		for paragraph_end < len(bytes) && bytes[paragraph_end] != '\n' {
			paragraph_end += 1
		}
		gui_text_wrap_paragraph(ctx, bytes, paragraph_start, paragraph_end, max_width, lines)
		if paragraph_end >= len(bytes) {
			break
		}
		paragraph_start = paragraph_end + 1
	}
}

gui_text_wrap_paragraph :: proc(ctx: ^Gui_Context, bytes: []u8, start, end: int, max_width: f32, lines: ^[dynamic]Gui_Text_Line) {
	if end <= start {
		append(lines, Gui_Text_Line{start, end})
		return
	}

	candidates := make([dynamic]Gui_Wrap_Candidate, 0, 16)
	defer delete(candidates)
	gui_text_wrap_candidates(ctx, bytes, start, end, max_width, &candidates)

	n := len(candidates)
	if n <= 1 {
		append(lines, gui_trim_wrap_span(bytes, start, end))
		return
	}

	large := f32(1.0e30)
	cost := make([]f32, n)
	previous := make([]int, n)
	defer delete(cost)
	defer delete(previous)

	for i in 0 ..< n {
		cost[i] = large
		previous[i] = -1
	}
	cost[0] = 0

	for i in 0 ..< n - 1 {
		if cost[i] >= large {
			continue
		}
		for j in i + 1 ..< n {
			trimmed := gui_trim_wrap_span(bytes, candidates[i].pos, candidates[j].pos)
			line_width := gui_text_span_width(ctx, bytes, trimmed.start, trimmed.end)
			if line_width <= 0 {
				continue
			}

			overflow := max(line_width - max_width, 0)
			leftover := max(max_width - line_width, 0)
			is_last := j == n - 1

			break_penalty := f32(0)
			if candidates[i].forced || candidates[j].forced {
				break_penalty = 500000
			}
			if overflow > 0 {
				break_penalty += overflow * overflow * overflow * 1000 + 500000
			}
			ragged_penalty := is_last ? f32(0) : leftover * leftover * leftover
			candidate := cost[i] + ragged_penalty + break_penalty
			if candidate < cost[j] {
				cost[j] = candidate
				previous[j] = i
			}

			if line_width > max_width {
				break
			}
		}
	}

	if previous[n - 1] < 0 {
		gui_text_wrap_greedy_fallback(ctx, bytes, start, end, max_width, lines)
		return
	}

	reversed := make([dynamic]Gui_Text_Line, 0, 8)
	defer delete(reversed)
	cursor := n - 1
	for cursor > 0 {
		prev := previous[cursor]
		if prev < 0 {
			break
		}
		trimmed := gui_trim_wrap_span(bytes, candidates[prev].pos, candidates[cursor].pos)
		append(&reversed, trimmed)
		cursor = prev
	}
	for i := len(reversed) - 1; i >= 0; i -= 1 {
		append(lines, reversed[i])
		if i == 0 {
			break
		}
	}
}

gui_text_wrap_candidates :: proc(ctx: ^Gui_Context, bytes: []u8, start, end: int, max_width: f32, out: ^[dynamic]Gui_Wrap_Candidate) {
	append(out, Gui_Wrap_Candidate{pos = start})
	cursor := start
	for cursor < end {
		next := cursor
		for next < end && !gui_is_wrap_space(bytes[next]) {
			next += 1
		}
		if next > cursor {
			word_width := gui_text_span_width(ctx, bytes, cursor, next)
			if word_width > max_width {
				gui_text_wrap_forced_candidates(ctx, bytes, cursor, next, max_width, out)
			}
		}
		for next < end && gui_is_wrap_space(bytes[next]) {
			next += 1
		}
		if next > start && next < end {
			gui_append_wrap_candidate(out, next, false)
		}
		cursor = next
	}
	gui_append_wrap_candidate(out, end, false)
}

gui_text_wrap_forced_candidates :: proc(ctx: ^Gui_Context, bytes: []u8, start, end: int, max_width: f32, out: ^[dynamic]Gui_Wrap_Candidate) {
	cursor := start
	for cursor < end {
		next := cursor
		width := f32(0)
		for next < end {
			advance := gui_glyph_advance(ctx, bytes[next])
			if next > cursor && width + advance > max_width {
				break
			}
			width += advance
			next += 1
		}
		if next <= cursor {
			next = cursor + 1
		}
		if next < end {
			gui_append_wrap_candidate(out, next, true)
		}
		cursor = next
	}
}

gui_append_wrap_candidate :: proc(out: ^[dynamic]Gui_Wrap_Candidate, pos: int, forced: bool) {
	if len(out^) > 0 {
		last := &out^[len(out^) - 1]
		if last.pos == pos {
			last.forced = last.forced || forced
			return
		}
	}
	append(out, Gui_Wrap_Candidate{pos = pos, forced = forced})
}

gui_text_wrap_greedy_fallback :: proc(ctx: ^Gui_Context, bytes: []u8, start, end: int, max_width: f32, lines: ^[dynamic]Gui_Text_Line) {
	cursor := start
	for cursor < end {
		next := cursor
		width := f32(0)
		for next < end {
			advance := gui_glyph_advance(ctx, bytes[next])
			if next > cursor && width + advance > max_width {
				break
			}
			width += advance
			next += 1
		}
		if next == cursor {
			next += 1
		}
		append(lines, gui_trim_wrap_span(bytes, cursor, next))
		cursor = next
	}
}

gui_text_width :: proc(ctx: ^Gui_Context, text: string) -> f32 {
	bytes := transmute([]u8)text
	return gui_text_span_width(ctx, bytes, 0, len(bytes))
}

gui_text_span_width :: proc(ctx: ^Gui_Context, bytes: []u8, start, end: int) -> f32 {
	if end <= start {
		return 0
	}
	return gui_font_text_width(.Body, bytes[start:end], ctx.style.text_scale, ctx.style.char_width)
}

gui_glyph_advance :: proc(ctx: ^Gui_Context, ch: u8) -> f32 {
	return gui_font_glyph_advance(.Body, ch, ctx.style.text_scale, ctx.style.char_width)
}

gui_font_text_width :: proc(font_kind: Gui_Font_Kind, bytes: []u8, scale, fallback_advance: f32) -> f32 {
	profile_start := time.tick_now()
	defer {
		gui_profile.width_calls += 1
		gui_profile.width_seconds += time.duration_seconds(time.tick_diff(profile_start, time.tick_now()))
	}
	if len(bytes) == 0 {
		return 0
	}
	effective_font_kind := gui_effective_font_kind(font_kind)
	shaper_ready := gui_text_shaper_ready && gui_font_kind_ready(effective_font_kind)
	cacheable := len(bytes) <= GUI_TEXT_WIDTH_CACHE_MAX_BYTES
	hash := u64(0)
	if cacheable {
		hash = gui_text_width_hash(effective_font_kind, bytes, scale, fallback_advance)
		slot := &gui_text_width_cache[int(hash % GUI_TEXT_WIDTH_CACHE_SLOTS)]
		if gui_text_width_cache_matches(slot, effective_font_kind, bytes, hash, scale, fallback_advance, shaper_ready) {
			gui_profile.width_cache_hits += 1
			return slot.width
		}
	}
	width := f32(0)
	if shaper_ready {
		width = vo_textshape_width(i32(effective_font_kind), raw_data(bytes), i32(len(bytes)), scale, fallback_advance)
	} else {
		for ch in bytes {
			width += gui_font_glyph_advance(effective_font_kind, ch, scale, fallback_advance)
		}
	}
	if cacheable {
		slot := &gui_text_width_cache[int(hash % GUI_TEXT_WIDTH_CACHE_SLOTS)]
		slot.hash = hash
		slot.len = len(bytes)
		slot.scale = scale
		slot.fallback_advance = fallback_advance
		slot.font_kind = effective_font_kind
		slot.width = width
		slot.shaper_ready = shaper_ready
		slot.valid = true
		copy(slot.bytes[:len(bytes)], bytes)
	}
	return width
}

gui_text_width_cache_matches :: proc(entry: ^Gui_Text_Width_Cache_Entry, font_kind: Gui_Font_Kind, bytes: []u8, hash: u64, scale, fallback_advance: f32, shaper_ready: bool) -> bool {
	if !entry.valid || entry.hash != hash || entry.len != len(bytes) || entry.scale != scale || entry.fallback_advance != fallback_advance || entry.font_kind != font_kind || entry.shaper_ready != shaper_ready {
		return false
	}
	for i in 0 ..< len(bytes) {
		if entry.bytes[i] != bytes[i] {
			return false
		}
	}
	return true
}

gui_text_width_hash :: proc(font_kind: Gui_Font_Kind, bytes: []u8, scale, fallback_advance: f32) -> u64 {
	hash := u64(14695981039346656037)
	hash = gui_hash_u64(hash, u64(len(bytes)))
	hash = gui_hash_u64(hash, u64(font_kind))
	hash = gui_hash_f32(hash, scale)
	hash = gui_hash_f32(hash, fallback_advance)
	for ch in bytes {
		hash = gui_hash_byte(hash, ch)
	}
	return hash
}

gui_hash_f32 :: proc(hash: u64, value: f32) -> u64 {
	return gui_hash_u64(hash, u64(transmute(u32)value))
}

gui_font_shape_text :: proc(font_kind: Gui_Font_Kind, bytes: []u8, scale: f32, out: []Gui_Shaped_Glyph) -> int {
	profile_start := time.tick_now()
	defer {
		gui_profile.shape_calls += 1
		gui_profile.shape_seconds += time.duration_seconds(time.tick_diff(profile_start, time.tick_now()))
	}
	effective_font_kind := gui_effective_font_kind(font_kind)
	if len(bytes) == 0 || len(out) == 0 || !gui_text_shaper_ready || !gui_font_kind_ready(effective_font_kind) {
		return 0
	}
	count := int(vo_textshape_shape(i32(effective_font_kind), raw_data(bytes), i32(len(bytes)), scale, raw_data(out), i32(len(out))))
	gui_profile.shape_glyphs += u64(max(count, 0))
	return count
}

gui_font_glyph_advance :: proc(font_kind: Gui_Font_Kind, ch: u8, scale, fallback: f32) -> f32 {
	_ = font_kind
	if ch >= GUI_FONT_GLYPH_FIRST && ch <= GUI_FONT_GLYPH_LAST {
		text_scale := scale
		if text_scale <= 0 {
			text_scale = 1
		}
		return GUI_FONT_ADVANCES[int(ch) - GUI_FONT_GLYPH_FIRST] * text_scale
	}
	return fallback
}

gui_font_glyph_slot :: proc(glyph_id: u32) -> i32 {
	if glyph_id >= GUI_FONT_GLYPH_FIRST && glyph_id <= GUI_FONT_GLYPH_LAST {
		return i32(glyph_id - GUI_FONT_GLYPH_FIRST)
	}
	return -1
}

gui_font_render_ascii_atlas :: proc(font_kind: Gui_Font_Kind, glyph_first, glyph_last, pixel_height, cell_width, cell_height, columns: int, rgba: []u8) -> bool {
	effective_font_kind := gui_effective_font_kind(font_kind)
	if len(rgba) == 0 || !gui_text_shaper_ready || !gui_font_kind_ready(effective_font_kind) {
		return false
	}
	return vo_textshape_render_ascii_atlas(
		i32(effective_font_kind),
		i32(glyph_first),
		i32(glyph_last),
		i32(pixel_height),
		i32(cell_width),
		i32(cell_height),
		i32(columns),
		raw_data(rgba),
		i32(len(rgba)),
	) != 0
}

gui_trim_wrap_span :: proc(bytes: []u8, start, end: int) -> Gui_Text_Line {
	s := start
	e := end
	for s < e && gui_is_wrap_space(bytes[s]) {
		s += 1
	}
	for e > s && gui_is_wrap_space(bytes[e - 1]) {
		e -= 1
	}
	return {s, e}
}

gui_is_break_boundary :: proc(bytes: []u8, pos, end: int) -> bool {
	if pos >= end {
		return true
	}
	if gui_is_wrap_space(bytes[pos]) {
		return true
	}
	if pos > 0 && gui_is_wrap_space(bytes[pos - 1]) {
		return true
	}
	return false
}

gui_is_wrap_space :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\r'
}

gui_inset :: proc(rect: Rect, amount: f32) -> Rect {
	return {rect.x + amount, rect.y + amount, max(rect.w - amount * 2, 0), max(rect.h - amount * 2, 0)}
}

gui_inset_edges :: proc(rect: Rect, edges: Gui_Edge_Insets) -> Rect {
	return {
		rect.x + edges.left,
		rect.y + edges.top,
		max(rect.w - edges.left - edges.right, 0),
		max(rect.h - edges.top - edges.bottom, 0),
	}
}
