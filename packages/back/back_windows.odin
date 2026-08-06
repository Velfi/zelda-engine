#+build windows
#+private
package backtrace

import "base:runtime"

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

import "pdb"

when !USE_FALLBACK {

    _Trace_Entry :: pdb.StackFrame

    _trace :: proc(buf: Trace) -> (n: int) {
        return int(pdb.capture_stack_trace(buf))
    }

    _lines_destroy :: proc(msgs: []Line) {
        for msg in msgs {
            delete(msg.location)
            delete(msg.symbol)
        }
        delete(msgs)
    }

    stack_frames_to_lines :: proc(frames: []pdb.StackFrame) -> (out: []Line) {
        out = make([]Line, len(frames))
        for frame, i in frames {
            out[i] = {
                symbol   = "??",
                location = fmt.aprintf(
                    "pc=0x%x image=0x%x func=[0x%x,0x%x)",
                    frame.progCounter,
                    frame.imgBaseAddr,
                    frame.funcBegin,
                    frame.funcEnd,
                ),
            }
        }
        return
    }

    _lines :: proc(bt: Trace) -> (out: []Line, err: Lines_Error) {
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = context.allocator == context.temp_allocator)

        rb: pdb.RingBuffer(runtime.Source_Code_Location)
        pdb.init_rb(&rb, len(bt))
        defer delete(rb.data)

        {
            context.allocator = context.temp_allocator
            if pdb.parse_stack_trace(bt, true, &rb) {
                out = stack_frames_to_lines(bt)
                return
            }
        }

        out = make([]Line, len(bt))
        for &msg, i in out {
            loc := pdb.get_rb(&rb, i)
            msg.symbol = strings.clone(loc.procedure)

            lb := strings.builder_make_len_cap(0, len(loc.file_path) + 5)
            strings.write_string(&lb, loc.file_path)
            strings.write_byte(&lb, ':')
            strings.write_int(&lb, int(loc.line))
            msg.location = strings.to_string(lb)
        }

        return
    }

    _register_segfault_handler :: proc() {
        pdb.SetUnhandledExceptionFilter(proc "stdcall" (exception_info: ^win.EXCEPTION_POINTERS) -> win.LONG {
            context = runtime.default_context()
            context.allocator = context.temp_allocator

            summary := "Exception"
            fmt.eprint("Exception ")
            if exception_info.ExceptionRecord != nil {
                fmt.eprintf(
                    "(Type: %x, Flags: %x)\n",
                    exception_info.ExceptionRecord.ExceptionCode,
                    exception_info.ExceptionRecord.ExceptionFlags,
                )
                summary = fmt.aprintf(
                    "Exception (Type: %x, Flags: %x)",
                    exception_info.ExceptionRecord.ExceptionCode,
                    exception_info.ExceptionRecord.ExceptionFlags,
                )
            }

            ctxt := cast(^pdb.CONTEXT)exception_info.ContextRecord

            trace_buf: [BACKTRACE_SIZE]pdb.StackFrame
            trace_count := pdb.capture_stack_trace_from_context(ctxt, trace_buf[:])

            src_code_locs: pdb.RingBuffer(runtime.Source_Code_Location)
            pdb.init_rb(&src_code_locs, BACKTRACE_SIZE)

            no_debug_info_found := pdb.parse_stack_trace(trace_buf[:trace_count], true, &src_code_locs)
            if no_debug_info_found {
                fallback_lines := stack_frames_to_lines(trace_buf[:trace_count])
                emit_crash_callback(.Segfault, summary, fallback_lines)
                fmt.eprintln("[back trace]")
                print(fallback_lines)
                fmt.eprintln("Could not resolve Windows debug symbols; showing raw stack addresses.")
                return win.EXCEPTION_CONTINUE_SEARCH
            }

            fmt.eprintln("[back trace]")

            lines: [BACKTRACE_SIZE]Line
            for i in 0 ..< src_code_locs.len {
                loc := pdb.get_rb(&src_code_locs, i)

                lb := strings.builder_make_len_cap(0, len(loc.file_path) + 5)
                strings.write_string(&lb, loc.file_path)
                strings.write_byte(&lb, ':')
                strings.write_int(&lb, int(loc.line))

                lines[i] = {
                    location = strings.to_string(lb),
                    symbol   = loc.procedure,
                }
            }
            emit_crash_callback(.Segfault, summary, lines[:src_code_locs.len])
            print(lines[:src_code_locs.len])

            return win.EXCEPTION_CONTINUE_SEARCH
        })
    }

}
