#+build linux, darwin
package backtrace

import "core:c/libc"

import "base:runtime"
import "core:fmt"
import "core:os"

@(private = "package")
_register_segfault_handler :: proc() {
    libc.signal(libc.SIGSEGV, proc "c" (code: i32) {
        context = runtime.default_context()
        context.allocator = context.temp_allocator

        summary := fmt.aprintf("Exception (Code: %i)", code)
        backtrace: {
            t := trace()
            lines, err := lines(t.trace[:t.len])
            if err != nil {
                emit_crash_callback(.Segfault, summary)
                fmt.eprintf("Exception (Code: %i)\nCould not get backtrace: %v\n", code, err)
                break backtrace
            }

            emit_crash_callback(.Segfault, summary, lines)
            fmt.eprintf("Exception (Code: %i)\n[back trace]\n", code)
            print(lines)
        }

        os.exit(int(code))
    })
}
