package ui

import "core:math"

// Gui_Text_Role names the semantic text tiers shared by widgets and products.
// A role resolves through Gui_Style so viewport and accessibility scaling stay
// centralized rather than leaking literal sizes into callers.
Gui_Text_Role :: enum {
    Display,
    Heading,
    Body,
    Small,
}

Gui_Typography :: struct {
    font_kind:   Gui_Font_Kind,
    text_height: f32,
    line_height: f32,
    char_width:  f32,
    text_scale:  f32,
}

// Gui_Space is the vertical-rhythm scale. Values are deliberately semantic:
// changing a style's rhythm updates every token without changing layout code.
Gui_Space :: enum {
    None,
    Quarter,
    Half,
    One,
    One_And_Half,
    Two,
    Three,
}

gui_typography :: proc(style: Gui_Style, role: Gui_Text_Role) -> Gui_Typography {
    switch role {
    case .Display:
        return {
            .Display,
            style.display_text_height,
            style.display_line_height,
            style.display_char_width,
            style.display_text_scale,
        }
    case .Heading:
        return {
            .Display,
            style.heading_text_height,
            style.heading_line_height,
            style.heading_char_width,
            style.heading_text_scale,
        }
    case .Small:
        return {
            .Body,
            style.small_text_height,
            style.small_line_height,
            style.small_char_width,
            style.small_text_scale,
        }
    case .Body:
        return {.Body, style.body_text_height, style.body_line_height, style.body_char_width, style.body_text_scale}
    }
    return {}
}

gui_space :: proc(style: Gui_Style, token: Gui_Space) -> f32 {
    switch token {
    case .None:
        return 0
    case .Quarter:
        return style.spacing_1
    case .Half:
        return style.spacing_2
    case .One:
        return style.spacing_3
    case .One_And_Half:
        return style.spacing_4
    case .Two:
        return gui_rhythm(style, 2)
    case .Three:
        return gui_rhythm(style, 3)
    }
    return 0
}

// gui_rhythm supports custom multiples while gui_space covers the shared scale.
gui_rhythm :: proc(style: Gui_Style, units: f32) -> f32 {
    return gui_snap(style.rhythm * max(units, 0))
}

gui_text_block_height :: proc(style: Gui_Style, role: Gui_Text_Role, lines: int) -> f32 {
    if lines <= 0 do return 0
    return gui_typography(style, role).line_height * f32(lines)
}

// Offset from a line box's top to the glyph box, useful for consistent vertical
// centering without repeating the same formula across widgets.
gui_text_inset_y :: proc(style: Gui_Style, role: Gui_Text_Role, box_height: f32) -> f32 {
    type := gui_typography(style, role)
    return max((box_height - type.text_height) * 0.5, 0)
}

gui_text_line_inset_y :: proc(style: Gui_Style, role: Gui_Text_Role) -> f32 {
    type := gui_typography(style, role)
    return max((type.line_height - type.text_height) * 0.5, 0)
}
