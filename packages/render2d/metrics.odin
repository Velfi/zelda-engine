package render2d

Frame_Metrics :: struct {
    draw_calls:            u64,
    batches:               u64,
    upload_bytes:          u64,
    screenshot_latency_ms: f64,
}

Metrics :: struct {
    current: Frame_Metrics,
    last:    Frame_Metrics,
}

metrics_begin_frame :: proc(metrics: ^Metrics) {
    metrics.current = {}
}

@(no_instrumentation)
metrics_record_draw :: #force_inline proc(metrics: ^Metrics, count: u64 = 1) {
    metrics.current.draw_calls += count
}

metrics_record_batches :: proc(metrics: ^Metrics, count: u64) {
    metrics.current.batches += count
}

metrics_record_upload :: proc(metrics: ^Metrics, byte_count: u64) {
    metrics.current.upload_bytes += byte_count
}

metrics_record_screenshot :: proc(metrics: ^Metrics, latency_ms: f64) {
    metrics.current.screenshot_latency_ms = latency_ms
}

metrics_end_frame :: proc(metrics: ^Metrics) {
    metrics.last = metrics.current
}
