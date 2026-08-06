package examples

import markov "../.."
import jsc "../../../../vendor/jsc"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

SCRIPT_PATH :: "scripts/markov_jsc.js"
SOURCE_NAME :: cstring("markov_jsc.js")

report_jsc_value :: proc(ctx: jsc.JSContextRef, value: jsc.JSValueRef, stderr: bool) {
    // DUMBAI: convert JS values to UTF-8 text so per-lib smoke examples report useful diagnostics.
    text := jsc.ValueToStringCopy(ctx, value, nil)
    if text == nil {
        if stderr {
            fmt.eprintln("<jsc string conversion failed>")
        } else {
            fmt.println("<jsc string conversion failed>")
        }
        return
    }
    defer jsc.StringRelease(text)

    buf_cap := jsc.StringGetMaximumUTF8CStringSize(text)
    if buf_cap == 0 do return
    buf := make([]c.char, int(buf_cap), context.temp_allocator)
    _ = jsc.StringGetUTF8CString(text, raw_data(buf), buf_cap)

    if stderr {
        fmt.eprintln(cstring(raw_data(buf)))
    } else {
        fmt.println(cstring(raw_data(buf)))
    }
}

main :: proc() {
    // DUMBAI: keep JS usage snippets as editable files so each rt module can iterate without rebuilding Odin code.
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

    group := jsc.ContextGroupCreate()
    defer jsc.ContextGroupRelease(group)

    global_ctx := jsc.GlobalContextCreateInGroup(group, nil)
    defer jsc.GlobalContextRelease(global_ctx)

    ctx := jsc.JSContextRef(global_ctx)
    global := jsc.ContextGetGlobalObject(ctx)

    exception: jsc.JSValueRef
    markov.register_markov_jsc_bindings(ctx, global, &exception)
    if exception != nil {
        report_jsc_value(ctx, exception, true)
        os.exit(1)
    }

    source_ref := jsc.StringCreateWithUTF8CString(source_cstr)
    defer jsc.StringRelease(source_ref)
    source_name_ref := jsc.StringCreateWithUTF8CString(SOURCE_NAME)
    defer jsc.StringRelease(source_name_ref)

    result := jsc.EvaluateScript(ctx, source_ref, nil, source_name_ref, 1, &exception)
    if exception != nil {
        report_jsc_value(ctx, exception, true)
        os.exit(1)
    }

    if result != nil && !jsc.ValueIsUndefined(ctx, result) && !jsc.ValueIsNull(ctx, result) {
        report_jsc_value(ctx, result, false)
    }
}
