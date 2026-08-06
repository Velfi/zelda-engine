package examples

import markov "../.."
import v8 "../../../../vendor/v8"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

SCRIPT_PATH :: "scripts/markov_v8.js"
SOURCE_NAME :: cstring("markov_v8.js")

print_v8_error :: proc(err: ^v8.Error) {
    // DUMBAI: print rich V8 diagnostics so failing usage examples are actionable.
    fmt.eprintf("V8 exception at %d:%d: %s\n", err.line, err.column, cstring(&err.message[0]))
    if err.stack[0] != 0 {
        fmt.eprintln(cstring(&err.stack[0]))
    }
}

main :: proc() {
    // DUMBAI: load per-lib JS snippets from disk so users can edit usage quickly.
    source_bytes, read_err := os.read_entire_file_from_path(SCRIPT_PATH, context.allocator)
    if read_err != os.ERROR_NONE {
        fmt.eprintf("Failed to read %s: %v\n", SCRIPT_PATH, read_err)
        os.exit(1)
    }
    defer delete(source_bytes)

    source_cstr, cerr := strings.clone_to_cstring(string(source_bytes), context.temp_allocator)
    if cerr != nil {
        fmt.eprintln("Failed to convert script to cstring")
        os.exit(1)
    }

    if v8.initialize(nil, nil, nil) == 0 {
        fmt.eprintln("v8.initialize failed")
        os.exit(1)
    }
    defer v8.shutdown()

    isolate := v8.isolate_new()
    if isolate == nil {
        fmt.eprintln("v8.isolate_new failed")
        os.exit(1)
    }
    defer v8.isolate_dispose(isolate)

    ctx := v8.context_new(isolate)
    if ctx == nil {
        fmt.eprintln("v8.context_new failed")
        os.exit(1)
    }
    defer v8.context_dispose(ctx)

    if !markov.register_markov_v8_bindings(isolate, ctx) {
        fmt.eprintln("register_markov_v8_bindings failed")
        os.exit(1)
    }

    out: [8192]c.char
    out_len: c.size_t
    js_err: v8.Error

    ok := v8.run_script_utf8(
        isolate,
        ctx,
        source_cstr,
        SOURCE_NAME,
        &js_err,
        raw_data(out[:]),
        c.size_t(len(out)),
        &out_len,
    )
    if ok == 0 {
        print_v8_error(&js_err)
        os.exit(1)
    }

    if out_len >= c.size_t(len(out)) {
        out[len(out) - 1] = 0
    } else {
        out[int(out_len)] = 0
    }
    if out[0] != 0 {
        fmt.println(cstring(&out[0]))
    }
}
