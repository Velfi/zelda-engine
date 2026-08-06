package toml

import "core:reflect"

toml_enum_info :: proc(et: typeid) -> reflect.Type_Info_Enum {
    info := reflect.type_info_base(type_info_of(et))
    result, ok := info.variant.(reflect.Type_Info_Enum)
    assert(ok, "enum type information expected")
    return result
}
