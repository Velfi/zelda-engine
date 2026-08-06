#+build !darwin
#+build !linux
package backtrace

tracking_process_memory_sample :: proc() -> Tracking_Process_Memory_Sample {
    return {}
}
