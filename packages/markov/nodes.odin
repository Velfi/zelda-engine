package markov
import "base:runtime"

import "core:math"
import "core:math/rand"
import "core:mem"
import "core:slice"

// Dispatch functions for polymorphic node operations

is_branch_kind :: proc(kind: Node_Kind) -> bool {
    return kind == .Sequence || kind == .Markov || kind == .Map || kind == .Overlap_WFC || kind == .Tile_WFC
}

node_go :: proc(node: ^Node) -> bool {
    #partial switch node.kind {
    case .One:
        return one_go(node)
    case .All:
        return all_go(node)
    case .Parallel:
        return parallel_go(node)
    case .Sequence:
        return sequence_go(node)
    case .Markov:
        return markov_go(node)
    case .Path:
        return path_go(node)
    case .Convolution:
        return convolution_go(node)
    case .Overlap_WFC:
        return overlap_wfc_go(node)
    case .Tile_WFC:
        return tile_wfc_go(node)
    case .Map:
        return map_go(node)
    }
    return false
}

node_reset :: proc(node: ^Node) {
    #partial switch node.kind {
    case .One:
        rule_node_reset(&node.data.one.rule_base)
    case .All:
        rule_node_reset(&node.data.all.rule_base)
    case .Parallel:
        rule_node_reset(&node.data.parallel.rule_base)
    case .Sequence:
        branch_reset(&node.data.sequence.branch_base)
    case .Markov:
        branch_reset(&node.data.markov.branch_base)
    case .Convolution:
        node.data.convolution.counter = 0
    case .Overlap_WFC:
        node.data.overlap.wfc_base.first_go = true
        branch_reset(&node.data.overlap.wfc_base.branch_base)
        node.data.overlap.wfc_base.branch_base.child_index = -1
    case .Tile_WFC:
        node.data.tile.wfc_base.first_go = true
        branch_reset(&node.data.tile.wfc_base.branch_base)
        node.data.tile.wfc_base.branch_base.child_index = -1
    case .Map:
        branch_reset(&node.data.map_.branch_base)
        node.data.map_.branch_base.child_index = -1 // Start in "apply map" state
    }
}

// Branch operations

branch_reset :: proc(b: ^Branch) {
    for child in b.children {
        node_reset(child)
    }
    b.child_index = 0
}

branch_go :: proc(node: ^Node, b: ^Branch) -> bool {
    for b.child_index < len(b.children) {
        child := b.children[b.child_index]
        if is_branch_kind(child.kind) {
            node.ip.current = child
        }
        if node_go(child) {
            return true
        }
        b.child_index += 1
    }
    node.ip.current = b.parent
    branch_reset(b)
    return false
}

sequence_go :: proc(node: ^Node) -> bool {
    return branch_go(node, &node.data.sequence.branch_base)
}

markov_go :: proc(node: ^Node) -> bool {
    node.data.markov.child_index = 0
    return branch_go(node, &node.data.markov.branch_base)
}

// RuleNode operations

rule_node_reset :: proc(rn: ^Rule_Node) {
    rn.last_matched_turn = -1
    rn.counter = 0
    rn.future_computed = false
    rn.match_count = 0
    if rn.match_mask != nil {
        for i in 0 ..< len(rn.match_mask) {
            if rn.match_mask[i] != nil {
                mem.zero_slice(rn.match_mask[i])
            }
        }
    }
    for i in 0 ..< len(rn.last) {
        rn.last[i] = false
    }
}

rule_node_add :: proc(node: ^Node, rn: ^Rule_Node, r: int, pos: [3]int) {
    g := node.grid
    idx := pos.x + pos.y * g.m.x + pos.z * g.m.x * g.m.y

    if rn.match_mask != nil {
        rn.match_mask[r][idx] = true
    }

    m: Match = {r, pos}
    if rn.match_count < len(rn.matches) {
        rn.matches[rn.match_count] = m
    } else {
        append(&rn.matches, m)
    }
    rn.match_count += 1
}

// Parallel node has special Add behavior
parallel_add :: proc(node: ^Node, rn: ^Rule_Node, r: int, pos: [3]int) {
    rule := &rn.rules[r]
    if rand.float64(node.ip.rng) > rule.p {
        return
    }
    rn.last[r] = true
    g := node.grid
    pn := &node.data.parallel

    for dz in 0 ..< rule.om.z {
        for dy in 0 ..< rule.om.y {
            for dx in 0 ..< rule.om.x {
                newvalue := rule.output[dx + dy * rule.om.x + dz * rule.om.x * rule.om.y]
                sp := pos + {dx, dy, dz}
                si := sp.x + sp.y * g.m.x + sp.z * g.m.x * g.m.y
                if newvalue != 0xff && newvalue != g.state[si] {
                    pn.newstate[si] = newvalue
                    append(&node.ip.changes, sp)
                }
            }
        }
    }
    rn.match_count += 1
}

// Common rule matching logic
rule_node_find_matches :: proc(node: ^Node, rn: ^Rule_Node) {
    g := node.grid
    ip := node.ip
    m := g.m

    if rn.last_matched_turn >= 0 {
        // Incremental update from changes
        first_change := ip.first[rn.last_matched_turn]
        for n in first_change ..< len(ip.changes) {
            change := ip.changes[n]
            value := g.state[change.x + change.y * m.x + change.z * m.x * m.y]

            for r in 0 ..< len(rn.rules) {
                rule := &rn.rules[r]
                shifts := rule.ishifts[value]

                for shift in shifts {
                    sp := change - shift
                    if sp.x < 0 ||
                       sp.y < 0 ||
                       sp.z < 0 ||
                       sp.x + rule.im.x > m.x ||
                       sp.y + rule.im.y > m.y ||
                       sp.z + rule.im.z > m.z {
                        continue
                    }
                    si := sp.x + sp.y * m.x + sp.z * m.x * m.y

                    if rn.match_mask != nil && rn.match_mask[r][si] {
                        continue
                    }
                    if grid_matches(g, rule, sp) {
                        if node.kind == .Parallel {
                            parallel_add(node, rn, r, sp)
                        } else {
                            rule_node_add(node, rn, r, sp)
                        }
                    }
                }
            }
        }
    } else {
        // Full scan
        rn.match_count = 0
        for r in 0 ..< len(rn.rules) {
            rule := &rn.rules[r]

            for z := rule.im.z - 1; z < m.z; z += rule.im.z {
                for y := rule.im.y - 1; y < m.y; y += rule.im.y {
                    for x := rule.im.x - 1; x < m.x; x += rule.im.x {
                        idx := x + y * m.x + z * m.x * m.y
                        value := g.state[idx]
                        shifts := rule.ishifts[value]

                        for shift in shifts {
                            sp: [3]int = {x, y, z} - shift
                            if sp.x < 0 ||
                               sp.y < 0 ||
                               sp.z < 0 ||
                               sp.x + rule.im.x > m.x ||
                               sp.y + rule.im.y > m.y ||
                               sp.z + rule.im.z > m.z {
                                continue
                            }
                            if grid_matches(g, rule, sp) {
                                if node.kind == .Parallel {
                                    parallel_add(node, rn, r, sp)
                                } else {
                                    rule_node_add(node, rn, r, sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

rule_node_go_base :: proc(node: ^Node, rn: ^Rule_Node) -> bool {
    g := node.grid
    ip := node.ip

    for i in 0 ..< len(rn.last) {
        rn.last[i] = false
    }

    if rn.steps > 0 && rn.counter >= rn.steps {
        return false
    }

    if rn.observations != nil && !rn.future_computed {
        if !compute_future_set_present(rn.future, g.state, rn.observations) {
            return false
        }

        rn.future_computed = true
        if rn.search {
            rn.trajectory = nil
            tries := rn.limit < 0 ? 1 : 20
            for k in 0 ..< tries {
                if rn.trajectory != nil {
                    break
                }
                seed := rand.int31(ip.rng)
                rn.trajectory = search_run(
                    g.state,
                    rn.future,
                    rn.rules,
                    g.m,
                    int(g.c),
                    node.kind == .All,
                    rn.limit,
                    rn.depth_coeff,
                    u64(seed),
                    context.allocator,
                )
            }
        } else if rn.potentials != nil {
            compute_backward_potentials(rn.potentials, rn.future, g.m, rn.rules)
        }
    }

    rule_node_find_matches(node, rn)

    if rn.fields != nil {
        any_success := false
        any_computation := false

        for c in 0 ..< len(rn.fields) {
            field := rn.fields[c]
            if field != nil && (rn.counter == 0 || field.recompute) {
                success := field_compute(field, rn.potentials[c], g)
                if !success && field.essential {
                    return false
                }
                any_success = any_success || success
                any_computation = true
            }
        }

        if any_computation && !any_success {
            return false
        }
    }

    return true
}

// OneNode implementation

one_apply :: proc(node: ^Node, rule: ^Rule, pos: [3]int) {
    g := node.grid
    changes := &node.ip.changes

    for dz in 0 ..< rule.om.z {
        for dy in 0 ..< rule.om.y {
            for dx in 0 ..< rule.om.x {
                newvalue := rule.output[dx + dy * rule.om.x + dz * rule.om.x * rule.om.y]
                if newvalue != 0xff {
                    sp := pos + {dx, dy, dz}
                    si := sp.x + sp.y * g.m.x + sp.z * g.m.x * g.m.y
                    oldvalue := g.state[si]
                    if newvalue != oldvalue {
                        g.state[si] = newvalue
                        append(changes, sp)
                    }
                }
            }
        }
    }
}

one_random_match :: proc(node: ^Node, rn: ^Rule_Node) -> (int, [3]int, bool) {
    g := node.grid

    if rn.potentials != nil {
        if rn.observations != nil && is_goal_reached(g.state, rn.future) {
            rn.future_computed = false
            return -1, {}, false
        }

        max_key := -1000.0
        argmax := -1
        first_heuristic := 0.0
        first_heuristic_computed := false

        for k := 0; k < rn.match_count; k += 1 {
            m := rn.matches[k]
            i := m.pos.x + m.pos.y * g.m.x + m.pos.z * g.m.x * g.m.y

            if !grid_matches(g, &rn.rules[m.r], m.pos) {
                if rn.match_mask != nil {
                    rn.match_mask[m.r][i] = false
                }
                rn.matches[k] = rn.matches[rn.match_count - 1]
                rn.match_count -= 1
                k -= 1
                continue
            }

            h, ok := field_delta_pointwise(g.state, &rn.rules[m.r], m.pos, rn.fields, rn.potentials, g.m)
            if !ok {
                continue
            }

            hf := f64(h)
            if !first_heuristic_computed {
                first_heuristic = hf
                first_heuristic_computed = true
            }

            u := rand.float64(node.ip.rng)
            key := -hf + 0.001 * u
            if rn.temperature > 0 {
                key = math.pow(u, math.exp((hf - first_heuristic) / rn.temperature))
            }

            if key > max_key {
                max_key = key
                argmax = k
            }
        }

        if argmax >= 0 {
            m := rn.matches[argmax]
            return m.r, m.pos, true
        }
        return -1, {}, false
    }

    // Simple random selection
    for rn.match_count > 0 {
        match_idx := rand.int_max(rn.match_count, node.ip.rng)
        m := rn.matches[match_idx]
        i := m.pos.x + m.pos.y * g.m.x + m.pos.z * g.m.x * g.m.y

        if rn.match_mask != nil {
            rn.match_mask[m.r][i] = false
        }
        rn.matches[match_idx] = rn.matches[rn.match_count - 1]
        rn.match_count -= 1

        if grid_matches(g, &rn.rules[m.r], m.pos) {
            return m.r, m.pos, true
        }
    }
    return -1, {}, false
}

one_go :: proc(node: ^Node) -> bool {
    rn := &node.data.one.rule_base

    if !rule_node_go_base(node, rn) {
        return false
    }
    rn.last_matched_turn = node.ip.counter

    // Handle trajectory playback
    if rn.trajectory != nil {
        if rn.counter >= len(rn.trajectory) {
            return false
        }
        copy(node.grid.state, rn.trajectory[rn.counter])
        rn.counter += 1
        return true
    }

    r, pos, ok := one_random_match(node, rn)
    if !ok {
        return false
    }

    rn.last[r] = true
    one_apply(node, &rn.rules[r], pos)
    rn.counter += 1
    return true
}

// AllNode implementation

all_fit :: proc(node: ^Node, rn: ^Rule_Node, r: int, pos: [3]int, newstate: []bool) {
    rule := &rn.rules[r]
    g := node.grid

    // Check if any output cell is already taken
    for dz in 0 ..< rule.om.z {
        for dy in 0 ..< rule.om.y {
            for dx in 0 ..< rule.om.x {
                value := rule.output[dx + dy * rule.om.x + dz * rule.om.x * rule.om.y]
                sp := pos + {dx, dy, dz}
                if value != 0xff && newstate[sp.x + sp.y * g.m.x + sp.z * g.m.x * g.m.y] {
                    return
                }
            }
        }
    }

    rn.last[r] = true
    for dz in 0 ..< rule.om.z {
        for dy in 0 ..< rule.om.y {
            for dx in 0 ..< rule.om.x {
                newvalue := rule.output[dx + dy * rule.om.x + dz * rule.om.x * rule.om.y]
                if newvalue != 0xff {
                    sp := pos + {dx, dy, dz}
                    si := sp.x + sp.y * g.m.x + sp.z * g.m.x * g.m.y
                    newstate[si] = true
                    g.state[si] = newvalue
                    append(&node.ip.changes, sp)
                }
            }
        }
    }
}

all_go :: proc(node: ^Node) -> bool {
    rn := &node.data.all.rule_base
    g := node.grid
    ip := node.ip

    if !rule_node_go_base(node, rn) {
        return false
    }
    rn.last_matched_turn = ip.counter

    // Handle trajectory playback
    if rn.trajectory != nil {
        if rn.counter >= len(rn.trajectory) {
            return false
        }
        copy(g.state, rn.trajectory[rn.counter])
        rn.counter += 1
        return true
    }

    if rn.match_count == 0 {
        return false
    }

    if rn.potentials != nil {
        Ranked_Match :: struct {
            match_idx: int,
            key:       f64,
        }

        ranked := make([dynamic]Ranked_Match, context.temp_allocator)
        first_heuristic := 0.0
        first_heuristic_computed := false

        for m_idx in 0 ..< rn.match_count {
            m := rn.matches[m_idx]
            h, ok := field_delta_pointwise(g.state, &rn.rules[m.r], m.pos, rn.fields, rn.potentials, g.m)
            if !ok {
                continue
            }

            hf := f64(h)
            if !first_heuristic_computed {
                first_heuristic = hf
                first_heuristic_computed = true
            }

            u := rand.float64(ip.rng)
            key := -hf + 0.001 * u
            if rn.temperature > 0 {
                key = math.pow(u, math.exp((hf - first_heuristic) / rn.temperature))
            }
            append(&ranked, Ranked_Match{m_idx, key})
        }

        slice.sort_by(ranked[:], proc(a, b: Ranked_Match) -> bool { return a.key > b.key })

        for rmatch in ranked {
            m := rn.matches[rmatch.match_idx]
            i := m.pos.x + m.pos.y * g.m.x + m.pos.z * g.m.x * g.m.y
            if rn.match_mask != nil {
                rn.match_mask[m.r][i] = false
            }
            all_fit(node, rn, m.r, m.pos, g.mask)
        }
    } else {
        // Shuffle matches
        shuffle := make([]int, rn.match_count, context.temp_allocator)
        for i in 0 ..< rn.match_count {
            shuffle[i] = i
        }
        rand.shuffle(shuffle[:], ip.rng)

        // Apply all non-overlapping matches
        for k in 0 ..< len(shuffle) {
            m := rn.matches[shuffle[k]]
            i := m.pos.x + m.pos.y * g.m.x + m.pos.z * g.m.x * g.m.y
            if rn.match_mask != nil {
                rn.match_mask[m.r][i] = false
            }
            all_fit(node, rn, m.r, m.pos, g.mask)
        }
    }

    // Clear mask for changed cells
    first_change := ip.first[rn.last_matched_turn]
    for n in first_change ..< len(ip.changes) {
        c := ip.changes[n]
        g.mask[c.x + c.y * g.m.x + c.z * g.m.x * g.m.y] = false
    }

    rn.counter += 1
    rn.match_count = 0
    return true
}

// ParallelNode implementation

parallel_go :: proc(node: ^Node) -> bool {
    rn := &node.data.parallel.rule_base
    pn := &node.data.parallel
    g := node.grid
    ip := node.ip

    if !rule_node_go_base(node, rn) {
        return false
    }

    // Apply buffered changes
    first_change := ip.first[ip.counter]
    for n in first_change ..< len(ip.changes) {
        c := ip.changes[n]
        i := c.x + c.y * g.m.x + c.z * g.m.x * g.m.y
        g.state[i] = pn.newstate[i]
    }

    rn.counter += 1
    return rn.match_count > 0
}

// PathNode implementation

path_directions :: proc(
    pos, m: [3]int,
    edges, vertices: bool,
    allocator := context.temp_allocator,
) -> [dynamic][3]int {
    result := make([dynamic][3]int, allocator)
    x, y, z := pos.x, pos.y, pos.z
    mx, my, mz := m.x, m.y, m.z

    if mz == 1 {
        if x > 0 { append(&result, [3]int{-1, 0, 0}) }
        if x < mx - 1 { append(&result, [3]int{1, 0, 0}) }
        if y > 0 { append(&result, [3]int{0, -1, 0}) }
        if y < my - 1 { append(&result, [3]int{0, 1, 0}) }

        if edges {
            if x > 0 && y > 0 { append(&result, [3]int{-1, -1, 0}) }
            if x > 0 && y < my - 1 { append(&result, [3]int{-1, 1, 0}) }
            if x < mx - 1 && y > 0 { append(&result, [3]int{1, -1, 0}) }
            if x < mx - 1 && y < my - 1 { append(&result, [3]int{1, 1, 0}) }
        }
    } else {
        if x > 0 { append(&result, [3]int{-1, 0, 0}) }
        if x < mx - 1 { append(&result, [3]int{1, 0, 0}) }
        if y > 0 { append(&result, [3]int{0, -1, 0}) }
        if y < my - 1 { append(&result, [3]int{0, 1, 0}) }
        if z > 0 { append(&result, [3]int{0, 0, -1}) }
        if z < mz - 1 { append(&result, [3]int{0, 0, 1}) }

        if edges {
            if x > 0 && y > 0 { append(&result, [3]int{-1, -1, 0}) }
            if x > 0 && y < my - 1 { append(&result, [3]int{-1, 1, 0}) }
            if x < mx - 1 && y > 0 { append(&result, [3]int{1, -1, 0}) }
            if x < mx - 1 && y < my - 1 { append(&result, [3]int{1, 1, 0}) }
            if x > 0 && z > 0 { append(&result, [3]int{-1, 0, -1}) }
            if x > 0 && z < mz - 1 { append(&result, [3]int{-1, 0, 1}) }
            if x < mx - 1 && z > 0 { append(&result, [3]int{1, 0, -1}) }
            if x < mx - 1 && z < mz - 1 { append(&result, [3]int{1, 0, 1}) }
            if y > 0 && z > 0 { append(&result, [3]int{0, -1, -1}) }
            if y > 0 && z < mz - 1 { append(&result, [3]int{0, -1, 1}) }
            if y < my - 1 && z > 0 { append(&result, [3]int{0, 1, -1}) }
            if y < my - 1 && z < mz - 1 { append(&result, [3]int{0, 1, 1}) }
        }

        if vertices {
            if x > 0 && y > 0 && z > 0 { append(&result, [3]int{-1, -1, -1}) }
            if x > 0 && y > 0 && z < mz - 1 { append(&result, [3]int{-1, -1, 1}) }
            if x > 0 && y < my - 1 && z > 0 { append(&result, [3]int{-1, 1, -1}) }
            if x > 0 && y < my - 1 && z < mz - 1 { append(&result, [3]int{-1, 1, 1}) }
            if x < mx - 1 && y > 0 && z > 0 { append(&result, [3]int{1, -1, -1}) }
            if x < mx - 1 && y > 0 && z < mz - 1 { append(&result, [3]int{1, -1, 1}) }
            if x < mx - 1 && y < my - 1 && z > 0 { append(&result, [3]int{1, 1, -1}) }
            if x < mx - 1 && y < my - 1 && z < mz - 1 { append(&result, [3]int{1, 1, 1}) }
        }
    }

    return result
}

path_go :: proc(node: ^Node) -> bool {
    pn := &node.data.path
    g := node.grid
    m := g.m
    ip := node.ip

    // BFS queue: (generation, x, y, z)
    Queue_Item :: struct {
        t:   int,
        pos: [3]int,
    }
    frontier := make([dynamic]Queue_Item, context.temp_allocator)
    start_positions := make([dynamic][3]int, context.temp_allocator)
    generations := make([]int, len(g.state), context.temp_allocator)
    for i in 0 ..< len(generations) {
        generations[i] = -1
    }

    // Find start and finish positions
    for z in 0 ..< m.z {
        for y in 0 ..< m.y {
            for x in 0 ..< m.x {
                i := x + y * m.x + z * m.x * m.y
                s := g.state[i]
                pos: [3]int = {x, y, z}
                if (pn.start & (1 << uint(s))) != 0 {
                    append(&start_positions, pos)
                }
                if (pn.finish & (1 << uint(s))) != 0 {
                    generations[i] = 0
                    append(&frontier, Queue_Item{0, pos})
                }
            }
        }
    }

    if len(start_positions) == 0 || len(frontier) == 0 {
        return false
    }

    // BFS from finish to start
    front_idx := 0
    for front_idx < len(frontier) {
        item := frontier[front_idx]
        front_idx += 1

        dirs := path_directions(item.pos, m, pn.edges, pn.vertices)
        for d in dirs {
            np := item.pos + d
            ni := np.x + np.y * m.x + np.z * m.x * m.y
            v := g.state[ni]
            if generations[ni] == -1 && ((pn.substrate & (1 << uint(v))) != 0 || (pn.start & (1 << uint(v))) != 0) {
                if (pn.substrate & (1 << uint(v))) != 0 {
                    append(&frontier, Queue_Item{item.t + 1, np})
                }
                generations[ni] = item.t + 1
            }
        }
    }

    // Find best start position
    has_valid_start := false
    for p in start_positions {
        if generations[p.x + p.y * m.x + p.z * m.x * m.y] > 0 {
            has_valid_start = true
            break
        }
    }
    if !has_valid_start {
        return false
    }

    local_rng_state: rand.Xoshiro256_Random_State
    local_rng := rand.xoshiro256_random_generator(&local_rng_state)
    rand.reset(u64(rand.int31(ip.rng)), local_rng)
    min_val := f64(m.x * m.y * m.z)
    max_val: f64 = -2
    argmin: [3]int
    argmax: [3]int

    for p in start_positions {
        gen := generations[p.x + p.y * m.x + p.z * m.x * m.y]
        if gen == -1 {
            continue
        }
        dg := f64(gen)
        noise := 0.1 * rand.float64(local_rng)

        if dg + noise < min_val {
            min_val = dg + noise
            argmin = p
        }
        if dg + noise > max_val {
            max_val = dg + noise
            argmax = p
        }
    }

    pen := pn.longest ? argmax : argmin

    // Find direction helper
    find_direction :: proc(
        pos, prev_dir: [3]int,
        generations: []int,
        m: [3]int,
        edges, vertices, inertia: bool,
        rng: runtime.Random_Generator,
    ) -> [3]int {
        candidates := make([dynamic][3]int, context.temp_allocator)
        gen := generations[pos.x + pos.y * m.x + pos.z * m.x * m.y]

        dirs := path_directions(pos, m, edges, vertices)
        for d in dirs {
            np := pos + d
            if generations[np.x + np.y * m.x + np.z * m.x * m.y] == gen - 1 {
                append(&candidates, d)
            }
        }

        if len(candidates) == 0 {
            return {}
        }

        // Check for inertia
        if inertia && (prev_dir.x != 0 || prev_dir.y != 0 || prev_dir.z != 0) {
            cp := pos + prev_dir
            if cp.x >= 0 && cp.y >= 0 && cp.z >= 0 && cp.x < m.x && cp.y < m.y && cp.z < m.z {
                if generations[cp.x + cp.y * m.x + cp.z * m.x * m.y] == gen - 1 {
                    return prev_dir
                }
            }
        }

        return candidates[rand.int_max(len(candidates), rng)]
    }

    // Step to first cell
    dir := find_direction(pen, {}, generations, m, pn.edges, pn.vertices, pn.inertia, local_rng)
    if dir.x == 0 && dir.y == 0 && dir.z == 0 {
        // No valid direction found from start
        return false
    }
    pen += dir

    // Walk to finish
    for generations[pen.x + pen.y * m.x + pen.z * m.x * m.y] != 0 {
        g.state[pen.x + pen.y * m.x + pen.z * m.x * m.y] = pn.value
        append(&ip.changes, pen)
        dir = find_direction(pen, dir, generations, m, pn.edges, pn.vertices, pn.inertia, local_rng)
        if dir.x == 0 && dir.y == 0 && dir.z == 0 {
            // No valid direction found - path is blocked
            break
        }
        pen += dir
    }

    return true
}

// ConvolutionNode implementation

KERNEL_VON_NEUMANN_2D :: [9]int{0, 1, 0, 1, 0, 1, 0, 1, 0}
KERNEL_MOORE_2D :: [9]int{1, 1, 1, 1, 0, 1, 1, 1, 1}
KERNEL_VON_NEUMANN_3D :: [27]int{0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0}
KERNEL_NO_CORNERS_3D :: [27]int{0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0}

convolution_go :: proc(node: ^Node) -> bool {
    cn := &node.data.convolution
    g := node.grid
    ip := node.ip
    m := g.m

    if cn.steps > 0 && cn.counter >= cn.steps {
        return false
    }

    // Clear sumfield
    for i in 0 ..< len(cn.sumfield) {
        mem.zero_slice(cn.sumfield[i])
    }

    // Compute sums
    if m.z == 1 {
        for y in 0 ..< m.y {
            for x in 0 ..< m.x {
                sums := cn.sumfield[x + y * m.x]
                for dy in -1 ..= 1 {
                    for dx in -1 ..= 1 {
                        sx := x + dx
                        sy := y + dy

                        if cn.periodic {
                            if sx < 0 { sx += m.x } else if sx >= m.x { sx -= m.x }
                            if sy < 0 { sy += m.y } else if sy >= m.y { sy -= m.y }
                        } else if sx < 0 || sy < 0 || sx >= m.x || sy >= m.y {
                            continue
                        }

                        sums[g.state[sx + sy * m.x]] += cn.kernel[dx + 1 + (dy + 1) * 3]
                    }
                }
            }
        }
    } else {
        for z in 0 ..< m.z {
            for y in 0 ..< m.y {
                for x in 0 ..< m.x {
                    sums := cn.sumfield[x + y * m.x + z * m.x * m.y]
                    for dz in -1 ..= 1 {
                        for dy in -1 ..= 1 {
                            for dx in -1 ..= 1 {
                                sx := x + dx
                                sy := y + dy
                                sz := z + dz

                                if cn.periodic {
                                    if sx < 0 { sx += m.x } else if sx >= m.x { sx -= m.x }
                                    if sy < 0 { sy += m.y } else if sy >= m.y { sy -= m.y }
                                    if sz < 0 { sz += m.z } else if sz >= m.z { sz -= m.z }
                                } else if sx < 0 || sy < 0 || sz < 0 || sx >= m.x || sy >= m.y || sz >= m.z {
                                    continue
                                }

                                sums[g.state[sx + sy * m.x + sz * m.x * m.y]] +=
                                    cn.kernel[dx + 1 + (dy + 1) * 3 + (dz + 1) * 9]
                            }
                        }
                    }
                }
            }
        }
    }

    // Apply rules
    change := false
    for i in 0 ..< len(cn.sumfield) {
        sums := cn.sumfield[i]
        input := g.state[i]

        for &rule in cn.rules {
            if input == rule.input && rule.output != g.state[i] {
                success := true
                // Check sum constraint if one exists (sum_end > 0 indicates a constraint)
                if rule.sum_end > 0 || rule.sum_start > 0 {
                    sum := 0
                    // Sum over specified values
                    wave := rule.values
                    for c in 0 ..< int(g.c) {
                        if (wave & (1 << uint(c))) != 0 {
                            sum += sums[c]
                        }
                    }
                    success = sum >= rule.sum_start && sum <= rule.sum_end
                }
                if success {
                    g.state[i] = rule.output
                    change = true
                    break
                }
            }
        }
    }

    cn.counter += 1
    return change
}

// WFC Node implementations

overlap_wfc_go :: proc(node: ^Node) -> bool {
    on := &node.data.overlap
    wfc := &on.wfc_base
    b := &wfc.branch_base
    ip := node.ip
    g := node.grid

    if b.child_index >= 0 {
        return branch_go(node, b)
    }

    if wfc.first_go {
        wfc.first_go = false

        wave_init(
            wfc.wave,
            wfc.propagator,
            wfc.sum_of_weights,
            wfc.sum_of_weight_log_weights,
            wfc.starting_entropy,
            wfc.shannon,
        )

        for i in 0 ..< len(wfc.wave.data) {
            value := g.state[i]
            if allowed, found := wfc.map_[value]; found {
                for t in 0 ..< wfc.p_count {
                    if !allowed[t] && wfc.wave.data[i][t] {
                        wfc_ban(wfc, wfc.wave, i, t)
                    }
                }
            }
        }

        if !wfc_propagate(wfc, wfc.wave, g) {
            return false
        }

        wave_copy_from(wfc.startwave, wfc.wave, len(wfc.propagator), wfc.shannon)
        seed, found := wfc_find_good_seed(wfc, ip, g)
        if !found {
            return false
        }

        wfc.local_rng = rand.xoshiro256_random_generator(&wfc.local_rng_state)
        rand.reset(u64(seed), wfc.local_rng)

        wfc.stack_size = 0
        wave_copy_from(wfc.wave, wfc.startwave, len(wfc.propagator), wfc.shannon)
        grid_clear(wfc.newgrid)
        ip.grid = wfc.newgrid
        return true
    }

    n := wfc_next_unobserved(wfc, wfc.wave, g, wfc.local_rng)
    if n >= 0 {
        wfc_observe(wfc, wfc.wave, n, wfc.local_rng)
        wfc_propagate(wfc, wfc.wave, g)
    } else {
        b.child_index = 0
    }

    if b.child_index >= 0 || ip.gif {
        overlap_wfc_update_state(on)
    }

    return true
}

tile_wfc_go :: proc(node: ^Node) -> bool {
    tn := &node.data.tile
    wfc := &tn.wfc_base
    b := &wfc.branch_base
    ip := node.ip
    g := node.grid

    if b.child_index >= 0 {
        return branch_go(node, b)
    }

    if wfc.first_go {
        wfc.first_go = false

        wave_init(
            wfc.wave,
            wfc.propagator,
            wfc.sum_of_weights,
            wfc.sum_of_weight_log_weights,
            wfc.starting_entropy,
            wfc.shannon,
        )

        for z in 0 ..< g.m.z {
            for y in 0 ..< g.m.y {
                for x in 0 ..< g.m.x {
                    i := x + y * g.m.x + z * g.m.x * g.m.y
                    value := g.state[i]

                    if allowed, found := wfc.map_[value]; found {
                        for t in 0 ..< wfc.p_count {
                            if !allowed[t] && wfc.wave.data[i][t] {
                                wfc_ban(wfc, wfc.wave, i, t)
                            }
                        }
                    }
                }
            }
        }

        if !wfc_propagate(wfc, wfc.wave, g) {
            return false
        }

        wave_copy_from(wfc.startwave, wfc.wave, len(wfc.propagator), wfc.shannon)
        seed, found := wfc_find_good_seed(wfc, ip, g)
        if !found {
            return false
        }

        wfc.local_rng = rand.xoshiro256_random_generator(&wfc.local_rng_state)
        rand.reset(u64(seed), wfc.local_rng)

        wfc.stack_size = 0
        wave_copy_from(wfc.wave, wfc.startwave, len(wfc.propagator), wfc.shannon)
        grid_clear(wfc.newgrid)
        ip.grid = wfc.newgrid
        return true
    }

    n := wfc_next_unobserved(wfc, wfc.wave, g, wfc.local_rng)
    if n >= 0 {
        wfc_observe(wfc, wfc.wave, n, wfc.local_rng)
        wfc_propagate(wfc, wfc.wave, g)
    } else {
        b.child_index = 0
    }

    if b.child_index >= 0 || ip.gif {
        tile_wfc_update_state(tn, g, wfc.local_rng)
    }

    return true
}

overlap_wfc_update_state :: proc(on: ^Overlap_Node) {
    wfc := &on.wfc_base
    newgrid := wfc.newgrid
    mx, my := newgrid.m.x, newgrid.m.y
    n := wfc.n

    votes := make([][]int, len(newgrid.state), context.temp_allocator)
    for i in 0 ..< len(votes) {
        votes[i] = make([]int, int(newgrid.c), context.temp_allocator)
    }

    for i in 0 ..< len(wfc.wave.data) {
        wave := wfc.wave.data[i]
        x := i % mx
        y := i / mx

        for p := 0; p < wfc.p_count; p += 1 {
            if !wave[p] {
                continue
            }
            pattern := on.patterns[p]
            for dy in 0 ..< n {
                ydy := y + dy
                if ydy >= my {
                    ydy -= my
                }
                for dx in 0 ..< n {
                    xdx := x + dx
                    if xdx >= mx {
                        xdx -= mx
                    }
                    value := pattern[dx + dy * n]
                    votes[xdx + ydy * mx][value] += 1
                }
            }
        }
    }

    for i in 0 ..< len(votes) {
        max_vote := -1.0
        argmax: u8 = 0xff
        for c in 0 ..< len(votes[i]) {
            vote := f64(votes[i][c]) + 0.1 * rand.float64(wfc.local_rng)
            if vote > max_vote {
                max_vote = vote
                argmax = u8(c)
            }
        }
        newgrid.state[i] = argmax
    }
}

// Write WFC results to newgrid
tile_wfc_update_state :: proc(tn: ^Tile_Node, g: ^Grid, rng: runtime.Random_Generator) {
    wfc := &tn.wfc_base
    s := tn.s
    sz := tn.sz
    overlap := tn.overlap
    overlapz := tn.overlapz
    newgrid := wfc.newgrid

    for z in 0 ..< g.m.z {
        for y in 0 ..< g.m.y {
            for x in 0 ..< g.m.x {
                w := wfc.wave.data[x + y * g.m.x + z * g.m.x * g.m.y]

                // Count votes for each color at each position in the tile
                votes := make([][]int, s * s * sz, context.temp_allocator)
                for i in 0 ..< len(votes) {
                    votes[i] = make([]int, int(newgrid.c), context.temp_allocator)
                }

                for t in 0 ..< wfc.p_count {
                    if w[t] {
                        tile := tn.tiledata[t]
                        for dz in 0 ..< sz {
                            for dy in 0 ..< s {
                                for dx in 0 ..< s {
                                    di := dx + dy * s + dz * s * s
                                    if int(tile[di]) < int(newgrid.c) {
                                        votes[di][tile[di]] += 1
                                    }
                                }
                            }
                        }
                    }
                }

                // Write most-voted color to each position
                for dz in 0 ..< sz {
                    for dy in 0 ..< s {
                        for dx in 0 ..< s {
                            v := votes[dx + dy * s + dz * s * s]
                            max_vote := -1.0
                            argmax: u8 = 0
                            for c in 0 ..< int(newgrid.c) {
                                vote := f64(v[c]) + 0.1 * rand.float64(rng)
                                if vote > max_vote {
                                    max_vote = vote
                                    argmax = u8(c)
                                }
                            }
                            sx := x * (s - overlap) + dx
                            sy := y * (s - overlap) + dy
                            szi := z * (sz - overlapz) + dz
                            if sx < newgrid.m.x && sy < newgrid.m.y && szi < newgrid.m.z {
                                newgrid.state[sx + sy * newgrid.m.x + szi * newgrid.m.x * newgrid.m.y] = argmax
                            }
                        }
                    }
                }
            }
        }
    }
}

// Map node - transforms grid to a new grid
map_go :: proc(node: ^Node) -> bool {
    mn := &node.data.map_
    b := &mn.branch_base
    ip := node.ip
    grid := node.grid

    // If already processed children, run them
    if b.child_index >= 0 {
        for b.child_index < len(b.children) {
            child := b.children[b.child_index]
            if is_branch_kind(child.kind) {
                ip.current = child
            }
            if node_go(child) {
                return true
            }
            b.child_index += 1
        }
        // Done with children, restore original grid
        ip.current = b.parent
        b.child_index = -1
        return false
    }

    // First call: apply map transformation
    newgrid := mn.newgrid
    mx, my, mz := grid.m.x, grid.m.y, grid.m.z
    nmx, nmy, nmz := newgrid.m.x, newgrid.m.y, newgrid.m.z
    nx, dx := mn.nm[0], mn.dm[0]
    ny, dy := mn.nm[1], mn.dm[1]
    nz, dz := mn.nm[2], mn.dm[2]

    // Clear the new grid
    for i in 0 ..< len(newgrid.state) {
        newgrid.state[i] = 0
    }

    // Apply all rules
    for rule in mn.rules {
        for z in 0 ..< mz {
            for y in 0 ..< my {
                for x in 0 ..< mx {
                    // Check if rule matches at this position (with periodic wrapping)
                    if map_matches(rule, x, y, z, grid.state, mx, my, mz) {
                        // Apply rule to new grid
                        map_apply(rule, x * nx / dx, y * ny / dy, z * nz / dz, newgrid.state, nmx, nmy, nmz)
                    }
                }
            }
        }
    }

    // Switch to new grid for children
    ip.grid = newgrid

    // Start running children
    b.child_index = 0
    return true
}

// Check if rule matches at position (with periodic wrapping)
map_matches :: proc(rule: Rule, x, y, z: int, state: []u8, mx, my, mz: int) -> bool {
    for dz in 0 ..< rule.im.z {
        for dy in 0 ..< rule.im.y {
            for dx in 0 ..< rule.im.x {
                sx := x + dx
                sy := y + dy
                sz := z + dz

                if sx >= mx { sx -= mx }
                if sy >= my { sy -= my }
                if sz >= mz { sz -= mz }

                input_wave := rule.input[dx + dy * rule.im.x + dz * rule.im.x * rule.im.y]
                cell_value := state[sx + sy * mx + sz * mx * my]
                if (input_wave & (1 << uint(cell_value))) == 0 {
                    return false
                }
            }
        }
    }
    return true
}

// Apply rule output at position (with periodic wrapping)
map_apply :: proc(rule: Rule, x, y, z: int, state: []u8, mx, my, mz: int) {
    for dz in 0 ..< rule.om.z {
        for dy in 0 ..< rule.om.y {
            for dx in 0 ..< rule.om.x {
                sx := x + dx
                sy := y + dy
                sz := z + dz

                if sx >= mx { sx -= mx }
                if sy >= my { sy -= my }
                if sz >= mz { sz -= mz }

                output := rule.output[dx + dy * rule.om.x + dz * rule.om.x * rule.om.y]
                if output != 0xff {
                    state[sx + sy * mx + sz * mx * my] = output
                }
            }
        }
    }
}
