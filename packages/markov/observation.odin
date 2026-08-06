package markov

import "core:container/queue"

Potential_Queue_Item :: struct {
    c:       u8,
    x, y, z: int,
}

// Compute future from present state with observations
compute_future_set_present :: proc(future: []int, state: []u8, observations: []^Observation) -> bool {
    mask := make([]bool, len(observations), context.temp_allocator)
    for k in 0 ..< len(observations) {
        if observations[k] == nil {
            mask[k] = true
        }
    }

    for i in 0 ..< len(state) {
        value := state[i]
        obs := observations[value]
        mask[value] = true
        if obs != nil {
            future[i] = obs.to
            state[i] = obs.from
        } else {
            future[i] = 1 << uint(value)
        }
    }

    for k in 0 ..< len(mask) {
        if !mask[k] {
            return false
        }
    }
    return true
}

// Compute forward potentials from current state
compute_forward_potentials :: proc(potentials: [][]int, state: []u8, m: [3]int, rules: []Rule) {
    // Initialize to -1
    for c in 0 ..< len(potentials) {
        for i in 0 ..< len(potentials[c]) {
            potentials[c][i] = -1
        }
    }
    // Set current state positions to 0
    for i in 0 ..< len(state) {
        potentials[state[i]][i] = 0
    }
    compute_potentials(potentials, m, rules, false)
}

// Compute backward potentials from future
compute_backward_potentials :: proc(potentials: [][]int, future: []int, m: [3]int, rules: []Rule) {
    for c in 0 ..< len(potentials) {
        potential := potentials[c]
        for i in 0 ..< len(future) {
            potential[i] = (future[i] & (1 << uint(c))) != 0 ? 0 : -1
        }
    }
    compute_potentials(potentials, m, rules, true)
}

// BFS to compute potentials
compute_potentials :: proc(potentials: [][]int, m: [3]int, rules: []Rule, backwards: bool) {
    q: queue.Queue(Potential_Queue_Item)
    queue.init(&q, 1024, context.temp_allocator)

    // Initialize queue with cells at potential 0
    for c in 0 ..< u8(len(potentials)) {
        potential := potentials[c]
        for i in 0 ..< len(potential) {
            if potential[i] == 0 {
                queue.push_back(&q, Potential_Queue_Item{c, i % m.x, (i % (m.x * m.y)) / m.x, i / (m.x * m.y)})
            }
        }
    }

    match_mask := make([][]bool, len(rules), context.temp_allocator)
    for r in 0 ..< len(rules) {
        match_mask[r] = make([]bool, len(potentials[0]), context.temp_allocator)
    }

    for queue.len(q) > 0 {
        item := queue.pop_front(&q)
        value := item.c
        x, y, z := item.x, item.y, item.z
        i := x + y * m.x + z * m.x * m.y
        t := potentials[value][i]

        for r in 0 ..< len(rules) {
            maskr := match_mask[r]
            rule := &rules[r]
            shifts := backwards ? rule.oshifts[value] : rule.ishifts[value]

            for shift in shifts {
                sx := x - shift.x
                sy := y - shift.y
                sz := z - shift.z

                if sx < 0 || sy < 0 || sz < 0 || sx + rule.im.x > m.x || sy + rule.im.y > m.y || sz + rule.im.z > m.z {
                    continue
                }
                si := sx + sy * m.x + sz * m.x * m.y

                if !maskr[si] && forward_matches(rule, sx, sy, sz, potentials, t, m, backwards) {
                    maskr[si] = true
                    apply_forward(rule, sx, sy, sz, potentials, t, m, &q, backwards)
                }
            }
        }
    }
}

forward_matches :: proc(rule: ^Rule, x, y, z: int, potentials: [][]int, t: int, m: [3]int, backwards: bool) -> bool {
    dz, dy, dx := 0, 0, 0
    a := backwards ? rule.output : rule.binput

    for di in 0 ..< len(a) {
        value := a[di]
        if value != 0xff {
            current := potentials[value][x + dx + (y + dy) * m.x + (z + dz) * m.x * m.y]
            if current > t || current == -1 {
                return false
            }
        }
        dx += 1
        if dx == rule.im.x {
            dx = 0
            dy += 1
            if dy == rule.im.y {
                dy = 0
                dz += 1
            }
        }
    }
    return true
}

apply_forward :: proc(
    rule: ^Rule,
    x, y, z: int,
    potentials: [][]int,
    t: int,
    m: [3]int,
    q: ^queue.Queue(Potential_Queue_Item),
    backwards: bool,
) {
    a := backwards ? rule.binput : rule.output

    for dz in 0 ..< rule.im.z {
        zdz := z + dz
        for dy in 0 ..< rule.im.y {
            ydy := y + dy
            for dx in 0 ..< rule.im.x {
                xdx := x + dx
                idi := xdx + ydy * m.x + zdz * m.x * m.y
                di := dx + dy * rule.im.x + dz * rule.im.x * rule.im.y
                o := a[di]
                if o != 0xff && potentials[o][idi] == -1 {
                    potentials[o][idi] = t + 1
                    queue.push_back(q, Potential_Queue_Item{o, xdx, ydy, zdz})
                }
            }
        }
    }
}

// Check if goal state is reached
is_goal_reached :: proc(present: []u8, future: []int) -> bool {
    for i in 0 ..< len(present) {
        if ((1 << uint(present[i])) & future[i]) == 0 {
            return false
        }
    }
    return true
}

// Forward pointwise heuristic
forward_pointwise :: proc(potentials: [][]int, future: []int) -> int {
    sum := 0
    for i in 0 ..< len(future) {
        f := future[i]
        min_val := 1000
        argmin := -1
        for c in 0 ..< len(potentials) {
            potential := potentials[c][i]
            if (f & (1 << uint(c))) != 0 && potential >= 0 && potential < min_val {
                min_val = potential
                argmin = c
            }
        }
        if argmin < 0 {
            return -1
        }
        sum += min_val
    }
    return sum
}

// Backward pointwise heuristic
backward_pointwise :: proc(potentials: [][]int, present: []u8) -> int {
    sum := 0
    for i in 0 ..< len(present) {
        potential := potentials[present[i]][i]
        if potential < 0 {
            return -1
        }
        sum += potential
    }
    return sum
}
