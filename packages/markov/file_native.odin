#+build !js
package markov

import "core:os"

read_markov_file :: proc(filename: string, allocator := context.allocator) -> ([]byte, bool) {
    data, err := os.read_entire_file(filename, allocator)
    return data, err == nil
}

write_markov_file :: proc(filename: string, data: []byte) -> bool {
    return os.write_entire_file(filename, data) == nil
}
