#include <stdint.h>
#include <stddef.h>

#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>

#define VO_TEXTSHAPE_MAX_FONTS 4

typedef struct Vo_Textshape_Font {
    FT_Face face;
    FT_Face render_face;
    hb_font_t *hb_font;
    char path[1024];
} Vo_Textshape_Font;

static FT_Library vo_ft_library = NULL;
static Vo_Textshape_Font vo_fonts[VO_TEXTSHAPE_MAX_FONTS];

typedef struct Vo_Shaped_Glyph {
    uint32_t glyph_id;
    float x_offset;
    float y_offset;
    float x_advance;
    float y_advance;
} Vo_Shaped_Glyph;

static Vo_Textshape_Font *vo_textshape_font(int font_kind) {
    if (font_kind < 0 || font_kind >= VO_TEXTSHAPE_MAX_FONTS) {
        return NULL;
    }
    if (vo_fonts[font_kind].hb_font == NULL) {
        return NULL;
    }
    return &vo_fonts[font_kind];
}

int vo_textshape_init(int font_kind, const char *font_path, float logical_height) {
    if (font_kind < 0 || font_kind >= VO_TEXTSHAPE_MAX_FONTS || font_path == NULL) {
        return 0;
    }
    Vo_Textshape_Font *font = &vo_fonts[font_kind];
    if (font->hb_font != NULL) {
        return 1;
    }
    if (vo_ft_library == NULL) {
        if (FT_Init_FreeType(&vo_ft_library) != 0) {
            return 0;
        }
    }
    if (FT_New_Face(vo_ft_library, font_path, 0, &font->face) != 0) {
        return 0;
    }
    if (FT_New_Face(vo_ft_library, font_path, 0, &font->render_face) != 0) {
        FT_Done_Face(font->face);
        font->face = NULL;
        return 0;
    }
    size_t path_len = 0;
    while (font_path[path_len] != '\0' && path_len + 1 < sizeof(font->path)) {
        font->path[path_len] = font_path[path_len];
        path_len += 1;
    }
    font->path[path_len] = '\0';
    int pixel_height = (int)(logical_height + 0.5f);
    if (pixel_height <= 0) {
        pixel_height = 16;
    }
    if (FT_Set_Char_Size(font->face, 0, pixel_height * 64, 72, 72) != 0) {
        FT_Done_Face(font->face);
        FT_Done_Face(font->render_face);
        font->face = NULL;
        font->render_face = NULL;
        return 0;
    }
    font->hb_font = hb_ft_font_create_referenced(font->face);
    return font->hb_font != NULL;
}

int vo_textshape_render_ascii_atlas(
    int font_kind,
    int glyph_first,
    int glyph_last,
    int pixel_height,
    int cell_width,
    int cell_height,
    int columns,
    uint8_t *out_rgba,
    int out_len
) {
    Vo_Textshape_Font *font = vo_textshape_font(font_kind);
    if (font == NULL || font->render_face == NULL || out_rgba == NULL || glyph_last < glyph_first || pixel_height <= 0 || cell_width <= 0 || cell_height <= 0 || columns <= 0) {
        return 0;
    }

    int glyph_count = glyph_last - glyph_first + 1;
    int rows = (glyph_count + columns - 1) / columns;
    int atlas_width = cell_width * columns;
    int atlas_height = cell_height * rows;
    int needed = atlas_width * atlas_height * 4;
    if (out_len < needed) {
        return 0;
    }

    for (int i = 0; i < needed; i += 4) {
        out_rgba[i + 0] = 255;
        out_rgba[i + 1] = 255;
        out_rgba[i + 2] = 255;
        out_rgba[i + 3] = 0;
    }

    if (FT_Set_Pixel_Sizes(font->render_face, 0, pixel_height) != 0) {
        return 0;
    }

    int baseline = (int)((font->render_face->size->metrics.ascender + 32) / 64);
    if (baseline <= 0 || baseline >= cell_height) {
        baseline = (int)((float)cell_height * 0.78f);
    }

    for (int codepoint = glyph_first; codepoint <= glyph_last; codepoint += 1) {
        int slot = codepoint - glyph_first;
        int cell_x = (slot % columns) * cell_width;
        int cell_y = (slot / columns) * cell_height;

        if (codepoint == ' ') {
            continue;
        }
        if (FT_Load_Char(font->render_face, (unsigned long)codepoint, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0) {
            continue;
        }

        FT_GlyphSlot glyph = font->render_face->glyph;
        FT_Bitmap *bitmap = &glyph->bitmap;
        int dst_origin_x = cell_x + glyph->bitmap_left;
        int dst_origin_y = cell_y + baseline - glyph->bitmap_top;

        for (int y = 0; y < (int)bitmap->rows; y += 1) {
            int dst_y = dst_origin_y + y;
            if (dst_y < cell_y || dst_y >= cell_y + cell_height) {
                continue;
            }
            for (int x = 0; x < (int)bitmap->width; x += 1) {
                int dst_x = dst_origin_x + x;
                if (dst_x < cell_x || dst_x >= cell_x + cell_width) {
                    continue;
                }
                uint8_t alpha = 0;
                if (bitmap->pixel_mode == FT_PIXEL_MODE_GRAY) {
                    alpha = bitmap->buffer[y * bitmap->pitch + x];
                } else if (bitmap->pixel_mode == FT_PIXEL_MODE_MONO) {
                    uint8_t byte = bitmap->buffer[y * bitmap->pitch + (x >> 3)];
                    alpha = (byte & (0x80 >> (x & 7))) ? 255 : 0;
                }
                int dst_i = (dst_y * atlas_width + dst_x) * 4;
                out_rgba[dst_i + 3] = alpha;
            }
        }
    }

    return 1;
}

float vo_textshape_width(int font_kind, const uint8_t *text, int len, float text_scale, float fallback_advance) {
    Vo_Textshape_Font *font = vo_textshape_font(font_kind);
    if (font == NULL || text == NULL || len <= 0) {
        if (len <= 0) {
            return 0.0f;
        }
        return fallback_advance * (float)len;
    }

    hb_buffer_t *buffer = hb_buffer_create();
    if (buffer == NULL) {
        return fallback_advance * (float)len;
    }

    hb_buffer_add_utf8(buffer, (const char *)text, len, 0, len);
    hb_buffer_guess_segment_properties(buffer);
    hb_shape(font->hb_font, buffer, NULL, 0);

    unsigned int glyph_count = 0;
    hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, &glyph_count);
    float width = 0.0f;
    for (unsigned int i = 0; i < glyph_count; i += 1) {
        width += (float)positions[i].x_advance / 64.0f;
    }

    hb_buffer_destroy(buffer);

    if (text_scale <= 0.0f) {
        text_scale = 1.0f;
    }
    return width * text_scale;
}

int vo_textshape_shape(int font_kind, const uint8_t *text, int len, float text_scale, Vo_Shaped_Glyph *out, int out_cap) {
    Vo_Textshape_Font *font = vo_textshape_font(font_kind);
    if (font == NULL || text == NULL || len <= 0 || out == NULL || out_cap <= 0) {
        return 0;
    }

    hb_buffer_t *buffer = hb_buffer_create();
    if (buffer == NULL) {
        return 0;
    }

    hb_feature_t features[3];
    hb_feature_from_string("liga=0", -1, &features[0]);
    hb_feature_from_string("clig=0", -1, &features[1]);
    hb_feature_from_string("calt=0", -1, &features[2]);

    hb_buffer_add_utf8(buffer, (const char *)text, len, 0, len);
    hb_buffer_guess_segment_properties(buffer);
    hb_shape(font->hb_font, buffer, features, 3);

    unsigned int glyph_count = 0;
    hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buffer, &glyph_count);
    hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, &glyph_count);

    int count = (int)glyph_count;
    if (count > out_cap) {
        count = out_cap;
    }
    if (text_scale <= 0.0f) {
        text_scale = 1.0f;
    }
    for (int i = 0; i < count; i += 1) {
        uint32_t glyph_id = infos[i].codepoint;
        if (infos[i].cluster < (uint32_t)len) {
            uint8_t source = text[infos[i].cluster];
            if (source >= 32 && source <= 126) {
                glyph_id = (uint32_t)source;
            }
        }
        out[i].glyph_id = glyph_id;
        out[i].x_offset = ((float)positions[i].x_offset / 64.0f) * text_scale;
        out[i].y_offset = ((float)positions[i].y_offset / 64.0f) * text_scale;
        out[i].x_advance = ((float)positions[i].x_advance / 64.0f) * text_scale;
        out[i].y_advance = ((float)positions[i].y_advance / 64.0f) * text_scale;
    }

    hb_buffer_destroy(buffer);
    return count;
}
