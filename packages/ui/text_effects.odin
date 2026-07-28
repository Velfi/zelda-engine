package ui

import "core:math"

Text_Effect :: struct {
    color:                                              [4]u8,
    scale:                                              f32,
    offset:                                             Vec2,
    letter_spacing:                                     f32,
    bold, italic, underline:                            bool,
    shadow_color:                                       [4]u8,
    shadow_offset:                                      Vec2,
    wave_amplitude, wave_frequency, wave_speed:         f32,
    shake:                                              f32,
    pulse_amount, pulse_speed:                          f32,
    drift:                                              Vec2,
    typewriter_characters_per_second, typewriter_delay: f32,
}

Text_Span :: struct {
    text:   string,
    effect: Text_Effect,
}

text_effect_default :: proc(color := [4]u8{255, 255, 255, 255}, scale: f32 = 1) -> Text_Effect {
    return {color = color, scale = scale}
}

text_effect_lerp :: proc(a, b: Text_Effect, t: f32) -> Text_Effect {
    amount := clamp(t, 0, 1); result := a
    for &channel, i in result.color do channel = u8(f32(a.color[i]) + (f32(b.color[i]) - f32(a.color[i])) * amount)
    for &channel, i in result.shadow_color do channel = u8(f32(a.shadow_color[i]) + (f32(b.shadow_color[i]) - f32(a.shadow_color[i])) * amount)
    result.scale = a.scale + (b.scale - a.scale) * amount
    result.offset = {a.offset.x + (b.offset.x - a.offset.x) * amount, a.offset.y + (b.offset.y - a.offset.y) * amount}
    result.letter_spacing = a.letter_spacing + (b.letter_spacing - a.letter_spacing) * amount
    result.bold =
        amount < .5 ? a.bold : b.bold; result.italic = amount < .5 ? a.italic : b.italic; result.underline = amount < .5 ? a.underline : b.underline
    result.shadow_offset = {
        a.shadow_offset.x + (b.shadow_offset.x - a.shadow_offset.x) * amount,
        a.shadow_offset.y + (b.shadow_offset.y - a.shadow_offset.y) * amount,
    }
    result.wave_amplitude =
        a.wave_amplitude +
        (b.wave_amplitude - a.wave_amplitude) *
            amount; result.wave_frequency = a.wave_frequency + (b.wave_frequency - a.wave_frequency) * amount; result.wave_speed = a.wave_speed + (b.wave_speed - a.wave_speed) * amount
    result.shake =
        a.shake +
        (b.shake - a.shake) *
            amount; result.pulse_amount = a.pulse_amount + (b.pulse_amount - a.pulse_amount) * amount; result.pulse_speed = a.pulse_speed + (b.pulse_speed - a.pulse_speed) * amount
    result.drift = {a.drift.x + (b.drift.x - a.drift.x) * amount, a.drift.y + (b.drift.y - a.drift.y) * amount}
    result.typewriter_characters_per_second =
        a.typewriter_characters_per_second +
        (b.typewriter_characters_per_second - a.typewriter_characters_per_second) *
            amount; result.typewriter_delay = a.typewriter_delay + (b.typewriter_delay - a.typewriter_delay) * amount
    return result
}

text_effect_visible_glyphs :: proc(effect: Text_Effect, elapsed: f32, glyph_count: int) -> int {
    if effect.typewriter_characters_per_second <= 0 do return glyph_count
    return clamp(
        int(max(elapsed - effect.typewriter_delay, 0) * effect.typewriter_characters_per_second),
        0,
        glyph_count,
    )
}

text_effect_span_visible_glyphs :: proc(effect: Text_Effect, elapsed, timeline_start: f32, glyph_count: int) -> int {
    return text_effect_visible_glyphs(effect, elapsed - timeline_start, glyph_count)
}

text_effect_span_duration :: proc(effect: Text_Effect, glyph_count: int) -> f32 {
    if effect.typewriter_characters_per_second <= 0 do return 0
    return max(effect.typewriter_delay, 0) + f32(glyph_count) / effect.typewriter_characters_per_second
}

text_effect_reveal_glyph_count :: proc(value: string) -> int {
    count := 0; for ch in value do if ch != '\n' do count += 1; return count
}

text_effect_line_scale :: proc(spans: []Text_Span, target_line: int) -> f32 {
    line := 0; line_scale: f32 = 1
    for span in spans {
        scale := span.effect.scale; if scale <= 0 do scale = 1
        for ch in span.text {
            if line == target_line do line_scale = max(line_scale, scale)
            if ch == '\n' { if line == target_line do return line_scale; line += 1 }
        }
    }
    return line_scale
}

text_effect_hash :: proc(index: int) -> f32 {
    value :=
        u32(index) * 747796405 +
        2891336453; shift := (value >> 28) + 4; value = ((value >> shift) ~ value) * u32(277803737); value = (value >> 22) ~ value
    return f32(value & 0xffff) / 32767.5 - 1
}
