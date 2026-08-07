package backtrace

import "base:intrinsics"
import "base:runtime"

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

WASM :: ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32

// The backtrace tracking allocator is the same allocator as the core tracking allocator but keeps
// backtraces for each allocation.
//
// See examples/allocator for a usage snippet.
//
// Print results at the end using tracking_allocator_print_results().
Tracking_Allocator :: struct {
    backing:                           mem.Allocator,
    internals_allocator:               mem.Allocator,
    allocation_map:                    map[rawptr]Tracking_Allocator_Entry,
    leak_group_index:                  map[Tracking_Leak_Group_Key]int,
    leak_group_array:                  [dynamic]Tracking_Leak_Group,
    bad_free_group_index:              map[Tracking_Bad_Free_Group_Key]int,
    bad_free_array:                    [dynamic]Tracking_Allocator_Bad_Free_Entry,
    alloc_top_group_index:             map[Tracking_Top_Alloc_Group_Key]int,
    alloc_top_group_array:             [dynamic]Tracking_Top_Alloc_Group,
    live_alloc_size:                   int,
    peak_live_alloc_size:              int,
    peak_live_alloc_count:             int,
    process_peak_ok:                   bool,
    process_peak_rss:                  u64,
    process_peak_phys:                 u64,
    process_peak_virt:                 u64,
    process_peak_heap_reserved:        u64,
    process_peak_heap_blocks:          u64,
    process_peak_graphics_footprint:   u64,
    process_peak_graphics_nofootprint: u64,
    process_sample_count:              u64,
    mutex:                             sync.Mutex,
    clear_on_free_all:                 bool,
}

Tracking_Allocator_Entry :: struct {
    memory:    rawptr,
    size:      int,
    alignment: int,
    mode:      mem.Allocator_Mode,
    err:       mem.Allocator_Error,
    location:  runtime.Source_Code_Location,
    backtrace: Trace_Const,
}

Tracking_Allocator_Bad_Free_Entry :: struct {
    memory:    rawptr,
    location:  runtime.Source_Code_Location,
    backtrace: Trace_Const,
    count:     int,
}

Tracking_Leak_Group_Key :: struct {
    location:  runtime.Source_Code_Location,
    size:      int,
    backtrace: Trace_Const,
}

Tracking_Leak_Group :: struct {
    key:   Tracking_Leak_Group_Key,
    count: int,
}

Tracking_Bad_Free_Group_Key :: struct {
    location:  runtime.Source_Code_Location,
    backtrace: Trace_Const,
}

Tracking_Top_Alloc_Group_Key :: struct {
    location: runtime.Source_Code_Location,
}

Tracking_Top_Alloc_Group :: struct {
    key:        Tracking_Top_Alloc_Group_Key,
    backtrace:  Trace_Const,
    min_size:   int,
    max_size:   int,
    total_size: int,
    count:      int,
}

tracking_allocator_init :: proc(t: ^Tracking_Allocator, backing_allocator: mem.Allocator, alloc := context.allocator) {
    t.backing = backing_allocator
    t.internals_allocator = alloc
    t.allocation_map.allocator = alloc
    t.leak_group_index.allocator = alloc
    t.leak_group_array.allocator = alloc
    t.bad_free_group_index.allocator = alloc
    t.bad_free_array.allocator = alloc
    t.alloc_top_group_index.allocator = alloc
    t.alloc_top_group_array.allocator = alloc

    if .Free_All in mem.query_features(t.backing) {
        t.clear_on_free_all = true
    }
    tracking_allocator_install_sdl_memory_hooks(alloc)
}

tracking_allocator_destroy :: proc(t: ^Tracking_Allocator) {
    tracking_allocator_delete_persisted_category_snapshot()
    tracking_allocator_delete_persisted_external_top_alloc_snapshot()
    tracking_sdl_memory_reset()
    delete(t.allocation_map)
    delete(t.leak_group_index)
    delete(t.leak_group_array)
    delete(t.bad_free_group_index)
    delete(t.bad_free_array)
    delete(t.alloc_top_group_index)
    delete(t.alloc_top_group_array)
}

// #+vet redundancy public-api
tracking_allocator_clear :: proc(t: ^Tracking_Allocator) {
    sync.guard(&t.mutex)

    tracking_allocator_delete_persisted_category_snapshot()
    tracking_allocator_delete_persisted_external_top_alloc_snapshot()
    tracking_sdl_memory_reset()
    clear(&t.allocation_map)
    clear(&t.leak_group_index)
    clear(&t.leak_group_array)
    clear(&t.bad_free_group_index)
    clear(&t.bad_free_array)
    clear(&t.alloc_top_group_index)
    clear(&t.alloc_top_group_array)
    t.live_alloc_size = 0
    t.peak_live_alloc_size = 0
    t.peak_live_alloc_count = 0
    t.process_peak_ok = false
    t.process_peak_rss = 0
    t.process_peak_phys = 0
    t.process_peak_virt = 0
    t.process_peak_heap_reserved = 0
    t.process_peak_heap_blocks = 0
    t.process_peak_graphics_footprint = 0
    t.process_peak_graphics_nofootprint = 0
    t.process_sample_count = 0
}

@(require_results)
tracking_allocator :: proc(data: ^Tracking_Allocator) -> mem.Allocator {
    return {data = data, procedure = tracking_allocator_proc}
}

// tracking_allocator_backing_allocator returns the allocator wrapped by a tracking allocator.
// Non-tracking allocators are returned unchanged.
tracking_allocator_backing_allocator :: proc(allocator: mem.Allocator) -> mem.Allocator {
    if allocator.procedure != tracking_allocator_proc {
        return allocator
    }
    return (^Tracking_Allocator)(allocator.data).backing
}

tracking_allocator_leak_group_add :: proc(data: ^Tracking_Allocator, entry: Tracking_Allocator_Entry) {
    key: Tracking_Leak_Group_Key = {
        location  = entry.location,
        size      = entry.size,
        backtrace = entry.backtrace,
    }
    if gi, ok := data.leak_group_index[key]; ok {
        data.leak_group_array[gi].count += 1
    } else {
        data.leak_group_index[key] = len(data.leak_group_array)
        append(&data.leak_group_array, Tracking_Leak_Group{key = key, count = 1})
    }
}

tracking_allocator_leak_group_remove :: proc(data: ^Tracking_Allocator, entry: Tracking_Allocator_Entry) {
    key: Tracking_Leak_Group_Key = {
        location  = entry.location,
        size      = entry.size,
        backtrace = entry.backtrace,
    }
    gi, ok := data.leak_group_index[key]
    if !ok {
        return
    }

    group := &data.leak_group_array[gi]
    if group.count > 1 {
        group.count -= 1
        return
    }

    delete_key(&data.leak_group_index, key)
    last_idx := len(data.leak_group_array) - 1
    if gi != last_idx {
        moved_group := data.leak_group_array[last_idx]
        data.leak_group_array[gi] = moved_group
        data.leak_group_index[moved_group.key] = gi
    }
    pop(&data.leak_group_array)
}

// #+vet redundancy public-api
tracking_allocator_bad_free_group_add :: proc(data: ^Tracking_Allocator, bad_free: Tracking_Allocator_Bad_Free_Entry) {
    key: Tracking_Bad_Free_Group_Key = {
        location  = bad_free.location,
        backtrace = bad_free.backtrace,
    }
    if fi, ok := data.bad_free_group_index[key]; ok {
        data.bad_free_array[fi].count += 1
    } else {
        data.bad_free_group_index[key] = len(data.bad_free_array)
        append(&data.bad_free_array, bad_free)
    }
}

tracking_allocator_top_alloc_group_add :: proc(data: ^Tracking_Allocator, entry: Tracking_Allocator_Entry) {
    if entry.size <= 0 {
        return
    }

    key: Tracking_Top_Alloc_Group_Key = {
        location = entry.location,
    }
    if gi, ok := data.alloc_top_group_index[key]; ok {
        group := &data.alloc_top_group_array[gi]
        group.count += 1
        group.total_size += entry.size
        if entry.size < group.min_size {
            group.min_size = entry.size
        }
        if entry.size > group.max_size {
            group.max_size = entry.size
            group.backtrace = entry.backtrace
        }
    } else {
        data.alloc_top_group_index[key] = len(data.alloc_top_group_array)
        append(&data.alloc_top_group_array, Tracking_Top_Alloc_Group {
            key        = key,
            backtrace  = entry.backtrace,
            min_size   = entry.size,
            max_size   = entry.size,
            total_size = entry.size,
            count      = 1,
        })
    }
}

TRACKING_PROCESS_SAMPLE_INTERVAL :: #config(TRACKING_PROCESS_SAMPLE_INTERVAL, 64)

tracking_allocator_note_process_memory_sample :: proc(t: ^Tracking_Allocator, sample: Tracking_Process_Memory_Sample) {
    if t == nil || !(.ok in sample.flags) {
        return
    }
    t.process_peak_ok = true
    if sample.rss > t.process_peak_rss do t.process_peak_rss = sample.rss
    if sample.phys_footprint > t.process_peak_phys do t.process_peak_phys = sample.phys_footprint
    if sample.virt > t.process_peak_virt do t.process_peak_virt = sample.virt
    if .heap_ok in sample.flags {
        if sample.heap_size_allocated > t.process_peak_heap_reserved {
            t.process_peak_heap_reserved = sample.heap_size_allocated
        }
        if sample.heap_blocks_in_use > t.process_peak_heap_blocks {
            t.process_peak_heap_blocks = sample.heap_blocks_in_use
        }
    }
    if sample.vm_graphics_footprint > t.process_peak_graphics_footprint {
        t.process_peak_graphics_footprint = sample.vm_graphics_footprint
    }
    if sample.vm_graphics_nofootprint > t.process_peak_graphics_nofootprint {
        t.process_peak_graphics_nofootprint = sample.vm_graphics_nofootprint
    }
}

// #+vet redundancy public-api
tracking_allocator_proc :: proc(
    allocator_data: rawptr,
    mode: mem.Allocator_Mode,
    size, alignment: int,
    old_memory: rawptr,
    old_size: int,
    loc := #caller_location,
) -> (
    result: []byte,
    err: mem.Allocator_Error,
) {
    data := (^Tracking_Allocator)(allocator_data)

    sync.mutex_guard(&data.mutex)
    should_sample_process := false

    if mode == .Query_Info {
        info := (^mem.Allocator_Query_Info)(old_memory)
        if info != nil && info.pointer != nil {
            if entry, ok := data.allocation_map[info.pointer]; ok {
                info.size = entry.size
                info.alignment = entry.alignment
            }
            info.pointer = nil
        }

        return
    }

    if mode == .Free && old_memory != nil && old_memory not_in data.allocation_map {
        tracking_allocator_bad_free_group_add(
            data,
            {memory = old_memory, location = loc, backtrace = trace(), count = 1},
        )
    } else {
        result = data.backing.procedure(data.backing.data, mode, size, alignment, old_memory, old_size, loc) or_return
    }
    result_ptr := raw_data(result)

    if data.allocation_map.allocator.procedure == nil {
        data.allocation_map.allocator = context.allocator
    }

    switch mode {
    case .Alloc, .Alloc_Non_Zeroed:
        entry: Tracking_Allocator_Entry = {
            memory    = result_ptr,
            size      = size,
            mode      = mode,
            alignment = alignment,
            err       = err,
            location  = loc,
            backtrace = trace(),
        }
        data.allocation_map[result_ptr] = entry
        data.live_alloc_size += entry.size
        if data.live_alloc_size > data.peak_live_alloc_size {
            data.peak_live_alloc_size = data.live_alloc_size
        }
        if len(data.allocation_map) > data.peak_live_alloc_count {
            data.peak_live_alloc_count = len(data.allocation_map)
        }
        tracking_allocator_leak_group_add(data, entry)
        tracking_allocator_top_alloc_group_add(data, entry)
        should_sample_process = true
    case .Free:
        if old_entry, ok := data.allocation_map[old_memory]; ok {
            data.live_alloc_size -= old_entry.size
            tracking_allocator_leak_group_remove(data, old_entry)
        }
        delete_key(&data.allocation_map, old_memory)
        should_sample_process = true
    case .Free_All:
        if data.clear_on_free_all {
            clear_map(&data.allocation_map)
            clear(&data.leak_group_index)
            clear(&data.leak_group_array)
            data.live_alloc_size = 0
        }
        should_sample_process = true
    case .Resize, .Resize_Non_Zeroed:
        if old_entry, ok := data.allocation_map[old_memory]; ok {
            data.live_alloc_size -= old_entry.size
            tracking_allocator_leak_group_remove(data, old_entry)
        }
        if old_memory != result_ptr {
            delete_key(&data.allocation_map, old_memory)
        }
        entry: Tracking_Allocator_Entry = {
            memory    = result_ptr,
            size      = size,
            mode      = mode,
            alignment = alignment,
            err       = err,
            location  = loc,
            backtrace = trace(),
        }
        data.allocation_map[result_ptr] = entry
        data.live_alloc_size += entry.size
        if data.live_alloc_size > data.peak_live_alloc_size {
            data.peak_live_alloc_size = data.live_alloc_size
        }
        if len(data.allocation_map) > data.peak_live_alloc_count {
            data.peak_live_alloc_count = len(data.allocation_map)
        }
        tracking_allocator_leak_group_add(data, entry)
        tracking_allocator_top_alloc_group_add(data, entry)
        should_sample_process = true

    case .Query_Features:
        set := (^mem.Allocator_Mode_Set)(old_memory)
        if set != nil {
            set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Free_All, .Resize, .Query_Features, .Query_Info}
        }
        return nil, nil

    case .Query_Info:
        unreachable()
    }

    if should_sample_process {
        data.process_sample_count += 1
        when TRACKING_PROCESS_SAMPLE_INTERVAL > 1 {
            if data.process_sample_count % u64(TRACKING_PROCESS_SAMPLE_INTERVAL) == 0 {
                tracking_allocator_note_process_memory_sample(data, tracking_process_memory_sample())
            }
        } else {
            tracking_allocator_note_process_memory_sample(data, tracking_process_memory_sample())
        }
    }

    return
}

Result_Type :: enum {
    Both,
    Leaks,
    Bad_Frees,
}

REPORT_RESET :: "\x1b[0m"
REPORT_RED_BOLD :: "\x1b[1;31m"
REPORT_GREEN_BOLD :: "\x1b[1;32m"
REPORT_CYAN_BOLD :: "\x1b[1;36m"

Tracking_Process_Memory_Flag :: enum u8 {
    ok,
    heap_ok,
    vm_ok,
}

Tracking_Process_Memory_Sample :: struct {
    heap_blocks_in_use:      u64,
    heap_size_allocated:     u64,
    heap_size_in_use:        u64,
    heap_size_in_use_peak:   u64,
    phys_footprint:          u64,
    rss:                     u64,
    virt:                    u64,
    vm_compressed:           u64,
    vm_compressed_peak:      u64,
    vm_device:               u64,
    vm_device_peak:          u64,
    vm_external:             u64,
    vm_external_peak:        u64,
    vm_graphics_footprint:   u64,
    vm_graphics_nofootprint: u64,
    vm_internal:             u64,
    vm_internal_peak:        u64,
    vm_resident_peak:        u64,
    vm_reusable:             u64,
    vm_reusable_peak:        u64,
    flags:                   bit_set[Tracking_Process_Memory_Flag;u8],
}

Tracking_Category_Snapshot :: struct {
    ok:                           bool,
    cpu_subset_live:              u64,
    cpu_subset_peak:              u64,
    cpu_subset_live_alloc_count:  u64,
    cpu_subset_peak_alloc_count:  u64,
    cpu_subset_total_alloc_bytes: u64,
    cpu_subset_total_alloc_count: u64,
    gpu_buffer_live:              u64,
    gpu_buffer_peak:              u64,
    gpu_image_live:               u64,
    gpu_image_peak:               u64,
    gpu_total_live:               u64,
    gpu_total_peak:               u64,
    gpu_device_live:              u64,
    gpu_device_peak:              u64,
}

Tracking_Category_Provider :: #type proc() -> Tracking_Category_Snapshot

tracking_category_provider: Tracking_Category_Provider

TRACKING_EXTERNAL_TOP_ALLOC_LIMIT :: #config(TRACKING_EXTERNAL_TOP_ALLOC_LIMIT, 16)

Tracking_External_Top_Alloc_Item :: struct {
    ok:             bool,
    label:          string,
    location:       runtime.Source_Code_Location,
    backtrace:      Trace_Const,
    rendered_stack: string,
    min_size:       u64,
    max_size:       u64,
    total_size:     u64,
    count:          int,
}

Tracking_External_Top_Alloc_Snapshot :: struct {
    count: int,
    items: [TRACKING_EXTERNAL_TOP_ALLOC_LIMIT]Tracking_External_Top_Alloc_Item,
}

Tracking_External_Top_Alloc_Provider :: #type proc() -> Tracking_External_Top_Alloc_Snapshot

tracking_external_top_alloc_provider: Tracking_External_Top_Alloc_Provider

TRACKING_CATEGORY_SNAPSHOT_FILE_VERSION :: 2
TRACKING_EXTERNAL_TOP_ALLOC_SNAPSHOT_FILE_VERSION :: 3

tracking_allocator_category_snapshot_path :: proc() -> string {
    temp_dir := back_tracking_temp_directory()
    if temp_dir == "" {
        return ""
    }
    return fmt.tprintf("%s/back-tracking-category-%v.txt", temp_dir, back_tracking_process_id())
}

tracking_allocator_external_top_alloc_snapshot_path :: proc() -> string {
    temp_dir := back_tracking_temp_directory()
    if temp_dir == "" {
        return ""
    }
    return fmt.tprintf("%s/back-tracking-top-alloc-%v.txt", temp_dir, back_tracking_process_id())
}

tracking_allocator_delete_persisted_category_snapshot :: proc() {
    path := tracking_allocator_category_snapshot_path()
    if path == "" do return
    back_tracking_remove_path(path)
}

tracking_allocator_delete_persisted_external_top_alloc_snapshot :: proc() {
    path := tracking_allocator_external_top_alloc_snapshot_path()
    if path == "" do return
    back_tracking_remove_path(path)
}

tracking_allocator_merge_category_snapshots :: proc(
    a, b: Tracking_Category_Snapshot,
) -> (
    merged: Tracking_Category_Snapshot,
) {
    if !a.ok do return b
    if !b.ok do return a

    merged.ok = true
    merged.cpu_subset_live = max(a.cpu_subset_live, b.cpu_subset_live)
    merged.cpu_subset_peak = max(a.cpu_subset_peak, b.cpu_subset_peak)
    merged.cpu_subset_live_alloc_count = max(a.cpu_subset_live_alloc_count, b.cpu_subset_live_alloc_count)
    merged.cpu_subset_peak_alloc_count = max(a.cpu_subset_peak_alloc_count, b.cpu_subset_peak_alloc_count)
    merged.cpu_subset_total_alloc_bytes = max(a.cpu_subset_total_alloc_bytes, b.cpu_subset_total_alloc_bytes)
    merged.cpu_subset_total_alloc_count = max(a.cpu_subset_total_alloc_count, b.cpu_subset_total_alloc_count)
    merged.gpu_buffer_live = max(a.gpu_buffer_live, b.gpu_buffer_live)
    merged.gpu_buffer_peak = max(a.gpu_buffer_peak, b.gpu_buffer_peak)
    merged.gpu_image_live = max(a.gpu_image_live, b.gpu_image_live)
    merged.gpu_image_peak = max(a.gpu_image_peak, b.gpu_image_peak)
    merged.gpu_total_live = max(a.gpu_total_live, b.gpu_total_live)
    merged.gpu_total_peak = max(a.gpu_total_peak, b.gpu_total_peak)
    merged.gpu_device_live = max(a.gpu_device_live, b.gpu_device_live)
    merged.gpu_device_peak = max(a.gpu_device_peak, b.gpu_device_peak)
    return merged
}

tracking_allocator_external_top_alloc_item_less :: proc(a, b: Tracking_External_Top_Alloc_Item) -> bool {
    when TOP_ALLOC_ORDER == "size" {
        if a.total_size != b.total_size {
            return a.total_size > b.total_size
        }
        if a.count != b.count {
            return a.count > b.count
        }
    } else when TOP_ALLOC_ORDER == "churn" {
        if a.count != b.count {
            return a.count > b.count
        }
        if a.total_size != b.total_size {
            return a.total_size > b.total_size
        }
    }
    if strings.compare(a.location.file_path, b.location.file_path) != 0 {
        return strings.compare(a.location.file_path, b.location.file_path) < 0
    }
    if a.location.line != b.location.line {
        return a.location.line < b.location.line
    }
    if a.location.column != b.location.column {
        return a.location.column < b.location.column
    }
    return strings.compare(a.label, b.label) < 0
}

tracking_allocator_external_top_alloc_item_same_bucket :: proc(a, b: Tracking_External_Top_Alloc_Item) -> bool {
    if a.label != b.label do return false
    if a.location.file_path != b.location.file_path do return false
    if a.location.line != b.location.line do return false
    if a.location.column != b.location.column do return false
    if a.location.procedure != b.location.procedure do return false
    return true
}

tracking_allocator_clone_external_top_alloc_item :: proc(
    item: Tracking_External_Top_Alloc_Item,
) -> (
    cloned: Tracking_External_Top_Alloc_Item,
    ok: bool,
) {
    cloned = item
    if item.label != "" {
        label, label_err := strings.clone(item.label, context.allocator)
        if label_err != nil {
            return {}, false
        }
        cloned.label = label
    }
    if item.location.file_path != "" {
        file_path, file_path_err := strings.clone(item.location.file_path, context.allocator)
        if file_path_err != nil {
            return {}, false
        }
        cloned.location.file_path = file_path
    }
    if item.location.procedure != "" {
        procedure, procedure_err := strings.clone(item.location.procedure, context.allocator)
        if procedure_err != nil {
            return {}, false
        }
        cloned.location.procedure = procedure
    }
    if item.rendered_stack != "" {
        rendered_stack, rendered_stack_err := strings.clone(item.rendered_stack, context.allocator)
        if rendered_stack_err != nil {
            return {}, false
        }
        cloned.rendered_stack = rendered_stack
    }
    return cloned, true
}

tracking_allocator_quote_string :: proc(s: string) -> string {
    builder: strings.Builder
    if _, err := strings.builder_init(&builder, 0, max(len(s) * 2 + 2, 2), context.temp_allocator); err != nil {
        return `""`
    }
    _ = strings.write_quoted_string(&builder, s)
    return strings.to_string(builder)
}

tracking_allocator_unquote_string :: proc(s: string) -> string {
    unquoted, _, ok := strconv.unquote_string(s, context.temp_allocator)
    if !ok {
        return ""
    }
    return unquoted
}

tracking_allocator_load_persisted_category_snapshot :: proc() -> Tracking_Category_Snapshot {
    path := tracking_allocator_category_snapshot_path()
    if path == "" {
        return {}
    }

    raw, read_ok := back_tracking_read_entire_file(path, context.temp_allocator)
    if !read_ok {
        return {}
    }
    defer delete(raw, context.temp_allocator)

    fields, split_err := strings.fields(string(raw), context.temp_allocator)
    if split_err != nil || len(fields) == 0 {
        return {}
    }
    defer delete(fields, context.temp_allocator)

    version, version_ok := strconv.parse_uint(fields[0])
    if !version_ok {
        return {}
    }

    if version == 1 {
        if len(fields) != 11 {
            return {}
        }

        values: [10]u64
        for field, i in fields[1:] {
            value, ok := strconv.parse_uint(field)
            if !ok {
                return {}
            }
            values[i] = u64(value)
        }

        return {
            ok = true,
            cpu_subset_live = 0,
            cpu_subset_peak = values[1],
            cpu_subset_live_alloc_count = 0,
            cpu_subset_peak_alloc_count = 0,
            cpu_subset_total_alloc_bytes = 0,
            cpu_subset_total_alloc_count = 0,
            gpu_buffer_live = 0,
            gpu_buffer_peak = values[3],
            gpu_image_live = 0,
            gpu_image_peak = values[5],
            gpu_total_live = 0,
            gpu_total_peak = values[7],
            gpu_device_live = 0,
            gpu_device_peak = values[9],
        }
    }

    if version != TRACKING_CATEGORY_SNAPSHOT_FILE_VERSION || len(fields) != 15 {
        return {}
    }

    values: [14]u64
    for field, i in fields[1:] {
        value, ok := strconv.parse_uint(field)
        if !ok {
            return {}
        }
        values[i] = u64(value)
    }

    return {
        ok = true,
        cpu_subset_live = 0,
        cpu_subset_peak = values[1],
        cpu_subset_live_alloc_count = 0,
        cpu_subset_peak_alloc_count = values[3],
        cpu_subset_total_alloc_bytes = values[4],
        cpu_subset_total_alloc_count = values[5],
        gpu_buffer_live = 0,
        gpu_buffer_peak = values[7],
        gpu_image_live = 0,
        gpu_image_peak = values[9],
        gpu_total_live = 0,
        gpu_total_peak = values[11],
        gpu_device_live = 0,
        gpu_device_peak = values[13],
    }
}

tracking_allocator_load_persisted_external_top_alloc_snapshot :: proc(
) -> (
    snapshot: Tracking_External_Top_Alloc_Snapshot,
) {
    path := tracking_allocator_external_top_alloc_snapshot_path()
    if path == "" {
        return
    }

    raw, read_ok := back_tracking_read_entire_file(path, context.temp_allocator)
    if !read_ok {
        return
    }

    lines, split_err := strings.split_lines(string(raw), context.temp_allocator)
    if split_err != nil {
        delete(raw, context.temp_allocator)
        return
    }

    groups: [dynamic]Tracking_External_Top_Alloc_Item
    groups.allocator = context.temp_allocator
    defer {
        delete(groups)
        delete(lines, context.temp_allocator)
        delete(raw, context.temp_allocator)
    }

    for line in lines {
        if line == "" {
            continue
        }

        fields, fields_err := strings.split(line, "\t", context.temp_allocator)
        if fields_err != nil {
            return {}
        }
        if len(fields) != 9 && len(fields) != 10 && len(fields) != 11 {
            delete(fields, context.temp_allocator)
            continue
        }

        version, version_ok := strconv.parse_uint(fields[0])
        if !version_ok ||
           (version != 1 && version != 2 && version != TRACKING_EXTERNAL_TOP_ALLOC_SNAPSHOT_FILE_VERSION) {
            delete(fields, context.temp_allocator)
            continue
        }
        if version == 1 && len(fields) != 9 {
            delete(fields, context.temp_allocator)
            continue
        }
        if version == 2 && len(fields) != 10 {
            delete(fields, context.temp_allocator)
            continue
        }
        if version == TRACKING_EXTERNAL_TOP_ALLOC_SNAPSHOT_FILE_VERSION && len(fields) != 11 {
            delete(fields, context.temp_allocator)
            continue
        }

        line_no, line_ok := strconv.parse_int(fields[3])
        column_no, column_ok := strconv.parse_int(fields[4])
        min_size_idx := 6 if version == TRACKING_EXTERNAL_TOP_ALLOC_SNAPSHOT_FILE_VERSION else -1
        max_size_idx := 6
        total_size_idx := 7
        count_idx := 8
        rendered_stack_idx := 9
        if version == TRACKING_EXTERNAL_TOP_ALLOC_SNAPSHOT_FILE_VERSION {
            max_size_idx = 7
            total_size_idx = 8
            count_idx = 9
            rendered_stack_idx = 10
        }

        min_size: u64 = 0
        min_ok := true
        if min_size_idx >= 0 {
            parsed_min_size, parsed_min_ok := strconv.parse_uint(fields[min_size_idx])
            min_size = u64(parsed_min_size)
            min_ok = parsed_min_ok
        }
        max_size, max_ok := strconv.parse_uint(fields[max_size_idx])
        total_size, total_ok := strconv.parse_uint(fields[total_size_idx])
        count, count_ok := strconv.parse_int(fields[count_idx])
        if !line_ok || !column_ok || !min_ok || !max_ok || !total_ok || !count_ok {
            delete(fields, context.temp_allocator)
            continue
        }

        label := fields[1]
        file_path := fields[2]
        procedure := fields[5]
        if version >= 2 {
            label = tracking_allocator_unquote_string(fields[1])
            file_path = tracking_allocator_unquote_string(fields[2])
            procedure = tracking_allocator_unquote_string(fields[5])
        }

        item: Tracking_External_Top_Alloc_Item = {
            ok = true,
            label = label,
            location = {file_path = file_path, line = i32(line_no), column = i32(column_no), procedure = procedure},
            min_size = min_size,
            max_size = u64(max_size),
            total_size = u64(total_size),
            count = count,
        }
        if item.min_size == 0 {
            item.min_size = item.max_size
        }
        if version >= 2 {
            item.rendered_stack = tracking_allocator_unquote_string(fields[rendered_stack_idx])
        }

        merged := false
        for &group in groups {
            if !tracking_allocator_external_top_alloc_item_same_bucket(group, item) {
                continue
            }
            group.count += item.count
            group.total_size += item.total_size
            if item.min_size < group.min_size {
                group.min_size = item.min_size
            }
            if item.max_size > group.max_size {
                group.max_size = item.max_size
                group.backtrace = item.backtrace
                group.rendered_stack = item.rendered_stack
            } else if group.rendered_stack == "" && item.rendered_stack != "" {
                group.rendered_stack = item.rendered_stack
            }
            merged = true
            break
        }
        if !merged {
            append(&groups, item)
        }
        delete(fields, context.temp_allocator)
    }

    slice.sort_by(groups[:], tracking_allocator_external_top_alloc_item_less)
    for item in groups[:min(len(groups), len(snapshot.items))] {
        cloned, clone_ok := tracking_allocator_clone_external_top_alloc_item(item)
        if !clone_ok {
            return {}
        }
        snapshot.items[snapshot.count] = cloned
        snapshot.count += 1
    }
    return snapshot
}

tracking_allocator_store_persisted_category_snapshot :: proc(snapshot: Tracking_Category_Snapshot) {
    if !snapshot.ok {
        return
    }

    path := tracking_allocator_category_snapshot_path()
    if path == "" {
        return
    }

    data := fmt.tprintf(
        "%v %v %v %v %v %v %v %v %v %v %v %v %v %v %v\n",
        TRACKING_CATEGORY_SNAPSHOT_FILE_VERSION,
        snapshot.cpu_subset_live,
        snapshot.cpu_subset_peak,
        snapshot.cpu_subset_live_alloc_count,
        snapshot.cpu_subset_peak_alloc_count,
        snapshot.cpu_subset_total_alloc_bytes,
        snapshot.cpu_subset_total_alloc_count,
        snapshot.gpu_buffer_live,
        snapshot.gpu_buffer_peak,
        snapshot.gpu_image_live,
        snapshot.gpu_image_peak,
        snapshot.gpu_total_live,
        snapshot.gpu_total_peak,
        snapshot.gpu_device_live,
        snapshot.gpu_device_peak,
    )
    back_tracking_write_entire_string(path, data)
}

tracking_allocator_store_persisted_external_top_alloc_snapshot :: proc(
    snapshot: Tracking_External_Top_Alloc_Snapshot,
) {
    if snapshot.count <= 0 {
        return
    }

    path := tracking_allocator_external_top_alloc_snapshot_path()
    if path == "" {
        return
    }

    for i in 0 ..< snapshot.count {
        item := snapshot.items[i]
        if !item.ok || item.total_size == 0 || item.max_size == 0 || item.count <= 0 {
            continue
        }
        if item.min_size == 0 {
            item.min_size = item.max_size
        }
        if item.rendered_stack == "" {
            stack, stack_err := lines_const(item.backtrace)
            item.rendered_stack = tracking_render_stack(stack, stack_err, item.location)
            lines_destroy(stack)
        }

        data := fmt.tprintf(
            "%v\t%s\t%s\t%v\t%v\t%s\t%v\t%v\t%v\t%v\t%s\n",
            TRACKING_EXTERNAL_TOP_ALLOC_SNAPSHOT_FILE_VERSION,
            tracking_allocator_quote_string(item.label),
            tracking_allocator_quote_string(item.location.file_path),
            item.location.line,
            item.location.column,
            tracking_allocator_quote_string(item.location.procedure),
            item.min_size,
            item.max_size,
            item.total_size,
            item.count,
            tracking_allocator_quote_string(item.rendered_stack),
        )
        back_tracking_append_string(path, data)
    }
}

tracking_allocator_set_category_provider :: proc(provider: Tracking_Category_Provider) {
    tracking_category_provider = provider
}

tracking_allocator_set_external_top_alloc_provider :: proc(provider: Tracking_External_Top_Alloc_Provider) {
    tracking_external_top_alloc_provider = provider
}

tracking_allocator_category_snapshot :: proc() -> Tracking_Category_Snapshot {
    snapshot := tracking_allocator_load_persisted_category_snapshot()
    if tracking_category_provider != nil {
        snapshot = tracking_allocator_merge_category_snapshots(snapshot, tracking_category_provider())
    }
    return snapshot
}

tracking_allocator_external_top_alloc_snapshot :: proc() -> Tracking_External_Top_Alloc_Snapshot {
    if tracking_external_top_alloc_provider != nil {
        return tracking_external_top_alloc_provider()
    }
    return tracking_allocator_load_persisted_external_top_alloc_snapshot()
}

tracking_allocator_print_summary :: proc(
    t: ^Tracking_Allocator,
    process_memory: Tracking_Process_Memory_Sample,
    category: Tracking_Category_Snapshot,
    has_failures: bool,
    live_alloc_size, live_alloc_count, total_alloc_size, total_alloc_count: int,
    gap_label: string,
    gap_bytes: u64,
    total_events, leak_events, bad_free_events, total_groups: int,
) {
    sdl_memory := tracking_sdl_memory_snapshot()
    fmt.eprintf("\n%s[report leak] summary%s\n", REPORT_CYAN_BOLD, REPORT_RESET)
    if has_failures {
        fmt.eprintf("status: %sFAIL%s\n", REPORT_RED_BOLD, REPORT_RESET)
    } else {
        fmt.eprintf("status: %sPASS%s\n", REPORT_GREEN_BOLD, REPORT_RESET)
    }
    if t.process_peak_ok {
        if t.process_peak_phys != 0 {
            fmt.eprintf("process peak: %M footprint, %M rss\n", t.process_peak_phys, t.process_peak_rss)
        } else {
            fmt.eprintf("process peak: %M rss\n", t.process_peak_rss)
        }
    }
    if .ok in process_memory.flags {
        if process_memory.phys_footprint != 0 {
            fmt.eprintf("process now: %M footprint, %M rss\n", process_memory.phys_footprint, process_memory.rss)
        } else {
            fmt.eprintf("process now: %M rss\n", process_memory.rss)
        }
    }
    fmt.eprintf("tracked now: %M live, %v allocs\n", live_alloc_size, live_alloc_count)
    fmt.eprintf("tracked peak: %M live, %v allocs\n", t.peak_live_alloc_size, t.peak_live_alloc_count)
    fmt.eprintf("tracked cumulative: %M, %v allocs\n", total_alloc_size, total_alloc_count)
    if .heap_ok in process_memory.flags {
        fmt.eprintf(
            "darwin heap now: %M in-use, %M reserved, %v blocks\n",
            process_memory.heap_size_in_use,
            process_memory.heap_size_allocated,
            process_memory.heap_blocks_in_use,
        )
        fmt.eprintf(
            "darwin heap peak: %M touched, %M reserved, %v blocks\n",
            process_memory.heap_size_in_use_peak,
            t.process_peak_heap_reserved,
            t.process_peak_heap_blocks,
        )
    }
    if .vm_ok in process_memory.flags {
        fmt.eprintf(
            "darwin vm now: %M internal, %M compressed, %M device, %M reusable, %M external\n",
            process_memory.vm_internal,
            process_memory.vm_compressed,
            process_memory.vm_device,
            process_memory.vm_reusable,
            process_memory.vm_external,
        )
        fmt.eprintf(
            "darwin vm peak: %M internal, %M compressed, %M device, %M reusable, %M external\n",
            process_memory.vm_internal_peak,
            process_memory.vm_compressed_peak,
            process_memory.vm_device_peak,
            process_memory.vm_reusable_peak,
            process_memory.vm_external_peak,
        )
        if process_memory.vm_graphics_footprint != 0 || process_memory.vm_graphics_nofootprint != 0 {
            fmt.eprintf(
                "darwin graphics ledger now: %M footprint, %M no-footprint\n",
                process_memory.vm_graphics_footprint,
                process_memory.vm_graphics_nofootprint,
            )
        }
        if t.process_peak_graphics_footprint != 0 || t.process_peak_graphics_nofootprint != 0 {
            fmt.eprintf(
                "darwin graphics ledger peak: %M footprint, %M no-footprint\n",
                t.process_peak_graphics_footprint,
                t.process_peak_graphics_nofootprint,
            )
        }
    }
    if category.ok {
        cpu_same_frame_now := u64(max(live_alloc_size, 0)) + sdl_memory.live_bytes
        cpu_peak_upper_bound := u64(max(t.peak_live_alloc_size, 0)) + sdl_memory.peak_live_bytes
        gpu_same_frame_now := category.gpu_total_live
        if category.gpu_device_live > gpu_same_frame_now {
            gpu_same_frame_now = category.gpu_device_live
        }
        if process_memory.vm_graphics_footprint > gpu_same_frame_now {
            gpu_same_frame_now = process_memory.vm_graphics_footprint
        }

        gpu_peak_upper_bound := category.gpu_total_peak
        if category.gpu_device_peak > gpu_peak_upper_bound {
            gpu_peak_upper_bound = category.gpu_device_peak
        }
        if t.process_peak_graphics_footprint > gpu_peak_upper_bound {
            gpu_peak_upper_bound = t.process_peak_graphics_footprint
        }

        gpu_extra_now: u64
        if gpu_same_frame_now > category.gpu_total_live {
            gpu_extra_now = gpu_same_frame_now - category.gpu_total_live
        }
        gpu_extra_peak_upper_bound: u64
        if gpu_peak_upper_bound > category.gpu_total_peak {
            gpu_extra_peak_upper_bound = gpu_peak_upper_bound - category.gpu_total_peak
        }

        fmt.eprintf(
            "sokol cpu subset now: %M live, %v allocs\n",
            category.cpu_subset_live,
            category.cpu_subset_live_alloc_count,
        )
        fmt.eprintf(
            "sokol cpu subset peak: %M live, %v allocs\n",
            category.cpu_subset_peak,
            category.cpu_subset_peak_alloc_count,
        )
        fmt.eprintf(
            "sokol cpu subset cumulative: %M, %v allocs\n",
            category.cpu_subset_total_alloc_bytes,
            category.cpu_subset_total_alloc_count,
        )
        if .ok in sdl_memory.flags {
            fmt.eprintf("sdl cpu subset now: %M live, %v allocs\n", sdl_memory.live_bytes, sdl_memory.live_alloc_count)
            fmt.eprintf(
                "sdl cpu subset peak: %M live, %v allocs\n",
                sdl_memory.peak_live_bytes,
                sdl_memory.peak_live_alloc_count,
            )
            fmt.eprintf(
                "sdl cpu subset cumulative: %M, %v allocs\n",
                sdl_memory.total_alloc_bytes,
                sdl_memory.total_alloc_count,
            )
            if .install_too_late in sdl_memory.flags {
                fmt.eprintf(
                    "sdl cpu subset note: partial, %v SDL allocs existed before hook install\n",
                    sdl_memory.preexisting_alloc_count,
                )
            }
        } else if .install_too_late in sdl_memory.flags {
            fmt.eprintf(
                "sdl cpu subset: unavailable, %v SDL allocs existed before hook install\n",
                sdl_memory.preexisting_alloc_count,
            )
        }
        if category.gpu_total_live > 0 {
            fmt.eprintf(
                "gpu estimated now: %M buffers + %M images = %M\n",
                category.gpu_buffer_live,
                category.gpu_image_live,
                category.gpu_total_live,
            )
        }
        fmt.eprintf(
            "gpu estimated peak: %M buffers + %M images = %M\n",
            category.gpu_buffer_peak,
            category.gpu_image_peak,
            category.gpu_total_peak,
        )
        if category.gpu_device_live > 0 do fmt.eprintf("metal device now: %M currentAllocatedSize\n", category.gpu_device_live)
        if category.gpu_device_peak > 0 {
            fmt.eprintf("metal device peak: %M currentAllocatedSize\n", category.gpu_device_peak)
        }
        if gpu_same_frame_now > 0 {
            fmt.eprintf("gpu extra now: %M swapchain/depth/msaa/private estimate\n", gpu_extra_now)
        }
        fmt.eprintf("gpu extra peak ub: %M swapchain/depth/msaa/private estimate\n", gpu_extra_peak_upper_bound)
        if gpu_same_frame_now > 0 || cpu_same_frame_now > 0 {
            fmt.eprintf(
                "categorized now: %M tracked cpu + %M sdl cpu + %M gpu/graphics = %M\n",
                live_alloc_size,
                sdl_memory.live_bytes,
                gpu_same_frame_now,
                cpu_same_frame_now + gpu_same_frame_now,
            )
        }
        fmt.eprintf(
            "categorized peak ub: %M tracked cpu peak + %M sdl cpu peak + %M gpu/graphics peak = %M\n",
            t.peak_live_alloc_size,
            sdl_memory.peak_live_bytes,
            gpu_peak_upper_bound,
            cpu_peak_upper_bound + gpu_peak_upper_bound,
        )
    }
    device_or_gpu_peak := category.gpu_total_peak
    if category.gpu_device_peak > device_or_gpu_peak {
        device_or_gpu_peak = category.gpu_device_peak
    }
    if .vm_ok in process_memory.flags && process_memory.vm_device_peak > device_or_gpu_peak {
        device_or_gpu_peak = process_memory.vm_device_peak
    }
    if t.process_peak_graphics_footprint > device_or_gpu_peak {
        device_or_gpu_peak = t.process_peak_graphics_footprint
    }
    if t.process_peak_ok {
        fmt.eprintf("%s: %M\n", gap_label, gap_bytes)
    }
    fmt.eprintf("events: %v total (%v leak, %v bad-free)\n", total_events, leak_events, bad_free_events)
    fmt.eprintf("groups: %v unique stack/message patterns\n", total_groups)
}

tracking_trim_symbol :: proc(symbol: string) -> string {
    if proc_start := strings.index(symbol, ":proc("); proc_start >= 0 {
        return symbol[:proc_start]
    }
    return symbol
}

tracking_extract_odin_path :: proc(location: string) -> string {
    odin_idx := strings.index(location, ".odin")
    if odin_idx < 0 {
        return ""
    }
    return location[:odin_idx + len(".odin")]
}

tracking_basename :: proc(path: string) -> string {
    slash := strings.last_index(path, "/")
    backslash := strings.last_index(path, "\\")
    sep := max(slash, backslash)
    if sep >= 0 && sep + 1 < len(path) {
        return path[sep + 1:]
    }
    return path
}

// #+vet redundancy public-api
tracking_short_path :: proc(path, cwd: string) -> string {
    if cwd == "" || !strings.has_prefix(path, cwd) {
        return path
    }
    if len(path) == len(cwd) {
        return "."
    }
    if len(path) > len(cwd) {
        c := path[len(cwd)]
        if c == '/' || c == '\\' {
            return path[len(cwd) + 1:]
        }
    }
    return path
}

tracking_source_loc_display :: proc(loc: runtime.Source_Code_Location, cwd: string) -> string {
    return fmt.tprintf("%s:%v:%v", tracking_short_path(loc.file_path, cwd), loc.line, loc.column)
}

tracking_stack_location_display :: proc(location: string) -> string {
    path := tracking_extract_odin_path(location)
    if path == "" {
        return location
    }
    file := tracking_basename(path)
    suffix := location[len(path):]
    if len(suffix) == 0 {
        return file
    }
    if suffix[0] == '(' {
        if close := strings.index(suffix, ")"); close > 1 {
            return fmt.tprintf("%s:%s", file, suffix[1:close])
        }
    }
    if suffix[0] == ':' {
        end := 1
        for end < len(suffix) {
            c := suffix[end]
            if (c < '0' || c > '9') && c != ':' {
                break
            }
            end += 1
        }
        if end > 1 {
            return fmt.tprintf("%s:%s", file, suffix[1:end])
        }
    }
    return file
}

tracking_package_from_symbol_or_location :: proc(symbol, location: string) -> string {
    if separator := strings.index(symbol, "::"); separator > 0 {
        return symbol[:separator]
    }

    path := tracking_extract_odin_path(location)
    if path == "" {
        return symbol
    }
    slash := strings.last_index(path, "/")
    backslash := strings.last_index(path, "\\")
    sep := max(slash, backslash)
    if sep <= 0 {
        return tracking_basename(path)
    }
    parent := path[:sep]
    pslash := strings.last_index(parent, "/")
    pbackslash := strings.last_index(parent, "\\")
    psep := max(pslash, pbackslash)
    if psep >= 0 && psep + 1 < len(parent) {
        return parent[psep + 1:]
    }
    return parent
}

tracking_is_internal_stack_line :: proc(line: Line) -> bool {
    symbol := tracking_trim_symbol(line.symbol)
    if symbol == "??" && tracking_extract_odin_path(line.location) == "" {
        return true
    }
    if symbol == "_trace" ||
       symbol == "trace" ||
       symbol == "tracking_allocator_proc" ||
       symbol == "other_instrumentation_enter" ||
       symbol == "other_instrumentation_exit" ||
       symbol == "main" {
        return true
    }
    return false
}

tracking_render_stack :: proc(
    lines: []Line,
    err: Lines_Error,
    fallback_loc: runtime.Source_Code_Location = {},
) -> string {
    builder: strings.Builder
    if _, builder_err := strings.builder_init(&builder, context.temp_allocator); builder_err != nil {
        return ""
    }

    if err != nil {
        fmt.sbprintf(&builder, "   backtrace error: %v\n", err)
        return strings.to_string(builder)
    }
    if len(lines) == 0 {
        if fallback_loc.file_path == "" {
            return ""
        }
        culprit := tracking_trim_symbol(fallback_loc.procedure)
        if culprit != "" {
            fmt.sbprintf(&builder, "   culprit: %s\n", culprit)
        }
        fmt.sbprintf(&builder, "   stack:\n")
        symbol := tracking_trim_symbol(fallback_loc.procedure)
        package_name := tracking_package_from_symbol_or_location(symbol, fallback_loc.file_path)
        frame_location := tracking_stack_location_display(
            fmt.tprintf("%s:%v:%v", fallback_loc.file_path, fallback_loc.line, fallback_loc.column),
        )
        fmt.sbprintf(&builder, "     %s[%s]%s (%s)\n", REPORT_CYAN_BOLD, package_name, REPORT_RESET, frame_location)
        return strings.to_string(builder)
    }

    visible_count: int
    has_odin_frame := false
    culprit := ""
    for line in lines {
        if !tracking_is_internal_stack_line(line) {
            visible_count += 1
            if tracking_extract_odin_path(line.location) != "" {
                has_odin_frame = true
            }
            if culprit == "" {
                culprit = tracking_trim_symbol(line.symbol)
            }
        }
    }

    use_fallback_loc := !has_odin_frame && fallback_loc.file_path != ""
    if use_fallback_loc && fallback_loc.procedure != "" {
        culprit = tracking_trim_symbol(fallback_loc.procedure)
    }

    if culprit != "" {
        fmt.sbprintf(&builder, "   culprit: %s\n", culprit)
    }

    fmt.sbprintf(&builder, "   stack:\n")
    if use_fallback_loc {
        symbol := tracking_trim_symbol(fallback_loc.procedure)
        package_name := tracking_package_from_symbol_or_location(symbol, fallback_loc.file_path)
        frame_location := tracking_stack_location_display(
            fmt.tprintf("%s:%v:%v", fallback_loc.file_path, fallback_loc.line, fallback_loc.column),
        )
        fmt.sbprintf(&builder, "     %s[%s]%s (%s)\n", REPORT_CYAN_BOLD, package_name, REPORT_RESET, frame_location)
    }
    for line in lines {
        if visible_count > 0 && tracking_is_internal_stack_line(line) {
            continue
        }
        symbol := tracking_trim_symbol(line.symbol)
        package_name := tracking_package_from_symbol_or_location(symbol, line.location)
        frame_location := tracking_stack_location_display(line.location)
        fmt.sbprintf(&builder, "     %s[%s]%s (%s)\n", REPORT_CYAN_BOLD, package_name, REPORT_RESET, frame_location)
    }
    return strings.to_string(builder)
}

tracking_print_stack :: proc(lines: []Line, err: Lines_Error, fallback_loc: runtime.Source_Code_Location = {}) {
    rendered := tracking_render_stack(lines, err, fallback_loc)
    if rendered == "" {
        return
    }
    fmt.eprint(rendered)
}

TOP_ALLOC :: #config(TOP_ALLOC, 10)
TOP_ALLOC_ORDER :: #config(TOP_ALLOC_ORDER, "churn")
#assert(TOP_ALLOC_ORDER == "size" || TOP_ALLOC_ORDER == "churn")

tracking_allocator_print_results :: proc(t: ^Tracking_Allocator, type: Result_Type = .Both) {
    context.allocator = t.internals_allocator

    leak_groups: [dynamic]Tracking_Leak_Group
    defer delete(leak_groups)
    bad_free_groups: [dynamic]Tracking_Allocator_Bad_Free_Entry
    defer delete(bad_free_groups)
    top_alloc_items: [dynamic]Tracking_External_Top_Alloc_Item
    defer delete(top_alloc_items)

    if type == .Both || type == .Leaks {
        for leak in t.leak_group_array {
            if leak.count <= 0 {
                continue
            }
            append(&leak_groups, leak)
        }
    }

    if type == .Both || type == .Bad_Frees {
        for bad_free in t.bad_free_array {
            if bad_free.count <= 0 {
                continue
            }
            append(&bad_free_groups, bad_free)
        }
    }
    if type == .Both {
        for group in t.alloc_top_group_array {
            if group.count <= 0 || group.max_size <= 0 {
                continue
            }
            append(&top_alloc_items, Tracking_External_Top_Alloc_Item {
                ok         = true,
                location   = group.key.location,
                backtrace  = group.backtrace,
                min_size   = u64(max(group.min_size, 0)),
                max_size   = u64(max(group.max_size, 0)),
                total_size = u64(max(group.total_size, 0)),
                count      = group.count,
            })
        }
        external_top_alloc := tracking_allocator_external_top_alloc_snapshot()
        for item in external_top_alloc.items[:external_top_alloc.count] {
            if !item.ok || item.total_size == 0 {
                continue
            }
            normalized_item := item
            if normalized_item.min_size == 0 {
                normalized_item.min_size = normalized_item.max_size
            }
            append(&top_alloc_items, normalized_item)
        }
        sdl_top_alloc := tracking_sdl_external_top_alloc_snapshot()
        for item in sdl_top_alloc.items[:sdl_top_alloc.count] {
            if !item.ok || item.total_size == 0 {
                continue
            }
            normalized_item := item
            if normalized_item.min_size == 0 {
                normalized_item.min_size = normalized_item.max_size
            }
            append(&top_alloc_items, normalized_item)
        }
    }

    leak_events: int
    for leak in leak_groups {
        leak_events += leak.count
    }
    bad_free_events: int
    for bad_free in bad_free_groups {
        bad_free_events += bad_free.count
    }
    total_groups := len(leak_groups) + len(bad_free_groups)
    has_failures := total_groups > 0
    if !has_failures && len(top_alloc_items) == 0 {
        return
    }
    total_events := leak_events + bad_free_events
    live_alloc_count := len(t.allocation_map)
    live_alloc_size := t.live_alloc_size
    total_alloc_count: int
    total_alloc_size: int
    for item in top_alloc_items {
        if item.label != "" {
            continue
        }
        total_alloc_count += item.count
        total_alloc_size += int(item.total_size)
    }
    process_memory := tracking_process_memory_sample()
    tracking_allocator_note_process_memory_sample(t, process_memory)
    category := tracking_allocator_category_snapshot()
    sdl_memory := tracking_sdl_memory_snapshot()
    process_peak_live := t.process_peak_phys
    if process_peak_live == 0 do process_peak_live = t.process_peak_rss
    tracked_peak_live := u64(max(t.peak_live_alloc_size, 0))
    peak_gap_bytes: u64
    if process_peak_live > tracked_peak_live {
        peak_gap_bytes = process_peak_live - tracked_peak_live
    }
    peak_gap_label := "untracked peak gap"

    cwd := back_tracking_get_working_directory()
    explained_gpu_peak := category.gpu_total_peak
    if category.gpu_device_peak > explained_gpu_peak {
        explained_gpu_peak = category.gpu_device_peak
    }
    if .vm_ok in process_memory.flags && process_memory.vm_device_peak > explained_gpu_peak {
        explained_gpu_peak = process_memory.vm_device_peak
    }
    if t.process_peak_graphics_footprint > explained_gpu_peak {
        explained_gpu_peak = t.process_peak_graphics_footprint
    }
    if explained_gpu_peak > 0 {
        categorized_peak_est := tracked_peak_live + sdl_memory.peak_live_bytes + explained_gpu_peak
        peak_gap_label = "unattributed peak gap"
        if process_peak_live > categorized_peak_est {
            peak_gap_bytes = process_peak_live - categorized_peak_est
        } else {
            peak_gap_bytes = 0
        }
    }

    when TOP_ALLOC != 0 {
        top_alloc_report: {
            if len(top_alloc_items) == 0 {
                break top_alloc_report
            }

            limit := TOP_ALLOC
            if limit < 0 {
                limit = len(top_alloc_items)
            } else {
                limit = min(limit, len(top_alloc_items))
            }
            slice.sort_by(top_alloc_items[:], proc(a, b: Tracking_External_Top_Alloc_Item) -> bool {
                return tracking_allocator_external_top_alloc_item_less(a, b)
            })
            when TOP_ALLOC_ORDER == "size" {
                LABEL :: "size"
            } else when TOP_ALLOC_ORDER == "churn" {
                LABEL :: "count"
            }
            fmt.eprintf(
                "top allocations by total " + LABEL + ": %v of %v unique allocation locations/runtime buckets\n",
                limit,
                len(top_alloc_items),
            )

            #reverse for item, index in top_alloc_items[:limit] {
                if item.label == "" {
                    if item.min_size == item.max_size {
                        fmt.eprintf(
                            "\n%v. %stop-alloc%s %M x%v\n",
                            index + 1,
                            REPORT_CYAN_BOLD,
                            REPORT_RESET,
                            item.max_size,
                            item.count,
                        )
                    } else {
                        fmt.eprintf(
                            "\n%v. %stop-alloc%s [%M, %M] x%v\n",
                            index + 1,
                            REPORT_CYAN_BOLD,
                            REPORT_RESET,
                            item.min_size,
                            item.max_size,
                            item.count,
                        )
                    }
                } else {
                    if item.min_size == item.max_size {
                        fmt.eprintf(
                            "\n%v. %stop-alloc[%s]%s %M x%v\n",
                            index + 1,
                            REPORT_CYAN_BOLD,
                            item.label,
                            REPORT_RESET,
                            item.max_size,
                            item.count,
                        )
                    } else {
                        fmt.eprintf(
                            "\n%v. %stop-alloc[%s]%s [%M, %M] x%v\n",
                            index + 1,
                            REPORT_CYAN_BOLD,
                            item.label,
                            REPORT_RESET,
                            item.min_size,
                            item.max_size,
                            item.count,
                        )
                    }
                }
                fmt.eprintf("   total: %M\n", item.total_size)
                if item.location.file_path != "" {
                    fmt.eprintf("   at: %s\n", tracking_source_loc_display(item.location, cwd))
                } else if item.label != "" {
                    fmt.eprintf("   at: %s runtime bucket\n", item.label)
                }
                if item.rendered_stack != "" && item.backtrace.len == 0 {
                    fmt.eprint(item.rendered_stack)
                } else {
                    stack, stack_err := lines_const(item.backtrace)
                    defer lines_destroy(stack)
                    tracking_print_stack(stack, stack_err, item.location)
                }
            }
        }
    }
    if !has_failures {
        tracking_allocator_print_summary(
            t,
            process_memory,
            category,
            has_failures,
            live_alloc_size,
            live_alloc_count,
            total_alloc_size,
            total_alloc_count,
            peak_gap_label,
            peak_gap_bytes,
            total_events,
            leak_events,
            bad_free_events,
            total_groups,
        )
        return
    }

    when ODIN_OS == .Windows && !ODIN_DEBUG {
        group_idx := 1
        for leak, li in leak_groups {
            if leak.count == 1 {
                fmt.eprintf("\n%v. %sleak%s %M\n", group_idx, REPORT_RED_BOLD, REPORT_RESET, leak.key.size)
            } else {
                fmt.eprintf(
                    "\n%v. %sleak%s %M x%v =%M\n",
                    group_idx,
                    REPORT_RED_BOLD,
                    REPORT_RESET,
                    leak.key.size,
                    leak.count,
                    leak.key.size * leak.count,
                )
            }
            fmt.eprintf("   at: %s\n", tracking_source_loc_display(leak.key.location, cwd))
            fmt.eprintln("   stack: Compile with `-debug` to get a back trace")
            if li + 1 < len(leak_groups) || len(bad_free_groups) > 0 { fmt.eprintln() }
            group_idx += 1
        }

        for bad_free, fi in bad_free_groups {
            fmt.eprintf("%v. %sbad-free%s x%v\n", group_idx, REPORT_RED_BOLD, REPORT_RESET, bad_free.count)
            fmt.eprintf("   at: %s\n", tracking_source_loc_display(bad_free.location, cwd))
            fmt.eprintln("   stack: Compile with `-debug` to get a back trace")
            if fi + 1 < len(bad_free_groups) { fmt.eprintln() }
            group_idx += 1
        }
        tracking_allocator_print_summary(
            t,
            process_memory,
            category,
            has_failures,
            live_alloc_size,
            live_alloc_count,
            total_alloc_size,
            total_alloc_count,
            peak_gap_label,
            peak_gap_bytes,
            total_events,
            leak_events,
            bad_free_events,
            total_groups,
        )
        return
    } else {
        Work :: struct {
            trace:  Trace_Const,
            result: []Line,
            err:    Lines_Error,
        }

        trace_count := len(leak_groups) + len(bad_free_groups)
        if trace_count == 0 { return }

        work := make([]Work, trace_count)
        defer delete(work)

        i: int
        for leak in leak_groups {
            work[i].trace = leak.key.backtrace
            i += 1
        }
        for bad_free in bad_free_groups {
            work[i].trace = bad_free.backtrace
            i += 1
        }

        when WASM && !intrinsics.has_target_feature("atomics") {
            for &entry in work {
                entry.result, entry.err = lines(entry.trace.trace[:entry.trace.len])
            }
        } else when ODIN_OS == .Darwin {
            for &entry in work {
                entry.result, entry.err = lines(entry.trace.trace[:entry.trace.len])
            }
        } else {
            extra_threads := max(0, min(back_tracking_core_count() - 1, trace_count - 1))
            extra_threads_done: sync.Wait_Group
            sync.wait_group_add(&extra_threads_done, extra_threads + 1)

            // Processes the slice of work given.
            thread_proc :: proc(work: ^[]Work, start: int, end: int, extra_threads_done: ^sync.Wait_Group) {
                defer sync.wait_group_done(extra_threads_done)

                for &entry in work[start:end] {
                    entry.result, entry.err = lines(entry.trace.trace[:entry.trace.len])
                }
            }

            thread_work := trace_count / extra_threads if extra_threads != 0 else trace_count
            worked: int
            for _ in 0 ..< extra_threads {
                thread.run_with_poly_data4(&work, worked, worked + thread_work, &extra_threads_done, thread_proc)
                worked += thread_work
            }

            thread_proc(&work, worked, len(work), &extra_threads_done)
            sync.wait_group_wait(&extra_threads_done)
        }

        work_leaks := work[:len(leak_groups)]
        work = work[len(leak_groups):]
        group_idx := 1

        for leak, li in leak_groups {
            if leak.count == 1 {
                fmt.eprintf("\n%v. %sleak%s %M\n", group_idx, REPORT_RED_BOLD, REPORT_RESET, leak.key.size)
            } else {
                fmt.eprintf(
                    "\n%v. %sleak%s %M x%v =%M\n",
                    group_idx,
                    REPORT_RED_BOLD,
                    REPORT_RESET,
                    leak.key.size,
                    leak.count,
                    leak.key.size * leak.count,
                )
            }
            fmt.eprintf("   at: %s\n", tracking_source_loc_display(leak.key.location, cwd))

            work_leak := work_leaks[li]
            defer lines_destroy(work_leak.result)
            tracking_print_stack(work_leak.result, work_leak.err, leak.key.location)
            group_idx += 1
        }

        for bad_free, fi in bad_free_groups {
            fmt.eprintf("\n%v. %sbad-free%s x%v\n", group_idx, REPORT_RED_BOLD, REPORT_RESET, bad_free.count)
            fmt.eprintf("   at: %s\n", tracking_source_loc_display(bad_free.location, cwd))

            work_free := work[fi]
            defer lines_destroy(work_free.result)
            tracking_print_stack(work_free.result, work_free.err, bad_free.location)
            group_idx += 1
        }
        tracking_allocator_print_summary(
            t,
            process_memory,
            category,
            has_failures,
            live_alloc_size,
            live_alloc_count,
            total_alloc_size,
            total_alloc_count,
            peak_gap_label,
            peak_gap_bytes,
            total_events,
            leak_events,
            bad_free_events,
            total_groups,
        )
    }
}
