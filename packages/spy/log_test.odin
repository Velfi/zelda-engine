#+test
package spy

import "core:testing"

import "base:runtime"

Log_Test_Sink :: struct {
    count: int,
}

log_test_sink_proc :: proc(data: rawptr, _: Level, _: string, _: Options, _: runtime.Source_Code_Location) {
    sink := cast(^Log_Test_Sink)data
    sink.count += 1
}

@(test)
global_subscriber_receives_logs_alongside_context_logger :: proc(t: ^testing.T) {
    subscriber_sink: Log_Test_Sink
    subscriber: Logger = {log_test_sink_proc, &subscriber_sink, .Debug, {}}
    layer, installed := add_global_subscriber_layer_with_id(subscriber)
    testing.expect(t, installed)
    defer testing.expect(t, remove_global_subscriber_layer_by_id(layer))

    previous_logger := context.logger
    defer context.logger = previous_logger
    context_sink: Log_Test_Sink
    context.logger = {log_test_sink_proc, &context_sink, .Debug, {}}

    log(.Info, "subscriber log")

    testing.expect_value(t, context_sink.count, 1)
    testing.expect_value(t, subscriber_sink.count, 1)
}
