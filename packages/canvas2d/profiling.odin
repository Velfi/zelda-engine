package canvas2d

import "core:os"

Gfx_Profile_Marker :: enum u32 {
    Frame,
    Acquire_Frame,
    Dynamic_Uploads,
    World_Pass,
    UI_Pass,
    HDR_Resolve,
    Screenshot_Readback,
    Submit_And_Present,
    UI_Buffer_Upload,
    UI_Command_Setup,
    UI_Ordinary_Draw,
    Frame_Setup,
    World_Composite,
}

when ODIN_OS == .Darwin {
    foreign import gfx_signposts "system:gfx_signposts"
    foreign gfx_signposts {
        zelda_canvas_gfx_signpost_begin :: proc(marker: Gfx_Profile_Marker) -> u64 ---
        zelda_canvas_gfx_signpost_end :: proc(marker: Gfx_Profile_Marker, id: u64) ---
    }
} else {
    zelda_canvas_gfx_signpost_begin :: proc(marker: Gfx_Profile_Marker) -> u64 { return 0 }
    zelda_canvas_gfx_signpost_end :: proc(marker: Gfx_Profile_Marker, id: u64) {  }
}

gfx_profile_begin :: proc(marker: Gfx_Profile_Marker) -> u64 {
    return zelda_canvas_gfx_signpost_begin(marker)
}

gfx_profile_end :: proc(marker: Gfx_Profile_Marker, id: u64) {
    zelda_canvas_gfx_signpost_end(marker, id)
}

gfx_detailed_profile_enabled :: proc() -> bool {
    buf: [16]u8
    value := os.get_env_buf(buf[:], "ZELDA_CANVAS_GFX_DETAILED_PROFILE")
    switch value {
    case "1", "true", "TRUE", "True", "on", "ON", "On", "yes", "YES", "Yes":
        return true
    }
    return false
}
