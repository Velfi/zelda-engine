#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float x;
    float y;
} ImNodeVec2;

typedef struct {
    bool changed;
    bool value;
} ImNodeBoolResult;

typedef struct {
    bool changed;
    int32_t value;
} ImNodeI32Result;

typedef struct {
    bool changed;
    float value;
} ImNodeF32Result;

typedef struct {
    bool changed;
    float r;
    float g;
    float b;
    float a;
} ImNodeColor4Result;

typedef struct {
    bool visible;
    bool open;
} ImNodeBeginResult;

typedef struct {
    bool changed;
    int32_t selection;
} ImNodeSelectionResult;

void im_set_odin_ctx(void);
void im_free_tmp_alloc(void);

void __im_check_version(void);
void* __im_create_context(void);
void __im_destroy_context(void* ctx);
void* __im_get_current_context(void);
void __im_set_current_context(void* ctx);
void* __im_get_io(void);
void __im_new_frame(void);
void __im_end_frame(void);
void __im_render(void);
void __im_style_colors_dark(void);
void __im_style_colors_light(void);
void __im_style_colors_classic(void);
ImNodeBoolResult __im_show_demo_window(bool use_open, bool open);

void __im_io_add_key_event(void* io, int32_t key, bool down);
void __im_io_add_mouse_pos_event(void* io, float x, float y);
void __im_io_add_mouse_button_event(void* io, int32_t button, bool down);
void __im_io_add_mouse_wheel_event(void* io, float wheel_x, float wheel_y);
void __im_io_add_input_characters_utf8(void* io, char* text);
void __im_io_set_display_size(void* io, ImNodeVec2 size);

ImNodeBeginResult __im_begin(char* name, bool use_open, bool open, uint32_t window_flags);
void __im_end(void);
bool __im_begin_child(char* str_id, ImNodeVec2 size, uint32_t child_flags, uint32_t window_flags);
void __im_end_child(void);
void __im_text(char* text);
void __im_text_unformatted(char* text);
void __im_text_disabled(char* text);
void __im_separator_text(char* text);
void __im_same_line(float offset_from_start_x, float spacing);
bool __im_button(char* label, ImNodeVec2 size);
bool __im_small_button(char* label);
ImNodeBoolResult __im_checkbox(char* label, bool value);
ImNodeF32Result __im_slider_float(char* label, float value, float v_min, float v_max, char* format, uint32_t flags);
ImNodeI32Result __im_slider_int(char* label, int32_t value, int32_t v_min, int32_t v_max, char* format, uint32_t flags);
ImNodeF32Result __im_drag_float(char* label, float value, float v_speed, float v_min, float v_max, char* format, uint32_t flags);
ImNodeI32Result __im_drag_int(char* label, int32_t value, float v_speed, int32_t v_min, int32_t v_max, char* format, uint32_t flags);
ImNodeI32Result __im_combo_char(char* label, int32_t current_item, char** items, int32_t items_count, int32_t popup_max_height_in_items);
ImNodeColor4Result __im_color_edit4(char* label, float r, float g, float b, float a, uint32_t flags);
void __im_progress_bar(float fraction, ImNodeVec2 size, char* overlay);
void __im_plot_lines(char* label, float* values, int32_t values_count, int32_t values_offset, char* overlay, float scale_min, float scale_max, ImNodeVec2 graph_size, int32_t stride);
void __im_set_scroll_here_y(float center_y_ratio);
void __im_push_id(char* value);
void __im_push_id_ptr(uintptr_t value);
void __im_pop_id(void);
void __im_begin_disabled(bool disabled);
void __im_end_disabled(void);
ImNodeSelectionResult __im_curve(
    char* label,
    ImNodeVec2 size,
    int32_t maxpoints,
    ImNodeVec2* points,
    bool use_selection,
    int32_t selection,
    ImNodeVec2 range_min,
    ImNodeVec2 range_max
);
float __im_curve_value(float p, int32_t maxpoints, ImNodeVec2* points);
float __im_curve_value_smooth(float p, int32_t maxpoints, ImNodeVec2* points);

#ifdef __cplusplus
}
#endif
