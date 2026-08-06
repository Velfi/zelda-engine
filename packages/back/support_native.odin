#+build !js
#+build !wasi
#+build !orca
#+no-instrumentation
package backtrace

import "core:os"
import "core:strings"

back_tracking_parent_dir :: proc(path: string) -> string {
    #reverse for ch, i in path {
        if ch == '/' || ch == '\\' {
            if i == 0 {
                return path[:1]
            }
            return path[:i]
        }
    }
    return ""
}

back_tracking_temp_directory :: proc() -> string {
    temp_dir, temp_err := os.temp_directory(context.temp_allocator)
    if temp_err != nil {
        return ""
    }
    return temp_dir
}

back_tracking_process_id :: proc() -> int {
    return os.get_pid()
}

back_tracking_core_count :: proc() -> int {
    return os.get_processor_core_count()
}

back_tracking_remove_path :: proc(path: string) {
    if len(path) == 0 do return
    _ = os.remove(path)
}

back_tracking_get_working_directory :: proc() -> string {
    working_dir, working_dir_err := os.get_working_directory(context.temp_allocator)
    if working_dir_err != nil {
        return ""
    }
    return working_dir
}

back_tracking_ensure_parent_dir :: proc(path: string) -> bool {
    parent := back_tracking_parent_dir(path)
    if len(strings.trim_space(parent)) == 0 || parent == "." {
        return true
    }
    mkdir_err := os.mkdir_all(parent)
    return mkdir_err == nil || mkdir_err == .Exist
}

back_tracking_read_entire_file :: proc(
    path: string,
    alloc := context.allocator,
    loc := #caller_location,
) -> (
    []byte,
    bool,
) {
    data, read_err := os.read_entire_file_from_path(path, alloc, loc = loc)
    if read_err != nil {
        return nil, false
    }
    return data, true
}

back_tracking_write_entire_string :: proc(path, data: string) -> bool {
    if !back_tracking_ensure_parent_dir(path) {
        return false
    }
    return os.write_entire_file(path, data) == nil
}

back_tracking_append_string :: proc(path, data: string) -> bool {
    if !back_tracking_ensure_parent_dir(path) {
        return false
    }

    file, open_err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND, os.Permissions_Read_All + {.Write_User})
    if open_err != nil {
        return false
    }
    defer _ = os.close(file)

    written, write_err := os.write(file, transmute([]byte)data)
    return write_err == nil && written == len(data)
}
