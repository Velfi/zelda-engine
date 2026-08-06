package backtrace

import "core:mem"
import "core:testing"

@(test)
tracking_allocator_backing_allocator_excludes_dynamic_arena_storage :: proc(t: ^testing.T) {
    tracker: Tracking_Allocator
    tracking_allocator_init(&tracker, context.allocator)
    defer tracking_allocator_destroy(&tracker)
    tracked_allocator := tracking_allocator(&tracker)
    backing_allocator := tracking_allocator_backing_allocator(tracked_allocator)
    testing.expect_value(t, backing_allocator.procedure, context.allocator.procedure)
    passthrough_allocator := tracking_allocator_backing_allocator(context.allocator)
    testing.expect_value(t, passthrough_allocator.procedure, context.allocator.procedure)
    testing.expect_value(t, passthrough_allocator.data, context.allocator.data)

    initial_count := len(tracker.allocation_map)
    initial_bytes := tracker.live_alloc_size
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(
        &arena,
        block_allocator = backing_allocator,
        array_allocator = backing_allocator,
        block_size = 64,
        out_band_size = 32,
    )
    _, allocation_error := mem.dynamic_arena_alloc(&arena, 16, 8)
    testing.expect_value(t, allocation_error, mem.Allocator_Error.None)
    _, allocation_error = mem.dynamic_arena_alloc(&arena, 64, 8)
    testing.expect_value(t, allocation_error, mem.Allocator_Error.None)
    testing.expect_value(t, len(tracker.allocation_map), initial_count)
    testing.expect_value(t, tracker.live_alloc_size, initial_bytes)
    mem.dynamic_arena_destroy(&arena)
    testing.expect_value(t, len(tracker.allocation_map), initial_count)
    testing.expect_value(t, tracker.live_alloc_size, initial_bytes)

    ordinary: []byte
    ordinary, allocation_error = mem.alloc_bytes(8, 8, tracked_allocator)
    testing.expect_value(t, allocation_error, mem.Allocator_Error.None)
    testing.expect_value(t, len(tracker.allocation_map), initial_count + 1)
    testing.expect_value(t, tracker.live_alloc_size, initial_bytes + 8)
    _ = mem.free(raw_data(ordinary), tracked_allocator)
    testing.expect_value(t, len(tracker.allocation_map), initial_count)
    testing.expect_value(t, tracker.live_alloc_size, initial_bytes)
}
