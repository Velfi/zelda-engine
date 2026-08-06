#+build !js
#+build !wasi
#+build !orca
#+private
package toml

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

import "base:runtime"
import "dates"

DECODER :: #config(DECODER, false)
ENCODER :: #config(ENCODER, false)
when DECODER || ENCODER {
    Toml_Test_JSON_Value :: union {
        map[string]Toml_Test_JSON_Value,
        []Toml_Test_JSON_Value,
        string,
        bool,
        i64,
        f64,
    }

    main :: proc() {
        if any_of("-parse-example", ..os.args) {
            logln("=========== UNMARSHALING =============")
            unmarshal_example_toml()
            logln("=========== NORMAL PARSING =============")
            parse_example_toml()
            return
        }
        if any_of("-pack", ..os.args) {
            pack_source_files()
            return
        }

        TypedValue :: struct {
            type:  string,
            value: union {
                map[string]UntypedValue,
                []UntypedValue,
                string,
                bool,
                i64,
                f64,
            },
        }
        UntypedValue :: union {
            TypedValue,
            map[string]UntypedValue,
            []UntypedValue,
        }
        when DECODER {
            data := make([]u8, 16 * 1024 * 1024)
            count, err_read := os.read(os.stdin, data)
            assert(err_read == nil || err_read == .EOF)

            table, err := parse(string(data[:count]), "<stdin>")

            if err.type != .None { print_error(err); os.exit(1) }

            idk, ok := _marshal(table)
            if !ok do return

            encoded := marshal_to_json_text(idk)
            logln(encoded)
            delete(encoded)

            deep_delete(table)
            delete_error(&err)

            _marshal :: proc(input: Type) -> (result: UntypedValue, ok: bool) {
                output: TypedValue

                switch value in input {
                case nil:
                    assert(false)
                case ^List:
                    if value == nil do return result, false
                    out := make([]UntypedValue, len(value))
                    for v, i in value { out[i] = _marshal(v) or_continue }
                    return out, true

                case ^Table:
                    if value == nil do return result, false
                    out := make(map[string]UntypedValue)
                    for k, v in value { out[k] = _marshal(v) or_continue }
                    return out, true

                case string:
                    output = {
                        type  = "string",
                        value = value,
                    }
                case bool:
                    output = {
                        type  = "bool",
                        value = fmt.aprint(value),
                    }
                case i64:
                    output = {
                        type  = "integer",
                        value = fmt.aprint(value),
                    }
                case f64:
                    output = {
                        type  = "float",
                        value = fmt.aprint(value),
                    }

                case dates.Date:
                    result, err := dates.partial_date_to_string(date = value, time_sep = 'T')
                    if err != .NONE do os.exit(1) // I shouldn't do this like that...

                    date := value
                    if .time_only in date.flags {
                        output.type = "time-local"
                    } else if .date_only in date.flags {
                        output.type = "date-local"
                    } else if .local_date in date.flags {
                        output.type = "datetime-local"
                    } else {
                        output.type = "datetime"
                    }
                    output.value = result
                }

                return output, true
            }

            marshal_to_json_text :: proc(value: UntypedValue) -> string {
                out: strings.Builder
                write_value(&out, value)
                return strings.to_string(out)

                write_value :: proc(out: ^strings.Builder, value: UntypedValue) {
                    switch v in value {
                    case TypedValue:
                        strings.write_byte(out, '{')
                        write_quoted(out, "type")
                        strings.write_byte(out, ':')
                        write_quoted(out, v.type)
                        strings.write_byte(out, ',')
                        write_quoted(out, "value")
                        strings.write_byte(out, ':')
                        switch x in v.value {
                        case map[string]UntypedValue:
                            write_object(out, x)
                        case []UntypedValue:
                            write_array(out, x)
                        case string:
                            write_quoted(out, x)
                        case bool:
                            if x do strings.write_string(out, "true")
                            else do strings.write_string(out, "false")
                        case i64:
                            fmt.sbprintf(out, "%d", x)
                        case f64:
                            strings.write_string(out, fmt.aprint(x))
                        }
                        strings.write_byte(out, '}')
                    case map[string]UntypedValue:
                        write_object(out, v)
                    case []UntypedValue:
                        write_array(out, v)
                    }
                }

                write_object :: proc(out: ^strings.Builder, value: map[string]UntypedValue) {
                    strings.write_byte(out, '{')
                    first := true
                    for key, item in value {
                        if !first do strings.write_byte(out, ',')
                        first = false
                        write_quoted(out, key)
                        strings.write_byte(out, ':')
                        write_value(out, item)
                    }
                    strings.write_byte(out, '}')
                }

                write_array :: proc(out: ^strings.Builder, value: []UntypedValue) {
                    strings.write_byte(out, '[')
                    for item, i in value {
                        if i > 0 do strings.write_byte(out, ',')
                        write_value(out, item)
                    }
                    strings.write_byte(out, ']')
                }

                write_quoted :: proc(out: ^strings.Builder, raw: string) {
                    strings.write_byte(out, '"')
                    for r in raw {
                        switch r {
                        case '\\':
                            strings.write_string(out, "\\\\")
                        case '"':
                            strings.write_string(out, "\\\"")
                        case '\b':
                            strings.write_string(out, "\\b")
                        case '\f':
                            strings.write_string(out, "\\f")
                        case '\n':
                            strings.write_string(out, "\\n")
                        case '\r':
                            strings.write_string(out, "\\r")
                        case '\t':
                            strings.write_string(out, "\\t")
                        case:
                            if r < 0x20 {
                                fmt.sbprintf(out, "\\u%04X", r)
                            } else {
                                strings.write_rune(out, r)
                            }
                        }
                    }
                    strings.write_byte(out, '"')
                }
            }
        } else when ENCODER {
            data := make([]u8, 16 * 1024 * 1024)
            count, err_read := os.read(os.stdin, data)
            assert(err_read == nil || err_read == .EOF)

            idk: map[string]Toml_Test_JSON_Value
            ensure(json.unmarshal(data[:count], &idk) == nil)

            table := marshal_toml_test_json(&idk)
            logln(emit(table))
            deep_delete(table)
        }
    }

    marshal_toml_test_json :: proc(root: ^map[string]Toml_Test_JSON_Value) -> ^Table {
        table := new(Table)
        if root == nil do return table
        for key, value in root {
            parsed, parsed_ok := marshal_value(value)
            if !parsed_ok do continue
            table[key] = parsed
        }
        return table

        marshal_value :: proc(input: Toml_Test_JSON_Value) -> (result: Type, ok: bool) {
            #partial switch value in input {
            case map[string]Toml_Test_JSON_Value:
                if typed_type, typed_raw, typed_ok := typed_value(value); typed_ok {
                    return marshal_typed_value(typed_type, typed_raw)
                }

                table := new(Table)
                for key, item in value {
                    parsed, parsed_ok := marshal_value(item)
                    if !parsed_ok do continue
                    table[key] = parsed
                }
                return table, true

            case []Toml_Test_JSON_Value:
                list := new(List)
                for item in value {
                    parsed, parsed_ok := marshal_value(item)
                    if !parsed_ok do continue
                    append(list, parsed)
                }
                return list, true

            case string:
                return value, true

            case bool:
                return value, true

            case i64:
                return value, true

            case f64:
                return value, true
            }

            return nil, false
        }

        typed_value :: proc(object: map[string]Toml_Test_JSON_Value) -> (kind, raw: string, ok: bool) {
            if len(object) != 2 do return

            kind_value, has_kind := object["type"]
            raw_value, has_raw := object["value"]
            if !has_kind || !has_raw do return

            kind_string, kind_ok := kind_value.(string)
            raw_string, raw_ok := raw_value.(string)
            if !kind_ok || !raw_ok do return

            return kind_string, raw_string, true
        }

        marshal_typed_value :: proc(kind, raw: string) -> (result: Type, ok: bool) {
            switch kind {
            case "string":
                return raw, true

            case "bool":
                value, parsed := strconv.parse_bool(raw)
                if parsed do return value, true
                return false, false

            case "integer":
                value, parsed := strconv.parse_i64(raw)
                if parsed do return value, true
                return i64(0), false

            case "float":
                value, parsed := parse_toml_float(raw)
                if parsed do return value, true
                return f64(0), false

            case "datetime", "datetime-local", "date-local", "time-local":
                value, err := dates.from_string(raw)
                if err == .NONE do return value, true
                return dates.Date{}, false
            }

            return nil, false
        }

        parse_toml_float :: proc(raw: string) -> (value: f64, ok: bool) {
            if len(raw) >= 2 && any_of(raw[0], '+', '-') && eq(raw[1:], "nan") {
                return f64(0h7FF0_0000_0000_0001), true
            }
            return strconv.parse_f64(raw)
        }
    }

    // packs .odin files into a single libtoml.odin (that still uses the dates library!)
    // useful for Neovim's telescope users
    // and people who don't want to litter their project...
    pack_source_files :: proc() {
        arena: runtime.Arena
        ensure(runtime.arena_init(&arena, 8 * 1024 * 1024) == nil) // 8 megabytes
        alloc := runtime.arena_allocator(&arena)
        context.allocator = alloc
        defer free_all(alloc)

        files :: [?]string {
            "main.odin",
            "toml.odin",
            "unmarshal.odin",
            "tokenizer.odin",
            "validator.odin",
            "parser.odin",
            "misc.odin",
        }

        output_file := "libtoml.odin"

        head: strings.Builder // for package, imports and TOC
        body: strings.Builder // for everything else (decls, ...)

        imports: map[string]struct{}
        contents := make([]string, len(files))
        lengths := make([]int, len(files)) // lines per file (same order as files)

        for file, file_index in files {
            data, err := os.read_entire_file(file, alloc)
            fmt.assertf(
                err == nil,
                "Failed to pack the source files! Received error '%s' when reading '%s'",
                err,
                file,
            )

            temp_text := string(data)
            line_count: int

            for line in strings.split_lines_iterator(&temp_text) {

                if strings.starts_with(line, "package") || strings.starts_with(line, "#+") {
                    continue
                }

                if strings.starts_with(strings.trim_left_space(line), "import ") {
                    imports[line] = {}
                    continue
                }

                line_count += 1
            }

            contents[file_index] = string(data)
            lengths[file_index] = line_count
        }

        // ======================== HEAD ========================

        strings.write_string(&head, "package toml\n")
        strings.write_byte(&head, '\n')

        for import_stmt, _ in imports {
            strings.write_string(&head, import_stmt)
            strings.write_byte(&head, '\n')
        }
        strings.write_byte(&head, '\n')

        toc_banner := "// ======================== TABLE OF CONTENTS ========================\n"
        strings.write_string(&head, toc_banner) // + 1
        toc_cursor := 8 + len(imports) + len(files)
        for file, file_index in files {
            padding := strings.repeat(
                ".",
                max(len(toc_banner) - 3 - 4 - len(file) - int(math.log10(f32(toc_cursor)) + 1), 4),
            )
            fmt.sbprintfln(&head, "// %d. %s%s%d", file_index + 1, file, padding, toc_cursor)
            toc_cursor += lengths[file_index]
            toc_cursor += 6 // "\n\n === FILE NAME === \n\n"
        }
        strings.write_string(&head, "// ===================================================================\n")

        // ======================== BODY ========================

        for file, file_index in files {
            lhs_padding := strings.repeat("=", (max(42 - len(file), 1)) / 2)
            rhs_padding := strings.repeat("=", (max(43 - len(file), 0)) / 2)

            strings.write_string(&body, "\n\n// ================================================\n")
            fmt.sbprintf(&body, "// %s   %s   %s", lhs_padding, file, rhs_padding)
            strings.write_string(&body, "\n// ================================================\n\n")

            temp_text := string(contents[file_index])
            for line in strings.split_lines_iterator(&temp_text) {
                trimmed_line := strings.trim_left_space(line)

                if strings.starts_with(trimmed_line, "package ") ||
                   strings.starts_with(trimmed_line, "import ") ||
                   strings.starts_with(trimmed_line, "#+") {
                    continue
                }

                strings.write_string(&body, line)
                strings.write_byte(&body, '\n')
            }
        }

        // fmt.println(string(head.buf[:]))
        // fmt.println(string(body.buf[:]))
        strings.write_bytes(&head, body.buf[:])
        err := os.write_entire_file(output_file, head.buf[:])
        fmt.assertf(err == nil, "Failed to write to the output file -- %s with error %v", output_file, err)

    }

    unmarshal_example_toml :: proc() {
        value: struct {
            integer:  int,
            num:      f32,
            infinity: f64,
            mstr:     string `toml:"multiline_str"`,
            a:        struct {
                b: string,
            },
            c:        struct {
                d: string,
            },
            // rest of values in example.toml
            // are ignored by unmarshal_table
        }

        table, err1 := parse_file("example.toml")
        value_ptr := &value
        value_ptr_ptr := &value_ptr
        err2 := unmarshal_table(&value_ptr_ptr, table) // <-- btw, you should take 0 references of value, not 3.

        print_error(err1)
        assert(err2 == .None)

        logln(value)
    }

    parse_example_toml :: proc() {
        table, err := parse_file("example.toml")
        print_error(err)
        print_table(table)
    }
}
