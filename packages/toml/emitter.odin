package toml

import "core:fmt"
import "core:strings"

import "dates"

emit :: proc(tokens: ^Table) -> string {
    if tokens == nil || len(tokens^) == 0 do return ""

    out: strings.Builder
    write_table(&out, nil, tokens, true)

    return strings.to_string(out)

    write_table :: proc(out: ^strings.Builder, path: []string, table: ^Table, root: bool) {
        if table == nil do return

        keys := sorted_keys(table)
        defer delete(keys)

        if !root {
            write_section_header(out, path)
        }

        wrote_inline := false
        for key in keys {
            if _, ok := table[key].(^Table); ok do continue

            write_key(out, key)
            strings.write_string(out, " = ")
            write_value(out, table[key])
            strings.write_byte(out, '\n')
            wrote_inline = true
        }

        wrote_child := false
        for key in keys {
            child, ok := table[key].(^Table)
            if !ok do continue

            if len(out.buf) > 0 && (wrote_inline || wrote_child || root) {
                strings.write_byte(out, '\n')
            }
            child_path := append_path(path, key)
            write_table(out, child_path, child, false)
            delete(child_path)
            wrote_child = true
        }
    }

    write_value :: proc(out: ^strings.Builder, value: Type) {
        #partial switch v in value {
        case ^Table:
            write_inline_table(out, v)
        case ^List:
            write_list(out, v)
        case string:
            write_key(out, v)
        case bool:
            if v do strings.write_string(out, "true")
            else do strings.write_string(out, "false")
        case i64:
            fmt.sbprintf(out, "%d", v)
        case f64:
            write_float(out, v)
        case dates.Date:
            raw, err := dates.partial_date_to_string(date = v, time_sep = 'T')
            if err != .NONE {
                write_key(out, "")
            } else {
                defer delete_string(raw)
                strings.write_string(out, raw)
            }
        }
    }

    sorted_keys :: proc(table: ^Table) -> [dynamic]string {
        keys := make([dynamic]string, 0, len(table^))
        for key in table {
            append(&keys, key)
        }

        for i := 1; i < len(keys); i += 1 {
            j := i
            for j > 0 && keys[j - 1] > keys[j] {
                keys[j - 1], keys[j] = keys[j], keys[j - 1]
                j -= 1
            }
        }
        return keys
    }

    append_path :: proc(path: []string, key: string) -> []string {
        out := make([]string, len(path) + 1)
        copy(out[:], path[:])
        out[len(path)] = key
        return out
    }

    is_leaf_table :: proc(table: ^Table) -> bool {
        if table == nil do return true
        for _, value in table {
            if _, ok := value.(^Table); ok do return false
        }
        return true
    }

    write_key :: proc(out: ^strings.Builder, raw: string) {
        strings.write_byte(out, '"')
        write_escaped(out, raw)
        strings.write_byte(out, '"')
    }

    write_section_header :: proc(out: ^strings.Builder, path: []string) {
        strings.write_byte(out, '[')
        for part, i in path {
            if i > 0 do strings.write_byte(out, '.')
            write_key(out, part)
        }
        strings.write_string(out, "]\n")
    }

    write_inline_table :: proc(out: ^strings.Builder, table: ^Table) {
        strings.write_byte(out, '{')
        if table != nil {
            keys := sorted_keys(table)
            defer delete(keys)
            first := true
            for key in keys {
                value := table[key]
                if !first do strings.write_string(out, ", ")
                first = false

                write_key(out, key)
                strings.write_string(out, " = ")
                write_value(out, value)
            }
        }
        strings.write_byte(out, '}')
    }

    write_list :: proc(out: ^strings.Builder, list: ^List) {
        strings.write_byte(out, '[')
        if list != nil {
            for value, i in list {
                if i > 0 do strings.write_string(out, ", ")
                write_value(out, value)
            }
        }
        strings.write_byte(out, ']')
    }

    write_float :: proc(out: ^strings.Builder, value: f64) {
        bits := transmute(u64)value
        abs_bits := bits & 0x7FFF_FFFF_FFFF_FFFF

        if abs_bits == 0x7FF0_0000_0000_0000 {
            if bits & 0x8000_0000_0000_0000 != 0 {
                strings.write_string(out, "-inf")
            } else {
                strings.write_string(out, "inf")
            }
            return
        }
        if abs_bits > 0x7FF0_0000_0000_0000 {
            if bits & 0x8000_0000_0000_0000 != 0 {
                strings.write_string(out, "-nan")
            } else {
                strings.write_string(out, "nan")
            }
            return
        }

        raw := fmt.aprint(value)
        defer delete_string(raw)
        strings.write_string(out, raw)
        if strings.contains_rune(raw, '.') || strings.contains_rune(raw, 'e') || strings.contains_rune(raw, 'E') do return
        strings.write_string(out, ".0")
    }

    write_escaped :: proc(out: ^strings.Builder, raw: string) {
        for r in raw {
            switch r {
            case '"':
                strings.write_string(out, "\\\"")
            case '\\':
                strings.write_string(out, "\\\\")
            case '\b':
                strings.write_string(out, "\\b")
            case '\t':
                strings.write_string(out, "\\t")
            case '\n':
                strings.write_string(out, "\\n")
            case '\f':
                strings.write_string(out, "\\f")
            case '\r':
                strings.write_string(out, "\\r")
            case:
                if r < 32 || r == 127 {
                    if r <= 0xFFFF {
                        fmt.sbprintf(out, "\\u%04X", r)
                    } else {
                        fmt.sbprintf(out, "\\U%08X", r)
                    }
                } else {
                    strings.write_rune(out, r)
                }
            }
        }
    }
}
