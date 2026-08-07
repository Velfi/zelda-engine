#+no-instrumentation
package dio

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import virtual "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import back "zelda_engine:back"
import im "zelda_engine:imgui"

// This is the Adriatic port of catermujo/rt/dio's flame graph.  The graph
// stores completed frames locally, so the package does not depend on the
// monorepo runtime, path, thread, or file wrappers.

FLAME_AUTO_INSTRUMENT :: #config(FLAME_AUTO_INSTRUMENT, false)
FLAME_GRAPH :: #config(DIO_FLAME_GRAPH, true)
FLAME_GRAPH_FULL_SESSION :: #config(DIO_FLAME_GRAPH_FULL_SESSION, false)
FLAME_GRAPH_DEVELOPER_EXPORTS :: #config(DIO_FLAME_GRAPH_DEVELOPER_EXPORTS, ODIN_DEBUG)
FLAME_GRAPH_DUMP_PATH :: #config(FLAME_GRAPH_DUMP_PATH, "flame.graph")
FLAME_GRAPH_HISTORY_SAMPLES :: #config(DIO_FLAME_GRAPH_HISTORY_SAMPLES, 180)
FLAME_GRAPH_SCOPE_BUCKETS :: 6
FLAME_GRAPH_TICK_FREQUENCY_HZ :: u64(1_000_000_000)
FLAME_GRAPH_SLOT_CAPACITY_DEFAULT :: #config(DIO_FLAME_GRAPH_SLOT_CAPACITY_DEFAULT, 256)
FLAME_AUTO_DEPTH_CAP :: #config(FLAME_AUTO_DEPTH_CAP, 4096)
FLAME_AUTO_SLOT_CAP :: #config(FLAME_AUTO_SLOT_CAP, 262144)
FLAME_SESSION_RECORDING :: FLAME_AUTO_INSTRUMENT || FLAME_GRAPH_FULL_SESSION

FLAME_GRAPH_DEFAULT_HEIGHT :: f32(420)
FLAME_GRAPH_SLOT_HEIGHT :: f32(20)
FLAME_GRAPH_TIMELINE_HEIGHT :: f32(72)

#assert(FLAME_GRAPH_HISTORY_SAMPLES >= 1, "DIO_FLAME_GRAPH_HISTORY_SAMPLES must be >= 1")

Flame_Slot :: struct {
    name:      string,
    file_path: string,
    color:     u32,
    depth:     int,
    line:      int,
    start:     time.Tick,
    end:       time.Tick,
    active:    bool,
}

Flame_Frame_Scope :: struct {
    name:        string,
    color:       u32,
    duration_ms: f32,
}

Flame_Frame_History :: struct {
    frame_id:       u64,
    session_offset: i64,
    total_ms:       f32,
    fps:            f32,
    wait_ms:        f32,
    cpu_ms:         f32,
    gpu_ms:         f32,
    gpu_valid:      bool,
    other_ms:       f32,
    scope_count:    int,
    dropped_slots:  u64,
    scopes:         [FLAME_GRAPH_SCOPE_BUCKETS]Flame_Frame_Scope,
    slots:          [dynamic]Flame_Slot,
}

Flame_Range_Summary :: struct {
    count:       int,
    first_frame: u64,
    last_frame:  u64,
    worst_frame: u64,
    total_ms:    f32,
    average_ms:  f32,
    worst_ms:    f32,
    valid:       bool,
}

Flame_Graph_Session_Record :: struct {
    frame_id:      u64,
    total_ms:      f32,
    wait_ms:       f32,
    cpu_ms:        f32,
    gpu_ms:        f32,
    gpu_valid:     bool,
    slot_count:    u32,
    dropped_slots: u64,
}

Flame_Graph_Session_Slot :: struct {
    name_len:      u32,
    file_path_len: u32,
    color:         u32,
    depth:         int,
    line:          int,
    start:         time.Tick,
    end:           time.Tick,
    active:        bool,
}

FLAME_SESSION_STRING_CAP :: u32(4096)

Flame_Export_Summary :: struct {
    kind:               string,
    freq_hz:            u64,
    frame_count:        int,
    first_frame_id:     u64,
    last_frame_id:      u64,
    worst_frame_id:     u64,
    total_ms:           f64,
    avg_ms:             f64,
    worst_ms:           f64,
    total_wait_ms:      f64,
    avg_wait_ms:        f64,
    total_cpu_ms:       f64,
    avg_cpu_ms:         f64,
    total_gpu_ms:       f64,
    avg_gpu_ms:         f64,
    worst_gpu_ms:       f64,
    gpu_frame_count:    int,
    worst_gpu_frame_id: u64,
    dropped_slots:      u64,
}

Flame_Export_Job :: struct {
    scopes_path:    string,
    frames_path:    string,
    folded_path:    string,
    session_path:   string,
    session_offset: i64,
    summary:        Flame_Export_Summary,
    session_frames: int,
    progress_total: int,
    progress_done:  int,
    finished:       int,
    success:        int,
    error_message:  string,
}

Flame_Slot_Handle :: distinct int

Flame_Graph :: struct {
    slots:                 [dynamic]Flame_Slot,
    curr_depth:            int,
    current_frame:         Flame_Slot_Handle,
    history:               [FLAME_GRAPH_HISTORY_SAMPLES]Flame_Frame_History,
    history_head:          int,
    history_count:         int,
    next_frame_id:         u64,
    selected_frame_id:     u64,
    selected_range_a:      u64,
    selected_range_b:      u64,
    drag_anchor_id:        u64,
    dragging_timeline:     bool,
    paused:                bool,
    next_wait_ms:          f32,
    next_cpu_ms:           f32,
    next_gpu_ms:           f32,
    next_gpu_valid:        bool,
    current_dropped_slots: u64,
    session_file:          ^os.File,
    session_frame_buffer:  [dynamic]byte,
    session_path:          string,
    session_frame_count:   int,
    session_byte_count:    i64,
    session_summary:       Flame_Export_Summary,
    export_thread:         ^thread.Thread,
    export_job:            ^Flame_Export_Job,
    export_ok:             bool,
    export_message:        string,
}

@(thread_local)
_flame_graph_current: ^Flame_Graph

@(thread_local)
_flame_graph_auto_handles: [dynamic]Flame_Slot_Handle

@(thread_local)
_flame_graph_auto_overflow_depth: int

@(thread_local)
_flame_graph_auto_busy: bool

flame_tick_ms :: #force_inline proc(start, end: time.Tick) -> f64 {
    if flame_tick_value(end) <= flame_tick_value(start) do return 0
    return time.duration_seconds(time.tick_diff(start, end)) * 1000
}

flame_tick_value :: #force_inline proc(tick: time.Tick) -> u64 {
    duration := time.tick_diff(time.Tick{}, tick)
    if duration <= 0 do return 0
    return u64(duration)
}

flame_tick_min :: #force_inline proc(a, b: time.Tick) -> time.Tick {
    return a if flame_tick_value(a) <= flame_tick_value(b) else b
}

flame_tick_max :: #force_inline proc(a, b: time.Tick) -> time.Tick {
    return a if flame_tick_value(a) >= flame_tick_value(b) else b
}

flame_slot_ms :: #force_inline proc(slot: Flame_Slot) -> f64 {
    return flame_tick_ms(slot.start, slot.end)
}

flame_color :: #force_inline proc(name: string) -> u32 {
    colors: [3]im.Vec4 = {
        {120.0 / 255.0, 85.0 / 255.0, 150.0 / 255.0, 1},
        {216.0 / 255.0, 63.0 / 255.0, 71.0 / 255.0, 1},
        {207.0 / 255.0, 164.0 / 255.0, 57.0 / 255.0, 1},
    }
    index := int(hash.crc32(transmute([]u8)name) % u32(len(colors)))
    return im.ColorConvertFloat4ToU32(colors[index])
}

flame_slot_active :: #force_inline proc(slot: Flame_Slot) -> bool {
    return slot.active
}

flame_graph_history_at :: proc(graph: ^Flame_Graph, order: int) -> ^Flame_Frame_History {
    if graph == nil || order < 0 || order >= graph.history_count do return nil
    oldest := graph.history_head - graph.history_count
    if oldest < 0 do oldest += FLAME_GRAPH_HISTORY_SAMPLES
    return &graph.history[(oldest + order) % FLAME_GRAPH_HISTORY_SAMPLES]
}

flame_graph_latest :: proc(graph: ^Flame_Graph) -> ^Flame_Frame_History {
    if graph == nil || graph.history_count == 0 do return nil
    index := graph.history_head - 1
    if index < 0 do index += FLAME_GRAPH_HISTORY_SAMPLES
    return &graph.history[index]
}

flame_graph_find_frame :: proc(graph: ^Flame_Graph, frame_id: u64) -> ^Flame_Frame_History {
    if graph == nil || frame_id == 0 do return nil
    for order in 0 ..< graph.history_count {
        entry := flame_graph_history_at(graph, order)
        if entry != nil && entry.frame_id == frame_id do return entry
    }
    return nil
}

flame_graph_history_order_for_frame :: proc(graph: ^Flame_Graph, frame_id: u64) -> int {
    if graph == nil || frame_id == 0 do return -1
    for order in 0 ..< graph.history_count {
        entry := flame_graph_history_at(graph, order)
        if entry != nil && entry.frame_id == frame_id do return order
    }
    return -1
}

flame_graph_clear_range_selection :: proc(graph: ^Flame_Graph) {
    if graph == nil do return
    graph.selected_range_a = 0
    graph.selected_range_b = 0
}

flame_graph_has_range_selection :: proc(graph: ^Flame_Graph) -> bool {
    if graph == nil || graph.selected_range_a == 0 || graph.selected_range_b == 0 do return false
    if graph.selected_range_a == graph.selected_range_b do return false
    return(
        flame_graph_history_order_for_frame(graph, graph.selected_range_a) >= 0 &&
        flame_graph_history_order_for_frame(graph, graph.selected_range_b) >= 0 \
    )
}

flame_graph_select_single_frame :: proc(graph: ^Flame_Graph, frame_id: u64) {
    if graph == nil do return
    flame_graph_clear_range_selection(graph)
    latest := flame_graph_latest(graph)
    if frame_id == 0 || (latest != nil && frame_id == latest.frame_id) {
        graph.selected_frame_id = 0
    } else {
        graph.selected_frame_id = frame_id
    }
}

flame_graph_range_summary :: proc(graph: ^Flame_Graph, order_a, order_b: int) -> Flame_Range_Summary {
    if graph == nil || graph.history_count == 0 do return {}
    first_order := clamp(min(order_a, order_b), 0, graph.history_count - 1)
    last_order := clamp(max(order_a, order_b), 0, graph.history_count - 1)
    first_entry := flame_graph_history_at(graph, first_order)
    last_entry := flame_graph_history_at(graph, last_order)
    if first_entry == nil || last_entry == nil do return {}

    out: Flame_Range_Summary = {
        count       = last_order - first_order + 1,
        first_frame = first_entry.frame_id,
        last_frame  = last_entry.frame_id,
        valid       = true,
    }
    for order in first_order ..= last_order {
        entry := flame_graph_history_at(graph, order)
        if entry == nil do continue
        out.total_ms += entry.total_ms
        if out.worst_frame == 0 || entry.total_ms > out.worst_ms {
            out.worst_frame = entry.frame_id
            out.worst_ms = entry.total_ms
        }
    }
    out.average_ms = out.total_ms / f32(max(out.count, 1))
    return out
}

flame_graph_selected_range_summary :: proc(graph: ^Flame_Graph) -> Flame_Range_Summary {
    if !flame_graph_has_range_selection(graph) do return {}
    first_order := flame_graph_history_order_for_frame(graph, graph.selected_range_a)
    last_order := flame_graph_history_order_for_frame(graph, graph.selected_range_b)
    if first_order < 0 || last_order < 0 do return {}
    return flame_graph_range_summary(graph, first_order, last_order)
}

flame_graph_select_range_summary :: proc(graph: ^Flame_Graph, summary: Flame_Range_Summary) {
    if graph == nil || !summary.valid do return
    if summary.count <= 1 {
        flame_graph_select_single_frame(graph, summary.first_frame)
        return
    }
    graph.selected_range_a = summary.first_frame
    graph.selected_range_b = summary.last_frame
    graph.selected_frame_id = summary.worst_frame
}

flame_graph_selected :: proc(graph: ^Flame_Graph) -> ^Flame_Frame_History {
    if graph == nil do return nil
    if graph.selected_frame_id != 0 {
        if selected := flame_graph_find_frame(graph, graph.selected_frame_id); selected != nil {
            return selected
        }
        graph.selected_frame_id = 0
    }
    return flame_graph_latest(graph)
}

flame_graph_history_summary :: proc(graph: ^Flame_Graph) -> Flame_Range_Summary {
    if graph == nil || graph.history_count == 0 do return {}
    out: Flame_Range_Summary = {
        valid = true,
        count = graph.history_count,
    }
    for order in 0 ..< graph.history_count {
        entry := flame_graph_history_at(graph, order)
        if entry == nil do continue
        if order == 0 do out.first_frame = entry.frame_id
        out.last_frame = entry.frame_id
        out.total_ms += entry.total_ms
        if entry.total_ms > out.worst_ms {
            out.worst_ms = entry.total_ms
            out.worst_frame = entry.frame_id
        }
    }
    out.average_ms = out.total_ms / f32(max(out.count, 1))
    return out
}

flame_graph_export_summary :: proc(graph: ^Flame_Graph) -> Flame_Export_Summary {
    if graph == nil || graph.history_count <= 0 do return {}
    out: Flame_Export_Summary
    for order in 0 ..< graph.history_count {
        entry := flame_graph_history_at(graph, order)
        flame_graph_export_summary_append(&out, entry)
    }
    return out
}

flame_graph_export_summary_append :: proc(summary: ^Flame_Export_Summary, entry: ^Flame_Frame_History) {
    if summary == nil || entry == nil do return

    if summary.frame_count == 0 {
        summary.kind = "history"
        summary.freq_hz = FLAME_GRAPH_TICK_FREQUENCY_HZ
        summary.first_frame_id = entry.frame_id
    }
    summary.frame_count += 1
    summary.last_frame_id = entry.frame_id
    summary.total_ms += f64(entry.total_ms)
    summary.total_wait_ms += f64(entry.wait_ms)
    summary.total_cpu_ms += f64(entry.cpu_ms)
    summary.dropped_slots += entry.dropped_slots
    if summary.frame_count == 1 || entry.total_ms > f32(summary.worst_ms) {
        summary.worst_ms = f64(entry.total_ms)
        summary.worst_frame_id = entry.frame_id
    }
    if entry.gpu_valid {
        summary.gpu_frame_count += 1
        summary.total_gpu_ms += f64(entry.gpu_ms)
        if summary.gpu_frame_count == 1 || entry.gpu_ms > f32(summary.worst_gpu_ms) {
            summary.worst_gpu_ms = f64(entry.gpu_ms)
            summary.worst_gpu_frame_id = entry.frame_id
        }
    }
    count := f64(summary.frame_count)
    summary.avg_ms = summary.total_ms / count
    summary.avg_wait_ms = summary.total_wait_ms / count
    summary.avg_cpu_ms = summary.total_cpu_ms / count
    summary.avg_gpu_ms = summary.total_gpu_ms / f64(max(summary.gpu_frame_count, 1))
}

@(no_instrumentation)
flame_graph_begin :: proc(graph: ^Flame_Graph, name: string, loc := #caller_location) -> Flame_Slot_Handle {
    when !FLAME_GRAPH do return Flame_Slot_Handle(-1)
    if graph == nil do return Flame_Slot_Handle(-1)
    if len(graph.slots) >= FLAME_AUTO_SLOT_CAP {
        graph.current_dropped_slots += 1
        return Flame_Slot_Handle(-1)
    }
    append(&graph.slots, Flame_Slot {
        name      = name if len(name) > 0 else "?",
        file_path = loc.file_path,
        color     = flame_color(name),
        depth     = graph.curr_depth,
        line      = int(loc.line),
        start     = time.tick_now(),
        active    = true,
    })
    graph.curr_depth += 1
    return Flame_Slot_Handle(len(graph.slots) - 1)
}

@(no_instrumentation)
flame_graph_end :: proc(graph: ^Flame_Graph, handle: Flame_Slot_Handle) -> bool {
    when !FLAME_GRAPH do return false
    if graph == nil || graph.curr_depth <= 0 do return false
    index := int(handle)
    if index < 0 || index >= len(graph.slots) do return false
    slot := &graph.slots[index]
    if !flame_slot_active(slot^) || slot.depth + 1 != graph.curr_depth do return false
    slot.end = time.tick_now()
    slot.active = false
    graph.curr_depth -= 1
    return true
}

@(no_instrumentation)
flame_graph_finish_open_slots :: proc(graph: ^Flame_Graph) {
    if graph == nil || graph.curr_depth == 0 do return
    now := time.tick_now()
    for &slot in graph.slots {
        if flame_slot_active(slot) {
            slot.end = now
            slot.active = false
        }
    }
    graph.curr_depth = 0
}

@(no_instrumentation)
flame_graph_set_current :: proc(graph: ^Flame_Graph) {
    when !FLAME_GRAPH {
        _flame_graph_current = nil
        clear(&_flame_graph_auto_handles)
        _flame_graph_auto_overflow_depth = 0
        return
    }

    previous_busy := _flame_graph_auto_busy
    _flame_graph_auto_busy = true
    defer _flame_graph_auto_busy = previous_busy

    if graph == nil && _flame_graph_current != nil {
        for len(_flame_graph_auto_handles) > 0 {
            index := len(_flame_graph_auto_handles) - 1
            handle := _flame_graph_auto_handles[index]
            resize(&_flame_graph_auto_handles, index)
            _ = flame_graph_end(_flame_graph_current, handle)
        }
        _flame_graph_auto_overflow_depth = 0
    }

    _flame_graph_current = graph
    clear(&_flame_graph_auto_handles)
    _flame_graph_auto_overflow_depth = 0
    if graph != nil {
        if cap(_flame_graph_auto_handles) < FLAME_AUTO_DEPTH_CAP {
            reserve(&_flame_graph_auto_handles, FLAME_AUTO_DEPTH_CAP)
        }
        when FLAME_AUTO_INSTRUMENT {
            // Instrumentation can fire while the allocator lock is held.
            // Reserve the hard cap before enabling callbacks so append never re-enters it.
            if cap(graph.slots) < FLAME_AUTO_SLOT_CAP {
                reserve(&graph.slots, FLAME_AUTO_SLOT_CAP)
            }
        } else {
            if cap(graph.slots) < FLAME_GRAPH_SLOT_CAPACITY_DEFAULT {
                reserve(&graph.slots, FLAME_GRAPH_SLOT_CAPACITY_DEFAULT)
            }
        }
    }
}

flame_graph_current :: #force_inline proc() -> ^Flame_Graph {
    return _flame_graph_current
}

@(no_instrumentation)
flame_graph_begin_frame :: proc(graph: ^Flame_Graph) {
    when !FLAME_GRAPH do return
    if graph == nil do return
    flame_graph_set_current(nil)
    clear(&graph.slots)
    graph.curr_depth = 0
    graph.next_wait_ms = 0
    graph.next_cpu_ms = 0
    graph.next_gpu_ms = 0
    graph.next_gpu_valid = false
    graph.current_dropped_slots = 0
    flame_graph_set_current(graph)
    graph.current_frame = flame_graph_begin(graph, "frame")
}

flame_graph_set_frame_metrics :: proc(graph: ^Flame_Graph, wait_ms, cpu_ms, gpu_ms: f32, gpu_valid := false) {
    when !FLAME_GRAPH do return
    if graph == nil do return
    graph.next_wait_ms = max(wait_ms, f32(0))
    graph.next_cpu_ms = max(cpu_ms, f32(0))
    graph.next_gpu_ms = max(gpu_ms, f32(0))
    graph.next_gpu_valid = gpu_valid
}

@(no_instrumentation)
flame_graph_session_close :: proc(graph: ^Flame_Graph, remove_file := false) {
    if graph == nil do return
    if graph.session_file != nil {
        _ = os.close(graph.session_file)
        graph.session_file = nil
    }
    if remove_file && len(graph.session_path) > 0 {
        _ = os.remove(graph.session_path)
    }
    delete(graph.session_path)
    graph.session_path = ""
    graph.session_frame_count = 0
    graph.session_byte_count = 0
    graph.session_summary = {}
}

@(no_instrumentation)
flame_graph_session_ensure_open :: proc(graph: ^Flame_Graph) -> bool {
    if graph == nil do return false
    if graph.session_file != nil do return true

    path := flame_graph_source_path(FLAME_GRAPH_DUMP_PATH, ".session.bin")
    defer delete(path)
    parent := os.dir(path)
    if parent != "." && parent != "" {
        if err := os.make_directory_all(parent); err != nil && err != .Exist do return false
    }

    file, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
    if err != nil do return false
    owned_path, path_err := strings.clone(path)
    if path_err != nil {
        _ = os.close(file)
        return false
    }
    graph.session_file = file
    graph.session_path = owned_path
    return true
}

@(no_instrumentation)
flame_graph_session_write_bytes :: proc(file: ^os.File, bytes: []byte) -> bool {
    if file == nil do return false
    if len(bytes) == 0 do return true
    written, err := os.write(file, bytes)
    return err == nil && written == len(bytes)
}

@(no_instrumentation)
flame_graph_session_read_string :: proc(file: ^os.File, length: u32, allocator: mem.Allocator) -> (string, bool) {
    if file == nil || length > FLAME_SESSION_STRING_CAP do return "", false
    bytes := make([]byte, int(length), allocator)
    if !flame_graph_session_read_bytes(file, bytes) do return "", false
    return string(bytes), true
}

@(no_instrumentation)
flame_graph_session_read_bytes :: proc(file: ^os.File, bytes: []byte) -> bool {
    if file == nil do return false
    if len(bytes) == 0 do return true
    read_count, err := os.read_full(file, bytes)
    return err == nil && read_count == len(bytes)
}

@(no_instrumentation)
flame_graph_session_record :: proc(graph: ^Flame_Graph, entry: ^Flame_Frame_History) {
    when !FLAME_SESSION_RECORDING do return
    if graph == nil || entry == nil || len(entry.slots) == 0 do return

    for slot in entry.slots {
        if len(slot.name) > int(FLAME_SESSION_STRING_CAP) || len(slot.file_path) > int(FLAME_SESSION_STRING_CAP) {
            flame_graph_session_close(graph, true)
            return
        }
    }
    if !flame_graph_session_ensure_open(graph) do return

    clear(&graph.session_frame_buffer)
    record := Flame_Graph_Session_Record {
        frame_id      = entry.frame_id,
        total_ms      = entry.total_ms,
        wait_ms       = entry.wait_ms,
        cpu_ms        = entry.cpu_ms,
        gpu_ms        = entry.gpu_ms,
        gpu_valid     = entry.gpu_valid,
        slot_count    = u32(len(entry.slots)),
        dropped_slots = entry.dropped_slots,
    }
    record_array := [1]Flame_Graph_Session_Record{record}
    record_bytes := slice.reinterpret([]byte, record_array[:])
    append(&graph.session_frame_buffer, ..record_bytes)
    for slot in entry.slots {
        session_slot := Flame_Graph_Session_Slot {
            name_len      = u32(len(slot.name)),
            file_path_len = u32(len(slot.file_path)),
            color         = slot.color,
            depth         = slot.depth,
            line          = slot.line,
            start         = slot.start,
            end           = slot.end,
            active        = slot.active,
        }
        session_slot_array := [1]Flame_Graph_Session_Slot{session_slot}
        session_slot_bytes := slice.reinterpret([]byte, session_slot_array[:])
        append(&graph.session_frame_buffer, ..session_slot_bytes)
        append(&graph.session_frame_buffer, ..transmute([]byte)slot.name)
        append(&graph.session_frame_buffer, ..transmute([]byte)slot.file_path)
    }
    if !flame_graph_session_write_bytes(graph.session_file, graph.session_frame_buffer[:]) {
        flame_graph_session_close(graph, true)
        return
    }
    entry.session_offset = graph.session_byte_count
    graph.session_byte_count += i64(len(graph.session_frame_buffer))
    graph.session_frame_count += 1
    flame_graph_export_summary_append(&graph.session_summary, entry)
}

@(no_instrumentation)
flame_graph_refresh_history_entry :: proc(entry: ^Flame_Frame_History) {
    if entry == nil do return

    entry.fps = 1000 / max(entry.total_ms, f32(0.001))
    entry.other_ms = max(entry.total_ms, f32(0))
    entry.scope_count = 0
    for &scope in entry.scopes {
        scope = {}
    }

    target_depth := 0
    for slot in entry.slots {
        if slot.depth == 1 {
            target_depth = 1
            break
        }
    }

    scope_sums := make([dynamic]Flame_Frame_Scope, 0, len(entry.slots), context.temp_allocator)
    defer delete(scope_sums)
    for slot in entry.slots {
        if slot.depth != target_depth do continue
        duration_ms := f32(flame_slot_ms(slot))
        if duration_ms <= 0 do continue

        found := -1
        for scope, index in scope_sums {
            if scope.name == slot.name {
                found = index
                break
            }
        }
        if found >= 0 {
            scope_sums[found].duration_ms += duration_ms
        } else {
            append(&scope_sums, Flame_Frame_Scope{name = slot.name, color = slot.color, duration_ms = duration_ms})
        }
    }

    selected_ms: f32
    for _ in 0 ..< FLAME_GRAPH_SCOPE_BUCKETS {
        best := -1
        best_ms: f32 = -1
        for scope, index in scope_sums {
            if scope.duration_ms > best_ms {
                best = index
                best_ms = scope.duration_ms
            }
        }
        if best < 0 || scope_sums[best].duration_ms <= 0 do break
        entry.scopes[entry.scope_count] = scope_sums[best]
        selected_ms += scope_sums[best].duration_ms
        entry.scope_count += 1
        scope_sums[best].duration_ms = -1
    }
    entry.other_ms = max(entry.total_ms - selected_ms, f32(0))
}

@(no_instrumentation)
flame_graph_end_frame :: proc(graph: ^Flame_Graph) {
    when !FLAME_GRAPH do return
    if graph == nil do return
    flame_graph_set_current(nil)
    _ = flame_graph_end(graph, graph.current_frame)
    flame_graph_finish_open_slots(graph)

    if len(graph.slots) > 0 && !graph.paused {
        entry := &graph.history[graph.history_head]
        if cap(entry.slots) < len(graph.slots) {
            delete(entry.slots)
            entry.slots = make([dynamic]Flame_Slot, 0, len(graph.slots))
        }
        resize(&entry.slots, len(graph.slots))
        copy(entry.slots[:], graph.slots[:])
        entry.frame_id = graph.next_frame_id
        graph.next_frame_id += 1

        first := entry.slots[0].start
        last := entry.slots[0].end
        for slot in entry.slots[1:] {
            first = flame_tick_min(first, slot.start)
            last = flame_tick_max(last, slot.end)
        }
        entry.total_ms = f32(flame_tick_ms(first, last))
        entry.wait_ms = min(graph.next_wait_ms, entry.total_ms)
        entry.cpu_ms = graph.next_cpu_ms
        if entry.cpu_ms <= 0 do entry.cpu_ms = max(entry.total_ms - entry.wait_ms, f32(0))
        entry.gpu_ms = graph.next_gpu_ms
        entry.gpu_valid = graph.next_gpu_valid
        entry.dropped_slots = graph.current_dropped_slots
        entry.session_offset = -1
        flame_graph_refresh_history_entry(entry)
        flame_graph_session_record(graph, entry)
        graph.history_head = (graph.history_head + 1) % FLAME_GRAPH_HISTORY_SAMPLES
        graph.history_count = min(graph.history_count + 1, FLAME_GRAPH_HISTORY_SAMPLES)
    }
    graph.current_frame = Flame_Slot_Handle(-1)
    clear(&graph.slots)
    graph.curr_depth = 0
}

@(no_instrumentation)
flame_graph_reset :: proc(graph: ^Flame_Graph) {
    when !FLAME_GRAPH do return
    if graph == nil do return
    flame_graph_export_stop(graph)
    flame_graph_set_current(nil)
    clear(&graph.slots)
    graph.curr_depth = 0
    graph.history_count = 0
    graph.history_head = 0
    graph.selected_frame_id = 0
    flame_graph_clear_range_selection(graph)
    graph.drag_anchor_id = 0
    graph.dragging_timeline = false
    for &entry in graph.history {
        clear(&entry.slots)
    }
    flame_graph_session_close(graph, true)
}

@(no_instrumentation)
flame_graph_destroy :: proc(graph: ^Flame_Graph) {
    if graph == nil do return

    flame_graph_export_stop(graph)
    if _flame_graph_current == graph do flame_graph_end_frame(graph)
    when FLAME_SESSION_RECORDING {
        if graph.session_frame_count > 0 {
            session_exported := flame_graph_export_begin(graph)
            if session_exported {
                flame_graph_export_stop(graph)
                session_exported = graph.export_ok
            }
            if !session_exported {
                last_order := graph.history_count - 1
                _ = flame_graph_write_source_range(graph, FLAME_GRAPH_DUMP_PATH, 0, last_order)
                _ = flame_graph_write_source_folded(graph, FLAME_GRAPH_DUMP_PATH, 0, last_order)
            }
        }
    } else {
        _ = flame_graph_write_exports(graph)
    }

    flame_graph_session_close(graph, true)
    if _flame_graph_current == graph {
        flame_graph_set_current(nil)
    }
    delete(_flame_graph_auto_handles)
    delete(graph.export_message)
    delete(graph.slots)
    delete(graph.session_frame_buffer)
    for &entry in graph.history {
        delete(entry.slots)
    }
    graph^ = {}
}

flame_graph_export_base :: proc(path: string = FLAME_GRAPH_DUMP_PATH) -> string {
    if len(strings.trim_space(path)) > 0 do return path
    return "flame.graph"
}

flame_graph_export_path :: proc(path, suffix: string) -> string {
    return fmt.aprintf("%s%s", flame_graph_export_base(path), suffix)
}

flame_graph_selection_export_path :: proc(graph: ^Flame_Graph, path, suffix: string) -> string {
    summary := flame_graph_selected_range_summary(graph)
    if !summary.valid do return ""
    return fmt.aprintf(
        "%s.selection-%d-%d%s",
        flame_graph_export_base(path),
        summary.first_frame,
        summary.last_frame,
        suffix,
    )
}

flame_graph_set_export_status :: proc(graph: ^Flame_Graph, ok: bool, path: string) {
    delete(graph.export_message)
    graph.export_ok = ok
    graph.export_message = fmt.aprintf("%s", path)
}

flame_json_string :: proc(builder: ^strings.Builder, value: string) {
    strings.write_byte(builder, '"')
    for ch in transmute([]u8)value {
        switch ch {
        case '"':
            strings.write_string(builder, "\\\"")
        case '\\':
            strings.write_string(builder, "\\\\")
        case '\n':
            strings.write_string(builder, "\\n")
        case '\r':
            strings.write_string(builder, "\\r")
        case '\t':
            strings.write_string(builder, "\\t")
        case:
            strings.write_byte(builder, ch)
        }
    }
    strings.write_byte(builder, '"')
}

flame_write_json_slot :: proc(builder: ^strings.Builder, slot: Flame_Slot, frame_start: time.Tick) {
    fmt.sbprintf(builder, "{{\"name\":")
    flame_json_string(builder, slot.name)
    strings.write_string(builder, ",\"file_path\":")
    flame_json_string(builder, slot.file_path)
    fmt.sbprintf(
        builder,
        ",\"depth\":%d,\"line\":%d,\"start_ticks\":%d,\"end_ticks\":%d,\"start_ms\":%.6f,\"duration_ms\":%.6f}}",
        slot.depth,
        slot.line,
        flame_tick_value(slot.start),
        flame_tick_value(slot.end),
        flame_tick_ms(frame_start, slot.start),
        flame_slot_ms(slot),
    )
}

flame_graph_write_json_range :: proc(graph: ^Flame_Graph, first_order, last_order: int, resolved: string) -> bool {
    when !FLAME_GRAPH do return false
    if graph == nil do return false
    builder := strings.builder_make_len_cap(0, 16 * 1024)
    defer delete(builder.buf)
    strings.write_string(&builder, "{\"frames\":[")
    wrote_frame := false
    if graph.history_count > 0 {
        start_order := clamp(first_order, 0, graph.history_count - 1)
        end_order := clamp(last_order, 0, graph.history_count - 1)
        if start_order <= end_order {
            for order in start_order ..= end_order {
                entry := flame_graph_history_at(graph, order)
                if entry == nil || len(entry.slots) == 0 do continue
                if wrote_frame do strings.write_byte(&builder, ',')
                wrote_frame = true
                first := entry.slots[0].start
                last := entry.slots[0].end
                for slot in entry.slots[1:] {
                    first = flame_tick_min(first, slot.start)
                    last = flame_tick_max(last, slot.end)
                }
                fmt.sbprintf(
                    &builder,
                    "{{\"frame_id\":%d,\"total_ms\":%.6f,\"wait_ms\":%.6f,\"cpu_ms\":%.6f,\"gpu_ms\":%.6f,\"gpu_valid\":%s,\"slots\":[",
                    entry.frame_id,
                    entry.total_ms,
                    entry.wait_ms,
                    entry.cpu_ms,
                    entry.gpu_ms,
                    "true" if entry.gpu_valid else "false",
                )
                for slot, slot_index in entry.slots {
                    if slot_index > 0 do strings.write_byte(&builder, ',')
                    flame_write_json_slot(&builder, slot, first)
                }
                fmt.sbprintf(&builder, "]}")
            }
        }
    }
    strings.write_string(&builder, "]}")
    ok := os.write_entire_file(resolved, transmute([]byte)strings.to_string(builder)) == nil
    flame_graph_set_export_status(graph, ok, resolved)
    return ok
}

flame_graph_write_json :: proc(graph: ^Flame_Graph, path: string = FLAME_GRAPH_DUMP_PATH) -> bool {
    if graph == nil do return false
    resolved := flame_graph_export_path(path, ".json")
    defer delete(resolved)
    return flame_graph_write_json_range(graph, 0, graph.history_count - 1, resolved)
}

flame_graph_write_selection_json :: proc(graph: ^Flame_Graph, path: string = FLAME_GRAPH_DUMP_PATH) -> bool {
    if graph == nil do return false
    summary := flame_graph_selected_range_summary(graph)
    if !summary.valid do return false
    first_order := flame_graph_history_order_for_frame(graph, summary.first_frame)
    last_order := flame_graph_history_order_for_frame(graph, summary.last_frame)
    resolved := flame_graph_selection_export_path(graph, path, ".json")
    defer delete(resolved)
    return flame_graph_write_json_range(graph, first_order, last_order, resolved)
}

flame_write_folded_name :: proc(builder: ^strings.Builder, name: string) {
    if len(name) == 0 {
        strings.write_byte(builder, '?')
        return
    }
    for ch in transmute([]u8)name {
        strings.write_byte(builder, ':' if ch == ';' else (' ' if ch == '\n' || ch == '\r' else ch))
    }
}

flame_graph_write_folded_range :: proc(graph: ^Flame_Graph, first_order, last_order: int, resolved: string) -> bool {
    when !FLAME_GRAPH do return false
    if graph == nil || graph.history_count == 0 do return false
    builder := strings.builder_make_len_cap(0, 16 * 1024)
    defer delete(builder.buf)

    start_order := clamp(first_order, 0, graph.history_count - 1)
    end_order := clamp(last_order, 0, graph.history_count - 1)
    if start_order > end_order do return false
    for order in start_order ..= end_order {
        entry := flame_graph_history_at(graph, order)
        if entry == nil do continue
        parent: [dynamic]int
        child_ticks: [dynamic]u64
        stack: [dynamic]int
        resize(&parent, len(entry.slots))
        resize(&child_ticks, len(entry.slots))
        for slot, index in entry.slots {
            parent[index] = -1
            for len(stack) > 0 {
                top := stack[len(stack) - 1]
                parent_slot := entry.slots[top]
                if slot.depth > parent_slot.depth &&
                   flame_tick_value(slot.start) >= flame_tick_value(parent_slot.start) &&
                   flame_tick_value(slot.end) <= flame_tick_value(parent_slot.end) {
                    break
                }
                resize(&stack, len(stack) - 1)
            }
            if len(stack) > 0 {
                parent[index] = stack[len(stack) - 1]
                child_ticks[parent[index]] += flame_tick_value(slot.end) - flame_tick_value(slot.start)
            }
            append(&stack, index)
        }
        path_stack: [dynamic]int
        for slot, index in entry.slots {
            total_ticks := flame_tick_value(slot.end) - flame_tick_value(slot.start)
            if total_ticks == 0 do continue
            self_ticks := total_ticks
            if child_ticks[index] < self_ticks do self_ticks -= child_ticks[index]
            if self_ticks == 0 do continue
            clear(&path_stack)
            cursor := index
            for cursor >= 0 {
                append(&path_stack, cursor)
                cursor = parent[cursor]
            }
            for path_index := len(path_stack) - 1; path_index >= 0; path_index -= 1 {
                if path_index < len(path_stack) - 1 do strings.write_byte(&builder, ';')
                flame_write_folded_name(&builder, entry.slots[path_stack[path_index]].name)
            }
            fmt.sbprintf(&builder, " %d\n", self_ticks)
        }
        delete(parent)
        delete(child_ticks)
        delete(stack)
        delete(path_stack)
    }
    ok := os.write_entire_file(resolved, transmute([]byte)strings.to_string(builder)) == nil
    flame_graph_set_export_status(graph, ok, resolved)
    return ok
}

flame_graph_write_folded :: proc(graph: ^Flame_Graph, path: string = FLAME_GRAPH_DUMP_PATH) -> bool {
    if graph == nil do return false
    resolved := flame_graph_export_path(path, ".folded")
    defer delete(resolved)
    return flame_graph_write_folded_range(graph, 0, graph.history_count - 1, resolved)
}

flame_graph_write_selection_folded :: proc(graph: ^Flame_Graph, path: string = FLAME_GRAPH_DUMP_PATH) -> bool {
    if graph == nil do return false
    summary := flame_graph_selected_range_summary(graph)
    if !summary.valid do return false
    first_order := flame_graph_history_order_for_frame(graph, summary.first_frame)
    last_order := flame_graph_history_order_for_frame(graph, summary.last_frame)
    resolved := flame_graph_selection_export_path(graph, path, ".folded")
    defer delete(resolved)
    return flame_graph_write_folded_range(graph, first_order, last_order, resolved)
}

flame_graph_source_stem :: proc(path: string = FLAME_GRAPH_DUMP_PATH) -> string {
    base := flame_graph_export_base(path)
    if strings.has_suffix(base, ".graph") {
        return base[:len(base) - len(".graph")]
    }
    return base
}

flame_graph_source_path :: proc(path, suffix: string) -> string {
    return fmt.aprintf("%s%s", flame_graph_source_stem(path), suffix)
}

flame_graph_write_source_file :: proc(path, payload: string) -> bool {
    parent := os.dir(path)
    if parent != "." && parent != "" {
        if err := os.make_directory_all(parent); err != nil && err != .Exist do return false
    }

    temporary := fmt.aprintf("%s.tmp", path)
    defer delete(temporary)
    if os.write_entire_file(temporary, transmute([]byte)payload) != nil do return false
    _ = os.remove(path)
    return os.rename(temporary, path) == nil
}

flame_graph_write_source_header :: proc(
    builder: ^strings.Builder,
    graph: ^Flame_Graph,
    first_order, last_order: int,
    kind: string,
) -> bool {
    summary := flame_graph_range_summary(graph, first_order, last_order)
    if !summary.valid do return false

    total_wait_ms: f64
    total_cpu_ms: f64
    total_gpu_ms: f64
    worst_gpu_ms: f64
    gpu_frame_count: int
    worst_gpu_frame_id: u64
    dropped_slots: u64
    for order in first_order ..= last_order {
        entry := flame_graph_history_at(graph, order)
        if entry == nil do continue
        total_wait_ms += f64(entry.wait_ms)
        total_cpu_ms += f64(entry.cpu_ms)
        dropped_slots += entry.dropped_slots
        if entry.gpu_valid {
            gpu_frame_count += 1
            total_gpu_ms += f64(entry.gpu_ms)
            if entry.gpu_ms > f32(worst_gpu_ms) {
                worst_gpu_ms = f64(entry.gpu_ms)
                worst_gpu_frame_id = entry.frame_id
            }
        }
    }
    count := max(summary.count, 1)
    avg_gpu_ms := total_gpu_ms / f64(max(gpu_frame_count, 1))
    fmt.sbprintf(
        builder,
        "{{\"kind\":\"%s_header\",\"freq_hz\":%d,\"frame_count\":%d,\"first_frame_id\":%d,\"last_frame_id\":%d,\"worst_frame_id\":%d,\"total_ms\":%.6f,\"avg_ms\":%.6f,\"total_wait_ms\":%.6f,\"avg_wait_ms\":%.6f,\"total_cpu_ms\":%.6f,\"avg_cpu_ms\":%.6f,\"total_gpu_ms\":%.6f,\"avg_gpu_ms\":%.6f,\"worst_gpu_ms\":%.6f,\"gpu_frame_count\":%d,\"worst_gpu_frame_id\":%d,\"dropped_slots\":%d}}\n",
        kind,
        FLAME_GRAPH_TICK_FREQUENCY_HZ,
        summary.count,
        summary.first_frame,
        summary.last_frame,
        summary.worst_frame,
        summary.total_ms,
        summary.total_ms / f32(count),
        total_wait_ms,
        total_wait_ms / f64(count),
        total_cpu_ms,
        total_cpu_ms / f64(count),
        total_gpu_ms,
        avg_gpu_ms,
        worst_gpu_ms,
        gpu_frame_count,
        worst_gpu_frame_id,
        dropped_slots,
    )
    return true
}

flame_graph_write_source_frame :: proc(builder: ^strings.Builder, entry: ^Flame_Frame_History) -> bool {
    if entry == nil || len(entry.slots) == 0 do return false

    first := entry.slots[0].start
    last := entry.slots[0].end
    for slot in entry.slots[1:] {
        first = flame_tick_min(first, slot.start)
        last = flame_tick_max(last, slot.end)
    }
    fmt.sbprintf(
        builder,
        "{{\"kind\":\"frame\",\"frame_id\":%d,\"start_ticks\":%d,\"end_ticks\":%d,\"total_ms\":%.6f,\"wait_ms\":%.6f,\"cpu_ms\":%.6f,\"gpu_ms\":%.6f,\"gpu_valid\":%s,\"dropped_slots\":%d,\"slots\":[",
        entry.frame_id,
        flame_tick_value(first),
        flame_tick_value(last),
        entry.total_ms,
        entry.wait_ms,
        entry.cpu_ms,
        entry.gpu_ms,
        "true" if entry.gpu_valid else "false",
        entry.dropped_slots,
    )
    for slot, index in entry.slots {
        if index > 0 do strings.write_byte(builder, ',')
        flame_write_json_slot(builder, slot, first)
    }
    strings.write_string(builder, "]}\n")
    return true
}

flame_graph_write_source_scopes :: proc(builder: ^strings.Builder, entry: ^Flame_Frame_History) -> bool {
    if entry == nil do return false
    fmt.sbprintf(
        builder,
        "{{\"kind\":\"frame_scopes\",\"frame_id\":%d,\"total_ms\":%.6f,\"wait_ms\":%.6f,\"cpu_ms\":%.6f,\"gpu_ms\":%.6f,\"gpu_valid\":%s,\"other_ms\":%.6f,\"scope_count\":%d,\"dropped_slots\":%d,\"scopes\":[",
        entry.frame_id,
        entry.total_ms,
        entry.wait_ms,
        entry.cpu_ms,
        entry.gpu_ms,
        "true" if entry.gpu_valid else "false",
        entry.other_ms,
        entry.scope_count,
        entry.dropped_slots,
    )
    for index in 0 ..< entry.scope_count {
        if index > 0 do strings.write_byte(builder, ',')
        scope := entry.scopes[index]
        fmt.sbprintf(builder, "{{\"name\":")
        flame_json_string(builder, scope.name)
        fmt.sbprintf(builder, ",\"color\":%d,\"duration_ms\":%.6f}}", scope.color, scope.duration_ms)
    }
    strings.write_string(builder, "]}\n")
    return true
}

flame_graph_write_export_summary_header :: proc(builder: ^strings.Builder, summary: Flame_Export_Summary) -> bool {
    if builder == nil || summary.frame_count <= 0 do return false
    fmt.sbprintf(
        builder,
        "{{\"kind\":\"%s_header\",\"freq_hz\":%d,\"frame_count\":%d,\"first_frame_id\":%d,\"last_frame_id\":%d,\"worst_frame_id\":%d,\"total_ms\":%.6f,\"avg_ms\":%.6f,\"total_wait_ms\":%.6f,\"avg_wait_ms\":%.6f,\"total_cpu_ms\":%.6f,\"avg_cpu_ms\":%.6f,\"total_gpu_ms\":%.6f,\"avg_gpu_ms\":%.6f,\"worst_gpu_ms\":%.6f,\"gpu_frame_count\":%d,\"worst_gpu_frame_id\":%d,\"dropped_slots\":%d}}\n",
        summary.kind,
        summary.freq_hz,
        summary.frame_count,
        summary.first_frame_id,
        summary.last_frame_id,
        summary.worst_frame_id,
        summary.total_ms,
        summary.avg_ms,
        summary.total_wait_ms,
        summary.avg_wait_ms,
        summary.total_cpu_ms,
        summary.avg_cpu_ms,
        summary.total_gpu_ms,
        summary.avg_gpu_ms,
        summary.worst_gpu_ms,
        summary.gpu_frame_count,
        summary.worst_gpu_frame_id,
        summary.dropped_slots,
    )
    return true
}

flame_graph_write_folded_slots :: proc(builder: ^strings.Builder, slots: []Flame_Slot) {
    if builder == nil || len(slots) == 0 do return

    parent: [dynamic]int
    child_ticks: [dynamic]u64
    stack: [dynamic]int
    resize(&parent, len(slots))
    resize(&child_ticks, len(slots))
    for slot, index in slots {
        parent[index] = -1
        for len(stack) > 0 {
            top := stack[len(stack) - 1]
            parent_slot := slots[top]
            if slot.depth > parent_slot.depth &&
               flame_tick_value(slot.start) >= flame_tick_value(parent_slot.start) &&
               flame_tick_value(slot.end) <= flame_tick_value(parent_slot.end) {
                break
            }
            resize(&stack, len(stack) - 1)
        }
        if len(stack) > 0 {
            parent[index] = stack[len(stack) - 1]
            child_ticks[parent[index]] += flame_tick_value(slot.end) - flame_tick_value(slot.start)
        }
        append(&stack, index)
    }

    path_stack: [dynamic]int
    for slot, index in slots {
        total_ticks := flame_tick_value(slot.end) - flame_tick_value(slot.start)
        if total_ticks == 0 do continue
        self_ticks := total_ticks
        if child_ticks[index] < self_ticks do self_ticks -= child_ticks[index]
        if self_ticks == 0 do continue

        clear(&path_stack)
        cursor := index
        for cursor >= 0 {
            append(&path_stack, cursor)
            cursor = parent[cursor]
        }
        for path_index := len(path_stack) - 1; path_index >= 0; path_index -= 1 {
            if path_index < len(path_stack) - 1 do strings.write_byte(builder, ';')
            flame_write_folded_name(builder, slots[path_stack[path_index]].name)
        }
        fmt.sbprintf(builder, " %d\n", self_ticks)
    }
    delete(parent)
    delete(child_ticks)
    delete(stack)
    delete(path_stack)
}

flame_graph_export_file_write :: proc(file: ^os.File, value: string) -> bool {
    if file == nil do return false
    written, err := os.write_string(file, value)
    return err == nil && written == len(value)
}

flame_graph_export_job_error :: proc(job: ^Flame_Export_Job, message: string) {
    if job == nil do return
    delete(job.error_message)
    job.error_message = fmt.aprintf("%s", message)
}

flame_graph_export_job_destroy :: proc(job: ^Flame_Export_Job) {
    if job == nil do return
    delete(job.scopes_path)
    delete(job.frames_path)
    delete(job.folded_path)
    delete(job.error_message)
    free(job)
}

flame_graph_export_stream :: proc(job: ^Flame_Export_Job) -> bool {
    if job == nil || len(job.session_path) == 0 || job.session_frames <= 0 do return false

    arena: virtual.Arena
    if virtual.arena_init_growing(&arena, mem.Megabyte) != nil {
        flame_graph_export_job_error(job, "failed to initialize flame export arena")
        return false
    }
    defer virtual.arena_destroy(&arena)
    arena_allocator := virtual.arena_allocator(&arena)

    session, err := os.open(job.session_path, {.Read}, os.Permissions_Default_File)
    if err != nil {
        flame_graph_export_job_error(job, "failed to open flame session")
        return false
    }
    defer os.close(session)
    offset, seek_err := os.seek(session, job.session_offset, .Start)
    if seek_err != nil || offset != job.session_offset {
        flame_graph_export_job_error(job, "failed to seek retained flame history")
        return false
    }

    scopes_temp := fmt.aprintf("%s.tmp", job.scopes_path)
    frames_temp := fmt.aprintf("%s.tmp", job.frames_path)
    folded_temp := fmt.aprintf("%s.tmp", job.folded_path)
    defer delete(scopes_temp)
    defer delete(frames_temp)
    defer delete(folded_temp)
    _ = os.remove(scopes_temp)
    _ = os.remove(frames_temp)
    _ = os.remove(folded_temp)

    scopes_file, scopes_err := os.open(scopes_temp, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
    if scopes_err != nil {
        flame_graph_export_job_error(job, "failed to create flame scopes export")
        return false
    }
    defer if scopes_file != nil { os.close(scopes_file) }
    frames_file, frames_err := os.open(frames_temp, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
    if frames_err != nil {
        flame_graph_export_job_error(job, "failed to create flame frames export")
        return false
    }
    defer if frames_file != nil { os.close(frames_file) }
    folded_file, folded_err := os.open(folded_temp, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
    if folded_err != nil {
        flame_graph_export_job_error(job, "failed to create flame folded export")
        return false
    }
    defer if folded_file != nil { os.close(folded_file) }

    builder := strings.builder_make_len_cap(0, 16 * 1024)
    defer delete(builder.buf)
    if !flame_graph_write_export_summary_header(&builder, job.summary) {
        flame_graph_export_job_error(job, "failed to encode flame export header")
        return false
    }
    header := strings.to_string(builder)
    if !flame_graph_export_file_write(scopes_file, header) || !flame_graph_export_file_write(frames_file, header) {
        flame_graph_export_job_error(job, "failed to write flame export header")
        return false
    }

    record_arr: [1]Flame_Graph_Session_Record
    slots: [dynamic]Flame_Slot
    defer delete(slots)
    entry: Flame_Frame_History
    for _ in 0 ..< job.session_frames {
        record_bytes := slice.reinterpret([]byte, record_arr[:])
        read_count, read_err := os.read_full(session, record_bytes)
        if read_err != nil || read_count != len(record_bytes) {
            flame_graph_export_job_error(job, "flame session record truncated")
            return false
        }

        record := record_arr[0]
        if record.slot_count > u32(FLAME_AUTO_SLOT_CAP) {
            flame_graph_export_job_error(job, "flame session slot count exceeds cap")
            return false
        }
        resize(&slots, int(record.slot_count))
        for index in 0 ..< len(slots) {
            session_slot_array: [1]Flame_Graph_Session_Slot
            session_slot_bytes := slice.reinterpret([]byte, session_slot_array[:])
            if !flame_graph_session_read_bytes(session, session_slot_bytes) {
                flame_graph_export_job_error(job, "flame session slots truncated")
                return false
            }
            session_slot := session_slot_array[0]
            name, name_ok := flame_graph_session_read_string(session, session_slot.name_len, arena_allocator)
            file_path, file_path_ok := flame_graph_session_read_string(
                session,
                session_slot.file_path_len,
                arena_allocator,
            )
            if !name_ok || !file_path_ok {
                flame_graph_export_job_error(job, "flame session string truncated")
                return false
            }
            slots[index] = {
                name      = name,
                file_path = file_path,
                color     = session_slot.color,
                depth     = session_slot.depth,
                line      = session_slot.line,
                start     = session_slot.start,
                end       = session_slot.end,
                active    = session_slot.active,
            }
        }

        entry = {
            frame_id      = record.frame_id,
            total_ms      = record.total_ms,
            wait_ms       = record.wait_ms,
            cpu_ms        = record.cpu_ms,
            gpu_ms        = record.gpu_ms,
            gpu_valid     = record.gpu_valid,
            dropped_slots = record.dropped_slots,
            slots         = slots,
        }
        flame_graph_refresh_history_entry(&entry)

        strings.builder_reset(&builder)
        if !flame_graph_write_source_frame(&builder, &entry) ||
           !flame_graph_export_file_write(frames_file, strings.to_string(builder)) {
            flame_graph_export_job_error(job, "failed to write flame frames export")
            return false
        }

        strings.builder_reset(&builder)
        if !flame_graph_write_source_scopes(&builder, &entry) ||
           !flame_graph_export_file_write(scopes_file, strings.to_string(builder)) {
            flame_graph_export_job_error(job, "failed to write flame scopes export")
            return false
        }

        strings.builder_reset(&builder)
        flame_graph_write_folded_slots(&builder, slots[:])
        if !flame_graph_export_file_write(folded_file, strings.to_string(builder)) {
            flame_graph_export_job_error(job, "failed to write flame folded export")
            return false
        }
        virtual.arena_free_all(&arena)
        sync.atomic_add_explicit(&job.progress_done, 1, .Acq_Rel)
    }

    _ = os.close(scopes_file)
    scopes_file = nil
    _ = os.close(frames_file)
    frames_file = nil
    _ = os.close(folded_file)
    folded_file = nil
    _ = os.remove(job.scopes_path)
    _ = os.remove(job.frames_path)
    _ = os.remove(job.folded_path)
    if os.rename(scopes_temp, job.scopes_path) != nil ||
       os.rename(frames_temp, job.frames_path) != nil ||
       os.rename(folded_temp, job.folded_path) != nil {
        flame_graph_export_job_error(job, "failed to finalize flame exports")
        return false
    }
    return true
}

flame_graph_export_thread_main :: proc(t: ^thread.Thread) {
    job := cast(^Flame_Export_Job)t.data
    ok := flame_graph_export_stream(job)
    sync.atomic_store_explicit(&job.success, 1 if ok else 0, .Release)
    sync.atomic_store_explicit(&job.finished, 1, .Release)
}

@(no_instrumentation)
flame_graph_export_poll :: proc(graph: ^Flame_Graph) {
    if graph == nil || graph.export_thread == nil || graph.export_job == nil do return
    if sync.atomic_load_explicit(&graph.export_job.finished, .Acquire) == 0 do return

    thread.destroy(graph.export_thread)
    graph.export_thread = nil
    job := graph.export_job
    graph.export_job = nil
    ok := sync.atomic_load_explicit(&job.success, .Acquire) != 0
    if ok {
        flame_graph_set_export_status(graph, true, job.scopes_path)
    } else if len(job.error_message) > 0 {
        flame_graph_set_export_status(graph, false, job.error_message)
    } else {
        flame_graph_set_export_status(graph, false, "flame export failed")
    }
    flame_graph_export_job_destroy(job)
}

@(no_instrumentation)
flame_graph_export_stop :: proc(graph: ^Flame_Graph) {
    if graph == nil do return
    if graph.export_thread != nil {
        thread.destroy(graph.export_thread)
        graph.export_thread = nil
    }
    if graph.export_job != nil {
        job := graph.export_job
        graph.export_job = nil
        ok := sync.atomic_load_explicit(&job.success, .Acquire) != 0
        if ok {
            flame_graph_set_export_status(graph, true, job.scopes_path)
        } else if len(job.error_message) > 0 {
            flame_graph_set_export_status(graph, false, job.error_message)
        }
        flame_graph_export_job_destroy(job)
    }
}

flame_graph_export_begin :: proc(graph: ^Flame_Graph, path: string = FLAME_GRAPH_DUMP_PATH) -> bool {
    when !FLAME_SESSION_RECORDING do return false
    if graph == nil || graph.session_frame_count <= 0 || graph.session_file == nil do return false
    flame_graph_export_poll(graph)
    if graph.export_thread != nil do return false
    _ = os.sync(graph.session_file)

    summary := graph.session_summary
    if summary.frame_count != graph.session_frame_count do return false
    job := new(Flame_Export_Job)
    job.scopes_path = flame_graph_source_path(path, ".scopes.ndjson")
    job.frames_path = flame_graph_source_path(path, ".frames.ndjson")
    job.folded_path = flame_graph_source_path(path, ".folded")
    job.session_path = graph.session_path
    job.session_offset = 0
    job.summary = summary
    job.session_frames = summary.frame_count
    job.progress_total = job.session_frames
    if job.session_frames <= 0 {
        flame_graph_export_job_destroy(job)
        return false
    }

    worker := thread.create(flame_graph_export_thread_main, .Low)
    if worker == nil {
        flame_graph_export_job_destroy(job)
        return false
    }
    worker.data = rawptr(job)
    graph.export_job = job
    graph.export_thread = worker
    thread.start(worker)
    return true
}

flame_graph_write_source_range :: proc(
    graph: ^Flame_Graph,
    base_path: string,
    first_order, last_order: int,
    kind: string = "history",
) -> bool {
    when !FLAME_GRAPH do return false
    if graph == nil || graph.history_count == 0 do return false

    first := clamp(first_order, 0, graph.history_count - 1)
    last := clamp(last_order, 0, graph.history_count - 1)
    if first > last do return false

    scopes_builder := strings.builder_make_len_cap(0, 16 * 1024)
    defer delete(scopes_builder.buf)
    frames_builder := strings.builder_make_len_cap(0, 16 * 1024)
    defer delete(frames_builder.buf)
    if !flame_graph_write_source_header(&scopes_builder, graph, first, last, kind) do return false
    if !flame_graph_write_source_header(&frames_builder, graph, first, last, kind) do return false

    for order in first ..= last {
        entry := flame_graph_history_at(graph, order)
        if entry == nil || len(entry.slots) == 0 do continue
        if !flame_graph_write_source_frame(&frames_builder, entry) do return false
        if !flame_graph_write_source_scopes(&scopes_builder, entry) do return false
    }

    scopes_path := flame_graph_source_path(base_path, ".scopes.ndjson")
    defer delete(scopes_path)
    frames_path := flame_graph_source_path(base_path, ".frames.ndjson")
    defer delete(frames_path)
    scopes_ok := flame_graph_write_source_file(scopes_path, strings.to_string(scopes_builder))
    frames_ok := flame_graph_write_source_file(frames_path, strings.to_string(frames_builder))
    flame_graph_set_export_status(graph, scopes_ok && frames_ok, scopes_path)
    return scopes_ok && frames_ok
}

flame_graph_write_source_selection_exports :: proc(graph: ^Flame_Graph, path: string = FLAME_GRAPH_DUMP_PATH) -> bool {
    if graph == nil do return false
    summary := flame_graph_selected_range_summary(graph)
    if !summary.valid do return false
    first_order := flame_graph_history_order_for_frame(graph, summary.first_frame)
    last_order := flame_graph_history_order_for_frame(graph, summary.last_frame)
    base := fmt.aprintf(
        "%s_selection_%d_%d.graph",
        flame_graph_source_stem(path),
        summary.first_frame,
        summary.last_frame,
    )
    defer delete(base)
    ndjson_ok := flame_graph_write_source_range(graph, base, first_order, last_order, "selection")
    folded_ok := flame_graph_write_source_selection_folded(graph, base, first_order, last_order)
    return ndjson_ok || folded_ok
}

flame_graph_write_source_selection_folded :: proc(
    graph: ^Flame_Graph,
    path: string,
    first_order, last_order: int,
) -> bool {
    if graph == nil do return false
    folded_path := flame_graph_source_path(path, ".folded")
    defer delete(folded_path)
    return flame_graph_write_folded_range(graph, first_order, last_order, folded_path)
}

flame_graph_write_source_folded :: proc(graph: ^Flame_Graph, path: string, first_order, last_order: int) -> bool {
    if graph == nil do return false
    folded_path := flame_graph_source_path(path, ".folded")
    defer delete(folded_path)
    return flame_graph_write_folded_range(graph, first_order, last_order, folded_path)
}

flame_graph_write_exports :: proc(graph: ^Flame_Graph, path: string = FLAME_GRAPH_DUMP_PATH) -> bool {
    if graph == nil do return false
    when FLAME_SESSION_RECORDING {
        if !flame_graph_export_begin(graph, path) do return false
        flame_graph_export_stop(graph)
        return graph.export_ok
    }
    ndjson_ok := flame_graph_write_source_range(graph, path, 0, graph.history_count - 1)
    folded_ok := flame_graph_write_source_folded(graph, path, 0, graph.history_count - 1)
    return ndjson_ok || folded_ok
}

when FLAME_AUTO_INSTRUMENT {
    when back.USE_FALLBACK && !back.OTHER_CUSTOM_INSTRUMENTATION {
        #panic("FLAME_AUTO_INSTRUMENT requires BACK_OTHER_CUSTOM_INSTRUMENTATION=true on fallback backtrace targets")
    }

    @(instrumentation_enter, no_instrumentation, private = "file")
    _flame_enter :: #force_inline proc "contextless" (
        proc_address: rawptr,
        call_site_return_address: rawptr,
        loc: runtime.Source_Code_Location,
    ) {
        when back.USE_FALLBACK {
            back.other_instrumentation_enter(proc_address, call_site_return_address, loc)
        }
        flame_graph_instrumentation_enter(proc_address, call_site_return_address, loc)
    }

    @(instrumentation_exit, no_instrumentation, private = "file")
    _flame_exit :: #force_inline proc "contextless" (
        proc_address: rawptr,
        call_site_return_address: rawptr,
        loc: runtime.Source_Code_Location,
    ) {
        flame_graph_instrumentation_exit(proc_address, call_site_return_address, loc)
        when back.USE_FALLBACK {
            back.other_instrumentation_exit(proc_address, call_site_return_address, loc)
        }
    }

    @(no_instrumentation)
    flame_graph_instrumentation_enter :: #force_inline proc "contextless" (
        _: rawptr,
        _: rawptr,
        loc: runtime.Source_Code_Location,
    ) {
        if _flame_graph_current == nil || _flame_graph_auto_busy do return
        _flame_graph_auto_busy = true
        defer _flame_graph_auto_busy = false
        context = runtime.default_context()
        if len(_flame_graph_auto_handles) >= cap(_flame_graph_auto_handles) ||
           len(_flame_graph_current.slots) >= FLAME_AUTO_SLOT_CAP {
            _flame_graph_current.current_dropped_slots += 1
            _flame_graph_auto_overflow_depth += 1
            return
        }
        append(&_flame_graph_auto_handles, flame_graph_begin(_flame_graph_current, loc.procedure, loc = loc))
    }

    @(no_instrumentation)
    flame_graph_instrumentation_exit :: #force_inline proc "contextless" (
        _: rawptr,
        _: rawptr,
        _: runtime.Source_Code_Location,
    ) {
        if _flame_graph_current == nil || _flame_graph_auto_busy do return
        _flame_graph_auto_busy = true
        defer _flame_graph_auto_busy = false
        context = runtime.default_context()
        if _flame_graph_auto_overflow_depth > 0 {
            _flame_graph_auto_overflow_depth -= 1
            return
        }
        if len(_flame_graph_auto_handles) == 0 do return
        index := len(_flame_graph_auto_handles) - 1
        handle := _flame_graph_auto_handles[index]
        resize(&_flame_graph_auto_handles, index)
        _ = flame_graph_end(_flame_graph_current, handle)
    }
} else {
    flame_graph_instrumentation_enter :: proc "contextless" (
        _: rawptr,
        _: rawptr,
        _: runtime.Source_Code_Location,
    ) {  }
    flame_graph_instrumentation_exit :: proc "contextless" (_: rawptr, _: rawptr, _: runtime.Source_Code_Location) {  }
}

flame_graph_widget :: proc(
    graph: ^Flame_Graph,
    child_size: im.Vec2 = {0, FLAME_GRAPH_DEFAULT_HEIGHT},
    slot_height: f32 = FLAME_GRAPH_SLOT_HEIGHT,
) {
    if graph == nil do return
    flame_graph_export_poll(graph)
    im.PushIDPtr(graph)
    defer im.PopID()

    if im.BeginChild("##flame_graph", child_size, {.Borders}, {.HorizontalScrollbar}) {
        if im.Button(graph.paused ? "Resume capture" : "Pause capture") do graph.paused = !graph.paused
        im.SameLine()
        if im.Button("Live") {
            flame_graph_select_single_frame(graph, 0)
            graph.drag_anchor_id = 0
            graph.dragging_timeline = false
        }
        im.SameLine()
        if im.Button("Clear") do flame_graph_reset(graph)
        when FLAME_GRAPH_DEVELOPER_EXPORTS {
            im.SameLine()
            if im.Button("Export history") {
                when FLAME_SESSION_RECORDING {
                    _ = flame_graph_export_begin(graph)
                } else {
                    _ = flame_graph_write_exports(graph)
                }
            }
            im.SameLine()
            if im.Button("Export folded") do _ = flame_graph_write_source_folded(graph, FLAME_GRAPH_DUMP_PATH, 0, graph.history_count - 1)
            if graph.export_thread != nil && graph.export_job != nil {
                im.SameLine()
                done := sync.atomic_load_explicit(&graph.export_job.progress_done, .Acquire)
                im.TextDisabled("exporting %d/%d", done, graph.export_job.progress_total)
            }
        }

        latest := flame_graph_latest(graph)
        selected := flame_graph_selected(graph)
        if latest == nil || selected == nil {
            im.TextDisabled("Waiting for frame samples")
            im.EndChild()
            return
        }

        selected_range := flame_graph_selected_range_summary(graph)
        summary := flame_graph_history_summary(graph)
        im.Text(
            "Frame #%d  %.2f ms  %.1f FPS",
            selected.frame_id,
            selected.total_ms,
            1000 / max(selected.total_ms, f32(.001)),
        )
        im.Text("History %d  avg %.2f ms  worst %.2f ms", summary.count, summary.average_ms, summary.worst_ms)
        im.Text("wait %.2f ms  cpu %.2f ms", selected.wait_ms, selected.cpu_ms)
        if selected.gpu_valid {
            im.SameLine()
            im.Text("gpu %.2f ms", selected.gpu_ms)
        } else {
            im.SameLine()
            im.TextDisabled("gpu unavailable")
        }
        if selected_range.valid {
            im.Text(
                "Selected frames #%d..#%d  avg %.2f ms",
                selected_range.first_frame,
                selected_range.last_frame,
                selected_range.average_ms,
            )
            when FLAME_GRAPH_DEVELOPER_EXPORTS {
                if im.Button("Export selection") do _ = flame_graph_write_source_selection_exports(graph)
                im.SameLine()
                if im.Button("Export selection folded") {
                    selection := flame_graph_selected_range_summary(graph)
                    if selection.valid {
                        first_order := flame_graph_history_order_for_frame(graph, selection.first_frame)
                        last_order := flame_graph_history_order_for_frame(graph, selection.last_frame)
                        base := fmt.aprintf(
                            "%s_selection_%d_%d.graph",
                            flame_graph_source_stem(FLAME_GRAPH_DUMP_PATH),
                            selection.first_frame,
                            selection.last_frame,
                        )
                        _ = flame_graph_write_source_selection_folded(graph, base, first_order, last_order)
                        delete(base)
                    }
                }
            }
        }
        if graph.export_message != "" {
            im.TextDisabled(
                "%s",
                fmt.ctprintf("export %s: %s", "ok" if graph.export_ok else "failed", graph.export_message),
            )
        }

        width := max(im.GetContentRegionAvail()[0], f32(1))
        im.InvisibleButton("##flame_timeline", {width, FLAME_GRAPH_TIMELINE_HEIGHT})
        timeline_min := im.GetItemRectMin()
        timeline_max := im.GetItemRectMax()
        timeline_height := timeline_max.y - timeline_min.y
        draw_list := im.GetWindowDrawList()
        im.DrawList_AddRectFilled(draw_list, timeline_min, timeline_max, im.GetColorU32(.FrameBg), 5)
        max_ms := f32(16.667)
        for order in 0 ..< graph.history_count {
            if entry := flame_graph_history_at(graph, order); entry != nil {
                max_ms = max(max_ms, entry.total_ms)
            }
        }
        max_ms *= 1.1
        for order in 0 ..< graph.history_count {
            entry := flame_graph_history_at(graph, order)
            if entry == nil || len(entry.slots) == 0 do continue
            x0 := timeline_min.x + f32(order) * (width - 1) / f32(max(graph.history_count - 1, 1))
            x1 := timeline_min.x + f32(order + 1) * (width - 1) / f32(max(graph.history_count - 1, 1))
            if graph.history_count == 1 do x1 = timeline_max.x
            for slot in entry.slots {
                if slot.depth != 0 do continue
                y0 := timeline_max.y - f32(flame_slot_ms(slot)) * timeline_height / max_ms
                y1 := timeline_max.y - f32(flame_tick_ms(entry.slots[0].start, slot.start)) * timeline_height / max_ms
                im.DrawList_AddRectFilled(
                    draw_list,
                    {x0, max(y0, timeline_min.y)},
                    {max(x1, x0 + 1), y1},
                    slot.color,
                    0,
                )
            }
        }
        hovered_order := -1
        if im.IsItemHovered() || graph.dragging_timeline {
            mouse := im.GetMousePos()
            fraction := clamp(
                (mouse.x - timeline_min.x) / max(timeline_max.x - timeline_min.x, f32(1)),
                f32(0),
                f32(1),
            )
            hovered_order = clamp(int(fraction * f32(graph.history_count - 1) + .5), 0, graph.history_count - 1)
        }
        hovered_entry: ^Flame_Frame_History
        if hovered_order >= 0 do hovered_entry = flame_graph_history_at(graph, hovered_order)
        if im.IsItemHovered() && im.IsMouseClicked(.Left) && hovered_entry != nil {
            graph.dragging_timeline = true
            graph.drag_anchor_id = hovered_entry.frame_id
        }

        if graph.dragging_timeline {
            anchor_order := flame_graph_history_order_for_frame(graph, graph.drag_anchor_id)
            current_order := hovered_order
            if current_order < 0 do current_order = anchor_order
            if anchor_order >= 0 && current_order >= 0 {
                provisional_range := flame_graph_range_summary(graph, anchor_order, current_order)
                if im.IsMouseReleased(.Left) {
                    if provisional_range.valid && provisional_range.count > 1 {
                        flame_graph_select_range_summary(graph, provisional_range)
                    } else if hovered_entry != nil {
                        flame_graph_select_single_frame(graph, hovered_entry.frame_id)
                    } else {
                        flame_graph_select_single_frame(graph, graph.drag_anchor_id)
                    }
                    graph.drag_anchor_id = 0
                    graph.dragging_timeline = false
                    im.ResetMouseDragDelta(.Left)
                }
            } else {
                graph.drag_anchor_id = 0
                graph.dragging_timeline = false
            }
        }
        selected_range = flame_graph_selected_range_summary(graph)
        selected = flame_graph_selected(graph)

        if selected_range.valid {
            first_order := flame_graph_history_order_for_frame(graph, selected_range.first_frame)
            last_order := flame_graph_history_order_for_frame(graph, selected_range.last_frame)
            left_x := timeline_min.x + f32(first_order) * (width - 1) / f32(max(graph.history_count - 1, 1))
            right_x := timeline_min.x + f32(last_order) * (width - 1) / f32(max(graph.history_count - 1, 1))
            if graph.history_count == 1 do right_x = timeline_max.x
            range_min: im.Vec2 = {max(left_x - 2, timeline_min.x), timeline_min.y}
            range_max: im.Vec2 = {min(right_x + 2, timeline_max.x), timeline_max.y}
            im.DrawList_AddRectFilled(draw_list, range_min, range_max, im.GetColorU32(.Border), 2)
            im.DrawList_AddRect(draw_list, range_min, range_max, im.GetColorU32(.Text), 2)
        }
        im.DrawList_AddRect(draw_list, timeline_min, timeline_max, im.GetColorU32(.Border), 5)

        im.Text("Flame frame #%d", selected.frame_id)
        if len(selected.slots) == 0 {
            im.TextDisabled("No nested scopes recorded")
        } else {
            span_start := selected.slots[0].start
            span_end := selected.slots[0].end
            max_depth := 0
            for slot in selected.slots {
                span_start = flame_tick_min(span_start, slot.start)
                span_end = flame_tick_max(span_end, slot.end)
                max_depth = max(max_depth, slot.depth)
            }
            span_ms := max(f32(flame_tick_ms(span_start, span_end)), f32(.001))
            height := slot_height * f32(max_depth + 1)
            canvas_min := im.GetCursorScreenPos()
            im.Dummy({width, height})
            canvas_max := canvas_min + im.Vec2{width, height}
            im.DrawList_AddRectFilled(draw_list, canvas_min, canvas_max, im.GetColorU32(.FrameBg), 5)
            text_color := im.GetColorU32(.Text)
            for slot in selected.slots {
                x0 := canvas_min.x + f32(flame_tick_ms(span_start, slot.start)) / span_ms * width
                x1 := canvas_min.x + f32(flame_tick_ms(slot.start, slot.end)) / span_ms * width + x0 - canvas_min.x
                x1 = max(x1, x0 + 1)
                y0 := canvas_min.y + slot_height * f32(slot.depth)
                y1 := y0 + slot_height - 2
                im.DrawList_AddRectFilled(draw_list, {x0, y0}, {min(x1, canvas_max.x), y1}, slot.color, 2)
                if x1 - x0 >= 48 {
                    label := fmt.ctprint(slot.name)
                    label_size := im.CalcTextSize(label)
                    if label_size.x + 8 <= x1 - x0 {
                        im.DrawList_PushClipRect(draw_list, {x0, y0}, {x1, y1}, true)
                        im.DrawList_AddText(draw_list, {x0 + 4, y0 + 2}, text_color, label)
                        im.DrawList_PopClipRect(draw_list)
                    }
                }
            }
            im.DrawList_AddRect(draw_list, canvas_min, canvas_max, im.GetColorU32(.Border), 5)
        }
    }
    im.EndChild()
}
