package hs
import "core:mem"
import "core:reflect"
import "core:slice"

import rt "base:runtime"

TAG :: "hs"
CAST_PRIMITIVES :: #config(CAST_PRIMITIVES, true)

/*
-- High level overview --

serialize
- recurses the type information of what you pass in,
  and saves out the the information into our own structures that mirror odin's.

- then dumps this information, followed by the binary of the value you are serializing,
  into a slice of bytes.

- for dynamic structures: maps, dynamic arrays, slices, ...
    we recurse the actual data,
    append the dynamic contents to the end of the data
    'dehydrate' the pointer inside, into an offset relative to the start of the data

deserialize
- unpacks the type information from the bytes, and then the bytes of the value

- recurses over the type information of the current value we are deserializing into,
  and attempts to write from the source value to the destination value

- each recursive call returns whether or not that value was identical between our saved type info,
  and odin's current info

- this allows us to skip future cases of deserializing identical types, we instead just skip to the fallback option,
  which is a mem copy (faster).

- for dynamic types:
    'rehydrate' the pointer inside, and fetch our source data
    allocate the amount of destintion data we need on the heap
    recurse into this data
*/

Option :: enum {
    Dynamics,
}
Options :: bit_set[Option]

// #+vet redundancy public-api
serialize :: proc(t: ^$T, options: Options = {}, alloc := context.allocator) -> []byte {
    SerializationCtx :: struct {
        types:          [dynamic]TypeInfo,
        struct_fields:  [dynamic]Struct_Field,
        bit_fields:     [dynamic]Bit_Field,
        enum_fields:    [dynamic]Enum_Field,
        handles:        [dynamic]TypeInfo_Handle,
        arena:          [dynamic]byte,
        check_dynamics: bool,
        in_progress:    map[typeid]TypeInfo_Handle, // break recursive type cycles
    }
    ctx: SerializationCtx = {}
    context.allocator = context.temp_allocator

    save_type :: proc(ctx: ^SerializationCtx, type: typeid) -> TypeInfo_Handle {
        append_slice :: #force_inline proc(array: ^[dynamic]$T, n: int) -> IndexSlice(T) {
            index: int = len(array^)
            for i in 0 ..< n {
                append(array, T{})
            }
            return {index, n}
        }

        // Check if already registered
        for info, i in ctx.types {
            if info.id != type do continue
            return TypeInfo_Handle(i + 1)
        }

        // Check if currently being processed (recursive type)
        if handle, ok := ctx.in_progress[type]; ok {
            return handle
        }

        info := type_info_of(type)
        save_info: TypeInfo = {
            size = info.size,
            id   = type,
        }

        // Reserve slot and handle for this type (for recursive references)
        type_index := len(ctx.types)
        append(&ctx.types, save_info) // append incomplete type
        ctx.in_progress[type] = TypeInfo_Handle(type_index + 1)

        #partial switch v in info.variant {
        case rt.Type_Info_Named:
            named_type := save_type(ctx, v.base.id)
            save_info.variant = TypeInfo_Named {
                name = to_index_string(&ctx.arena, v.name),
                type = named_type,
            }
        case rt.Type_Info_Struct:
            save_struct: TypeInfo_Struct

            actual_fields := reflect.struct_fields_zipped(type)
            save_struct.fields = append_slice(&ctx.struct_fields, len(actual_fields))
            for i in 0 ..< len(actual_fields) {
                field := actual_fields[i]
                field_type := save_type(ctx, field.type.id)
                ctx.struct_fields[save_struct.fields.index + i] = Struct_Field {
                    name   = to_index_string(&ctx.arena, field.name),
                    offset = field.offset,
                    type   = field_type,
                }
            }
            save_info.variant = save_struct
        case rt.Type_Info_Array:
            elem := save_type(ctx, v.elem.id)
            save_info.variant = TypeInfo_Array {
                elem      = elem,
                elem_size = v.elem_size,
                count     = v.count,
            }
        case rt.Type_Info_Enum:
            save_enum: TypeInfo_Enum
            actual_fields := reflect.enum_fields_zipped(type)

            save_enum.base = save_type(ctx, v.base.id)
            save_enum.fields = append_slice(&ctx.enum_fields, len(actual_fields))
            for i in 0 ..< save_enum.fields.length {
                field := actual_fields[i]
                ctx.enum_fields[i + save_enum.fields.index] = {
                    name  = to_index_string(&ctx.arena, field.name),
                    value = i64(field.value),
                }
            }
            save_info.variant = save_enum
        case rt.Type_Info_Enumerated_Array:
            elem := save_type(ctx, v.elem.id)
            index := save_type(ctx, v.index.id)

            save_info.variant = TypeInfo_Enumerated_Array {
                elem_size = v.elem_size,
                count     = v.count,
                elem      = elem,
                index     = index,
            }
        case rt.Type_Info_Bit_Set:
            elem := save_type(ctx, v.elem.id)
            save_info.variant = TypeInfo_Bit_Set {
                elem = elem,
            }
        case rt.Type_Info_Bit_Field:
            save_bit_field: TypeInfo_Bit_Field
            save_bit_field.backing_type = save_type(ctx, v.backing_type.id)

            actual_fields := reflect.bit_fields_zipped(type)
            save_bit_field.fields = append_slice(&ctx.bit_fields, len(actual_fields))
            for i in 0 ..< save_bit_field.fields.length {
                field := actual_fields[i]

                field_name := to_index_string(&ctx.arena, field.name)
                field_type := save_type(ctx, field.type.id)

                ctx.bit_fields[i + save_bit_field.fields.index] = {
                    name       = field_name,
                    type       = field_type,
                    bit_size   = field.size,
                    bit_offset = field.offset,
                }
            }
            save_info.variant = save_bit_field
        case rt.Type_Info_Union:
            tag_type := save_type(ctx, v.tag_type.id)

            save_union: TypeInfo_Union = {
                tag_offset = v.tag_offset,
                tag_type   = tag_type,
            }

            save_union.variants = append_slice(&ctx.handles, len(v.variants))
            for i in 0 ..< save_union.variants.length {
                ctx.handles[i + save_union.variants.index] = save_type(ctx, v.variants[i].id)
            }

            save_info.variant = save_union

        // experimental
        case rt.Type_Info_Dynamic_Array:
            ctx.check_dynamics = true

            elem := save_type(ctx, v.elem.id)
            save_info.variant = TypeInfo_Dynamic_Array {
                elem      = elem,
                elem_size = v.elem_size,
            }
        case rt.Type_Info_Slice:
            ctx.check_dynamics = true

            elem := save_type(ctx, v.elem.id)
            save_info.variant = TypeInfo_Slice {
                elem      = elem,
                elem_size = v.elem_size,
            }
        case rt.Type_Info_String:
            ctx.check_dynamics = true
            save_info.variant = TypeInfo_String {
                is_cstring = v.is_cstring,
            }
        case rt.Type_Info_Pointer:
            ctx.check_dynamics = true
            if v.elem == nil {
                elem := save_type(ctx, type_info_of(rawptr).id)
                save_info.variant = TypeInfo_Pointer {
                    elem = elem,
                }
            } else {
                elem := save_type(ctx, v.elem.id)
                save_info.variant = TypeInfo_Pointer {
                    elem = elem,
                }
            }
        case rt.Type_Info_Map:
            ctx.check_dynamics = true
            key := save_type(ctx, v.key.id)
            value := save_type(ctx, v.value.id)
            save_info.variant = TypeInfo_Map {
                key   = key,
                value = value,
            }
        }

        // Update the reserved slot with complete type info
        ctx.types[type_index] = save_info
        delete_key(&ctx.in_progress, type)
        return TypeInfo_Handle(type_index + 1)
    }

    save_type(&ctx, T)

    header: SaveHeader = {
        types         = ctx.types[:],
        struct_fields = ctx.struct_fields[:],
        bit_fields    = ctx.bit_fields[:],
        enum_fields   = ctx.enum_fields[:],
        handles       = ctx.handles[:],
        arena         = ctx.arena[:],
        options       = options,
    }
    for info, i in ctx.types {
        if info.id != T do continue
        header.stored_type = TypeInfo_Handle(i + 1)
    }

    bytes := make([dynamic]byte, alloc)

    append(&bytes, ..mem.ptr_to_bytes(&header))
    append(&bytes, ..mem.slice_to_bytes(header.types))
    append(&bytes, ..mem.slice_to_bytes(header.struct_fields))
    append(&bytes, ..mem.slice_to_bytes(header.bit_fields))
    append(&bytes, ..mem.slice_to_bytes(header.enum_fields))
    append(&bytes, ..mem.slice_to_bytes(header.handles))
    append(&bytes, ..mem.slice_to_bytes(header.arena))

    header_length := len(bytes)
    append(&bytes, ..mem.ptr_to_bytes(t))

    if ctx.check_dynamics && .Dynamics in options {
        munch(&bytes, header_length, header_length, type_info_of(T))
    }

    return bytes[:]
}
// #+vet redundancy public-api
deserialize :: proc(t: ^$T, data: []byte, options: Options = {}, alloc := context.allocator) -> bool {
    split_ref :: #force_inline proc(s: ^[]$T, index: int) -> []T {
        a, b := slice.split_at(s^, index)
        s^ = b
        return a
    }

    extract_slice :: #force_inline proc(dst: ^[]$T, data: ^[]byte) {
        dst^ = slice.reinterpret([]T, split_ref(data, len(dst^) * size_of(T)))
    }

    data := data

    // Keep serialized descriptors relative and immutable: hot-state loading
    // preflights a payload before decoding it into the live editor.

    header := transmute(^SaveHeader)(&split_ref(&data, size_of(SaveHeader))[0])

    extract_slice(&header.types, &data)
    extract_slice(&header.struct_fields, &data)
    extract_slice(&header.bit_fields, &data)
    extract_slice(&header.enum_fields, &data)
    extract_slice(&header.handles, &data)
    extract_slice(&header.arena, &data)

    body := data[:]

    start, ok := get_typeinfo_ptr(header, header.stored_type)
    assert(ok, "stored root type is missing from serialized type table")

    header.data_base = uintptr(&body[0])
    header.options &= options

    return deserialize_raw(header, uintptr(&body[0]), uintptr(t), header.stored_type, type_info_of(T), alloc)
}

// #+vet redundancy public-api
deserialize_raw :: proc(
    header: ^SaveHeader,
    src, dst: uintptr,
    src_type: TypeInfo_Handle,
    _dst: ^rt.Type_Info,
    alloc: rt.Allocator,
) -> (
    identical: bool,
) #no_bounds_check {
    saved_type, found_saved := get_typeinfo_base(header, src_type)
    assert(found_saved, "serialized source type handle is missing from saved type table")

    dst_type := rt.type_info_base(_dst)

    defer if saved_type.identical {
        saved_type.identical_id = dst_type.id
    }

    if !saved_type.identical {
        saved_type.identical = true

        #partial switch v in dst_type.variant {
        case rt.Type_Info_Struct:
            saved_struct := (&saved_type.variant.(TypeInfo_Struct)) or_break

            fields := reflect.struct_fields_zipped(dst_type.id)
            identical_fields: int

            saved_fields := to_slice(header.struct_fields, saved_struct.fields)

            for field in fields {

                field_index := fully_match_field(header, saved_fields, field.name, string(field.tag)) or_continue
                saved_field := saved_fields[field_index]

                if saved_field.offset != field.offset do saved_type.identical = false
                field_src := src + saved_field.offset
                field_dst := dst + field.offset
                if deserialize_raw(header, field_src, field_dst, saved_field.type, field.type, alloc) {
                    identical_fields += 1
                }
            }
            if identical_fields != len(fields) do saved_type.identical = false

            return saved_type.identical

        case rt.Type_Info_Array:
            saved_array := (&saved_type.variant.(TypeInfo_Array)) or_break
            count := min(saved_array.count, v.count)
            elem_identical: bool
            for i in 0 ..< count {
                elem_src := src + uintptr(i * saved_array.elem_size)
                elem_dst := dst + uintptr(i * v.elem_size)

                elem_identical = deserialize_raw(header, elem_src, elem_dst, saved_array.elem, v.elem, alloc)
                if elem_identical {
                    break
                } else {
                    saved_type.identical = false
                }
            }
            if elem_identical do break
            return saved_type.identical
        case rt.Type_Info_Enum:
            saved_enum := (&saved_type.variant.(TypeInfo_Enum)) or_break

            enum_get_value :: #force_inline proc(
                header: ^SaveHeader,
                e: ^TypeInfo_Enum,
                src: rawptr,
            ) -> (
                value: i64,
                valid: bool,
            ) {
                base := get_typeinfo_base(header, e.base) or_return
                a := mem.make_any(src, base.id)
                value, valid = any_get_i64(a)
                return
            }

            src_value := enum_get_value(header, saved_enum, rawptr(src)) or_break

            saved_fields := to_slice(header.enum_fields, saved_enum.fields)
            actual_fields := reflect.enum_fields_zipped(dst_type.id)

            // identical check
            if enum_identical(header, saved_type, dst_type) {
                break
            }

            // otherwise assumed to be a known, non identical enum, do the correct copy operation
            saved_type.identical = false

            saved_field: ^Enum_Field
            for &field in saved_fields {
                if field.value != src_value do continue
                saved_field = &field
                break
            }

            saved_name: string = resolve_to_string(header.arena, saved_field.name)
            for field in actual_fields {
                if field.name != saved_name do continue
                any_assign_i64(mem.make_any(rawptr(dst), v.base.id), i64(field.value))
                return saved_type.identical
            }
        case rt.Type_Info_Enumerated_Array:
            saved_array := (&saved_type.variant.(TypeInfo_Enumerated_Array)) or_break
            saved_index := get_typeinfo_base(header, saved_array.index) or_break

            if enum_identical(header, saved_index, v.index) {
                saved_index.identical = true
            }

            saved_elem := get_typeinfo_base(header, saved_array.elem) or_break
            if saved_index.identical && saved_elem.identical do break

            saved_type.identical = false

            saved_enum := (&saved_index.variant.(TypeInfo_Enum)) or_break
            saved_enum_fields := to_slice(header.enum_fields, saved_enum.fields)
            count := min(len(saved_enum_fields), v.count)

            for &saved_field in saved_enum_fields {
                saved_name := resolve_to_string(header.arena, saved_field.name)
                for actual_field in reflect.enum_fields_zipped(v.index.id) {
                    if saved_name != actual_field.name do continue
                    elem_src := src + uintptr(int(saved_field.value) * saved_elem.size)
                    elem_dst := dst + uintptr(int(actual_field.value) * v.elem_size)
                    if !deserialize_raw(header, elem_src, elem_dst, saved_array.elem, v.elem, alloc) {
                        saved_type.identical = false
                    }
                }
            }
            return saved_type.identical
        case rt.Type_Info_Bit_Set:
            saved_bitset := (&saved_type.variant.(TypeInfo_Bit_Set)) or_break
            saved_enum_base := get_typeinfo_base(header, saved_bitset.elem) or_break

            if enum_identical(header, saved_enum_base, v.elem) {
                saved_enum_base.identical = true
            }

            if saved_enum_base.identical && saved_type.size == dst_type.size do break

            saved_enum := (&saved_enum_base.variant.(TypeInfo_Enum)) or_break
            src_bytes := mem.byte_slice(rawptr(src), saved_type.size)
            dst_bytes := mem.byte_slice(rawptr(dst), dst_type.size)
            for &saved_field in to_slice(header.enum_fields, saved_enum.fields) {
                byte_index: u64 = u64(saved_field.value / 8)
                bit_index: u64 = u64(saved_field.value % 8)

                src_byte := src_bytes[byte_index]
                is_set: bool = ((byte(1) << bit_index) & src_byte) > 0

                saved_name := resolve_to_string(header.arena, saved_field.name)

                for &actual_field in reflect.enum_fields_zipped(v.elem.id) {
                    if actual_field.name != saved_name do continue

                    byte_index_actual := u64(actual_field.value / 8)
                    bit_index_actual := u64(actual_field.value % 8)

                    if is_set {
                        dst_bytes[byte_index_actual] |= 1 << bit_index_actual
                    } else {
                        dst_bytes[byte_index_actual] &= ~(1 << bit_index_actual)
                    }
                }
            }
            saved_type.identical = false
            return saved_type.identical
        case rt.Type_Info_Bit_Field:
            saved_bit_field := (&saved_type.variant.(TypeInfo_Bit_Field)) or_break
            fields := reflect.bit_fields_zipped(dst_type.id)

            saved_fields := to_slice(header.bit_fields, saved_bit_field.fields)

            matching_fields: int
            for field in fields {

                field_index := fully_match_field(header, saved_fields, field.name, string(field.tag)) or_continue

                matching_field: Bit_Field = saved_fields[field_index]

                source_bits: u64 = read_bits(cast([^]byte)src, matching_field.bit_offset, matching_field.bit_size)
                temporary_destination: u64
                field_identical := deserialize_raw(
                    header,
                    uintptr(&source_bits),
                    uintptr(&temporary_destination),
                    matching_field.type,
                    field.type,
                    alloc,
                )

                write_bits(cast([^]byte)dst, field.offset, field.size, temporary_destination)
                if field_identical && matching_field.bit_offset == field.offset {
                    matching_fields += 1
                }
            }
            saved_type.identical = matching_fields == len(fields)
            return saved_type.identical
        case rt.Type_Info_Union:
            saved_union := (&saved_type.variant.(TypeInfo_Union)) or_break


            saved_variants := to_slice(header.handles, saved_union.variants)
            actual_variants := v.variants

            check: {
                if len(saved_variants) != len(actual_variants) do break check

                for variant_handle, i in saved_variants {
                    saved_variant, found := get_typeinfo_base(header, variant_handle)
                    assert(found, "serialized union variant type handle is missing from saved type table")
                    if !saved_variant.identical do break check
                    if saved_variant.identical_id != actual_variants[i].id do break check
                }
                break
            }
            saved_type.identical = false

            tag_type, found_tag_type := get_typeinfo_base(header, saved_union.tag_type)
            assert(found_tag_type, "serialized union tag type handle is missing from saved type table")

            src_tag := mem.make_any(rawptr(src + saved_union.tag_offset), tag_type.id)
            dst_tag := mem.make_any(rawptr(dst + v.tag_offset), v.tag_type.id)

            local_src_tag := any_get_i64(src_tag) or_break
            if local_src_tag == 0 do break

            src_variant := saved_variants[local_src_tag - 1]
            src_name, has_src_name := get_name(header, src_variant)

            src_variant_id: typeid
            if !has_src_name {
                source_typeinfo, found_info := get_typeinfo_ptr(header, src_variant)
                assert(found_info, "serialized union variant type info is missing from saved type table")
                src_variant_id = source_typeinfo.id
            }

            local_dst_tag: i64

            for variant, i in actual_variants {
                if has_src_name {
                    name := get_name_info_ptr(variant) or_continue
                    if name != src_name do continue
                } else {
                    if variant.id != src_variant_id do continue
                }
                local_dst_tag = i64(i + 1)
                break
            }

            // if we couldnt find the tag, just leave the union zeroed out
            if local_dst_tag == 0 {
                return saved_type.identical
            }

            dst_variant := actual_variants[local_dst_tag - 1]
            any_assign_i64(dst_tag, local_dst_tag)

            deserialize_raw(header, src, dst, src_variant, dst_variant, alloc)
            return saved_type.identical
        case rt.Type_Info_Dynamic_Array:
            if .Dynamics not_in header.options {
                saved_type.identical = false
                return saved_type.identical
            }

            saved_dynamic_array := (&saved_type.variant.(TypeInfo_Dynamic_Array)) or_break

            raw_src := transmute(^mem.Raw_Dynamic_Array)src
            source_data := rawptr(uintptr(raw_src.data) + header.data_base)
            source_len := raw_src.len

            copy := make([]byte, source_len * v.elem_size)

            raw_dst := transmute(^mem.Raw_Dynamic_Array)dst
            raw_dst.data = &copy[0]
            raw_dst.len = source_len
            raw_dst.cap = source_len

            for i in 0 ..< source_len {
                elem_src := uintptr(source_data) + uintptr(i * saved_dynamic_array.elem_size)
                elem_dst := uintptr(raw_dst.data) + uintptr(i * v.elem_size)
                deserialize_raw(header, elem_src, elem_dst, saved_dynamic_array.elem, v.elem, alloc)
            }

            saved_type.identical = false
            return saved_type.identical

        case rt.Type_Info_String:
            if .Dynamics not_in header.options {
                saved_type.identical = false
                return saved_type.identical
            }

            saved_string := (&saved_type.variant.(TypeInfo_String)) or_break

            raw_src := transmute(^mem.Raw_String)src
            if raw_src.data == nil {
                saved_type.identical = false
                return saved_type.identical
            }

            source_ptr := transmute([^]byte)(uintptr(raw_src.data) + header.data_base)
            src_len := raw_src.len
            if saved_string.is_cstring {
                src_len = len(cstring(source_ptr))
            }

            source_data := source_ptr[:src_len]

            output_size: int = src_len
            if v.is_cstring {
                output_size += 1
            }

            output := make([]byte, output_size)

            copy(output, source_data)

            raw_dst := transmute(^mem.Raw_String)dst
            raw_dst.data = &output[0]

            raw_dst.len = raw_src.len

            saved_type.identical = false
            return saved_type.identical

        case rt.Type_Info_Slice:
            if .Dynamics not_in header.options {
                saved_type.identical = false
                return saved_type.identical
            }

            saved_slice := (&saved_type.variant.(TypeInfo_Slice)) or_break
            raw_src := transmute(^mem.Raw_Slice)src
            source_data := rawptr(uintptr(raw_src.data) + header.data_base)

            copy := make([]byte, raw_src.len * v.elem_size)

            raw_dst := transmute(^mem.Raw_Slice)dst
            raw_dst.data = &copy[0]
            raw_dst.len = raw_src.len

            for i in 0 ..< raw_src.len {
                elem_src := uintptr(source_data) + uintptr(i * saved_slice.elem_size)
                elem_dst := uintptr(raw_dst.data) + uintptr(i * v.elem_size)
                deserialize_raw(header, elem_src, elem_dst, saved_slice.elem, v.elem, alloc)
            }

            saved_type.identical = false
            return saved_type.identical


        case rt.Type_Info_Pointer:
            if .Dynamics not_in header.options {
                saved_type.identical = false
                return saved_type.identical
            }

            saved_ptr := (&saved_type.variant.(TypeInfo_Pointer)) or_break

            raw_src := (^uintptr)(src)
            if raw_src^ == 0 {
                saved_type.identical = false
                return saved_type.identical
            }

            // Opaque raw pointers have no element metadata and cannot cross a
            // module unload. Treat them as transient instead of dereferencing
            // foreign runtime state.
            if v.elem == nil {
                saved_type.identical = false
                return saved_type.identical
            }

            // rehydrate to local variable (don't modify source)
            elem_src := raw_src^ + header.data_base

            // allocate destination element
            elem_data := make([]byte, v.elem.size)
            deserialize_raw(header, elem_src, uintptr(&elem_data[0]), saved_ptr.elem, v.elem, alloc)

            // set destination pointer
            (^rawptr)(dst)^ = &elem_data[0]

            saved_type.identical = false
            return saved_type.identical

        case rt.Type_Info_Map:
            if .Dynamics not_in header.options {
                saved_type.identical = false
                return saved_type.identical
            }

            saved_map := (&saved_type.variant.(TypeInfo_Map)) or_break

            raw_src := transmute(^rt.Raw_Map)src
            count := int(raw_src.len)
            if count == 0 {
                // Zero out destination for empty maps
                (transmute(^rt.Raw_Map)dst)^ = {}
                saved_type.identical = false
                return saved_type.identical
            }

            // rehydrate
            data_ptr := uintptr(raw_src.data) + header.data_base

            // get saved key/value sizes
            saved_key_info, found_key := get_typeinfo_ptr(header, saved_map.key)
            assert(found_key, "serialized map key type handle is missing from saved type table")
            saved_val_info, found_val := get_typeinfo_ptr(header, saved_map.value)
            assert(found_val, "serialized map value type handle is missing from saved type table")
            key_size := saved_key_info.size
            val_size := saved_val_info.size

            // Zero and reserve destination map
            raw_dst := transmute(^rt.Raw_Map)dst
            raw_dst^ = {}
            raw_dst.allocator = alloc
            _ = rt.map_reserve_dynamic(raw_dst, v.map_info, uintptr(count))

            for i in 0 ..< count {
                src_key := data_ptr + uintptr(i * (key_size + val_size))
                src_val := src_key + uintptr(key_size)

                // Copy serialized data first to avoid corruption during rehydration
                src_key_copy := make([]byte, key_size)
                src_val_copy := make([]byte, val_size)
                mem.copy(&src_key_copy[0], rawptr(src_key), key_size)
                mem.copy(&src_val_copy[0], rawptr(src_val), val_size)

                tmp_key := make([]byte, v.key.size)
                tmp_val := make([]byte, v.value.size)

                deserialize_raw(header, uintptr(&src_key_copy[0]), uintptr(&tmp_key[0]), saved_map.key, v.key, alloc)
                deserialize_raw(
                    header,
                    uintptr(&src_val_copy[0]),
                    uintptr(&tmp_val[0]),
                    saved_map.value,
                    v.value,
                    alloc,
                )

                // DUMBAI: use the mirrored public hash insert path instead of a private runtime helper.
                hash := v.map_info.key_hasher(&tmp_key[0], rt.map_seed(raw_dst^))
                if result := rt.map_insert_hash_dynamic(
                    raw_dst,
                    v.map_info,
                    hash,
                    uintptr(&tmp_key[0]),
                    uintptr(&tmp_val[0]),
                ); result != 0 {
                    raw_dst.len += 1
                }
            }

            saved_type.identical = false
            return saved_type.identical
        }
    }

    // specified small types that dont automatically transmute
    when CAST_PRIMITIVES {

        if saved_type.id != dst_type.id {

            a := mem.make_any(rawptr(src), saved_type.id)
            b := mem.make_any(rawptr(dst), dst_type.id)

            if any_to_any(a, b) {
                return false
            }
        }
    }

    // fallback option
    if saved_type.size != dst_type.size do saved_type.identical = false
    size := min(saved_type.size, dst_type.size)
    mem.copy(rawptr(dst), rawptr(src), size)
    return saved_type.identical
}
Munch_Frame :: struct {
    index: int,
    type:  ^rt.Type_Info,
}

munch_static_leaf_array :: #force_inline proc(elem: ^rt.Type_Info) -> bool {
    return elem != nil && (elem.id == typeid_of(u8) || elem.id == typeid_of(f32))
}

// #+vet redundancy public-api
munch :: proc(bytes: ^[dynamic]byte, bytes_start, index: int, type: ^rt.Type_Info) {
    frames := make([dynamic]Munch_Frame, context.temp_allocator)
    append(&frames, Munch_Frame{index = index, type = type})

    for len(frames) > 0 {
        frame := pop(&frames)
        ptr := uintptr(&bytes[frame.index])
        info_base := rt.type_info_base(frame.type)

        #partial switch info in info_base.variant {
        case rt.Type_Info_Struct:
            field_offsets := info.offsets[:info.field_count]
            i := len(field_offsets) - 1
            for i >= 0 {
                append(&frames, Munch_Frame{index = frame.index + int(field_offsets[i]), type = info.types[i]})
                i -= 1
            }
        case rt.Type_Info_String:
            raw := transmute(^mem.Raw_String)ptr
            if raw.data == nil do continue

            mark := len(bytes)
            string_len := raw.len
            string_data := raw.data
            if info.is_cstring {
                string_len = len(cstring(raw.data)) + 1
            }
            raw.data = transmute([^]byte)(mark - bytes_start)
            append(bytes, ..string_data[:string_len])

        case rt.Type_Info_Enumerated_Array:
            if munch_static_leaf_array(info.elem) do continue
            i := info.count - 1
            for i >= 0 {
                append(&frames, Munch_Frame{index = frame.index + i * info.elem_size, type = info.elem})
                i -= 1
            }
        case rt.Type_Info_Array:
            if munch_static_leaf_array(info.elem) do continue
            i := info.count - 1
            for i >= 0 {
                append(&frames, Munch_Frame{index = frame.index + i * info.elem_size, type = info.elem})
                i -= 1
            }
        case rt.Type_Info_Slice:
            raw := transmute(^rt.Raw_Slice)ptr
            size := raw.len * info.elem_size
            if size == 0 do continue

            mark := len(bytes)
            raw_local := raw^
            raw.data = transmute(rawptr)(mark - bytes_start)
            append(bytes, ..mem.byte_slice(raw_local.data, size))

            i := raw_local.len - 1
            for i >= 0 {
                append(&frames, Munch_Frame{index = mark + info.elem_size * i, type = info.elem})
                i -= 1
            }
        case rt.Type_Info_Dynamic_Array:
            raw := transmute(^rt.Raw_Dynamic_Array)ptr
            size := raw.len * info.elem_size
            if size == 0 do continue

            mark := len(bytes)
            raw_local := raw^
            raw.data = transmute(rawptr)(mark - bytes_start)
            append(bytes, ..mem.byte_slice(raw_local.data, size))

            i := raw_local.len - 1
            for i >= 0 {
                append(&frames, Munch_Frame{index = mark + info.elem_size * i, type = info.elem})
                i -= 1
            }
        case rt.Type_Info_Pointer:
            raw := (^rawptr)(ptr)
            if raw^ == nil do continue

            if info.elem == nil {
                raw^ = nil
                continue
            }

            mark := len(bytes)
            local := raw^
            raw^ = rawptr(uintptr(mark - bytes_start))
            append(bytes, ..mem.byte_slice(local, info.elem.size))
            append(&frames, Munch_Frame{index = mark, type = info.elem})
        case rt.Type_Info_Map:
            raw := transmute(^rt.Raw_Map)ptr
            count := int(rt.map_len(raw^))
            if count == 0 do continue

            mark := len(bytes)
            ks, vs, hs, _, _ := rt.map_kvh_data_dynamic(raw^, info.map_info)
            capacity := uintptr(rt.map_cap(raw^))

            key_size := int(info.map_info.ks.size_of_type)
            val_size := int(info.map_info.vs.size_of_type)

            entries := make([dynamic]byte, context.temp_allocator)
            for i in 0 ..< capacity {
                if !rt.map_hash_is_valid(hs[i]) do continue
                k := rt.map_cell_index_dynamic(ks, info.map_info.ks, i)
                v := rt.map_cell_index_dynamic(vs, info.map_info.vs, i)
                append(&entries, ..mem.byte_slice(rawptr(k), key_size))
                append(&entries, ..mem.byte_slice(rawptr(v), val_size))
            }

            raw.data = uintptr(mark - bytes_start)
            raw.len = uintptr(count)
            raw.allocator = {}
            append(bytes, ..entries[:])

            i := count - 1
            for i >= 0 {
                entry_offset := mark + i * (key_size + val_size)
                append(&frames, Munch_Frame{index = entry_offset + key_size, type = info.value})
                append(&frames, Munch_Frame{index = entry_offset, type = info.key})
                i -= 1
            }
        }
    }
}
