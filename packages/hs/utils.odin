package hs

import "core:hash"
import "core:slice"

// #+vet redundancy public-api
type_hash :: proc($T: typeid) -> u64 {
    t := new(T, context.temp_allocator)
    data := serialize(t, {.Dynamics}, context.temp_allocator)
    if len(data) <= size_of(SaveHeader) do return 0

    payload := data[size_of(SaveHeader):]
    header := transmute(^SaveHeader)(&data[0])
    cursor := payload
    take_bytes :: #force_inline proc(cursor: ^[]byte, count: int) -> []byte {
        if count < 0 || count > len(cursor^) do return nil
        part, rest := slice.split_at(cursor^, count)
        cursor^ = rest
        return part
    }

    type_bytes := take_bytes(&cursor, len(header.types) * size_of(TypeInfo))
    struct_field_bytes := take_bytes(&cursor, len(header.struct_fields) * size_of(Struct_Field))
    bit_field_bytes := take_bytes(&cursor, len(header.bit_fields) * size_of(Bit_Field))
    enum_field_bytes := take_bytes(&cursor, len(header.enum_fields) * size_of(Enum_Field))
    _ = take_bytes(&cursor, len(header.handles) * size_of(TypeInfo_Handle))
    arena_bytes := take_bytes(&cursor, len(header.arena))

    if type_bytes == nil ||
       struct_field_bytes == nil ||
       bit_field_bytes == nil ||
       enum_field_bytes == nil ||
       arena_bytes == nil {
        // DUMBAI: malformed serialized payload should still produce a deterministic hash.
        return hash.fnv64a(payload)
    }

    types := slice.reinterpret([]TypeInfo, type_bytes)
    for &info in types {
        // DUMBAI: strip runtime-assigned type IDs so ABI hashing depends on shape, not compiler/linker numbering.
        info.id = {}
        info.identical_id = {}
        named := (&info.variant.(TypeInfo_Named)) or_continue
        // DUMBAI: generic-instantiation name strings can be compiler-order dependent; ignore symbolic names.
        named.name = {}
    }

    struct_fields := slice.reinterpret([]Struct_Field, struct_field_bytes)
    for &field in struct_fields do field.name = {}

    bit_fields := slice.reinterpret([]Bit_Field, bit_field_bytes)
    for &field in bit_fields do field.name = {}

    enum_fields := slice.reinterpret([]Enum_Field, enum_field_bytes)
    for &field in enum_fields do field.name = {}

    // DUMBAI: names are ignored above, so arena contents should not contribute to ABI decisions.
    for i in 0 ..< len(arena_bytes) do arena_bytes[i] = 0

    for i in 0 ..< len(cursor) {
        // DUMBAI: default-initialized value bytes can carry nondeterministic padding; clear tail object payload.
        cursor[i] = 0
    }

    return hash.fnv64a(payload)
}
