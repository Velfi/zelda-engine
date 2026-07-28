package ui

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:sync"
import "core:time"
import zmath "zelda_engine:math"

when ODIN_OS == .Windows {
    foreign import textshape "../../third_party/textshape/textshape.lib"
} else {
    foreign import textshape "../../third_party/textshape/libtextshape.a"
}

@(default_calling_convention = "c")
foreign textshape {
    vo_textshape_init :: proc(font_kind: i32, font_path: cstring, logical_height: f32) -> i32 ---
    vo_textshape_add_fallback :: proc(font_kind: i32, font_path: cstring, logical_height: f32) -> i32 ---
    vo_textshape_width :: proc(font_kind: i32, text: [^]u8, len: i32, text_scale, fallback_advance: f32) -> f32 ---
    vo_textshape_shape :: proc(font_kind: i32, text: [^]u8, len: i32, text_scale: f32, out: [^]Gui_Shaped_Glyph, out_cap: i32) -> i32 ---
    vo_textshape_shape_ex :: proc(font_kind: i32, text: [^]u8, len: i32, text_scale: f32, base_direction: i32, out: [^]Gui_Shaped_Glyph, out_cap: i32) -> i32 ---
    vo_textshape_rasterize_glyph :: proc(face_id: i32, glyph_id: u32, pixel_height: i32, out_alpha: [^]u8, out_cap: i32, out: ^Gui_Raster_Glyph) -> i32 ---
    vo_textshape_next_grapheme :: proc(text: [^]u8, len: i32) -> i32 ---
    vo_textshape_next_word :: proc(text: [^]u8, len: i32) -> i32 ---
    vo_textshape_next_line_break :: proc(text: [^]u8, len: i32) -> i32 ---
    vo_textshape_ascii_glyph_bounds :: proc(font_kind: i32, glyph_first, glyph_last, pixel_height: i32, out: ^Gui_Glyph_Bounds) -> i32 ---
    vo_textshape_render_ascii_atlas :: proc(font_kind: i32, glyph_first, glyph_last, pixel_height, cell_width, cell_height, columns, origin_x, baseline: i32, out_rgba: [^]u8, out_len: i32) -> i32 ---
}

Vec2 :: zmath.Vec2

Rect :: struct {
    x, y, w, h: f32,
}

Color :: struct {
    r, g, b, a: f32,
}

Hsv_Color :: struct {
    h, s, v, a: f32,
}

Gui_Vec2_Range :: struct {
    min, max: Vec2,
}

Text_Align :: enum {
    Left,
    Center,
    Right,
}

Text_Direction :: enum i32 {
    Auto,
    LTR,
    RTL,
}

Gui_Font_Kind :: enum i32 {
    Body,
    Display,
    SimStart,
}

Gui_Align :: enum {
    Start,
    Center,
    End,
    Stretch,
}

Gui_Distribution :: enum {
    Start,
    Center,
    End,
    Space_Between,
}

Gui_Breakpoint :: enum {
    Compact,
    Medium,
    Expanded,
    Wide,
}

Gui_Blend_Mode :: enum {
    Alpha,
    Add,
    Multiply,
    Screen,
}

Gui_Shader_Kind :: enum {
    Hue_Strip,
    SV_Grid,
    Alpha_Ramp,
    Hue_Wheel,
    Circular_Progress,
}

Gui_Edge_Insets :: struct {
    left, top, right, bottom: f32,
}

Gui_Anchor :: struct {
    left, top, right, bottom: f32,
}

Gui_Box_Style :: struct {
    fill:          Color,
    fill_to:       Color,
    border:        Color,
    radius:        f32,
    border_width:  f32,
    opacity:       f32,
    shadow_color:  Color,
    shadow_offset: Vec2,
    shadow_blur:   f32,
    gradient:      bool,
    blend:         Gui_Blend_Mode,
}

Gui_Image_Filter :: struct {
    brightness: f32,
    contrast:   f32,
    grayscale:  f32,
    blur:       f32,
}

Gui_Glass_Style :: struct {
    tint:       Color,
    radius:     f32,
    thickness:  f32,
    roughness:  f32,
    bevel:      f32,
    ior:        f32,
    dispersion: f32,
    border:     f32,
    highlight:  f32,
}

Input_Device_Kind :: enum {
    Mouse_Keyboard,
    Controller,
}

Controller_Prompt_Style :: enum {
    Xbox,
    PlayStation,
    Steam_Deck,
}

Input_State :: struct {
    window_width:               i32,
    window_height:              i32,
    mouse_pos:                  Vec2,
    mouse_down:                 bool,
    mouse_pressed:              bool,
    mouse_released:             bool,
    mouse_moved:                bool,
    mouse_delta:                Vec2,
    mouse_button:               u32,
    wheel_delta_x:              f32,
    wheel_delta:                f32,
    delta_time:                 f32,
    active_device:              Input_Device_Kind,
    controller_prompt_style:    Controller_Prompt_Style,
    controller_south_is_accept: bool,
    pointer_enabled:            bool,
    virtual_cursor_pos:         Vec2,
    nav_x:                      f32,
    nav_y:                      f32,
    nav_pressed_x:              f32,
    nav_pressed_y:              f32,
    accept:                     bool,
    accept_pressed:             bool,
    back:                       bool,
    pause:                      bool,
    toggle_ui:                  bool,
    focus_next:                 bool,
    focus_prev:                 bool,
    primary_down:               bool,
    primary_pressed:            bool,
    primary_released:           bool,
    secondary_down:             bool,
    secondary_pressed:          bool,
    secondary_released:         bool,
    controller_connected:       bool,
    controller_disconnected:    bool,
    canvas_tool_slot:           u32,
    text_input:                 [32]u8,
    text_input_len:             int,
    clipboard_paste:            [256]u8,
    clipboard_paste_len:        int,
    key_tab:                    bool,
    key_shift:                  bool,
    key_ctrl:                   bool,
    key_super:                  bool,
    key_enter:                  bool,
    key_escape:                 bool,
    key_backspace:              bool,
    key_delete:                 bool,
    key_home:                   bool,
    key_end:                    bool,
    key_left:                   bool,
    key_right:                  bool,
    key_up:                     bool,
    key_down:                   bool,
    key_w:                      bool,
    key_a:                      bool,
    key_s:                      bool,
    key_d:                      bool,
    key_q:                      bool,
    key_e:                      bool,
    key_x:                      bool,
    key_v:                      bool,
    key_c:                      bool,
    key_f1:                     bool,
    key_slash:                  bool,
    key_space:                  bool,
    key_space_down:             bool,
    key_space_pressed:          bool,
    key_space_released:         bool,
    controller_left:            Vec2,
    controller_zoom:            f32,
}

Draw_Command_Kind :: enum {
    Filled_Rect,
    Stroked_Rect,
    Filled_Rounded_Rect,
    Stroked_Rounded_Rect,
    Gradient_Rect,
    Horizontal_Gradient_Rect,
    Filled_Quad,
    Filled_Triangle,
    Gradient_Triangle,
    Line,
    Filled_Ellipse,
    Stroked_Ellipse,
    Shader_Rect,
    Image,
    Backdrop_Blur_Rect,
    Refractive_Glass_Rect,
    Text,
    Scissor_Begin,
    Scissor_End,
}

Gui_Image_Id :: distinct u64
Gui_Id :: u64
GUI_ID_NONE :: Gui_Id(0)

// Shared controller focus primitives. Screens own their region hierarchy; the
// framework owns phase transitions and optional per-region cursor memory.
Controller_Focus_Phase :: enum {
    Unfocused,
    Region,
    Child_Region,
    Active_Control,
}

Controller_Focus_Memory :: struct {
    region:  Gui_Id,
    control: Gui_Id,
}

MAX_CONTROLLER_FOCUS_MEMORY :: 32

Controller_Focus_State :: struct {
    phase:          Controller_Focus_Phase,
    region:         Gui_Id,
    parent_region:  Gui_Id,
    active_control: Gui_Id,
    remember_focus: bool,
    memory:         [MAX_CONTROLLER_FOCUS_MEMORY]Controller_Focus_Memory,
    memory_count:   int,
}

Controller_Edit_Snapshot_Kind :: enum {
    None,
    Float,
    Integer,
    Boolean,
    Text,
    Vec2,
    Hsv,
}

gui_controller_focus_init :: proc(state: ^Controller_Focus_State, remember_focus := true) {
    state^ = {
        phase          = .Unfocused,
        remember_focus = remember_focus,
    }
}

gui_controller_focus_remember :: proc(state: ^Controller_Focus_State, region, control: Gui_Id) {
    if state == nil || !state.remember_focus || region == GUI_ID_NONE || control == GUI_ID_NONE {
        return
    }
    for i in 0 ..< state.memory_count {
        if state.memory[i].region == region {
            state.memory[i].control = control
            return
        }
    }
    if state.memory_count < MAX_CONTROLLER_FOCUS_MEMORY {
        state.memory[state.memory_count] = {
            region  = region,
            control = control,
        }
        state.memory_count += 1
    }
}

gui_controller_focus_restore :: proc(state: ^Controller_Focus_State, region, fallback: Gui_Id) -> Gui_Id {
    if state != nil && state.remember_focus {
        for i in 0 ..< state.memory_count {
            if state.memory[i].region == region && state.memory[i].control != GUI_ID_NONE {
                return state.memory[i].control
            }
        }
    }
    return fallback
}

gui_controller_focus_enter_region :: proc(
    state: ^Controller_Focus_State,
    region, parent_region, fallback: Gui_Id,
) -> Gui_Id {
    if state == nil {
        return fallback
    }
    state.parent_region = parent_region
    state.region = region
    state.active_control = GUI_ID_NONE
    state.phase = parent_region == GUI_ID_NONE ? .Region : .Child_Region
    return gui_controller_focus_restore(state, region, fallback)
}

gui_controller_focus_activate :: proc(state: ^Controller_Focus_State, control: Gui_Id) {
    if state == nil || control == GUI_ID_NONE {
        return
    }
    state.active_control = control
    state.phase = .Active_Control
}

gui_controller_focus_deactivate :: proc(state: ^Controller_Focus_State) {
    if state == nil {
        return
    }
    state.active_control = GUI_ID_NONE
    state.phase = state.parent_region == GUI_ID_NONE ? .Region : .Child_Region
}

gui_controller_focus_leave_region :: proc(state: ^Controller_Focus_State) {
    if state == nil {
        return
    }
    if state.parent_region != GUI_ID_NONE {
        state.region = state.parent_region
        state.parent_region = GUI_ID_NONE
        state.phase = .Region
    } else {
        state.region = GUI_ID_NONE
        state.phase = .Unfocused
    }
    state.active_control = GUI_ID_NONE
}

Draw_Command :: struct {
    kind:          Draw_Command_Kind,
    rect:          Rect,
    rect_2:        Rect,
    p0:            Vec2,
    p1:            Vec2,
    p2:            Vec2,
    p3:            Vec2,
    color:         Color,
    color_2:       Color,
    color_3:       Color,
    text:          string,
    text_scale:    f32,
    text_align:    Text_Align,
    font_kind:     Gui_Font_Kind,
    radius:        f32,
    stroke_width:  f32,
    image_id:      Gui_Image_Id,
    image_filter:  Gui_Image_Filter,
    glass_style:   Gui_Glass_Style,
    shader_kind:   Gui_Shader_Kind,
    shader_params: Color,
    blend:         Gui_Blend_Mode,
}

Gui_Style :: struct {
    bg:                  Color,
    panel:               Color,
    panel_border:        Color,
    control:             Color,
    control_hot:         Color,
    control_active:      Color,
    control_disabled:    Color,
    text:                Color,
    text_muted:          Color,
    accent:              Color,
    danger:              Color,
    spacing:             f32,
    spacing_1:           f32,
    spacing_2:           f32,
    spacing_3:           f32,
    spacing_4:           f32,
    rhythm:              f32,
    display_text_height: f32,
    display_line_height: f32,
    display_char_width:  f32,
    display_text_scale:  f32,
    heading_text_height: f32,
    heading_line_height: f32,
    heading_char_width:  f32,
    heading_text_scale:  f32,
    body_text_height:    f32,
    body_line_height:    f32,
    body_char_width:     f32,
    body_text_scale:     f32,
    small_text_height:   f32,
    small_line_height:   f32,
    small_char_width:    f32,
    small_text_scale:    f32,
    control_padding:     f32,
    margin:              f32,
    section_gap:         f32,
    scrollbar_width:     f32,
    scrollbar_gutter:    f32,
    focus_ring_width:    f32,
    row_height:          f32,
    text_height:         f32,
    char_width:          f32,
    text_scale:          f32,
    panel_padding:       f32,
    radius_panel:        f32,
    radius_control:      f32,
    border_width:        f32,
    shadow_blur:         f32,
    shadow_offset:       Vec2,
    shadow_color:        Color,
}

Gui_Axis :: enum {
    Column,
    Row,
}

Gui_Layout_Frame :: struct {
    bounds:         Rect,
    cursor:         Vec2,
    axis:           Gui_Axis,
    content_width:  f32,
    content_height: f32,
    gap:            f32,
    item_height:    f32,
    padding:        Gui_Edge_Insets,
    align_cross:    Gui_Align,
}

Gui_Scroll_Frame :: struct {
    viewport:        Rect,
    content_height:  f32,
    scroll:          f32,
    previous_scroll: f32,
    target_scroll:   ^f32,
    wheel_consumed:  bool,
    focus_record:    int,
}

Gui_Scroll_Focus_Record :: struct {
    viewport:      Rect,
    scroll:        f32,
    max_scroll:    f32,
    target_scroll: ^f32,
    animation_id:  Gui_Id,
    parent:        int,
}

Gui_Scroll_Hit :: struct {
    viewport:   Rect,
    scroll:     f32,
    max_scroll: f32,
    step:       f32,
    depth:      int,
}

MAX_GUI_LAYOUT_DEPTH :: 16
MAX_GUI_CLIP_DEPTH :: 16
MAX_GUI_SCROLL_DEPTH :: 8
MAX_GUI_SCROLL_HITS :: 32
MAX_GUI_SCROLL_FOCUS_RECORDS :: 32
MAX_GUI_ID_DEPTH :: 32
MAX_GUI_DEBUG_IDS :: 512
MAX_GUI_ANIMATION_SLOTS :: 128
MAX_GUI_SPATIAL_ITEMS :: 512
MAX_GUI_SPATIAL_GROUP_DEPTH :: 16
MAX_GUI_OVERLAY_INPUT_RECTS :: 16
MAX_GUI_INTERACTION_RECTS :: 512
GUI_TEXT_WIDTH_CACHE_SLOTS :: 512
GUI_TEXT_WIDTH_CACHE_MAX_BYTES :: 128
GUI_FONT_KIND_CAP :: 4
GUI_FONT_FALLBACK_CAP :: 31
GUI_COMBO_SHORT_POPUP_ROWS :: 5
GUI_BODY_FONT_PATH :: "assets/fonts/ZeldaSans-Regular-v1.otf"
GUI_DISPLAY_FONT_PATH :: "assets/fonts/ZeldaSerif-Regular-v0_1.otf"
GUI_SIM_START_FONT_PATH :: "assets/fonts/MomoTrustDisplay-Regular.ttf"
GUI_PI :: f32(3.14159265358979323846)
GUI_TAU :: f32(6.28318530717958647692)

gui_body_font_path: cstring = GUI_BODY_FONT_PATH
gui_display_font_path: cstring = GUI_DISPLAY_FONT_PATH
gui_font_fallback_paths: [GUI_FONT_KIND_CAP][GUI_FONT_FALLBACK_CAP]cstring
gui_font_fallback_counts: [GUI_FONT_KIND_CAP]int
gui_text_shaper_ready: bool
gui_text_shaper_font_ready: [GUI_FONT_KIND_CAP]bool
gui_text_shaper_once: sync.Once

Gui_Profile_Snapshot :: struct {
    width_calls:      u64,
    width_cache_hits: u64,
    width_seconds:    f64,
    shape_calls:      u64,
    shape_glyphs:     u64,
    shape_seconds:    f64,
    wrap_calls:       u64,
    wrap_seconds:     f64,
}

gui_profile: Gui_Profile_Snapshot

Gui_Animation_Slot :: struct {
    id:         Gui_Id,
    value:      f32,
    last_frame: u64,
}

Gui_Text_Line :: struct {
    start: int,
    end:   int,
}

Gui_Wrap_Candidate :: struct {
    pos:    int,
    forced: bool,
}

Gui_Text_Width_Cache_Entry :: struct {
    hash:             u64,
    len:              int,
    scale:            f32,
    fallback_advance: f32,
    font_kind:        Gui_Font_Kind,
    width:            f32,
    shaper_ready:     bool,
    valid:            bool,
    bytes:            [GUI_TEXT_WIDTH_CACHE_MAX_BYTES]u8,
}

gui_text_width_cache: [GUI_TEXT_WIDTH_CACHE_SLOTS]Gui_Text_Width_Cache_Entry

Gui_Control :: struct {
    id:        Gui_Id,
    bounds:    Rect,
    enabled:   bool,
    hovered:   bool,
    focused:   bool,
    activated: bool,
    nav_x:     f32,
    nav_y:     f32,
}

Gui_Spatial_Group_Options :: struct {
    enabled: bool,
}

Gui_Spatial_Group :: struct {
    id:      Gui_Id,
    enabled: bool,
}

Gui_Spatial_Item :: struct {
    id:           Gui_Id,
    bounds:       Rect,
    group:        Gui_Id,
    order:        int,
    enabled:      bool,
    focusable:    bool,
    visible:      bool,
    scroll_owner: int,
}

// Interaction rectangles are a compact retained snapshot of the previous
// completed frame. Product values remain immediate-mode; only stable ID and
// resolved geometry cross the frame boundary.
Gui_Interaction_Rect :: struct {
    id:      Gui_Id,
    bounds:  Rect,
    enabled: bool,
}

Gui_Document_Scroll_Slot :: struct {
    id:         Gui_Id,
    value:      f32,
    last_frame: u64,
}

MAX_GUI_DOCUMENT_SCROLL_SLOTS :: 64

Gui_Shaped_Glyph :: struct {
    glyph_id:    u32,
    cluster:     u32,
    cluster_end: u32,
    face_id:     u16,
    direction:   u8,
    missing:     u8,
    x_offset:    f32,
    y_offset:    f32,
    x_advance:   f32,
    y_advance:   f32,
}

Gui_Raster_Glyph :: struct {
    width:     i32,
    height:    i32,
    left:      i32,
    top:       i32,
    advance_x: i32,
}

Gui_Glyph_Bounds :: struct {
    min_x:   i32,
    max_x:   i32,
    ascent:  i32,
    descent: i32,
}

Gui_Context :: struct {
    input:                           Input_State,
    previous_input:                  Input_State,
    commands:                        [dynamic]Draw_Command,
    paint_commands:                  [dynamic]Draw_Command,
    spare_commands:                  [dynamic]Draw_Command,
    paint_publish_pending:           bool,
    hot:                             Gui_Id,
    active:                          Gui_Id,
    focused:                         Gui_Id,
    mouse_prev_pos:                  Vec2,
    mouse_delta:                     Vec2,
    mouse_initialized:               bool,
    fine_pointer_drag_id:            Gui_Id,
    text_edit_id:                    Gui_Id,
    text_edit_buffer:                [64]u8,
    text_edit_len:                   int,
    text_edit_caret:                 int,
    text_edit_anchor:                int,
    text_edit_scroll_x:              f32,
    text_edit_blink:                 f32,
    text_edit_selecting:             bool,
    wants_text_input:                bool,
    numeric_edit_snapshot_id:        Gui_Id,
    numeric_edit_snapshot_value:     f32,
    numeric_edit_snapshot_u32:       u32,
    numeric_precision_id:            Gui_Id,
    numeric_precision_index:         int,
    numeric_pointer_id:              Gui_Id,
    numeric_pointer_distance:        f32,
    clipboard_set_pending:           bool,
    clipboard_set_text:              [256]u8,
    clipboard_set_len:               int,
    focus_order_next:                int,
    focus_moved:                     bool,
    focus_edit_id:                   Gui_Id,
    focus_edit_seen:                 bool,
    controller_explicit_activation:  bool,
    controller_armed_id:             Gui_Id,
    controller_snapshot_id:          Gui_Id,
    controller_snapshot_kind:        Controller_Edit_Snapshot_Kind,
    controller_snapshot_f32:         f32,
    controller_snapshot_int:         int,
    controller_snapshot_bool:        bool,
    controller_snapshot_vec2:        Vec2,
    controller_snapshot_hsv:         Hsv_Color,
    controller_snapshot_text:        [256]u8,
    controller_snapshot_text_len:    int,
    controller_cancel_id:            Gui_Id,
    spatial_items:                   [MAX_GUI_SPATIAL_ITEMS]Gui_Spatial_Item,
    spatial_item_count:              int,
    spatial_groups:                  [MAX_GUI_SPATIAL_GROUP_DEPTH]Gui_Spatial_Group,
    spatial_group_depth:             int,
    focus_scope:                     Gui_Id,
    focus_scope_active:              bool,
    frame_index:                     u64,
    open_panel:                      Gui_Id,
    scroll_drag_id:                  Gui_Id,
    scroll_drag_start_pos:           Vec2,
    scroll_drag_start_scroll:        f32,
    scroll_drag_consumed:            bool,
    scroll_drag_release_pending:     bool,
    combo_highlight:                 int,
    combo_scroll:                    f32,
    combo_popup_visible:             bool,
    combo_popup_id:                  Gui_Id,
    combo_popup_rect:                Rect,
    combo_popup_options:             []string,
    combo_popup_query:               [128]u8,
    combo_popup_query_len:           int,
    tooltip_visible:                 bool,
    tooltip_from_hover:              bool,
    tooltip_rect:                    Rect,
    tooltip_text:                    string,
    tooltip_numeric_controls:        bool,
    tooltip_numeric_text_editing:    bool,
    notice_text:                     [192]u8,
    notice_text_len:                 int,
    notice_seconds:                  f32,
    next_cursor:                     Vec2,
    content_width:                   f32,
    style:                           Gui_Style,
    layout_stack:                    [MAX_GUI_LAYOUT_DEPTH]Gui_Layout_Frame,
    layout_depth:                    int,
    input_clip_stack:                [MAX_GUI_CLIP_DEPTH]Rect,
    input_clip_depth:                int,
    overlay_input_rects:             [MAX_GUI_OVERLAY_INPUT_RECTS]Rect,
    overlay_input_rect_count:        int,
    next_overlay_input_rects:        [MAX_GUI_OVERLAY_INPUT_RECTS]Rect,
    next_overlay_input_rect_count:   int,
    overlay_input_depth:             int,
    scroll_stack:                    [MAX_GUI_SCROLL_DEPTH]Gui_Scroll_Frame,
    scroll_depth:                    int,
    wheel_scroll_consumed:           bool,
    wheel_scroll_depth:              int,
    wheel_scroll_target_depth:       int,
    scroll_hits:                     [MAX_GUI_SCROLL_HITS]Gui_Scroll_Hit,
    scroll_hit_count:                int,
    next_scroll_hits:                [MAX_GUI_SCROLL_HITS]Gui_Scroll_Hit,
    next_scroll_hit_count:           int,
    scroll_focus_records:            [MAX_GUI_SCROLL_FOCUS_RECORDS]Gui_Scroll_Focus_Record,
    scroll_focus_record_count:       int,
    last_scroll_declared_height:     f32,
    last_scroll_used_height:         f32,
    scroll_measure_declared:         [MAX_GUI_SCROLL_HITS]f32,
    scroll_measure_used:             [MAX_GUI_SCROLL_HITS]f32,
    scroll_measure_count:            int,
    id_stack:                        [MAX_GUI_ID_DEPTH]Gui_Id,
    id_depth:                        int,
    debug_registered_ids:            [MAX_GUI_DEBUG_IDS]Gui_Id,
    debug_registered_id_count:       int,
    debug_duplicate_id_count:        int,
    animation_slots:                 [MAX_GUI_ANIMATION_SLOTS]Gui_Animation_Slot,
    interaction_rects:               [MAX_GUI_INTERACTION_RECTS]Gui_Interaction_Rect,
    interaction_rect_count:          int,
    next_interaction_rects:          [MAX_GUI_INTERACTION_RECTS]Gui_Interaction_Rect,
    next_interaction_rect_count:     int,
    interaction_snapshot_misses:     u32,
    semantic_nodes:                  [MAX_GUI_SEMANTIC_NODES]Gui_Semantic_Node,
    semantic_node_count:             int,
    semantic_stack:                  [MAX_GUI_SEMANTIC_DEPTH]int,
    semantic_depth:                  int,
    semantic_next_container_kind:    Gui_Semantic_Node_Kind,
    semantic_unstable_ids:           [MAX_GUI_UNSTABLE_IDS]Gui_Id,
    semantic_unstable_id_count:      int,
    next_semantic_unstable_ids:      [MAX_GUI_UNSTABLE_IDS]Gui_Id,
    next_semantic_unstable_id_count: int,
    semantic_diagnostics:            Gui_Semantic_Diagnostics,
    document_scroll_slots:           [MAX_GUI_DOCUMENT_SCROLL_SLOTS]Gui_Document_Scroll_Slot,
    document_scroll_slot_count:      int,
    document_scroll_fallback:        f32,
    focus_ownership:                 Gui_Focus_Ownership,
}
