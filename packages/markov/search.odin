package markov
import "base:runtime"

import "core:container/priority_queue"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:slice"

// Board for A* search
Board :: struct {
    state:             []u8,
    parent_index:      int,
    depth:             int,
    backward_estimate: int,
    forward_estimate:  int,
}

board_rank :: proc(b: ^Board, rng: runtime.Random_Generator, depth_coeff: f64) -> f64 {
    result: f64
    if depth_coeff < 0.0 {
        result = 1000 - f64(b.depth)
    } else {
        result = f64(b.forward_estimate + b.backward_estimate) + 2.0 * depth_coeff * f64(b.depth)
    }
    return result + 0.0001 * rand.float64(rng)
}

board_trajectory :: proc(index: int, database: []Board, allocator := context.allocator) -> [][]u8 {
    result := make([dynamic][]u8, allocator)
    idx := index
    for database[idx].parent_index >= 0 {
        state := make([]u8, len(database[idx].state), allocator)
        copy(state, database[idx].state)
        append(&result, state)
        idx = database[idx].parent_index
    }
    slice.reverse(result[:])
    return result[:]
}

// State hash for visited map
state_hash :: proc(state: []u8) -> u64 {
    result: u64 = 17
    for b in state {
        result = result * 29 + u64(b)
    }
    return result
}

state_equals :: proc(a, b: []u8) -> bool {
    if len(a) != len(b) { return false }
    for i in 0 ..< len(a) {
        if a[i] != b[i] { return false }
    }
    return true
}

// Priority queue item for A* frontier
Frontier_Item :: struct {
    index: int,
    rank:  f64,
}

frontier_less :: proc(a, b: Frontier_Item) -> bool {
    return a.rank < b.rank
}

// A* Search
search_run :: proc(
    present: []u8,
    future: []int,
    rules: []Rule,
    m: [3]int,
    c: int,
    all: bool,
    limit: int,
    depth_coeff: f64,
    seed: u64,
    allocator := context.allocator,
) -> [][]u8 {
    size := len(present)

    bpotentials := make([][]int, c, allocator)
    fpotentials := make([][]int, c, allocator)
    for i in 0 ..< c {
        bpotentials[i] = make([]int, size, allocator)
        fpotentials[i] = make([]int, size, allocator)
    }
    defer {
        for potential in bpotentials do delete(potential, allocator)
        for potential in fpotentials do delete(potential, allocator)
        delete(bpotentials, allocator)
        delete(fpotentials, allocator)
    }

    compute_backward_potentials(bpotentials, future, m, rules)
    root_backward := backward_pointwise(bpotentials, present)
    compute_forward_potentials(fpotentials, present, m, rules)
    root_forward := forward_pointwise(fpotentials, future)

    if root_backward < 0 || root_forward < 0 {
        log.error("INCORRECT PROBLEM")
        return nil
    }
    log.infof("root estimate = (%d, %d)", root_backward, root_forward)

    if root_backward == 0 {
        return make([][]u8, 0, allocator)
    }

    root_state := make([]u8, size, allocator)
    copy(root_state, present)

    root_board: Board = {root_state, -1, 0, root_backward, root_forward}

    database := make([dynamic]Board, allocator)
    defer {
        for board in database do delete(board.state, allocator)
        delete(database)
    }
    append(&database, root_board)

    visited := make(map[u64]int, 1024, allocator)
    defer delete(visited)
    visited[state_hash(present)] = 0

    rng_state := rand.create(seed)
    rng := rand.default_random_generator(&rng_state)

    frontier: priority_queue.Priority_Queue(Frontier_Item)
    priority_queue.init(&frontier, frontier_less, priority_queue.default_swap_proc(Frontier_Item), 1024, allocator)
    defer {
        priority_queue.clear(&frontier)
        delete(frontier.queue)
    }
    priority_queue.push(&frontier, Frontier_Item{0, board_rank(&root_board, rng, depth_coeff)})

    record := root_backward + root_forward

    for priority_queue.len(frontier) > 0 && (limit < 0 || len(database) < limit) {
        parent_item := priority_queue.pop(&frontier)
        parent_index := parent_item.index
        parent_board := &database[parent_index]
        parent_depth := parent_board.depth

        children: [][]u8
        if all {
            children = all_child_states(parent_board.state, m, rules, allocator)
        } else {
            children = one_child_states(parent_board.state, m, rules, allocator)
        }

        for child_state in children {
            child_hash := state_hash(child_state)
            existing_index := -1

            if child_hash in visited {
                // A hash hit is only a candidate match. Preserve distinct states
                // that happen to collide by checking the actual board contents.
                for board, board_index in database {
                    if state_hash(board.state) == child_hash && state_equals(board.state, child_state) {
                        existing_index = board_index
                        break
                    }
                }
            }

            if existing_index >= 0 {
                old_board := &database[existing_index]
                if parent_depth + 1 < old_board.depth {
                    old_board.depth = parent_depth + 1
                    old_board.parent_index = parent_index
                    if old_board.backward_estimate >= 0 && old_board.forward_estimate >= 0 {
                        priority_queue.push(
                            &frontier,
                            Frontier_Item{existing_index, board_rank(old_board, rng, depth_coeff)},
                        )
                    }
                }
                delete(child_state, allocator)
            } else {
                child_backward := backward_pointwise(bpotentials, child_state)
                compute_forward_potentials(fpotentials, child_state, m, rules)
                child_forward := forward_pointwise(fpotentials, future)

                if child_backward < 0 || child_forward < 0 {
                    delete(child_state, allocator)
                    continue
                }

                child_board: Board = {child_state, parent_index, parent_depth + 1, child_backward, child_forward}
                append(&database, child_board)
                child_index := len(database) - 1
                visited[child_hash] = child_index

                if child_forward == 0 {
                    log.infof("found trajectory of length %d, visited %d states", parent_depth + 1, len(visited))
                    trajectory := board_trajectory(child_index, database[:], allocator)
                    delete(children, allocator)
                    return trajectory
                } else {
                    if limit < 0 && child_backward + child_forward <= record {
                        record = child_backward + child_forward
                        log.infof("found state of record estimate %d = %d + %d", record, child_backward, child_forward)
                    }
                    priority_queue.push(
                        &frontier,
                        Frontier_Item{child_index, board_rank(&child_board, rng, depth_coeff)},
                    )
                }
            }
        }
        delete(children, allocator)
    }

    return nil
}

// Generate one child state per matching rule position
one_child_states :: proc(state: []u8, m: [3]int, rules: []Rule, allocator := context.temp_allocator) -> [][]u8 {
    result := make([dynamic][]u8, allocator)

    for &rule in rules {
        for z in 0 ..< m.z {
            for y in 0 ..< m.y {
                for x in 0 ..< m.x {
                    if search_matches(&rule, x, y, z, state, m) {
                        append(&result, search_applied(&rule, x, y, z, state, m, allocator))
                    }
                }
            }
        }
    }
    return result[:]
}

search_matches :: proc(rule: ^Rule, x, y, z: int, state: []u8, m: [3]int) -> bool {
    if x + rule.im.x > m.x || y + rule.im.y > m.y || z + rule.im.z > m.z {
        return false
    }

    for dz in 0 ..< rule.im.z {
        for dy in 0 ..< rule.im.y {
            for dx in 0 ..< rule.im.x {
                rule_index := dx + dy * rule.im.x + dz * rule.im.x * rule.im.y
                state_index := x + dx + (y + dy) * m.x + (z + dz) * m.x * m.y
                if (rule.input[rule_index] & (1 << uint(state[state_index]))) == 0 {
                    return false
                }
            }
        }
    }
    return true
}

search_applied :: proc(
    rule: ^Rule,
    x, y, z: int,
    state: []u8,
    m: [3]int,
    allocator := context.temp_allocator,
) -> []u8 {
    result := make([]u8, len(state), allocator)
    copy(result, state)

    for dz in 0 ..< rule.om.z {
        for dy in 0 ..< rule.om.y {
            for dx in 0 ..< rule.om.x {
                new_value := rule.output[dx + dy * rule.om.x + dz * rule.om.x * rule.om.y]
                if new_value != 0xff {
                    result[x + dx + (y + dy) * m.x + (z + dz) * m.x * m.y] = new_value
                }
            }
        }
    }
    return result
}

// Generate all non-overlapping child states
all_child_states :: proc(state: []u8, m: [3]int, rules: []Rule, allocator := context.temp_allocator) -> [][]u8 {
    tiles := make([dynamic]Match_Tile, allocator)
    defer delete(tiles)
    amounts := make([]int, len(state), allocator)
    defer delete(amounts, allocator)

    for z in 0 ..< m.z {
        for y in 0 ..< m.y {
            for x in 0 ..< m.x {
                i := x + y * m.x + z * m.x * m.y
                for &rule in rules {
                    if search_matches(&rule, x, y, z, state, m) {
                        append(&tiles, Match_Tile{&rule, i})
                        for dz in 0 ..< rule.im.z {
                            for dy in 0 ..< rule.im.y {
                                for dx in 0 ..< rule.im.x {
                                    amounts[x + dx + (y + dy) * m.x + (z + dz) * m.x * m.y] += 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    mask := make([]bool, len(tiles), allocator)
    defer delete(mask, allocator)
    for i in 0 ..< len(mask) { mask[i] = true }

    solution := make([dynamic]Match_Tile, allocator)
    defer delete(solution)
    result := make([dynamic][]u8, allocator)

    enumerate_solutions(&result, &solution, tiles[:], amounts, mask, state, m, allocator)
    return result[:]
}

max_positive_index :: proc(amounts: []int) -> int {
    max_val := 0
    argmax := -1
    for i in 0 ..< len(amounts) {
        if amounts[i] > max_val {
            max_val = amounts[i]
            argmax = i
        }
    }
    return argmax
}

is_inside :: proc(px, py, pz: int, rule: ^Rule, x, y, z: int) -> bool {
    return x <= px && px < x + rule.im.x && y <= py && py < y + rule.im.y && z <= pz && pz < z + rule.im.z
}

tiles_overlap :: proc(r0: ^Rule, i0: int, r1: ^Rule, i1: int, m: [3]int) -> bool {
    x0 := i0 % m.x
    y0 := (i0 / m.x) % m.y
    z0 := i0 / (m.x * m.y)
    x1 := i1 % m.x
    y1 := (i1 / m.x) % m.y
    z1 := i1 / (m.x * m.y)
    for dz in 0 ..< r0.im.z {
        for dy in 0 ..< r0.im.y {
            for dx in 0 ..< r0.im.x {
                if is_inside(x0 + dx, y0 + dy, z0 + dz, r1, x1, y1, z1) {
                    return true
                }
            }
        }
    }
    return false
}

Match_Tile :: struct {
    rule: ^Rule,
    i:    int,
}

enumerate_solutions :: proc(
    children: ^[dynamic][]u8,
    solution: ^[dynamic]Match_Tile,
    tiles: []Match_Tile,
    amounts: []int,
    mask: []bool,
    state: []u8,
    m: [3]int,
    allocator: mem.Allocator,
) {
    I := max_positive_index(amounts)
    if I < 0 {
        append(children, apply_solution(state, solution[:], m, allocator))
        return
    }

    X := I % m.x
    Y := (I / m.x) % m.y
    Z := I / (m.x * m.y)

    cover := make([dynamic]Match_Tile, context.temp_allocator)
    for l in 0 ..< len(tiles) {
        tile := tiles[l]
        tile_x := tile.i % m.x
        tile_y := (tile.i / m.x) % m.y
        tile_z := tile.i / (m.x * m.y)
        if mask[l] && is_inside(X, Y, Z, tile.rule, tile_x, tile_y, tile_z) {
            append(&cover, tile)
        }
    }

    for tile in cover {
        append(solution, tile)

        intersecting := make([dynamic]int, context.temp_allocator)
        for l in 0 ..< len(tiles) {
            if mask[l] {
                t := tiles[l]
                if tiles_overlap(tile.rule, tile.i, t.rule, t.i, m) {
                    append(&intersecting, l)
                }
            }
        }

        for l in intersecting { hide_tile(l, false, tiles, amounts, mask, m) }
        enumerate_solutions(children, solution, tiles, amounts, mask, state, m, allocator)
        for l in intersecting { hide_tile(l, true, tiles, amounts, mask, m) }

        pop(solution)
    }
}

hide_tile :: proc(l: int, unhide: bool, tiles: []Match_Tile, amounts: []int, mask: []bool, m: [3]int) {
    mask[l] = unhide
    tile := tiles[l]
    x := tile.i % m.x
    y := (tile.i / m.x) % m.y
    z := tile.i / (m.x * m.y)
    incr := unhide ? 1 : -1
    for dz in 0 ..< tile.rule.im.z {
        for dy in 0 ..< tile.rule.im.y {
            for dx in 0 ..< tile.rule.im.x {
                amounts[x + dx + (y + dy) * m.x + (z + dz) * m.x * m.y] += incr
            }
        }
    }
}

apply_solution :: proc(state: []u8, solution: []Match_Tile, m: [3]int, allocator: mem.Allocator) -> []u8 {
    result := make([]u8, len(state), allocator)
    copy(result, state)
    for tile in solution {
        x := tile.i % m.x
        y := (tile.i / m.x) % m.y
        z := tile.i / (m.x * m.y)
        for dz in 0 ..< tile.rule.om.z {
            for dy in 0 ..< tile.rule.om.y {
                for dx in 0 ..< tile.rule.om.x {
                    result[x + dx + (y + dy) * m.x + (z + dz) * m.x * m.y] =
                        tile.rule.output[dx + dy * tile.rule.om.x + dz * tile.rule.om.x * tile.rule.om.y]
                }
            }
        }
    }
    return result
}
