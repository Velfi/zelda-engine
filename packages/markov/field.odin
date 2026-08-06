package markov

// Field for BFS-based distance computation
field_compute :: proc(f: ^Field, potential: []int, g: ^Grid) -> bool {
    m := g.m
    size := m.x * m.y * m.z

    // Queue: (generation, x, y, z)
    Queue_Item :: struct {
        t:   int,
        pos: [3]int,
    }
    front := make([dynamic]Queue_Item, context.temp_allocator)

    // Initialize potentials
    pos: [3]int
    for i in 0 ..< size {
        potential[i] = -1
        value := g.state[i]
        if (f.zero & (1 << uint(value))) != 0 {
            potential[i] = 0
            append(&front, Queue_Item{0, pos})
        }

        pos.x += 1
        if pos.x == m.x {
            pos.x = 0
            pos.y += 1
            if pos.y == m.y {
                pos.y = 0
                pos.z += 1
            }
        }
    }

    if len(front) == 0 {
        return false
    }

    // BFS propagation
    front_idx := 0
    for front_idx < len(front) {
        item := front[front_idx]
        front_idx += 1

        neighbors := field_neighbors(item.pos, m)
        for np in neighbors {
            ni := np.x + np.y * m.x + np.z * m.x * m.y
            v := g.state[ni]
            if potential[ni] == -1 && (f.substrate & (1 << uint(v))) != 0 {
                append(&front, Queue_Item{item.t + 1, np})
                potential[ni] = item.t + 1
            }
        }
    }

    return true
}

field_neighbors :: proc(p, m: [3]int, allocator := context.temp_allocator) -> [dynamic][3]int {
    result := make([dynamic][3]int, allocator)

    if p.x > 0 { append(&result, [3]int{p.x - 1, p.y, p.z}) }
    if p.x < m.x - 1 { append(&result, [3]int{p.x + 1, p.y, p.z}) }
    if p.y > 0 { append(&result, [3]int{p.x, p.y - 1, p.z}) }
    if p.y < m.y - 1 { append(&result, [3]int{p.x, p.y + 1, p.z}) }
    if p.z > 0 { append(&result, [3]int{p.x, p.y, p.z - 1}) }
    if p.z < m.z - 1 { append(&result, [3]int{p.x, p.y, p.z + 1}) }

    return result
}

// Compute heuristic delta for rule application
field_delta_pointwise :: proc(
    state: []u8,
    rule: ^Rule,
    pos: [3]int,
    fields: []^Field,
    potentials: [][]int,
    m: [3]int,
) -> (
    int,
    bool,
) {
    sum := 0
    d: [3]int

    for di in 0 ..< len(rule.input) {
        newvalue := rule.output[di]
        if newvalue != 0xff && (rule.input[di] & (1 << uint(newvalue))) == 0 {
            sp := pos + d
            si := sp.x + sp.y * m.x + sp.z * m.x * m.y

            new_potential := potentials[newvalue][si]
            if new_potential == -1 {
                return 0, false
            }

            oldvalue := state[si]
            old_potential := potentials[oldvalue][si]
            sum += new_potential - old_potential

            if fields != nil {
                old_field := fields[oldvalue]
                if old_field != nil && old_field.inversed {
                    sum += 2 * old_potential
                }
                new_field := fields[newvalue]
                if new_field != nil && new_field.inversed {
                    sum -= 2 * new_potential
                }
            }
        }

        d.x += 1
        if d.x == rule.im.x {
            d.x = 0
            d.y += 1
            if d.y == rule.im.y {
                d.y = 0
                d.z += 1
            }
        }
    }

    return sum, true
}
