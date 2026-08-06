package hot_abi

import "core:hash"
import "core:mem"
import "core:reflect"

Run_Result :: enum {
    Quit,
    Reload,
    Restart,
}

Contract :: struct {
    run:                      proc(_: rawptr) -> Run_Result,
    abi_version:              proc() -> u64,
    canvas_state:             proc() -> rawptr,
    canvas_state_abi_version: proc() -> u64,
    close_canvas:             proc(),
}

ABI_Hash_State :: struct {
    value: u64,
}

ABI_HASH_SEED :: u64(0xcbf29ce484222325)

hash_value :: proc(state: ^ABI_Hash_State, value: $T) {
    value := value
    state.value = hash.fnv64a(mem.ptr_to_bytes(&value), state.value)
}

hash_type :: proc(state: ^ABI_Hash_State, info: ^reflect.Type_Info) {
    if info == nil {
        hash_value(state, u8(0))
        return
    }

    type_info := reflect.type_info_base(info)
    hash_value(state, u64(type_info.size))
    hash_value(state, u64(type_info.align))

    #partial switch v in type_info.variant {
    case reflect.Type_Info_Named:
        hash_type(state, v.base)
    case reflect.Type_Info_Integer:
        hash_value(state, u8(1))
        hash_value(state, v.signed)
        hash_value(state, u8(v.endianness))
    case reflect.Type_Info_Boolean:
        hash_value(state, u8(2))
    case reflect.Type_Info_Procedure:
        hash_value(state, u8(3))
        hash_value(state, v.variadic)
        hash_value(state, u8(v.convention))
        hash_type(state, v.params)
        hash_type(state, v.results)
    case reflect.Type_Info_Parameters:
        hash_value(state, u8(4))
        hash_value(state, u64(len(v.types)))
        for type in v.types do hash_type(state, type)
    case reflect.Type_Info_Struct:
        hash_value(state, u8(5))
        hash_value(state, u64(v.field_count))
        for i in 0 ..< int(v.field_count) {
            hash_value(state, u64(v.offsets[i]))
            hash_type(state, v.types[i])
        }
    }
}

type_hash :: proc($T: typeid) -> u64 {
    state := ABI_Hash_State {
        value = ABI_HASH_SEED,
    }
    hash_type(&state, type_info_of(T))
    return state.value
}
