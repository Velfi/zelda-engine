package engine

import "core:fmt"
import "core:os"
import vk "vendor:vulkan"

checked_mul_u64 :: proc(a, b: u64) -> (u64, bool) {
    if a != 0 && b > max(u64) / a do return 0, false
    return a * b, true
}

checked_add_u64 :: proc(a, b: u64) -> (u64, bool) {
    if b > max(u64) - a do return 0, false
    return a + b, true
}

vk_clear_resource_error :: proc(ctx: ^Vk_Context) {
    if ctx != nil do ctx.last_resource_error = {}
}

vk_record_resource_error :: proc(
    ctx: ^Vk_Context,
    kind: Resource_Error_Kind,
    resource: string,
    requested_bytes, available_bytes: u64,
) {
    if ctx == nil do return
    ctx.last_resource_error = {
        kind            = kind,
        requested_bytes = requested_bytes,
        available_bytes = available_bytes,
    }
    write_fixed_string(ctx.last_resource_error.resource[:], resource)
}

vk_refresh_memory_budget :: proc(ctx: ^Vk_Context) {
    if ctx == nil || ctx.physical_device == nil do return
    ctx.caps.memory = vk_query_memory_budget(
        ctx.physical_device,
        ctx.caps.supports_memory_budget_ext,
        ctx.caps.memory.override_fraction,
    )
}

vk_memory_type_heap_index :: proc(ctx: ^Vk_Context, memory_type: u32) -> (int, bool) {
    if ctx == nil do return 0, false
    props: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(ctx.physical_device, &props)
    if memory_type >= props.memoryTypeCount do return 0, false
    return int(props.memoryTypes[memory_type].heapIndex), true
}

gpu_heap_allocation_fits :: proc(
    heap: Gpu_Memory_Heap,
    requested_bytes, headroom_bytes: u64,
) -> (
    available_bytes: u64,
    ok: bool,
) {
    if heap.usage >= heap.ceiling do return 0, false
    available_bytes = heap.ceiling - heap.usage
    needed, added := checked_add_u64(requested_bytes, headroom_bytes)
    if !added do return available_bytes, false
    return available_bytes, needed <= available_bytes
}

vk_admit_memory_allocation :: proc(
    ctx: ^Vk_Context,
    memory_type: u32,
    requested_bytes: u64,
    resource: string,
    headroom_bytes := GPU_ALLOCATION_HEADROOM_BYTES,
) -> bool {
    if requested_bytes == 0 {
        vk_record_resource_error(ctx, .Invalid_Size, resource, requested_bytes, 0)
        return false
    }
    vk_refresh_memory_budget(ctx)
    heap_index, found := vk_memory_type_heap_index(ctx, memory_type)
    if !found || heap_index < 0 || heap_index >= ctx.caps.memory.heap_count {
        vk_record_resource_error(ctx, .Unsupported, resource, requested_bytes, 0)
        return false
    }
    available, fits := gpu_heap_allocation_fits(ctx.caps.memory.heaps[heap_index], requested_bytes, headroom_bytes)
    if !fits {
        vk_record_resource_error(ctx, .Budget_Exceeded, resource, requested_bytes, available)
        return false
    }
    return true
}

vk_record_allocation_result :: proc(ctx: ^Vk_Context, result: vk.Result, resource: string, requested_bytes: u64) {
    #partial switch result {
    case .ERROR_OUT_OF_HOST_MEMORY:
        vk_record_resource_error(ctx, .Vulkan_Out_Of_Host_Memory, resource, requested_bytes, 0)
    case .ERROR_OUT_OF_DEVICE_MEMORY:
        vk_record_resource_error(ctx, .Vulkan_Out_Of_Device_Memory, resource, requested_bytes, 0)
    case .ERROR_DEVICE_LOST:
        vk_record_resource_error(ctx, .Device_Lost, resource, requested_bytes, 0)
    case:
        vk_record_resource_error(ctx, .Unsupported, resource, requested_bytes, 0)
    }
}

vk_allocate_memory_checked :: proc(
    ctx: ^Vk_Context,
    alloc: ^vk.MemoryAllocateInfo,
    resource: string,
    out: ^vk.DeviceMemory,
) -> bool {
    out^ = vk.DeviceMemory(0)
    vk_clear_resource_error(ctx)
    if !vk_admit_memory_allocation(ctx, alloc.memoryTypeIndex, u64(alloc.allocationSize), resource) do return false
    result := vk.AllocateMemory(ctx.device, alloc, nil, out)
    if result != .SUCCESS {
        vk_record_allocation_result(ctx, result, resource, u64(alloc.allocationSize))
        return false
    }
    vk_set_debug_name(ctx, .DEVICE_MEMORY, auto_cast out^, resource)
    return true
}

vk_create_host_buffer :: proc(
    ctx: ^Vk_Context,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    out: ^Vk_Buffer,
) -> bool {
    out^ = {}
    vk_clear_resource_error(ctx)
    if size == 0 {
        vk_record_resource_error(ctx, .Invalid_Size, "host buffer", 0, 0)
        return false
    }
    info := vk.BufferCreateInfo {
        sType       = .BUFFER_CREATE_INFO,
        size        = size,
        usage       = usage,
        sharingMode = .EXCLUSIVE,
    }
    if vk.CreateBuffer(ctx.device, &info, nil, &out.handle) != .SUCCESS {
        return false
    }
    vk_set_debug_name(ctx, .BUFFER, auto_cast out.handle, "host buffer")

    req: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, out.handle, &req)
    memory_type, ok := vk_find_memory_type(ctx, req.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT})
    if !ok {
        vk.DestroyBuffer(ctx.device, out.handle, nil)
        out^ = {}
        return false
    }

    alloc := vk.MemoryAllocateInfo {
        sType           = .MEMORY_ALLOCATE_INFO,
        allocationSize  = req.size,
        memoryTypeIndex = memory_type,
    }
    if !vk_allocate_memory_checked(ctx, &alloc, "host buffer", &out.memory) {
        vk.DestroyBuffer(ctx.device, out.handle, nil)
        out^ = {}
        return false
    }
    if vk.BindBufferMemory(ctx.device, out.handle, out.memory, 0) != .SUCCESS {
        vk_destroy_buffer(ctx, out)
        return false
    }
    if vk.MapMemory(ctx.device, out.memory, 0, size, {}, &out.mapped) != .SUCCESS {
        vk_destroy_buffer(ctx, out)
        return false
    }

    out.size = size
    return true
}

vk_create_device_buffer_named :: proc(
    ctx: ^Vk_Context,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    out: ^Vk_Buffer,
    name: string,
) -> bool {
    if ctx == nil || out == nil do return false
    out^ = {}
    vk_clear_resource_error(ctx)
    if size == 0 {
        vk_record_resource_error(ctx, .Invalid_Size, name, 0, 0)
        return false
    }
    info := vk.BufferCreateInfo {
        sType       = .BUFFER_CREATE_INFO,
        size        = size,
        usage       = usage,
        sharingMode = .EXCLUSIVE,
    }
    if vk.CreateBuffer(ctx.device, &info, nil, &out.handle) != .SUCCESS do return false
    vk_set_debug_name(ctx, .BUFFER, auto_cast out.handle, name)
    req: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, out.handle, &req)
    memory_type, found := vk_find_memory_type(ctx, req.memoryTypeBits, {.DEVICE_LOCAL})
    if !found {
        vk.DestroyBuffer(ctx.device, out.handle, nil)
        out^ = {}
        vk_record_resource_error(ctx, .Unsupported, name, u64(size), 0)
        return false
    }
    alloc := vk.MemoryAllocateInfo {
        sType           = .MEMORY_ALLOCATE_INFO,
        allocationSize  = req.size,
        memoryTypeIndex = memory_type,
    }
    if !vk_allocate_memory_checked(ctx, &alloc, name, &out.memory) {
        vk.DestroyBuffer(ctx.device, out.handle, nil)
        out^ = {}
        return false
    }
    if vk.BindBufferMemory(ctx.device, out.handle, out.memory, 0) != .SUCCESS {
        vk_destroy_buffer(ctx, out)
        return false
    }
    out.size = size
    return true
}

vk_cmd_copy_buffer_range :: proc(
    ctx: ^Vk_Context,
    cmd: vk.CommandBuffer,
    source, destination: ^Vk_Buffer,
    source_offset, destination_offset, size: vk.DeviceSize,
) -> bool {
    if ctx == nil || cmd == nil || source == nil || destination == nil ||
       source.handle == vk.Buffer(0) || destination.handle == vk.Buffer(0) || size == 0 ||
       source_offset + size > source.size || destination_offset + size > destination.size {
        return false
    }
    region := vk.BufferCopy {srcOffset = source_offset, dstOffset = destination_offset, size = size}
    vk.CmdCopyBuffer(cmd, source.handle, destination.handle, 1, &region)
    ctx.command_shape.transfer_copy_count += 1
    return true
}

vk_destroy_buffer :: proc(ctx: ^Vk_Context, buffer: ^Vk_Buffer) {
    if buffer.mapped != nil {
        vk.UnmapMemory(ctx.device, buffer.memory)
    }
    if buffer.handle != vk.Buffer(0) {
        vk.DestroyBuffer(ctx.device, buffer.handle, nil)
    }
    if buffer.memory != vk.DeviceMemory(0) {
        vk.FreeMemory(ctx.device, buffer.memory, nil)
    }
    buffer^ = {}
}

vk_find_memory_type :: proc(ctx: ^Vk_Context, type_bits: u32, required: vk.MemoryPropertyFlags) -> (u32, bool) {
    props: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(ctx.physical_device, &props)
    for i: u32 = 0; i < props.memoryTypeCount; i += 1 {
        if (type_bits & (1 << i)) != 0 && required <= props.memoryTypes[i].propertyFlags {
            return i, true
        }
    }
    return 0, false
}

vk_load_shader_module :: proc(ctx: ^Vk_Context, path: string, out: ^Vk_Shader_Module) -> bool {
    out^ = {}
    data, err := os.read_entire_file_from_path(path, context.allocator)
    if err != nil || len(data) == 0 {
        return false
    }
    defer delete(data, context.allocator)
    if len(data) % 4 != 0 {
        return false
    }
    info := vk.ShaderModuleCreateInfo {
        sType    = .SHADER_MODULE_CREATE_INFO,
        codeSize = len(data),
        pCode    = cast(^u32)raw_data(data),
    }
    if vk.CreateShaderModule(ctx.device, &info, nil, &out.handle) != .SUCCESS do return false
    vk_set_debug_name(ctx, .SHADER_MODULE, auto_cast out.handle, path)
    return true
}

vk_load_shader_module_with_fallback :: proc(
    ctx: ^Vk_Context,
    source_path: string,
    base_path: string,
    stage: Shader_Stage,
    entry_point: string,
    out: ^Vk_Shader_Module,
) -> bool {
    if manifest_path := shader_spirv_path(source_path, stage, entry_point, ""); manifest_path != "" {
        if vk_load_shader_module(ctx, manifest_path, out) {
            return true
        }
    }
    base_spv := fmt.tprintf("%s.spv", base_path)
    if vk_load_shader_module(ctx, base_spv, out) {
        return true
    }
    stage_spv := fmt.tprintf("%s_%s.spv", base_path, shader_stage_suffix(stage))
    if vk_load_shader_module(ctx, stage_spv, out) {
        return true
    }
    return false
}

shader_stage_suffix :: proc(stage: Shader_Stage) -> string {
    #partial switch stage {
    case .Vertex:
        return "vertex"
    case .Fragment:
        return "fragment"
    case .Compute:
        return "compute"
    }
    return "unknown"
}

vk_destroy_shader_module :: proc(ctx: ^Vk_Context, shader: ^Vk_Shader_Module) {
    if shader.handle != vk.ShaderModule(0) {
        vk.DestroyShaderModule(ctx.device, shader.handle, nil)
    }
    shader^ = {}
}

vk_destroy_graphics_pipeline :: proc(ctx: ^Vk_Context, pipeline: ^Vk_Graphics_Pipeline) {
    if pipeline.pipeline != vk.Pipeline(0) {
        vk.DestroyPipeline(ctx.device, pipeline.pipeline, nil)
    }
    if pipeline.layout != vk.PipelineLayout(0) {
        vk.DestroyPipelineLayout(ctx.device, pipeline.layout, nil)
    }
    pipeline^ = {}
}
