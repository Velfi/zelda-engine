package tweak

import "core:os"

read_tweak_file :: proc(filename: string, allocator := context.allocator) -> ([]byte, os.Error) {
    return os.read_entire_file(filename, allocator)
}

write_tweak_file :: proc(filename: string, data: []byte) -> os.Error {
    return os.write_entire_file(filename, data)
}
