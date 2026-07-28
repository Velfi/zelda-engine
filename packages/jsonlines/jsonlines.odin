package jsonlines

import "core:encoding/json"
import "core:os"

read :: proc(handle := os.stdin, initial_capacity := 512) -> ([dynamic]u8, bool) {
    data := make([dynamic]u8, 0, max(initial_capacity, 1))
    one: [1]u8
    for {
        n, err := os.read(handle, one[:])
        if err != nil || n == 0 do return data, len(data) > 0
        if one[0] == '\n' do return data, true
        if one[0] != '\r' do append(&data, one[0])
    }
}

write :: proc(value: $T, handle := os.stdout) -> bool {
    data, err := json.marshal(value)
    if err != nil do return false
    defer delete(data)
    if _, write_err := os.write(handle, data); write_err != nil do return false
    if _, write_err := os.write(handle, []u8{'\n'}); write_err != nil do return false
    return true
}
