package jobs

import "core:testing"

mark_index :: proc(index: int, data: rawptr) {
    values := cast(^[8]int)data
    values[index] = index + 1
}

@(test)
indexed_jobs_visit_every_index_once :: proc(t: ^testing.T) {
    values: [8]int
    run_indexed(len(values), 3, mark_index, &values)
    for value, index in values do testing.expect_value(t, value, index + 1)
}
