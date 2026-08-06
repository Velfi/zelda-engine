// C ABI wrappers for imgui_impl_metal symbols used by Odin bindings.
#include "../imgui/backends/imgui_impl_metal.h"

#ifdef __OBJC__
extern "C" {
bool cImGui_ImplMetal_Init(id<MTLDevice> device) {
    return ImGui_ImplMetal_Init(device);
}

void cImGui_ImplMetal_Shutdown(void) {
    ImGui_ImplMetal_Shutdown();
}

void cImGui_ImplMetal_NewFrame(MTLRenderPassDescriptor* renderPassDescriptor) {
    ImGui_ImplMetal_NewFrame(renderPassDescriptor);
}

void cImGui_ImplMetal_RenderDrawData(ImDrawData* drawData, id<MTLCommandBuffer> commandBuffer, id<MTLRenderCommandEncoder> commandEncoder) {
    ImGui_ImplMetal_RenderDrawData(drawData, commandBuffer, commandEncoder);
}

bool cImGui_ImplMetal_CreateFontsTexture(id<MTLDevice> device) {
    return ImGui_ImplMetal_CreateFontsTexture(device);
}

void cImGui_ImplMetal_DestroyFontsTexture(void) {
    ImGui_ImplMetal_DestroyFontsTexture();
}

bool cImGui_ImplMetal_CreateDeviceObjects(id<MTLDevice> device) {
    return ImGui_ImplMetal_CreateDeviceObjects(device);
}

void cImGui_ImplMetal_DestroyDeviceObjects(void) {
    ImGui_ImplMetal_DestroyDeviceObjects();
}
}
#endif
