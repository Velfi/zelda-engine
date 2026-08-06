package toml

import "core:os"

read_toml_file :: proc(filename: string, allocator := context.allocator, loc := #caller_location) -> ([]byte, bool) {
    data, err := os.read_entire_file(filename, allocator, loc = loc)
    return data, err == nil
}
