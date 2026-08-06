package hs
import "core:mem"

import rt "base:runtime"

TypeInfo_Handle :: distinct int

Struct_Field :: struct {
    name:   IndexString,
    offset: uintptr,
    type:   TypeInfo_Handle,
}

TypeInfo_Struct :: struct {
    fields: IndexSlice(Struct_Field),
}

Bit_Field :: struct {
    name:                 IndexString,
    bit_size, bit_offset: uintptr,
    type:                 TypeInfo_Handle,
}

TypeInfo_Bit_Field :: struct {
    backing_type: TypeInfo_Handle,
    fields:       IndexSlice(Bit_Field),
}

Enum_Field :: struct {
    name:  IndexString,
    value: i64,
}

TypeInfo_Enum :: struct {
    base:   TypeInfo_Handle,
    fields: IndexSlice(Enum_Field),
}

TypeInfo_Array :: struct {
    elem:      TypeInfo_Handle,
    elem_size: int,
    count:     int,
}

TypeInfo_Enumerated_Array :: struct {
    elem:      TypeInfo_Handle,
    index:     TypeInfo_Handle,
    elem_size: int,
    count:     int,
}

TypeInfo_Bit_Set :: struct {
    elem:       TypeInfo_Handle,
    underlying: TypeInfo_Handle,
    lower:      i64,
    upper:      i64,
}

TypeInfo_Union :: struct {
    variants:   IndexSlice(TypeInfo_Handle),
    tag_offset: uintptr,
    tag_type:   TypeInfo_Handle,
}

TypeInfo_Named :: struct {
    name: IndexString,
    type: TypeInfo_Handle,
}

// dynamic stuff

TypeInfo_Dynamic_Array :: struct {
    elem:      TypeInfo_Handle,
    elem_size: int,
}

TypeInfo_Slice :: struct {
    elem:      TypeInfo_Handle,
    elem_size: int,
}

TypeInfo_String :: struct {
    is_cstring: bool,
}

TypeInfo_Pointer :: struct {
    elem: TypeInfo_Handle,
}

TypeInfo_Map :: struct {
    key:   TypeInfo_Handle,
    value: TypeInfo_Handle,
}

TypeInfo :: struct {
    size:         int,
    id:           typeid,
    variant:      union {
        TypeInfo_Named,
        TypeInfo_Struct,
        TypeInfo_Enum,
        TypeInfo_Array,
        TypeInfo_Enumerated_Array,
        TypeInfo_Bit_Set,
        TypeInfo_Union,
        TypeInfo_Bit_Field,
        TypeInfo_Dynamic_Array,
        TypeInfo_Slice,
        TypeInfo_String,
        TypeInfo_Pointer,
        TypeInfo_Map,
    },

    // deserialization info
    identical:    bool,
    identical_id: typeid,
}

IndexString :: distinct IndexSlice(byte)
to_index_string :: #force_inline proc(buffer: ^[dynamic]byte, s: string) -> IndexString {
    return IndexString(to_index_slice(buffer, transmute([]byte)s))
}
resolve_to_string :: #force_inline proc(buffer: []byte, is: IndexString) -> string #no_bounds_check {
    return string(buffer[is.index:is.index + is.length])
}

IndexSlice :: struct($T: typeid) {
    index, length: int,
}
// #+vet redundancy public-api
to_index_slice :: #force_inline proc(buffer: ^[dynamic]byte, s: []$T) -> IndexSlice(T) {
    index := len(buffer)
    append(buffer, ..mem.slice_to_bytes(s))
    return {index, len(s)}
}
to_slice :: #force_inline proc(buffer: []$T, is: IndexSlice(T)) -> []T #no_bounds_check {
    return buffer[is.index:is.index + is.length]
}
// #+vet redundancy public-api
resolve_to_slice :: #force_inline proc(buffer: []byte, is: IndexSlice($T)) -> []T {
    return slice.reinterpret([]T, buffer[is.index:is.index + is.length * size_of(T)])
}

any_get_f64 :: #force_inline proc(a: any) -> (value: f64, valid: bool) {
    info := type_info_of(a.id)
    #partial switch v in info.variant {
    case rt.Type_Info_Float:
        switch info.size {
        case 2:
            value = f64((^f16)(a.data)^)
        case 4:
            value = f64((^f32)(a.data)^)
        case 8:
            value = (^f64)(a.data)^
        case:
            return 0, false
        }
        return value, true
    case rt.Type_Info_Integer, rt.Type_Info_Rune:
        int_value: i64
        int_value, valid = any_get_i64(a)
        if valid do value = f64(int_value)
        return
    case:
        return 0, false
    }
}
any_get_bool :: #force_inline proc(a: any) -> (value: bool, valid: bool) {
    info := type_info_of(a.id)
    #partial switch v in info.variant {
    case rt.Type_Info_Boolean:
        switch info.size {
        case 1:
            value = bool((^b8)(a.data)^)
        case 2:
            value = bool((^b16)(a.data)^)
        case 4:
            value = bool((^b32)(a.data)^)
        case 8:
            value = bool((^b64)(a.data)^)
        case:
            return false, false
        }
        return value, true
    case rt.Type_Info_Integer, rt.Type_Info_Float, rt.Type_Info_Rune:
        int_value: u64
        int_value, valid = any_get_u64(a)
        if valid do value = bool(int_value)
        return
    case:
        return false, false
    }
}
// #+vet redundancy public-api
any_get_u64 :: #force_inline proc(a: any) -> (value: u64, valid: bool) #no_bounds_check {
    info := type_info_of(a.id)
    #partial switch v in info.variant {
    case rt.Type_Info_Integer:
        if v.signed {
            switch info.size {
            case 1:
                value = u64((^i8)(a.data)^)
            case 2:
                value = u64((^i16)(a.data)^)
            case 4:
                value = u64((^i32)(a.data)^)
            case 8:
                value = u64((^i64)(a.data)^)
            case:
                return 0, false
            }
        } else {
            switch info.size {
            case 1:
                value = u64((^u8)(a.data)^)
            case 2:
                value = u64((^u16)(a.data)^)
            case 4:
                value = u64((^u32)(a.data)^)
            case 8:
                value = u64((^u64)(a.data)^)
            case:
                return 0, false
            }
        }
        return value, true
    case rt.Type_Info_Rune:
        return u64((^rune)(a.data)^), true
    case rt.Type_Info_Float:
        float_value: f64
        float_value, valid = any_get_f64(a)
        if valid do value = u64(float_value)
        return
    case rt.Type_Info_Boolean:
        bool_value: bool
        bool_value, valid = any_get_bool(a)
        if valid do value = u64(bool_value)
        return
    case:
        return 0, false
    }
}
any_get_i64 :: #force_inline proc(a: any) -> (value: i64, valid: bool) #no_bounds_check {
    info := type_info_of(a.id)
    #partial switch v in info.variant {
    case rt.Type_Info_Integer:
        if v.signed {
            switch info.size {
            case 1:
                value = i64((^i8)(a.data)^)
            case 2:
                value = i64((^i16)(a.data)^)
            case 4:
                value = i64((^i32)(a.data)^)
            case 8:
                value = (^i64)(a.data)^
            case:
                return 0, false
            }
        } else {
            switch info.size {
            case 1:
                value = i64((^u8)(a.data)^)
            case 2:
                value = i64((^u16)(a.data)^)
            case 4:
                value = i64((^u32)(a.data)^)
            case 8:
                value = i64((^u64)(a.data)^)
            case:
                return 0, false
            }
        }
        return value, true
    case rt.Type_Info_Rune:
        return i64((^rune)(a.data)^), true
    case rt.Type_Info_Float:
        float_value: f64
        float_value, valid = any_get_f64(a)
        if valid do value = i64(float_value)
        return
    case rt.Type_Info_Boolean:
        bool_value: bool
        bool_value, valid = any_get_bool(a)
        if valid do value = i64(bool_value)
        return
    case:
        return 0, false
    }
}
// #+vet redundancy public-api
any_to_any :: #force_inline proc(a, b: any) -> bool {
    info_b := type_info_of(b.id)
    #partial switch info in info_b.variant {
    case rt.Type_Info_Integer, rt.Type_Info_Rune:
        if value, valid := any_get_i64(a); valid {
            any_assign_i64(b, value)
            return true
        }
    case rt.Type_Info_Float:
        if value, valid := any_get_f64(a); valid {
            any_assign_f64(b, value)
            return true
        }
    case rt.Type_Info_Boolean:
        if value, valid := any_get_bool(a); valid {
            any_assign_bool(b, value)
            return true
        }
    }
    return false
}
// #+vet redundancy public-api
any_assign_bool :: #force_inline proc(a: any, value: bool) {
    info := type_info_of(a.id)
    switch info.size {
    case 1:
        (^b8)(a.data)^ = b8(value)
    case 2:
        (^b16)(a.data)^ = b16(value)
    case 4:
        (^b32)(a.data)^ = b32(value)
    case 8:
        (^b64)(a.data)^ = b64(value)
    }
}
// #+vet redundancy public-api
any_assign_f64 :: #force_inline proc(a: any, value: f64) {
    info := type_info_of(a.id)
    switch info.size {
    case 2:
        (^f16)(a.data)^ = f16(value)
    case 4:
        (^f32)(a.data)^ = f32(value)
    case 8:
        (^f64)(a.data)^ = f64(value)
    }
}
// #+vet redundancy public-api
any_assign_u64 :: #force_inline proc(a: any, value: u64) {
    info := type_info_of(a.id)
    switch info.size {
    case 1:
        (^u8)(a.data)^ = u8(value)
    case 2:
        (^u16)(a.data)^ = u16(value)
    case 4:
        (^u32)(a.data)^ = u32(value)
    case 8:
        (^u64)(a.data)^ = u64(value)
    }
}
any_assign_i64 :: #force_inline proc(a: any, value: i64) {
    info := type_info_of(a.id)
    #partial switch v in info.variant {
    case rt.Type_Info_Integer:
        if v.signed {
            switch info.size {
            case 1:
                (^i8)(a.data)^ = i8(value)
            case 2:
                (^i16)(a.data)^ = i16(value)
            case 4:
                (^i32)(a.data)^ = i32(value)
            case 8:
                (^i64)(a.data)^ = i64(value)
            }
        } else {
            switch info.size {
            case 1:
                (^u8)(a.data)^ = u8(value)
            case 2:
                (^u16)(a.data)^ = u16(value)
            case 4:
                (^u32)(a.data)^ = u32(value)
            case 8:
                (^u64)(a.data)^ = u64(value)
            }
        }
    case rt.Type_Info_Rune:
        (^rune)(a.data)^ = rune(value)
    }
}
// #+vet redundancy public-api
read_bits :: #force_inline proc(ptr: [^]byte, offset, size: uintptr) -> (res: u64) {
    for i in 0 ..< size {
        j := i + offset
        B := ptr[j / 8]
        k := j & 7
        if B & (u8(1) << k) != 0 {
            res |= u64(1) << u64(i)
        }
    }
    return
}
// #+vet redundancy public-api
write_bits :: #force_inline proc(dst: [^]byte, offset, size: uintptr, value: u64) {
    for i in 0 ..< size {
        j := i + offset
        B := &dst[j / 8]
        k := j & 7
        if value & (u64(1) << i) != 0 {
            B^ |= u8(1) << k
        }
    }
}
