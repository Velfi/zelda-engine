package markov

// Symmetry subgroup definitions
// For 2D (square): 8 elements of dihedral group D4
// For 3D (cube): 48 elements of octahedral group

Symmetry_Mask :: distinct u64

SYMMETRY_2D_BITS :: 8
SYMMETRY_3D_BITS :: 48

SYMMETRY_2D_IDENTITY :: Symmetry_Mask(0x0000000000000001)
SYMMETRY_2D_X :: Symmetry_Mask(0x0000000000000003)
SYMMETRY_2D_Y :: Symmetry_Mask(0x0000000000000021)
SYMMETRY_2D_XY_FLIPS :: Symmetry_Mask(0x0000000000000033)
SYMMETRY_2D_XY_PLUS :: Symmetry_Mask(0x0000000000000055)
SYMMETRY_2D_ALL :: Symmetry_Mask(0x00000000000000ff)

SYMMETRY_3D_IDENTITY :: Symmetry_Mask(0x0000000000000001)
SYMMETRY_3D_X :: Symmetry_Mask(0x0000000000000003)
SYMMETRY_3D_Z :: Symmetry_Mask(0x0000000000020001)
SYMMETRY_3D_XY :: Symmetry_Mask(0x00000000000000ff)
SYMMETRY_3D_XYZ_PLUS :: Symmetry_Mask(0x0000555555555555)
SYMMETRY_3D_ALL :: Symmetry_Mask(0x0000ffffffffffff)

symmetry_bit :: #force_inline proc(index: int) -> Symmetry_Mask {
    return Symmetry_Mask(1) << cast(u64)index
}

symmetry_has :: #force_inline proc(mask: Symmetry_Mask, index: int) -> bool {
    return (mask & symmetry_bit(index)) != Symmetry_Mask(0)
}

symmetry_valid_mask :: #force_inline proc(mask: Symmetry_Mask, is_2d: bool) -> bool {
    allowed := is_2d ? SYMMETRY_2D_ALL : SYMMETRY_3D_ALL
    return (mask & ~allowed) == Symmetry_Mask(0)
}

get_square_subgroup :: proc(name: string) -> (Symmetry_Mask, bool) {
    switch name {
    case "()":
        return SYMMETRY_2D_IDENTITY, true
    case "(x)":
        return SYMMETRY_2D_X, true
    case "(y)":
        return SYMMETRY_2D_Y, true
    case "(x)(y)":
        return SYMMETRY_2D_XY_FLIPS, true
    case "(xy+)":
        return SYMMETRY_2D_XY_PLUS, true
    case "(xy)":
        return SYMMETRY_2D_ALL, true
    }
    return Symmetry_Mask(0), false
}

// Cube subgroups - indices into the 48-element group
cube_subgroup_mask :: proc(name: string) -> (Symmetry_Mask, bool) {
    switch name {
    case "()":
        return SYMMETRY_3D_IDENTITY, true
    case "(x)":
        return SYMMETRY_3D_X, true
    case "(z)":
        return SYMMETRY_3D_Z, true
    case "(xy)":
        return SYMMETRY_3D_XY, true
    case "(xyz+)":
        return SYMMETRY_3D_XYZ_PLUS, true
    case "(xyz)":
        return SYMMETRY_3D_ALL, true
    }
    return Symmetry_Mask(0), false
}

get_symmetry :: proc(is_2d: bool, name: string, dflt: Symmetry_Mask) -> (Symmetry_Mask, bool) {
    if name == "" {
        return dflt, true
    }
    if is_2d {
        return get_square_subgroup(name)
    }
    return cube_subgroup_mask(name)
}

// Rule rotation around Z axis (swap X/Y, negate Y)
rule_z_rotated :: proc(r: ^Rule, c: int, allocator := context.allocator) -> Rule {
    newinput := make([]int, len(r.input), allocator)
    for z in 0 ..< r.im.z {
        for y in 0 ..< r.im.x {
            for x in 0 ..< r.im.y {
                newinput[x + y * r.im.y + z * r.im.x * r.im.y] =
                    r.input[r.im.x - 1 - y + x * r.im.x + z * r.im.x * r.im.y]
            }
        }
    }

    newoutput := make([]u8, len(r.output), allocator)
    for z in 0 ..< r.om.z {
        for y in 0 ..< r.om.x {
            for x in 0 ..< r.om.y {
                newoutput[x + y * r.om.y + z * r.om.x * r.om.y] =
                    r.output[r.om.x - 1 - y + x * r.om.x + z * r.om.x * r.om.y]
            }
        }
    }

    result: Rule
    rule_init(&result, newinput, {r.im.y, r.im.x, r.im.z}, newoutput, {r.om.y, r.om.x, r.om.z}, c, r.p, allocator)
    return result
}

// Rule rotation around Y axis (swap X/Z, negate Z)
rule_y_rotated :: proc(r: ^Rule, c: int, allocator := context.allocator) -> Rule {
    newinput := make([]int, len(r.input), allocator)
    for z in 0 ..< r.im.x {
        for y in 0 ..< r.im.y {
            for x in 0 ..< r.im.z {
                newinput[x + y * r.im.z + z * r.im.z * r.im.y] =
                    r.input[r.im.x - 1 - z + y * r.im.x + x * r.im.x * r.im.y]
            }
        }
    }

    newoutput := make([]u8, len(r.output), allocator)
    for z in 0 ..< r.om.x {
        for y in 0 ..< r.om.y {
            for x in 0 ..< r.om.z {
                newoutput[x + y * r.om.z + z * r.om.z * r.om.y] =
                    r.output[r.om.x - 1 - z + y * r.om.x + x * r.om.x * r.om.y]
            }
        }
    }

    result: Rule
    rule_init(&result, newinput, {r.im.z, r.im.y, r.im.x}, newoutput, {r.om.z, r.om.y, r.om.x}, c, r.p, allocator)
    return result
}

// Rule reflection (negate X)
rule_reflected :: proc(r: ^Rule, c: int, allocator := context.allocator) -> Rule {
    newinput := make([]int, len(r.input), allocator)
    for z in 0 ..< r.im.z {
        for y in 0 ..< r.im.y {
            for x in 0 ..< r.im.x {
                newinput[x + y * r.im.x + z * r.im.x * r.im.y] =
                    r.input[r.im.x - 1 - x + y * r.im.x + z * r.im.x * r.im.y]
            }
        }
    }

    newoutput := make([]u8, len(r.output), allocator)
    for z in 0 ..< r.om.z {
        for y in 0 ..< r.om.y {
            for x in 0 ..< r.om.x {
                newoutput[x + y * r.om.x + z * r.om.x * r.om.y] =
                    r.output[r.om.x - 1 - x + y * r.om.x + z * r.om.x * r.om.y]
            }
        }
    }

    result: Rule
    rule_init(&result, newinput, r.im, newoutput, r.om, c, r.p, allocator)
    return result
}

// Generate all square symmetry variants of a rule
rule_square_symmetries :: proc(
    rule: ^Rule,
    c: int,
    subgroup: Symmetry_Mask,
    allocator := context.allocator,
) -> [dynamic]Rule {
    rules: [8]Rule

    rules[0] = rule^ // e (identity)
    rules[1] = rule_reflected(&rules[0], c, allocator) // b
    rules[2] = rule_z_rotated(&rules[0], c, allocator) // a
    rules[3] = rule_reflected(&rules[2], c, allocator) // ba
    rules[4] = rule_z_rotated(&rules[2], c, allocator) // a2
    rules[5] = rule_reflected(&rules[4], c, allocator) // ba2
    rules[6] = rule_z_rotated(&rules[4], c, allocator) // a3
    rules[7] = rule_reflected(&rules[6], c, allocator) // ba3

    result := make([dynamic]Rule, allocator)
    for i in 0 ..< 8 {
        if symmetry_has(subgroup, i) {
            // Check if this rule is already in result
            found := false
            for &existing in result {
                if rule_same(&existing, &rules[i]) {
                    found = true
                    break
                }
            }
            if !found {
                append(&result, rules[i])
                // Ownership of the rule's allocations moves into result.
                rules[i] = {}
            }
        }
    }

    // Every generated candidate not moved into result is scratch storage,
    // including symmetry variants excluded by the subgroup or deduplication.
    for &candidate in rules {
        rule_destroy(&candidate, allocator)
    }

    return result
}

// Generate all cube symmetry variants of a rule
rule_cube_symmetries :: proc(
    rule: ^Rule,
    c: int,
    subgroup: Symmetry_Mask,
    allocator := context.allocator,
) -> [dynamic]Rule {
    s: [48]Rule

    s[0] = rule^
    s[1] = rule_reflected(&s[0], c, allocator)
    s[2] = rule_z_rotated(&s[0], c, allocator)
    s[3] = rule_reflected(&s[2], c, allocator)
    s[4] = rule_z_rotated(&s[2], c, allocator)
    s[5] = rule_reflected(&s[4], c, allocator)
    s[6] = rule_z_rotated(&s[4], c, allocator)
    s[7] = rule_reflected(&s[6], c, allocator)
    s[8] = rule_y_rotated(&s[0], c, allocator)
    s[9] = rule_reflected(&s[8], c, allocator)
    s[10] = rule_y_rotated(&s[2], c, allocator)
    s[11] = rule_reflected(&s[10], c, allocator)
    s[12] = rule_y_rotated(&s[4], c, allocator)
    s[13] = rule_reflected(&s[12], c, allocator)
    s[14] = rule_y_rotated(&s[6], c, allocator)
    s[15] = rule_reflected(&s[14], c, allocator)
    s[16] = rule_y_rotated(&s[8], c, allocator)
    s[17] = rule_reflected(&s[16], c, allocator)
    s[18] = rule_y_rotated(&s[10], c, allocator)
    s[19] = rule_reflected(&s[18], c, allocator)
    s[20] = rule_y_rotated(&s[12], c, allocator)
    s[21] = rule_reflected(&s[20], c, allocator)
    s[22] = rule_y_rotated(&s[14], c, allocator)
    s[23] = rule_reflected(&s[22], c, allocator)
    s[24] = rule_y_rotated(&s[16], c, allocator)
    s[25] = rule_reflected(&s[24], c, allocator)
    s[26] = rule_y_rotated(&s[18], c, allocator)
    s[27] = rule_reflected(&s[26], c, allocator)
    s[28] = rule_y_rotated(&s[20], c, allocator)
    s[29] = rule_reflected(&s[28], c, allocator)
    s[30] = rule_y_rotated(&s[22], c, allocator)
    s[31] = rule_reflected(&s[30], c, allocator)
    s[32] = rule_z_rotated(&s[8], c, allocator)
    s[33] = rule_reflected(&s[32], c, allocator)
    s[34] = rule_z_rotated(&s[10], c, allocator)
    s[35] = rule_reflected(&s[34], c, allocator)
    s[36] = rule_z_rotated(&s[12], c, allocator)
    s[37] = rule_reflected(&s[36], c, allocator)
    s[38] = rule_z_rotated(&s[14], c, allocator)
    s[39] = rule_reflected(&s[38], c, allocator)
    s[40] = rule_z_rotated(&s[24], c, allocator)
    s[41] = rule_reflected(&s[40], c, allocator)
    s[42] = rule_z_rotated(&s[26], c, allocator)
    s[43] = rule_reflected(&s[42], c, allocator)
    s[44] = rule_z_rotated(&s[28], c, allocator)
    s[45] = rule_reflected(&s[44], c, allocator)
    s[46] = rule_z_rotated(&s[30], c, allocator)
    s[47] = rule_reflected(&s[46], c, allocator)

    result := make([dynamic]Rule, allocator)
    for i in 0 ..< 48 {
        if symmetry_has(subgroup, i) {
            found := false
            for &existing in result {
                if rule_same(&existing, &s[i]) {
                    found = true
                    break
                }
            }
            if !found {
                append(&result, s[i])
                // Ownership of the rule's allocations moves into result.
                s[i] = {}
            }
        }
    }

    for &candidate in s {
        rule_destroy(&candidate, allocator)
    }

    return result
}

// Generate symmetries for a rule based on dimension
rule_symmetries :: proc(
    rule: ^Rule,
    c: int,
    subgroup: Symmetry_Mask,
    is_2d: bool,
    allocator := context.allocator,
) -> [dynamic]Rule {
    if is_2d {
        return rule_square_symmetries(rule, c, subgroup, allocator)
    } else {
        return rule_cube_symmetries(rule, c, subgroup, allocator)
    }
}
