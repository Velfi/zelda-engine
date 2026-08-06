package impl_sdl3

import im ".."
import sdl "vendor:sdl3"

when im.BACKEND_SDL3_ENABLED {
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

    @(link_prefix = "ImGui_ImplSDL3_", default_calling_convention = "c")
    foreign _ {
        InitForOpenGL :: proc(window: ^sdl.Window, gl_ctx: rawptr) -> bool ---
        InitForMetal :: proc(window: ^sdl.Window) -> bool ---
        InitForVulkan :: proc(window: ^sdl.Window) -> bool ---
        InitForD3D :: proc(window: ^sdl.Window) -> bool ---
        InitForOther :: proc(window: ^sdl.Window) -> bool ---
        Shutdown :: proc() ---
        ProcessEvent :: proc(event: ^sdl.Event) -> bool ---
        NewFrame :: proc() ---
    }
}
