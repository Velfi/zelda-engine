package ui

import "core:testing"

@(test)
unicode_boundaries_keep_combining_marks_and_emoji_sequences_atomic :: proc(t: ^testing.T) {
    decomposed_text: string = "e\u0301x"
    decomposed := transmute([]u8)decomposed_text
    testing.expect_value(t, gui_text_next_grapheme(decomposed), 3)
    testing.expect_value(t, gui_text_previous_grapheme(decomposed, 3), 0)

    family_text: string = "👩‍👩‍👧‍👦!"
    family := transmute([]u8)family_text
    testing.expect_value(t, gui_text_next_grapheme(family), len(family) - 1)
}

@(test)
unicode_editing_never_inserts_half_a_grapheme :: proc(t: ^testing.T) {
    ctx: Gui_Context
    ctx.text_edit_id = 1
    ctx.text_edit_caret = 0
    ctx.text_edit_anchor = 0
    buffer: [4]u8
    length := 0
    inserted_text: string = "e\u0301x"
    changed := gui_text_edit_insert_bytes(
        &ctx,
        buffer[:],
        &length,
        transmute([]u8)inserted_text,
    )
    testing.expect(t, changed)
    testing.expect_value(t, length, 4)

    short: [2]u8
    short_length := 0
    ctx.text_edit_caret = 0
    ctx.text_edit_anchor = 0
    cluster_text: string = "e\u0301"
    testing.expect(
        t,
        !gui_text_edit_insert_bytes(
            &ctx,
            short[:],
            &short_length,
            transmute([]u8)cluster_text,
        ),
    )
    testing.expect_value(t, short_length, 0)
}
