package imgui_impl_opengl3

import im ".."

when im.BACKEND_OPENGL3_ENABLED {
    when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 {
        foreign import lib "../imgui_wasm.a"
    } else {
        when ODIN_OS == .Linux {
            @(require) foreign import stdcpp "system:stdc++"
        } else when ODIN_OS == .Darwin {
            @(require) foreign import stdcpp "system:c++"
        }
        when ODIN_OS == .Windows {
            when ODIN_ARCH == .amd64 {
                foreign import lib "../windows_x64/imgui.lib"
            } else {
                foreign import lib "../windows_arm64/imgui.lib"
            }
        } else when ODIN_OS == .Linux {
            when ODIN_ARCH == .amd64 {
                foreign import lib "../linux_x64/imgui.linux.a"
            } else {
                foreign import lib "../linux_arm64/imgui.linux.a"
            }
        } else when ODIN_OS == .Darwin {
            when ODIN_ARCH == .amd64 {
                foreign import lib "../darwin_x64/imgui.darwin.a"
            } else {
                foreign import lib "../darwin_arm64/imgui.darwin.a"
            }
        }
    }

    // imgui_impl_opengl3.h
    // Last checked `v1.91.1-docking` (6df1a0)
    @(link_prefix = "ImGui_ImplOpenGL3_", default_calling_convention = "c")
    foreign _ {
        // Backend API
        Init :: proc(glsl_version: cstring = nil) -> bool ---
        Shutdown :: proc() ---
        NewFrame :: proc() ---
        RenderDrawData :: proc(draw_data: ^im.DrawData) ---

        // (Optional) Called by Init/NewFrame/Shutdown
        CreateFontsTexture :: proc() -> bool ---
        DestroyFontsTexture :: proc() ---
        CreateDeviceObjects :: proc() -> bool ---
        DestroyDeviceObjects :: proc() ---
    }
}
