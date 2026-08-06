#+build js
package markov

import "core:c"
import "core:fmt"
import "core:slice"

@(default_calling_convention = "c")
foreign _ {
    markov_read_file_raw :: proc(path: cstring, data: ^[^]byte) -> int ---
    markov_free_file_raw :: proc(data: rawptr) ---
    markov_write_file_raw :: proc(path: cstring, data: [^]byte, size: int) -> int ---
}

read_markov_file :: proc(filename: string, allocator := context.allocator) -> ([]byte, bool) {
    raw: [^]byte
    size := markov_read_file_raw(fmt.ctprint(filename), &raw)
    if size < 0 || raw == nil {
        if raw != nil {
            markov_free_file_raw(rawptr(raw))
        }
        return nil, false
    }

    data := make([]byte, size, allocator)
    copy(data, slice.from_ptr(raw, size))
    markov_free_file_raw(rawptr(raw))
    return data, true
}

write_markov_file :: proc(filename: string, data: []byte) -> bool {
    return markov_write_file_raw(fmt.ctprint(filename), raw_data(data), len(data)) >= 0
}
