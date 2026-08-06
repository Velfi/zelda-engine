package hs

import rt "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"
import "core:unicode/utf8"

Portable_Magic :: [8]byte{'H', 'S', 'P', 'O', 'R', 'T', '1', 0}
Portable_Version :: u16(1)
Portable_Header_Size :: 28
PORTABLE_SAFE_MAX_RECURSION_DEPTH :: 256

Portable_Limits :: struct {
    max_payload:         int,
    max_types:           int,
    max_fields:          int,
    max_array_elements:  int,
    max_string_bytes:    int,
    max_recursion_depth: int,
}

Portable_Config :: struct {
    exclusion_tag: string,
    retain_tag:    string,
    exact_schema:  bool,
    limits:        Portable_Limits,
}

Portable_Error_Kind :: enum {
    None,
    Invalid_Argument,
    Unsupported_Type,
    Invalid_Header,
    Truncated,
    Overflow,
    Invalid_Handle,
    Invalid_Metadata,
    Limit_Exceeded,
    Trailing_Bytes,
    Type_Mismatch,
}

Portable_Error :: struct {
    kind:           Portable_Error_Kind,
    offset:         int,
    path:           string,
    message:        string,
    path_owned:     bool,
    path_allocator: mem.Allocator,
}

portable_default_config :: proc() -> Portable_Config {
    return PORTABLE_DEFAULT_CONFIG
}

PORTABLE_DEFAULT_CONFIG :: Portable_Config {
    exclusion_tag = "",
    limits = Portable_Limits {
        max_payload = 64 * 1024 * 1024,
        max_types = 4096,
        max_fields = 65536,
        max_array_elements = 16 * 1024 * 1024,
        max_string_bytes = 1024 * 1024,
        max_recursion_depth = 256,
    },
}

portable_no_error :: proc() -> Portable_Error {
    return {}
}

portable_validate_limits :: proc(limits: Portable_Limits) -> Portable_Error {
    if limits.max_payload < Portable_Header_Size ||
       limits.max_types <= 0 ||
       limits.max_fields < 0 ||
       limits.max_array_elements < 0 ||
       limits.max_string_bytes < 0 ||
       limits.max_recursion_depth < 0 {
        return portable_error(.Limit_Exceeded, 0, "$", "portable limits are invalid")
    }
    if limits.max_recursion_depth > PORTABLE_SAFE_MAX_RECURSION_DEPTH {
        return portable_error(.Limit_Exceeded, 0, "$", "portable recursion limit exceeds safe ceiling")
    }
    wire_max := u64(max(u32))
    if u64(limits.max_payload) > wire_max ||
       u64(limits.max_types) > wire_max ||
       u64(limits.max_fields) > wire_max ||
       u64(limits.max_string_bytes) > wire_max {
        return portable_error(.Overflow, 0, "$", "portable limits exceed wire width")
    }
    return portable_no_error()
}

Portable_Kind :: enum u8 {
    Invalid,
    Bool,
    Signed,
    Unsigned,
    Rune,
    Float,
    String,
    Struct,
    Array,
    Enum,
    Dynamic_Array,
    Enumerated_Array,
    Quaternion,
}

Portable_Field :: struct {
    name: string,
    type: u32,
}

Portable_Enum_Field :: struct {
    name:  string,
    value: i64,
}

Portable_Type :: struct {
    kind:        Portable_Kind,
    width:       u8,
    signed:      bool,
    elem:        u32,
    index:       u32,
    count:       int,
    base:        u32,
    fields:      [dynamic]Portable_Field,
    enum_fields: [dynamic]Portable_Enum_Field,
    id:          typeid,
}

portable_delete_type :: proc(type: ^Portable_Type) {
    delete(type.fields)
    delete(type.enum_fields)
}

portable_delete_types :: proc(types: [dynamic]Portable_Type) {
    for &type in types {
        portable_delete_type(&type)
    }
    delete(types)
}

Portable_Writer :: struct {
    bytes:             [dynamic]byte,
    limit:             int,
    error:             Portable_Error,
    allocation_failed: bool,
}

portable_copy_error_path :: proc(path: string, alloc: mem.Allocator) -> (string, bool) {
    if path == "" || path == "$" || strings.has_prefix(path, "$table") || strings.has_prefix(path, "$.header") || alloc.procedure == nil do return path, false
    copy, err := strings.clone(path, alloc)
    if err == nil do return copy, true
    return "$", false
}

portable_error :: proc(kind: Portable_Error_Kind, offset: int, path, message: string) -> Portable_Error {
    return {kind = kind, offset = offset, path = path, message = message}
}

// Dispose an error path returned by portable_encode or portable_decode.
// Static paths are no-ops. Allocated paths are released with their original allocator.
portable_error_dispose :: proc(error: ^Portable_Error) {
    if error == nil || !error.path_owned do return
    delete(error.path, error.path_allocator)
    error.path = ""
    error.path_owned = false
    error.path_allocator = {}
}

portable_path_field_push :: proc(path: ^[dynamic]byte, name: string) -> (checkpoint: int, result: string, ok: bool) {
    checkpoint = len(path^)
    if len(name) >= max(int) || checkpoint > max(int) - len(name) - 1 do return checkpoint, "", false
    if _, allocation_error := append(path, '.'); allocation_error != nil do return checkpoint, "", false
    if _, allocation_error := append(path, ..transmute([]byte)name); allocation_error != nil {
        resize(path, checkpoint)
        return checkpoint, "", false
    }
    return checkpoint, string(path^[:]), true
}

portable_path_field_pop :: proc(path: ^[dynamic]byte, checkpoint: int) {
    resize(path, checkpoint)
}

portable_writer_can_append :: proc(w: ^Portable_Writer, count: int) -> bool {
    if count < 0 || len(w.bytes) > w.limit do return false
    return count <= w.limit - len(w.bytes)
}

portable_write_byte :: proc(w: ^Portable_Writer, value: byte) -> bool {
    if !portable_writer_can_append(w, 1) do return false
    _, allocation_error := append(&w.bytes, value)
    if allocation_error != nil {
        w.allocation_failed = true
        return false
    }
    return true
}

portable_write_u16 :: proc(w: ^Portable_Writer, value: u16) -> bool {
    if !portable_writer_can_append(w, 2) do return false
    _, allocation_error := append(&w.bytes, byte(value), byte(value >> 8))
    if allocation_error != nil {
        w.allocation_failed = true
        return false
    }
    return true
}

portable_write_u32 :: proc(w: ^Portable_Writer, value: u32) -> bool {
    if !portable_writer_can_append(w, 4) do return false
    _, allocation_error := append(&w.bytes, byte(value), byte(value >> 8), byte(value >> 16), byte(value >> 24))
    if allocation_error != nil {
        w.allocation_failed = true
        return false
    }
    return true
}

portable_write_u64 :: proc(w: ^Portable_Writer, value: u64) -> bool {
    if !portable_writer_can_append(w, 8) do return false
    for i in 0 ..< 8 {
        _, allocation_error := append(&w.bytes, byte(value >> (u64(i) * 8)))
        if allocation_error != nil {
            w.allocation_failed = true
            return false
        }
    }
    return true
}

portable_write_i64 :: proc(w: ^Portable_Writer, value: i64) -> bool {
    return portable_write_u64(w, cast(u64)value)
}

portable_write_fixed_u64 :: proc(w: ^Portable_Writer, value: u64, width: int) -> bool {
    if width < 1 || width > 8 || !portable_writer_can_append(w, width) do return false
    for i in 0 ..< width {
        _, allocation_error := append(&w.bytes, byte(value >> (u64(i) * 8)))
        if allocation_error != nil {
            w.allocation_failed = true
            return false
        }
    }
    return true
}

portable_write_bytes :: proc(w: ^Portable_Writer, data: []byte) -> bool {
    if !portable_writer_can_append(w, len(data)) do return false
    _, allocation_error := append(&w.bytes, ..data)
    if allocation_error != nil {
        w.allocation_failed = true
        return false
    }
    return true
}

portable_write_string :: proc(w: ^Portable_Writer, value: string) -> bool {
    if u64(len(value)) > u64(max(u32)) do return false
    if len(value) > max(0, w.limit - len(w.bytes) - 4) do return false
    return portable_write_u32(w, u32(len(value))) && portable_write_bytes(w, transmute([]byte)value)
}

portable_quaternion_width :: proc(info: ^rt.Type_Info) -> (width: u8, ok: bool) {
    if info == nil do return 0, false
    if _, variant_ok := info.variant.(rt.Type_Info_Quaternion); !variant_ok do return 0, false
    switch info.id {
    case quaternion64:
        valid :=
            info.size == 8 &&
            info.align == 2 &&
            align_of(quaternion64) == 2 &&
            reflect.typeid_elem(info.id) == typeid_of(f16) &&
            info.size == 4 * size_of(f16)
        return 8, valid
    case quaternion128:
        valid :=
            info.size == 16 &&
            info.align == 4 &&
            align_of(quaternion128) == 4 &&
            reflect.typeid_elem(info.id) == typeid_of(f32) &&
            info.size == 4 * size_of(f32)
        return 16, valid
    }
    return 0, false
}

portable_type_kind :: proc(info: ^rt.Type_Info) -> (kind: Portable_Kind, width: u8, signed: bool, ok: bool) {
    if info == nil do return .Invalid, 0, false, false
    #partial switch value in info.variant {
    case rt.Type_Info_Boolean:
        return .Bool, u8(info.size), false, info.size == 1
    case rt.Type_Info_Integer:
        if value.signed do return .Signed, u8(info.size), true, info.size == 1 || info.size == 2 || info.size == 4 || info.size == 8
        return .Unsigned, u8(info.size), false, info.size == 1 || info.size == 2 || info.size == 4 || info.size == 8
    case rt.Type_Info_Rune:
        return .Rune, u8(info.size), true, info.size == 4
    case rt.Type_Info_Float:
        return .Float, u8(info.size), false, info.size == 2 || info.size == 4 || info.size == 8
    case rt.Type_Info_Quaternion:
        quaternion_width, width_ok := portable_quaternion_width(info)
        return .Quaternion, quaternion_width, false, width_ok
    case rt.Type_Info_String:
        return .String, 0, false, !value.is_cstring && value.encoding == .UTF_8
    case:
        return .Invalid, 0, false, false
    }
}

portable_runtime_enumerated_array_info :: proc(
    array: rt.Type_Info_Enumerated_Array,
) -> (
    index: rt.Type_Info_Enum,
    min_value: i64,
    ok: bool,
) {
    if array.is_sparse || array.count <= 0 || array.elem == nil || array.index == nil do return {}, 0, false
    element_info := rt.type_info_base(array.elem)
    index_info := rt.type_info_base(array.index)
    if element_info == nil || index_info == nil || array.elem_size != element_info.size do return {}, 0, false
    index_ok: bool
    index, index_ok = index_info.variant.(rt.Type_Info_Enum)
    if !index_ok || len(index.names) != len(index.values) || len(index.values) != array.count do return {}, 0, false

    min_value = i64(index.values[0])
    max_value := min_value
    for value, value_index in index.values {
        candidate := i64(value)
        min_value = min(min_value, candidate)
        max_value = max(max_value, candidate)
        for previous_index in 0 ..< value_index {
            if index.values[previous_index] == value do return {}, 0, false
        }
    }
    if u64(array.count - 1) > u64(max(i64)) ||
       min_value > max(i64) - i64(array.count - 1) ||
       min_value + i64(array.count - 1) != max_value ||
       min_value != i64(array.min_value) ||
       max_value != i64(array.max_value) {
        return {}, 0, false
    }
    return index, min_value, true
}

portable_fixed_array_bulk_width :: proc(
    types: []Portable_Type,
    array: Portable_Type,
    runtime_array: rt.Type_Info_Array,
) -> (
    width: int,
    ok: bool,
) {
    if runtime_array.elem == nil ||
       runtime_array.count < array.count ||
       !portable_handle_valid(array.elem, len(types)) {
        return 0, false
    }
    element := types[array.elem - 1]
    if runtime_array.elem.id == typeid_of(u8) &&
       runtime_array.elem_size == 1 &&
       element.kind == .Unsigned &&
       element.width == 1 &&
       !element.signed {
        return 1, true
    }
    when ODIN_ENDIAN == .Little {
        if runtime_array.elem.id == typeid_of(f32) &&
           runtime_array.elem_size == 4 &&
           element.kind == .Float &&
           element.width == 4 &&
           !element.signed {
            return 4, true
        }
    }
    return 0, false
}

portable_field_excluded :: proc(field: reflect.Struct_Field, config: Portable_Config) -> bool {
    if config.exclusion_tag == "" do return false
    value, ok := reflect.struct_tag_lookup(field.tag, config.exclusion_tag)
    if !ok || value != "-" do return false
    if config.retain_tag == "" do return true
    retained, retained_ok := reflect.struct_tag_lookup(field.tag, config.retain_tag)
    return !retained_ok || retained != "-"
}

Portable_Discovery :: struct {
    types:       [dynamic]Portable_Type,
    handles:     map[typeid]u32,
    fields_seen: int,
    config:      Portable_Config,
    alloc:       mem.Allocator,
    flat_paths:  bool,
    path:        [dynamic]byte,
    error:       Portable_Error,
}

portable_discovery_error :: proc(ctx: ^Portable_Discovery, kind: Portable_Error_Kind, path, message: string) {
    if ctx.error.kind == .None {
        copied_path, path_owned := portable_copy_error_path(path, ctx.alloc)
        ctx.error = portable_error(kind, 0, copied_path, message)
        ctx.error.path_owned = path_owned
        ctx.error.path_allocator = ctx.alloc
    }
}

portable_discover_type :: proc(ctx: ^Portable_Discovery, id: typeid, input_path: string, depth: int) -> u32 {
    path := input_path
    if !ctx.flat_paths do path = string(ctx.path[:])
    if ctx.error.kind != .None do return 0
    if depth > ctx.config.limits.max_recursion_depth {
        portable_discovery_error(ctx, .Limit_Exceeded, path, "maximum recursion depth exceeded")
        return 0
    }
    if handle, ok := ctx.handles[id]; ok do return handle
    if len(ctx.types) >= ctx.config.limits.max_types {
        portable_discovery_error(ctx, .Limit_Exceeded, path, "maximum type count exceeded")
        return 0
    }

    index := len(ctx.types)
    if u64(index + 1) > u64(max(u32)) {
        portable_discovery_error(ctx, .Overflow, path, "type handle exceeds wire width")
        return 0
    }
    handle := u32(index + 1)
    _, handle_ptr, _, handle_error := map_entry(&ctx.handles, id)
    if handle_error != nil {
        portable_discovery_error(ctx, .Limit_Exceeded, path, "type handle allocation failed")
        return 0
    }
    handle_ptr^ = handle
    _, type_error := append(&ctx.types, Portable_Type{id = id})
    if type_error != nil {
        delete_key(&ctx.handles, id)
        portable_discovery_error(ctx, .Limit_Exceeded, path, "type metadata allocation failed")
        return 0
    }

    info := rt.type_info_base(type_info_of(id))
    if info == nil {
        portable_discovery_error(ctx, .Invalid_Argument, path, "missing runtime type information")
        return 0
    }

    kind, width, signed, scalar_ok := portable_type_kind(info)
    if scalar_ok {
        ctx.types[index].kind = kind
        ctx.types[index].width = width
        ctx.types[index].signed = signed
        return handle
    }

    #partial switch value in info.variant {
    case rt.Type_Info_Named:
        portable_discovery_error(ctx, .Invalid_Metadata, path, "named type did not flatten")
    case rt.Type_Info_Array:
        if value.count < 0 || value.count > ctx.config.limits.max_array_elements {
            portable_discovery_error(ctx, .Limit_Exceeded, path, "array element count exceeds limit")
            return 0
        }
        elem := portable_discover_type(ctx, value.elem.id, path, depth + 1)
        if elem == 0 do return 0
        ctx.types[index].kind = .Array
        ctx.types[index].elem = elem
        ctx.types[index].count = value.count
    case rt.Type_Info_Enumerated_Array:
        if value.is_sparse {
            portable_discovery_error(ctx, .Unsupported_Type, path, "sparse enumerated arrays are not portable")
            return 0
        }
        if value.count <= 0 || value.count > ctx.config.limits.max_array_elements {
            portable_discovery_error(ctx, .Limit_Exceeded, path, "enumerated array element count exceeds limit")
            return 0
        }
        _, _, metadata_ok := portable_runtime_enumerated_array_info(value)
        if !metadata_ok {
            portable_discovery_error(ctx, .Invalid_Metadata, path, "enumerated array metadata is invalid")
            return 0
        }
        elem := portable_discover_type(ctx, value.elem.id, path, depth + 1)
        if elem == 0 do return 0
        index_handle := portable_discover_type(ctx, value.index.id, path, depth + 1)
        if index_handle == 0 do return 0
        ctx.types[index].kind = .Enumerated_Array
        ctx.types[index].elem = elem
        ctx.types[index].index = index_handle
        ctx.types[index].count = value.count
    case rt.Type_Info_Dynamic_Array:
        elem := portable_discover_type(ctx, value.elem.id, path, depth + 1)
        if elem == 0 do return 0
        ctx.types[index].kind = .Dynamic_Array
        ctx.types[index].elem = elem
    case rt.Type_Info_Struct:
        ctx.types[index].kind = .Struct
        fields := reflect.struct_fields_zipped(id)
        for field, _ in fields {
            current_path := path
            if !ctx.flat_paths do current_path = string(ctx.path[:])
            if portable_field_excluded(field, ctx.config) do continue
            if len(field.name) > ctx.config.limits.max_string_bytes {
                portable_discovery_error(ctx, .Limit_Exceeded, current_path, "field name exceeds string limit")
                return 0
            }
            ctx.fields_seen += 1
            if ctx.fields_seen > ctx.config.limits.max_fields {
                portable_discovery_error(ctx, .Limit_Exceeded, current_path, "maximum field count exceeded")
                return 0
            }
            field_path := current_path
            checkpoint: int
            if !ctx.flat_paths {
                path_ok: bool
                checkpoint, field_path, path_ok = portable_path_field_push(&ctx.path, field.name)
                if !path_ok {
                    portable_discovery_error(ctx, .Limit_Exceeded, string(ctx.path[:]), "field path allocation failed")
                    return 0
                }
            }
            field_handle := portable_discover_type(ctx, field.type.id, field_path, depth + 1)
            if field_handle == 0 {
                if !ctx.flat_paths do portable_path_field_pop(&ctx.path, checkpoint)
                return 0
            }
            _, field_error := append(&ctx.types[index].fields, Portable_Field{name = field.name, type = field_handle})
            if field_error != nil {
                portable_discovery_error(ctx, .Limit_Exceeded, string(ctx.path[:]), "field metadata allocation failed")
                if !ctx.flat_paths do portable_path_field_pop(&ctx.path, checkpoint)
                return 0
            }
            if !ctx.flat_paths do portable_path_field_pop(&ctx.path, checkpoint)
        }
    case rt.Type_Info_Enum:
        base := portable_discover_type(ctx, value.base.id, path, depth + 1)
        if base == 0 do return 0
        ctx.types[index].kind = .Enum
        ctx.types[index].base = base
        for name, i in value.names {
            if len(name) > ctx.config.limits.max_string_bytes {
                portable_discovery_error(ctx, .Limit_Exceeded, path, "enum name exceeds string limit")
                return 0
            }
            ctx.fields_seen += 1
            if ctx.fields_seen > ctx.config.limits.max_fields {
                portable_discovery_error(ctx, .Limit_Exceeded, path, "maximum field count exceeded")
                return 0
            }
            _, field_error := append(
                &ctx.types[index].enum_fields,
                Portable_Enum_Field{name = name, value = i64(value.values[i])},
            )
            if field_error != nil {
                portable_discovery_error(ctx, .Limit_Exceeded, path, "enum metadata allocation failed")
                return 0
            }
        }
    case:
        portable_discovery_error(ctx, .Unsupported_Type, path, "type is not portable")
    }
    return handle
}

portable_encode_value :: proc(
    ctx: ^Portable_Discovery,
    w: ^Portable_Writer,
    value: any,
    handle: u32,
    input_path: string,
    depth: int,
) -> bool {
    path := string(ctx.path[:])
    if len(ctx.path) == 0 do path = input_path
    if ctx.error.kind != .None do return false
    if depth > ctx.config.limits.max_recursion_depth {
        portable_discovery_error(ctx, .Limit_Exceeded, path, "maximum recursion depth exceeded")
        return false
    }
    if handle == 0 || u64(handle) > u64(len(ctx.types)) {
        portable_discovery_error(ctx, .Invalid_Handle, path, "invalid local type handle")
        return false
    }
    type := &ctx.types[handle - 1]
    info := rt.type_info_base(type_info_of(value.id))
    if info == nil {
        portable_discovery_error(ctx, .Invalid_Argument, path, "missing runtime type information")
        return false
    }

    #partial switch type.kind {
    case .Bool:
        base_value := any {
            data = value.data,
            id   = info.id,
        }
        v, ok := any_get_bool(base_value)
        return ok && portable_write_byte(w, byte(v))
    case .Signed, .Rune:
        base_value := any {
            data = value.data,
            id   = info.id,
        }
        v, ok := any_get_i64(base_value)
        return ok && portable_write_fixed_u64(w, cast(u64)v, int(type.width))
    case .Unsigned:
        base_value := any {
            data = value.data,
            id   = info.id,
        }
        v, ok := any_get_u64(base_value)
        return ok && portable_write_fixed_u64(w, v, int(type.width))
    case .Float:
        switch type.width {
        case 2:
            v := (^f16)(value.data)^
            return portable_write_u16(w, transmute(u16)v)
        case 4:
            v := (^f32)(value.data)^
            return portable_write_u32(w, transmute(u32)v)
        case 8:
            v := (^f64)(value.data)^
            return portable_write_u64(w, transmute(u64)v)
        }
    case .Quaternion:
        width, metadata_ok := portable_quaternion_width(info)
        if !metadata_ok || width != type.width {
            portable_discovery_error(ctx, .Type_Mismatch, path, "quaternion metadata changed during encoding")
            return false
        }
        switch type.width {
        case 8:
            quaternion_value := (^rt.Raw_Quaternion64)(value.data)
            return(
                portable_write_u16(w, transmute(u16)quaternion_value.imag) &&
                portable_write_u16(w, transmute(u16)quaternion_value.jmag) &&
                portable_write_u16(w, transmute(u16)quaternion_value.kmag) &&
                portable_write_u16(w, transmute(u16)quaternion_value.real) \
            )
        case 16:
            quaternion_value := (^rt.Raw_Quaternion128)(value.data)
            return(
                portable_write_u32(w, transmute(u32)quaternion_value.imag) &&
                portable_write_u32(w, transmute(u32)quaternion_value.jmag) &&
                portable_write_u32(w, transmute(u32)quaternion_value.kmag) &&
                portable_write_u32(w, transmute(u32)quaternion_value.real) \
            )
        }
    case .String:
        v := (^string)(value.data)^
        if len(v) > ctx.config.limits.max_string_bytes {
            portable_discovery_error(ctx, .Limit_Exceeded, path, "string length exceeds limit")
            return false
        }
        return portable_write_string(w, v)
    case .Array:
        array_info, ok := info.variant.(rt.Type_Info_Array)
        if !ok || array_info.count != type.count {
            portable_discovery_error(ctx, .Type_Mismatch, path, "array metadata changed during encoding")
            return false
        }
        bulk_width, bulk_ok := portable_fixed_array_bulk_width(ctx.types[:], type^, array_info)
        if bulk_ok {
            return portable_write_bytes(w, mem.byte_slice(value.data, type.count * bulk_width))
        }
        for i in 0 ..< type.count {
            field := any {
                data = rawptr(uintptr(value.data) + uintptr(i * array_info.elem_size)),
                id   = array_info.elem.id,
            }
            if !portable_encode_value(ctx, w, field, type.elem, path, depth + 1) do return false
        }
        return true
    case .Enumerated_Array:
        array_info, ok := info.variant.(rt.Type_Info_Enumerated_Array)
        if !ok ||
           array_info.is_sparse ||
           array_info.count != type.count ||
           array_info.elem.id != ctx.types[type.elem - 1].id ||
           array_info.index.id != ctx.types[type.index - 1].id {
            portable_discovery_error(ctx, .Type_Mismatch, path, "enumerated array metadata changed during encoding")
            return false
        }
        element_info := rt.type_info_base(array_info.elem)
        if element_info == nil || array_info.elem_size != element_info.size {
            portable_discovery_error(ctx, .Invalid_Metadata, path, "enumerated array element metadata is invalid")
            return false
        }
        for i in 0 ..< type.count {
            field := any {
                data = rawptr(uintptr(value.data) + uintptr(i * array_info.elem_size)),
                id   = array_info.elem.id,
            }
            if !portable_encode_value(ctx, w, field, type.elem, path, depth + 1) do return false
        }
        return true
    case .Dynamic_Array:
        dynamic_info, ok := info.variant.(rt.Type_Info_Dynamic_Array)
        if !ok {
            portable_discovery_error(ctx, .Type_Mismatch, path, "dynamic array metadata changed during encoding")
            return false
        }
        element_info := rt.type_info_base(type_info_of(dynamic_info.elem.id))
        if element_info == nil || dynamic_info.elem_size != element_info.size {
            portable_discovery_error(
                ctx,
                .Type_Mismatch,
                path,
                "dynamic array element metadata changed during encoding",
            )
            return false
        }
        raw := cast(^rt.Raw_Dynamic_Array)value.data
        if raw == nil || raw.len < 0 || raw.cap < raw.len {
            portable_discovery_error(ctx, .Invalid_Metadata, path, "dynamic array header is invalid")
            return false
        }
        if raw.len > ctx.config.limits.max_array_elements {
            portable_discovery_error(ctx, .Limit_Exceeded, path, "dynamic array element count exceeds limit")
            return false
        }
        if raw.len > 0 && raw.data == nil {
            portable_discovery_error(ctx, .Invalid_Metadata, path, "dynamic array has no data for nonzero length")
            return false
        }
        if element_info.size > 0 && raw.len > max(int) / element_info.size {
            portable_discovery_error(ctx, .Overflow, path, "dynamic array byte size overflows")
            return false
        }
        if !portable_write_u64(w, u64(raw.len)) {
            portable_discovery_error(ctx, .Limit_Exceeded, path, "dynamic array exceeds payload limit")
            return false
        }
        for i in 0 ..< raw.len {
            field := any {
                data = rawptr(uintptr(raw.data) + uintptr(i * dynamic_info.elem_size)),
                id   = dynamic_info.elem.id,
            }
            if !portable_encode_value(ctx, w, field, type.elem, path, depth + 1) do return false
        }
        return true
    case .Struct:
        fields := reflect.struct_fields_zipped(value.id)
        field_index := 0
        for field, _ in fields {
            if portable_field_excluded(field, ctx.config) do continue
            if field_index >= len(type.fields) {
                portable_discovery_error(ctx, .Type_Mismatch, path, "struct field metadata changed during encoding")
                return false
            }
            saved_field := type.fields[field_index]
            if saved_field.name != field.name {
                portable_discovery_error(ctx, .Type_Mismatch, path, "struct field order changed during encoding")
                return false
            }
            field_value := any {
                data = rawptr(uintptr(value.data) + field.offset),
                id   = field.type.id,
            }
            checkpoint, field_path, path_ok := portable_path_field_push(&ctx.path, field.name)
            if !path_ok {
                portable_discovery_error(ctx, .Limit_Exceeded, string(ctx.path[:]), "field path allocation failed")
                return false
            }
            field_ok := portable_encode_value(ctx, w, field_value, saved_field.type, field_path, depth + 1)
            portable_path_field_pop(&ctx.path, checkpoint)
            if !field_ok do return false
            field_index += 1
        }
        return field_index == len(type.fields)
    case .Enum:
        enum_info, ok := info.variant.(rt.Type_Info_Enum)
        if !ok {
            portable_discovery_error(ctx, .Type_Mismatch, path, "enum metadata changed during encoding")
            return false
        }
        base := any {
            data = value.data,
            id   = enum_info.base.id,
        }
        return portable_encode_value(ctx, w, base, type.base, path, depth + 1)
    }
    portable_discovery_error(ctx, .Unsupported_Type, path, "value is not portable")
    return false
}

portable_encode_type_table :: proc(ctx: ^Portable_Discovery, w: ^Portable_Writer) -> bool {
    for type in ctx.types {
        if !portable_write_byte(w, byte(type.kind)) || !portable_write_byte(w, type.width) || !portable_write_byte(w, byte(type.signed)) || !portable_write_byte(w, 0) do return false
        #partial switch type.kind {
        case .Array:
            if !portable_write_u32(w, type.elem) || !portable_write_u64(w, u64(type.count)) do return false
        case .Enumerated_Array:
            if !portable_write_u32(w, type.elem) || !portable_write_u32(w, type.index) || !portable_write_u64(w, u64(type.count)) do return false
        case .Dynamic_Array:
            if !portable_write_u32(w, type.elem) do return false
        case .Struct:
            if !portable_write_u32(w, u32(len(type.fields))) do return false
            for field in type.fields {
                if !portable_write_string(w, field.name) || !portable_write_u32(w, field.type) do return false
            }
        case .Enum:
            if !portable_write_u32(w, type.base) || !portable_write_u32(w, u32(len(type.enum_fields))) do return false
            for field in type.enum_fields {
                if !portable_write_string(w, field.name) || !portable_write_i64(w, field.value) do return false
            }
        case:
        }
    }
    return true
}

portable_header_write :: proc(w: ^Portable_Writer, root, type_count, table_bytes, body_bytes: u32) -> bool {
    magic := Portable_Magic
    if !portable_write_bytes(w, magic[:]) || !portable_write_u16(w, Portable_Version) || !portable_write_u16(w, 0) do return false
    return(
        portable_write_u32(w, root) &&
        portable_write_u32(w, type_count) &&
        portable_write_u32(w, table_bytes) &&
        portable_write_u32(w, body_bytes) \
    )
}

// The caller owns the returned byte slice on success and must delete it with the same allocator.
// On failure, the caller must call portable_error_dispose for an allocated error path.
portable_encode :: proc(
    value: any,
    config := PORTABLE_DEFAULT_CONFIG,
    alloc := context.allocator,
) -> (
    data: []byte,
    error: Portable_Error,
    ok: bool,
) {
    if value.data == nil || value.id == nil do return nil, portable_error(.Invalid_Argument, 0, "$", "value has no storage or type"), false
    if alloc.procedure == nil do return nil, portable_error(.Invalid_Argument, 0, "$", "allocator has no procedure"), false
    limits_error := portable_validate_limits(config.limits)
    if limits_error.kind != .None do return nil, limits_error, false

    old_allocator := context.allocator
    context.allocator = alloc
    defer context.allocator = old_allocator

    discovery := Portable_Discovery {
        config = config,
        alloc  = alloc,
    }
    path_storage, path_error := make([dynamic]byte, 0, 64, alloc)
    if path_error != nil {
        return nil, portable_error(.Limit_Exceeded, 0, "$", "field path allocation failed"), false
    }
    discovery.path = path_storage
    defer delete(discovery.path)
    if _, path_error = append(&discovery.path, '$'); path_error != nil {
        return nil, portable_error(.Limit_Exceeded, 0, "$", "field path allocation failed"), false
    }
    types, types_error := make([dynamic]Portable_Type, alloc)
    if types_error != nil {
        return nil, portable_error(.Limit_Exceeded, 0, "$", "type metadata allocation failed"), false
    }
    discovery.types = types
    defer portable_delete_types(discovery.types)
    discovery.handles = make(map[typeid]u32, alloc)
    defer delete(discovery.handles)
    root := portable_discover_type(&discovery, value.id, "$", 0)
    if discovery.error.kind != .None do return nil, discovery.error, false
    graph_error := portable_validate_type_graph(discovery.types[:], root, config.limits, alloc)
    if graph_error.kind != .None do return nil, graph_error, false

    table_storage, table_storage_error := make([dynamic]byte, alloc)
    if table_storage_error != nil {
        return nil, portable_error(.Limit_Exceeded, 0, "$table", "type table allocation failed"), false
    }
    table_writer := Portable_Writer {
        bytes = table_storage,
        limit = config.limits.max_payload,
    }
    defer delete(table_writer.bytes)
    if !portable_encode_type_table(&discovery, &table_writer) {
        if table_writer.allocation_failed {
            return nil,
                portable_error(.Limit_Exceeded, len(table_writer.bytes), "$", "type table allocation failed"),
                false
        }
        return nil,
            portable_error(.Limit_Exceeded, len(table_writer.bytes), "$", "type table exceeds payload limit"),
            false
    }
    body_storage, body_storage_error := make([dynamic]byte, alloc)
    if body_storage_error != nil {
        return nil, portable_error(.Limit_Exceeded, 0, "$", "value body allocation failed"), false
    }
    body_writer := Portable_Writer {
        bytes = body_storage,
        limit = config.limits.max_payload,
    }
    defer delete(body_writer.bytes)
    if !portable_encode_value(&discovery, &body_writer, value, root, "$", 0) {
        if discovery.error.kind != .None do return nil, discovery.error, false
        if body_writer.allocation_failed {
            return nil,
                portable_error(.Limit_Exceeded, len(body_writer.bytes), "$", "value body allocation failed"),
                false
        }
        return nil, portable_error(.Limit_Exceeded, len(body_writer.bytes), "$", "value exceeds payload limit"), false
    }

    output, output_error := make([dynamic]byte, alloc)
    if output_error != nil {
        return nil, portable_error(.Limit_Exceeded, 0, "$", "payload allocation failed"), false
    }
    output_writer := Portable_Writer {
        bytes = output,
        limit = config.limits.max_payload,
    }
    defer delete(output_writer.bytes)
    if !portable_header_write(
           &output_writer,
           root,
           u32(len(discovery.types)),
           u32(len(table_writer.bytes)),
           u32(len(body_writer.bytes)),
       ) ||
       !portable_write_bytes(&output_writer, table_writer.bytes[:]) ||
       !portable_write_bytes(&output_writer, body_writer.bytes[:]) {
        if output_writer.allocation_failed {
            return nil,
                portable_error(.Limit_Exceeded, len(output_writer.bytes), "$", "payload allocation failed"),
                false
        }
        return nil, portable_error(.Limit_Exceeded, len(output_writer.bytes), "$", "payload exceeds limit"), false
    }
    result, result_error := make([]byte, len(output_writer.bytes), alloc)
    if result_error != nil {
        return nil, portable_error(.Limit_Exceeded, 0, "$", "result allocation failed"), false
    }
    copy(result, output_writer.bytes[:])
    return result, portable_no_error(), true
}

Portable_Reader :: struct {
    data:   []byte,
    cursor: int,
    alloc:  mem.Allocator,
    error:  Portable_Error,
}

portable_reader_fail :: proc(r: ^Portable_Reader, kind: Portable_Error_Kind, path, message: string) {
    if r.error.kind == .None {
        copied_path, path_owned := portable_copy_error_path(path, r.alloc)
        r.error = portable_error(kind, r.cursor, copied_path, message)
        r.error.path_owned = path_owned
        r.error.path_allocator = r.alloc
    }
}

portable_reader_need :: proc(r: ^Portable_Reader, count: int, path: string) -> bool {
    if count < 0 || count > len(r.data) - r.cursor {
        portable_reader_fail(r, .Truncated, path, "payload ends before requested bytes")
        return false
    }
    return true
}

portable_read_u8 :: proc(r: ^Portable_Reader, path: string) -> (value: u8, ok: bool) {
    if !portable_reader_need(r, 1, path) do return 0, false
    value = r.data[r.cursor]
    r.cursor += 1
    return value, true
}

portable_read_u16 :: proc(r: ^Portable_Reader, path: string) -> (value: u16, ok: bool) {
    if !portable_reader_need(r, 2, path) do return 0, false
    value = u16(r.data[r.cursor]) | u16(r.data[r.cursor + 1]) << 8
    r.cursor += 2
    return value, true
}

portable_read_u32 :: proc(r: ^Portable_Reader, path: string) -> (value: u32, ok: bool) {
    if !portable_reader_need(r, 4, path) do return 0, false
    value =
        u32(r.data[r.cursor]) |
        u32(r.data[r.cursor + 1]) << 8 |
        u32(r.data[r.cursor + 2]) << 16 |
        u32(r.data[r.cursor + 3]) << 24
    r.cursor += 4
    return value, true
}

portable_read_u64 :: proc(r: ^Portable_Reader, path: string) -> (value: u64, ok: bool) {
    if !portable_reader_need(r, 8, path) do return 0, false
    for i in 0 ..< 8 {
        value |= u64(r.data[r.cursor + i]) << (u64(i) * 8)
    }
    r.cursor += 8
    return value, true
}

portable_read_fixed_u64 :: proc(r: ^Portable_Reader, width: int, path: string) -> (value: u64, ok: bool) {
    if width < 1 || width > 8 {
        portable_reader_fail(r, .Invalid_Metadata, path, "scalar width is invalid")
        return 0, false
    }
    bytes, bytes_ok := portable_read_bytes(r, width, path)
    if !bytes_ok do return 0, false
    for i in 0 ..< width {
        value |= u64(bytes[i]) << (u64(i) * 8)
    }
    return value, true
}

portable_fixed_to_i64 :: proc(value: u64, width: int) -> i64 {
    bits := value
    if width < 8 && (bits & (u64(1) << (u64(width) * 8 - 1))) != 0 {
        bits |= ~u64(0) << (u64(width) * 8)
    }
    return cast(i64)bits
}

portable_read_i64 :: proc(r: ^Portable_Reader, path: string) -> (value: i64, ok: bool) {
    bits, bits_ok := portable_read_u64(r, path)
    return cast(i64)bits, bits_ok
}

portable_read_bytes :: proc(r: ^Portable_Reader, count: int, path: string) -> (value: []byte, ok: bool) {
    if !portable_reader_need(r, count, path) do return nil, false
    value = r.data[r.cursor:r.cursor + count]
    r.cursor += count
    return value, true
}

// Read a scalar-array body without changing the recursive decoder's truncated-input cursor.
portable_read_fixed_array_bytes :: proc(
    r: ^Portable_Reader,
    count, element_width: int,
    path: string,
) -> (
    value: []byte,
    ok: bool,
) {
    if count < 0 || element_width <= 0 {
        portable_reader_fail(r, .Invalid_Metadata, path, "fixed array byte count is invalid")
        return nil, false
    }
    available := len(r.data) - r.cursor
    complete := min(count, available)
    complete -= complete % element_width
    value = r.data[r.cursor:r.cursor + complete]
    r.cursor += complete
    if complete != count {
        portable_reader_fail(r, .Truncated, path, "payload ends before requested bytes")
        return value, false
    }
    return value, true
}

portable_read_string :: proc(r: ^Portable_Reader, max_bytes: int, path: string) -> (value: string, ok: bool) {
    if max_bytes < 0 {
        portable_reader_fail(r, .Limit_Exceeded, path, "string limit is invalid")
        return "", false
    }
    length, length_ok := portable_read_u32(r, path)
    if !length_ok do return "", false
    if u64(length) > u64(max_bytes) {
        portable_reader_fail(r, .Limit_Exceeded, path, "string length exceeds limit")
        return "", false
    }
    if u64(length) > u64(len(r.data) - r.cursor) {
        portable_reader_fail(r, .Truncated, path, "string length exceeds payload")
        return "", false
    }
    bytes, bytes_ok := portable_read_bytes(r, int(length), path)
    if !bytes_ok do return "", false
    value = string(bytes)
    if !utf8.valid_string(value) {
        portable_reader_fail(r, .Invalid_Metadata, path, "string is not valid UTF-8")
        return "", false
    }
    return value, true
}

portable_handle_valid :: proc(handle: u32, type_count: int) -> bool {
    return handle != 0 && u64(handle) <= u64(type_count)
}

portable_saved_type_valid :: proc(type: Portable_Type, type_count: int, limits: Portable_Limits) -> bool {
    #partial switch type.kind {
    case .Bool:
        return type.width == 1 && !type.signed
    case .Signed:
        return (type.width == 1 || type.width == 2 || type.width == 4 || type.width == 8) && type.signed
    case .Unsigned:
        return (type.width == 1 || type.width == 2 || type.width == 4 || type.width == 8) && !type.signed
    case .Rune:
        return type.width == 4 && type.signed
    case .Float:
        return (type.width == 2 || type.width == 4 || type.width == 8) && !type.signed
    case .Quaternion:
        return(
            (type.width == 8 || type.width == 16) &&
            !type.signed &&
            type.elem == 0 &&
            type.index == 0 &&
            type.count == 0 &&
            type.base == 0 &&
            len(type.fields) == 0 &&
            len(type.enum_fields) == 0 \
        )
    case .String:
        return type.width == 0 && !type.signed
    case .Array:
        return(
            !type.signed &&
            type.width == 0 &&
            portable_handle_valid(type.elem, type_count) &&
            type.count >= 0 &&
            type.count <= limits.max_array_elements \
        )
    case .Enumerated_Array:
        return !type.signed && type.width == 0 && type.count > 0 && type.count <= limits.max_array_elements
    case .Dynamic_Array:
        return !type.signed && type.width == 0
    case .Struct:
        return !type.signed && type.width == 0 && len(type.fields) <= limits.max_fields
    case .Enum:
        return !type.signed && type.width == 0 && portable_handle_valid(type.base, type_count)
    case:
        return false
    }
}

portable_parse_type_table :: proc(
    data: []byte,
    type_count: int,
    limits: Portable_Limits,
    alloc: mem.Allocator,
) -> (
    types: [dynamic]Portable_Type,
    error: Portable_Error,
    ok: bool,
) {
    if type_count <= 0 || u64(type_count) > u64(len(data) / 4) {
        return nil, portable_error(.Limit_Exceeded, 0, "$table", "type count cannot fit in table"), false
    }
    reader := Portable_Reader {
        data  = data,
        alloc = alloc,
    }
    allocation_error: mem.Allocator_Error
    types, allocation_error = make([dynamic]Portable_Type, 0, type_count, alloc)
    if allocation_error != nil {
        return nil, portable_error(.Limit_Exceeded, 0, "$table", "type table allocation failed"), false
    }
    defer if !ok do portable_delete_types(types)
    names, names_error := make(map[string]bool, 0, alloc)
    if names_error != nil {
        return types, portable_error(.Limit_Exceeded, 0, "$table", "name index allocation failed"), false
    }
    defer delete(names)
    total_fields := 0
    for type_index in 0 ..< type_count {
        kind_byte, kind_ok := portable_read_u8(&reader, "$table")
        width, width_ok := portable_read_u8(&reader, "$table")
        signed_byte, signed_ok := portable_read_u8(&reader, "$table")
        reserved_byte, reserved_ok := portable_read_u8(&reader, "$table")
        if !kind_ok || !width_ok || !signed_ok || !reserved_ok do return types, reader.error, false
        if signed_byte > 1 || reserved_byte != 0 {
            portable_reader_fail(&reader, .Invalid_Metadata, "$table", "reserved type metadata is not zero")
            return types, reader.error, false
        }
        if kind_byte > u8(Portable_Kind.Quaternion) {
            portable_reader_fail(&reader, .Invalid_Metadata, "$table", "unknown type kind")
            return types, reader.error, false
        }
        _, append_error := append(
            &types,
            Portable_Type{kind = Portable_Kind(kind_byte), width = width, signed = signed_byte != 0},
        )
        if append_error != nil {
            return types,
                portable_error(.Limit_Exceeded, reader.cursor, "$table", "type metadata allocation failed"),
                false
        }
        type := &types[len(types) - 1]
        #partial switch type.kind {
        case .Array:
            elem, elem_ok := portable_read_u32(&reader, "$table.array")
            count, count_ok := portable_read_u64(&reader, "$table.array")
            if !elem_ok || !count_ok do return types, reader.error, false
            if count > u64(max(0, limits.max_array_elements)) {
                portable_reader_fail(&reader, .Limit_Exceeded, "$table.array", "array count exceeds limit")
                return types, reader.error, false
            }
            type.elem = elem
            type.count = int(count)
        case .Enumerated_Array:
            elem, elem_ok := portable_read_u32(&reader, "$table.enumerated_array")
            index_handle, index_ok := portable_read_u32(&reader, "$table.enumerated_array")
            count, count_ok := portable_read_u64(&reader, "$table.enumerated_array")
            if !elem_ok || !index_ok || !count_ok do return types, reader.error, false
            if count == 0 || count > u64(max(0, limits.max_array_elements)) {
                portable_reader_fail(
                    &reader,
                    .Limit_Exceeded,
                    "$table.enumerated_array",
                    "enumerated array count exceeds limit",
                )
                return types, reader.error, false
            }
            type.elem = elem
            type.index = index_handle
            type.count = int(count)
        case .Dynamic_Array:
            elem, elem_ok := portable_read_u32(&reader, "$table.dynamic_array")
            if !elem_ok do return types, reader.error, false
            type.elem = elem
        case .Struct:
            field_count, field_ok := portable_read_u32(&reader, "$table.struct")
            if !field_ok do return types, reader.error, false
            field_limit := max(0, limits.max_fields)
            if u64(field_count) > u64(field_limit) || total_fields > field_limit - int(field_count) {
                portable_reader_fail(&reader, .Limit_Exceeded, "$table.struct", "field count exceeds limit")
                return types, reader.error, false
            }
            for name in names do delete_key(&names, name)
            for _ in 0 ..< int(field_count) {
                field_path := "$table.struct"
                name, name_ok := portable_read_string(&reader, limits.max_string_bytes, field_path)
                handle, handle_ok := portable_read_u32(&reader, field_path)
                if !name_ok || !handle_ok do return types, reader.error, false
                if name == "" {
                    portable_reader_fail(&reader, .Invalid_Metadata, field_path, "field name is empty")
                    return types, reader.error, false
                }
                if _, exists := names[name]; exists {
                    portable_reader_fail(&reader, .Invalid_Metadata, field_path, "duplicate field name")
                    return types, reader.error, false
                }
                _, name_ptr, _, name_error := map_entry(&names, name)
                if name_error != nil {
                    portable_reader_fail(&reader, .Limit_Exceeded, field_path, "field-name index allocation failed")
                    return types, reader.error, false
                }
                name_ptr^ = true
                _, field_error := append(&type.fields, Portable_Field{name = name, type = handle})
                if field_error != nil {
                    portable_reader_fail(&reader, .Limit_Exceeded, field_path, "field metadata allocation failed")
                    return types, reader.error, false
                }
            }
            total_fields += int(field_count)
        case .Enum:
            base, base_ok := portable_read_u32(&reader, "$table.enum")
            field_count, field_ok := portable_read_u32(&reader, "$table.enum")
            if !base_ok || !field_ok do return types, reader.error, false
            field_limit := max(0, limits.max_fields)
            if u64(field_count) > u64(field_limit) || total_fields > field_limit - int(field_count) {
                portable_reader_fail(&reader, .Limit_Exceeded, "$table.enum", "enum field count exceeds limit")
                return types, reader.error, false
            }
            type.base = base
            for name in names do delete_key(&names, name)
            for _ in 0 ..< int(field_count) {
                field_path := "$table.enum"
                name, name_ok := portable_read_string(&reader, limits.max_string_bytes, field_path)
                value, value_ok := portable_read_i64(&reader, field_path)
                if !name_ok || !value_ok do return types, reader.error, false
                if name == "" {
                    portable_reader_fail(&reader, .Invalid_Metadata, field_path, "enum name is empty")
                    return types, reader.error, false
                }
                if _, exists := names[name]; exists {
                    portable_reader_fail(&reader, .Invalid_Metadata, field_path, "duplicate enum name")
                    return types, reader.error, false
                }
                _, name_ptr, _, name_error := map_entry(&names, name)
                if name_error != nil {
                    portable_reader_fail(&reader, .Limit_Exceeded, field_path, "enum-name index allocation failed")
                    return types, reader.error, false
                }
                name_ptr^ = true
                _, field_error := append(&type.enum_fields, Portable_Enum_Field{name = name, value = value})
                if field_error != nil {
                    portable_reader_fail(&reader, .Limit_Exceeded, field_path, "enum metadata allocation failed")
                    return types, reader.error, false
                }
            }
            total_fields += int(field_count)
        case:
        }
        if !portable_saved_type_valid(type^, type_count, limits) {
            portable_reader_fail(&reader, .Invalid_Metadata, "$table", "invalid type metadata")
            return types, reader.error, false
        }
    }
    if reader.cursor != len(reader.data) {
        portable_reader_fail(&reader, .Invalid_Metadata, "$table", "type table has trailing bytes")
        return types, reader.error, false
    }
    for type in types {
        if type.kind == .Array && !portable_handle_valid(type.elem, type_count) {
            return types,
                portable_error(.Invalid_Handle, reader.cursor, "$table.array", "array element handle is invalid"),
                false
        }
        if type.kind == .Enumerated_Array &&
           (!portable_handle_valid(type.elem, type_count) || !portable_handle_valid(type.index, type_count)) {
            return types,
                portable_error(
                    .Invalid_Handle,
                    reader.cursor,
                    "$table.enumerated_array",
                    "enumerated array element or index handle is invalid",
                ),
                false
        }
        if type.kind == .Dynamic_Array && !portable_handle_valid(type.elem, type_count) {
            return types,
                portable_error(
                    .Invalid_Handle,
                    reader.cursor,
                    "$table.dynamic_array",
                    "dynamic array element handle is invalid",
                ),
                false
        }
        if type.kind == .Struct {
            for field in type.fields {
                if !portable_handle_valid(field.type, type_count) do return types, portable_error(.Invalid_Handle, reader.cursor, "$table.struct", "field type handle is invalid"), false
            }
        }
        if type.kind == .Enum && !portable_handle_valid(type.base, type_count) {
            return types,
                portable_error(.Invalid_Handle, reader.cursor, "$table.enum", "enum base handle is invalid"),
                false
        }
    }
    return types, portable_no_error(), true
}

Portable_Graph_State :: enum u8 {
    Unseen,
    Visiting,
    Complete,
}

portable_enum_value_fits :: proc(type: Portable_Type, value: i64) -> bool {
    if type.kind == .Unsigned {
        if value < 0 do return false
        if type.width == 8 do return u64(value) <= u64(max(i64))
        max_value := (u64(1) << (u64(type.width) * 8)) - 1
        return u64(value) <= max_value
    }
    if type.kind != .Signed && type.kind != .Rune do return false
    bits := int(type.width) * 8
    if bits == 64 do return true
    max_value := i64((u64(1) << u64(bits - 1)) - 1)
    min_value := -i64(u64(1) << u64(bits - 1))
    return min_value <= value && value <= max_value
}

portable_validate_graph_type :: proc(
    types: []Portable_Type,
    handle: u32,
    states: []u8,
    depth: int,
    max_depth: int,
) -> Portable_Error {
    if depth > max_depth do return portable_error(.Limit_Exceeded, 0, "$table", "maximum type graph depth exceeded")
    if !portable_handle_valid(handle, len(types)) do return portable_error(.Invalid_Handle, 0, "$table", "type handle is invalid")
    index := int(handle - 1)
    #partial switch Portable_Graph_State(states[index]) {
    case .Complete:
        return portable_no_error()
    case .Visiting:
        return portable_error(.Invalid_Metadata, 0, "$table", "by-value type graph contains a cycle")
    case:
    }
    states[index] = u8(Portable_Graph_State.Visiting)
    type := types[index]
    #partial switch type.kind {
    case .Array:
        graph_error := portable_validate_graph_type(types, type.elem, states, depth + 1, max_depth)
        if graph_error.kind != .None do return graph_error
    case .Enumerated_Array:
        graph_error := portable_validate_graph_type(types, type.elem, states, depth + 1, max_depth)
        if graph_error.kind != .None do return graph_error
        graph_error = portable_validate_graph_type(types, type.index, states, depth + 1, max_depth)
        if graph_error.kind != .None do return graph_error
    case .Dynamic_Array:
        graph_error := portable_validate_graph_type(types, type.elem, states, depth + 1, max_depth)
        if graph_error.kind != .None do return graph_error
    case .Struct:
        for field in type.fields {
            graph_error := portable_validate_graph_type(types, field.type, states, depth + 1, max_depth)
            if graph_error.kind != .None do return graph_error
        }
    case .Enum:
        if !portable_handle_valid(type.base, len(types)) do return portable_error(.Invalid_Handle, 0, "$table.enum", "enum base handle is invalid")
        base := types[type.base - 1]
        if base.kind != .Signed && base.kind != .Unsigned && base.kind != .Rune {
            return portable_error(.Invalid_Metadata, 0, "$table.enum", "enum base is not a scalar integer")
        }
        for field in type.enum_fields {
            if !portable_enum_value_fits(base, field.value) {
                return portable_error(.Invalid_Metadata, 0, "$table.enum", "enum value exceeds base width")
            }
        }
        graph_error := portable_validate_graph_type(types, type.base, states, depth + 1, max_depth)
        if graph_error.kind != .None do return graph_error
    case:
    }
    states[index] = u8(Portable_Graph_State.Complete)
    return portable_no_error()
}

portable_validate_enumerated_array_type :: proc(
    types: []Portable_Type,
    type: Portable_Type,
    alloc: mem.Allocator,
) -> Portable_Error {
    if !portable_handle_valid(type.index, len(types)) {
        return portable_error(
            .Invalid_Handle,
            0,
            "$table.enumerated_array",
            "enumerated array index handle is invalid",
        )
    }
    index_type := types[type.index - 1]
    if index_type.kind != .Enum {
        return portable_error(.Invalid_Metadata, 0, "$table.enumerated_array", "enumerated array index is not an enum")
    }
    if type.count <= 0 || len(index_type.enum_fields) != type.count {
        return portable_error(
            .Invalid_Metadata,
            0,
            "$table.enumerated_array",
            "enumerated array count does not match index enum",
        )
    }

    min_value := index_type.enum_fields[0].value
    max_value := min_value
    for field in index_type.enum_fields {
        min_value = min(min_value, field.value)
        max_value = max(max_value, field.value)
    }
    if u64(type.count - 1) > u64(max(i64)) ||
       min_value > max(i64) - i64(type.count - 1) ||
       min_value + i64(type.count - 1) != max_value {
        return portable_error(
            .Invalid_Metadata,
            0,
            "$table.enumerated_array",
            "enumerated array index range is not contiguous",
        )
    }

    seen, allocation_error := make([]bool, type.count, alloc)
    if allocation_error != nil {
        return portable_error(
            .Limit_Exceeded,
            0,
            "$table.enumerated_array",
            "enumerated array validation allocation failed",
        )
    }
    defer delete(seen, alloc)
    for field in index_type.enum_fields {
        offset := u64(field.value) - u64(min_value)
        if offset >= u64(type.count) || seen[int(offset)] {
            return portable_error(
                .Invalid_Metadata,
                0,
                "$table.enumerated_array",
                "enumerated array index values are not unique and contiguous",
            )
        }
        seen[int(offset)] = true
    }
    return portable_no_error()
}

portable_validate_type_graph :: proc(
    types: []Portable_Type,
    root: u32,
    limits: Portable_Limits,
    alloc: mem.Allocator,
) -> Portable_Error {
    states, allocation_error := make([]u8, len(types), alloc)
    if allocation_error != nil {
        return portable_error(.Limit_Exceeded, 0, "$table", "type graph state allocation failed")
    }
    defer delete(states, alloc)
    graph_error := portable_validate_graph_type(types, root, states, 0, limits.max_recursion_depth)
    if graph_error.kind != .None do return graph_error
    for state in states {
        if Portable_Graph_State(state) == .Unseen {
            return portable_error(.Invalid_Metadata, 0, "$table", "type table contains unreachable metadata")
        }
    }
    for type in types {
        if type.kind == .Enumerated_Array {
            enum_array_error := portable_validate_enumerated_array_type(types, type, alloc)
            if enum_array_error.kind != .None do return enum_array_error
        }
    }
    return portable_no_error()
}

Portable_Decoder :: struct {
    types:  []Portable_Type,
    reader: Portable_Reader,
    config: Portable_Config,
    alloc:  mem.Allocator,
    path:   [dynamic]byte,
}

portable_decoder_fail :: proc(ctx: ^Portable_Decoder, kind: Portable_Error_Kind, path, message: string) {
    if ctx.reader.error.kind == .None do portable_reader_fail(&ctx.reader, kind, path, message)
}

portable_dynamic_destination_init :: proc(
    ctx: ^Portable_Decoder,
    destination: any,
    count: int,
    element_info: ^rt.Type_Info,
    path: string,
) -> bool {
    raw := cast(^rt.Raw_Dynamic_Array)destination.data
    if raw == nil {
        portable_decoder_fail(ctx, .Invalid_Argument, path, "dynamic array destination has no header")
        return false
    }
    if raw.data != nil || raw.len != 0 || raw.cap != 0 || raw.allocator.procedure != nil {
        portable_decoder_fail(ctx, .Type_Mismatch, path, "destination dynamic array already owns storage")
        return false
    }
    raw.allocator = ctx.alloc
    raw.len = count
    raw.cap = count
    if count == 0 do return true
    if element_info == nil || element_info.size < 0 || element_info.align <= 0 {
        portable_decoder_fail(ctx, .Invalid_Metadata, path, "dynamic array element metadata is invalid")
        return false
    }
    if element_info.size > 0 && count > max(int) / element_info.size {
        portable_decoder_fail(ctx, .Overflow, path, "dynamic array byte size overflows")
        return false
    }
    backing, allocation_error := mem.alloc_bytes(count * element_info.size, element_info.align, ctx.alloc)
    if allocation_error != nil || backing == nil {
        portable_decoder_fail(ctx, .Limit_Exceeded, path, "dynamic array allocation failed")
        return false
    }
    raw.data = raw_data(backing)
    return true
}

portable_skip_value :: proc(ctx: ^Portable_Decoder, handle: u32, input_path: string, depth: int) {
    path := string(ctx.path[:])
    if len(ctx.path) == 0 do path = input_path
    if ctx.reader.error.kind != .None do return
    if depth > ctx.config.limits.max_recursion_depth {
        portable_decoder_fail(ctx, .Limit_Exceeded, path, "maximum recursion depth exceeded")
        return
    }
    if !portable_handle_valid(handle, len(ctx.types)) {
        portable_decoder_fail(ctx, .Invalid_Handle, path, "invalid saved type handle")
        return
    }
    type := ctx.types[handle - 1]
    #partial switch type.kind {
    case .Bool:
        _, _ = portable_read_u8(&ctx.reader, path)
    case .Signed, .Unsigned, .Rune, .Float, .Quaternion:
        _, _ = portable_read_bytes(&ctx.reader, int(type.width), path)
    case .String:
        _, _ = portable_read_string(&ctx.reader, ctx.config.limits.max_string_bytes, path)
    case .Array, .Enumerated_Array:
        for _ in 0 ..< type.count {
            portable_skip_value(ctx, type.elem, path, depth + 1)
            if ctx.reader.error.kind != .None do return
        }
    case .Dynamic_Array:
        count, count_ok := portable_read_u64(&ctx.reader, path)
        if !count_ok do return
        if count > u64(ctx.config.limits.max_array_elements) || count > u64(max(int)) {
            portable_decoder_fail(ctx, .Limit_Exceeded, path, "dynamic array element count exceeds limit")
            return
        }
        for _ in 0 ..< int(count) {
            portable_skip_value(ctx, type.elem, path, depth + 1)
            if ctx.reader.error.kind != .None do return
        }
    case .Struct:
        for field in type.fields {
            checkpoint, field_path, path_ok := portable_path_field_push(&ctx.path, field.name)
            if !path_ok {
                portable_decoder_fail(ctx, .Limit_Exceeded, string(ctx.path[:]), "field path allocation failed")
                return
            }
            portable_skip_value(ctx, field.type, field_path, depth + 1)
            portable_path_field_pop(&ctx.path, checkpoint)
            if ctx.reader.error.kind != .None do return
        }
    case .Enum:
        if !portable_handle_valid(type.base, len(ctx.types)) {
            portable_decoder_fail(ctx, .Invalid_Handle, path, "invalid saved enum base handle")
            return
        }
        base := ctx.types[type.base - 1]
        bits, bits_ok := portable_read_fixed_u64(&ctx.reader, int(base.width), path)
        if !bits_ok do return
        value: i64
        if base.kind == .Unsigned {
            if bits > u64(max(i64)) {
                portable_decoder_fail(ctx, .Invalid_Metadata, path, "enum value exceeds signed wire domain")
                return
            }
            value = i64(bits)
        } else if base.kind == .Signed || base.kind == .Rune {
            value = portable_fixed_to_i64(bits, int(base.width))
        } else {
            portable_decoder_fail(ctx, .Invalid_Metadata, path, "enum base is not an integer")
            return
        }
        if !portable_saved_enum_value_valid(type, value) {
            portable_decoder_fail(ctx, .Invalid_Metadata, path, "enum body value is not declared")
        }
    case:
        portable_decoder_fail(ctx, .Invalid_Metadata, path, "invalid saved type")
    }
}

portable_find_current_field :: proc(
    id: typeid,
    name: string,
    config: Portable_Config,
) -> (
    field: reflect.Struct_Field,
    found: bool,
) {
    for candidate, _ in reflect.struct_fields_zipped(id) {
        if candidate.name == name && !portable_field_excluded(candidate, config) do return candidate, true
    }
    return {}, false
}

portable_enum_value_valid :: proc(id: typeid, value: i64) -> bool {
    info := rt.type_info_base(type_info_of(id))
    if enum_info, ok := info.variant.(rt.Type_Info_Enum); ok {
        for candidate in enum_info.values {
            if i64(candidate) == value do return true
        }
    }
    return false
}

portable_saved_enum_value_valid :: proc(type: Portable_Type, value: i64) -> bool {
    for field in type.enum_fields {
        if field.value == value do return true
    }
    return false
}

portable_decode_value :: proc(
    ctx: ^Portable_Decoder,
    handle: u32,
    destination: any,
    current_id: typeid,
    input_path: string,
    depth: int,
) {
    path := string(ctx.path[:])
    if len(ctx.path) == 0 do path = input_path
    if ctx.reader.error.kind != .None do return
    if depth > ctx.config.limits.max_recursion_depth {
        portable_decoder_fail(ctx, .Limit_Exceeded, path, "maximum recursion depth exceeded")
        return
    }
    if !portable_handle_valid(handle, len(ctx.types)) {
        portable_decoder_fail(ctx, .Invalid_Handle, path, "invalid saved type handle")
        return
    }
    saved := ctx.types[handle - 1]
    current_info := rt.type_info_base(type_info_of(current_id))
    if current_info == nil {
        portable_decoder_fail(ctx, .Invalid_Argument, path, "missing current runtime type information")
        return
    }

    #partial switch saved.kind {
    case .Bool, .Signed, .Unsigned, .Rune, .Float, .String:
        current_kind, current_width, current_signed, current_ok := portable_type_kind(current_info)
        if !current_ok ||
           current_kind != saved.kind ||
           current_width != saved.width ||
           current_signed != saved.signed {
            portable_decoder_fail(ctx, .Type_Mismatch, path, "saved scalar does not match destination")
            return
        }
        #partial switch saved.kind {
        case .Bool:
            value, ok := portable_read_u8(&ctx.reader, path)
            if !ok do return
            if value > 1 {
                portable_decoder_fail(ctx, .Invalid_Metadata, path, "boolean value is not 0 or 1")
                return
            }
            any_assign_bool(any{data = destination.data, id = current_info.id}, value != 0)
        case .Signed, .Rune:
            bits, ok := portable_read_fixed_u64(&ctx.reader, int(saved.width), path)
            if !ok do return
            any_assign_i64(
                any{data = destination.data, id = current_info.id},
                portable_fixed_to_i64(bits, int(saved.width)),
            )
        case .Unsigned:
            value, ok := portable_read_fixed_u64(&ctx.reader, int(saved.width), path)
            if !ok do return
            any_assign_u64(any{data = destination.data, id = current_info.id}, value)
        case .Float:
            bits, ok := portable_read_bytes(&ctx.reader, int(saved.width), path)
            if !ok do return
            switch saved.width {
            case 2:
                bits16 := u16(bits[0]) | u16(bits[1]) << 8
                (^f16)(destination.data)^ = transmute(f16)bits16
            case 4:
                value := u32(bits[0]) | u32(bits[1]) << 8 | u32(bits[2]) << 16 | u32(bits[3]) << 24
                (^f32)(destination.data)^ = transmute(f32)value
            case 8:
                value: u64
                for i in 0 ..< 8 {
                    value |= u64(bits[i]) << (u64(i) * 8)
                }
                (^f64)(destination.data)^ = transmute(f64)value
            }
        case .String:
            value, ok := portable_read_string(&ctx.reader, ctx.config.limits.max_string_bytes, path)
            if !ok do return
            clone, clone_err := strings.clone(value, ctx.alloc)
            if clone_err != nil {
                portable_decoder_fail(ctx, .Limit_Exceeded, path, "string allocation failed")
                return
            }
            (^string)(destination.data)^ = clone
        }
    case .Quaternion:
        current_width, current_ok := portable_quaternion_width(current_info)
        if !current_ok || current_width != saved.width || saved.signed {
            portable_decoder_fail(ctx, .Type_Mismatch, path, "saved quaternion does not match destination")
            return
        }
        bits, bits_ok := portable_read_bytes(&ctx.reader, int(saved.width), path)
        if !bits_ok do return
        switch saved.width {
        case 8:
            imag_bits := u16(bits[0]) | u16(bits[1]) << 8
            jmag_bits := u16(bits[2]) | u16(bits[3]) << 8
            kmag_bits := u16(bits[4]) | u16(bits[5]) << 8
            real_bits := u16(bits[6]) | u16(bits[7]) << 8
            value := (^rt.Raw_Quaternion64)(destination.data)
            value.imag = transmute(f16)imag_bits
            value.jmag = transmute(f16)jmag_bits
            value.kmag = transmute(f16)kmag_bits
            value.real = transmute(f16)real_bits
        case 16:
            imag_bits := u32(bits[0]) | u32(bits[1]) << 8 | u32(bits[2]) << 16 | u32(bits[3]) << 24
            jmag_bits := u32(bits[4]) | u32(bits[5]) << 8 | u32(bits[6]) << 16 | u32(bits[7]) << 24
            kmag_bits := u32(bits[8]) | u32(bits[9]) << 8 | u32(bits[10]) << 16 | u32(bits[11]) << 24
            real_bits := u32(bits[12]) | u32(bits[13]) << 8 | u32(bits[14]) << 16 | u32(bits[15]) << 24
            value := (^rt.Raw_Quaternion128)(destination.data)
            value.imag = transmute(f32)imag_bits
            value.jmag = transmute(f32)jmag_bits
            value.kmag = transmute(f32)kmag_bits
            value.real = transmute(f32)real_bits
        }
    case .Array:
        dynamic_info, dynamic_ok := current_info.variant.(rt.Type_Info_Dynamic_Array)
        if dynamic_ok {
            element_info := rt.type_info_base(type_info_of(dynamic_info.elem.id))
            if element_info == nil || dynamic_info.elem_size != element_info.size {
                portable_decoder_fail(ctx, .Type_Mismatch, path, "destination dynamic array metadata is invalid")
                return
            }
            if !portable_dynamic_destination_init(ctx, destination, saved.count, element_info, path) do return
            raw_destination := cast(^rt.Raw_Dynamic_Array)destination.data
            for i in 0 ..< saved.count {
                field := any {
                    data = rawptr(uintptr(raw_destination.data) + uintptr(i * dynamic_info.elem_size)),
                    id   = dynamic_info.elem.id,
                }
                portable_decode_value(ctx, saved.elem, field, dynamic_info.elem.id, path, depth + 1)
                if ctx.reader.error.kind != .None do return
            }
            return
        }
        array_info, array_ok := current_info.variant.(rt.Type_Info_Array)
        if !array_ok {
            portable_decoder_fail(ctx, .Type_Mismatch, path, "saved array does not match destination")
            return
        }
        decode_count := saved.count
        if decode_count > array_info.count do decode_count = array_info.count
        bulk_width, bulk_ok := portable_fixed_array_bulk_width(ctx.types, saved, array_info)
        if bulk_ok && decode_count == saved.count {
            bytes, bytes_ok := portable_read_fixed_array_bytes(&ctx.reader, saved.count * bulk_width, bulk_width, path)
            copy(mem.byte_slice(destination.data, len(bytes)), bytes)
            if !bytes_ok do return
            return
        }
        for i in 0 ..< decode_count {
            field := any {
                data = rawptr(uintptr(destination.data) + uintptr(i * array_info.elem_size)),
                id   = array_info.elem.id,
            }
            portable_decode_value(ctx, saved.elem, field, array_info.elem.id, path, depth + 1)
            if ctx.reader.error.kind != .None do return
        }
        for _ in decode_count ..< saved.count {
            portable_skip_value(ctx, saved.elem, path, depth + 1)
            if ctx.reader.error.kind != .None do return
        }
    case .Enumerated_Array:
        array_info, array_ok := current_info.variant.(rt.Type_Info_Enumerated_Array)
        if !array_ok {
            portable_decoder_fail(ctx, .Type_Mismatch, path, "saved enumerated array does not match destination")
            return
        }
        current_index, current_min, current_metadata_ok := portable_runtime_enumerated_array_info(array_info)
        if !current_metadata_ok {
            portable_decoder_fail(ctx, .Invalid_Metadata, path, "destination enumerated array metadata is invalid")
            return
        }
        saved_index := ctx.types[saved.index - 1]
        saved_base := ctx.types[saved_index.base - 1]
        current_base_info := rt.type_info_base(current_index.base)
        current_kind, current_width, current_signed, current_base_ok := portable_type_kind(current_base_info)
        if !current_base_ok ||
           current_kind != saved_base.kind ||
           current_width != saved_base.width ||
           current_signed != saved_base.signed {
            portable_decoder_fail(ctx, .Type_Mismatch, path, "enumerated array index base does not match destination")
            return
        }
        saved_min := saved_index.enum_fields[0].value
        for field in saved_index.enum_fields {
            saved_min = min(saved_min, field.value)
        }
        current_max := i64(array_info.max_value)
        for i in 0 ..< saved.count {
            if saved_min > max(i64) - i64(i) {
                portable_decoder_fail(ctx, .Overflow, path, "saved enumerated array index overflows")
                return
            }
            logical_index := saved_min + i64(i)
            if logical_index < current_min || logical_index > current_max {
                portable_skip_value(ctx, saved.elem, path, depth + 1)
            } else {
                destination_index := logical_index - current_min
                field := any {
                    data = rawptr(uintptr(destination.data) + uintptr(destination_index * i64(array_info.elem_size))),
                    id   = array_info.elem.id,
                }
                portable_decode_value(ctx, saved.elem, field, array_info.elem.id, path, depth + 1)
            }
            if ctx.reader.error.kind != .None do return
        }
    case .Dynamic_Array:
        count, count_ok := portable_read_u64(&ctx.reader, path)
        if !count_ok do return
        if count > u64(ctx.config.limits.max_array_elements) || count > u64(max(int)) {
            portable_decoder_fail(ctx, .Limit_Exceeded, path, "dynamic array element count exceeds limit")
            return
        }
        dynamic_info, dynamic_ok := current_info.variant.(rt.Type_Info_Dynamic_Array)
        if dynamic_ok {
            element_info := rt.type_info_base(type_info_of(dynamic_info.elem.id))
            if element_info == nil || dynamic_info.elem_size != element_info.size {
                portable_decoder_fail(ctx, .Type_Mismatch, path, "destination dynamic array metadata is invalid")
                return
            }
            count_int := int(count)
            if !portable_dynamic_destination_init(ctx, destination, count_int, element_info, path) do return
            raw_destination := cast(^rt.Raw_Dynamic_Array)destination.data
            for i in 0 ..< count_int {
                field := any {
                    data = rawptr(uintptr(raw_destination.data) + uintptr(i * dynamic_info.elem_size)),
                    id   = dynamic_info.elem.id,
                }
                portable_decode_value(ctx, saved.elem, field, dynamic_info.elem.id, path, depth + 1)
                if ctx.reader.error.kind != .None do return
            }
            return
        }
        array_info, array_ok := current_info.variant.(rt.Type_Info_Array)
        if array_ok {
            count_int := int(count)
            decode_count := min(count_int, array_info.count)
            for i in 0 ..< decode_count {
                field := any {
                    data = rawptr(uintptr(destination.data) + uintptr(i * array_info.elem_size)),
                    id   = array_info.elem.id,
                }
                portable_decode_value(ctx, saved.elem, field, array_info.elem.id, path, depth + 1)
                if ctx.reader.error.kind != .None do return
            }
            for _ in decode_count ..< count_int {
                portable_skip_value(ctx, saved.elem, path, depth + 1)
                if ctx.reader.error.kind != .None do return
            }
            return
        }
        portable_decoder_fail(ctx, .Type_Mismatch, path, "saved dynamic array does not match destination")
    case .Struct:
        if _, ok := current_info.variant.(rt.Type_Info_Struct); !ok {
            portable_decoder_fail(ctx, .Type_Mismatch, path, "saved struct does not match destination")
            return
        }
        for field in saved.fields {
            current_path := path
            if !ctx.config.exact_schema do current_path = string(ctx.path[:])
            current_field, found := portable_find_current_field(current_id, field.name, ctx.config)
            if !found {
                field_path := current_path
                checkpoint: int
                if !ctx.config.exact_schema {
                    path_ok: bool
                    checkpoint, field_path, path_ok = portable_path_field_push(&ctx.path, field.name)
                    if !path_ok {
                        portable_decoder_fail(
                            ctx,
                            .Limit_Exceeded,
                            string(ctx.path[:]),
                            "field path allocation failed",
                        )
                        return
                    }
                }
                portable_skip_value(ctx, field.type, field_path, depth + 1)
                if !ctx.config.exact_schema do portable_path_field_pop(&ctx.path, checkpoint)
                if ctx.reader.error.kind != .None do return
                continue
            }
            destination_field := any {
                data = rawptr(uintptr(destination.data) + current_field.offset),
                id   = current_field.type.id,
            }
            field_path := current_path
            checkpoint: int
            if !ctx.config.exact_schema {
                path_ok: bool
                checkpoint, field_path, path_ok = portable_path_field_push(&ctx.path, field.name)
                if !path_ok {
                    portable_decoder_fail(ctx, .Limit_Exceeded, string(ctx.path[:]), "field path allocation failed")
                    return
                }
            }
            portable_decode_value(ctx, field.type, destination_field, current_field.type.id, field_path, depth + 1)
            if !ctx.config.exact_schema do portable_path_field_pop(&ctx.path, checkpoint)
            if ctx.reader.error.kind != .None do return
        }
    case .Enum:
        current_enum, ok := current_info.variant.(rt.Type_Info_Enum)
        if !ok {
            portable_decoder_fail(ctx, .Type_Mismatch, path, "saved enum does not match destination")
            return
        }
        storage: u64
        base := any {
            data = rawptr(&storage),
            id   = current_enum.base.id,
        }
        portable_decode_value(ctx, saved.base, base, current_enum.base.id, path, depth + 1)
        if ctx.reader.error.kind != .None do return
        saved_base := ctx.types[saved.base - 1]
        destination_base_info := rt.type_info_base(type_info_of(current_enum.base.id))
        destination_base := any {
            data = destination.data,
            id   = destination_base_info.id,
        }
        if saved_base.kind == .Unsigned {
            value, value_ok := any_get_u64(any{data = rawptr(&storage), id = destination_base_info.id})
            if !value_ok || value > u64(max(i64)) || !portable_saved_enum_value_valid(saved, i64(value)) {
                portable_decoder_fail(ctx, .Invalid_Metadata, path, "enum body value is not declared")
                return
            }
            if !portable_enum_value_valid(current_id, i64(value)) {
                portable_decoder_fail(ctx, .Invalid_Metadata, path, "enum value is not declared by destination")
                return
            }
            any_assign_u64(destination_base, value)
        } else {
            value, value_ok := any_get_i64(any{data = rawptr(&storage), id = destination_base_info.id})
            if !value_ok || !portable_saved_enum_value_valid(saved, value) {
                portable_decoder_fail(ctx, .Invalid_Metadata, path, "enum body value is not declared")
                return
            }
            if !portable_enum_value_valid(current_id, value) {
                portable_decoder_fail(ctx, .Invalid_Metadata, path, "enum value is not declared by destination")
                return
            }
            any_assign_i64(destination_base, value)
        }
    case:
        portable_decoder_fail(ctx, .Invalid_Metadata, path, "invalid saved type")
    }
}

portable_header_valid :: proc(
    data: []byte,
    config: Portable_Config,
) -> (
    root, type_count, table_bytes, body_bytes: int,
    error: Portable_Error,
    ok: bool,
) {
    if len(data) < Portable_Header_Size do return 0, 0, 0, 0, portable_error(.Truncated, 0, "$", "payload is shorter than header"), false
    magic_ok := true
    magic := Portable_Magic
    for i in 0 ..< len(magic) {
        if data[i] != magic[i] do magic_ok = false
    }
    if !magic_ok do return 0, 0, 0, 0, portable_error(.Invalid_Header, 0, "$", "portable payload magic is invalid"), false
    header := Portable_Reader {
        data = data[8:],
    }
    version, _ := portable_read_u16(&header, "$.header.version")
    flags, _ := portable_read_u16(&header, "$.header.flags")
    root_u32, root_ok := portable_read_u32(&header, "$.header.root")
    types_u32, types_ok := portable_read_u32(&header, "$.header.types")
    table_u32, table_ok := portable_read_u32(&header, "$.header.table")
    body_u32, body_ok := portable_read_u32(&header, "$.header.body")
    if !root_ok || !types_ok || !table_ok || !body_ok do return 0, 0, 0, 0, header.error, false
    if version != Portable_Version do return 0, 0, 0, 0, portable_error(.Invalid_Header, 8, "$.header.version", "portable payload version is unsupported"), false
    if flags != 0 do return 0, 0, 0, 0, portable_error(.Invalid_Header, 10, "$.header.flags", "portable payload flags are reserved"), false
    if len(data) > config.limits.max_payload do return 0, 0, 0, 0, portable_error(.Limit_Exceeded, 0, "$", "payload exceeds limit"), false
    if types_u32 == 0 || types_u32 > u32(config.limits.max_types) do return 0, 0, 0, 0, portable_error(.Limit_Exceeded, 16, "$.header.types", "type count exceeds limit"), false
    if root_u32 == 0 || root_u32 > types_u32 do return 0, 0, 0, 0, portable_error(.Invalid_Handle, 12, "$.header.root", "root type handle is invalid"), false
    if table_u32 > u32(len(data) - Portable_Header_Size) do return 0, 0, 0, 0, portable_error(.Truncated, 20, "$.header.table", "type table exceeds payload"), false
    body_start := Portable_Header_Size + int(table_u32)
    if body_u32 > u32(len(data) - body_start) do return 0, 0, 0, 0, portable_error(.Truncated, 24, "$.header.body", "value body exceeds payload"), false
    if body_start + int(body_u32) != len(data) do return 0, 0, 0, 0, portable_error(.Trailing_Bytes, body_start + int(body_u32), "$", "payload has trailing bytes"), false
    return int(root_u32), int(types_u32), int(table_u32), int(body_u32), portable_no_error(), true
}

portable_validate_exact_type_table :: proc(
    destination_id: typeid,
    saved_table: []byte,
    saved_root: u32,
    saved_type_count: int,
    config: Portable_Config,
    alloc: mem.Allocator,
) -> Portable_Error {
    discovery := Portable_Discovery {
        config     = config,
        alloc      = alloc,
        flat_paths = true,
    }
    types, types_error := make([dynamic]Portable_Type, 0, saved_type_count, alloc)
    if types_error != nil {
        return portable_error(.Limit_Exceeded, 0, "$table", "exact type metadata allocation failed")
    }
    discovery.types = types
    defer portable_delete_types(discovery.types)
    handles, handles_error := make(map[typeid]u32, saved_type_count, alloc)
    if handles_error != nil {
        return portable_error(.Limit_Exceeded, 0, "$table", "exact type handle allocation failed")
    }
    discovery.handles = handles
    defer delete(discovery.handles)

    root := portable_discover_type(&discovery, destination_id, "$", 0)
    if discovery.error.kind != .None do return discovery.error
    graph_error := portable_validate_type_graph(discovery.types[:], root, config.limits, alloc)
    if graph_error.kind != .None do return graph_error
    if root != saved_root {
        return portable_error(.Type_Mismatch, 12, "$.header.root", "saved root handle does not match destination")
    }
    if len(discovery.types) != saved_type_count {
        return portable_error(.Type_Mismatch, 16, "$table", "saved type count does not match destination")
    }

    table_storage, table_error := make([dynamic]byte, 0, len(saved_table), alloc)
    if table_error != nil {
        return portable_error(.Limit_Exceeded, 0, "$table", "exact type table allocation failed")
    }
    writer := Portable_Writer {
        bytes = table_storage,
        limit = config.limits.max_payload,
    }
    defer delete(writer.bytes)
    if !portable_encode_type_table(&discovery, &writer) {
        if writer.allocation_failed {
            return portable_error(.Limit_Exceeded, len(writer.bytes), "$table", "exact type table allocation failed")
        }
        return portable_error(.Limit_Exceeded, len(writer.bytes), "$table", "exact type table emission failed")
    }
    if len(writer.bytes) != len(saved_table) {
        return portable_error(.Type_Mismatch, 20, "$table", "saved type table length does not match destination")
    }
    for byte_value, index in writer.bytes {
        if byte_value != saved_table[index] {
            return portable_error(
                .Type_Mismatch,
                Portable_Header_Size + index,
                "$table",
                "saved type table does not match destination",
            )
        }
    }
    return portable_no_error()
}

// The caller owns strings and dynamic-array backing storage written into destination
// on success or partial failure. On failure, the caller must discard or walk that
// destination with the supplied allocator before reusing it. The caller must also
// call portable_error_dispose for an allocated error path.
portable_decode :: proc(
    destination: any,
    data: []byte,
    config := PORTABLE_DEFAULT_CONFIG,
    alloc := context.allocator,
) -> (
    error: Portable_Error,
    ok: bool,
) {
    if destination.data == nil || destination.id == nil do return portable_error(.Invalid_Argument, 0, "$", "destination has no storage or type"), false
    if alloc.procedure == nil do return portable_error(.Invalid_Argument, 0, "$", "allocator has no procedure"), false
    limits_error := portable_validate_limits(config.limits)
    if limits_error.kind != .None do return limits_error, false
    root, type_count, table_bytes, body_bytes, header_error, header_ok := portable_header_valid(data, config)
    if !header_ok do return header_error, false
    old_allocator := context.allocator
    context.allocator = alloc
    defer context.allocator = old_allocator

    table, table_error, table_ok := portable_parse_type_table(
        data[Portable_Header_Size:Portable_Header_Size + table_bytes],
        type_count,
        config.limits,
        alloc,
    )
    if !table_ok do return table_error, false
    defer portable_delete_types(table)
    graph_error := portable_validate_type_graph(table[:], u32(root), config.limits, alloc)
    if graph_error.kind != .None do return graph_error, false
    if config.exact_schema {
        exact_error := portable_validate_exact_type_table(
            destination.id,
            data[Portable_Header_Size:Portable_Header_Size + table_bytes],
            u32(root),
            type_count,
            config,
            alloc,
        )
        if exact_error.kind != .None do return exact_error, false
    }
    body_start := Portable_Header_Size + table_bytes
    decoder := Portable_Decoder {
        types = table[:],
        reader = Portable_Reader{data = data[body_start:body_start + body_bytes], alloc = alloc},
        config = config,
        alloc = alloc,
    }
    decoder_path, decoder_path_error := make([dynamic]byte, 0, 64, alloc)
    if decoder_path_error != nil {
        return portable_error(.Limit_Exceeded, body_start, "$", "field path allocation failed"), false
    }
    decoder.path = decoder_path
    defer delete(decoder.path)
    if _, decoder_path_error = append(&decoder.path, '$'); decoder_path_error != nil {
        return portable_error(.Limit_Exceeded, body_start, "$", "field path allocation failed"), false
    }
    portable_decode_value(&decoder, u32(root), destination, destination.id, "$", 0)
    if decoder.reader.error.kind != .None do return decoder.reader.error, false
    if decoder.reader.cursor != len(decoder.reader.data) do return portable_error(.Trailing_Bytes, body_start + decoder.reader.cursor, "$", "value body has trailing bytes"), false
    return portable_no_error(), true
}
