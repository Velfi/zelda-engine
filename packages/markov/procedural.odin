package markov

import "base:runtime"
import "core:encoding/xml"
import "core:fmt"
import "core:strings"

Proc_Tag :: enum u8 {
    one,
    all,
    prl,
    markov,
    sequence,
    path,
    map_,
    convolution,
    convchain,
    wfc,
    rule,
    field,
    observe,
    union_,
}

proc_tag_name :: proc(tag: Proc_Tag) -> string {
    switch tag {
    case .one:
        return "one"
    case .all:
        return "all"
    case .prl:
        return "prl"
    case .markov:
        return "markov"
    case .sequence:
        return "sequence"
    case .path:
        return "path"
    case .map_:
        return "map"
    case .convolution:
        return "convolution"
    case .convchain:
        return "convchain"
    case .wfc:
        return "wfc"
    case .rule:
        return "rule"
    case .field:
        return "field"
    case .observe:
        return "observe"
    case .union_:
        return "union"
    }
    return "one"
}

Proc_Key :: enum u8 {
    values,
    origin,
    in_,
    out,
    fin,
    fout,
    file,
    legend,
    comment,
    steps,
    to,
    symmetry,
    on,
    from_,
    value,
    for_,
    sum,
    symbol,
    color,
    p,
    recompute,
    inertia,
    neighborhood,
    temperature,
    periodic,
    tileset,
    scale,
    sample,
    n,
    folder,
    search,
    longest,
    limit,
    depth_coefficient,
    tiles,
    d,
    output_values,
    black,
    white,
    shannon,
    essential,
    transparent,
    overlap,
    regular,
}

proc_key_name :: proc(key: Proc_Key) -> string {
    switch key {
    case .values:
        return "values"
    case .origin:
        return "origin"
    case .in_:
        return "in"
    case .out:
        return "out"
    case .fin:
        return "fin"
    case .fout:
        return "fout"
    case .file:
        return "file"
    case .legend:
        return "legend"
    case .comment:
        return "comment"
    case .steps:
        return "steps"
    case .to:
        return "to"
    case .symmetry:
        return "symmetry"
    case .on:
        return "on"
    case .from_:
        return "from"
    case .value:
        return "value"
    case .for_:
        return "for"
    case .sum:
        return "sum"
    case .symbol:
        return "symbol"
    case .color:
        return "color"
    case .p:
        return "p"
    case .recompute:
        return "recompute"
    case .inertia:
        return "inertia"
    case .neighborhood:
        return "neighborhood"
    case .temperature:
        return "temperature"
    case .periodic:
        return "periodic"
    case .tileset:
        return "tileset"
    case .scale:
        return "scale"
    case .sample:
        return "sample"
    case .n:
        return "n"
    case .folder:
        return "folder"
    case .search:
        return "search"
    case .longest:
        return "longest"
    case .limit:
        return "limit"
    case .depth_coefficient:
        return "depthCoefficient"
    case .tiles:
        return "tiles"
    case .d:
        return "d"
    case .output_values:
        return "outputValues"
    case .black:
        return "black"
    case .white:
        return "white"
    case .shannon:
        return "shannon"
    case .essential:
        return "essential"
    case .transparent:
        return "transparent"
    case .overlap:
        return "overlap"
    case .regular:
        return "regular"
    }
    return ""
}

Pattern :: struct {
    m:    [3]int,
    data: []u8,
}

Symbol_Set :: distinct []u8
Symmetry_Set :: struct {
    mask: Symmetry_Mask,
}

clone_bytes :: proc(src: []u8, allocator := context.allocator) -> []u8 {
    if len(src) == 0 {
        return nil
    }
    dst := make([]u8, len(src), allocator)
    copy(dst, src)
    return dst
}

pattern_clone :: proc(p: Pattern, allocator := context.allocator) -> Pattern {
    return {m = p.m, data = clone_bytes(p.data, allocator)}
}

pattern_destroy :: proc(p: ^Pattern, allocator := context.allocator) {
    if len(p.data) > 0 {
        delete(p.data, allocator)
        p.data = nil
    }
}

symbol_set_clone :: proc(s: Symbol_Set, allocator := context.allocator) -> Symbol_Set {
    return Symbol_Set(clone_bytes(cast([]u8)s, allocator))
}

symbol_set_destroy :: proc(s: ^Symbol_Set, allocator := context.allocator) {
    b := cast([]u8)s^
    if len(b) > 0 {
        delete(b, allocator)
    }
    s^ = Symbol_Set(nil)
}

symmetry_set_clone :: proc(s: Symmetry_Set) -> Symmetry_Set {
    return s
}

symmetry_set_destroy :: proc(s: ^Symmetry_Set) {
    s^ = {}
}

symmetry_mask :: #force_inline proc(mask: Symmetry_Mask) -> Symmetry_Set {
    return Symmetry_Set{mask = mask}
}

symmetry_2d :: proc(indices: ..int) -> Symmetry_Set {
    mask := Symmetry_Mask(0)
    for idx in indices {
        assert(idx >= 0 && idx < SYMMETRY_2D_BITS, "symmetry_2d index out of range")
        mask |= symmetry_bit(idx)
    }
    return symmetry_mask(mask)
}

symmetry_3d :: proc(indices: ..int) -> Symmetry_Set {
    mask := Symmetry_Mask(0)
    for idx in indices {
        assert(idx >= 0 && idx < SYMMETRY_3D_BITS, "symmetry_3d index out of range")
        mask |= symmetry_bit(idx)
    }
    return symmetry_mask(mask)
}

symmetry_all_2d :: proc() -> Symmetry_Set {
    return symmetry_mask(SYMMETRY_2D_ALL)
}

symmetry_all_3d :: proc() -> Symmetry_Set {
    return symmetry_mask(SYMMETRY_3D_ALL)
}

@(private = "file")
_row_bytes :: proc(cells: ..u8, allocator := context.allocator) -> []u8 {
    result := make([]u8, len(cells), allocator)
    for c, i in cells {
        result[i] = c
    }
    return result
}

@(private = "file")
_row_string :: proc(cells: string, allocator := context.allocator) -> []u8 {
    result := make([]u8, len(cells), allocator)
    for i in 0 ..< len(cells) {
        result[i] = cells[i]
    }
    return result
}

// row creates one pattern row from either bytes or a row string.
row :: proc {
    _row_bytes,
    _row_string,
}

@(private = "file")
_symbols_bytes :: proc(chars: ..u8, allocator := context.allocator) -> Symbol_Set {
    return Symbol_Set(_row_bytes(..chars, allocator = allocator))
}

@(private = "file")
_symbols_string :: proc(chars: string, allocator := context.allocator) -> Symbol_Set {
    return Symbol_Set(_row_string(chars, allocator = allocator))
}

// symbols creates a symbol set for attributes like values/on/from/to.
symbols :: proc {
    _symbols_bytes,
    _symbols_string,
}

// layer builds a 2D pattern directly from row strings (one z-layer).
layer :: proc(rows: ..string, allocator := context.allocator) -> Pattern {
    assert(len(rows) > 0, "layer requires at least one row")
    mx := len(rows[0])
    assert(mx > 0, "layer rows must be non-empty")
    my := len(rows)

    data := make([]u8, mx * my, allocator)
    for r, y in rows {
        assert(len(r) == mx, "layer rows must have equal width")
        for x in 0 ..< mx {
            data[y * mx + x] = r[x]
        }
    }

    return Pattern{m = {mx, my, 1}, data = data}
}

@(private = "file")
_pattern_bytes :: proc(m: [3]int, data: []u8, allocator := context.allocator) -> Pattern {
    assert(m.x > 0 && m.y > 0 && m.z > 0, "pattern dimensions must be positive")
    assert(len(data) == m.x * m.y * m.z, "pattern data size mismatch")
    return Pattern{m = m, data = clone_bytes(data, allocator)}
}

@(private = "file")
_pattern_string :: proc(m: [3]int, data: string, allocator := context.allocator) -> Pattern {
    assert(m.x > 0 && m.y > 0 && m.z > 0, "pattern dimensions must be positive")
    assert(len(data) == m.x * m.y * m.z, "pattern data size mismatch")
    bytes := make([]u8, len(data), allocator)
    for i in 0 ..< len(data) {
        bytes[i] = data[i]
    }
    return Pattern{m = m, data = bytes}
}

// pattern builds a pattern directly from dimensions and cell data.
pattern :: proc {
    _pattern_bytes,
    _pattern_string,
}

@(private = "file")
_pattern_rows_bytes :: proc(rows: ..[]u8, allocator := context.allocator) -> Pattern {
    assert(len(rows) > 0, "pattern_rows requires at least one row")
    mx := len(rows[0])
    assert(mx > 0, "pattern_rows rows must be non-empty")
    my := len(rows)

    data := make([]u8, mx * my, allocator)
    for r, y in rows {
        assert(len(r) == mx, "pattern_rows rows must have equal width")
        copy(data[y * mx:(y + 1) * mx], r)
    }
    return Pattern{m = {mx, my, 1}, data = data}
}

@(private = "file")
_pattern_layers_patterns :: proc(layers: ..Pattern, allocator := context.allocator) -> Pattern {
    assert(len(layers) > 0, "pattern_layers requires at least one layer")
    mx := layers[0].m.x
    my := layers[0].m.y
    assert(mx > 0 && my > 0, "pattern_layers layers must be non-empty")

    total_z := 0
    for l in layers {
        assert(l.m.x == mx && l.m.y == my, "pattern_layers dimensions must match")
        assert(l.m.z > 0, "pattern_layers layers must have positive depth")
        total_z += l.m.z
    }

    layer_size := mx * my
    data := make([]u8, layer_size * total_z, allocator)
    z := 0
    for l in layers {
        count := layer_size * l.m.z
        copy(data[z * layer_size:(z * layer_size) + count], l.data)
        z += l.m.z
    }
    return Pattern{m = {mx, my, total_z}, data = data}
}

pattern_to_string :: proc(p: Pattern, allocator := context.allocator) -> string {
    if p.m.x <= 0 || p.m.y <= 0 || p.m.z <= 0 || len(p.data) == 0 {
        return ""
    }

    b := strings.builder_make(allocator)
    for z := p.m.z - 1; z >= 0; z -= 1 {
        if z < p.m.z - 1 {
            strings.write_string(&b, " ")
        }
        for y in 0 ..< p.m.y {
            if y > 0 {
                strings.write_string(&b, "/")
            }
            start := z * p.m.x * p.m.y + y * p.m.x
            row := p.data[start:start + p.m.x]
            strings.write_string(&b, string(row))
        }
    }
    return strings.to_string(b)
}

symbol_set_to_string :: proc(s: Symbol_Set, allocator := context.allocator) -> string {
    b := cast([]u8)s
    if len(b) == 0 {
        return ""
    }
    out := make([]u8, len(b), allocator)
    copy(out, b)
    return string(out)
}

PROC_MATCH_ANY :: -1
PROC_WRITE_KEEP :: -1
IN_ANY :: PROC_MATCH_ANY
OUT_KEEP :: PROC_WRITE_KEEP

// Symbol_Count describes how many symbols should exist, without naming them.
Symbol_Count :: struct {
    count: int,
}

// Match_Pattern encodes direct rule input waves (bitmasks per cell).
// Use PROC_MATCH_ANY for wildcard cells.
Match_Pattern :: struct {
    m:    [3]int,
    data: []int,
}

// Write_Pattern encodes direct rule outputs (symbol index per cell).
// Use PROC_WRITE_KEEP for unchanged cells.
Write_Pattern :: struct {
    m:    [3]int,
    data: []int,
}

// values_count defines a symbol domain size without using letter alphabets.
values_count :: proc(count: int) -> Symbol_Count {
    assert(count > 0, "values_count must be > 0")
    return Symbol_Count{count = count}
}

// sym references a symbol by index.
sym :: #force_inline proc(index: int) -> int {
    assert(index >= 0, "sym index must be >= 0")
    return index
}

// one_of builds an input-wave bitmask from symbol indices.
one_of :: proc(indices: ..int) -> int {
    assert(len(indices) > 0, "one_of requires at least one symbol index")
    wave := 0
    for idx in indices {
        assert(idx >= 0, "one_of indices must be >= 0")
        wave |= 1 << uint(idx)
    }
    return wave
}

// any marks an input cell as wildcard (match any symbol).
any :: #force_inline proc() -> int {
    return PROC_MATCH_ANY
}

// keep marks an output cell as unchanged.
keep :: #force_inline proc() -> int {
    return PROC_WRITE_KEEP
}

@(private = "file")
_in_exact_cell :: proc(cell: int) -> int {
    if cell == IN_ANY {
        return any()
    }
    assert(cell >= 0, "in_exact cells must be >= 0 or IN_ANY")
    return one_of(sym(cell))
}

@(private = "file")
_out_exact_cell :: proc(cell: int) -> int {
    if cell == OUT_KEEP {
        return keep()
    }
    assert(cell >= 0, "out_exact cells must be >= 0 or OUT_KEEP")
    return sym(cell)
}

// in_exact_row converts exact symbol indices to match waves.
// Use IN_ANY for wildcard cells.
in_exact_row :: proc(cells: ..int, allocator := context.allocator) -> []int {
    row := make([]int, len(cells), allocator)
    for cell, i in cells {
        row[i] = _in_exact_cell(cell)
    }
    return row
}

// out_exact_row converts exact symbol indices to write cells.
// Use OUT_KEEP for unchanged cells.
out_exact_row :: proc(cells: ..int, allocator := context.allocator) -> []int {
    row := make([]int, len(cells), allocator)
    for cell, i in cells {
        row[i] = _out_exact_cell(cell)
    }
    return row
}

in_exact_layer_int :: proc(rows: ..[]int, allocator := context.allocator) -> Match_Pattern {
    assert(len(rows) > 0, "in_exact_layer requires at least one row")
    mx := len(rows[0])
    assert(mx > 0, "in_exact_layer rows must be non-empty")
    my := len(rows)

    data := make([]int, mx * my, allocator)
    for r, y in rows {
        assert(len(r) == mx, "in_exact_layer rows must have equal width")
        for cell, x in r {
            data[y * mx + x] = _in_exact_cell(cell)
        }
    }
    return Match_Pattern{m = {mx, my, 1}, data = data}
}

in_exact_layer_enum :: proc(
    first: []$T,
    rest: ..[]T,
    allocator := context.allocator,
) -> Match_Pattern where runtime.type_is_enum(T) {
    return match_layer_enum(first, ..rest, allocator = allocator)
}

// in_exact_layer builds one exact input layer from indices (or enum rows).
// Use IN_ANY only with []int rows.
in_exact_layer :: proc {
    in_exact_layer_int,
    in_exact_layer_enum,
}

out_exact_layer_int :: proc(rows: ..[]int, allocator := context.allocator) -> Write_Pattern {
    assert(len(rows) > 0, "out_exact_layer requires at least one row")
    mx := len(rows[0])
    assert(mx > 0, "out_exact_layer rows must be non-empty")
    my := len(rows)

    data := make([]int, mx * my, allocator)
    for r, y in rows {
        assert(len(r) == mx, "out_exact_layer rows must have equal width")
        for cell, x in r {
            data[y * mx + x] = _out_exact_cell(cell)
        }
    }
    return Write_Pattern{m = {mx, my, 1}, data = data}
}

out_exact_layer_enum :: proc(
    first: []$T,
    rest: ..[]T,
    allocator := context.allocator,
) -> Write_Pattern where runtime.type_is_enum(T) {
    return write_layer_enum(first, ..rest, allocator = allocator)
}

// out_exact_layer builds one exact output layer from indices (or enum rows).
// Use OUT_KEEP only with []int rows.
out_exact_layer :: proc {
    out_exact_layer_int,
    out_exact_layer_enum,
}

in_exact_layers_int :: proc(first: [][]int, rest: ..[][]int, allocator := context.allocator) -> Match_Pattern {
    my := len(first)
    assert(my > 0, "in_exact_layers layers must be non-empty")
    mx := len(first[0])
    assert(mx > 0, "in_exact_layers rows must be non-empty")

    layer_count := len(rest) + 1
    layer_size := mx * my
    data := make([]int, layer_size * layer_count, allocator)

    assert(len(first) == my, "in_exact_layers dimensions must match")
    for row, y in first {
        assert(len(row) == mx, "in_exact_layers rows must have equal width")
        for cell, x in row {
            data[y * mx + x] = _in_exact_cell(cell)
        }
    }

    for layer, z0 in rest {
        z := z0 + 1
        assert(len(layer) == my, "in_exact_layers dimensions must match")
        for row, y in layer {
            assert(len(row) == mx, "in_exact_layers rows must have equal width")
            for cell, x in row {
                data[z * layer_size + y * mx + x] = _in_exact_cell(cell)
            }
        }
    }
    return Match_Pattern{m = {mx, my, layer_count}, data = data}
}

in_exact_layers_enum :: proc(
    first: [][]$T,
    rest: ..[][]T,
    allocator := context.allocator,
) -> Match_Pattern where runtime.type_is_enum(T) {
    return match_layers_enum(first, ..rest, allocator = allocator)
}

// in_exact_layers builds stacked exact input layers from indices (or enum layers).
// Use IN_ANY only with [][]int layers.
in_exact_layers :: proc {
    in_exact_layers_int,
    in_exact_layers_enum,
}

out_exact_layers_int :: proc(first: [][]int, rest: ..[][]int, allocator := context.allocator) -> Write_Pattern {
    my := len(first)
    assert(my > 0, "out_exact_layers layers must be non-empty")
    mx := len(first[0])
    assert(mx > 0, "out_exact_layers rows must be non-empty")

    layer_count := len(rest) + 1
    layer_size := mx * my
    data := make([]int, layer_size * layer_count, allocator)

    assert(len(first) == my, "out_exact_layers dimensions must match")
    for row, y in first {
        assert(len(row) == mx, "out_exact_layers rows must have equal width")
        for cell, x in row {
            data[y * mx + x] = _out_exact_cell(cell)
        }
    }

    for layer, z0 in rest {
        z := z0 + 1
        assert(len(layer) == my, "out_exact_layers dimensions must match")
        for row, y in layer {
            assert(len(row) == mx, "out_exact_layers rows must have equal width")
            for cell, x in row {
                data[z * layer_size + y * mx + x] = _out_exact_cell(cell)
            }
        }
    }
    return Write_Pattern{m = {mx, my, layer_count}, data = data}
}

out_exact_layers_enum :: proc(
    first: [][]$T,
    rest: ..[][]T,
    allocator := context.allocator,
) -> Write_Pattern where runtime.type_is_enum(T) {
    return write_layers_enum(first, ..rest, allocator = allocator)
}

// out_exact_layers builds stacked exact output layers from indices (or enum layers).
// Use OUT_KEEP only with [][]int layers.
out_exact_layers :: proc {
    out_exact_layers_int,
    out_exact_layers_enum,
}

clone_ints :: proc(src: []int, allocator := context.allocator) -> []int {
    if len(src) == 0 {
        return nil
    }
    dst := make([]int, len(src), allocator)
    copy(dst, src)
    return dst
}

match_pattern_clone :: proc(p: Match_Pattern, allocator := context.allocator) -> Match_Pattern {
    return Match_Pattern{m = p.m, data = clone_ints(p.data, allocator)}
}

match_pattern_destroy :: proc(p: ^Match_Pattern, allocator := context.allocator) {
    if len(p.data) > 0 {
        delete(p.data, allocator)
        p.data = nil
    }
}

write_pattern_clone :: proc(p: Write_Pattern, allocator := context.allocator) -> Write_Pattern {
    return {m = p.m, data = clone_ints(p.data, allocator)}
}

write_pattern_destroy :: proc(p: ^Write_Pattern, allocator := context.allocator) {
    if len(p.data) > 0 {
        delete(p.data, allocator)
        p.data = nil
    }
}

Match_Row :: distinct []int
Write_Row :: distinct []int

// match_row builds an owned input row consumed by match_layer.
match_row :: proc(cells: ..int, allocator := context.allocator) -> Match_Row {
    return Match_Row(clone_ints(cells[:], allocator))
}

// write_row builds an owned output row consumed by write_layer.
write_row :: proc(cells: ..int, allocator := context.allocator) -> Write_Row {
    return Write_Row(clone_ints(cells[:], allocator))
}

@(private = "file")
match_layer_waves :: proc(rows: ..Match_Row, allocator := context.allocator) -> Match_Pattern {
    assert(len(rows) > 0, "match_layer requires at least one row")
    mx := len(rows[0])
    assert(mx > 0, "match_layer rows must be non-empty")
    my := len(rows)

    data := make([]int, mx * my, allocator)
    for r, y in rows {
        assert(len(r) == mx, "match_layer rows must have equal width")
        row := cast([]int)r
        copy(data[y * mx:(y + 1) * mx], row)
        delete(row, allocator)
    }

    return Match_Pattern{m = {mx, my, 1}, data = data}
}

match_layer_enum :: proc(
    first: []$T,
    rest: ..[]T,
    allocator := context.allocator,
) -> Match_Pattern where runtime.type_is_enum(T) {
    mx := len(first)
    assert(mx > 0, "match_layer rows must be non-empty")
    my := len(rest) + 1

    data := make([]int, mx * my, allocator)

    for cell, x in first {
        index := int(cell)
        assert(index >= 0, "match_layer enum value must map to a non-negative symbol index")
        data[x] = one_of(index)
    }
    for r, y0 in rest {
        y := y0 + 1
        assert(len(r) == mx, "match_layer rows must have equal width")
        for cell, x in r {
            index := int(cell)
            assert(index >= 0, "match_layer enum value must map to a non-negative symbol index")
            data[y * mx + x] = one_of(index)
        }
    }

    return Match_Pattern{m = {mx, my, 1}, data = data}
}

// match_layer builds one z-layer from raw input-wave rows (`[]int`).
match_layer :: proc {
    match_layer_waves,
}

@(private = "file")
write_layer_cells :: proc(rows: ..Write_Row, allocator := context.allocator) -> Write_Pattern {
    assert(len(rows) > 0, "write_layer requires at least one row")
    mx := len(rows[0])
    assert(mx > 0, "write_layer rows must be non-empty")
    my := len(rows)

    data := make([]int, mx * my, allocator)
    for r, y in rows {
        assert(len(r) == mx, "write_layer rows must have equal width")
        row := cast([]int)r
        copy(data[y * mx:(y + 1) * mx], row)
        delete(row, allocator)
    }

    return Write_Pattern{m = {mx, my, 1}, data = data}
}

write_layer_enum :: proc(
    first: []$T,
    rest: ..[]T,
    allocator := context.allocator,
) -> Write_Pattern where runtime.type_is_enum(T) {
    mx := len(first)
    assert(mx > 0, "write_layer rows must be non-empty")
    my := len(rest) + 1

    data := make([]int, mx * my, allocator)

    for cell, x in first {
        index := int(cell)
        assert(index >= 0, "write_layer enum value must map to a non-negative symbol index")
        data[x] = index
    }
    for r, y0 in rest {
        y := y0 + 1
        assert(len(r) == mx, "write_layer rows must have equal width")
        for cell, x in r {
            index := int(cell)
            assert(index >= 0, "write_layer enum value must map to a non-negative symbol index")
            data[y * mx + x] = index
        }
    }

    return Write_Pattern{m = {mx, my, 1}, data = data}
}

// write_layer builds one z-layer from raw output rows (`[]int`).
write_layer :: proc {
    write_layer_cells,
}

@(private = "file")
match_layers_patterns :: proc(layers: ..Match_Pattern, allocator := context.allocator) -> Match_Pattern {
    assert(len(layers) > 0, "match_layers requires at least one layer")
    mx := layers[0].m.x
    my := layers[0].m.y
    assert(mx > 0 && my > 0, "match_layers layers must be non-empty")

    total_z := 0
    for l in layers {
        assert(l.m.x == mx && l.m.y == my, "match_layers dimensions must match")
        assert(l.m.z > 0, "match_layers layers must have positive depth")
        total_z += l.m.z
    }

    layer_size := mx * my
    data := make([]int, layer_size * total_z, allocator)
    z := 0
    for l in layers {
        count := layer_size * l.m.z
        copy(data[z * layer_size:(z * layer_size) + count], l.data)
        z += l.m.z
    }

    return Match_Pattern{m = {mx, my, total_z}, data = data}
}

match_layers_enum :: proc(
    first: [][]$T,
    rest: ..[][]T,
    allocator := context.allocator,
) -> Match_Pattern where runtime.type_is_enum(T) {
    my := len(first)
    assert(my > 0, "match_layers layers must be non-empty")
    mx := len(first[0])
    assert(mx > 0, "match_layers rows must be non-empty")

    layer_count := len(rest) + 1
    layer_size := mx * my
    data := make([]int, layer_size * layer_count, allocator)

    assert(len(first) == my, "match_layers dimensions must match")
    for row, y in first {
        assert(len(row) == mx, "match_layers rows must have equal width")
        for cell, x in row {
            index := int(cell)
            assert(index >= 0, "match_layers enum value must map to a non-negative symbol index")
            data[y * mx + x] = one_of(index)
        }
    }

    for layer, z0 in rest {
        z := z0 + 1
        assert(len(layer) == my, "match_layers dimensions must match")
        for row, y in layer {
            assert(len(row) == mx, "match_layers rows must have equal width")
            for cell, x in row {
                index := int(cell)
                assert(index >= 0, "match_layers enum value must map to a non-negative symbol index")
                data[z * layer_size + y * mx + x] = one_of(index)
            }
        }
    }

    return Match_Pattern{m = {mx, my, layer_count}, data = data}
}

// match_layers builds stacked typed patterns (`Match_Pattern` overload).
match_layers :: proc {
    match_layers_patterns,
}

@(private = "file")
write_layers_patterns :: proc(layers: ..Write_Pattern, allocator := context.allocator) -> Write_Pattern {
    assert(len(layers) > 0, "write_layers requires at least one layer")
    mx := layers[0].m.x
    my := layers[0].m.y
    assert(mx > 0 && my > 0, "write_layers layers must be non-empty")

    total_z := 0
    for l in layers {
        assert(l.m.x == mx && l.m.y == my, "write_layers dimensions must match")
        assert(l.m.z > 0, "write_layers layers must have positive depth")
        total_z += l.m.z
    }

    layer_size := mx * my
    data := make([]int, layer_size * total_z, allocator)
    z := 0
    for l in layers {
        count := layer_size * l.m.z
        copy(data[z * layer_size:(z * layer_size) + count], l.data)
        z += l.m.z
    }

    return Write_Pattern{m = {mx, my, total_z}, data = data}
}

write_layers_enum :: proc(
    first: [][]$T,
    rest: ..[][]T,
    allocator := context.allocator,
) -> Write_Pattern where runtime.type_is_enum(T) {
    my := len(first)
    assert(my > 0, "write_layers layers must be non-empty")
    mx := len(first[0])
    assert(mx > 0, "write_layers rows must be non-empty")

    layer_count := len(rest) + 1
    layer_size := mx * my
    data := make([]int, layer_size * layer_count, allocator)

    assert(len(first) == my, "write_layers dimensions must match")
    for row, y in first {
        assert(len(row) == mx, "write_layers rows must have equal width")
        for cell, x in row {
            index := int(cell)
            assert(index >= 0, "write_layers enum value must map to a non-negative symbol index")
            data[y * mx + x] = index
        }
    }

    for layer, z0 in rest {
        z := z0 + 1
        assert(len(layer) == my, "write_layers dimensions must match")
        for row, y in layer {
            assert(len(row) == mx, "write_layers rows must have equal width")
            for cell, x in row {
                index := int(cell)
                assert(index >= 0, "write_layers enum value must map to a non-negative symbol index")
                data[z * layer_size + y * mx + x] = index
            }
        }
    }

    return Write_Pattern{m = {mx, my, layer_count}, data = data}
}

// write_layers builds stacked typed patterns (`Write_Pattern` overload).
write_layers :: proc {
    write_layers_patterns,
}

Proc_Value :: union {
    string,
    int,
    f64,
    bool,
    Pattern,
    Symbol_Set,
    Symmetry_Set,
    Symbol_Count,
    Match_Pattern,
    Write_Pattern,
}

Proc_Attr_Key :: union {
    Proc_Key,
    string,
}

// Proc_Attr is a typed procedural equivalent of an XML attribute.
Proc_Attr :: struct {
    key:       Proc_Attr_Key,
    value:     Proc_Value,
    allocator: runtime.Allocator,
}

// Proc_Node is a procedural equivalent of an XML model node.
Proc_Node :: struct {
    ident:     string,
    attrs:     []Proc_Attr,
    children:  []Proc_Node,
    allocator: runtime.Allocator,
}

Node_Item :: union {
    Proc_Attr,
    Proc_Node,
}

Proc_Typed_Attr_Key :: struct {
    elem: xml.Element_ID,
    key:  string,
}

Proc_Doc_Metadata :: struct {
    doc:   ^xml.Document,
    attrs: map[Proc_Typed_Attr_Key]Proc_Value,
}

@(private = "file")
current_proc_doc_metadata: ^Proc_Doc_Metadata

proc_doc_typed_value :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string) -> (Proc_Value, bool) {
    if current_proc_doc_metadata == nil || current_proc_doc_metadata.doc != doc {
        return {}, false
    }
    lookup: Proc_Typed_Attr_Key = {
        elem = elem_id,
        key  = key,
    }
    value, ok := current_proc_doc_metadata.attrs[lookup]
    return value, ok
}

typed_attr_pattern :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string) -> (Pattern, bool) {
    if value, ok := proc_doc_typed_value(doc, elem_id, key); ok {
        #partial switch v in value {
        case Pattern:
            return v, true
        }
    }
    return {}, false
}

typed_attr_symbols :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string) -> (Symbol_Set, bool) {
    if value, ok := proc_doc_typed_value(doc, elem_id, key); ok {
        #partial switch v in value {
        case Symbol_Set:
            return v, true
        }
    }
    return Symbol_Set(nil), false
}

typed_attr_symmetry :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string) -> (Symmetry_Set, bool) {
    if value, ok := proc_doc_typed_value(doc, elem_id, key); ok {
        #partial switch v in value {
        case Symmetry_Set:
            return v, true
        }
    }
    return {}, false
}

typed_attr_symbol_count :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string) -> (int, bool) {
    if value, ok := proc_doc_typed_value(doc, elem_id, key); ok {
        #partial switch v in value {
        case Symbol_Count:
            return v.count, true
        }
    }
    return 0, false
}

typed_attr_match_pattern :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string) -> (Match_Pattern, bool) {
    if value, ok := proc_doc_typed_value(doc, elem_id, key); ok {
        #partial switch v in value {
        case Match_Pattern:
            return v, true
        }
    }
    return {}, false
}

typed_attr_write_pattern :: proc(doc: ^xml.Document, elem_id: xml.Element_ID, key: string) -> (Write_Pattern, bool) {
    if value, ok := proc_doc_typed_value(doc, elem_id, key); ok {
        #partial switch v in value {
        case Write_Pattern:
            return v, true
        }
    }
    return {}, false
}

@(private = "file")
_attr_string :: proc(key, val: string) -> Proc_Attr {
    return Proc_Attr{key, val, {}}
}

@(private = "file")
_attr_int :: proc(key: string, val: int) -> Proc_Attr {
    return Proc_Attr{key, val, {}}
}

@(private = "file")
_attr_float :: proc(key: string, val: f64) -> Proc_Attr {
    return Proc_Attr{key, val, {}}
}

@(private = "file")
_attr_bool :: proc(key: string, val: bool) -> Proc_Attr {
    return Proc_Attr{key, val, {}}
}

@(private = "file")
_attr_pattern :: proc(key: string, val: Pattern, allocator := context.allocator) -> Proc_Attr {
    return Proc_Attr{key, val, allocator}
}

@(private = "file")
_attr_symbols :: proc(key: string, val: Symbol_Set, allocator := context.allocator) -> Proc_Attr {
    return Proc_Attr{key, val, allocator}
}

@(private = "file")
_attr_symmetry :: proc(key: string, val: Symmetry_Set) -> Proc_Attr {
    return Proc_Attr{key, symmetry_set_clone(val), {}}
}

@(private = "file")
_attr_symbol_count :: proc(key: string, val: Symbol_Count) -> Proc_Attr {
    return Proc_Attr{key, val, {}}
}

@(private = "file")
_attr_match_pattern :: proc(key: string, val: Match_Pattern, allocator := context.allocator) -> Proc_Attr {
    return Proc_Attr{key, val, allocator}
}

@(private = "file")
_attr_write_pattern :: proc(key: string, val: Write_Pattern, allocator := context.allocator) -> Proc_Attr {
    return Proc_Attr{key, val, allocator}
}

// attr creates a typed attribute from a raw string key.
attr :: proc {
    _attr_string,
    _attr_int,
    _attr_float,
    _attr_bool,
    _attr_pattern,
    _attr_symbols,
    _attr_symmetry,
    _attr_symbol_count,
    _attr_match_pattern,
    _attr_write_pattern,
}

// Backwards-compatible alias.
proc_attr :: proc {
    _attr_string,
    _attr_int,
    _attr_float,
    _attr_bool,
    _attr_pattern,
    _attr_symbols,
    _attr_symmetry,
    _attr_symbol_count,
    _attr_match_pattern,
    _attr_write_pattern,
}

@(private = "file")
_kattr_string :: proc(key: Proc_Key, val: string) -> Proc_Attr {
    return Proc_Attr{key, val, {}}
}

@(private = "file")
_kattr_int :: proc(key: Proc_Key, val: int) -> Proc_Attr {
    return {key, val, {}}
}

@(private = "file")
_kattr_float :: proc(key: Proc_Key, val: f64) -> Proc_Attr {
    return {key, val, {}}
}

@(private = "file")
_kattr_bool :: proc(key: Proc_Key, val: bool) -> Proc_Attr {
    return {key, val, {}}
}

@(private = "file")
_kattr_pattern :: proc(key: Proc_Key, val: Pattern, allocator := context.allocator) -> Proc_Attr {
    return {key, val, allocator}
}

@(private = "file")
_kattr_symbols :: proc(key: Proc_Key, val: Symbol_Set, allocator := context.allocator) -> Proc_Attr {
    return {key, val, allocator}
}

@(private = "file")
_kattr_symmetry :: proc(key: Proc_Key, val: Symmetry_Set) -> Proc_Attr {
    return {key, symmetry_set_clone(val), {}}
}

@(private = "file")
_kattr_symbol_count :: proc(key: Proc_Key, val: Symbol_Count) -> Proc_Attr {
    return {key, val, {}}
}

@(private = "file")
_kattr_match_pattern :: proc(key: Proc_Key, val: Match_Pattern, allocator := context.allocator) -> Proc_Attr {
    return {key, val, allocator}
}

@(private = "file")
_kattr_write_pattern :: proc(key: Proc_Key, val: Write_Pattern, allocator := context.allocator) -> Proc_Attr {
    return {key, val, allocator}
}

// kattr creates a typed attribute from a strongly-typed Proc_Key.
kattr :: proc {
    _kattr_string,
    _kattr_int,
    _kattr_float,
    _kattr_bool,
    _kattr_pattern,
    _kattr_symbols,
    _kattr_symmetry,
    _kattr_symbol_count,
    _kattr_match_pattern,
    _kattr_write_pattern,
}

// Backwards-compatible alias.
proc_kattr :: proc {
    _kattr_string,
    _kattr_int,
    _kattr_float,
    _kattr_bool,
    _kattr_pattern,
    _kattr_symbols,
    _kattr_symmetry,
    _kattr_symbol_count,
    _kattr_match_pattern,
    _kattr_write_pattern,
}

attrs :: proc(values: ..Proc_Attr, allocator := context.allocator) -> []Proc_Attr {
    if len(values) == 0 {
        return nil
    }

    out := make([]Proc_Attr, len(values), allocator)
    for value, i in values {
        out[i] = value
    }
    return out
}

children :: proc(values: ..Proc_Node, allocator := context.allocator) -> []Proc_Node {
    if len(values) == 0 {
        return nil
    }

    out := make([]Proc_Node, len(values), allocator)
    for value, i in values {
        out[i] = value
    }
    return out
}

@(private = "file")
_tag_node_items :: proc(tag: Proc_Tag, items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    attr_count := 0
    child_count := 0
    for item in items {
        #partial switch item in item {
        case Proc_Attr:
            attr_count += 1
        case Proc_Node:
            child_count += 1
        }
    }

    attrs: []Proc_Attr
    if attr_count > 0 {
        attrs = make([]Proc_Attr, attr_count, allocator)
    }
    children: []Proc_Node
    if child_count > 0 {
        children = make([]Proc_Node, child_count, allocator)
    }

    ai := 0
    ci := 0
    for item in items {
        #partial switch item in item {
        case Proc_Attr:
            attrs[ai] = item
            ai += 1
        case Proc_Node:
            children[ci] = item
            ci += 1
        }
    }
    result := proc_node_tag(tag, attrs, children, allocator)
    delete(attrs, allocator)
    delete(children, allocator)
    return result
}

@(private = "file")
_tag_node :: proc(
    tag: Proc_Tag,
    attrs: []Proc_Attr = nil,
    children: []Proc_Node = nil,
    allocator := context.allocator,
) -> Proc_Node {
    return proc_node_tag(tag, attrs, children, allocator)
}

@(private = "file")
_tag_node_attrs :: proc(
    tag: Proc_Tag,
    first: Proc_Attr,
    rest: ..Proc_Attr,
    allocator := context.allocator,
) -> Proc_Node {
    values := make([]Proc_Attr, len(rest) + 1, allocator)
    values[0] = first
    for value, i in rest {
        values[i + 1] = value
    }
    result := proc_node_tag(tag, values, nil, allocator)
    delete(values, allocator)
    return result
}

@(private = "file")
_node_one :: proc(attrs: []Proc_Attr = nil, children: []Proc_Node = nil, allocator := context.allocator) -> Proc_Node {
    return _tag_node(.one, attrs, children, allocator)
}

@(private = "file")
_node_one_items :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.one, ..items, allocator = allocator)
}

@(private = "file")
_node_one_attrs :: proc(first: Proc_Attr, rest: ..Proc_Attr, allocator := context.allocator) -> Proc_Node {
    return _tag_node_attrs(.one, first, ..rest, allocator = allocator)
}

one :: proc {
    _node_one_items,
    _node_one_attrs,
    _node_one,
}

@(private = "file")
_node_all :: proc(attrs: []Proc_Attr = nil, children: []Proc_Node = nil, allocator := context.allocator) -> Proc_Node {
    return _tag_node(.all, attrs, children, allocator)
}

@(private = "file")
_node_all_items :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.all, ..items, allocator = allocator)
}

@(private = "file")
_node_all_attrs :: proc(first: Proc_Attr, rest: ..Proc_Attr, allocator := context.allocator) -> Proc_Node {
    return _tag_node_attrs(.all, first, ..rest, allocator = allocator)
}

all :: proc {
    _node_all_items,
    _node_all_attrs,
    _node_all,
}

@(private = "file")
_node_prl :: proc(attrs: []Proc_Attr = nil, children: []Proc_Node = nil, allocator := context.allocator) -> Proc_Node {
    return _tag_node(.prl, attrs, children, allocator)
}

@(private = "file")
_node_prl_items :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.prl, ..items, allocator = allocator)
}

@(private = "file")
_node_prl_attrs :: proc(first: Proc_Attr, rest: ..Proc_Attr, allocator := context.allocator) -> Proc_Node {
    return _tag_node_attrs(.prl, first, ..rest, allocator = allocator)
}

prl :: proc {
    _node_prl_items,
    _node_prl_attrs,
    _node_prl,
}

@(private = "file")
_node_sequence :: proc(
    attrs: []Proc_Attr = nil,
    children: []Proc_Node = nil,
    allocator := context.allocator,
) -> Proc_Node {
    return _tag_node(.sequence, attrs, children, allocator)
}

@(private = "file")
_node_sequence_items :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.sequence, ..items, allocator = allocator)
}

@(private = "file")
_node_sequence_attrs :: proc(first: Proc_Attr, rest: ..Proc_Attr, allocator := context.allocator) -> Proc_Node {
    return _tag_node_attrs(.sequence, first, ..rest, allocator = allocator)
}

sequence :: proc {
    _node_sequence_items,
    _node_sequence_attrs,
    _node_sequence,
}

@(private = "file")
_node_markov :: proc(
    attrs: []Proc_Attr = nil,
    children: []Proc_Node = nil,
    allocator := context.allocator,
) -> Proc_Node {
    return _tag_node(.markov, attrs, children, allocator)
}

@(private = "file")
_node_markov_items :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.markov, ..items, allocator = allocator)
}

@(private = "file")
_node_markov_attrs :: proc(first: Proc_Attr, rest: ..Proc_Attr, allocator := context.allocator) -> Proc_Node {
    return _tag_node_attrs(.markov, first, ..rest, allocator = allocator)
}

markov_node :: proc {
    _node_markov_items,
    _node_markov_attrs,
    _node_markov,
}

path_node :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.path, ..items, allocator = allocator)
}

map_node :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.map_, ..items, allocator = allocator)
}

convolution_node :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.convolution, ..items, allocator = allocator)
}

convchain_node :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.convchain, ..items, allocator = allocator)
}

wfc_node :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.wfc, ..items, allocator = allocator)
}

rule_node :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.rule, ..items, allocator = allocator)
}

field_node :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.field, ..items, allocator = allocator)
}

observe_node :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.observe, ..items, allocator = allocator)
}

union_node :: proc(items: ..Node_Item, allocator := context.allocator) -> Proc_Node {
    return _tag_node_items(.union_, ..items, allocator = allocator)
}

rule_attrs :: proc(
    in_attr: Proc_Value,
    out_attr: Proc_Value,
    attrs: []Proc_Attr = nil,
    allocator := context.allocator,
) -> Proc_Node {
    values := make([]Proc_Attr, len(attrs) + 2, allocator)
    values[0] = Proc_Attr{.in_, in_attr, allocator}
    values[1] = Proc_Attr{.out, out_attr, allocator}
    for attr, i in attrs {
        values[i + 2] = attr
    }
    result := proc_node_tag(.rule, values, nil, allocator)
    delete(values, allocator)
    return result
}

rule_extra :: proc(
    in_attr: Proc_Value,
    out_attr: Proc_Value,
    first: Proc_Attr,
    rest: ..Proc_Attr,
    allocator := context.allocator,
) -> Proc_Node {
    values := make([]Proc_Attr, len(rest) + 1, allocator)
    values[0] = first
    for attr, i in rest {
        values[i + 1] = attr
    }
    result := rule_attrs(in_attr, out_attr, values, allocator = allocator)
    delete(values, allocator)
    return result
}

// rule builds a rule node from in/out typed values plus optional extra attrs.
rule :: proc {
    rule_extra,
    rule_attrs,
}

clone_attr :: proc(attr: Proc_Attr, allocator := context.allocator) -> Proc_Attr {
    result := attr
    #partial switch v in attr.value {
    case Pattern:
        result.value = pattern_clone(v, allocator)
    case Symbol_Set:
        result.value = symbol_set_clone(v, allocator)
    case Symmetry_Set:
        result.value = symmetry_set_clone(v)
    case Match_Pattern:
        result.value = match_pattern_clone(v, allocator)
    case Write_Pattern:
        result.value = write_pattern_clone(v, allocator)
    }
    result.allocator = allocator
    return result
}

destroy_attr :: proc(attr: ^Proc_Attr, allocator := context.allocator) {
    owned_allocator := allocator
    if attr.allocator.procedure != nil do owned_allocator = attr.allocator
    #partial switch v in attr.value {
    case Pattern:
        p := v
        pattern_destroy(&p, owned_allocator)
    case Symbol_Set:
        s := v
        symbol_set_destroy(&s, owned_allocator)
    case Symmetry_Set:
        s := v
        symmetry_set_destroy(&s)
    case Match_Pattern:
        p := v
        match_pattern_destroy(&p, owned_allocator)
    case Write_Pattern:
        p := v
        write_pattern_destroy(&p, owned_allocator)
    }
    attr^ = {}
}

proc_node :: proc(
    ident: string,
    attrs: []Proc_Attr = nil,
    children: []Proc_Node = nil,
    allocator := context.allocator,
) -> Proc_Node {
    node: Proc_Node = {
        ident     = ident,
        allocator = allocator,
    }
    if len(attrs) > 0 {
        node.attrs = make([]Proc_Attr, len(attrs), allocator)
        for attr, i in attrs {
            // The slice backing is borrowed, but typed payload allocations move
            // into the returned node and are released by proc_node_destroy.
            node.attrs[i] = attr
        }
    }
    if len(children) > 0 {
        node.children = make([]Proc_Node, len(children), allocator)
        for child, i in children {
            // Child-owned payloads likewise move while the borrowed slice
            // backing is copied.
            node.children[i] = child
        }
    }
    return node
}

proc_node_tag :: proc(
    tag: Proc_Tag,
    attrs: []Proc_Attr = nil,
    children: []Proc_Node = nil,
    allocator := context.allocator,
) -> Proc_Node {
    return proc_node(proc_tag_name(tag), attrs, children, allocator)
}

node_ident :: proc(
    ident: string,
    attrs: []Proc_Attr = nil,
    children: []Proc_Node = nil,
    allocator := context.allocator,
) -> Proc_Node {
    return proc_node(ident, attrs, children, allocator)
}

node_tag :: proc(
    tag: Proc_Tag,
    attrs: []Proc_Attr = nil,
    children: []Proc_Node = nil,
    allocator := context.allocator,
) -> Proc_Node {
    return proc_node_tag(tag, attrs, children, allocator)
}

node_ident_attrs :: proc(
    ident: string,
    first: Proc_Attr,
    rest: ..Proc_Attr,
    allocator := context.allocator,
) -> Proc_Node {
    values := make([]Proc_Attr, len(rest) + 1, allocator)
    values[0] = first
    for value, i in rest {
        values[i + 1] = value
    }
    result := proc_node(ident, values, nil, allocator)
    delete(values, allocator)
    return result
}

node_tag_attrs :: proc(
    tag: Proc_Tag,
    first: Proc_Attr,
    rest: ..Proc_Attr,
    allocator := context.allocator,
) -> Proc_Node {
    values := make([]Proc_Attr, len(rest) + 1, allocator)
    values[0] = first
    for value, i in rest {
        values[i + 1] = value
    }
    result := proc_node_tag(tag, values, nil, allocator)
    delete(values, allocator)
    return result
}

// node is the preferred constructor for procedural nodes.
node :: proc {
    node_ident_attrs,
    node_tag_attrs,
    node_ident,
    node_tag,
}

proc_node_destroy :: proc(node: ^Proc_Node, allocator := context.allocator) {
    owned_allocator := allocator
    if node.allocator.procedure != nil do owned_allocator = node.allocator
    for i in 0 ..< len(node.children) {
        proc_node_destroy(&node.children[i], owned_allocator)
    }
    if len(node.attrs) > 0 {
        for i in 0 ..< len(node.attrs) {
            destroy_attr(&node.attrs[i], owned_allocator)
        }
        delete(node.attrs, owned_allocator)
        node.attrs = nil
    }
    if len(node.children) > 0 {
        delete(node.children, owned_allocator)
        node.children = nil
    }
    node^ = {}
}

@(private = "file")
_pattern_rows_string :: proc(rows: ..string, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    for row, i in rows {
        if i > 0 {
            strings.write_string(&b, "/")
        }
        strings.write_string(&b, row)
    }
    return strings.to_string(b)
}

@(private = "file")
_pattern_layers_string :: proc(layers: ..string, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    for layer, i in layers {
        if i > 0 {
            strings.write_string(&b, " ")
        }
        strings.write_string(&b, layer)
    }
    return strings.to_string(b)
}

// pattern_rows builds either:
// - legacy string rows (string overload), or
// - typed 2D Pattern rows ([]u8 overload).
pattern_rows :: proc {
    _pattern_rows_string,
    _pattern_rows_bytes,
}

// pattern_layers builds either:
// - legacy layered string (string overload), or
// - typed 3D Pattern stack (Pattern overload).
pattern_layers :: proc {
    _pattern_layers_string,
    _pattern_layers_patterns,
}

attr_value_string :: proc(doc: ^xml.Document, value: Proc_Value, allocator := context.allocator) -> string {
    switch v in value {
    case string:
        return v
    case int:
        s := fmt.aprintf("%d", v, allocator = allocator)
        append(&doc.strings_to_free, s)
        return s
    case f64:
        s := fmt.aprintf("%g", v, allocator = allocator)
        append(&doc.strings_to_free, s)
        return s
    case bool:
        return v ? "True" : "False"
    case Pattern:
        s := pattern_to_string(v, allocator)
        append(&doc.strings_to_free, s)
        return s
    case Symbol_Set:
        s := symbol_set_to_string(v, allocator)
        append(&doc.strings_to_free, s)
        return s
    case Symmetry_Set:
        return ""
    case Symbol_Count:
        if s, ok := value_string_for_count(v.count, allocator); ok {
            append(&doc.strings_to_free, s)
            return s
        }
        s := fmt.aprintf("%d", v.count, allocator = allocator)
        append(&doc.strings_to_free, s)
        return s
    case Match_Pattern:
        return ""
    case Write_Pattern:
        return ""
    }
    return ""
}

attr_key_string :: proc(key: Proc_Attr_Key) -> string {
    switch k in key {
    case Proc_Key:
        return proc_key_name(k)
    case string:
        return k
    }
    return ""
}

append_proc_node :: proc(
    doc: ^xml.Document,
    meta: ^Proc_Doc_Metadata,
    node: Proc_Node,
    parent: xml.Element_ID,
    has_parent: bool,
    allocator := context.allocator,
) -> xml.Element_ID {
    id := cast(xml.Element_ID)len(doc.elements)

    elem: xml.Element
    elem.ident = node.ident
    if has_parent {
        elem.parent = parent
    }
    elem.attribs = make([dynamic]xml.Attribute, allocator)
    elem.value = make([dynamic]xml.Value, allocator)

    for attr in node.attrs {
        key := attr_key_string(attr.key)
        if meta != nil {
            meta.attrs[{elem = id, key = key}] = attr.value
        }

        append(&elem.attribs, xml.Attribute{key = key, val = attr_value_string(doc, attr.value, allocator)})
    }

    append(&doc.elements, elem)

    for child in node.children {
        child_id := append_proc_node(doc, meta, child, id, true, allocator)
        append(&doc.elements[id].value, xml.Value(child_id))
    }

    return id
}

proc_document :: proc(root: Proc_Node, allocator := context.allocator) -> (^xml.Document, Proc_Doc_Metadata) {
    doc := new(xml.Document, allocator)
    doc.elements = make([dynamic]xml.Element, allocator)
    meta: Proc_Doc_Metadata = {
        doc   = doc,
        attrs = make(map[Proc_Typed_Attr_Key]Proc_Value, allocator),
    }

    append_proc_node(doc, &meta, root, 0, false, allocator)
    doc.element_count = cast(xml.Element_ID)len(doc.elements)
    return doc, meta
}

// load_model_proc creates an interpreter from a procedural model tree.
load_model_proc :: proc(root: Proc_Node, m: [3]int, allocator := context.allocator) -> (^Interpreter, bool) {
    root_owned := root
    defer proc_node_destroy(&root_owned, allocator)
    doc, meta := proc_document(root_owned, allocator)
    defer delete(meta.attrs)
    prev_meta := current_proc_doc_metadata
    current_proc_doc_metadata = &meta
    defer current_proc_doc_metadata = prev_meta
    defer xml.destroy(doc, allocator)
    return load_model_document(doc, m, allocator)
}
