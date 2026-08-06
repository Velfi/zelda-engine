package backtrace
import "base:runtime"
@(require) import "core:fmt"

when USE_FALLBACK {

    when ODIN_OPTIMIZATION_MODE == .None && !WASM {
        #panic(
            "the `back` package's `other` mode requires at least `-o:minimal` to work (it requires `#force_inline` to actually be applied)",
        )
    }

    @(no_instrumentation)
    other_instrumentation_enter :: #force_inline proc "contextless" (a, b: rawptr, loc: runtime.Source_Code_Location) {
        _other_instrumentation_enter(a, b, loc)
    }

    @(no_instrumentation)
    other_instrumentation_exit :: #force_inline proc "contextless" (a, b: rawptr, loc: runtime.Source_Code_Location) {
        _other_instrumentation_exit(a, b, loc)
    }

    @(private = "package")
    _Trace_Entry :: runtime.Source_Code_Location

    STACK_LOC_CAP :: #config(BACK_OTHER_STACK_LOC_CAP, 1024)

    @(thread_local, private = "file")
    stack_len: int
    @(thread_local, private = "file")
    stack_locs: [STACK_LOC_CAP]runtime.Source_Code_Location

    @(private = "package")
    _trace :: proc(buf: Trace) -> (n: int) #no_bounds_check {
        for i := stack_len - 1; i >= 0 && n < len(buf); i -= 1 {
            buf[n] = stack_locs[i]
            n += 1
        }

        return
    }

    @(private = "package")
    _lines_destroy :: proc(lines: []Line) {
        for line in lines {
            delete(line.location)
        }
    }

    @(private = "package")
    _lines :: proc(bt: Trace) -> (out: []Line, err: Lines_Error) {
        out = make([]Line, len(bt))

        for t, i in bt {
            out[i].symbol = t.procedure
            out[i].location = fmt.aprintf("%s(%v:%v)", t.file_path, t.line, t.column)
        }

        return
    }

    when ODIN_OS != .Linux && ODIN_OS != .Darwin {
        @(private = "package")
        _register_segfault_handler :: proc() {  }
    }

    when OTHER_CUSTOM_INSTRUMENTATION {
        @(no_instrumentation, private = "file")
        _other_instrumentation_enter :: #force_inline proc "contextless" (
            _, _: rawptr,
            loc: runtime.Source_Code_Location,
        ) #no_bounds_check {
            if stack_len < STACK_LOC_CAP {
                stack_locs[stack_len] = loc
                stack_len += 1
            }
        }

        @(no_instrumentation, private = "file")
        _other_instrumentation_exit :: #force_inline proc "contextless" (
            _, _: rawptr,
            loc: runtime.Source_Code_Location,
        ) #no_bounds_check {
            if stack_len > 0 {
                stack_len -= 1
            }
        }
    } else {
        @(instrumentation_enter, private = "file")
        _other_instrumentation_enter :: #force_inline proc "contextless" (
            _, _: rawptr,
            loc: runtime.Source_Code_Location,
        ) #no_bounds_check {
            if stack_len < STACK_LOC_CAP {
                stack_locs[stack_len] = loc
                stack_len += 1
            }
        }

        @(instrumentation_exit, private = "file")
        _other_instrumentation_exit :: #force_inline proc "contextless" (
            _, _: rawptr,
            loc: runtime.Source_Code_Location,
        ) #no_bounds_check {
            if stack_len > 0 {
                stack_len -= 1
            }
        }
    }

}
