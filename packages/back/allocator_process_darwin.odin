#+build darwin
package backtrace

import "core:c"
import "core:os"
import "core:sys/darwin"
import "core:sys/posix"

foreign import libc "system:System"

@(default_calling_convention = "c")
foreign libc {
    malloc_zone_statistics :: proc(zone: rawptr, stats: ^malloc_statistics_t) ---
}

malloc_statistics_t :: struct {
    blocks_in_use:   c.uint,
    size_in_use:     c.size_t,
    max_size_in_use: c.size_t,
    size_allocated:  c.size_t,
}

TASK_VM_INFO :: 22
TASK_VM_INFO_COUNT :: u32(size_of(task_vm_info) / size_of(c.int))

task_vm_info :: struct {
    virtual_size:                               u64,
    region_count:                               c.int,
    page_size:                                  c.int,
    resident_size:                              u64,
    resident_size_peak:                         u64,
    device:                                     u64,
    device_peak:                                u64,
    internal:                                   u64,
    internal_peak:                              u64,
    external:                                   u64,
    external_peak:                              u64,
    reusable:                                   u64,
    reusable_peak:                              u64,
    purgeable_volatile_pmap:                    u64,
    purgeable_volatile_resident:                u64,
    purgeable_volatile_virtual:                 u64,
    compressed:                                 u64,
    compressed_peak:                            u64,
    compressed_lifetime:                        u64,
    phys_footprint:                             u64,
    min_address:                                u64,
    max_address:                                u64,
    ledger_phys_footprint_peak:                 i64,
    ledger_purgeable_nonvolatile:               i64,
    ledger_purgeable_novolatile_compressed:     i64,
    ledger_purgeable_volatile:                  i64,
    ledger_purgeable_volatile_compressed:       i64,
    ledger_tag_network_nonvolatile:             i64,
    ledger_tag_network_nonvolatile_compressed:  i64,
    ledger_tag_network_volatile:                i64,
    ledger_tag_network_volatile_compressed:     i64,
    ledger_tag_media_footprint:                 i64,
    ledger_tag_media_footprint_compressed:      i64,
    ledger_tag_media_nofootprint:               i64,
    ledger_tag_media_nofootprint_compressed:    i64,
    ledger_tag_graphics_footprint:              i64,
    ledger_tag_graphics_footprint_compressed:   i64,
    ledger_tag_graphics_nofootprint:            i64,
    ledger_tag_graphics_nofootprint_compressed: i64,
    ledger_tag_neural_footprint:                i64,
    ledger_tag_neural_footprint_compressed:     i64,
    ledger_tag_neural_nofootprint:              i64,
    ledger_tag_neural_nofootprint_compressed:   i64,
    limit_bytes_remaining:                      u64,
    decompressions:                             c.int,
    ledger_swapins:                             i64,
    ledger_tag_neural_nofootprint_total:        i64,
    ledger_tag_neural_nofootprint_peak:         i64,
}

tracking_u64_from_i64 :: #force_inline proc(v: i64) -> u64 {
    if v <= 0 do return 0
    return u64(v)
}

tracking_process_memory_sample :: proc() -> (sample: Tracking_Process_Memory_Sample) {

    usage: darwin.rusage_info_v0
    pid := posix.pid_t(os.get_pid())
    if ret := darwin.proc_pid_rusage(pid, .V0, &usage); ret == 0 {
        sample.flags += {.ok}
        sample.rss = usage.ri_resident_size
        sample.phys_footprint = usage.ri_phys_footprint
    }

    heap_stats: malloc_statistics_t
    malloc_zone_statistics(nil, &heap_stats)
    sample.flags += {.heap_ok}
    sample.heap_blocks_in_use = u64(heap_stats.blocks_in_use)
    sample.heap_size_in_use = u64(heap_stats.size_in_use)
    sample.heap_size_in_use_peak = u64(heap_stats.max_size_in_use)
    if sample.heap_size_in_use_peak < sample.heap_size_in_use {
        sample.heap_size_in_use_peak = sample.heap_size_in_use
    }
    sample.heap_size_allocated = u64(heap_stats.size_allocated)
    sample.flags += {.ok}

    vm_info: task_vm_info
    info_count := TASK_VM_INFO_COUNT
    if darwin.task_info(
           darwin.task_t(darwin.mach_task_self()),
           TASK_VM_INFO,
           cast(darwin.task_info_t)&vm_info,
           &info_count,
       ) ==
       .Success {
        sample.flags += {.ok, .vm_ok}
        if sample.virt == 0 do sample.virt = vm_info.virtual_size
        if sample.rss == 0 do sample.rss = vm_info.resident_size
        if sample.phys_footprint == 0 do sample.phys_footprint = vm_info.phys_footprint
        sample.vm_resident_peak = vm_info.resident_size_peak
        sample.vm_device = vm_info.device
        sample.vm_device_peak = vm_info.device_peak
        sample.vm_internal = vm_info.internal
        sample.vm_internal_peak = vm_info.internal_peak
        sample.vm_external = vm_info.external
        sample.vm_external_peak = vm_info.external_peak
        sample.vm_reusable = vm_info.reusable
        sample.vm_reusable_peak = vm_info.reusable_peak
        sample.vm_compressed = vm_info.compressed
        sample.vm_compressed_peak = vm_info.compressed_peak
        sample.vm_graphics_footprint = tracking_u64_from_i64(vm_info.ledger_tag_graphics_footprint)
        sample.vm_graphics_nofootprint = tracking_u64_from_i64(vm_info.ledger_tag_graphics_nofootprint)
    }

    return sample
}
