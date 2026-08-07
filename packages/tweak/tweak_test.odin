#+test
package tweak

import "core:math"
import "core:reflect"
import "core:strings"
import "core:testing"
import "core:time"

import "base:intrinsics"
import "base:runtime"
import "zelda_engine:toml"

Vec4 :: #simd[4]f32
Color :: [4]f32
Local_Enum :: enum u8 {
    alpha,
    beta,
}
Local_Maybe_Enum :: union {
    Local_Enum,
}
Local_Tag_A :: distinct struct{}
Local_Tag_B :: distinct struct{}
Local_Macroish :: union #no_nil {
    Local_Tag_A,
    Local_Tag_B,
    Local_Enum,
}

Versioned :: struct {
    version: i64,
}

No_Version :: struct {
    enabled: bool,
}

@(test)
encode_struct_fields_reuses_existing_key :: proc(t: ^testing.T) {
    table := new(toml.Table, context.allocator)
    table[strings.clone("version", context.allocator)] = i64(1)
    defer toml.deep_delete(table, context.allocator)

    value := Versioned {
        version = 2,
    }
    testing.expect(t, encode_struct_fields(table, reflect.deref(any(&value)), context.allocator))
    testing.expect_value(t, len(table), 1)
    testing.expect_value(t, table["version"], toml.Type(i64(2)))
}

@(test)
generated_table_owns_seeded_version_key :: proc(t: ^testing.T) {
    table := new(toml.Table, context.allocator)
    table[strings.clone("version", context.allocator)] = i64(1)

    value := No_Version {
        enabled = true,
    }
    testing.expect(t, encode_struct_fields(table, reflect.deref(any(&value)), context.allocator))
    testing.expect(t, toml.deep_delete(table, context.allocator) == .None)
}

Meta_Parse_Spec :: struct {
    range_no_speed:  f32 `tweak:"range=0..1"`,
    constants:       f32 `tweak:"range=-PI..TAU;E"`,
    explicit:        f32 `tweak:"range=-5..10;0.25"`,
    speed_only:      f32 `tweak:"range=;0.05"`,
    lower_only:      int `tweak:"range=-7.."`,
    upper_only:      int `tweak:"range=..42"`,
    duration_ms:     time.Duration `tweak:"range=0..30000;10ms"`,
    duration_minute: time.Duration `tweak:"range=1..240;1minute"`,
    color:           Color `tweak:"widget=color"`,
}

meta_parse_field :: proc(name: string) -> (meta: Field_Meta, ok: bool) {
    for field in reflect.struct_fields_zipped(typeid_of(Meta_Parse_Spec)) {
        if field.name != name do continue
        return field_meta(field), true
    }
    return {}, false
}

@(test)
encode_small_array_uses_axis_names :: proc(t: ^testing.T) {
    value: [2]f32 = {1, 2}

    encoded, ok := encode_value(any(&value), context.allocator, {})
    testing.expect(t, ok)

    table, table_ok := encoded.(^toml.Table)
    testing.expect(t, table_ok)
    if !table_ok do return
    defer toml.deep_delete(table, context.allocator)

    x, x_ok := table["x"].(f64)
    y, y_ok := table["y"].(f64)
    testing.expect(t, x_ok)
    testing.expect(t, y_ok)
    testing.expect_value(t, x, 1.0)
    testing.expect_value(t, y, 2.0)
}

@(test)
decode_small_array_accepts_axis_names :: proc(t: ^testing.T) {
    table := new(toml.Table, context.allocator)
    table[strings.clone("x", context.allocator)] = f64(3)
    table[strings.clone("y", context.allocator)] = f64(4)
    defer toml.deep_delete(table, context.allocator)

    value: [2]f32
    testing.expect(t, process_value(any(&value), table, context.allocator, {}, true) == .None)
    testing.expect_value(t, value[0], 3.0)
    testing.expect_value(t, value[1], 4.0)
}

@(test)
decode_small_array_still_accepts_lists :: proc(t: ^testing.T) {
    list := new(toml.List, context.allocator)
    append(list, i64(7))
    append(list, i64(8))
    defer toml.deep_delete(list, context.allocator)

    value: [2]int
    testing.expect(t, process_value(any(&value), list, context.allocator, {}, true) == .None)
    testing.expect_value(t, value[0], 7)
    testing.expect_value(t, value[1], 8)
}

@(test)
encode_simd_vector_uses_axis_names :: proc(t: ^testing.T) {
    value: Vec4 = {1, 2, 3, 4}

    encoded, ok := encode_value(any(&value), context.allocator, {})
    testing.expect(t, ok)

    table, table_ok := encoded.(^toml.Table)
    testing.expect(t, table_ok)
    if !table_ok do return
    defer toml.deep_delete(table, context.allocator)

    w, w_ok := table["w"].(f64)
    testing.expect(t, w_ok)
    testing.expect_value(t, w, 4.0)
}

@(test)
decode_simd_vector_accepts_axis_names :: proc(t: ^testing.T) {
    table := new(toml.Table, context.allocator)
    table[strings.clone("x", context.allocator)] = f64(9)
    table[strings.clone("y", context.allocator)] = f64(8)
    table[strings.clone("z", context.allocator)] = f64(7)
    table[strings.clone("w", context.allocator)] = f64(6)
    defer toml.deep_delete(table, context.allocator)

    value: Vec4
    testing.expect(t, process_value(any(&value), table, context.allocator, {}, true) == .None)
    testing.expect_value(t, intrinsics.simd_extract(value, 0), f32(9))
    testing.expect_value(t, intrinsics.simd_extract(value, 1), f32(8))
    testing.expect_value(t, intrinsics.simd_extract(value, 2), f32(7))
    testing.expect_value(t, intrinsics.simd_extract(value, 3), f32(6))
}

@(test)
dye_color_round_trip_uses_rgba_axes :: proc(t: ^testing.T) {
    expected: Color = {0.2, 0.45, 0.8, 0.35}
    encoded, ok := encode_value(any(&expected), context.allocator, {widget = "color"})
    testing.expect(t, ok)

    table, table_ok := encoded.(^toml.Table)
    testing.expect(t, table_ok)
    if !table_ok do return
    defer toml.deep_delete(table, context.allocator)

    x, x_ok := table["x"].(f64)
    y, y_ok := table["y"].(f64)
    z, z_ok := table["z"].(f64)
    w, w_ok := table["w"].(f64)
    testing.expect(t, x_ok)
    testing.expect(t, y_ok)
    testing.expect(t, z_ok)
    testing.expect(t, w_ok)
    testing.expect_value(t, x, f64(expected[0]))
    testing.expect_value(t, y, f64(expected[1]))
    testing.expect_value(t, z, f64(expected[2]))
    testing.expect_value(t, w, f64(expected[3]))

    actual: Color
    testing.expect(t, process_value(any(&actual), table, context.allocator, {widget = "color"}, true) == .None)
    testing.expect_value(t, actual, expected)
}

@(test)
dye_color_field_parses_color_widget_metadata :: proc(t: ^testing.T) {
    meta, ok := meta_parse_field("color")
    testing.expect(t, ok)
    testing.expect_value(t, meta.widget, "color")
}

@(test)
range_tag_parses_bounds_without_implied_speed :: proc(t: ^testing.T) {
    meta, ok := meta_parse_field("range_no_speed")
    testing.expect(t, ok)
    testing.expect(t, .has_min in meta.flags)
    testing.expect(t, .has_max in meta.flags)
    testing.expect_value(t, meta.min, 0.0)
    testing.expect_value(t, meta.max, 1.0)
    testing.expect(t, .has_speed not_in meta.flags)
}

@(test)
range_tag_parses_explicit_speed_and_open_bounds :: proc(t: ^testing.T) {
    constants, constants_ok := meta_parse_field("constants")
    explicit, explicit_ok := meta_parse_field("explicit")
    lower_only, lower_ok := meta_parse_field("lower_only")
    upper_only, upper_ok := meta_parse_field("upper_only")
    speed_only, speed_only_ok := meta_parse_field("speed_only")
    duration_ms, duration_ms_ok := meta_parse_field("duration_ms")
    duration_minute, duration_minute_ok := meta_parse_field("duration_minute")

    testing.expect(t, constants_ok)
    testing.expect(t, explicit_ok)
    testing.expect(t, lower_ok)
    testing.expect(t, upper_ok)
    testing.expect(t, speed_only_ok)
    testing.expect(t, duration_ms_ok)
    testing.expect(t, duration_minute_ok)

    testing.expect_value(t, constants.min, -math.PI)
    testing.expect_value(t, constants.max, math.TAU)
    testing.expect_value(t, constants.speed, _META_E)

    testing.expect_value(t, explicit.min, -5.0)
    testing.expect_value(t, explicit.max, 10.0)
    testing.expect_value(t, explicit.speed, 0.25)

    testing.expect(t, .has_min in lower_only.flags)
    testing.expect(t, .has_max not_in lower_only.flags)
    testing.expect_value(t, lower_only.min, -7.0)

    testing.expect(t, .has_min not_in upper_only.flags)
    testing.expect(t, .has_max in upper_only.flags)
    testing.expect_value(t, upper_only.max, 42.0)

    testing.expect(t, .has_min not_in speed_only.flags)
    testing.expect(t, .has_max not_in speed_only.flags)
    testing.expect(t, .has_speed in speed_only.flags)
    testing.expect_value(t, speed_only.speed, 0.05)

    testing.expect(t, .has_speed in duration_ms.flags)
    testing.expect_value(t, duration_ms.speed, 10.0)
    testing.expect_value(t, duration_ms.unit, "ms")

    testing.expect(t, .has_speed in duration_minute.flags)
    testing.expect_value(t, duration_minute.speed, 1.0)
    testing.expect_value(t, duration_minute.unit, "min")
}

@(test)
supported_union_strings_round_trip :: proc(t: ^testing.T) {
    maybe_value: Local_Maybe_Enum
    macro_value: Local_Macroish

    testing.expect(t, process_value(any(&maybe_value), "beta", context.allocator, {}, true) == .None)
    maybe_encoded, maybe_ok := encode_value(any(&maybe_value), context.allocator, {})
    testing.expect(t, maybe_ok)
    maybe_raw, maybe_raw_ok := maybe_encoded.(string)
    testing.expect(t, maybe_raw_ok)
    if maybe_raw_ok do defer delete_string(maybe_raw)
    testing.expect_value(t, maybe_raw, "beta")

    testing.expect(t, process_value(any(&maybe_value), "", context.allocator, {}, true) == .None)
    maybe_nil_encoded, maybe_nil_ok := encode_value(any(&maybe_value), context.allocator, {})
    testing.expect(t, maybe_nil_ok)
    maybe_nil_raw, maybe_nil_raw_ok := maybe_nil_encoded.(string)
    testing.expect(t, maybe_nil_raw_ok)
    if maybe_nil_raw_ok do defer delete_string(maybe_nil_raw)
    testing.expect_value(t, maybe_nil_raw, "")

    testing.expect(t, process_value(any(&macro_value), "Local_Tag_A{}", context.allocator, {}, true) == .None)
    tag_encoded, tag_ok := encode_value(any(&macro_value), context.allocator, {})
    testing.expect(t, tag_ok)
    tag_raw, tag_raw_ok := tag_encoded.(string)
    testing.expect(t, tag_raw_ok)
    if tag_raw_ok do defer delete_string(tag_raw)
    testing.expect_value(t, tag_raw, "Local_Tag_A{}")

    testing.expect(t, process_value(any(&macro_value), "Local_Tag_B", context.allocator, {}, true) == .None)
    short_tag_encoded, short_tag_ok := encode_value(any(&macro_value), context.allocator, {})
    testing.expect(t, short_tag_ok)
    short_tag_raw, short_tag_raw_ok := short_tag_encoded.(string)
    testing.expect(t, short_tag_raw_ok)
    if short_tag_raw_ok do defer delete_string(short_tag_raw)
    testing.expect_value(t, short_tag_raw, "Local_Tag_B{}")

    testing.expect(t, process_value(any(&macro_value), "alpha", context.allocator, {}, true) == .None)
    enum_encoded, enum_ok := encode_value(any(&macro_value), context.allocator, {})
    testing.expect(t, enum_ok)
    enum_raw, enum_raw_ok := enum_encoded.(string)
    testing.expect(t, enum_raw_ok)
    if enum_raw_ok do defer delete_string(enum_raw)
    testing.expect_value(t, enum_raw, "alpha")
}

@(test)
encode_duration_stays_raw_i64_even_with_unit_meta :: proc(t: ^testing.T) {
    value := 250 * time.Millisecond

    encoded, ok := encode_value(any(&value), context.allocator, Field_Meta{unit = "ms"})
    testing.expect(t, ok)

    raw, raw_ok := encoded.(i64)
    testing.expect(t, raw_ok)
    testing.expect_value(t, raw, i64(value))
}

@(test)
decode_duration_accepts_raw_i64_even_with_unit_meta :: proc(t: ^testing.T) {
    raw := i64(250 * time.Millisecond)
    value: time.Duration

    testing.expect(t, process_value(any(&value), raw, context.allocator, {unit = "ms"}, true) == .None)
    testing.expect_value(t, i64(value), raw)
}
