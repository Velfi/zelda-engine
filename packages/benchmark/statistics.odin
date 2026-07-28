package benchmark

Summary :: struct {
    count:                int,
    minimum, median, p95: f64,
    p99, maximum:         f64,
}

sort_samples :: proc(values: []f64) {
    for i in 1 ..< len(values) {
        value := values[i]
        j := i
        for j > 0 && values[j - 1] > value {
            values[j] = values[j - 1]
            j -= 1
        }
        values[j] = value
    }
}

percentile_index :: proc(count, percentile: int) -> int {
    if count <= 0 do return -1
    return clamp((count * clamp(percentile, 0, 100) + 99) / 100 - 1, 0, count - 1)
}

summarize_sorted :: proc(values: []f64) -> Summary {
    if len(values) == 0 do return {}
    return {
        count = len(values),
        minimum = values[0],
        median = values[len(values) / 2],
        p95 = values[percentile_index(len(values), 95)],
        p99 = values[percentile_index(len(values), 99)],
        maximum = values[len(values) - 1],
    }
}

sort_and_summarize :: proc(values: []f64) -> Summary {
    sort_samples(values)
    return summarize_sorted(values)
}
