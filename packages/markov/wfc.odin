package markov
import "base:runtime"

import "core:math"
import "core:math/rand"

WFC_DX: [6]int = {1, 0, -1, 0, 0, 0}
WFC_DY: [6]int = {0, 1, 0, -1, 0, 0}
WFC_DZ: [6]int = {0, 0, 0, 0, 1, -1}
WFC_OPPOSITE: [6]int = {2, 3, 0, 1, 5, 4}

// Wave initialization
wave_init :: proc(
    w: ^Wave,
    propagator: [][][]int,
    sum_of_weights, sum_of_weight_log_weights, starting_entropy: f64,
    shannon: bool,
) {
    p := len(w.data[0])
    for i in 0 ..< len(w.data) {
        for pat in 0 ..< p {
            w.data[i][pat] = true
            for d in 0 ..< len(propagator) {
                w.compatible[i][pat][d] = len(propagator[WFC_OPPOSITE[d]][pat])
            }
        }
        w.sums_of_ones[i] = p
        if shannon {
            w.sums_of_weights[i] = sum_of_weights
            w.sums_of_weight_log_weights[i] = sum_of_weight_log_weights
            w.entropies[i] = starting_entropy
        }
    }
}

// Wave copy
wave_copy_from :: proc(dst, src: ^Wave, d: int, shannon: bool) {
    for i in 0 ..< len(dst.data) {
        for t in 0 ..< len(dst.data[i]) {
            dst.data[i][t] = src.data[i][t]
            for dir in 0 ..< d {
                dst.compatible[i][t][dir] = src.compatible[i][t][dir]
            }
        }
        dst.sums_of_ones[i] = src.sums_of_ones[i]
        if shannon {
            dst.sums_of_weights[i] = src.sums_of_weights[i]
            dst.sums_of_weight_log_weights[i] = src.sums_of_weight_log_weights[i]
            dst.entropies[i] = src.entropies[i]
        }
    }
}

// Create a new wave
wave_create :: proc(length, p, d: int, shannon: bool, allocator := context.allocator) -> ^Wave {
    w := new(Wave, allocator)
    w.data = make([][]bool, length, allocator)
    w.compatible = make([][][]int, length, allocator)
    w.sums_of_ones = make([]int, length, allocator)

    for i in 0 ..< length {
        w.data[i] = make([]bool, p, allocator)
        w.compatible[i] = make([][]int, p, allocator)
        for pat in 0 ..< p {
            w.data[i][pat] = true
            w.compatible[i][pat] = make([]int, d, allocator)
        }
    }

    if shannon {
        w.sums_of_weights = make([]f64, length, allocator)
        w.sums_of_weight_log_weights = make([]f64, length, allocator)
        w.entropies = make([]f64, length, allocator)
    }

    return w
}

// WFC Node operations
wfc_ban :: proc(wfc: ^WFC_Base, w: ^Wave, i, t: int) {
    w.data[i][t] = false

    comp := w.compatible[i][t]
    for d in 0 ..< len(wfc.propagator) {
        comp[d] = 0
    }
    wfc.stack[wfc.stack_size] = {i, t}
    wfc.stack_size += 1

    w.sums_of_ones[i] -= 1
    if wfc.shannon {
        sum := w.sums_of_weights[i]
        w.entropies[i] += w.sums_of_weight_log_weights[i] / sum - math.ln(sum)

        w.sums_of_weights[i] -= wfc.weights[t]
        w.sums_of_weight_log_weights[i] -= wfc.weight_log_weights[t]

        sum = w.sums_of_weights[i]
        w.entropies[i] -= w.sums_of_weight_log_weights[i] / sum - math.ln(sum)
    }
}

wfc_propagate :: proc(wfc: ^WFC_Base, w: ^Wave, g: ^Grid) -> bool {
    m := g.m
    prop_bans := 0

    for wfc.stack_size > 0 {
        wfc.stack_size -= 1
        item := wfc.stack[wfc.stack_size]
        i1 := item[0]
        p1 := item[1]

        x1 := i1 % m.x
        y1 := (i1 % (m.x * m.y)) / m.x
        z1 := i1 / (m.x * m.y)

        for d in 0 ..< len(wfc.propagator) {
            dx := WFC_DX[d]
            dy := WFC_DY[d]
            dz := WFC_DZ[d]
            x2 := x1 + dx
            y2 := y1 + dy
            z2 := z1 + dz

            if !wfc.periodic && (x2 < 0 || y2 < 0 || z2 < 0 || x2 + wfc.n > m.x || y2 + wfc.n > m.y || z2 + 1 > m.z) {
                continue
            }

            if x2 < 0 { x2 += m.x } else if x2 >= m.x { x2 -= m.x }
            if y2 < 0 { y2 += m.y } else if y2 >= m.y { y2 -= m.y }
            if z2 < 0 { z2 += m.z } else if z2 >= m.z { z2 -= m.z }

            i2 := x2 + y2 * m.x + z2 * m.x * m.y
            p := wfc.propagator[d][p1]
            compat := w.compatible[i2]

            for t2 in p {
                comp := compat[t2]
                comp[d] -= 1
                if comp[d] == 0 {
                    wfc_ban(wfc, w, i2, t2)
                    prop_bans += 1
                }
            }
        }
    }

    return w.sums_of_ones[0] > 0
}

wfc_next_unobserved :: proc(wfc: ^WFC_Base, w: ^Wave, g: ^Grid, rng: runtime.Random_Generator) -> int {
    m := g.m
    min_val: f64 = 1e4
    argmin := -1

    for z in 0 ..< m.z {
        for y in 0 ..< m.y {
            for x in 0 ..< m.x {
                if !wfc.periodic && (x + wfc.n > m.x || y + wfc.n > m.y || z + 1 > m.z) {
                    continue
                }
                i := x + y * m.x + z * m.x * m.y
                remaining := w.sums_of_ones[i]
                entropy := wfc.shannon ? w.entropies[i] : f64(remaining)
                if remaining > 1 && entropy <= min_val {
                    noise := 1e-6 * rand.float64(rng)
                    if entropy + noise < min_val {
                        min_val = entropy + noise
                        argmin = i
                    }
                }
            }
        }
    }

    return argmin
}

wfc_observe :: proc(wfc: ^WFC_Base, w: ^Wave, node: int, rng: runtime.Random_Generator) {
    data := w.data[node]
    for t in 0 ..< wfc.p_count {
        wfc.distribution[t] = data[t] ? wfc.weights[t] : 0.0
    }

    // Weighted random selection
    r := random_weighted(wfc.distribution, rand.float64(rng))

    for t in 0 ..< wfc.p_count {
        if data[t] != (t == r) {
            wfc_ban(wfc, w, node, t)
        }
    }
}

wfc_find_good_seed :: proc(wfc: ^WFC_Base, ip: ^Interpreter, g: ^Grid) -> (int, bool) {
    total_cells := g.m.x * g.m.y * g.m.z
    uncollapsed := 0
    collapsed_to_one := 0
    collapsed_to_zero := 0
    for i in 0 ..< total_cells {
        sum := wfc.startwave.sums_of_ones[i]
        if sum > 1 {
            uncollapsed += 1
        } else if sum == 1 {
            collapsed_to_one += 1
        } else {
            collapsed_to_zero += 1
        }
    }
    for k in 0 ..< wfc.tries {
        observations := 0
        seed := rand.int31(ip.rng)
        local_rng_state: rand.Xoshiro256_Random_State
        local_rng := rand.xoshiro256_random_generator(&local_rng_state)
        rand.reset(u64(seed), local_rng)
        wfc.stack_size = 0
        wave_copy_from(wfc.wave, wfc.startwave, len(wfc.propagator), wfc.shannon)

        for {
            node := wfc_next_unobserved(wfc, wfc.wave, g, local_rng)
            if node >= 0 {
                wfc_observe(wfc, wfc.wave, node, local_rng)
                observations += 1
                success := wfc_propagate(wfc, wfc.wave, g)
                if !success {
                    break
                }
            } else {
                return int(seed), true
            }
        }
    }

    return 0, false
}

// Helper for weighted random selection
random_weighted :: proc(weights: []f64, r: f64) -> int {
    sum: f64 = 0
    for w in weights {
        sum += w
    }
    threshold := r * sum
    partial_sum: f64 = 0
    for i in 0 ..< len(weights) {
        partial_sum += weights[i]
        if partial_sum >= threshold {
            return i
        }
    }
    return 0
}
