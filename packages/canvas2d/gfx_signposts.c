#if defined(__APPLE__)
#include <os/log.h>
#include <os/signpost.h>

static os_log_t gfx_log(void) {
    static os_log_t log;
    if (log == NULL) {
        log = os_log_create("com.zelda.engine", "Canvas2D");
    }
    return log;
}

uint64_t zelda_canvas_gfx_signpost_begin(unsigned marker) {
    os_log_t log = gfx_log();
    os_signpost_id_t id = os_signpost_id_generate(log);
    switch (marker) {
    case 0: os_signpost_interval_begin(log, id, "Frame"); break;
    case 1: os_signpost_interval_begin(log, id, "Acquire Frame"); break;
    case 2: os_signpost_interval_begin(log, id, "Dynamic Uploads"); break;
    case 3: os_signpost_interval_begin(log, id, "World Pass"); break;
    case 4: os_signpost_interval_begin(log, id, "UI Pass"); break;
    case 5: os_signpost_interval_begin(log, id, "HDR Resolve"); break;
    case 6: os_signpost_interval_begin(log, id, "Screenshot Readback"); break;
    case 7: os_signpost_interval_begin(log, id, "Submit and Present"); break;
    case 8: os_signpost_interval_begin(log, id, "UI Buffer Upload"); break;
    case 9: os_signpost_interval_begin(log, id, "UI Command Setup"); break;
    case 10: os_signpost_interval_begin(log, id, "UI Ordinary Draw"); break;
    default: os_signpost_interval_begin(log, id, "Unknown GFX Work"); break;
    }
    return id;
}

void zelda_canvas_gfx_signpost_end(unsigned marker, uint64_t id) {
    os_log_t log = gfx_log();
    switch (marker) {
    case 0: os_signpost_interval_end(log, id, "Frame"); break;
    case 1: os_signpost_interval_end(log, id, "Acquire Frame"); break;
    case 2: os_signpost_interval_end(log, id, "Dynamic Uploads"); break;
    case 3: os_signpost_interval_end(log, id, "World Pass"); break;
    case 4: os_signpost_interval_end(log, id, "UI Pass"); break;
    case 5: os_signpost_interval_end(log, id, "HDR Resolve"); break;
    case 6: os_signpost_interval_end(log, id, "Screenshot Readback"); break;
    case 7: os_signpost_interval_end(log, id, "Submit and Present"); break;
    case 8: os_signpost_interval_end(log, id, "UI Buffer Upload"); break;
    case 9: os_signpost_interval_end(log, id, "UI Command Setup"); break;
    case 10: os_signpost_interval_end(log, id, "UI Ordinary Draw"); break;
    default: os_signpost_interval_end(log, id, "Unknown GFX Work"); break;
    }
}
#else
#include <stdint.h>
uint64_t zelda_canvas_gfx_signpost_begin(unsigned marker) { (void)marker; return 0; }
void zelda_canvas_gfx_signpost_end(unsigned marker, uint64_t id) { (void)marker; (void)id; }
#endif
