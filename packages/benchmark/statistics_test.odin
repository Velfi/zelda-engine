package benchmark

import "core:testing"

@(test)
summary_is_deterministic_and_handles_empty_samples :: proc(t: ^testing.T) {
    values := [5]f64{5, 1, 4, 2, 3}
    summary := sort_and_summarize(values[:])
    testing.expect_value(t, values, [5]f64{1, 2, 3, 4, 5})
    testing.expect_value(t, summary.count, 5)
    testing.expect_value(t, summary.median, f64(3))
    testing.expect_value(t, summary.p95, f64(5))
    testing.expect_value(t, summarize_sorted(nil).count, 0)
}
