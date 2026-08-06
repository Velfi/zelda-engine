#+private file
package backtrace

import "base:runtime"
@(require) import "core:c/libc"
@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:sync"

when !USE_FALLBACK {

    Frame_Line_Cache_Entry :: struct {
        line: Line,
    }

    frame_line_cache: map[rawptr]Frame_Line_Cache_Entry
    frame_line_cache_mutex: sync.Mutex
    frame_symbolicator: CSSymbolicatorRef
    frame_symbolicator_ready: bool

    clone_line :: proc(line: Line, alloc := context.allocator) -> (out: Line) {
        if line.location != "" {
            out.location = strings.clone(line.location, alloc)
        }
        if line.symbol != "" {
            out.symbol = strings.clone(line.symbol, alloc)
        }
        return
    }

    frame_line_cache_init :: proc() {
        if frame_line_cache.allocator.procedure == nil {
            frame_line_cache.allocator = runtime.default_context().allocator
        }
    }

    frame_line_cache_lookup :: proc(frame: rawptr, alloc := context.allocator) -> (line: Line, ok: bool) {
        sync.guard(&frame_line_cache_mutex)
        frame_line_cache_init()
        cached, found := frame_line_cache[frame]
        if !found {
            return
        }
        line = clone_line(cached.line, alloc)
        return line, true
    }

    frame_line_cache_store :: proc(frame: rawptr, line: Line) {
        sync.guard(&frame_line_cache_mutex)
        frame_line_cache_init()
        if _, ok := frame_line_cache[frame]; ok {
            return
        }
        frame_line_cache[frame] = {
            line = clone_line(line, runtime.default_context().allocator),
        }
    }

    frame_symbolicator_get :: proc() -> CSSymbolicatorRef {
        sync.guard(&frame_line_cache_mutex)
        if !frame_symbolicator_ready {
            frame_symbolicator = CSSymbolicatorCreateWithPid(getpid())
            frame_symbolicator_ready = true
        }
        return frame_symbolicator
    }

    resolve_line :: proc(frame: rawptr) -> (msg: Line) {
        symbolicator := frame_symbolicator_get()
        symbol := CSSymbolicatorGetSymbolWithAddressAtTime(symbolicator, uintptr(frame), CSNow)
        info := CSSymbolicatorGetSourceInfoWithAddressAtTime(symbolicator, uintptr(frame), CSNow)

        msg.symbol = strings.clone_from(CSSymbolGetName(symbol))

        // No debug info.
        if CSIsNull(info) {
            owner := CSSymbolGetSymbolOwner(symbol)
            msg.location = strings.clone_from(CSSymbolOwnerGetPath(owner))
            if fallback := atos_source_location(frame); fallback != "" {
                delete(msg.location)
                msg.location = fallback
            }
        } else {
            path := string(CSSourceInfoGetPath(info))
            location := strings.builder_make(0, len(path) + 6)
            strings.write_string(&location, path)
            strings.write_string(&location, ":")
            strings.write_int(&location, int(CSSourceInfoGetLineNumber(info)))
            msg.location = strings.to_string(location)
        }
        return
    }

    foreign import system "system:System.framework"

    // NOTE: CoreSymbolication is a private framework, Apple is allowed to break it and doesn't provide
    // headers, although the API has as of my knowledge been the same in the past 10 years at least.
    @(extra_linker_flags = "-iframework /System/Library/PrivateFrameworks")
    foreign import symbolication "system:CoreSymbolication.framework"

    @(private = "package")
    _Trace_Entry :: rawptr

    @(private = "package")
    _trace :: proc(buf: Trace) -> (n: int) {
        ctx: unw_context_t
        cursor: unw_cursor_t

        ret: i32
        ret = unw_getcontext(&ctx)
        assert(ret == 0, "libunwind failed to capture current execution context")
        ret = unw_init_local(&cursor, &ctx)
        assert(ret == 0, "libunwind failed to initialize local cursor")

        pc: uintptr
        for ; unw_step(&cursor) > 0 && n < len(buf); n += 1 {
            ret = unw_get_reg(&cursor, .IP, &pc)
            assert(ret == 0, "libunwind failed to read instruction pointer register")
            buf[n] = rawptr(pc)
        }

        return
    }

    @(private = "package")
    _lines_destroy :: proc(lines: []Line) {
        for line in lines {
            if len(line.location) > 0 {
                delete(line.location)
            }
            if len(line.symbol) > 0 {
                delete(line.symbol)
            }
        }
        delete(lines)
    }

    @(private = "package")
    _lines :: proc(bt: Trace) -> (out: []Line, err: Lines_Error) {
        out = make([]Line, len(bt))

        for &msg, i in out {
            if cached, ok := frame_line_cache_lookup(bt[i]); ok {
                msg = cached
                continue
            }

            msg = resolve_line(bt[i])
            frame_line_cache_store(bt[i], msg)
        }
        return
    }

    CSTypeRef :: struct {
        csCppData: rawptr,
        csCppObj:  rawptr,
    }

    CSSymbolicatorRef :: distinct CSTypeRef
    CSSymbolRef :: distinct CSTypeRef
    CSSourceInfoRef :: distinct CSTypeRef
    CSSymbolOwnerRef :: distinct CSTypeRef

    CSNow :: 0x80000000

    foreign symbolication {
        @(link_name = "CSIsNull")
        _CSIsNull :: proc(ref: CSTypeRef) -> bool ---
        @(link_name = "CSRelease")
        _CSRelease :: proc(ref: CSTypeRef) ---

        CSSymbolicatorCreateWithPid :: proc(pid: pid_t) -> CSSymbolicatorRef ---

        CSSymbolicatorGetSymbolWithAddressAtTime :: proc(symbolicator: CSSymbolicatorRef, addr: uintptr, time: u64) -> CSSymbolRef ---
        CSSymbolicatorGetSourceInfoWithAddressAtTime :: proc(symbolicator: CSSymbolicatorRef, adrr: uintptr, time: u64) -> CSSourceInfoRef ---

        CSSymbolGetName :: proc(symbol: CSSymbolRef) -> cstring ---
        CSSymbolGetSymbolOwner :: proc(symbol: CSSymbolRef) -> CSSymbolOwnerRef ---

        CSSourceInfoGetPath :: proc(info: CSSourceInfoRef) -> cstring ---
        CSSourceInfoGetLineNumber :: proc(info: CSSourceInfoRef) -> i32 ---
        CSSourceInfoGetSymbol :: proc(info: CSSourceInfoRef) -> CSSymbolRef ---

        CSSymbolOwnerGetPath :: proc(owner: CSSymbolOwnerRef) -> cstring ---
    }

    CSRelease :: #force_inline proc(ref: $T) {
        _CSRelease(CSTypeRef(ref))
    }

    CSIsNull :: #force_inline proc(ref: $T) -> bool {
        return _CSIsNull(CSTypeRef(ref))
    }

    // These could actually be smaller, but then we would have to define and check the size on each
    // architecture, the sizes here are the largest they can be.
    _LIBUNWIND_CONTEXT_SIZE :: 167
    _LIBUNWIND_CURSOR_SIZE :: 204

    unw_context_t :: struct {
        data: [_LIBUNWIND_CONTEXT_SIZE]u64,
    }

    unw_cursor_t :: struct {
        data: [_LIBUNWIND_CURSOR_SIZE]u64,
    }

    // Cross-platform registers, each architecture has additional registers but these are enough for us.
    Register :: enum i32 {
        SP = -2,
        IP = -1,
    }

    pid_t :: distinct i32

    foreign system {
        unw_getcontext :: proc(ctx: ^unw_context_t) -> i32 ---
        unw_init_local :: proc(cursor: ^unw_cursor_t, ctx: ^unw_context_t) -> i32 ---
        unw_get_reg :: proc(cursor: ^unw_cursor_t, name: Register, reg: ^uintptr) -> i32 ---
        unw_step :: proc(cursor: ^unw_cursor_t) -> i32 ---

        getpid :: proc() -> pid_t ---
    }

    foreign import lib "system:c"

    Dl_Info :: struct {
        dli_fname: cstring,
        dli_fbase: rawptr,
        dli_sname: cstring,
        dli_saddr: rawptr,
    }

    foreign lib {
        dladdr :: proc(addr: rawptr, info: ^Dl_Info) -> i32 ---
        popen :: proc(command: cstring, mode: cstring) -> ^libc.FILE ---
        pclose :: proc(stream: ^libc.FILE) -> i32 ---
    }

    atos_source_location :: proc(addr: rawptr) -> string {
        info: Dl_Info
        if dladdr(addr, &info) == 0 || info.dli_fname == nil || info.dli_fbase == nil {
            return ""
        }

        command := fmt.aprintf("atos -o '%s' -l %p %p 2>/dev/null", string(info.dli_fname), info.dli_fbase, addr)
        defer delete(command)

        command_builder := strings.builder_make(0, len(command) + 1)
        defer strings.builder_destroy(&command_builder)
        strings.write_string(&command_builder, command)
        strings.write_byte(&command_builder, 0)
        command_c := strings.unsafe_string_to_cstring(strings.to_string(command_builder))

        output := popen(command_c, "r")
        if output == nil {
            return ""
        }
        defer pclose(output)

        line_buf: [2048]byte
        if libc.fgets(raw_data(line_buf[:]), i32(len(line_buf)), output) == nil {
            return ""
        }

        line_raw := strings.clone_from(cstring(raw_data(line_buf[:])))
        if len(line_raw) == 0 {
            return ""
        }
        defer delete(line_raw)
        line := strings.trim_right_space(line_raw)
        if line == "" {
            return ""
        }
        return parse_atos_source_line(line)
    }

    parse_atos_source_line :: proc(line: string) -> string {
        if !strings.contains(line, ".odin:") {
            return ""
        }

        if strings.has_suffix(line, ")") {
            if open := strings.last_index(line, " ("); open >= 0 {
                candidate := strings.trim_space(line[open + 2:len(line) - 1])
                if strings.contains(candidate, ".odin:") {
                    return strings.clone(candidate)
                }
            }
        }

        anchor := strings.index(line, ".odin:")
        if anchor < 0 {
            return ""
        }

        start := anchor
        for start > 0 {
            prev := line[start - 1]
            if prev == ' ' || prev == '(' {
                break
            }
            start -= 1
        }

        end := anchor + len(".odin:")
        for end < len(line) {
            ch := line[end]
            if (ch < '0' || ch > '9') && ch != ':' {
                break
            }
            end += 1
        }

        if end <= start {
            return ""
        }
        return strings.clone(line[start:end])
    }

}
