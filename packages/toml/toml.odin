package toml

import "core:fmt"
import "core:strings"
import "core:sync"

import "base:intrinsics"
import "base:runtime"
import "dates"
import "zelda_engine:spy"

log :: fmt.print
logf :: fmt.printf
logln :: fmt.println

b_printf :: fmt.sbprintf


// #+vet redundancy public-api
emit_file :: proc() {

}

// Parses the file. You can use print_error(err) for error messages.
parse_file :: proc(
    filename: string,
    alloc := context.allocator,
    loc := #caller_location,
) -> (
    section: ^Table,
    err: Error,
) {
    context.allocator = alloc

    blob, ok := read_toml_file(filename, alloc, loc = loc)
    if !ok {
        err.type = .Bad_File
        strings.write_string(&err.more, filename)
        return nil, err
    }

    section, err = parse(string(blob), filename, alloc)
    delete_slice(blob)
    return
}

// This is made to be used with default, err := #load(filename). original_filename is only used for errors.
// #+vet redundancy public-api
parse_data :: proc(
    data: []u8,
    original_filename := "untitled data",
    alloc := context.allocator,
) -> (
    section: ^Table,
    err: Error,
) {
    return parse(string(data), original_filename, alloc)
}

@(private)
_Parsed_Backing :: struct {
    root:       ^Table,
    owned_data: string,
    data_begin: uintptr,
    data_end:   uintptr,
    alloc:      runtime.Allocator,
}

@(private)
_parsed_backings: [dynamic]_Parsed_Backing
@(private)
_parsed_backings_lock: sync.Mutex

@(private)
_parsed_backings_init :: proc() {
    if _parsed_backings.allocator.procedure == nil {
        _parsed_backings.allocator = runtime.default_context().allocator
    }
}

@(private)
_parsed_backing_register :: proc(root: ^Table, owned_data: string, alloc := context.allocator) {
    if root == nil || len(owned_data) == 0 do return
    sync.guard(&_parsed_backings_lock)
    _parsed_backings_init()
    data_begin := uintptr(raw_data(owned_data))
    append(&_parsed_backings, _Parsed_Backing {
        root       = root,
        owned_data = owned_data,
        data_begin = data_begin,
        data_end   = data_begin + uintptr(len(owned_data)),
        alloc      = alloc,
    })
}

@(private)
_parsed_backing_lookup :: proc(root: ^Table) -> (_Parsed_Backing, bool) {
    if root == nil do return {}, false
    sync.guard(&_parsed_backings_lock)
    for backing in _parsed_backings {
        if backing.root == root {
            return backing, true
        }
    }
    return {}, false
}

@(private)
_parsed_backing_remove :: proc(root: ^Table) {
    if root == nil do return
    sync.guard(&_parsed_backings_lock)
    for i in 0 ..< len(_parsed_backings) {
        if _parsed_backings[i].root != root do continue
        last := len(_parsed_backings) - 1
        if i != last {
            _parsed_backings[i] = _parsed_backings[last]
        }
        resize(&_parsed_backings, last)
        return
    }
}

@(private)
_parsed_string_borrowed :: proc(value: string) -> bool {
    if len(value) == 0 {
        return false
    }
    ptr := uintptr(raw_data(value))
    sync.guard(&_parsed_backings_lock)
    for backing in _parsed_backings {
        if ptr >= backing.data_begin && ptr < backing.data_end {
            return true
        }
    }
    return false
}

// Frees all of the memory allocated by the parser for a particular type
// It is recursive, so you can just give it the root Table.
deep_delete :: proc(type: Type, alloc := context.allocator) -> (err: runtime.Allocator_Error) {
    context.allocator = alloc
    #partial switch value in type {
    case ^List:
        if value == nil do break
        for &item in value {
            err = deep_delete(item, alloc)
            if err != .None do return
        }
        err = delete_dynamic_array(value^)
        if err == .None do free(value)

    case ^Table:
        if value == nil do break
        backing, has_backing := _parsed_backing_lookup(value)
        defer if has_backing {
            _parsed_backing_remove(value)
            delete(backing.owned_data, backing.alloc)
        }
        for k, &v in value {
            if !_parsed_string_borrowed(k) {
                err = delete_string(k)
                if err != .None do return
            }
            err = deep_delete(v, alloc)
            if err != .None do return
        }
        err = delete_map(value^)
        if err == .None do free(value)

    case string:
        if !_parsed_string_borrowed(value) {
            err = delete_string(value)
        }
    }
    return
}

// Retrieves and type checks the value at path. The last element of path is the actual key.
// section may be any Table.
get :: proc(
    $T: typeid,
    section: ^Table,
    path: ..string,
) -> (
    val: T,
    ok: bool,
) where intrinsics.type_is_variant_of(Type, T) {
    assert(len(path) > 0, "You must specify at least one path str in toml.fetch()!")
    if section == nil {
        return val, false
    }

    section := section
    for dir in path[:len(path) - 1] {
        if dir in section {
            section, ok = section[dir].(^Table)
            if !ok do return val, false
        } else do return val, false
    }
    last := path[len(path) - 1]
    if last in section do return section[last].(T)
    else do return val, false
}

// Also retrieves and typechecks the value at path, but if something goes wrong, it crashes the program.
get_panic :: proc($T: typeid, section: ^Table, path: ..string) -> T where intrinsics.type_is_variant_of(Type, T) {
    assert(len(path) > 0, "You must specify at least one path str in toml.fetch_panic()!")
    section := section
    for dir in path[:len(path) - 1] {
        if dir not_in section do spy.panicf("Missing key: '%s' in table '%v'!", path, section^)
        section = section[dir].(^Table)
    }
    last := path[len(path) - 1]
    if last not_in section do spy.panicf("Missing key: '%s' in table '%v'!", last, section^)
    return section[last].(T)
}

// Currently(2024-06-__), Odin hangs if you simply fmt.print Table
// #+vet redundancy public-api
print_table :: proc(section: ^Table, level := 0) {
    log("{ ")
    i := 0
    if section == nil {
        log("<nil>")
        return
    }
    for k, v in section {
        log(k, "= ")
        print_value(v, level)
        if i != len(section) - 1 do log(", ")
        else do log(" ")
        i += 1
    }
    log("}")
    if level == 0 do logln()

    print_value :: proc(v: Type, level := 0) {
        #partial switch t in v {
        case ^Table:
            print_table(t, level + 1)
        case ^[dynamic]Type:
            log("[ ")
            for e, i in t {
                print_value(e, level)
                if i != len(t) - 1 do log(", ")
                else do log(" ")
            }
            log("]")
        case string:
            logf("%q", v)
        case:
            log(v)
        }
    }
}


// Here lies the code for LSP:
// #+vet redundancy public-api
get_i64 :: proc(section: ^Table, path: ..string) -> (val: i64, ok: bool) { return get(i64, section, ..path) }
// #+vet redundancy public-api
get_f64 :: proc(section: ^Table, path: ..string) -> (val: f64, ok: bool) { return get(f64, section, ..path) }
// #+vet redundancy public-api
get_bool :: proc(section: ^Table, path: ..string) -> (val: bool, ok: bool) { return get(bool, section, ..path) }
// #+vet redundancy public-api
get_string :: proc(section: ^Table, path: ..string) -> (val: string, ok: bool) { return get(string, section, ..path) }
// #+vet redundancy public-api
get_date :: proc(section: ^Table, path: ..string) -> (val: dates.Date, ok: bool) {return get(
        dates.Date,
        section,
        ..path,
    )}
// #+vet redundancy public-api
get_list :: proc(section: ^Table, path: ..string) -> (val: ^List, ok: bool) { return get(^List, section, ..path) }
// #+vet redundancy public-api
get_table :: proc(section: ^Table, path: ..string) -> (val: ^Table, ok: bool) { return get(^Table, section, ..path) }

// #+vet redundancy public-api
get_i64_panic :: proc(section: ^Table, path: ..string) -> i64 { return get_panic(i64, section, ..path) }
// #+vet redundancy public-api
get_f64_panic :: proc(section: ^Table, path: ..string) -> f64 { return get_panic(f64, section, ..path) }
// #+vet redundancy public-api
get_bool_panic :: proc(section: ^Table, path: ..string) -> bool { return get_panic(bool, section, ..path) }
// #+vet redundancy public-api
get_string_panic :: proc(section: ^Table, path: ..string) -> string { return get_panic(string, section, ..path) }
// #+vet redundancy public-api
get_date_panic :: proc(section: ^Table, path: ..string) -> dates.Date { return get_panic(dates.Date, section, ..path) }
// #+vet redundancy public-api
get_list_panic :: proc(section: ^Table, path: ..string) -> ^List { return get_panic(^List, section, ..path) }
// #+vet redundancy public-api
get_table_panic :: proc(section: ^Table, path: ..string) -> ^Table { return get_panic(^Table, section, ..path) }
