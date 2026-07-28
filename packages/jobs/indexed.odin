package jobs

import "core:thread"

Indexed_Proc :: #type proc(index: int, user_data: rawptr)

Worker :: struct {
    callback:  Indexed_Proc,
    user_data: rawptr,
    index:     int,
}

worker_entry :: proc(worker: ^thread.Thread) {
    job := cast(^Worker)worker.data
    job.callback(job.index, job.user_data)
}

run_indexed :: proc(count, worker_count: int, callback: Indexed_Proc, user_data: rawptr = nil) {
    if count <= 0 || callback == nil do return
    workers := clamp(worker_count, 1, count)
    if workers == 1 {
        for index in 0 ..< count do callback(index, user_data)
        return
    }
    jobs := make([]Worker, workers)
    handles := make([]^thread.Thread, workers)
    defer delete(jobs)
    defer delete(handles)
    for batch_start := 0; batch_start < count; batch_start += workers {
        batch_count := min(workers, count - batch_start)
        for slot in 0 ..< batch_count {
            jobs[slot] = {
                callback  = callback,
                user_data = user_data,
                index     = batch_start + slot,
            }
            handles[slot] = thread.create(worker_entry)
            handles[slot].data = &jobs[slot]
            thread.start(handles[slot])
        }
        for slot in 0 ..< batch_count {
            thread.join(handles[slot])
            thread.destroy(handles[slot])
        }
    }
}
