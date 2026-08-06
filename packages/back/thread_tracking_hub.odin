package backtrace

import "core:mem"
import "core:sync"

Thread_Tracking_Hub :: struct {
    merged_tracker:    Tracking_Allocator,
    merged_allocator:  mem.Allocator,
    backing_allocator: mem.Allocator,
    internals:         mem.Allocator,
    merge_mutex:       sync.Mutex,
    initialized:       bool,
}

Thread_Tracking_Binding :: struct {
    tracker:   Tracking_Allocator,
    allocator: mem.Allocator,
    hub:       ^Thread_Tracking_Hub,
    active:    bool,
}

// #+vet redundancy public-api
thread_tracking_hub_init :: proc(
    hub: ^Thread_Tracking_Hub,
    backing_allocator: mem.Allocator,
    alloc := context.allocator,
) {
    if hub == nil {
        return
    }
    if hub.initialized {
        tracking_allocator_destroy(&hub.merged_tracker)
        hub.merged_tracker = {}
    }

    tracking_allocator_init(&hub.merged_tracker, backing_allocator, alloc)
    hub.merged_allocator = tracking_allocator(&hub.merged_tracker)
    hub.backing_allocator = backing_allocator
    hub.internals = alloc
    hub.initialized = true
}

// #+vet redundancy public-api
thread_tracking_hub_destroy :: proc(hub: ^Thread_Tracking_Hub) {
    if hub == nil {
        return
    }
    if hub.initialized {
        tracking_allocator_destroy(&hub.merged_tracker)
    }
    hub.merged_tracker = {}
    hub.merged_allocator = {}
    hub.backing_allocator = {}
    hub.internals = {}
    hub.initialized = false
}

// #+vet redundancy public-api
thread_tracking_hub_allocator :: proc(hub: ^Thread_Tracking_Hub) -> mem.Allocator {
    if hub == nil || !hub.initialized {
        return {}
    }
    return hub.merged_allocator
}

// #+vet redundancy public-api
thread_tracking_hub_merge_tracker :: proc(hub: ^Thread_Tracking_Hub, src: ^Tracking_Allocator) {
    if hub == nil || src == nil || !hub.initialized {
        return
    }

    sync.guard(&hub.merge_mutex)

    dst := &hub.merged_tracker

    for leak_group in src.leak_group_array {
        if leak_group.count <= 0 {
            continue
        }

        if existing_index, ok := dst.leak_group_index[leak_group.key]; ok {
            dst.leak_group_array[existing_index].count += leak_group.count
        } else {
            dst.leak_group_index[leak_group.key] = len(dst.leak_group_array)
            append(&dst.leak_group_array, leak_group)
        }
    }

    for bad_free in src.bad_free_array {
        if bad_free.count <= 0 {
            continue
        }

        group_key: Tracking_Bad_Free_Group_Key = {
            location  = bad_free.location,
            backtrace = bad_free.backtrace,
        }
        if existing_index, ok := dst.bad_free_group_index[group_key]; ok {
            dst.bad_free_array[existing_index].count += bad_free.count
        } else {
            dst.bad_free_group_index[group_key] = len(dst.bad_free_array)
            append(&dst.bad_free_array, bad_free)
        }
    }

    for top_group in src.alloc_top_group_array {
        if top_group.count <= 0 || top_group.max_size <= 0 {
            continue
        }

        if existing_index, ok := dst.alloc_top_group_index[top_group.key]; ok {
            merged := &dst.alloc_top_group_array[existing_index]
            merged.count += top_group.count
            merged.total_size += top_group.total_size
            if top_group.max_size > merged.max_size {
                merged.max_size = top_group.max_size
                merged.backtrace = top_group.backtrace
            }
        } else {
            dst.alloc_top_group_index[top_group.key] = len(dst.alloc_top_group_array)
            append(&dst.alloc_top_group_array, top_group)
        }
    }
}

// #+vet redundancy public-api
thread_tracking_hub_print_results :: proc(hub: ^Thread_Tracking_Hub, type: Result_Type = .Both) {
    if hub == nil || !hub.initialized {
        return
    }
    tracking_allocator_print_results(&hub.merged_tracker, type)
}

// #+vet redundancy public-api
thread_tracking_hub_clear :: proc(hub: ^Thread_Tracking_Hub) {
    if hub == nil || !hub.initialized {
        return
    }
    tracking_allocator_clear(&hub.merged_tracker)
}

// #+vet redundancy public-api
thread_tracking_binding_init :: proc(
    binding: ^Thread_Tracking_Binding,
    hub: ^Thread_Tracking_Hub,
    backing_allocator: mem.Allocator,
) -> mem.Allocator {
    if binding == nil || hub == nil || !hub.initialized {
        return {}
    }

    tracking_allocator_init(&binding.tracker, backing_allocator, hub.internals)
    binding.allocator = tracking_allocator(&binding.tracker)
    binding.hub = hub
    binding.active = true
    return binding.allocator
}

// #+vet redundancy public-api
thread_tracking_binding_init_default :: proc(
    binding: ^Thread_Tracking_Binding,
    hub: ^Thread_Tracking_Hub,
) -> mem.Allocator {
    if hub == nil {
        return {}
    }
    return thread_tracking_binding_init(binding, hub, hub.backing_allocator)
}

// #+vet redundancy public-api
thread_tracking_binding_merge_and_destroy :: proc(binding: ^Thread_Tracking_Binding) {
    if binding == nil || !binding.active {
        return
    }

    if binding.hub != nil {
        thread_tracking_hub_merge_tracker(binding.hub, &binding.tracker)
    }
    tracking_allocator_destroy(&binding.tracker)

    binding.tracker = {}
    binding.allocator = {}
    binding.hub = nil
    binding.active = false
}
