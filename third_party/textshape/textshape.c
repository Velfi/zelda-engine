#include <stdint.h>
#include <stddef.h>
#include <limits.h>
#include <stdlib.h>

#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>
#include <grapheme.h>
#include <SheenBidi/SheenBidi.h>

#define VO_TEXTSHAPE_MAX_FONTS 4
#define VO_TEXTSHAPE_MAX_FACES_PER_FONT 32

typedef struct Vo_Textshape_Font {
    FT_Face face;
    FT_Face render_face;
    hb_font_t *hb_font;
    char path[1024];
} Vo_Textshape_Font;

static FT_Library vo_ft_library = NULL;
static Vo_Textshape_Font vo_fonts[VO_TEXTSHAPE_MAX_FONTS];
static Vo_Textshape_Font vo_fallback_fonts[VO_TEXTSHAPE_MAX_FONTS][VO_TEXTSHAPE_MAX_FACES_PER_FONT - 1];
static int vo_fallback_counts[VO_TEXTSHAPE_MAX_FONTS];

typedef struct Vo_Shaped_Glyph {
    uint32_t glyph_id;
    uint32_t cluster;
    uint32_t cluster_end;
    uint16_t face_id;
    uint8_t direction;
    uint8_t missing;
    float x_offset;
    float y_offset;
    float x_advance;
    float y_advance;
} Vo_Shaped_Glyph;

typedef struct Vo_Raster_Glyph {
    int32_t width;
    int32_t height;
    int32_t left;
    int32_t top;
    int32_t advance_x;
} Vo_Raster_Glyph;

typedef struct Vo_Glyph_Bounds {
    int32_t min_x;
    int32_t max_x;
    int32_t ascent;
    int32_t descent;
} Vo_Glyph_Bounds;

static Vo_Textshape_Font *vo_textshape_font(int font_kind) {
    if (font_kind < 0 || font_kind >= VO_TEXTSHAPE_MAX_FONTS) {
        return NULL;
    }
    if (vo_fonts[font_kind].hb_font == NULL) {
        return NULL;
    }
    return &vo_fonts[font_kind];
}

static Vo_Textshape_Font *vo_textshape_face(int face_id) {
    int font_kind = face_id / VO_TEXTSHAPE_MAX_FACES_PER_FONT;
    int face_index = face_id % VO_TEXTSHAPE_MAX_FACES_PER_FONT;
    if (font_kind < 0 || font_kind >= VO_TEXTSHAPE_MAX_FONTS) {
        return NULL;
    }
    if (face_index == 0) {
        return vo_textshape_font(font_kind);
    }
    if (face_index > vo_fallback_counts[font_kind]) {
        return NULL;
    }
    Vo_Textshape_Font *font = &vo_fallback_fonts[font_kind][face_index - 1];
    return font->hb_font != NULL ? font : NULL;
}

static int vo_textshape_load_font(Vo_Textshape_Font *font, const char *font_path, float logical_height) {
    if (font == NULL || font_path == NULL) {
        return 0;
    }
    if (font->hb_font != NULL) {
        return 1;
    }
    if (vo_ft_library == NULL && FT_Init_FreeType(&vo_ft_library) != 0) {
        return 0;
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

int vo_textshape_init(int font_kind, const char *font_path, float logical_height) {
    if (font_kind < 0 || font_kind >= VO_TEXTSHAPE_MAX_FONTS || font_path == NULL) {
        return 0;
    }
    return vo_textshape_load_font(&vo_fonts[font_kind], font_path, logical_height);
}

int vo_textshape_add_fallback(int font_kind, const char *font_path, float logical_height) {
    if (font_kind < 0 || font_kind >= VO_TEXTSHAPE_MAX_FONTS || font_path == NULL) {
        return 0;
    }
    int index = vo_fallback_counts[font_kind];
    if (index >= VO_TEXTSHAPE_MAX_FACES_PER_FONT - 1) {
        return 0;
    }
    if (!vo_textshape_load_font(&vo_fallback_fonts[font_kind][index], font_path, logical_height)) {
        return 0;
    }
    vo_fallback_counts[font_kind] += 1;
    return 1;
}

int vo_textshape_ascii_glyph_bounds(
    int font_kind,
    int glyph_first,
    int glyph_last,
    int pixel_height,
    Vo_Glyph_Bounds *out
) {
    Vo_Textshape_Font *font = vo_textshape_font(font_kind);
    if (font == NULL || font->render_face == NULL || out == NULL || glyph_last < glyph_first || pixel_height <= 0) {
        return 0;
    }
    if (FT_Set_Pixel_Sizes(font->render_face, 0, pixel_height) != 0) {
        return 0;
    }

    int min_x = INT_MAX;
    int max_x = INT_MIN;
    int ascent = 0;
    int descent = 0;
    for (int codepoint = glyph_first; codepoint <= glyph_last; codepoint += 1) {
        if (codepoint == ' ') {
            continue;
        }
        if (FT_Load_Char(font->render_face, (unsigned long)codepoint, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0) {
            continue;
        }
        FT_GlyphSlot glyph = font->render_face->glyph;
        int glyph_min_x = glyph->bitmap_left;
        int glyph_max_x = glyph->bitmap_left + (int)glyph->bitmap.width;
        min_x = glyph_min_x < min_x ? glyph_min_x : min_x;
        max_x = glyph_max_x > max_x ? glyph_max_x : max_x;
        ascent = glyph->bitmap_top > ascent ? glyph->bitmap_top : ascent;
        int glyph_descent = (int)glyph->bitmap.rows - glyph->bitmap_top;
        descent = glyph_descent > descent ? glyph_descent : descent;
    }
    if (min_x == INT_MAX || max_x == INT_MIN) {
        return 0;
    }
    out->min_x = min_x;
    out->max_x = max_x;
    out->ascent = ascent;
    out->descent = descent;
    return 1;
}

int vo_textshape_render_ascii_atlas(
    int font_kind,
    int glyph_first,
    int glyph_last,
    int pixel_height,
    int cell_width,
    int cell_height,
    int columns,
    int origin_x,
    int baseline,
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
        int dst_origin_x = cell_x + origin_x + glyph->bitmap_left;
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

static int vo_codepoint_is_format(uint32_t codepoint) {
    return codepoint == 0x200C || codepoint == 0x200D ||
        (codepoint >= 0xFE00 && codepoint <= 0xFE0F) ||
        (codepoint >= 0xE0100 && codepoint <= 0xE01EF);
}

static int vo_face_supports_cluster(
    Vo_Textshape_Font *font,
    const uint8_t *text,
    int length
) {
    int cursor = 0;
    while (cursor < length) {
        uint_least32_t codepoint = GRAPHEME_INVALID_CODEPOINT;
        size_t consumed = grapheme_decode_utf8(
            (const char *)text + cursor,
            (size_t)(length - cursor),
            &codepoint
        );
        if (consumed == 0) {
            consumed = 1;
            codepoint = GRAPHEME_INVALID_CODEPOINT;
        }
        if (!vo_codepoint_is_format((uint32_t)codepoint) &&
            FT_Get_Char_Index(font->face, (FT_ULong)codepoint) == 0) {
            return 0;
        }
        cursor += (int)consumed;
    }
    return 1;
}

static int vo_cluster_face(int font_kind, const uint8_t *text, int length) {
    Vo_Textshape_Font *primary = vo_textshape_font(font_kind);
    if (primary != NULL && vo_face_supports_cluster(primary, text, length)) {
        return font_kind * VO_TEXTSHAPE_MAX_FACES_PER_FONT;
    }
    for (int index = 0; index < vo_fallback_counts[font_kind]; index += 1) {
        Vo_Textshape_Font *fallback = &vo_fallback_fonts[font_kind][index];
        if (vo_face_supports_cluster(fallback, text, length)) {
            return font_kind * VO_TEXTSHAPE_MAX_FACES_PER_FONT + index + 1;
        }
    }
    return font_kind * VO_TEXTSHAPE_MAX_FACES_PER_FONT;
}

typedef struct Vo_Text_Segment {
    int start;
    int length;
    int face_id;
} Vo_Text_Segment;

static int vo_shape_segment(
    const uint8_t *text,
    Vo_Text_Segment segment,
    int rtl,
    float text_scale,
    Vo_Shaped_Glyph *out,
    int out_cap
) {
    Vo_Textshape_Font *font = vo_textshape_face(segment.face_id);
    if (font == NULL || out_cap <= 0) {
        return 0;
    }
    hb_buffer_t *buffer = hb_buffer_create();
    if (buffer == NULL) {
        return 0;
    }
    hb_buffer_add_utf8(
        buffer,
        (const char *)text,
        segment.start + segment.length,
        segment.start,
        segment.length
    );
    hb_buffer_set_direction(buffer, rtl ? HB_DIRECTION_RTL : HB_DIRECTION_LTR);
    hb_buffer_guess_segment_properties(buffer);
    hb_shape(font->hb_font, buffer, NULL, 0);

    unsigned int glyph_count = 0;
    hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buffer, &glyph_count);
    hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, &glyph_count);
    int count = (int)glyph_count;
    if (count > out_cap) {
        count = out_cap;
    }
    for (int index = 0; index < count; index += 1) {
        uint32_t cluster = infos[index].cluster;
        size_t cluster_length = 1;
        if (cluster < (uint32_t)(segment.start + segment.length)) {
            cluster_length = grapheme_next_character_break_utf8(
                (const char *)text + cluster,
                (size_t)(segment.start + segment.length) - cluster
            );
            if (cluster_length == 0) {
                cluster_length = 1;
            }
        }
        out[index].glyph_id = infos[index].codepoint;
        out[index].cluster = cluster;
        out[index].cluster_end = cluster + (uint32_t)cluster_length;
        out[index].face_id = (uint16_t)segment.face_id;
        out[index].direction = (uint8_t)(rtl ? 2 : 1);
        out[index].missing = (uint8_t)(infos[index].codepoint == 0);
        out[index].x_offset = ((float)positions[index].x_offset / 64.0f) * text_scale;
        out[index].y_offset = ((float)positions[index].y_offset / 64.0f) * text_scale;
        out[index].x_advance = ((float)positions[index].x_advance / 64.0f) * text_scale;
        out[index].y_advance = ((float)positions[index].y_advance / 64.0f) * text_scale;
    }
    hb_buffer_destroy(buffer);
    return count;
}

static int vo_shape_run(
    int font_kind,
    const uint8_t *text,
    int start,
    int length,
    int rtl,
    float text_scale,
    Vo_Shaped_Glyph *out,
    int out_cap
) {
    int end = start + length;
    int cursor = start;
    int segment_count = 0;
    int segment_cap = length > 0 ? length : 1;
    Vo_Text_Segment *segments = (Vo_Text_Segment *)malloc(
        sizeof(Vo_Text_Segment) * (size_t)segment_cap
    );
    if (segments == NULL) {
        return 0;
    }
    while (cursor < end) {
        size_t cluster_length = grapheme_next_character_break_utf8(
            (const char *)text + cursor,
            (size_t)(end - cursor)
        );
        if (cluster_length == 0) {
            cluster_length = 1;
        }
        int face_id = vo_cluster_face(font_kind, text + cursor, (int)cluster_length);
        if (segment_count > 0 &&
            segments[segment_count - 1].face_id == face_id &&
            segments[segment_count - 1].start + segments[segment_count - 1].length == cursor) {
            segments[segment_count - 1].length += (int)cluster_length;
        } else {
            segments[segment_count++] = (Vo_Text_Segment){cursor, (int)cluster_length, face_id};
        }
        cursor += (int)cluster_length;
    }

    int count = 0;
    for (int visual = 0; visual < segment_count && count < out_cap; visual += 1) {
        int index = rtl ? segment_count - visual - 1 : visual;
        count += vo_shape_segment(
            text,
            segments[index],
            rtl,
            text_scale,
            out + count,
            out_cap - count
        );
    }
    free(segments);
    return count;
}

int vo_textshape_shape_ex(
    int font_kind,
    const uint8_t *text,
    int len,
    float text_scale,
    int base_direction,
    Vo_Shaped_Glyph *out,
    int out_cap
) {
    if (font_kind < 0 || font_kind >= VO_TEXTSHAPE_MAX_FONTS ||
        vo_textshape_font(font_kind) == NULL || text == NULL || len <= 0 ||
        out == NULL || out_cap <= 0) {
        return 0;
    }
    if (text_scale <= 0.0f) {
        text_scale = 1.0f;
    }
    SBCodepointSequence sequence = {
        SBStringEncodingUTF8,
        text,
        (SBUInteger)len,
    };
    SBAlgorithmRef algorithm = SBAlgorithmCreate(&sequence);
    if (algorithm == NULL) {
        return vo_shape_run(font_kind, text, 0, len, 0, text_scale, out, out_cap);
    }
    SBLevel base_level = SBLevelDefaultLTR;
    if (base_direction == 1) {
        base_level = 0;
    } else if (base_direction == 2) {
        base_level = 1;
    }
    SBParagraphRef paragraph = SBAlgorithmCreateParagraph(
        algorithm,
        0,
        (SBUInteger)len,
        base_level
    );
    if (paragraph == NULL) {
        SBAlgorithmRelease(algorithm);
        return vo_shape_run(font_kind, text, 0, len, 0, text_scale, out, out_cap);
    }
    SBLineRef line = SBParagraphCreateLine(paragraph, 0, (SBUInteger)len);
    int count = 0;
    if (line != NULL) {
        SBUInteger run_count = SBLineGetRunCount(line);
        const SBRun *runs = SBLineGetRunsPtr(line);
        for (SBUInteger index = 0; index < run_count && count < out_cap; index += 1) {
            count += vo_shape_run(
                font_kind,
                text,
                (int)runs[index].offset,
                (int)runs[index].length,
                (runs[index].level & 1) != 0,
                text_scale,
                out + count,
                out_cap - count
            );
        }
        SBLineRelease(line);
    }
    SBParagraphRelease(paragraph);
    SBAlgorithmRelease(algorithm);
    return count;
}

int vo_textshape_shape(
    int font_kind,
    const uint8_t *text,
    int len,
    float text_scale,
    Vo_Shaped_Glyph *out,
    int out_cap
) {
    return vo_textshape_shape_ex(font_kind, text, len, text_scale, 0, out, out_cap);
}

float vo_textshape_width(int font_kind, const uint8_t *text, int len, float text_scale, float fallback_advance) {
    if (text == NULL || len <= 0) {
        return 0.0f;
    }
    Vo_Shaped_Glyph *glyphs = (Vo_Shaped_Glyph *)malloc(sizeof(Vo_Shaped_Glyph) * (size_t)len);
    if (glyphs == NULL) {
        return fallback_advance * (float)len;
    }
    int count = vo_textshape_shape(font_kind, text, len, text_scale, glyphs, len);
    float width = 0.0f;
    for (int index = 0; index < count; index += 1) {
        width += glyphs[index].x_advance;
    }
    free(glyphs);
    return count > 0 ? width : fallback_advance * (float)len;
}

int vo_textshape_rasterize_glyph(
    int face_id,
    uint32_t glyph_id,
    int pixel_height,
    uint8_t *out_alpha,
    int out_cap,
    Vo_Raster_Glyph *out
) {
    Vo_Textshape_Font *font = vo_textshape_face(face_id);
    if (font == NULL || out == NULL || pixel_height <= 0 ||
        FT_Set_Pixel_Sizes(font->render_face, 0, pixel_height) != 0 ||
        FT_Load_Glyph(font->render_face, (FT_UInt)glyph_id, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0) {
        return 0;
    }
    FT_GlyphSlot glyph = font->render_face->glyph;
    FT_Bitmap *bitmap = &glyph->bitmap;
    int needed = (int)bitmap->width * (int)bitmap->rows;
    out->width = (int32_t)bitmap->width;
    out->height = (int32_t)bitmap->rows;
    out->left = glyph->bitmap_left;
    out->top = glyph->bitmap_top;
    out->advance_x = (int32_t)(glyph->advance.x / 64);
    if (needed == 0) {
        return 1;
    }
    if (out_alpha == NULL || out_cap < needed) {
        return -needed;
    }
    for (int y = 0; y < (int)bitmap->rows; y += 1) {
        for (int x = 0; x < (int)bitmap->width; x += 1) {
            uint8_t alpha = 0;
            if (bitmap->pixel_mode == FT_PIXEL_MODE_GRAY) {
                alpha = bitmap->buffer[y * bitmap->pitch + x];
            } else if (bitmap->pixel_mode == FT_PIXEL_MODE_MONO) {
                uint8_t byte = bitmap->buffer[y * bitmap->pitch + (x >> 3)];
                alpha = (byte & (0x80 >> (x & 7))) ? 255 : 0;
            }
            out_alpha[y * (int)bitmap->width + x] = alpha;
        }
    }
    return needed;
}

int vo_textshape_next_grapheme(const uint8_t *text, int len) {
    if (text == NULL || len <= 0) {
        return 0;
    }
    size_t result = grapheme_next_character_break_utf8((const char *)text, (size_t)len);
    return result > (size_t)INT_MAX ? len : (int)result;
}

int vo_textshape_next_word(const uint8_t *text, int len) {
    if (text == NULL || len <= 0) {
        return 0;
    }
    size_t result = grapheme_next_word_break_utf8((const char *)text, (size_t)len);
    return result > (size_t)INT_MAX ? len : (int)result;
}

int vo_textshape_next_line_break(const uint8_t *text, int len) {
    if (text == NULL || len <= 0) {
        return 0;
    }
    size_t result = grapheme_next_line_break_utf8((const char *)text, (size_t)len);
    return result > (size_t)INT_MAX ? len : (int)result;
}
