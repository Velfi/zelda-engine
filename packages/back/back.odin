package backtrace

import "base:runtime"

import "core:fmt"
import "core:io"
import "core:text/table"

// Size of a constant backtrace, as used by the allocator for example.
BACKTRACE_SIZE :: #config(BACKTRACE_SIZE, 16)

// For targets that do not have native support (using debug info),
// backtraces are done through instrumentation, Odin only allows one enter/exit instrumentation
// procedure though, so you can set this to true, add your own instrumentation procs, and have
// them call `back.other_instrumentation_enter` and `back.other_instrumentation_exit` to hook
// up the backtraces.
//
// The custom proc must have `#force_inline`.
OTHER_CUSTOM_INSTRUMENTATION :: #config(BACK_OTHER_CUSTOM_INSTRUMENTATION, false)

// Force the fallback instrumentation based implementation instead of debug info based.
FORCE_FALLBACK :: #config(BACK_FORCE_FALLBACK, false)

USE_FALLBACK :: FORCE_FALLBACK || (ODIN_OS != .Darwin && ODIN_OS != .Linux && ODIN_OS != .Windows)

Trace :: []Trace_Entry

Trace_Const :: struct {
    trace: [BACKTRACE_SIZE]Trace_Entry,
    len:   int,
}

// Platform specific.
Trace_Entry :: _Trace_Entry

Line :: struct {
    location: string,
    symbol:   string,
}

Crash_Kind :: enum {
    Assertion,
    Segfault,
}

Crash_Callback :: #type proc(kind: Crash_Kind, summary: string, lines: []Line)

@(private = "package")
crash_callback: Crash_Callback

// #+vet redundancy public-api
set_crash_callback :: proc(callback: Crash_Callback) {
    crash_callback = callback
}

@(private = "package")
emit_crash_callback :: proc(kind: Crash_Kind, summary: string, lines: []Line = nil) {
    if crash_callback != nil {
        crash_callback(kind, summary, lines)
    }
}

trigger_crash_callback :: proc(kind: Crash_Kind, summary: string, lines: []Line = nil) {
    emit_crash_callback(kind, summary, lines)
}

EAGAIN :: 11 when ODIN_OS == .Linux || ODIN_OS == .Darwin else 5
ENOMEM :: 12 when ODIN_OS == .Linux || ODIN_OS == .Darwin else 6
EFAULT :: 14 when ODIN_OS == .Linux || ODIN_OS == .Darwin else 7
EMFILE :: 24 when ODIN_OS == .Linux || ODIN_OS == .Darwin else 8
ENFILE :: 23 when ODIN_OS == .Linux || ODIN_OS == .Darwin else 9
ENOSYS :: 38 when ODIN_OS == .Linux || ODIN_OS == .Darwin else 10

Lines_Error :: enum {
    None,
    Parse_Address_Fail,
    Addr2line_Unexpected_EOF,
    Addr2line_Output_Error,
    Addr2line_Unresolved,
    Fork_Limited = int(EAGAIN),
    Out_Of_Memory = int(ENOMEM),
    Invalid_Fd = int(EFAULT),
    Pipe_Process_Limited = int(EMFILE),
    Pipe_System_Limited = int(ENFILE),
    Fork_Not_Supported = int(ENOSYS),
    Info_Not_Found,
}

trace :: #force_no_inline proc() -> (bt: Trace_Const) {
    bt.len = #force_inline _trace(bt.trace[:])
    return
}

// #+vet redundancy public-api
trace_n :: #force_no_inline proc(max_len: i32, alloc := context.allocator) -> Trace {
    context.allocator = alloc
    bt := make([]Trace_Entry, max_len)
    n := #force_inline _trace(bt[:])
    return bt[:n]
}

// #+vet redundancy public-api
trace_fill :: #force_no_inline proc(buf: Trace) -> int {
    return #force_inline _trace(buf)
}

// #+vet redundancy public-api
trace_n_destroy :: proc(b: Trace, alloc := context.allocator) {
    delete(b, alloc)
}

// Processes the message trying to get more/useful information.
// This adds file and line information if the program is running in debug mode.
//
// If an error is returned the original message will be the result and is save to use.
lines :: proc {
    lines_n,
    lines_const,
}

lines_n :: proc(bt: Trace, alloc := context.allocator) -> (out: []Line, err: Lines_Error) {
    context.allocator = alloc
    return _lines(bt)
}

lines_const :: proc(bt: Trace_Const, alloc := context.allocator) -> (out: []Line, err: Lines_Error) {
    context.allocator = alloc
    bt := bt
    return _lines(bt.trace[:bt.len])
}

lines_destroy :: proc(lines: []Line, alloc := context.allocator) {
    context.allocator = alloc
    _lines_destroy(lines)
}

// #+vet redundancy public-api
assertion_failure_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
    summary := fmt.aprintf("%s: %s", prefix, message)
    t := trace()
    lines, err := lines(t.trace[:t.len])
    if err != nil {
        emit_crash_callback(.Assertion, summary)
        fmt.eprintf("could not get backtrace for assertion failure: %v\n", err)
        runtime.default_assertion_failure_proc(prefix, message, loc)
    } else {
        emit_crash_callback(.Assertion, summary, lines)
        fmt.eprintln("[back trace]")
        print(lines)
        runtime.default_assertion_failure_proc(prefix, message, loc)
    }
}

// #+vet redundancy public-api
register_segfault_handler :: proc() {
    _register_segfault_handler()
}

@(private = "file")
_back_stderr_stream_proc :: proc(
    stream_data: rawptr,
    mode: io.Stream_Mode,
    p: []byte,
    offset: i64,
    whence: io.Seek_From,
) -> (
    n: i64,
    err: io.Error,
) {

    switch mode {
    case .Write:
        written, _ := runtime.stderr_write(p)
        return i64(written), nil
    case .Flush, .Close:
        return 0, nil
    case .Query:
        return io.query_utility({.Write, .Flush, .Close})
    case .Read, .Read_At, .Write_At, .Seek, .Size, .Destroy:
        return 0, .Unsupported
    case:
        return 0, .Unsupported
    }
}

back_default_writer :: proc() -> io.Writer {
    return {procedure = _back_stderr_stream_proc}
}

print :: proc(lines: []Line, padding := "    ", w: Maybe(io.Writer) = nil, no_temp_guard := false) {
    writer := w.? or_else back_default_writer()

    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = no_temp_guard)

    tbl := table.init(&table.Table{}, context.temp_allocator, context.temp_allocator)

    for line in lines {
        table.row(tbl, padding, line.symbol, " - ", line.location)
    }

    table.build(tbl, table.unicode_width_proc)

    for row in 0 ..< tbl.nr_rows {
        for col in 0 ..< tbl.nr_cols {
            table.write_table_cell(writer, tbl, row, col)
        }
        io.write_byte(writer, '\n')
    }
}
