package hs
import "core:reflect"
import "core:slice"
import "core:strings"

import rt "base:runtime"

SaveHeader :: struct {
    types:         []TypeInfo,
    struct_fields: []Struct_Field,
    bit_fields:    []Bit_Field,
    enum_fields:   []Enum_Field,
    handles:       []TypeInfo_Handle,
    arena:         []byte,
    options:       Options,
    stored_type:   TypeInfo_Handle,
    data_base:     uintptr, // used when deserializing to know where the memory starts
}
get_typeinfo_base :: #force_inline proc(header: ^SaveHeader, handle: TypeInfo_Handle) -> (base: ^TypeInfo, ok: bool) {
    handle := handle
    for {
        base = get_typeinfo_ptr(header, handle) or_return
        named := base.variant.(TypeInfo_Named) or_break
        handle = named.type
    }
    return base, true
}
get_typeinfo_ptr :: #force_inline proc(
    header: ^SaveHeader,
    handle: TypeInfo_Handle,
) -> (
    ptr: ^TypeInfo,
    ok: bool,
) #no_bounds_check {
    return &header.types[int(handle) - 1], true
}
// #+vet redundancy public-api
get_name :: #force_inline proc(header: ^SaveHeader, handle: TypeInfo_Handle) -> (s: string, ok: bool) {
    info := get_typeinfo_ptr(header, handle) or_return
    named := (&info.variant.(TypeInfo_Named)) or_return
    s = resolve_to_string(header.arena, named.name)
    return s, true
}
// #+vet redundancy public-api
get_name_info_ptr :: #force_inline proc(t: ^rt.Type_Info) -> (s: string, ok: bool) {
    named := (&t.variant.(rt.Type_Info_Named)) or_return
    return named.name, true
}
find_matching_field_index :: #force_inline proc(
    header: ^SaveHeader,
    fields: []$T,
    name: string,
) -> (
    index: int,
    found: bool,
) {
    for &field, i in fields {
        if resolve_to_string(header.arena, field.name) != name do continue
        return i, true
    }
    return -1, false
}
fully_match_field :: proc(header: ^SaveHeader, fields: []$T, name, tag: string) -> (index: int, found: bool) {
    tag_values: []string
    if t, ok := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), TAG); ok {
        tag_values = strings.split(t, ",", context.temp_allocator)
    }
    // ignore this field
    if slice.contains(tag_values, "-") {
        return
    }

    index, found = find_matching_field_index(header, fields, name)
    if found do return

    for alias in tag_values {
        index, found = find_matching_field_index(header, fields, alias)
        if found do return
    }
    return
}
enum_identical :: proc(header: ^SaveHeader, a: ^TypeInfo, b: ^rt.Type_Info) -> bool {
    a := (&a.variant.(TypeInfo_Enum)) or_return
    a_fields := to_slice(header.enum_fields, a.fields)
    b_fields := reflect.enum_fields_zipped(b.id)

    if len(a_fields) != len(b_fields) do return false
    for a_field, i in a_fields {
        b_field := b_fields[i]
        if a_field.value != i64(b_field.value) do return false
        a_name := resolve_to_string(header.arena, a_field.name)
        if a_name != b_field.name do return false
    }
    return true
}
