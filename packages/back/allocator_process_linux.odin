#+build linux
package backtrace

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

tracking_process_memory_sample :: proc() -> Tracking_Process_Memory_Sample {
    statm, err := os.read_entire_file_from_path("/proc/self/statm", context.temp_allocator)
    if err != nil {
        return {}
    }
    defer delete(statm, context.temp_allocator)

    fields, split_err := strings.fields(string(statm), context.temp_allocator)
    if split_err != nil || len(fields) < 2 {
        return {}
    }
    defer delete(fields, context.temp_allocator)

    virt_pages, virt_ok := strconv.parse_uint(fields[0])
    if !virt_ok {
        return {}
    }

    rss_pages, rss_ok := strconv.parse_uint(fields[1])
    if !rss_ok {
        return {}
    }

    page_size := posix.sysconf(._PAGESIZE)
    if page_size <= 0 {
        return {}
    }

    page_bytes := u64(page_size)
    return {flags = {.ok}, rss = u64(rss_pages) * page_bytes, virt = u64(virt_pages) * page_bytes}
}
