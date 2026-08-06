#+build js, wasi, orca
#+no-instrumentation
package backtrace

back_tracking_temp_directory :: proc() -> string {
    return "/tmp"
}

back_tracking_process_id :: proc() -> int {
    return 1
}

back_tracking_core_count :: proc() -> int {
    return 1
}

back_tracking_remove_path :: proc(path: string) {
    return
}

back_tracking_get_working_directory :: proc() -> string {
    return "/"
}

back_tracking_ensure_parent_dir :: proc(path: string) -> bool {
    return true
}

back_tracking_read_entire_file :: proc(
    path: string,
    alloc := context.allocator,
    loc := #caller_location,
) -> (
    []byte,
    bool,
) {
    return nil, false
}

back_tracking_write_entire_string :: proc(path, data: string) -> bool {
    return false
}

back_tracking_append_string :: proc(path, data: string, loc := #caller_location) -> bool {
    return false
}
