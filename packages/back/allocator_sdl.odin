package backtrace

Tracking_SDL_Memory_Flag :: enum u8 {
    ok,
    installed,
    install_too_late,
}

Tracking_SDL_Memory_Snapshot :: struct {
    preexisting_alloc_count: u64,
    live_bytes:              u64,
    peak_live_bytes:         u64,
    total_alloc_bytes:       u64,
    live_alloc_count:        u64,
    peak_live_alloc_count:   u64,
    total_alloc_count:       u64,
    flags:                   bit_set[Tracking_SDL_Memory_Flag;u8],
}

tracking_allocator_install_sdl_memory_hooks :: proc(alloc := context.allocator) {  }

tracking_sdl_memory_reset :: proc() {  }

tracking_sdl_memory_snapshot :: proc() -> Tracking_SDL_Memory_Snapshot {
    return {}
}

tracking_sdl_external_top_alloc_snapshot :: proc() -> Tracking_External_Top_Alloc_Snapshot {
    return {}
}
