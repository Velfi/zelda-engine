package toml

import "core:mem"
import "core:reflect"
import "core:strings"

import "base:runtime"
import "dates"
import "zelda_engine:spy"

marshal :: proc(ptr: ^$T, alloc := context.allocator, loc := #caller_location) -> ^Table {
    if ptr == nil do spy.panicf("Cannot marshal nil TOML source pointer", loc = loc)

    context.allocator = alloc

    root_value, ok := marshal_value(reflect.deref(any(ptr)), alloc)
    if !ok do spy.panicf("TOML marshal unsupported root type: %v", type_info_of(typeid_of(T)), loc = loc)

    root, root_ok := root_value.(^Table)
    if !root_ok || root == nil do spy.panicf("TOML marshal root must be a table", loc = loc)
    return root
}

@(private)
marshal_value :: proc(value: any, alloc: mem.Allocator) -> (result: Type, ok: bool) {
    if value == nil || value.id == nil do return nil, false

    info := reflect.type_info_base(type_info_of(value.id))

    enum_info, is_enum := info.variant.(reflect.Type_Info_Enum)
    if is_enum {
        enum_value, enum_value_ok := marshal_i64({data = value.data, id = enum_info.base.id})
        if !enum_value_ok do return nil, false

        for enum_name, idx in enum_info.names {
            if i64(enum_info.values[idx]) != enum_value do continue
            return strings.clone(enum_name, alloc), true
        }
        return nil, false
    }

    core := reflect.any_core(value)
    switch v in core {
    case string:
        return strings.clone(v, alloc), true
    case bool:
        return v, true

    case i8:
        return i64(v), true
    case i16:
        return i64(v), true
    case i32:
        return i64(v), true
    case i64:
        return i64(v), true
    case int:
        return i64(v), true

    case u8:
        return i64(v), true
    case u16:
        return i64(v), true
    case u32:
        return i64(v), true
    case uint:
        when size_of(uint) > size_of(i64) {
            if u64(v) > u64(max(i64)) do return nil, false
        }
        return i64(v), true
    case u64:
        if v > u64(max(i64)) do return nil, false
        return i64(v), true
    case uintptr:
        when size_of(uintptr) > size_of(i64) {
            if u64(v) > u64(max(i64)) do return nil, false
        }
        return i64(v), true

    case f16:
        return f64(v), true
    case f32:
        return f64(v), true
    case f64:
        return f64(v), true
    case dates.Date:
        return v, true
    }

    #partial switch t in info.variant {
    case reflect.Type_Info_Pointer:
        if value.data == nil do return nil, false
        return marshal_value(reflect.deref(value), alloc)

    case reflect.Type_Info_Struct:
        table := new(Table)
        fields := reflect.struct_fields_zipped(info.id)
        for field in fields {
            if field.name == "_" do continue

            field_name := field.name
            if tag := reflect.struct_tag_get(field.tag, "toml"); tag != "" {
                tagged_name, _ := toml_name_from_tag_value(tag)
                if tagged_name == "-" do continue
                if tagged_name != "" do field_name = tagged_name
            }

            field_value: any = {
                data = rawptr(uintptr(value.data) + field.offset),
                id   = field.type.id,
            }
            encoded, encoded_ok := marshal_value(field_value, alloc)
            if !encoded_ok {
                deep_delete(table, alloc)
                return nil, false
            }

            table[strings.clone(field_name, alloc)] = encoded
        }
        return table, true

    case reflect.Type_Info_Array:
        return marshal_contiguous_list(value.data, t.elem, t.count, alloc)

    case reflect.Type_Info_Enumerated_Array:
        return marshal_enumerated_array(value.data, t.elem, t.index.id, alloc)

    case reflect.Type_Info_Slice:
        raw := cast(^mem.Raw_Slice)value.data
        if raw == nil do return nil, false
        return marshal_contiguous_list(raw.data, t.elem, raw.len, alloc)

    case reflect.Type_Info_Dynamic_Array:
        raw := cast(^mem.Raw_Dynamic_Array)value.data
        if raw == nil do return nil, false
        return marshal_contiguous_list(raw.data, t.elem, raw.len, alloc)
    }

    return nil, false
}

@(private)
marshal_contiguous_list :: proc(
    data: rawptr,
    elem: ^reflect.Type_Info,
    count: int,
    alloc: mem.Allocator,
) -> (
    result: Type,
    ok: bool,
) {
    if count < 0 do return nil, false

    list := new(List)
    if count == 0 do return list, true
    if data == nil {
        free(list)
        return nil, false
    }

    for i in 0 ..< count {
        elem_ptr := rawptr(uintptr(data) + uintptr(i) * uintptr(elem.size))
        encoded, encoded_ok := marshal_value({data = elem_ptr, id = elem.id}, alloc)
        if !encoded_ok {
            deep_delete(list, alloc)
            return nil, false
        }
        append(list, encoded)
    }
    return list, true
}

// Marshal an [Enum]T array as a TOML table keyed by the enum variant name.
// Rationale: positional lists for enumerated arrays are fragile across enum
// reorders and unreadable for hand-edited configs. Named keys match what
// humans expect to see and stay stable when variants are added/removed.
@(private)
// #+vet redundancy public-api
marshal_enumerated_array :: proc(
    data: rawptr,
    elem: ^reflect.Type_Info,
    index_typeid: typeid,
    alloc: mem.Allocator,
) -> (
    result: Type,
    ok: bool,
) {
    e := toml_enum_info(index_typeid)

    table := new(Table)
    if data == nil {
        return table, true
    }

    for i in 0 ..< len(e.names) {
        elem_ptr := rawptr(uintptr(data) + uintptr(i) * uintptr(elem.size))
        encoded, encoded_ok := marshal_value({data = elem_ptr, id = elem.id}, alloc)
        if !encoded_ok {
            deep_delete(table, alloc)
            return nil, false
        }
        table[strings.clone(e.names[i], alloc)] = encoded
    }
    return table, true
}

@(private)
// #+vet redundancy public-api
marshal_i64 :: proc(value: any) -> (out: i64, ok: bool) {
    if value == nil || value.id == nil do return 0, false

    core := reflect.any_core(value)
    switch v in core {
    case i8:
        return i64(v), true
    case i16:
        return i64(v), true
    case i32:
        return i64(v), true
    case i64:
        return i64(v), true
    case int:
        return i64(v), true

    case u8:
        return i64(v), true
    case u16:
        return i64(v), true
    case u32:
        return i64(v), true
    case uint:
        when size_of(uint) > size_of(i64) {
            if u64(v) > u64(max(i64)) do return 0, false
        }
        return i64(v), true
    case u64:
        if v > u64(max(i64)) do return 0, false
        return i64(v), true
    case uintptr:
        when size_of(uintptr) > size_of(i64) {
            if u64(v) > u64(max(i64)) do return 0, false
        }
        return i64(v), true
    }
    return 0, false
}
