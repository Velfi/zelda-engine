package markov
import "base:runtime"

import "core:math/rand"

// Run the interpreter and return all frames
run :: proc(ip: ^Interpreter, seed: int, steps: int, gif: bool, allocator := context.allocator) -> [dynamic]Frame {
    frames := make([dynamic]Frame, allocator)

    // Initialize RNG - store state in interpreter and wrap as generator
    ip.rng = rand.xoshiro256_random_generator(&ip.rng_state)
    rand.reset(u64(seed), ip.rng)
    ip.grid = ip.startgrid
    grid_clear(ip.grid)

    // Set origin if needed
    if ip.origin {
        g := ip.grid
        center := g.m.x / 2 + (g.m.y / 2) * g.m.x + (g.m.z / 2) * g.m.x * g.m.y
        g.state[center] = 1
    }

    clear(&ip.changes)
    clear(&ip.first)
    append(&ip.first, 0)

    if ip.root != nil {
        node_reset(ip.root)
    }
    ip.current = ip.root

    ip.gif = gif
    ip.counter = 0

    // Main loop
    for ip.current != nil && (steps <= 0 || ip.counter < steps) {
        if gif {
            append(&frames, make_frame(ip.grid, allocator))
        }

        node_go(ip.current)
        ip.counter += 1
        append(&ip.first, len(ip.changes))
    }

    // Final frame
    append(&frames, make_frame(ip.grid, allocator))

    return frames
}

make_frame :: proc(g: ^Grid, allocator := context.allocator) -> Frame {
    frame: Frame
    frame.m = g.m
    frame.state = make([]u8, len(g.state), allocator)
    copy(frame.state, g.state)
    frame.chars = make([]u8, int(g.c), allocator)
    for i in 0 ..< int(g.c) {
        frame.chars[i] = g.chars[i]
    }
    return frame
}

frame_destroy :: proc(frame: ^Frame, allocator := context.allocator) {
    if frame == nil do return
    delete(frame.state, allocator)
    delete(frame.chars, allocator)
    frame^ = {}
}

frames_destroy :: proc(frames: ^[dynamic]Frame, allocator := context.allocator) {
    if frames == nil do return
    for &frame in frames^ do frame_destroy(&frame, allocator)
    delete(frames^)
    frames^ = nil
}

// Create an interpreter from a loaded model
interpreter_create :: proc(root: ^Node, grid: ^Grid, origin: bool, allocator := context.allocator) -> ^Interpreter {
    ip := new(Interpreter, allocator)
    ip.allocator = allocator
    ip.root = root
    ip.current = root
    ip.grid = grid
    ip.startgrid = grid
    ip.origin = origin
    ip.changes = make([dynamic][3]int, allocator)
    ip.first = make([dynamic]int, allocator)
    return ip
}
