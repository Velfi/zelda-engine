package tweak

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"

import "zelda_engine:toml"
import "base:runtime"
import "zelda_engine:spy"

Err :: Maybe(string)

Load_Result :: struct {
    loaded_sections:  int,
    skipped_sections: int,
    notes:            [dynamic]string,
}

_META_E :: 2.71828182845904523536028747135266250

Field_Meta_Flag :: enum u8 {
    has_min,
    has_max,
    has_speed,
    readonly,
    multiline,
    collapsed,
}

Field_Meta_Flags :: bit_set[Field_Meta_Flag;u8]

Field_Meta :: struct {
    label:  string,
    widget: string,
    codec:  string,
    unit:   string,
    format: string,
    min:    f64,
    max:    f64,
    speed:  f64,
    flags:  Field_Meta_Flags,
}

destroy_load_result :: proc(r: ^Load_Result) {
    delete(r.notes)
}

load :: proc(path: string, version: i64, root: ^$T, label: string, after_load: proc() = nil) -> (res: Load_Result) {
    defer if len(res.notes) > 0 do for n in res.notes do spy.warn(n)

    data, read_err := read_tweak_file(path, context.temp_allocator)
    if read_err == .Not_Exist {
        append(&res.notes, fmt.tprintf("%s: %s not found, using defaults", label, path))
        return res
    }
    if read_err != nil {
        append(&res.notes, fmt.tprintf("%s: read %s failed: %v", label, path, read_err))
        return res
    }
    if len(data) == 0 {
        append(&res.notes, fmt.tprintf("%s: %s empty, using defaults", label, path))
        return res
    }

    table, parse_err := toml.parse(string(data), path, context.temp_allocator)
    if parse_err.type != .None {
        append(
            &res.notes,
            fmt.tprintf(
                "%s: %s parse error line %d (%v) — using defaults",
                label,
                path,
                parse_err.line + 1,
                parse_err.type,
            ),
        )
        if table != nil do toml.deep_delete(table, context.temp_allocator)
        return res
    }
    defer toml.deep_delete(table, context.temp_allocator)

    if version != 0 {
        if found_version, ok := table["version"].(i64); ok && found_version != version {
            append(&res.notes, fmt.tprintf("%s: %s version %d != expected %d", label, path, found_version, version))
        }
    }

    root_any := reflect.deref(any(root))
    fields := reflect.struct_fields_zipped(root_any.id)
    for field in fields {
        if field.name == "_" do continue

        name := field_name(field)
        if name == "" do continue

        value, present := table[name]
        if !present do continue

        field_any := reflect.struct_field_value(root_any, field)
        meta := field_meta(field)
        if err := process_value(field_any, value, context.allocator, meta, false); err != .None {
            append(&res.notes, fmt.tprintf("%s: %s malformed: %v", label, name, err))
            res.skipped_sections += 1
            continue
        }
        if err := process_value(field_any, value, context.allocator, meta, true); err != .None {
            append(&res.notes, fmt.tprintf("%s: %s malformed: %v", label, name, err))
            res.skipped_sections += 1
            continue
        }
        res.loaded_sections += 1
    }

    if after_load != nil do after_load()
    return res
}

save :: proc(path: string, version: i64, root: ^$T) -> (err: Err) {
    // Saving also runs from an app-scope defer, after the final frame has
    // cleared its temporary arena. Use the ordinary allocator so deep_delete
    // releases the complete encoded tree instead of retaining its map storage
    // until a temporary-arena reset that will never happen.
    alloc := context.allocator
    table := new(toml.Table, alloc)
    table[strings.clone("version", alloc)] = version

    root_any := reflect.deref(any(root))
    if !encode_struct_fields(table, root_any, alloc) {
        defer toml.deep_delete(table, alloc)
        return fmt.tprintf("encode %s failed", path)
    }
    defer toml.deep_delete(table, alloc)

    encoded := toml.emit(table)
    defer delete_string(encoded)

    if write_err := write_tweak_file(path, transmute([]u8)encoded); write_err != nil {
        return fmt.tprintf("write %s failed: %v", path, write_err)
    }
    return nil
}

field_name :: proc(field: reflect.Struct_Field) -> string {
    tag_value := reflect.struct_tag_get(field.tag, "toml")
    toml_name, _ := toml_name_from_tag_value(tag_value)
    if toml_name == "-" do return ""
    if toml_name != "" do return toml_name
    return field.name
}

field_meta :: proc(field: reflect.Struct_Field) -> (meta: Field_Meta) {
    meta.label = field_name(field)

    tag_value := reflect.struct_tag_get(field.tag, "tweak")
    if tag_value == "" do return meta

    for raw_part in strings.split(tag_value, ",", context.temp_allocator) {
        part := strings.trim_space(raw_part)
        if part == "" do continue

        key := part
        val := ""
        if eq := strings.index_byte(part, '='); eq >= 0 {
            key = strings.trim_space(part[:eq])
            val = strings.trim_space(part[eq + 1:])
        }

        switch key {
        case "label":
            meta.label = val
        case "widget":
            meta.widget = val
        case "codec":
            meta.codec = val
        case "unit":
            meta.unit = val
        case "format":
            meta.format = val
        case "range":
            parse_range_meta(&meta, val)
        case "readonly":
            if val == "" || val == "true" do meta.flags += {.readonly}
        case "multiline":
            if val == "" || val == "true" do meta.flags += {.multiline}
        case "collapsed":
            if val == "" || val == "true" do meta.flags += {.collapsed}
        }
    }

    return meta
}

parse_range_meta :: proc(meta: ^Field_Meta, value: string) {
    range_text := strings.trim_space(value)
    speed_text := ""
    if sep := strings.index(value, ";"); sep >= 0 {
        range_text = strings.trim_space(value[:sep])
        speed_text = strings.trim_space(value[sep + 1:])
    }

    if speed_text != "" {
        if parsed, unit, ok := parse_meta_speed(speed_text); ok {
            meta.speed = parsed
            meta.flags += {.has_speed}
            if meta.unit == "" && unit != "" do meta.unit = unit
        }
    }

    if range_text == "" do return
    if dots := strings.index(range_text, ".."); dots >= 0 {
        min_text := strings.trim_space(range_text[:dots])
        max_text := strings.trim_space(range_text[dots + 2:])

        if min_text != "" {
            if parsed, ok := parse_meta_scalar(min_text); ok {
                meta.min = parsed
                meta.flags += {.has_min}
            }
        }
        if max_text != "" {
            if parsed, ok := parse_meta_scalar(max_text); ok {
                meta.max = parsed
                meta.flags += {.has_max}
            }
        }
    }
}

parse_meta_speed :: proc(value: string) -> (parsed: f64, unit: string, ok: bool) {
    token := strings.trim_space(value)
    if token == "" do return 0, "", false

    if parsed, ok = parse_meta_scalar(token); ok {
        return parsed, "", true
    }

    if parsed, unit, ok = parse_meta_duration_scalar(token); ok {
        return parsed, unit, true
    }

    return 0, "", false
}

parse_meta_scalar :: proc(value: string) -> (parsed: f64, ok: bool) {
    token := strings.trim_space(value)
    if token == "" do return 0, false

    sign := 1.0
    if token[0] == '+' {
        token = strings.trim_space(token[1:])
    } else if token[0] == '-' {
        sign = -1
        token = strings.trim_space(token[1:])
    }

    if token == "" do return 0, false
    if parsed, ok = strconv.parse_f64(token); ok {
        return sign * parsed, true
    }

    switch {
    case strings.equal_fold(token, "PI"):
        return sign * math.PI, true
    case strings.equal_fold(token, "TAU"):
        return sign * math.TAU, true
    case strings.equal_fold(token, "E"):
        return sign * _META_E, true
    }

    return 0, false
}

parse_meta_duration_scalar :: proc(value: string) -> (parsed: f64, unit: string, ok: bool) {
    aliases: [][2]string = {
        {"nanoseconds", "ns"},
        {"nanosecond", "ns"},
        {"microseconds", "us"},
        {"microsecond", "us"},
        {"milliseconds", "ms"},
        {"millisecond", "ms"},
        {"minutes", "min"},
        {"minute", "min"},
        {"seconds", "s"},
        {"second", "s"},
        {"hours", "h"},
        {"hour", "h"},
        {"min", "min"},
        {"ns", "ns"},
        {"us", "us"},
        {"ms", "ms"},
        {"s", "s"},
        {"m", "min"},
        {"h", "h"},
    }

    token := strings.trim_space(value)
    for alias in aliases {
        suffix, canonical := alias[0], alias[1]
        if len(token) <= len(suffix) do continue
        start := len(token) - len(suffix)
        if !strings.equal_fold(token[start:], suffix) do continue
        if parsed, ok = parse_meta_scalar(token[:start]); ok {
            return parsed, canonical, true
        }
    }

    return 0, "", false
}

toml_name_from_tag_value :: proc(value: string) -> (toml_name, extra: string) {
    toml_name = value
    if comma_idx := strings.index_byte(toml_name, ','); comma_idx >= 0 {
        toml_name = toml_name[:comma_idx]
        extra = value[comma_idx + 1:]
    }
    return
}

_AXIS_NAMES :: [4]string{"x", "y", "z", "w"}

sequence_uses_axes :: proc(count: int) -> bool {
    return count >= 2 && count <= len(_AXIS_NAMES)
}

sequence_axis_name :: proc(index: int) -> string {
    switch index {
    case 0:
        return _AXIS_NAMES[0]
    case 1:
        return _AXIS_NAMES[1]
    case 2:
        return _AXIS_NAMES[2]
    case 3:
        return _AXIS_NAMES[3]
    }
    return fmt.tprintf("[%d]", index)
}

simd_lane_value :: proc(value: any, info: reflect.Type_Info_Simd_Vector, index: int) -> any {
    if index < 0 || index >= info.count do return nil
    offset := uintptr(info.elem_size * index)
    data := rawptr(uintptr(value.data) + offset)
    return {data, info.elem.id}
}

encode_struct_fields :: proc(table: ^toml.Table, value: any, alloc := context.allocator) -> (ok: bool) {
    ti := reflect.type_info_base(type_info_of(value.id))
    _, is_struct := ti.variant.(reflect.Type_Info_Struct)
    if !is_struct do return false

    for field in reflect.struct_fields_zipped(value.id) {
        if field.name == "_" do continue

        name := field_name(field)
        if name == "" do continue

        field_value := reflect.struct_field_value(value, field)
        encoded, encoded_ok := encode_value(field_value, alloc, field_meta(field))
        if !encoded_ok do return false
        if previous, present := table[name]; present {
            table[name] = encoded
            if toml.deep_delete(previous, alloc) != .None {
                return false
            }
        } else {
            table[strings.clone(name, alloc)] = encoded
        }
    }
    return true
}

encode_value :: proc(value: any, alloc: runtime.Allocator, meta: Field_Meta) -> (result: toml.Type, ok: bool) {
    if value == nil || value.id == nil do return nil, false

    current := value
    ti := reflect.type_info_base(type_info_of(current.id))
    if p, is_pointer := ti.variant.(reflect.Type_Info_Pointer); is_pointer {
        if current.data == nil do return nil, false
        current = reflect.deref(current)
        ti = reflect.type_info_base(type_info_of(current.id))
        _ = p
    }

    if meta.codec != "" {
        if encoded, handled, encoded_ok := encode_codec_value(current, meta.codec, alloc); handled {
            return encoded, encoded_ok
        }
    }

    if _, is_union := ti.variant.(reflect.Type_Info_Union); is_union {
        if encoded, handled, encoded_ok := encode_union_string_value(current, alloc); handled {
            return encoded, encoded_ok
        }
    }

    if info, is_enum := ti.variant.(reflect.Type_Info_Enum); is_enum {
        raw := core_any(current)
        enum_value, enum_ok := any_get_i64(raw)
        if !enum_ok do return nil, false
        for enum_name, idx in info.names {
            if i64(info.values[idx]) == enum_value {
                return strings.clone(enum_name, alloc), true
            }
        }
        return nil, false
    }

    if str_value, is_string := current.(string); is_string {
        return strings.clone(str_value, alloc), true
    }

    if bool_value, bool_ok := any_get_bool(core_any(current)); bool_ok && is_boolean_like(current) {
        return bool_value, true
    }

    if float_value, float_ok := any_get_f64(core_any(current)); float_ok && is_float_like(current) {
        return float_value, true
    }

    if int_value, int_ok := any_get_i64(core_any(current)); int_ok && is_integer_like(current) {
        return int_value, true
    }

    #partial switch info in ti.variant {
    case reflect.Type_Info_Struct:
        table := new(toml.Table, alloc)
        if !encode_struct_fields(table, current, alloc) {
            toml.deep_delete(table, alloc)
            return nil, false
        }
        return table, true

    case reflect.Type_Info_Array:
        if sequence_uses_axes(info.count) {
            return encode_axis_array(current, info.count, alloc, meta)
        }
        return encode_regular_array(current, info.elem, info.count, alloc, meta)

    case reflect.Type_Info_Enumerated_Array:
        return encode_enumerated_array(current, info.elem, info.index.id, info.count, alloc, meta)

    case reflect.Type_Info_Simd_Vector:
        if sequence_uses_axes(info.count) {
            return encode_axis_simd_vector(current, info, alloc, meta)
        }
        return encode_regular_simd_vector(current, info, alloc, meta)
    }

    return nil, false
}

encode_regular_array :: proc(
    value: any,
    elem: ^reflect.Type_Info,
    count: int,
    alloc: runtime.Allocator,
    meta: Field_Meta,
) -> (
    result: toml.Type,
    ok: bool,
) {
    list := new(toml.List, alloc)
    for i in 0 ..< count {
        elem_value := reflect.index(value, i)
        encoded, encoded_ok := encode_value(elem_value, alloc, meta)
        if !encoded_ok {
            toml.deep_delete(list, alloc)
            return nil, false
        }
        append(list, encoded)
    }
    return list, true
}

encode_axis_array :: proc(
    value: any,
    count: int,
    alloc: runtime.Allocator,
    meta: Field_Meta,
) -> (
    result: toml.Type,
    ok: bool,
) {
    table := new(toml.Table, alloc)
    for i in 0 ..< count {
        elem_value := reflect.index(value, i)
        encoded, encoded_ok := encode_value(elem_value, alloc, meta)
        if !encoded_ok {
            toml.deep_delete(table, alloc)
            return nil, false
        }
        table[strings.clone(sequence_axis_name(i), alloc)] = encoded
    }
    return table, true
}

encode_enumerated_array :: proc(
    value: any,
    elem: ^reflect.Type_Info,
    index_type: typeid,
    count: int,
    alloc: runtime.Allocator,
    meta: Field_Meta,
) -> (
    result: toml.Type,
    ok: bool,
) {
    table := new(toml.Table, alloc)
    names := tweak_enum_info(index_type).names
    for i in 0 ..< min(count, len(names)) {
        elem_value := reflect.index(value, i)
        encoded, encoded_ok := encode_value(elem_value, alloc, meta)
        if !encoded_ok {
            toml.deep_delete(table, alloc)
            return nil, false
        }
        table[strings.clone(names[i], alloc)] = encoded
    }
    return table, true
}

encode_regular_simd_vector :: proc(
    value: any,
    info: reflect.Type_Info_Simd_Vector,
    alloc: runtime.Allocator,
    meta: Field_Meta,
) -> (
    result: toml.Type,
    ok: bool,
) {
    list := new(toml.List, alloc)
    for i in 0 ..< info.count {
        elem_value := simd_lane_value(value, info, i)
        encoded, encoded_ok := encode_value(elem_value, alloc, meta)
        if !encoded_ok {
            toml.deep_delete(list, alloc)
            return nil, false
        }
        append(list, encoded)
    }
    return list, true
}

encode_axis_simd_vector :: proc(
    value: any,
    info: reflect.Type_Info_Simd_Vector,
    alloc: runtime.Allocator,
    meta: Field_Meta,
) -> (
    result: toml.Type,
    ok: bool,
) {
    table := new(toml.Table, alloc)
    for i in 0 ..< info.count {
        elem_value := simd_lane_value(value, info, i)
        encoded, encoded_ok := encode_value(elem_value, alloc, meta)
        if !encoded_ok {
            toml.deep_delete(table, alloc)
            return nil, false
        }
        table[strings.clone(sequence_axis_name(i), alloc)] = encoded
    }
    return table, true
}

process_value :: proc(
    dest: any,
    value: toml.Type,
    alloc: runtime.Allocator,
    meta: Field_Meta,
    apply: bool,
) -> (
    err: toml.Unmarshal_Error,
) {
    if dest == nil || dest.id == nil do return .Invalid_Parameter
    if dest.data == nil do return .Invalid_Parameter

    target := dest
    ti := reflect.type_info_base(type_info_of(target.id))
    if _, is_pointer := ti.variant.(reflect.Type_Info_Pointer); is_pointer {
        target = reflect.deref(target)
        ti = reflect.type_info_base(type_info_of(target.id))
    }

    if meta.codec != "" {
        if handled, codec_err := process_codec_value(target, value, alloc, meta.codec, apply); handled {
            return codec_err
        }
    }

    #partial switch v in value {
    case ^toml.Table:
        #partial switch info in ti.variant {
        case reflect.Type_Info_Struct:
            return process_struct_table(target, v, alloc, apply)
        case reflect.Type_Info_Array:
            if sequence_uses_axes(info.count) {
                return process_axis_array_table(target, v, alloc, info.count, meta, apply)
            }
            return .Unsupported_Type
        case reflect.Type_Info_Enumerated_Array:
            return process_enumerated_array_table(target, v, alloc, meta, apply)
        case reflect.Type_Info_Simd_Vector:
            if sequence_uses_axes(info.count) {
                return process_axis_simd_vector_table(target, v, alloc, info, meta, apply)
            }
            return .Unsupported_Type
        }
        return .Unsupported_Type

    case ^toml.List:
        if info, ok := ti.variant.(reflect.Type_Info_Array); ok {
            return process_regular_array_list(target, v, alloc, info.count, meta, apply)
        }
        if info, ok := ti.variant.(reflect.Type_Info_Simd_Vector); ok {
            return process_regular_simd_vector_list(target, v, alloc, info, meta, apply)
        }
        return .Unsupported_Type

    case bool:
        if is_boolean_like(target) || is_integer_like(target) || is_float_like(target) {
            if apply {
                assign_bool_like(target, v)
            }
            return .None
        }
        return .Unsupported_Type

    case f64:
        if is_float_like(target) || is_integer_like(target) {
            if apply {
                assign_float_like(target, v)
            }
            return .None
        }
        return .Unsupported_Type

    case i64:
        if info, ok := ti.variant.(reflect.Type_Info_Enum); ok {
            if apply {
                any_assign_i64({target.data, info.base.id}, v)
            }
            return .None
        }
        if is_integer_like(target) || is_float_like(target) || is_boolean_like(target) {
            if apply {
                assign_i64_like(target, v)
            }
            return .None
        }
        return .Unsupported_Type

    case string:
        return process_string_token(target, v, alloc, apply)

    case:
        return .Unsupported_Type
    }
}

process_struct_table :: proc(
    dest: any,
    table: ^toml.Table,
    alloc: runtime.Allocator,
    apply: bool,
) -> (
    err: toml.Unmarshal_Error,
) {
    ti := reflect.type_info_base(type_info_of(dest.id))
    _, ok := ti.variant.(reflect.Type_Info_Struct)
    if !ok do return .Unsupported_Type

    fields := reflect.struct_fields_zipped(dest.id)
    for key in table {
        field_index := -1
        for field, i in fields {
            if field_name(field) == key {
                field_index = i
                break
            }
        }
        if field_index < 0 do continue

        field := fields[field_index]
        field_any := reflect.struct_field_value(dest, field)
        if field_err := process_value(field_any, table[key], alloc, field_meta(field), apply); field_err != .None {
            return field_err
        }
    }
    return .None
}

process_regular_array_list :: proc(
    dest: any,
    list: ^toml.List,
    alloc: runtime.Allocator,
    count: int,
    meta: Field_Meta,
    apply: bool,
) -> (
    err: toml.Unmarshal_Error,
) {
    for i in 0 ..< min(count, len(list^)) {
        elem := reflect.index(dest, i)
        if elem_err := process_value(elem, list[i], alloc, meta, apply); elem_err != .None {
            return elem_err
        }
    }
    return .None
}

process_axis_array_table :: proc(
    dest: any,
    table: ^toml.Table,
    alloc: runtime.Allocator,
    count: int,
    meta: Field_Meta,
    apply: bool,
) -> (
    err: toml.Unmarshal_Error,
) {
    for i in 0 ..< count {
        value, present := table[sequence_axis_name(i)]
        if !present do continue

        elem := reflect.index(dest, i)
        if elem_err := process_value(elem, value, alloc, meta, apply); elem_err != .None {
            return elem_err
        }
    }
    return .None
}

process_enumerated_array_table :: proc(
    dest: any,
    table: ^toml.Table,
    alloc: runtime.Allocator,
    meta: Field_Meta,
    apply: bool,
) -> (
    err: toml.Unmarshal_Error,
) {
    ti := reflect.type_info_base(type_info_of(dest.id))
    info, ok := ti.variant.(reflect.Type_Info_Enumerated_Array)
    if !ok do return .Unsupported_Type

    names := tweak_enum_info(info.index.id).names
    for i in 0 ..< min(info.count, len(names)) {
        value, present := table[names[i]]
        if !present do continue

        elem := reflect.index(dest, i)
        if elem_err := process_value(elem, value, alloc, meta, apply); elem_err != .None {
            return elem_err
        }
    }
    return .None
}

process_regular_simd_vector_list :: proc(
    dest: any,
    list: ^toml.List,
    alloc: runtime.Allocator,
    info: reflect.Type_Info_Simd_Vector,
    meta: Field_Meta,
    apply: bool,
) -> (
    err: toml.Unmarshal_Error,
) {
    for i in 0 ..< min(info.count, len(list^)) {
        elem := simd_lane_value(dest, info, i)
        if elem_err := process_value(elem, list[i], alloc, meta, apply); elem_err != .None {
            return elem_err
        }
    }
    return .None
}

process_axis_simd_vector_table :: proc(
    dest: any,
    table: ^toml.Table,
    alloc: runtime.Allocator,
    info: reflect.Type_Info_Simd_Vector,
    meta: Field_Meta,
    apply: bool,
) -> (
    err: toml.Unmarshal_Error,
) {
    for i in 0 ..< info.count {
        value, present := table[sequence_axis_name(i)]
        if !present do continue

        elem := simd_lane_value(dest, info, i)
        if elem_err := process_value(elem, value, alloc, meta, apply); elem_err != .None {
            return elem_err
        }
    }
    return .None
}

process_string_token :: proc(
    dest: any,
    raw: string,
    alloc: runtime.Allocator,
    apply: bool,
) -> (
    err: toml.Unmarshal_Error,
) {
    ti := reflect.type_info_base(type_info_of(dest.id))

    if handled, union_err := process_union_string_value(dest, raw, apply); handled {
        return union_err
    }

    if info, is_enum := ti.variant.(reflect.Type_Info_Enum); is_enum {
        for name, i in info.names {
            if name != raw do continue
            if apply {
                any_assign_i64({dest.data, info.base.id}, i64(info.values[i]))
            }
            return .None
        }
        return .None
    }

    if string_info, is_string := ti.variant.(reflect.Type_Info_String); is_string {
        if !apply do return .None
        if string_info.is_cstring {
            owned, owned_err := strings.clone_to_cstring(raw, alloc)
            if owned_err != .None do return .Out_Of_Memory
            (^cstring)(dest.data)^ = owned
            return .None
        }

        owned, owned_err := strings.clone(raw, alloc)
        if owned_err != .None do return .Out_Of_Memory
        (^string)(dest.data)^ = owned
        return .None
    }

    if is_integer_like(dest) {
        value, ok := strconv.parse_i64(raw)
        if !ok do return .Unsupported_Type
        if apply do assign_i64_like(dest, value)
        return .None
    }

    if is_float_like(dest) {
        value, ok := strconv.parse_f64(raw)
        if !ok do return .Unsupported_Type
        if apply do assign_float_like(dest, value)
        return .None
    }

    if is_boolean_like(dest) {
        if raw != "true" && raw != "false" do return .Unsupported_Type
        if apply do assign_bool_like(dest, raw == "true")
        return .None
    }

    return .Unsupported_Type
}

encode_union_string_value :: proc(value: any, alloc: runtime.Allocator) -> (result: toml.Type, handled, ok: bool) {
    raw, union_handled, union_ok := union_string_value(value)
    if !union_handled do return nil, false, false
    if !union_ok do return nil, true, false
    return strings.clone(raw, alloc), true, true
}

union_string_value :: proc(value: any) -> (raw: string, handled, ok: bool) {
    ti := reflect.type_info_base(type_info_of(value.id))
    info, union_ok := ti.variant.(reflect.Type_Info_Union)
    if !union_ok do return "", false, false
    if !union_string_info_supported(info) do return "", false, false

    variant := reflect.get_union_variant(value)
    if variant == nil {
        if info.no_nil do return "", true, false
        return "", true, true
    }

    if label, label_ok := union_string_option_label(type_info_of(variant.id)); label_ok {
        return label, true, true
    }

    enum_info, enum_ok := reflect.type_info_base(type_info_of(variant.id)).variant.(reflect.Type_Info_Enum)
    if !enum_ok do return "", true, false

    enum_value, value_ok := any_get_i64({variant.data, enum_info.base.id})
    if !value_ok do return "", true, false

    for name, i in enum_info.names {
        if i64(enum_info.values[i]) == enum_value do return name, true, true
    }
    return "", true, false
}

process_union_string_value :: proc(dest: any, raw: string, apply: bool) -> (handled: bool, err: toml.Unmarshal_Error) {
    ti := reflect.type_info_base(type_info_of(dest.id))
    info, union_ok := ti.variant.(reflect.Type_Info_Union)
    if !union_ok do return false, .None
    if !union_string_info_supported(info) do return false, .None

    if raw == "" || raw == "nil" {
        if info.no_nil do return true, .None
        if apply do reflect.set_union_variant_typeid(dest, nil)
        return true, .None
    }

    for variant in info.variants {
        if label, label_ok := union_string_option_label(variant); label_ok {
            if named, named_ok := variant.variant.(reflect.Type_Info_Named); named_ok {
                if raw == named.name || raw == label {
                    if apply do reflect.set_union_variant_typeid(dest, variant.id)
                    return true, .None
                }
            }
            continue
        }

        enum_info, enum_ok := reflect.type_info_base(variant).variant.(reflect.Type_Info_Enum)
        if !enum_ok do continue

        for name, i in enum_info.names {
            if name != raw do continue
            if apply {
                reflect.set_union_variant_typeid(dest, variant.id)
                variant_any := reflect.get_union_variant(dest)
                any_assign_i64({variant_any.data, enum_info.base.id}, i64(enum_info.values[i]))
            }
            return true, .None
        }
    }

    return true, .Unsupported_Type
}

union_string_options :: proc(
    info: reflect.Type_Info_Union,
    alloc := context.temp_allocator,
) -> (
    options: [dynamic]string,
    allow_none: bool,
    handled: bool,
) {
    if !union_string_info_supported(info) do return nil, false, false

    option_count := 0
    for variant in info.variants {
        if _, label_ok := union_string_option_label(variant); label_ok {
            option_count += 1
            continue
        }
        if enum_info, enum_ok := reflect.type_info_base(variant).variant.(reflect.Type_Info_Enum); enum_ok {
            option_count += len(enum_info.names)
        }
    }

    options = make([dynamic]string, 0, option_count, alloc)
    for variant in info.variants {
        if label, label_ok := union_string_option_label(variant); label_ok {
            append(&options, label)
            continue
        }
        if enum_info, enum_ok := reflect.type_info_base(variant).variant.(reflect.Type_Info_Enum); enum_ok {
            append(&options, ..enum_info.names)
        }
    }

    return options, !info.no_nil, true
}

union_string_option_label :: proc(variant: ^reflect.Type_Info) -> (label: string, ok: bool) {
    if variant == nil || variant.size != 0 do return "", false
    if named, named_ok := variant.variant.(reflect.Type_Info_Named); named_ok {
        return fmt.aprint(named.name, "{}", sep = "", allocator = context.temp_allocator), true
    }
    return "", false
}

union_string_info_supported :: proc(info: reflect.Type_Info_Union) -> bool {
    if len(info.variants) == 0 do return false

    for variant in info.variants {
        if _, label_ok := union_string_option_label(variant); label_ok do continue
        if _, enum_ok := reflect.type_info_base(variant).variant.(reflect.Type_Info_Enum); enum_ok do continue
        return false
    }

    return true
}

encode_codec_value :: proc(
    value: any,
    codec: string,
    alloc: runtime.Allocator,
) -> (
    result: toml.Type,
    handled, ok: bool,
) {
    switch codec {
    case "maybe_enum_string":
    case "macro_resource_string":
        return encode_union_string_value(value, alloc)
    }

    return nil, false, false
}

process_codec_value :: proc(
    dest: any,
    value: toml.Type,
    alloc: runtime.Allocator,
    codec: string,
    apply: bool,
) -> (
    handled: bool,
    err: toml.Unmarshal_Error,
) {
    switch codec {
    case "maybe_enum_string":
    case "macro_resource_string":
        raw, raw_ok := value.(string)
        if !raw_ok do return true, .Unsupported_Type
        return process_union_string_value(dest, raw, apply)
    }

    return false, .None
}

codec_string :: proc(value: any, codec: string) -> string {
    switch codec {
    case "maybe_enum_string":
    case "macro_resource_string":
        raw, handled, ok := union_string_value(value)
        if handled && ok do return raw
        return ""
    }

    encoded, handled, ok := encode_codec_value(value, codec, context.temp_allocator)
    if !handled || !ok do return ""
    if str, str_ok := encoded.(string); str_ok do return str
    return fmt.tprintf("%v", encoded)
}

find_enum_union_variant :: proc(
    info: reflect.Type_Info_Union,
) -> (
    variant: ^reflect.Type_Info,
    enum_info: reflect.Type_Info_Enum,
    found: bool,
) {
    for v in info.variants {
        if e, ok := reflect.type_info_base(v).variant.(reflect.Type_Info_Enum); ok {
            return v, e, true
        }
    }
    return nil, {}, false
}

core_any :: proc(value: any) -> any {
    core := reflect.type_info_base_without_enum(type_info_of(value.id))
    return {data = value.data, id = core.id}
}

is_integer_like :: proc(value: any) -> bool {
    ti := reflect.type_info_base_without_enum(type_info_of(value.id))
    _, ok := ti.variant.(reflect.Type_Info_Integer)
    if ok do return true
    _, ok = ti.variant.(reflect.Type_Info_Rune)
    return ok
}

is_float_like :: proc(value: any) -> bool {
    ti := reflect.type_info_base_without_enum(type_info_of(value.id))
    _, ok := ti.variant.(reflect.Type_Info_Float)
    return ok
}

is_boolean_like :: proc(value: any) -> bool {
    ti := reflect.type_info_base_without_enum(type_info_of(value.id))
    _, ok := ti.variant.(reflect.Type_Info_Boolean)
    return ok
}

assign_i64_like :: proc(dest: any, value: i64) {
    ti := reflect.type_info_base(type_info_of(dest.id))
    if info, ok := ti.variant.(reflect.Type_Info_Enum); ok {
        any_assign_i64({dest.data, info.base.id}, value)
        return
    }

    core := core_any(dest)
    if is_float_like(dest) {
        any_assign_f64(core, f64(value))
        return
    }
    if is_boolean_like(dest) {
        any_assign_bool(core, value != 0)
        return
    }
    any_assign_i64(core, value)
}

assign_float_like :: proc(dest: any, value: f64) {
    if is_integer_like(dest) {
        any_assign_i64(core_any(dest), i64(value))
        return
    }
    if is_boolean_like(dest) {
        any_assign_bool(core_any(dest), value != 0)
        return
    }
    any_assign_f64(core_any(dest), value)
}

assign_bool_like :: proc(dest: any, value: bool) {
    if is_integer_like(dest) {
        any_assign_i64(core_any(dest), 1 if value else 0)
        return
    }
    if is_float_like(dest) {
        any_assign_f64(core_any(dest), 1 if value else 0)
        return
    }
    any_assign_bool(core_any(dest), value)
}
