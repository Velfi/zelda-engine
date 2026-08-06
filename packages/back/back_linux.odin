#+private file
package backtrace
import "base:runtime"
@(require) import "core:c"
@(require) import "core:c/libc"
@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:path/filepath"
@(require) import "core:slice"
@(require) import "core:strings"
@(require) import "core:sync"

ADDR2LINE_PATH := #config(BACK_ADDR2LINE_PATH, #config(TRACE_ADDR2LINE_PATH, "addr2line"))
PROGRAM := #config(BACK_PROGRAM, "")

when !USE_FALLBACK {

    Frame_Line_Cache_Entry :: struct {
        line: Line,
        ok:   bool,
    }

    frame_line_cache: map[rawptr]Frame_Line_Cache_Entry
    frame_line_cache_mutex: sync.Mutex

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

    frame_line_cache_lookup :: proc(frame: rawptr, alloc := context.allocator) -> (line: Line, ok, cached: bool) {
        sync.guard(&frame_line_cache_mutex)
        frame_line_cache_init()
        entry: Frame_Line_Cache_Entry
        entry, cached = frame_line_cache[frame]
        if !cached {
            return
        }
        line = clone_line(entry.line, alloc)
        ok = entry.ok
        return
    }

    frame_line_cache_store :: proc(frame: rawptr, line: Line, ok: bool) {
        sync.guard(&frame_line_cache_mutex)
        frame_line_cache_init()
        if _, cached := frame_line_cache[frame]; cached {
            return
        }
        frame_line_cache[frame] = {
            line = clone_line(line, runtime.default_context().allocator),
            ok   = ok,
        }
    }

    foreign import lib "system:c"

    @(init)
    program_init :: proc "contextless" () {
        context = runtime.default_context()
        if PROGRAM == "" {
            PROGRAM = os.args[0]
            if PROGRAM != "" && !filepath.is_abs(PROGRAM) {
                if abs, err := filepath.abs(PROGRAM); err == nil {
                    PROGRAM = abs
                } else {
                    fmt.eprintln("back: could not convert `os.args[0]` to an absolute path")
                }
            }
            if PROGRAM == "" {
                if exe, exe_err := os.get_executable_path(context.allocator); exe_err == nil {
                    PROGRAM = exe
                } else {
                    fmt.eprintln("back: could not resolve executable path from os.get_executable_path")
                }
            }
        }
    }

    @(private = "package")
    _Trace_Entry :: rawptr

    @(private = "package")
    _trace :: proc(buf: Trace) -> (n: int) {
        n = int(backtrace(raw_data(buf), i32(len(buf))))
        return
    }

    @(private = "package")
    _lines_destroy :: proc(msgs: []Line) {
        for msg in msgs {
            delete(msg.location)

            when ODIN_DEBUG {
                if msg.symbol != "" && msg.symbol != "??" { delete(msg.symbol) }
            }
        }
        delete(msgs)
    }

    @(private = "package")
    _lines :: proc(bt: Trace) -> (out: []Line, err: Lines_Error) {
        if len(bt) == 0 do return

        raw_msgs := backtrace_symbols(raw_data(bt), i32(len(bt)))
        if raw_msgs == nil {
            out = make([]Line, len(bt))
            for i in 0 ..< len(out) {
                out[i] = {
                    location = strings.clone("??"),
                    symbol   = "??",
                }
            }
            err = .Info_Not_Found
            return
        }
        msgs := raw_msgs[:len(bt)]
        defer libc.free(raw_data(msgs))

        out = make([]Line, len(bt))

        // Debug info is needed.
        when !ODIN_DEBUG {
            for msg, i in msgs {
                location := strings.clone("??")
                if msg != nil {
                    delete(location)
                    location = strings.clone_from(msg)
                }
                out[i] = Line {
                    location = location,
                    symbol   = "??",
                }
            }
            return
        }

        // Parse output, each address gets 2 lines of output,
        // one for the function/symbol and one for the location.
        // If it could not be resolved, '??' is put out.
        line_buf: [1024]byte
        for msg, i in msgs {
            location := strings.clone("??")
            if msg != nil {
                delete(location)
                location = strings.clone_from(msg)
            }
            out[i] = Line {
                location = location,
                symbol   = "??",
            }
            if msg == nil do continue

            parsed, parsed_ok := symbolize_message(bt[i], msg, line_buf[:])
            if !parsed_ok do continue

            delete(out[i].location)
            out[i] = parsed
            if out[i].location == "" || out[i].location == "??" {
                out[i].location = strings.clone_from(msg)
            }
            line_buf = 0
        }

        return
    }


    foreign lib {
        backtrace :: proc(buffer: [^]rawptr, size: c.int) -> c.int ---
        backtrace_symbols :: proc(buffer: [^]rawptr, size: c.int) -> [^]cstring ---
        backtrace_symbols_fd :: proc(buffer: [^]rawptr, size: c.int, fd: ^libc.FILE) ---
        dladdr :: proc(addr: rawptr, info: ^Dl_Info) -> i32 ---

        popen :: proc(command: cstring, type: cstring) -> ^libc.FILE ---
        pclose :: proc(stream: ^libc.FILE) -> c.int ---
    }

    Dl_Info :: struct {
        dli_fname: cstring,
        dli_fbase: rawptr,
        dli_sname: cstring,
        dli_saddr: rawptr,
    }

    Symbolizer_Source :: struct {
        exe:         string,
        addr:        string,
        addr_alt:    string,
        symbol_hint: string,
    }

    parse_symbolizer_source :: proc(frame: Trace_Entry, msg: cstring) -> (source: Symbolizer_Source, ok: bool) {
        info: Dl_Info
        if dladdr(frame, &info) != 0 && info.dli_fname != nil && info.dli_fbase != nil {
            source.exe = strings.clone_from(info.dli_fname)
            source.addr = strings.clone(fmt.tprintf("0x%x", uintptr(frame) - uintptr(info.dli_fbase)))
            source.addr_alt = strings.clone(fmt.tprintf("0x%x", uintptr(frame)))
            if info.dli_sname != nil {
                source.symbol_hint = strings.clone_from(info.dli_sname)
            }
            return source, true
        }

        multi := ([^]byte)(msg)
        msg_len := len(msg)

        open := -1
        close := -1
        for c, i in multi[:msg_len] {
            if c == '(' {
                open = i
                break
            }
        }
        if open > 0 {
            for c, i in multi[open + 1:msg_len] {
                if c == ')' {
                    close = open + 1 + i
                    break
                }
            }
        }

        if open > 0 && close > open {
            plus := -1
            for c, i in multi[open + 1:close] {
                if c == '+' {
                    plus = open + 1 + i
                    break
                }
            }
            if plus >= 0 &&
               plus + 2 < close &&
               multi[plus + 1] == '0' &&
               (multi[plus + 2] == 'x' || multi[plus + 2] == 'X') {
                source.exe = strings.clone(string(multi[:open]))
                source.addr = strings.clone(string(multi[plus + 1:close]))
                symbol := strings.trim_space(string(multi[open + 1:plus]))
                if symbol != "" {
                    source.symbol_hint = strings.clone(symbol)
                }
                absolute, absolute_err := parse_address(msg)
                if absolute_err == nil {
                    source.addr_alt = strings.clone(absolute)
                }
                return source, true
            }

            symbol := strings.trim_space(string(multi[open + 1:close]))
            if symbol != "" && !strings.contains(symbol, "0x") {
                source.symbol_hint = strings.clone(symbol)
            }
        }

        absolute, absolute_err := parse_address(msg)
        if absolute_err != nil {
            return source, false
        }

        if open > 0 {
            source.exe = strings.clone(string(multi[:open]))
        } else if PROGRAM != "" {
            source.exe = strings.clone(PROGRAM)
        } else {
            if exe, exe_err := os.get_executable_path(context.temp_allocator); exe_err == nil {
                source.exe = strings.clone(exe)
            }
        }
        if source.exe == "" {
            return source, false
        }
        source.addr = strings.clone(absolute)
        return source, true
    }

    shell_write_single_quoted :: proc(sb: ^strings.Builder, s: string) {
        strings.write_byte(sb, '\'')
        for i in 0 ..< len(s) {
            c := s[i]
            if c == '\'' {
                strings.write_string(sb, "'\"'\"'")
            } else {
                strings.write_byte(sb, c)
            }
        }
        strings.write_byte(sb, '\'')
    }

    symbolizer_exe_resolve :: proc(exe: string) -> (resolved: string, ok: bool) {
        candidate := strings.trim_space(exe)
        if candidate == "" || candidate == "linux-vdso.so.1" do return

        if os.exists(candidate) && !os.is_directory(candidate) {
            if filepath.is_abs(candidate) {
                resolved = strings.clone(candidate)
            } else if abs, abs_err := filepath.abs(candidate); abs_err == nil {
                resolved = abs
            } else {
                resolved = strings.clone(candidate)
            }
            ok = resolved != ""
            return
        }
        if filepath.is_abs(candidate) do return

        if abs, abs_err := filepath.abs(candidate); abs_err == nil {
            if os.exists(abs) && !os.is_directory(abs) {
                resolved = abs
                ok = true
                return
            }
            delete(abs)
        }
        return
    }

    // Build command like: `{addr2line_path} -f -e '{program}' {address}`.
    make_symbolizer_cmd :: proc(exe, addr: string) -> (cmd: cstring) {
        cmd_builder := strings.builder_make()

        strings.write_string(&cmd_builder, ADDR2LINE_PATH)
        strings.write_string(&cmd_builder, " -f -e ")
        shell_write_single_quoted(&cmd_builder, exe)

        strings.write_byte(&cmd_builder, ' ')
        strings.write_string(&cmd_builder, addr)

        strings.write_byte(&cmd_builder, 0)
        return strings.unsafe_string_to_cstring(strings.to_string(cmd_builder))
    }

    symbolize_message :: proc(frame: Trace_Entry, msg: cstring, buf: []byte) -> (line: Line, ok: bool) {
        if cached, cached_ok, was_cached := frame_line_cache_lookup(frame); was_cached {
            return cached, cached_ok
        }

        source, source_ok := parse_symbolizer_source(frame, msg)
        if !source_ok {
            frame_line_cache_store(frame, {}, false)
            return
        }
        defer delete(source.exe)
        defer delete(source.addr)
        if source.addr_alt != "" do defer delete(source.addr_alt)
        symbol_hint := ""
        if source.symbol_hint != "" {
            symbol_hint = strings.clone(source.symbol_hint)
            delete(source.symbol_hint)
            source.symbol_hint = ""
        }
        if symbol_hint != "" do defer delete(symbol_hint)

        line, ok = symbolize_message_with(source.exe, source.addr, buf)
        if ok {
            if line.symbol == "??" && symbol_hint != "" {
                line.symbol = strings.clone(symbol_hint)
            }
            if line.symbol != "??" || line.location != "??" {
                return
            }
            if line.symbol != "" && line.symbol != "??" do delete(line.symbol)
            if line.location != "" && line.location != "??" do delete(line.location)
            ok = false
        }
        if source.addr_alt != "" {
            line, ok = symbolize_message_with(source.exe, source.addr_alt, buf)
            if ok && line.symbol == "??" && symbol_hint != "" {
                line.symbol = strings.clone(symbol_hint)
            }
            if ok do return
        }
        if source.addr_alt != "" {
            line, ok = symbolize_message_with(PROGRAM, source.addr_alt, buf)
            if ok && line.symbol == "??" && symbol_hint != "" {
                line.symbol = strings.clone(symbol_hint)
            }
            if ok do return
        }
        line, ok = symbolize_message_with(PROGRAM, source.addr, buf)
        if ok && line.symbol == "??" && symbol_hint != "" {
            line.symbol = strings.clone(symbol_hint)
        }
        if !ok && symbol_hint != "" {
            line = Line {
                symbol   = strings.clone(symbol_hint),
                location = strings.clone("??"),
            }
            ok = true
        }
        frame_line_cache_store(frame, line, ok)
        return
    }

    symbolize_message_with :: proc(exe, addr: string, buf: []byte) -> (line: Line, ok: bool) {
        if exe == "" || addr == "" do return

        resolved_exe, resolved_ok := symbolizer_exe_resolve(exe)
        if !resolved_ok do return
        defer delete(resolved_exe)

        cmd := make_symbolizer_cmd(resolved_exe, addr)
        defer delete(cmd)

        fp := popen(cmd, "r")
        if fp == nil do return
        defer pclose(fp)

        parsed, line_err := read_message(buf, fp)
        if line_err != nil do return
        line = parsed
        ok = true
        return
    }

    read_message :: proc(buf: []byte, fp: ^libc.FILE) -> (msg: Line, err: Lines_Error) {
        msg.symbol = get_line(buf[:], fp) or_return
        msg.location = get_line(buf[:], fp) or_return
        return
    }

    get_line :: proc(buf: []byte, fp: ^libc.FILE) -> (string, Lines_Error) {
        defer slice.zero(buf)

        got := libc.fgets(raw_data(buf), i32(len(buf)), fp)
        if got == nil {
            if libc.feof(fp) == 0 {
                return "", .Addr2line_Unexpected_EOF
            }
            return "", .Addr2line_Output_Error
        }

        cout := cstring(raw_data(buf))
        if (buf[0] == '?' || buf[0] == ' ') && (buf[1] == '?' || buf[1] == ' ') {
            return "??", nil
        }

        ret := strings.clone_from(cout)
        ret = strings.trim_right_space(ret)
        return ret, nil
    }

    // Parses the address out of a backtrace line.
    // Example: .../main() [0x100000] -> 0x100000
    parse_address :: proc(msg: cstring) -> (string, Lines_Error) {
        multi := ([^]byte)(msg)
        msg_len := len(msg)
        #reverse for c, i in multi[:msg_len] {
            if c == '[' {
                return string(multi[i + 1:msg_len - 1]), nil
            }
        }
        return "", .Parse_Address_Fail
    }

}
