package ui

import "core:testing"

@(test)
text_effect_default_is_neutral :: proc(t: ^testing.T) {
    effect := text_effect_default()
    testing.expect(t, effect.color == [4]u8{255, 255, 255, 255})
    testing.expect(t, effect.scale == 1)
    testing.expect(t, effect.wave_amplitude == 0 && effect.wave_frequency == 0 && effect.wave_speed == 0)
    testing.expect(t, effect.shake == 0 && effect.pulse_amount == 0 && effect.pulse_speed == 0)
}

@(test)
text_effect_timing_is_deterministic :: proc(t: ^testing.T) {
    effect := text_effect_default(); effect.typewriter_characters_per_second = 10; effect.typewriter_delay = .5
    testing.expect(t, text_effect_visible_glyphs(effect, .25, 20) == 0)
    testing.expect(t, text_effect_visible_glyphs(effect, 1, 20) == 5)
    testing.expect(t, text_effect_visible_glyphs(effect, 4, 20) == 20)
}
