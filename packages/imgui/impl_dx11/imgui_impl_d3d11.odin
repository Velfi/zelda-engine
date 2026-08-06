#+build windows
package imgui_impl_d3d11

import im "../"
import d3d11 "vendor:directx/d3d11"

// imgui_impl_dx11.h
// Last checked `v1.91.7-docking` (960a6f1)
@(link_prefix = "ImGui_ImplDX11_")
foreign _ {
    Init :: proc(device: ^d3d11.IDevice, device_context: ^d3d11.IDeviceContext) -> bool ---
    Shutdown :: proc() ---
    NewFrame :: proc() ---
    RenderDrawData :: proc(draw_data: ^im.DrawData) ---

    // Use if you want to reset your rendering device without losing Dear ImGui state.
    InvalidateDeviceObjects :: proc() ---
    CreateDeviceObjects :: proc() -> bool ---
}

// [BETA] Selected render state data shared with callbacks.
// This is temporarily stored in GetPlatformIO().Renderer_RenderState during the ImGui_ImplDX11_RenderDrawData() call.
// (Please open an issue if you feel you need access to more data)
RenderState :: struct {
    Device:               ^d3d11.IDevice,
    DeviceContext:        ^d3d11.IDeviceContext,
    SamplerDefault:       ^d3d11.ISamplerState,
    VertexConstantBuffer: ^d3d11.IBuffer,
}
