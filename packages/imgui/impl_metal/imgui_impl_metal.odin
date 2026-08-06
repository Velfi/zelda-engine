#+build darwin
package imgui_impl_metal

import im "../"
import mtl "vendor:darwin/Metal"

// imgui_impl_metal.h
// Last checked `v1.91.7-docking` (a9cd0f5)
@(link_prefix = "cImGui_ImplMetal_")
foreign _ {
    Init :: proc(device: ^mtl.Device) -> bool ---
    Shutdown :: proc() ---
    NewFrame :: proc(renderPassDescriptor: ^mtl.RenderPassDescriptor) ---
    RenderDrawData :: proc(draw_data: ^im.DrawData, commandBuffer: ^mtl.CommandBuffer, commandEncoder: ^mtl.RenderCommandEncoder) ---

    // Called by Init/NewFrame/Shutdown
    CreateFontsTexture :: proc(device: ^mtl.Device) -> bool ---
    DestroyFontsTexture :: proc() ---
    CreateDeviceObjects :: proc(device: ^mtl.Device) -> bool ---
    DestroyDeviceObjects :: proc() ---
}

RenderState :: struct {
    CommandBuffer:  ^mtl.CommandBuffer,
    CommandEncoder: ^mtl.RenderCommandEncoder,
    SamplerDefault: ^mtl.SamplerState,
}
