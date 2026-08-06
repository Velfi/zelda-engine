#+build js
package example

import "core:encoding/xml"
import "core:fmt"
import "core:strconv"

import mk "../.."

PALETTE_XML :: #load("../../resources/palette.xml")

palette_get_attr :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string) -> (string, bool) {
    for attr in doc.elements[elem_id].attribs {
        if attr.key == key {
            return attr.val, true
        }
    }
    return "", false
}

palette_get_children :: proc(doc: ^xml.Document, elem_id: xml.Element_ID) -> []xml.Element_ID {
    result := make([dynamic]xml.Element_ID, context.temp_allocator)
    for v in doc.elements[elem_id].value {
        #partial switch e in v {
        case xml.Element_ID:
            append(&result, e)
        }
    }
    return result[:]
}

ensure_markov_root :: proc() -> bool {
    // Web builds run from packaged assets, so cwd probing is unnecessary.
    return true
}

load_example_palette :: proc() -> mk.Palette {
    // Parse embedded palette XML because filesystem-based palette loading is unavailable on js/wasm.
    palette := make(mk.Palette, 256)
    doc, err := xml.parse_bytes(PALETTE_XML, allocator = context.temp_allocator)
    if err != .None || doc == nil {
        return palette
    }
    defer xml.destroy(doc, allocator = context.temp_allocator)

    for child_id in palette_get_children(doc, 0) {
        elem := doc.elements[child_id]
        if elem.ident != "color" {
            continue
        }
        sym_str, sym_ok := palette_get_attr(doc, child_id, "symbol")
        value_str, val_ok := palette_get_attr(doc, child_id, "value")
        if !sym_ok || !val_ok || len(sym_str) == 0 || len(value_str) == 0 {
            continue
        }

        value, ok := strconv.parse_int(value_str, 16)
        if !ok {
            continue
        }
        palette[sym_str[0]] = cast(i32)u32((0xff << 24) | u32(value))
    }
    return palette
}

initial_model_name :: proc() -> string {
    return "Basic"
}

compile_failure_status :: proc(name: string) -> string {
    return fmt.tprintf("compile failed: %s", name)
}
