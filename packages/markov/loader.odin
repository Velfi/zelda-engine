package markov
import "base:runtime"

import "core:encoding/xml"
import "core:log"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

// Helper to get attribute value from element
get_attr :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string) -> (string, bool) {
    elem := doc.elements[elem_id]
    for attr in elem.attribs {
        if attr.key == key {
            return attr.val, true
        }
    }
    return "", false
}

get_attr_int :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string, default_val: int = 0) -> int {
    if val, ok := get_attr(doc, elem_id, key); ok {
        result, _ := strconv.parse_int(val)
        return result
    }
    return default_val
}

get_attr_float :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string, default_val: f64 = 0.0) -> f64 {
    if val, ok := get_attr(doc, elem_id, key); ok {
        result, _ := strconv.parse_f64(val)
        return result
    }
    return default_val
}

get_attr_bool :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string, default_val: bool = false) -> bool {
    if val, ok := get_attr(doc, elem_id, key); ok {
        return val == "True" || val == "true"
    }
    return default_val
}

get_attr_typed_int :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string) -> (int, bool) {
    if value, ok := proc_doc_typed_value(doc, elem_id, key); ok {
        #partial switch v in value {
        case int:
            return v, true
        }
    }
    return 0, false
}

get_attr_symbol :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string) -> (u8, bool) {
    if syms, ok := typed_attr_symbols(doc, elem_id, key); ok {
        chars := cast([]u8)syms
        if len(chars) > 0 {
            return chars[0], true
        }
    }
    if val, ok := get_attr(doc, elem_id, key); ok && len(val) > 0 {
        return val[0], true
    }
    return 0, false
}

get_attr_symbol_value :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string, grid: ^Grid) -> (u8, bool) {
    if typed_val, ok := get_attr_typed_int(doc, elem_id, key); ok {
        if typed_val >= 0 && typed_val < int(grid.c) {
            return u8(typed_val), true
        }
        return 0, false
    }
    if syms, ok := typed_attr_symbols(doc, elem_id, key); ok {
        chars := cast([]u8)syms
        if len(chars) > 0 {
            value := grid.values[chars[0]]
            if value != 0xff {
                return value, true
            }
            return 0, false
        }
    }
    if val, ok := get_attr(doc, elem_id, key); ok && len(val) > 0 {
        value := grid.values[val[0]]
        if value != 0xff {
            return value, true
        }
    }
    return 0, false
}

get_attr_wave :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string, grid: ^Grid) -> (int, bool) {
    if typed_wave, ok := get_attr_typed_int(doc, elem_id, key); ok {
        if typed_wave < 0 {
            return 0, false
        }
        all_wave := (1 << uint(grid.c)) - 1
        if (typed_wave & ~all_wave) != 0 {
            return 0, false
        }
        return typed_wave, true
    }
    if syms, ok := typed_attr_symbols(doc, elem_id, key); ok {
        return grid_wave_symbols(grid, syms), true
    }
    if val, ok := get_attr(doc, elem_id, key); ok {
        return grid_wave(grid, val), true
    }
    return 0, false
}

first_symbol_from_wave :: proc(wave: int, c: int) -> (u8, bool) {
    if wave <= 0 {
        return 0, false
    }
    for i in 0 ..< c {
        if (wave & (1 << uint(i))) != 0 {
            return u8(i), true
        }
    }
    return 0, false
}

get_attr_symmetry_mask :: proc(
    doc: ^xml.Document,
    elem_id: xml.Element_ID,
    is_2d: bool,
    dflt: Symmetry_Mask,
) -> (
    Symmetry_Mask,
    bool,
) {
    if typed_mask, has_typed := typed_attr_symmetry(doc, elem_id, "symmetry"); has_typed {
        mask := typed_mask.mask
        if !symmetry_valid_mask(mask, is_2d) {
            bits := is_2d ? SYMMETRY_2D_BITS : SYMMETRY_3D_BITS
            log.errorf("typed symmetry mask contains bits outside %d-bit range", bits)
            return Symmetry_Mask(0), false
        }
        return mask, true
    }

    sym_str, has_string := get_attr(doc, elem_id, "symmetry")
    if !has_string {
        return dflt, true
    }

    symmetry, ok := get_symmetry(is_2d, sym_str, dflt)
    if !ok {
        log.errorf("unknown symmetry %s", sym_str)
        return Symmetry_Mask(0), false
    }
    return symmetry, true
}

// Get children of an element (returns child Element_IDs)
get_children :: proc(doc: ^xml.Document, elem_id: xml.Element_ID) -> []xml.Element_ID {
    elem := doc.elements[elem_id]
    result := make([dynamic]xml.Element_ID, context.temp_allocator)
    for v in elem.value {
        #partial switch e in v {
        case xml.Element_ID:
            append(&result, e)
        }
    }
    return result[:]
}

// Get children by name
get_children_by_name :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, name: string) -> []xml.Element_ID {
    result := make([dynamic]xml.Element_ID, context.temp_allocator)
    for child_id in get_children(doc, elem_id) {
        elem := doc.elements[child_id]
        if elem.ident == name {
            append(&result, child_id)
        }
    }
    return result[:]
}

// Node names that we recognize
NODE_NAMES :: []string{"one", "all", "prl", "markov", "sequence", "path", "map", "convolution", "convchain", "wfc"}

is_node_name :: proc(name: string) -> bool {
    for n in NODE_NAMES {
        if n == name { return true }
    }
    return false
}

// Load union elements from the document tree (following markov, sequence, union elements)
load_unions :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, grid: ^Grid) {
    // Use BFS to find all union elements, only following markov/sequence/union containers
    queue := make([dynamic]xml.Element_ID, context.temp_allocator)
    append(&queue, elem_id)

    for len(queue) > 0 {
        current := queue[0]
        ordered_remove(&queue, 0)

        elem := doc.elements[current]

        // If this is a union, process it
        if elem.ident == "union" && current != elem_id {
            symbol, sym_ok := get_attr_symbol(doc, current, "symbol")
            values_wave, val_ok := get_attr_wave(doc, current, "values", grid)

            if sym_ok && val_ok {
                if grid.waves[symbol] != 0 {
                    log.warnf("repeating union type '%c'", symbol)
                } else {
                    grid.waves[symbol] = values_wave
                }
            }
        }

        // Enqueue children that are markov, sequence, or union
        for child_id in get_children(doc, current) {
            child_elem := doc.elements[child_id]
            if child_elem.ident == "markov" || child_elem.ident == "sequence" || child_elem.ident == "union" {
                append(&queue, child_id)
            }
        }
    }
}

// Get node children (elements that are node types)
get_node_children :: proc(doc: ^xml.Document, elem_id: xml.Element_ID) -> []xml.Element_ID {
    result := make([dynamic]xml.Element_ID, context.temp_allocator)
    for child_id in get_children(doc, elem_id) {
        elem := doc.elements[child_id]
        if is_node_name(elem.ident) {
            append(&result, child_id)
        }
    }
    return result[:]
}

// Load palette.xml
Palette :: map[u8]i32
load_xml_document :: proc(filename: string, allocator := context.allocator) -> (^xml.Document, xml.Error) {
    data, ok := read_markov_file(filename, context.temp_allocator)
    if !ok {
        return nil, .File_Error
    }
    return xml.parse_bytes(data, xml.DEFAULT_OPTIONS, filename, xml.default_error_handler, allocator)
}

load_palette :: proc(filename: string, allocator := context.allocator) -> Palette {
    palette := make(Palette, 256, allocator)

    doc, err := load_xml_document(filename, allocator = context.temp_allocator)
    if err != .None {
        log.errorf("Failed to load palette: %s %v", filename, err)
        return palette
    }
    defer xml.destroy(doc, allocator = context.temp_allocator)

    if doc.element_count > 0 {
        children := get_children(doc, 0)
        for child_id in children {
            elem := doc.elements[child_id]
            if elem.ident == "color" {
                symbol: u8 = 0
                value_str: string = ""
                sym_str, sym_ok := get_attr(doc, child_id, "symbol")
                if sym_ok && len(sym_str) > 0 {
                    symbol = sym_str[0]
                }
                value_str, _ = get_attr(doc, child_id, "value")
                if symbol != 0 && len(value_str) > 0 {
                    val, _ := strconv.parse_int(value_str, 16)
                    palette[symbol] = cast(i32)u32((0xff << 24) | u32(val))
                }
            }
        }
    }

    return palette
}

// Model configuration
Model_Config :: struct {
    name:       string,
    size:       [3]int,
    amount:     int,
    pixel_size: int,
    seeds:      [dynamic]int,
    gif:        bool,
    iso:        bool,
    steps:      int,
    gui:        int,
    colors:     Palette,
}

load_models_list :: proc(filename: string, allocator := context.allocator) -> [dynamic]Model_Config {
    models := make([dynamic]Model_Config, allocator)

    doc, err := load_xml_document(filename, allocator = context.temp_allocator)
    if err != .None {
        log.errorf("Failed to load models list: %s %v", filename, err)
        return models
    }
    defer xml.destroy(doc, allocator = context.temp_allocator)

    if doc.element_count > 0 {
        children := get_children(doc, 0)
        for child_id in children {
            elem := doc.elements[child_id]
            if elem.ident == "model" {
                config: Model_Config
                config.size = {16, 16, 1}
                config.amount = 1
                config.pixel_size = 4
                config.colors = make(Palette, allocator)

                if name, ok := get_attr(doc, child_id, "name"); ok {
                    config.name = strings.clone(name, allocator)
                }
                if size_str, ok := get_attr(doc, child_id, "size"); ok {
                    size, _ := strconv.parse_int(size_str)
                    config.size = {size, size, 1}
                }
                config.size.x = get_attr_int(doc, child_id, "length", config.size.x)
                config.size.y = get_attr_int(doc, child_id, "width", config.size.y)
                config.size.z = get_attr_int(doc, child_id, "height", config.size.z)
                if d := get_attr_int(doc, child_id, "d", 0); d == 3 {
                    config.size.z = config.size.x
                }
                config.amount = get_attr_int(doc, child_id, "amount", config.amount)
                config.pixel_size = get_attr_int(doc, child_id, "pixelsize", config.pixel_size)
                config.gif = get_attr_bool(doc, child_id, "gif")
                config.iso = get_attr_bool(doc, child_id, "iso")
                // Match C#: default steps is 1000 for gif, 50000 otherwise
                default_steps := config.gif ? 1000 : 50000
                config.steps = get_attr_int(doc, child_id, "steps", default_steps)
                config.gui = get_attr_int(doc, child_id, "gui", 0)

                if val, ok := get_attr(doc, child_id, "seeds"); ok {
                    config.seeds = make([dynamic]int, allocator)
                    parts := strings.split(val, " ", context.temp_allocator)
                    for part in parts {
                        if len(part) > 0 {
                            seed_val, parse_ok := strconv.parse_int(part)
                            if parse_ok {
                                append(&config.seeds, seed_val)
                            }
                        }
                    }
                }

                for model_child in get_children(doc, child_id) {
                    model_child_elem := doc.elements[model_child]
                    if model_child_elem.ident != "color" {
                        continue
                    }

                    sym_str, sym_ok := get_attr(doc, model_child, "symbol")
                    value_str, value_ok := get_attr(doc, model_child, "value")
                    if !sym_ok || !value_ok || len(sym_str) == 0 {
                        continue
                    }

                    color_val, parse_ok := strconv.parse_int(value_str, 16)
                    if parse_ok {
                        config.colors[sym_str[0]] = cast(i32)u32((0xff << 24) | u32(color_val))
                    }
                }

                append(&models, config)
            }
        }
    }

    return models
}

// Parse a rule pattern string like "BWW/BBW" into char array and dimensions
// Format: space separates z-layers, '/' separates y-rows within a layer
// Example 2D: "BWW/BBW" = 2 rows, 3 cols
// Example 3D: "***/***/** ***/*W*/*** ***/***/***" = 3 z-layers
parse_pattern :: proc(s: string) -> (data: []u8, m: [3]int, ok: bool) {
    if len(s) == 0 {
        return nil, {}, false
    }

    // Split by space for z-layers (3D)
    z_layers := strings.split(s, " ", context.temp_allocator)
    mz := len(z_layers)

    // Parse first layer to get my and mx
    // Split by '/' for y-rows within a layer
    first_rows := strings.split(z_layers[0], "/", context.temp_allocator)
    my := len(first_rows)
    mx := len(first_rows[0])

    result := make([]u8, mx * my * mz, context.temp_allocator)

    for zi in 0 ..< mz {
        // Flip Z-axis to match C# implementation (reads from bottom to top)
        rows := strings.split(z_layers[mz - 1 - zi], "/", context.temp_allocator)
        if len(rows) != my {
            log.errorf("non-rectangular pattern in z-layer %d: expected %d rows, got %d", zi, my, len(rows))
            return nil, {}, false
        }
        for yi in 0 ..< my {
            row := rows[yi]
            if len(row) != mx {
                log.errorf("non-rectangular pattern in row %d: expected %d cols, got %d", yi, mx, len(row))
                return nil, {}, false
            }
            for xi in 0 ..< mx {
                result[xi + yi * mx + zi * mx * my] = row[xi]
            }
        }
    }

    return result, {mx, my, mz}, true
}

// Load a pattern from a file (PNG for 2D, VOX for 3D)
// Returns char data mapped via legend, and dimensions
load_resource :: proc(filename: string, legend: string, d2: bool) -> ([]u8, [3]int, bool) {
    if len(legend) == 0 {
        log.errorf("no legend for %s", filename)
        return nil, {}, false
    }

    data: []i32
    m: [3]int
    ok: bool

    if d2 {
        data, m, ok = load_bitmap(filename, context.temp_allocator)
    } else {
        data, m, ok = load_vox(filename, context.temp_allocator)
    }

    if !ok {
        log.errorf("couldn't read %s", filename)
        return nil, m, false
    }

    // Convert colors to ordinals
    ord_data, amount := ords(data, context.temp_allocator)

    if amount > len(legend) {
        log.errorf("the amount of colors %d in %s is more than legend length %d", amount, filename, len(legend))
        return nil, m, false
    }

    // Map ordinals to legend characters
    result := make([]u8, len(ord_data), context.temp_allocator)
    for i in 0 ..< len(ord_data) {
        result[i] = legend[ord_data[i]]
    }

    return result, m, true
}

// Build file path for rule resource
rule_filepath :: proc(grid: ^Grid, name: string) -> string {
    sb := strings.builder_make(context.temp_allocator)
    strings.write_string(&sb, "resources/rules/")
    if len(grid.folder) > 0 {
        strings.write_string(&sb, grid.folder)
        strings.write_string(&sb, "/")
    }
    strings.write_string(&sb, name)
    if grid.m.z == 1 {
        strings.write_string(&sb, ".png")
    } else {
        strings.write_string(&sb, ".vox")
    }
    return strings.to_string(sb)
}

// Load a single rule from XML
load_rule :: proc(
    doc: ^xml.Document,
    rule_id: xml.Element_ID,
    grid: ^Grid,
    symmetry: Symmetry_Mask,
    allocator := context.allocator,
) -> (
    []Rule,
    bool,
) {
    in_str, in_ok := get_attr(doc, rule_id, "in")
    out_str, out_ok := get_attr(doc, rule_id, "out")
    in_pattern, has_in_pattern := typed_attr_pattern(doc, rule_id, "in")
    out_pattern, has_out_pattern := typed_attr_pattern(doc, rule_id, "out")
    in_match_pattern, has_in_match_pattern := typed_attr_match_pattern(doc, rule_id, "in")
    out_write_pattern, has_out_write_pattern := typed_attr_write_pattern(doc, rule_id, "out")
    fin_str, fin_ok := get_attr(doc, rule_id, "fin")
    fout_str, fout_ok := get_attr(doc, rule_id, "fout")
    file_str, file_ok := get_attr(doc, rule_id, "file")
    legend, _ := get_attr(doc, rule_id, "legend")

    in_data: []u8
    out_data: []u8
    input: []int
    output: []u8
    input_owned := false
    output_owned := false
    defer {
        if input_owned do delete(input, allocator)
        if output_owned do delete(output, allocator)
    }
    im, om: [3]int
    input_direct := false
    output_direct := false
    d2 := grid.m.z == 1

    if file_ok {
        // File-based rule: left half is input, right half is output
        if in_ok || fin_ok || out_ok || fout_ok {
            log.error("rule already contains a file attribute")
            return nil, false
        }

        filepath := rule_filepath(grid, file_str)
        rect, fm, rect_ok := load_resource(filepath, legend, d2)
        if !rect_ok {
            return nil, false
        }

        if fm.x % 2 != 0 {
            log.errorf("odd width %d in %s", fm.x, file_str)
            return nil, false
        }

        // Split into left (input) and right (output) halves
        half_x := fm.x / 2
        im = {half_x, fm.y, fm.z}
        om = im

        in_data = make([]u8, half_x * fm.y * fm.z, context.temp_allocator)
        out_data = make([]u8, half_x * fm.y * fm.z, context.temp_allocator)

        for z in 0 ..< fm.z {
            for y in 0 ..< fm.y {
                for x in 0 ..< half_x {
                    idx := x + y * half_x + z * half_x * fm.y
                    in_data[idx] = rect[x + y * fm.x + z * fm.x * fm.y]
                    out_data[idx] = rect[x + half_x + y * fm.x + z * fm.x * fm.y]
                }
            }
        }
    } else {
        // String-based rules (in/out, fin/fout)
        if !in_ok && !fin_ok && !has_in_match_pattern {
            log.error("no input in rule")
            return nil, false
        }
        if !out_ok && !fout_ok && !has_out_write_pattern {
            log.error("no output in rule")
            return nil, false
        }

        in_parse_ok: bool
        if has_in_match_pattern {
            input_direct = true
            im = in_match_pattern.m
            input = make([]int, len(in_match_pattern.data), allocator)
            input_owned = true
            all_wave := (1 << uint(grid.c)) - 1
            for wave, i in in_match_pattern.data {
                if wave == PROC_MATCH_ANY {
                    input[i] = all_wave
                    continue
                }
                if wave <= 0 {
                    log.errorf("invalid direct input wave %d in rule", wave)
                    return nil, false
                }
                if (wave & ~all_wave) != 0 {
                    log.errorf("direct input wave %d references symbols outside current values", wave)
                    return nil, false
                }
                input[i] = wave
            }
            in_parse_ok = true
        } else if in_ok {
            if has_in_pattern {
                in_data = in_pattern.data
                im = in_pattern.m
                in_parse_ok = true
            } else {
                in_data, im, in_parse_ok = parse_pattern(in_str)
            }
        } else {
            filepath := rule_filepath(grid, fin_str)
            in_data, im, in_parse_ok = load_resource(filepath, legend, d2)
        }
        if !in_parse_ok {
            return nil, false
        }

        out_parse_ok: bool
        if has_out_write_pattern {
            output_direct = true
            om = out_write_pattern.m
            output = make([]u8, len(out_write_pattern.data), allocator)
            output_owned = true
            for cell, i in out_write_pattern.data {
                if cell == PROC_WRITE_KEEP {
                    output[i] = 0xff
                    continue
                }
                if cell < 0 || cell >= int(grid.c) {
                    log.errorf("direct output value %d is outside current values", cell)
                    return nil, false
                }
                output[i] = u8(cell)
            }
            out_parse_ok = true
        } else if out_ok {
            if has_out_pattern {
                out_data = out_pattern.data
                om = out_pattern.m
                out_parse_ok = true
            } else {
                out_data, om, out_parse_ok = parse_pattern(out_str)
            }
        } else {
            filepath := rule_filepath(grid, fout_str)
            out_data, om, out_parse_ok = load_resource(filepath, legend, d2)
        }
        if !out_parse_ok {
            return nil, false
        }

        if im != om {
            log.errorf("input/output size mismatch: %v vs %v", im, om)
            return nil, false
        }
    }

    if !input_direct {
        // Convert input chars to wave bitmasks
        input = make([]int, len(in_data), allocator)
        input_owned = true
        for i in 0 ..< len(in_data) {
            c := in_data[i]
            wave := grid.waves[c]
            if wave == 0 && c != '*' {
                log.errorf("unknown input char '%c'", c)
                return nil, false
            }
            input[i] = wave
        }
    }

    if !output_direct {
        // Convert output chars to value indices
        output = make([]u8, len(out_data), allocator)
        output_owned = true
        for i in 0 ..< len(out_data) {
            c := out_data[i]
            if c == '*' {
                output[i] = 0xff
            } else {
                val := grid.values[c]
                if val == 0xff {
                    log.errorf("unknown output char '%c'", c)
                    return nil, false
                }
                output[i] = val
            }
        }
    }

    p := get_attr_float(doc, rule_id, "p", 1.0)

    // Create base rule
    base_rule: Rule
    rule_init(&base_rule, input, im, output, om, int(grid.c), p, allocator)
    input_owned = false
    output_owned = false
    base_rule.original = true
    base_rule_owned := true
    defer if base_rule_owned do rule_destroy(&base_rule, allocator)

    // Apply symmetry transformations
    rule_symmetry, sym_ok := get_attr_symmetry_mask(doc, rule_id, grid.m.z == 1, symmetry)
    if !sym_ok {
        return nil, false
    }

    rules := make([dynamic]Rule, allocator)

    if grid.m.z == 1 {
        // 2D symmetries
        sym_rules := rule_square_symmetries(&base_rule, int(grid.c), rule_symmetry, allocator)
        base_rule_owned = false
        for r in sym_rules {
            append(&rules, r)
        }
        delete(sym_rules)
    } else {
        // 3D symmetries
        sym_rules := rule_cube_symmetries(&base_rule, int(grid.c), rule_symmetry, allocator)
        base_rule_owned = false
        for r in sym_rules {
            append(&rules, r)
        }
        delete(sym_rules)
    }

    return rules[:], true
}

// Load a map rule - input uses gin, output uses gout
load_map_rule :: proc(
    doc: ^xml.Document,
    rule_id: xml.Element_ID,
    gin: ^Grid, // Input grid
    gout: ^Grid, // Output grid
    symmetry: Symmetry_Mask,
    allocator := context.allocator,
) -> (
    []Rule,
    bool,
) {
    in_str, in_ok := get_attr(doc, rule_id, "in")
    out_str, out_ok := get_attr(doc, rule_id, "out")
    in_pattern, has_in_pattern := typed_attr_pattern(doc, rule_id, "in")
    out_pattern, has_out_pattern := typed_attr_pattern(doc, rule_id, "out")
    in_match_pattern, has_in_match_pattern := typed_attr_match_pattern(doc, rule_id, "in")
    out_write_pattern, has_out_write_pattern := typed_attr_write_pattern(doc, rule_id, "out")
    fin_str, fin_ok := get_attr(doc, rule_id, "fin")
    fout_str, fout_ok := get_attr(doc, rule_id, "fout")
    file_str, file_ok := get_attr(doc, rule_id, "file")
    legend, _ := get_attr(doc, rule_id, "legend")

    in_data: []u8
    out_data: []u8
    input: []int
    output: []u8
    input_owned := false
    output_owned := false
    defer {
        if input_owned do delete(input, allocator)
        if output_owned do delete(output, allocator)
    }
    im, om: [3]int
    input_direct := false
    output_direct := false
    d2 := gin.m.z == 1

    if file_ok {
        // File-based rule: left half is input, right half is output
        if in_ok || fin_ok || out_ok || fout_ok {
            log.error("map rule already contains a file attribute")
            return nil, false
        }

        filepath := rule_filepath(gin, file_str)
        rect, fm, rect_ok := load_resource(filepath, legend, d2)
        if !rect_ok {
            return nil, false
        }

        if fm.x % 2 != 0 {
            log.errorf("odd width %d in %s", fm.x, file_str)
            return nil, false
        }

        half_x := fm.x / 2
        im = {half_x, fm.y, fm.z}
        om = im

        in_data = make([]u8, half_x * fm.y * fm.z, context.temp_allocator)
        out_data = make([]u8, half_x * fm.y * fm.z, context.temp_allocator)

        for z in 0 ..< fm.z {
            for y in 0 ..< fm.y {
                for x in 0 ..< half_x {
                    idx := x + y * half_x + z * half_x * fm.y
                    in_data[idx] = rect[x + y * fm.x + z * fm.x * fm.y]
                    out_data[idx] = rect[x + half_x + y * fm.x + z * fm.x * fm.y]
                }
            }
        }
    } else {
        // String-based rules (in/out, fin/fout)
        if !in_ok && !fin_ok && !has_in_match_pattern {
            log.error("no input in map rule")
            return nil, false
        }
        if !out_ok && !fout_ok && !has_out_write_pattern {
            log.error("no output in map rule")
            return nil, false
        }

        in_parse_ok: bool
        if has_in_match_pattern {
            input_direct = true
            im = in_match_pattern.m
            input = make([]int, len(in_match_pattern.data), allocator)
            input_owned = true
            all_wave := (1 << uint(gin.c)) - 1
            for wave, i in in_match_pattern.data {
                if wave == PROC_MATCH_ANY {
                    input[i] = all_wave
                    continue
                }
                if wave <= 0 {
                    log.errorf("invalid direct input wave %d in map rule", wave)
                    return nil, false
                }
                if (wave & ~all_wave) != 0 {
                    log.errorf("direct input wave %d references symbols outside map-input values", wave)
                    return nil, false
                }
                input[i] = wave
            }
            in_parse_ok = true
        } else if in_ok {
            if has_in_pattern {
                in_data = in_pattern.data
                im = in_pattern.m
                in_parse_ok = true
            } else {
                in_data, im, in_parse_ok = parse_pattern(in_str)
            }
        } else {
            filepath := rule_filepath(gin, fin_str)
            in_data, im, in_parse_ok = load_resource(filepath, legend, d2)
        }
        if !in_parse_ok {
            return nil, false
        }

        out_parse_ok: bool
        if has_out_write_pattern {
            output_direct = true
            om = out_write_pattern.m
            output = make([]u8, len(out_write_pattern.data), allocator)
            output_owned = true
            for cell, i in out_write_pattern.data {
                if cell == PROC_WRITE_KEEP {
                    output[i] = 0xff
                    continue
                }
                if cell < 0 || cell >= int(gout.c) {
                    log.errorf("direct output value %d is outside map-output values", cell)
                    return nil, false
                }
                output[i] = u8(cell)
            }
            out_parse_ok = true
        } else if out_ok {
            if has_out_pattern {
                out_data = out_pattern.data
                om = out_pattern.m
                out_parse_ok = true
            } else {
                out_data, om, out_parse_ok = parse_pattern(out_str)
            }
        } else {
            filepath := rule_filepath(gout, fout_str)
            out_data, om, out_parse_ok = load_resource(filepath, legend, d2)
        }
        if !out_parse_ok {
            return nil, false
        }

        // Map rules can have different input/output sizes
    }

    if !input_direct {
        // Convert input chars to wave bitmasks using gin
        input = make([]int, len(in_data), allocator)
        input_owned = true
        for i in 0 ..< len(in_data) {
            c := in_data[i]
            wave := gin.waves[c]
            if wave == 0 && c != '*' {
                log.errorf("unknown input char '%c' in map rule", c)
                return nil, false
            }
            input[i] = wave
        }
    }

    if !output_direct {
        // Convert output chars to value indices using gout
        output = make([]u8, len(out_data), allocator)
        output_owned = true
        for i in 0 ..< len(out_data) {
            c := out_data[i]
            if c == '*' {
                output[i] = 0xff
            } else {
                val := gout.values[c]
                if val == 0xff {
                    log.errorf("unknown output char '%c' in map rule", c)
                    return nil, false
                }
                output[i] = val
            }
        }
    }

    p := get_attr_float(doc, rule_id, "p", 1.0)

    // Create base rule
    base_rule: Rule
    rule_init(&base_rule, input, im, output, om, int(gin.c), p, allocator)
    input_owned = false
    output_owned = false
    base_rule.original = true
    base_rule_owned := true
    defer if base_rule_owned do rule_destroy(&base_rule, allocator)

    // Apply symmetry transformations
    rule_symmetry, sym_ok := get_attr_symmetry_mask(doc, rule_id, gin.m.z == 1, symmetry)
    if !sym_ok {
        return nil, false
    }

    rules := make([dynamic]Rule, allocator)

    if gin.m.z == 1 {
        sym_rules := rule_square_symmetries(&base_rule, int(gin.c), rule_symmetry, allocator)
        base_rule_owned = false
        for r in sym_rules {
            append(&rules, r)
        }
        delete(sym_rules)
    } else {
        sym_rules := rule_cube_symmetries(&base_rule, int(gin.c), rule_symmetry, allocator)
        base_rule_owned = false
        for r in sym_rules {
            append(&rules, r)
        }
        delete(sym_rules)
    }

    return rules[:], true
}

// Load rules for a RuleNode (one, all, prl)
load_rules :: proc(
    doc: ^xml.Document,
    elem_id: xml.Element_ID,
    grid: ^Grid,
    symmetry: Symmetry_Mask,
    allocator := context.allocator,
) -> (
    []Rule,
    bool,
) {
    all_rules := make([dynamic]Rule, allocator)
    load_succeeded := false
    defer if !load_succeeded {
        for &rule in all_rules do rule_destroy(&rule, allocator)
        delete(all_rules)
    }

    // Check for nested <rule> elements
    rule_children := get_children_by_name(doc, elem_id, "rule")

    if len(rule_children) > 0 {
        // Multiple rule children
        for rule_id in rule_children {
            rules, ok := load_rule(doc, rule_id, grid, symmetry, allocator)
            if !ok {
                return nil, false
            }
            for r in rules {
                append(&all_rules, r)
            }
            delete(rules, allocator)
        }
    } else {
        // Single rule on the element itself
        rules, ok := load_rule(doc, elem_id, grid, symmetry, allocator)
        if !ok {
            return nil, false
        }
        for r in rules {
            append(&all_rules, r)
        }
        delete(rules, allocator)
    }

    load_succeeded = true
    return all_rules[:], true
}

alloc_rule_potentials :: proc(rn: ^Rule_Node, grid: ^Grid, allocator := context.allocator) {
    if rn.potentials != nil {
        return
    }
    rn.potentials = make([][]int, int(grid.c), allocator)
    for c in 0 ..< int(grid.c) {
        rn.potentials[c] = make([]int, len(grid.state), allocator)
    }
}

load_rule_node_metadata :: proc(
    doc: ^xml.Document,
    elem_id: xml.Element_ID,
    grid: ^Grid,
    rn: ^Rule_Node,
    allocator := context.allocator,
) -> bool {
    field_children := get_children_by_name(doc, elem_id, "field")
    if len(field_children) > 0 {
        rn.fields = make([]^Field, int(grid.c), allocator)

        for field_id in field_children {
            field_value, for_ok := get_attr_symbol_value(doc, field_id, "for", grid)
            if !for_ok {
                log.error("field node requires a non-empty 'for' attribute")
                return false
            }

            f := new(Field, allocator)
            f.recompute = get_attr_bool(doc, field_id, "recompute")
            f.essential = get_attr_bool(doc, field_id, "essential")

            on_wave, on_ok := get_attr_wave(doc, field_id, "on", grid)
            if !on_ok {
                log.error("field node requires an 'on' attribute")
                return false
            }
            f.substrate = on_wave

            if from_wave, from_ok := get_attr_wave(doc, field_id, "from", grid); from_ok {
                f.inversed = true
                f.zero = from_wave
            } else if to_wave, to_ok := get_attr_wave(doc, field_id, "to", grid); to_ok {
                f.zero = to_wave
            } else {
                log.error("field node requires either 'from' or 'to'")
                return false
            }

            rn.fields[field_value] = f
        }

        alloc_rule_potentials(rn, grid, allocator)
    }

    observation_children := get_children_by_name(doc, elem_id, "observe")
    if len(observation_children) > 0 {
        rn.observations = make([]^Observation, int(grid.c), allocator)

        for observation_id in observation_children {
            observed_value, value_ok := get_attr_symbol_value(doc, observation_id, "value", grid)
            to_wave, to_ok := get_attr_wave(doc, observation_id, "to", grid)
            if !value_ok || !to_ok {
                log.error("observe node requires 'value' and 'to'")
                return false
            }

            from_value := observed_value
            if explicit_from, ok := get_attr_symbol_value(doc, observation_id, "from", grid); ok {
                from_value = explicit_from
            }

            obs := new(Observation, allocator)
            obs.from = from_value
            obs.to = to_wave
            rn.observations[observed_value] = obs
        }

        rn.search = get_attr_bool(doc, elem_id, "search")
        if rn.search {
            rn.limit = get_attr_int(doc, elem_id, "limit", -1)
            rn.depth_coeff = get_attr_float(doc, elem_id, "depthCoefficient", 0.5)
        } else {
            alloc_rule_potentials(rn, grid, allocator)
        }

        rn.future = make([]int, len(grid.state), allocator)
    }

    return true
}

// Create a node from XML element
load_node :: proc(
    doc: ^xml.Document,
    elem_id: xml.Element_ID,
    ip: ^Interpreter,
    grid: ^Grid,
    parent_symmetry: Symmetry_Mask,
    allocator := context.allocator,
) -> (
    ^Node,
    bool,
) {
    elem := doc.elements[elem_id]
    ident := elem.ident

    if !is_node_name(ident) {
        log.errorf("unknown node type '%s'", ident)
        return nil, false
    }

    // Get symmetry for this node
    symmetry, sym_ok := get_attr_symmetry_mask(doc, elem_id, grid.m.z == 1, parent_symmetry)
    if !sym_ok {
        return nil, false
    }

    node := new(Node, allocator)
    load_succeeded := false
    unowned_grid: ^Grid
    defer if !load_succeeded {
        node_destroy(node, allocator)
        if unowned_grid != nil {
            grid_destroy(unowned_grid, allocator)
            free(unowned_grid, allocator)
        }
    }
    node.ip = ip
    node.grid = grid

    switch ident {
    case "one":
        node.kind = .One
        rules, ok := load_rules(doc, elem_id, grid, symmetry, allocator)
        if !ok { return nil, false }
        rn := &node.data.one.rule_base
        rn.rules = rules
        rn.steps = get_attr_int(doc, elem_id, "steps", 0)
        rn.temperature = get_attr_float(doc, elem_id, "temperature", 0.0)
        rn.last = make([]bool, len(rules), allocator)
        rn.matches = make([dynamic]Match, allocator)
        rn.match_mask = make([][]bool, len(rules), allocator)
        for i in 0 ..< len(rules) {
            rn.match_mask[i] = make([]bool, len(grid.state), allocator)
        }
        if !load_rule_node_metadata(doc, elem_id, grid, rn, allocator) {
            return nil, false
        }

    case "all":
        node.kind = .All
        rules, ok := load_rules(doc, elem_id, grid, symmetry, allocator)
        if !ok { return nil, false }
        rn := &node.data.all.rule_base
        rn.rules = rules
        rn.steps = get_attr_int(doc, elem_id, "steps", 0)
        rn.temperature = get_attr_float(doc, elem_id, "temperature", 0.0)
        rn.last = make([]bool, len(rules), allocator)
        rn.matches = make([dynamic]Match, allocator)
        rn.match_mask = make([][]bool, len(rules), allocator)
        for i in 0 ..< len(rules) {
            rn.match_mask[i] = make([]bool, len(grid.state), allocator)
        }
        if !load_rule_node_metadata(doc, elem_id, grid, rn, allocator) {
            return nil, false
        }

    case "prl":
        node.kind = .Parallel
        rules, ok := load_rules(doc, elem_id, grid, symmetry, allocator)
        if !ok { return nil, false }
        rn := &node.data.parallel.rule_base
        rn.rules = rules
        rn.steps = get_attr_int(doc, elem_id, "steps", 0)
        rn.temperature = get_attr_float(doc, elem_id, "temperature", 0.0)
        rn.last = make([]bool, len(rules), allocator)
        rn.matches = make([dynamic]Match, allocator)
        node.data.parallel.newstate = make([]u8, len(grid.state), allocator)
        if !load_rule_node_metadata(doc, elem_id, grid, rn, allocator) {
            return nil, false
        }

    case "sequence":
        node.kind = .Sequence
        b := &node.data.sequence.branch_base
        b.children = make([dynamic]^Node, allocator)
        for child_id in get_node_children(doc, elem_id) {
            child, ok := load_node(doc, child_id, ip, grid, symmetry, allocator)
            if !ok { return nil, false }
            if child.kind == .Sequence || child.kind == .Markov {
                set_branch_parent(child, node)
            }
            append(&b.children, child)
        }

    case "markov":
        node.kind = .Markov
        b := &node.data.markov.branch_base
        b.children = make([dynamic]^Node, allocator)
        for child_id in get_node_children(doc, elem_id) {
            child, ok := load_node(doc, child_id, ip, grid, symmetry, allocator)
            if !ok { return nil, false }
            if child.kind == .Sequence || child.kind == .Markov {
                set_branch_parent(child, node)
            }
            append(&b.children, child)
        }

    case "path":
        node.kind = .Path
        pn := &node.data.path

        from_wave, from_ok := get_attr_wave(doc, elem_id, "from", grid)
        to_wave, to_ok := get_attr_wave(doc, elem_id, "to", grid)
        on_wave, on_ok := get_attr_wave(doc, elem_id, "on", grid)
        if !from_ok || !to_ok || !on_ok {
            log.error("path node requires non-empty 'from', 'to', and 'on' attributes")
            return nil, false
        }

        pn.start = from_wave
        pn.finish = to_wave
        pn.substrate = on_wave

        default_value, default_ok := first_symbol_from_wave(from_wave, int(grid.c))
        if !default_ok {
            log.error("path node requires 'from' to contain at least one symbol")
            return nil, false
        }
        pn.value = default_value
        if color_value, ok := get_attr_symbol_value(doc, elem_id, "color", grid); ok {
            pn.value = color_value
        }

        pn.inertia = get_attr_bool(doc, elem_id, "inertia")
        pn.longest = get_attr_bool(doc, elem_id, "longest")
        pn.edges = get_attr_bool(doc, elem_id, "edges")
        pn.vertices = get_attr_bool(doc, elem_id, "vertices")

    case "map":
        node.kind = .Map
        mn := &node.data.map_

        // Parse scale (e.g., "4 4 4" or "1/2 1/2 1")
        scale_str, scale_ok := get_attr(doc, elem_id, "scale")
        if !scale_ok {
            log.error("scale should be specified in map node")
            return nil, false
        }

        scale_parts := strings.split(scale_str, " ", context.temp_allocator)
        if len(scale_parts) != 3 {
            log.errorf("scale attribute \"%s\" should have 3 components separated by space", scale_str)
            return nil, false
        }

        parse_scale :: proc(s: string) -> (int, int) {
            slash_idx := strings.index(s, "/")
            if slash_idx < 0 {
                n, _ := strconv.parse_int(s)
                return n, 1
            }
            n, _ := strconv.parse_int(s[:slash_idx])
            d, _ := strconv.parse_int(s[slash_idx + 1:])
            return n, d
        }

        mn.nm[0], mn.dm[0] = parse_scale(scale_parts[0])
        mn.nm[1], mn.dm[1] = parse_scale(scale_parts[1])
        mn.nm[2], mn.dm[2] = parse_scale(scale_parts[2])

        // Get new grid values
        values_count: int
        has_values_count := false
        values_string := ""
        if n, ok := typed_attr_symbol_count(doc, elem_id, "values"); ok {
            values_count = n
            has_values_count = true
        } else if val, values_ok := get_attr(doc, elem_id, "values"); values_ok {
            values_string = val
        } else {
            log.error("values should be specified in map node")
            return nil, false
        }

        // Create new grid with scaled dimensions
        new_m: [3]int = {
            grid.m.x * mn.nm[0] / mn.dm[0],
            grid.m.y * mn.nm[1] / mn.dm[1],
            grid.m.z * mn.nm[2] / mn.dm[2],
        }
        newgrid := new(Grid, allocator)
        unowned_grid = newgrid
        if has_values_count {
            if !grid_init_count(newgrid, new_m, values_count, allocator) {
                log.error("Failed to initialize map newgrid from values_count")
                return nil, false
            }
        } else {
            if !grid_init(newgrid, new_m, values_string, allocator) {
                log.error("Failed to initialize map newgrid")
                return nil, false
            }
        }
        if folder_str, ok := get_attr(doc, elem_id, "folder"); ok {
            newgrid.folder = strings.clone(folder_str, allocator)
        } else {
            newgrid.folder = strings.clone(grid.folder, allocator)
        }

        // Load unions for the new grid
        load_unions(doc, elem_id, newgrid)

        mn.newgrid = newgrid
        unowned_grid = nil

        // Load rules (from grid to newgrid)
        map_rules := make([dynamic]Rule, allocator)
        for rule_id in get_children_by_name(doc, elem_id, "rule") {
            // Load map rules with two grids: input from grid, output to newgrid
            rules, ok := load_map_rule(doc, rule_id, grid, newgrid, symmetry, allocator)
            if !ok {
                return nil, false
            }
            for r in rules {
                append(&map_rules, r)
            }
        }
        mn.rules = map_rules[:]

        // Load map children using newgrid
        mn.branch_base.children = make([dynamic]^Node, allocator)
        for child_id in get_node_children(doc, elem_id) {
            child, ok := load_node(doc, child_id, ip, newgrid, symmetry, allocator)
            if !ok {
                return nil, false
            }
            if child.kind == .Sequence || child.kind == .Markov {
                set_branch_parent(child, node)
            }
            append(&mn.branch_base.children, child)
        }

    case "convolution":
        node.kind = .Convolution
        cn := &node.data.convolution
        cn.steps = get_attr_int(doc, elem_id, "steps", 0)
        cn.periodic = get_attr_bool(doc, elem_id, "periodic")

        // Parse neighborhood
        neighborhood := "Moore"
        if nb_str, ok := get_attr(doc, elem_id, "neighborhood"); ok {
            neighborhood = nb_str
        }
        if grid.m.z == 1 {
            if neighborhood == "VonNeumann" {
                kernel := KERNEL_VON_NEUMANN_2D
                cn.kernel = make([]int, 9, allocator)
                for i in 0 ..< 9 { cn.kernel[i] = kernel[i] }
            } else {
                kernel := KERNEL_MOORE_2D
                cn.kernel = make([]int, 9, allocator)
                for i in 0 ..< 9 { cn.kernel[i] = kernel[i] }
            }
        } else {
            if neighborhood == "VonNeumann" {
                kernel := KERNEL_VON_NEUMANN_3D
                cn.kernel = make([]int, 27, allocator)
                for i in 0 ..< 27 { cn.kernel[i] = kernel[i] }
            } else {
                kernel := KERNEL_NO_CORNERS_3D
                cn.kernel = make([]int, 27, allocator)
                for i in 0 ..< 27 { cn.kernel[i] = kernel[i] }
            }
        }

        // Parse convolution rules
        conv_rules := make([dynamic]Convolution_Rule, allocator)
        for rule_id in get_children_by_name(doc, elem_id, "rule") {
            cr: Convolution_Rule
            if in_value, ok := get_attr_symbol_value(doc, rule_id, "in", grid); ok {
                cr.input = in_value
            }
            if out_value, ok := get_attr_symbol_value(doc, rule_id, "out", grid); ok {
                cr.output = out_value
            }
            if values_wave, ok := get_attr_wave(doc, rule_id, "values", grid); ok {
                cr.values = values_wave
            }
            cr.sum_start = 0
            cr.sum_end = 0
            if sum_str, ok := get_attr(doc, rule_id, "sum"); ok {
                // Parse "5..8" or "5" format
                if strings.contains(sum_str, "..") {
                    parts := strings.split(sum_str, "..", context.temp_allocator)
                    if len(parts) == 2 {
                        cr.sum_start, _ = strconv.parse_int(parts[0])
                        cr.sum_end, _ = strconv.parse_int(parts[1])
                    }
                } else {
                    // Single value - set both start and end to same value
                    val, _ := strconv.parse_int(sum_str)
                    cr.sum_start = val
                    cr.sum_end = val
                }
            }
            append(&conv_rules, cr)
        }
        cn.rules = conv_rules[:]

        // Allocate sumfield (single contiguous allocation)
        cn.sumfield = make([][]int, len(grid.state), allocator)
        for i in 0 ..< len(cn.sumfield) {
            cn.sumfield[i] = make([]int, int(grid.c), allocator)
        }

    case "convchain":
        node.kind = .ConvChain
        ccn := &node.data.convchain
        ccn.n = get_attr_int(doc, elem_id, "n", 3)
        ccn.temperature = get_attr_float(doc, elem_id, "temperature", 1.0)
        ccn.steps = get_attr_int(doc, elem_id, "steps", 0)
    // Additional ConvChain initialization would go here

    case "wfc":
        child_grid := grid
        if values_count, count_ok := typed_attr_symbol_count(doc, elem_id, "values"); count_ok {
            child_grid = new(Grid, allocator)
            unowned_grid = child_grid
            if !grid_init_count(child_grid, grid.m, values_count, allocator) {
                log.error("Failed to initialize WFC grid with values_count")
                return nil, false
            }
            load_unions(doc, elem_id, child_grid)
        } else if wfc_values, values_ok := get_attr(doc, elem_id, "values"); values_ok {
            clean_values := strings.trim_space(wfc_values)
            values_no_space, _ := strings.replace_all(clean_values, " ", "", context.temp_allocator)
            child_grid = new(Grid, allocator)
            unowned_grid = child_grid
            if !grid_init(child_grid, grid.m, values_no_space, allocator) {
                log.error("Failed to initialize WFC grid with values")
                return nil, false
            }
            load_unions(doc, elem_id, child_grid)
        }

        if sample_name, sample_ok := get_attr(doc, elem_id, "sample"); sample_ok {
            node.kind = .Overlap_WFC
            on := &node.data.overlap
            wfc := &on.wfc_base
            wfc.branch_base.children = make([dynamic]^Node, allocator)
            wfc.first_go = true
            wfc.periodic = true
            wfc.shannon = get_attr_bool(doc, elem_id, "shannon")
            wfc.tries = get_attr_int(doc, elem_id, "tries", 1000)
            wfc.n = get_attr_int(doc, elem_id, "n", 3)

            if grid.m.z != 1 {
                log.error("overlapping model currently works only for 2d")
                return nil, false
            }

            overlap_values := child_grid
            if overlap_values == grid {
                overlap_values = new(Grid, allocator)
                unowned_grid = overlap_values
                values_str := ""
                for i in 0 ..< int(grid.c) {
                    values_str = strings.concatenate({values_str, string([]u8{grid.chars[i]})}, context.temp_allocator)
                }
                if !grid_init(overlap_values, grid.m, values_str, allocator) {
                    log.error("Failed to initialize overlap WFC grid")
                    return nil, false
                }
                overlap_values.folder = strings.clone(grid.folder, allocator)
                load_unions(doc, elem_id, overlap_values)
            }
            wfc.newgrid = overlap_values
            unowned_grid = nil

            sample_path := strings.concatenate({"resources/samples/", sample_name, ".png"}, context.temp_allocator)
            sample_bitmap, sample_m, sample_loaded := load_bitmap(sample_path, context.temp_allocator)
            if !sample_loaded {
                log.errorf("couldn't read sample %s", sample_name)
                return nil, false
            }

            sample_ords, sample_color_count := ords(sample_bitmap, context.temp_allocator)
            if sample_color_count > int(wfc.newgrid.c) {
                log.errorf("there were more than %d colors in the sample", wfc.newgrid.c)
                return nil, false
            }

            pattern_rotate :: proc(p: []u8, n: int, allocator := context.temp_allocator) -> []u8 {
                r := make([]u8, len(p), allocator)
                for y in 0 ..< n {
                    for x in 0 ..< n {
                        r[x + y * n] = p[n - 1 - y + x * n]
                    }
                }
                return r
            }

            pattern_reflect :: proc(p: []u8, n: int, allocator := context.temp_allocator) -> []u8 {
                r := make([]u8, len(p), allocator)
                for y in 0 ..< n {
                    for x in 0 ..< n {
                        r[x + y * n] = p[n - 1 - x + y * n]
                    }
                }
                return r
            }

            pattern_index :: proc(p: []u8, c: int) -> i64 {
                result: i64 = 0
                power: i64 = 1
                for i := len(p) - 1; i >= 0; i -= 1 {
                    result += i64(p[i]) * power
                    power *= i64(c)
                }
                return result
            }

            pattern_from_index :: proc(ind: i64, c, n: int, allocator := context.temp_allocator) -> []u8 {
                result := make([]u8, n * n, allocator)
                residue := ind
                power: i64 = 1
                for _ in 0 ..< n * n {
                    power *= i64(c)
                }
                for i in 0 ..< n * n {
                    power /= i64(c)
                    count: u8 = 0
                    for residue >= power {
                        residue -= power
                        count += 1
                    }
                    result[i] = count
                }
                return result
            }

            weights := make(map[i64]int, allocator)
            ordering := make([dynamic]i64, allocator)
            periodic_input := get_attr_bool(doc, elem_id, "periodicInput", true)
            ymax := periodic_input ? grid.m.y : grid.m.y - wfc.n + 1
            xmax := periodic_input ? grid.m.x : grid.m.x - wfc.n + 1

            for y in 0 ..< ymax {
                for x in 0 ..< xmax {
                    pattern := make([]u8, wfc.n * wfc.n, context.temp_allocator)
                    for dy in 0 ..< wfc.n {
                        for dx in 0 ..< wfc.n {
                            sx := (x + dx) % sample_m.x
                            sy := (y + dy) % sample_m.y
                            pattern[dx + dy * wfc.n] = sample_ords[sx + sy * sample_m.x]
                        }
                    }

                    syms: [8][]u8 = {
                        pattern,
                        pattern_reflect(pattern, wfc.n),
                        pattern_rotate(pattern, wfc.n),
                        nil,
                        nil,
                        nil,
                        nil,
                        nil,
                    }
                    syms[3] = pattern_reflect(syms[2], wfc.n)
                    syms[4] = pattern_rotate(syms[2], wfc.n)
                    syms[5] = pattern_reflect(syms[4], wfc.n)
                    syms[6] = pattern_rotate(syms[4], wfc.n)
                    syms[7] = pattern_reflect(syms[6], wfc.n)

                    for i in 0 ..< 8 {
                        if symmetry_has(symmetry, i) {
                            ind := pattern_index(syms[i], sample_color_count)
                            if ind in weights {
                                weights[ind] += 1
                            } else {
                                weights[ind] = 1
                                append(&ordering, ind)
                            }
                        }
                    }
                }
            }

            p := len(ordering)
            wfc.p_count = p
            on.patterns = make([][]u8, p, allocator)
            wfc.weights = make([]f64, p, allocator)
            wfc.weight_log_weights = make([]f64, p, allocator)
            wfc.distribution = make([]f64, p, allocator)

            wfc.sum_of_weights = 0
            wfc.sum_of_weight_log_weights = 0
            for i in 0 ..< p {
                ind := ordering[i]
                on.patterns[i] = pattern_from_index(ind, sample_color_count, wfc.n, allocator)
                wfc.weights[i] = f64(weights[ind])
                wlw := wfc.weights[i] * math.ln(wfc.weights[i])
                wfc.weight_log_weights[i] = wlw
                wfc.sum_of_weights += wfc.weights[i]
                wfc.sum_of_weight_log_weights += wlw
            }
            wfc.starting_entropy = math.ln(wfc.sum_of_weights) - wfc.sum_of_weight_log_weights / wfc.sum_of_weights

            agrees :: proc(p1, p2: []u8, dx, dy, n: int) -> bool {
                xmin := dx < 0 ? 0 : dx
                xmax := dx < 0 ? dx + n : n
                ymin := dy < 0 ? 0 : dy
                ymax := dy < 0 ? dy + n : n
                for y in ymin ..< ymax {
                    for x in xmin ..< xmax {
                        if p1[x + n * y] != p2[x - dx + n * (y - dy)] {
                            return false
                        }
                    }
                }
                return true
            }

            wfc.propagator = make([][][]int, 4, allocator)
            for d in 0 ..< 4 {
                wfc.propagator[d] = make([][]int, p, allocator)
                for t in 0 ..< p {
                    compatible := make([dynamic]int, context.temp_allocator)
                    for t2 in 0 ..< p {
                        if agrees(on.patterns[t], on.patterns[t2], WFC_DX[d], WFC_DY[d], wfc.n) {
                            append(&compatible, t2)
                        }
                    }
                    wfc.propagator[d][t] = make([]int, len(compatible), allocator)
                    copy(wfc.propagator[d][t], compatible[:])
                }
            }

            wave_length := grid.m.x * grid.m.y * grid.m.z
            wfc.wave = wave_create(wave_length, p, 4, wfc.shannon, allocator)
            wfc.startwave = wave_create(wave_length, p, 4, wfc.shannon, allocator)
            wfc.stack = make([][2]int, wave_length * p, allocator)

            wfc.map_ = make(map[u8][]bool, allocator)
            for rule_id in get_children_by_name(doc, elem_id, "rule") {
                input_value, in_ok := get_attr_symbol_value(doc, rule_id, "in", grid)
                if !in_ok {
                    continue
                }

                allowed_colors := make(map[u8]bool, context.temp_allocator)
                if out_wave, out_wave_ok := get_attr_wave(doc, rule_id, "out", wfc.newgrid); out_wave_ok {
                    for i in 0 ..< int(wfc.newgrid.c) {
                        if (out_wave & (1 << uint(i))) != 0 {
                            allowed_colors[u8(i)] = true
                        }
                    }
                } else {
                    out_str, out_ok := get_attr(doc, rule_id, "out")
                    if !out_ok {
                        continue
                    }
                    out_parts := strings.split(out_str, "|", context.temp_allocator)
                    for part in out_parts {
                        part_trimmed := strings.trim_space(part)
                        if len(part_trimmed) == 0 {
                            continue
                        }
                        output_value := wfc.newgrid.values[part_trimmed[0]]
                        if output_value == 0xff {
                            log.errorf("unknown overlap output value '%c'", part_trimmed[0])
                            return nil, false
                        }
                        allowed_colors[output_value] = true
                    }
                }

                position := make([]bool, p, allocator)
                for t in 0 ..< p {
                    position[t] = on.patterns[t][0] in allowed_colors
                }
                wfc.map_[input_value] = position
            }

            if 0 not_in wfc.map_ {
                all_patterns := make([]bool, p, allocator)
                for i in 0 ..< p {
                    all_patterns[i] = true
                }
                wfc.map_[0] = all_patterns
            }

            for child_id in get_node_children(doc, elem_id) {
                child, ok := load_node(doc, child_id, ip, wfc.newgrid, symmetry, allocator)
                if !ok {
                    return nil, false
                }
                if child.kind == .Sequence || child.kind == .Markov {
                    set_branch_parent(child, node)
                }
                append(&wfc.branch_base.children, child)
            }
            wfc.branch_base.child_index = -1
        } else if tileset_name, tileset_ok := get_attr(doc, elem_id, "tileset"); tileset_ok {
            node.kind = .Tile_WFC
            tn := &node.data.tile
            wfc := &tn.wfc_base
            wfc.branch_base.children = make([dynamic]^Node, allocator)
            wfc.first_go = true
            wfc.periodic = get_attr_bool(doc, elem_id, "periodic")
            wfc.shannon = get_attr_bool(doc, elem_id, "shannon")
            wfc.tries = get_attr_int(doc, elem_id, "tries", 1000)

            tiles_dir := tileset_name
            if tiles_val, tiles_ok := get_attr(doc, elem_id, "tiles"); tiles_ok {
                tiles_dir = tiles_val
            }

            ts, ts_ok := load_tileset(tileset_name, tiles_dir, grid, allocator)
            if !ts_ok {
                log.errorf("Failed to load tileset: %s", tileset_name)
                return nil, false
            }
            defer tileset_destroy(ts, allocator)

            tn.s = ts.tile_size
            tn.sz = ts.tile_sizez
            tn.overlap = get_attr_int(doc, elem_id, "overlap", 0)
            tn.overlapz = get_attr_int(doc, elem_id, "overlapz", 0)

            nm: [3]int
            nm.x = (ts.tile_size - tn.overlap) * grid.m.x + tn.overlap
            nm.y = (ts.tile_size - tn.overlap) * grid.m.y + tn.overlap
            nm.z = (ts.tile_sizez - tn.overlapz) * grid.m.z + tn.overlapz

            grid_values := child_grid != nil ? child_grid : grid
            wfc.newgrid = new(Grid, allocator)
            values_str := ""
            for i in 0 ..< int(grid_values.c) {
                values_str = strings.concatenate(
                    {values_str, string([]u8{grid_values.chars[i]})},
                    context.temp_allocator,
                )
            }
            if !grid_init(wfc.newgrid, nm, values_str, allocator) {
                log.error("Failed to initialize WFC newgrid")
                return nil, false
            }
            load_unions(doc, elem_id, wfc.newgrid)
            if child_grid != grid {
                grid_destroy(child_grid, allocator)
                free(child_grid, allocator)
                child_grid = grid
                unowned_grid = nil
            }

            tn.tiledata = make([dynamic][]u8, allocator)
            for &tile in ts.tiles {
                append(&tn.tiledata, tile.data)
                tile.data = nil
            }

            p := len(ts.tiles)
            wfc.p_count = p
            wfc.n = 1
            wfc.weights = make([]f64, p, allocator)
            wfc.weight_log_weights = make([]f64, p, allocator)
            wfc.distribution = make([]f64, p, allocator)

            wfc.sum_of_weights = 0
            wfc.sum_of_weight_log_weights = 0
            for i in 0 ..< p {
                wfc.weights[i] = ts.tiles[i].weight
                wfc.sum_of_weights += ts.tiles[i].weight
                wlw := ts.tiles[i].weight * math.ln(ts.tiles[i].weight)
                wfc.weight_log_weights[i] = wlw
                wfc.sum_of_weight_log_weights += wlw
            }
            wfc.starting_entropy = math.ln(wfc.sum_of_weights) - wfc.sum_of_weight_log_weights / wfc.sum_of_weights

            wfc.propagator = make([][][]int, 6, allocator)
            for d in 0 ..< 6 {
                wfc.propagator[d] = make([][]int, p, allocator)
                for t in 0 ..< p {
                    wfc.propagator[d][t] = make([]int, len(ts.propagator[d][t]), allocator)
                    copy(wfc.propagator[d][t], ts.propagator[d][t])
                }
            }

            wave_length := grid.m.x * grid.m.y * grid.m.z
            wfc.wave = wave_create(wave_length, p, 6, wfc.shannon, allocator)
            wfc.startwave = wave_create(wave_length, p, 6, wfc.shannon, allocator)
            wfc.stack = make([][2]int, wave_length * p, allocator)

            wfc.map_ = make(map[u8][]bool, allocator)
            tile_positions := make(map[string][]bool, 64, context.temp_allocator)
            for i in 0 ..< p {
                name := ts.tiles[i].name
                if name not_in tile_positions {
                    tile_positions[name] = make([]bool, p, context.temp_allocator)
                }
                tile_positions[name][i] = true
            }

            for rule_id in get_children_by_name(doc, elem_id, "rule") {
                input_value, in_ok := get_attr_symbol_value(doc, rule_id, "in", grid)
                out_str, out_ok := get_attr(doc, rule_id, "out")
                if !in_ok || !out_ok {
                    continue
                }

                position := make([]bool, p, allocator)
                out_parts := strings.split(out_str, "|", context.temp_allocator)
                for part in out_parts {
                    part_trimmed := strings.trim_space(part)
                    if len(part_trimmed) == 0 {
                        continue
                    }
                    if tile_pos, found := tile_positions[part_trimmed]; found {
                        for i in 0 ..< p {
                            if tile_pos[i] { position[i] = true }
                        }
                    } else {
                        log.errorf("unknown tile name '%s' in WFC rule", part_trimmed)
                        return nil, false
                    }
                }
                wfc.map_[input_value] = position
            }

            if 0 not_in wfc.map_ {
                all_tiles := make([]bool, p, allocator)
                for i in 0 ..< p { all_tiles[i] = true }
                wfc.map_[0] = all_tiles
            }

            for child_id in get_node_children(doc, elem_id) {
                child, node_ok := load_node(doc, child_id, ip, wfc.newgrid, symmetry, allocator)
                if !node_ok {
                    return nil, false
                }
                if child.kind == .Sequence || child.kind == .Markov {
                    set_branch_parent(child, node)
                }
                append(&wfc.branch_base.children, child)
            }
            wfc.branch_base.child_index = -1
        } else {
            log.error("wfc node must have 'sample' or 'tileset' attribute")
            return nil, false
        }

    case:
        log.errorf("unhandled node type '%s'", ident)
        return nil, false
    }

    load_succeeded = true
    return node, true
}

// Helper to set parent on branch nodes
set_branch_parent :: proc(child: ^Node, parent: ^Node) {
    #partial switch child.kind {
    case .Sequence:
        child.data.sequence.branch_base.parent = parent
    case .Markov:
        child.data.markov.branch_base.parent = parent
    }
}

// Create an interpreter from a parsed model document.
load_model_document :: proc(doc: ^xml.Document, m: [3]int, allocator := context.allocator) -> (^Interpreter, bool) {
    // Find root element (element 0) and values attribute
    values: string = ""
    values_count: int = 0
    has_values_count := false
    origin := false
    folder: string = ""

    if doc.element_count > 0 {
        if n, ok := typed_attr_symbol_count(doc, 0, "values"); ok {
            values_count = n
            has_values_count = true
        } else if val, value_ok := get_attr(doc, 0, "values"); value_ok {
            values = strings.trim_space(val)
        }
        origin = get_attr_bool(doc, 0, "origin")
        if val, ok := get_attr(doc, 0, "folder"); ok {
            folder = val
        }
    }

    if !has_values_count && len(values) == 0 {
        log.error("No values specified in model")
        return nil, false
    }

    grid := new(Grid, allocator)
    ip := new(Interpreter, allocator)
    ip.allocator = allocator
    ip.grid = grid
    ip.startgrid = grid
    load_succeeded := false
    defer if !load_succeeded do interpreter_destroy(ip)

    if has_values_count {
        if !grid_init_count(grid, m, values_count, allocator) {
            log.error("Failed to initialize grid from values_count")
            return nil, false
        }
    } else {
        if !grid_init(grid, m, values, allocator) {
            log.error("Failed to initialize grid")
            return nil, false
        }
    }
    grid.folder = strings.clone(folder, allocator)

    // Load all unions from the model tree
    load_unions(doc, 0, grid)

    // Finish interpreter initialization before loading nodes.
    ip.origin = origin
    ip.changes = make([dynamic][3]int, allocator)
    ip.first = make([dynamic]int, allocator)

    // Get default symmetry (all variants)
    default_symmetry := grid.m.z == 1 ? SYMMETRY_2D_ALL : SYMMETRY_3D_ALL

    // Load root node
    if doc.element_count > 0 {
        root_elem := doc.elements[0]

        // First check if root element itself is a node type (sequence, markov, etc.)
        if is_node_name(root_elem.ident) {
            root, ok := load_node(doc, 0, ip, grid, default_symmetry, allocator)
            if !ok {
                return nil, false
            }

            // Wrap non-Branch nodes in a MarkovNode (matches C# behavior)
            // This ensures the interpreter loop can terminate properly
            // Branch nodes are: Sequence, Markov, Map, Overlap_WFC, Tile_WFC
            is_branch :=
                root.kind == .Sequence ||
                root.kind == .Markov ||
                root.kind == .Map ||
                root.kind == .Overlap_WFC ||
                root.kind == .Tile_WFC

            if !is_branch {
                wrapper := new(Node, allocator)
                wrapper.kind = .Markov
                wrapper.ip = ip
                wrapper.grid = grid
                b := &wrapper.data.markov.branch_base
                b.parent = nil
                b.children = make([dynamic]^Node, allocator)
                append(&b.children, root)
                wrapper.data.markov.child_index = 0
                ip.root = wrapper
            } else {
                ip.root = root
            }
        } else {
            // Root is a container (not a node), load its children
            node_children := get_node_children(doc, 0)
            if len(node_children) > 0 {
                // Wrap in Markov node if multiple children
                if len(node_children) == 1 {
                    root, ok := load_node(doc, node_children[0], ip, grid, default_symmetry, allocator)
                    if !ok {
                        return nil, false
                    }
                    ip.root = root
                } else {
                    // Create Markov wrapper
                    root := new(Node, allocator)
                    root.kind = .Markov
                    root.ip = ip
                    root.grid = grid
                    b := &root.data.markov.branch_base
                    b.children = make([dynamic]^Node, allocator)
                    ip.root = root

                    for child_id in node_children {
                        child, ok := load_node(doc, child_id, ip, grid, default_symmetry, allocator)
                        if !ok {
                            return nil, false
                        }
                        append(&b.children, child)
                    }
                }
            } else {
                log.error("No node children found in model")
                return nil, false
            }
        }
    }

    ip.current = ip.root
    load_succeeded = true
    return ip, true
}

// Load a model XML file and create interpreter
load_model :: proc(filename: string, m: [3]int, allocator := context.allocator) -> (^Interpreter, bool) {
    doc, err := load_xml_document(filename, allocator = context.temp_allocator)
    if err != .None {
        log.errorf("Failed to load model: %s %v", filename, err)
        return nil, false
    }
    defer xml.destroy(doc, allocator = context.temp_allocator)

    return load_model_document(doc, m, allocator)
}

// Tileset for tile-based WFC
Tileset :: struct {
    tiles:      [dynamic]Tile_Info,
    propagator: [6][][]int, // [direction][tile1] -> list of compatible tile2
    tile_size:  int,
    tile_sizez: int,
}

Tile_Info :: struct {
    name:   string,
    data:   []u8,
    weight: f64,
}

tileset_destroy :: proc(ts: ^Tileset, allocator := context.allocator) {
    if ts == nil do return
    for &tile in ts.tiles {
        delete(tile.name, allocator)
        delete(tile.data, allocator)
    }
    delete(ts.tiles)
    for direction in ts.propagator {
        for compatible in direction do delete(compatible, allocator)
        delete(direction, allocator)
    }
    free(ts, allocator)
}

// Load a tileset XML file
// name: tileset name (for loading the XML file)
// tiles_dir: directory where tile VOX files are located (relative to resources/tilesets/)
load_tileset :: proc(
    name: string,
    tiles_dir: string,
    grid: ^Grid,
    allocator := context.allocator,
) -> (
    ^Tileset,
    bool,
) {
    filepath := strings.concatenate({"resources/tilesets/", name, ".xml"}, context.temp_allocator)
    doc, err := load_xml_document(filepath, allocator = context.temp_allocator)
    if err != .None {
        log.errorf("Failed to load tileset: %s %v", filepath, err)
        return nil, false
    }
    defer xml.destroy(doc, allocator = context.temp_allocator)

    ts := new(Tileset, allocator)
    ts.tiles = make([dynamic]Tile_Info, allocator)
    load_succeeded := false
    defer if !load_succeeded do tileset_destroy(ts, allocator)

    // Find tiles element
    tiles_elems := get_children_by_name(doc, 0, "tiles")
    if len(tiles_elems) == 0 {
        log.error("No tiles element in tileset")
        return nil, false
    }

    // Map tile names to indices for propagator building
    tile_indices := make(map[string]int, 64, context.temp_allocator)

    // Shared unique color list (like C#'s uniques)
    uniques := make([dynamic]i32, context.temp_allocator)

    // Load each tile
    tile_elems := get_children_by_name(doc, tiles_elems[0], "tile")
    for tile_id in tile_elems {
        tile_name, name_ok := get_attr(doc, tile_id, "name")
        if !name_ok {
            log.error("Tile missing name attribute")
            return nil, false
        }

        weight := get_attr_float(doc, tile_id, "weight", 1.0)

        // Load tile VOX file using tiles_dir
        vox_path := strings.concatenate(
            {"resources/tilesets/", tiles_dir, "/", tile_name, ".vox"},
            context.temp_allocator,
        )
        vox_data, vox_size, vox_ok := load_vox(vox_path, context.temp_allocator)
        if !vox_ok {
            log.errorf("Failed to load tile VOX: %s", vox_path)
            return nil, false
        }

        // Set tile size from first tile
        if len(ts.tiles) == 0 {
            ts.tile_size = vox_size.x
            ts.tile_sizez = vox_size.z
            if vox_size.x != vox_size.y {
                log.errorf("Tile must be square: %d x %d", vox_size.x, vox_size.y)
                return nil, false
            }
        }

        // Convert vox colors to ordinal indices (like C#'s Ords)
        tile_data := make([]u8, len(vox_data), allocator)
        for i in 0 ..< len(vox_data) {
            color := vox_data[i]
            // Find ordinal in uniques list
            ord := -1
            for j in 0 ..< len(uniques) {
                if uniques[j] == color {
                    ord = j
                    break
                }
            }
            if ord == -1 {
                ord = len(uniques)
                append(&uniques, color)
            }
            tile_data[i] = u8(ord)
        }

        // Generate rotations (z-axis rotations for 2D-style tiles)
        rotations := tile_rotations(tile_data, ts.tile_size, ts.tile_sizez, allocator)
        delete(tile_data, allocator)
        first_idx := len(ts.tiles)
        for rot in rotations {
            append(&ts.tiles, Tile_Info{name = strings.clone(tile_name, allocator), data = rot, weight = weight})
        }
        delete(rotations)
        tile_indices[tile_name] = first_idx // First rotation is the "base"
    }

    p := len(ts.tiles)
    if p == 0 {
        log.error("No tiles in tileset")
        return nil, false
    }

    // Initialize propagator as dense boolean array first
    temp_prop := make([][][]bool, 6, context.temp_allocator)
    for d in 0 ..< 6 {
        temp_prop[d] = make([][]bool, p, context.temp_allocator)
        for t in 0 ..< p {
            temp_prop[d][t] = make([]bool, p, context.temp_allocator)
        }
    }

    // Find neighbors element
    neighbors_elems := get_children_by_name(doc, 0, "neighbors")
    if len(neighbors_elems) == 0 {
        log.error("No neighbors element in tileset")
        return nil, false
    }

    // Parse neighbor constraints - matching C# behavior
    s := ts.tile_size
    sz := ts.tile_sizez

    neighbor_elems := get_children_by_name(doc, neighbors_elems[0], "neighbor")
    for neighbor_id in neighbor_elems {
        left, left_ok := get_attr(doc, neighbor_id, "left")
        right, right_ok := get_attr(doc, neighbor_id, "right")
        top, top_ok := get_attr(doc, neighbor_id, "top")
        bottom, bottom_ok := get_attr(doc, neighbor_id, "bottom")

        if left_ok && right_ok {
            // Horizontal neighbor - add all symmetries like C#
            ltile, lok := parse_tile_ref(left, tile_indices, ts.tiles[:], s, sz)
            rtile, rok := parse_tile_ref(right, tile_indices, ts.tiles[:], s, sz)
            if lok && rok {
                // Direction 0 (+x): original and y-reflected
                add_prop(temp_prop, ts.tiles[:], 0, ltile, rtile, s, sz)
                add_prop(temp_prop, ts.tiles[:], 0, y_reflect_tile(ltile, s, sz), y_reflect_tile(rtile, s, sz), s, sz)
                // Also add x-reflected with swapped order
                add_prop(temp_prop, ts.tiles[:], 0, x_reflect_tile(rtile, s, sz), x_reflect_tile(ltile, s, sz), s, sz)
                add_prop(
                    temp_prop,
                    ts.tiles[:],
                    0,
                    y_reflect_tile(x_reflect_tile(rtile, s, sz), s, sz),
                    y_reflect_tile(x_reflect_tile(ltile, s, sz), s, sz),
                    s,
                    sz,
                )

                // Direction 1 (+y): z-rotated versions
                dtile := z_rotate_tile(ltile, s, sz)
                utile := z_rotate_tile(rtile, s, sz)
                add_prop(temp_prop, ts.tiles[:], 1, dtile, utile, s, sz)
                add_prop(temp_prop, ts.tiles[:], 1, x_reflect_tile(dtile, s, sz), x_reflect_tile(utile, s, sz), s, sz)
                add_prop(temp_prop, ts.tiles[:], 1, y_reflect_tile(utile, s, sz), y_reflect_tile(dtile, s, sz), s, sz)
                add_prop(
                    temp_prop,
                    ts.tiles[:],
                    1,
                    x_reflect_tile(y_reflect_tile(utile, s, sz), s, sz),
                    x_reflect_tile(y_reflect_tile(dtile, s, sz), s, sz),
                    s,
                    sz,
                )
            }
        }
        if top_ok && bottom_ok {
            // Vertical neighbor - apply square symmetries
            ttile, tok := parse_tile_ref(top, tile_indices, ts.tiles[:], s, sz)
            btile, bok := parse_tile_ref(bottom, tile_indices, ts.tiles[:], s, sz)
            if tok && bok {
                // Generate all z-rotations
                tsyms := square_symmetries(ttile, s, sz)
                bsyms := square_symmetries(btile, s, sz)
                for i in 0 ..< len(tsyms) {
                    add_prop(temp_prop, ts.tiles[:], 4, bsyms[i], tsyms[i], s, sz)
                }
            }
        }
    }

    // Add reverse constraints
    for p1 in 0 ..< p {
        for p2 in 0 ..< p {
            temp_prop[2][p2][p1] = temp_prop[0][p1][p2] // -x is reverse of +x
            temp_prop[3][p2][p1] = temp_prop[1][p1][p2] // -y is reverse of +y
            temp_prop[5][p2][p1] = temp_prop[4][p1][p2] // -z is reverse of +z
        }
    }

    // Convert to sparse propagator
    for d in 0 ..< 6 {
        ts.propagator[d] = make([][]int, p, allocator)
        for t1 in 0 ..< p {
            compatible := make([dynamic]int, allocator)
            for t2 in 0 ..< p {
                if temp_prop[d][t1][t2] {
                    append(&compatible, t2)
                }
            }
            ts.propagator[d][t1] = compatible[:]
        }
    }

    load_succeeded = true
    return ts, true
}

// Generate z-axis rotations of a tile
// Generate all 8 square symmetries (4 rotations × 2 reflections) like C#'s SquareSymmetries
// Order matches C#: e, b, a, ba, a², ba², a³, ba³ where a=rotate, b=reflect
tile_rotations :: proc(data: []u8, s, sz: int, allocator := context.allocator) -> [][]u8 {
    things: [8][]u8 = ---

    // Helper to z-rotate a tile
    z_rot :: proc(p: []u8, s, sz: int, alloc: mem.Allocator) -> []u8 {
        r := make([]u8, len(p), alloc)
        for z in 0 ..< sz {
            for y in 0 ..< s {
                for x in 0 ..< s {
                    r[x + y * s + z * s * s] = p[y + (s - 1 - x) * s + z * s * s]
                }
            }
        }
        return r
    }

    // Helper to x-reflect a tile
    x_ref :: proc(p: []u8, s, sz: int, alloc: mem.Allocator) -> []u8 {
        r := make([]u8, len(p), alloc)
        for z in 0 ..< sz {
            for y in 0 ..< s {
                for x in 0 ..< s {
                    r[x + y * s + z * s * s] = p[(s - 1 - x) + y * s + z * s * s]
                }
            }
        }
        return r
    }

    // Generate all 8 variants in C#'s order
    things[0] = make([]u8, len(data), allocator) // e
    copy(things[0], data)
    things[1] = x_ref(things[0], s, sz, allocator) // b
    things[2] = z_rot(things[0], s, sz, allocator) // a
    things[3] = x_ref(things[2], s, sz, allocator) // ba
    things[4] = z_rot(things[2], s, sz, allocator) // a²
    things[5] = x_ref(things[4], s, sz, allocator) // ba²
    things[6] = z_rot(things[4], s, sz, allocator) // a³
    things[7] = x_ref(things[6], s, sz, allocator) // ba³

    // Deduplicate like C#
    result := make([dynamic][]u8, allocator)
    for i in 0 ..< 8 {
        already_have := false
        for j in 0 ..< len(result) {
            if tile_equals(things[i], result[j]) {
                already_have = true
                break
            }
        }
        if !already_have {
            append(&result, things[i])
            things[i] = nil
        }
    }

    for thing in things do delete(thing, allocator)
    return result[:]
}

tile_equals :: proc(a, b: []u8) -> bool {
    if len(a) != len(b) { return false }
    for i in 0 ..< len(a) {
        if a[i] != b[i] { return false }
    }
    return true
}

// Find tile index by data
tile_index :: proc(tiles: []Tile_Info, data: []u8) -> int {
    for i in 0 ..< len(tiles) {
        if tile_equals(tiles[i].data, data) {
            return i
        }
    }
    return -1
}

// Parse tile reference like "z Turn" -> rotate tile "Turn" by z
parse_tile_ref :: proc(
    ref: string,
    tile_indices: map[string]int,
    tiles: []Tile_Info,
    s, sz: int,
    allocator := context.temp_allocator,
) -> (
    []u8,
    bool,
) {
    parts := strings.split(ref, " ", context.temp_allocator)
    name := parts[len(parts) - 1]

    idx, found := tile_indices[name]
    if !found {
        return nil, false
    }

    data := make([]u8, len(tiles[idx].data), allocator)
    copy(data, tiles[idx].data)

    // Apply rotations (z prefix)
    if len(parts) > 1 {
        action := parts[0]
        for i := len(action) - 1; i >= 0; i -= 1 {
            ch := action[i]
            if ch == 'z' {
                // Z-axis rotation (90 degrees)
                rotated := make([]u8, len(data), allocator)
                for zi in 0 ..< sz {
                    for y in 0 ..< s {
                        for x in 0 ..< s {
                            rotated[x + y * s + zi * s * s] = data[y + (s - 1 - x) * s + zi * s * s]
                        }
                    }
                }
                data = rotated
            }
        }
    }

    return data, true
}

add_neighbor_constraint :: proc(
    prop: [][][]bool,
    tile_indices: map[string]int,
    tiles: []Tile_Info,
    s, sz: int,
    left_ref, right_ref: string,
    direction: int,
    allocator := context.allocator,
) {
    left_data, left_ok := parse_tile_ref(left_ref, tile_indices, tiles, s, sz)
    right_data, right_ok := parse_tile_ref(right_ref, tile_indices, tiles, s, sz)

    if !left_ok || !right_ok {
        return
    }

    left_idx := tile_index(tiles, left_data)
    right_idx := tile_index(tiles, right_data)

    if left_idx >= 0 && right_idx >= 0 {
        prop[direction][left_idx][right_idx] = true

        // Also add y-reflected versions for direction 0/1
        if direction == 0 || direction == 1 {
            left_refl := y_reflect_tile(left_data, s, sz)
            right_refl := y_reflect_tile(right_data, s, sz)
            left_refl_idx := tile_index(tiles, left_refl)
            right_refl_idx := tile_index(tiles, right_refl)
            if left_refl_idx >= 0 && right_refl_idx >= 0 {
                prop[direction][left_refl_idx][right_refl_idx] = true
            }
        }
    }
}

y_reflect_tile :: proc(data: []u8, s, sz: int) -> []u8 {
    result := make([]u8, len(data), context.temp_allocator)
    for z in 0 ..< sz {
        for y in 0 ..< s {
            for x in 0 ..< s {
                result[x + y * s + z * s * s] = data[x + (s - 1 - y) * s + z * s * s]
            }
        }
    }
    return result
}

x_reflect_tile :: proc(data: []u8, s, sz: int) -> []u8 {
    result := make([]u8, len(data), context.temp_allocator)
    for z in 0 ..< sz {
        for y in 0 ..< s {
            for x in 0 ..< s {
                result[x + y * s + z * s * s] = data[(s - 1 - x) + y * s + z * s * s]
            }
        }
    }
    return result
}

z_rotate_tile :: proc(data: []u8, s, sz: int) -> []u8 {
    result := make([]u8, len(data), context.temp_allocator)
    for z in 0 ..< sz {
        for y in 0 ..< s {
            for x in 0 ..< s {
                result[x + y * s + z * s * s] = data[y + (s - 1 - x) * s + z * s * s]
            }
        }
    }
    return result
}

// Generate all 4 z-axis rotations plus x-reflections (always 8 variants)
// Matching C# behavior: no deduplication
square_symmetries :: proc(data: []u8, s, sz: int) -> [][]u8 {
    result := make([][]u8, 8, context.temp_allocator)

    current := make([]u8, len(data), context.temp_allocator)
    copy(current, data)

    for rot in 0 ..< 4 {
        // Add rotation
        result[rot * 2] = make([]u8, len(current), context.temp_allocator)
        copy(result[rot * 2], current)
        // Add x-reflection
        result[rot * 2 + 1] = x_reflect_tile(current, s, sz)
        // Rotate for next iteration
        current = z_rotate_tile(current, s, sz)
    }
    return result
}

tile_in_list :: proc(tile: []u8, list: [][]u8, s, sz: int) -> bool {
    for t in list {
        if tiles_equal(tile, t) {
            return true
        }
    }
    return false
}

tiles_equal :: proc(a, b: []u8) -> bool {
    if len(a) != len(b) { return false }
    for i in 0 ..< len(a) {
        if a[i] != b[i] { return false }
    }
    return true
}

// Add propagator constraint by tile data
add_prop :: proc(prop: [][][]bool, tiles: []Tile_Info, dir: int, t1, t2: []u8, s, sz: int) {
    i1 := tile_index(tiles, t1)
    i2 := tile_index(tiles, t2)
    if i1 >= 0 && i2 >= 0 {
        prop[dir][i1][i2] = true
    }
}
