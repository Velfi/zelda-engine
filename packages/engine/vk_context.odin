package engine

ENGINE_VERSION_MAJOR :: u32(0)
ENGINE_VERSION_MINOR :: u32(1)
ENGINE_VERSION_PATCH :: u32(0)

import "core:strings"
import "core:time"
import spy "../spy"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

MAX_GPU_HEAPS :: 16
MAX_VK_EXTENSIONS :: 32
MAX_SWAPCHAIN_IMAGES :: 8
MAX_FRAMES_IN_FLIGHT :: 2
DEFAULT_REPORTED_BUDGET_CEILING :: 0.70
DEFAULT_HEAP_SIZE_CEILING :: 0.60
GPU_ALLOCATION_HEADROOM_BYTES :: u64(64 * 1024 * 1024)
VK_SHUTDOWN_FRAME_FENCE_TIMEOUT_NS :: u64(1_000_000_000)

Gpu_Memory_Heap :: struct {
    size:       u64,
    usage:      u64,
    budget:     u64,
    ceiling:    u64,
    has_budget: bool,
}

Gpu_Memory_Budget :: struct {
    heaps:                  [MAX_GPU_HEAPS]Gpu_Memory_Heap,
    heap_count:             int,
    total_ceiling:          u64,
    uses_memory_budget_ext: bool,
    override_fraction:      f32,
}

Resource_Error_Kind :: enum {
    None,
    Invalid_Size,
    Size_Overflow,
    Budget_Exceeded,
    Cpu_Out_Of_Memory,
    Vulkan_Out_Of_Host_Memory,
    Vulkan_Out_Of_Device_Memory,
    Device_Lost,
    Unsupported,
}

Resource_Error :: struct {
    kind:            Resource_Error_Kind,
    requested_bytes: u64,
    available_bytes: u64,
    resource:        [64]u8,
}

Vk_Queue_Family_Indices :: struct {
    graphics: i32,
    compute:  i32,
    present:  i32,
}

Vk_Device_Caps :: struct {
    adapter_name:               [128]u8,
    adapter_type:               [32]u8,
    queue_families:             Vk_Queue_Family_Indices,
    memory:                     Gpu_Memory_Budget,
    supports_memory_budget_ext: bool,
    supports_synchronization2:  bool,
    supports_dynamic_rendering: bool,
    supports_device_fault:      bool,
    api_version:                u32,
    supports_timestamp_queries: bool,
    timestamp_period:           f32,
    framebuffer_sample_counts: vk.SampleCountFlags,
    supports_min_depth_resolve: bool,
    swapchain_format:           vk.Format,
    present_mode:               vk.PresentModeKHR,
    swapchain_extent:           vk.Extent2D,
}

Vk_Frame_State :: struct {
    command_pool:    vk.CommandPool,
    command_buffer:  vk.CommandBuffer,
    image_available: vk.Semaphore,
    render_finished: vk.Semaphore,
    in_flight:       vk.Fence,
}

Vk_Frame :: struct {
    state:          ^Vk_Frame_State,
    command_buffer: vk.CommandBuffer,
    image_index:    u32,
    frame_index:    u32,
}

Vk_Frame_Cpu_Timings :: struct {
    wait_fence_ms:    f64,
    acquire_ms:       f64,
    command_begin_ms: f64,
    end_command_ms:   f64,
    queue_submit_ms:  f64,
    queue_present_ms: f64,
}

Vk_Command_Shape_Counters :: struct {
    rendering_scope_count:    u32,
    compute_dispatch_count:   u32,
    draw_count:               u32,
    pipeline_bind_count:      u32,
    descriptor_bind_count:    u32,
    pipeline_barrier_count:   u32,
    transfer_copy_count:      u32,
    ui_batch_count:           u32,
    backdrop_blur_pass_count: u32,
}

Vk_Buffer :: struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    size:   vk.DeviceSize,
    mapped: rawptr,
}

Vk_Shader_Module :: struct {
    handle: vk.ShaderModule,
}

Vk_Graphics_Pipeline :: struct {
    layout:   vk.PipelineLayout,
    pipeline: vk.Pipeline,
}

Vk_Compute_Pipeline :: struct {
    layout:   vk.PipelineLayout,
    pipeline: vk.Pipeline,
}

Vk_Context :: struct {
    instance:                        vk.Instance,
    surface:                         vk.SurfaceKHR,
    physical_device:                 vk.PhysicalDevice,
    device:                          vk.Device,
    swapchain:                       vk.SwapchainKHR,
    swapchain_images:                [MAX_SWAPCHAIN_IMAGES]vk.Image,
    swapchain_image_views:           [MAX_SWAPCHAIN_IMAGES]vk.ImageView,
    swapchain_render_finished:       [MAX_SWAPCHAIN_IMAGES]vk.Semaphore,
    swapchain_image_initialized:     [MAX_SWAPCHAIN_IMAGES]bool,
    swapchain_image_count:           u32,
    swapchain_format:                vk.Format,
    swapchain_extent:                vk.Extent2D,
    frames:                          [MAX_FRAMES_IN_FLIGHT]Vk_Frame_State,
    upload_command_pool:             vk.CommandPool,
    upload_command_buffer:           vk.CommandBuffer,
    current_frame:                   u32,
    frame_resources_ready:           bool,
    needs_swapchain_recreate:        bool,
    device_lost:                     bool,
    device_loss_stage:               [32]u8,
    device_loss_detail:              [256]u8,
    last_resource_error:             Resource_Error,
    graphics_queue:                  vk.Queue,
    compute_queue:                   vk.Queue,
    present_queue:                   vk.Queue,
    caps:                            Vk_Device_Caps,
    gpu_profiler:                    Gpu_Profiler,
    last_cpu_timings:                Vk_Frame_Cpu_Timings,
    command_shape:                   Vk_Command_Shape_Counters,
    last_command_shape:              Vk_Command_Shape_Counters,
    swapchain_supports_transfer_src: bool,
    initialized:                     bool,
    capture_enabled:                 bool,
    vsync_enabled:                   bool,
    supports_debug_utils:            bool,
}

vk_record_device_loss :: proc(ctx: ^Vk_Context, stage: string) {
    if ctx == nil do return
    ctx.device_lost = true
    write_fixed_string(ctx.device_loss_stage[:], stage)
    write_fixed_string(ctx.device_loss_detail[:], "The Vulkan driver did not provide a more specific cause")
    if !ctx.caps.supports_device_fault || vk.GetDeviceFaultInfoEXT == nil do return
    counts := vk.DeviceFaultCountsEXT {
        sType = .DEVICE_FAULT_COUNTS_EXT,
    }
    if vk.GetDeviceFaultInfoEXT(ctx.device, &counts, nil) != .SUCCESS do return
    address_infos: [8]vk.DeviceFaultAddressInfoEXT
    vendor_infos: [8]vk.DeviceFaultVendorInfoEXT
    counts.addressInfoCount = min(counts.addressInfoCount, u32(len(address_infos)))
    counts.vendorInfoCount = min(counts.vendorInfoCount, u32(len(vendor_infos)))
    counts.vendorBinarySize = 0
    info := vk.DeviceFaultInfoEXT {
        sType         = .DEVICE_FAULT_INFO_EXT,
        pAddressInfos = raw_data(address_infos[:]),
        pVendorInfos  = raw_data(vendor_infos[:]),
    }
    if vk.GetDeviceFaultInfoEXT(ctx.device, &counts, &info) == .SUCCESS {
        description := fixed_string(info.description[:])
        if len(description) > 0 do write_fixed_string(ctx.device_loss_detail[:], description)
    }
}

vk_set_vsync_enabled :: proc(ctx: ^Vk_Context, enabled: bool) {
    if ctx == nil || ctx.vsync_enabled == enabled do return
    ctx.vsync_enabled = enabled
    if ctx.initialized do ctx.needs_swapchain_recreate = true
}

vk_context_init :: proc(
    ctx: ^Vk_Context,
    window: ^sdl.Window,
    width, height: i32,
    configured_ceiling_fraction: f32,
    capture_enabled := false,
    vsync_enabled := true,
) -> bool {
    ctx^ = {}
    ctx.capture_enabled = capture_enabled
    ctx.vsync_enabled = vsync_enabled
    log_info(
        "requested_size=",
        width,
        "x",
        height,
        " capture_enabled=",
        capture_enabled,
        " vsync_enabled=",
        vsync_enabled,
    )

    if !sdl.Vulkan_LoadLibrary(nil) {
        log_error("Vulkan library load failed")
        ctx.caps = vk_make_placeholder_caps(configured_ceiling_fraction)
        write_fixed_string(ctx.caps.adapter_name[:], "SDL could not load Vulkan library")
        return false
    }

    vk.load_proc_addresses(cast(rawptr)sdl.Vulkan_GetVkGetInstanceProcAddr())
    if vk.CreateInstance == nil {
        log_error("instance creation unavailable after loading procedure addresses")
        ctx.caps = vk_make_placeholder_caps(configured_ceiling_fraction)
        write_fixed_string(ctx.caps.adapter_name[:], "vkCreateInstance unavailable")
        return false
    }
    loader_version := u32(0)
    if vk.EnumerateInstanceVersion == nil ||
       vk.EnumerateInstanceVersion(&loader_version) != .SUCCESS ||
       loader_version < vk_make_version(1, 3, 0) {
        ctx.caps = vk_make_placeholder_caps(configured_ceiling_fraction)
        write_fixed_string(ctx.caps.adapter_name[:], "Vulkan 1.3 loader is required")
        log_error("Vulkan 1.3 loader is required; reported version=", loader_version)
        return false
    }

    if !vk_create_instance(ctx) {
        log_error("instance creation failed")
        return false
    }
    vk.load_proc_addresses(ctx.instance)

    if !sdl.Vulkan_CreateSurface(window, ctx.instance, nil, &ctx.surface) {
        log_error("surface creation failed: ", sdl.GetError())
        return false
    }

    if !vk_pick_physical_device(ctx, configured_ceiling_fraction) {
        log_error("physical device selection failed")
        return false
    }
    log_info(
        "selected device=",
        fixed_string(ctx.caps.adapter_name[:]),
        " type=",
        fixed_string(ctx.caps.adapter_type[:]),
    )
    spy.debug(
        "queues graphics=",
        ctx.caps.queue_families.graphics,
        " compute=",
        ctx.caps.queue_families.compute,
        " present=",
        ctx.caps.queue_families.present,
    )
    if !vk_create_logical_device(ctx) {
        log_error("logical device creation failed")
        return false
    }
    vk.load_proc_addresses(ctx.device)
    ctx.supports_debug_utils =
        vk.SetDebugUtilsObjectNameEXT != nil ||
        vk.CmdBeginDebugUtilsLabelEXT != nil ||
        vk.CmdEndDebugUtilsLabelEXT != nil
    vk_set_debug_name(ctx, .INSTANCE, u64(uintptr(ctx.instance)), "Vulkan instance")
    vk_set_debug_name(ctx, .SURFACE_KHR, auto_cast ctx.surface, "Vulkan surface")
    vk_set_debug_name(ctx, .PHYSICAL_DEVICE, u64(uintptr(ctx.physical_device)), "Vulkan physical device")
    vk_set_debug_name(ctx, .DEVICE, u64(uintptr(ctx.device)), "Vulkan device")
    vk_set_debug_name(ctx, .QUEUE, u64(uintptr(ctx.graphics_queue)), "Vulkan graphics queue")
    vk_set_debug_name(ctx, .QUEUE, u64(uintptr(ctx.compute_queue)), "Vulkan compute queue")
    vk_set_debug_name(ctx, .QUEUE, u64(uintptr(ctx.present_queue)), "Vulkan present queue")

    if !vk_create_swapchain(ctx, width, height) {
        log_error("swapchain creation failed")
        return false
    }
    if !vk_create_frame_resources(ctx) {
        log_error("frame resource creation failed")
        return false
    }
    if !gpu_profiler_init(ctx) {
        log_error("GPU profiler initialization failed")
        return false
    }

    ctx.initialized = true
    spy.debug("ready")
    return true
}

vk_context_destroy :: proc(ctx: ^Vk_Context) {
    total_start := time.tick_now()
    log_info("shutdown: vk context begin")
    if ctx.device != nil {
        step_start := time.tick_now()
        // A lost device cannot make outstanding fences progress. Waiting for them
        // (or for the whole device) turns recoverable adapter loss into an app
        // freeze, so proceed directly to destruction in that state.
        frame_fences_idle := ctx.device_lost || vk_wait_for_frame_fences(ctx)
        when ODIN_OS == .Darwin {
            if ctx.device_lost {
                log_info("shutdown: vk waits skipped for lost device")
            } else if frame_fences_idle {
                log_info(
                    "shutdown: vk DeviceWaitIdle skipped on Darwin after frame fence wait ms=",
                    vk_elapsed_ms(step_start),
                )
            } else {
                _ = vk.DeviceWaitIdle(ctx.device)
                log_info("shutdown: vk DeviceWaitIdle fallback ms=", vk_elapsed_ms(step_start))
            }
        } else {
            if !ctx.device_lost {
                _ = vk.DeviceWaitIdle(ctx.device)
                log_info("shutdown: vk DeviceWaitIdle ms=", vk_elapsed_ms(step_start))
            } else {
                log_info("shutdown: vk waits skipped for lost device")
            }
        }
        step_start = time.tick_now()
        gpu_profiler_destroy(ctx)
        log_info("shutdown: gpu profiler destroy ms=", vk_elapsed_ms(step_start))
        step_start = time.tick_now()
        vk_destroy_frame_resources(ctx)
        log_info("shutdown: vk frame resources destroy ms=", vk_elapsed_ms(step_start))
        step_start = time.tick_now()
        vk_destroy_swapchain_resources(ctx)
        log_info("shutdown: vk swapchain resources destroy ms=", vk_elapsed_ms(step_start))
        step_start = time.tick_now()
        vk.DestroyDevice(ctx.device, nil)
        log_info("shutdown: vk DestroyDevice ms=", vk_elapsed_ms(step_start))
    }
    if ctx.surface != vk.SurfaceKHR(0) && ctx.instance != nil {
        step_start := time.tick_now()
        vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
        log_info("shutdown: vk DestroySurfaceKHR ms=", vk_elapsed_ms(step_start))
    }
    if ctx.instance != nil {
        step_start := time.tick_now()
        vk.DestroyInstance(ctx.instance, nil)
        log_info("shutdown: vk DestroyInstance ms=", vk_elapsed_ms(step_start))
    }
    step_start := time.tick_now()
    sdl.Vulkan_UnloadLibrary()
    log_info("shutdown: SDL Vulkan_UnloadLibrary ms=", vk_elapsed_ms(step_start))
    ctx^ = {}
    log_info("shutdown: vk context total ms=", vk_elapsed_ms(total_start))
}

vk_wait_for_frame_fences :: proc(ctx: ^Vk_Context) -> bool {
    if ctx.device == nil || !ctx.frame_resources_ready {
        return true
    }
    all_idle := true
    for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
        frame := &ctx.frames[i]
        if frame.in_flight == vk.Fence(0) {
            continue
        }
        step_start := time.tick_now()
        status := vk.GetFenceStatus(ctx.device, frame.in_flight)
        if status == .NOT_READY {
            status = vk.WaitForFences(ctx.device, 1, &frame.in_flight, true, VK_SHUTDOWN_FRAME_FENCE_TIMEOUT_NS)
        }
        elapsed_ms := vk_elapsed_ms(step_start)
        if status == .SUCCESS {
            log_info("shutdown: vk frame fence idle index=", i, " ms=", elapsed_ms)
        } else {
            all_idle = false
            log_warn("shutdown: vk frame fence wait incomplete index=", i, " result=", status, " ms=", elapsed_ms)
        }
    }
    return all_idle
}

vk_make_placeholder_caps :: proc(configured_ceiling_fraction: f32) -> Vk_Device_Caps {
    caps: Vk_Device_Caps
    write_fixed_string(caps.adapter_name[:], "Vulkan device selection pending")
    write_fixed_string(caps.adapter_type[:], "Unknown")
    caps.queue_families = {-1, -1, -1}
    caps.memory = gpu_memory_budget_from_heaps(
        sizes = []u64{8 * 1024 * 1024 * 1024},
        usages = []u64{0},
        budgets = []u64{6 * 1024 * 1024 * 1024},
        has_budget = true,
        override_fraction = configured_ceiling_fraction,
    )
    caps.supports_memory_budget_ext = true
    return caps
}

vk_create_instance :: proc(ctx: ^Vk_Context) -> bool {
    sdl_ext_count: sdl.Uint32
    sdl_exts := sdl.Vulkan_GetInstanceExtensions(&sdl_ext_count)
    if sdl_exts == nil || sdl_ext_count == 0 {
        ctx.caps = vk_make_placeholder_caps(0)
        write_fixed_string(ctx.caps.adapter_name[:], "SDL returned no Vulkan instance extensions")
        return false
    }

    extensions: [MAX_VK_EXTENSIONS]cstring
    extension_count: u32
    for i in 0 ..< int(sdl_ext_count) {
        if extension_count < MAX_VK_EXTENSIONS {
            extensions[extension_count] = sdl_exts[i]
            extension_count += 1
        }
    }
    if vk_instance_extension_available(vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) &&
       extension_count < MAX_VK_EXTENSIONS {
        extensions[extension_count] = vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
        extension_count += 1
    }
    if vk_instance_extension_available(vk.EXT_DEBUG_UTILS_EXTENSION_NAME) && extension_count < MAX_VK_EXTENSIONS {
        extensions[extension_count] = vk.EXT_DEBUG_UTILS_EXTENSION_NAME
        extension_count += 1
    }

    app_info := vk.ApplicationInfo {
        sType              = .APPLICATION_INFO,
        pApplicationName   = "zelda-engine application",
        applicationVersion = vk_make_version(ENGINE_VERSION_MAJOR, ENGINE_VERSION_MINOR, ENGINE_VERSION_PATCH),
        pEngineName        = "zelda-engine",
        engineVersion      = vk_make_version(ENGINE_VERSION_MAJOR, ENGINE_VERSION_MINOR, ENGINE_VERSION_PATCH),
        apiVersion         = vk_make_version(1, 3, 0),
    }
    create_info := vk.InstanceCreateInfo {
        sType                   = .INSTANCE_CREATE_INFO,
        flags                   = {.ENUMERATE_PORTABILITY_KHR},
        pApplicationInfo        = &app_info,
        enabledExtensionCount   = extension_count,
        ppEnabledExtensionNames = raw_data(extensions[:]),
    }

    return vk.CreateInstance(&create_info, nil, &ctx.instance) == .SUCCESS
}

vk_instance_extension_available :: proc(name: string) -> bool {
    count: u32
    if vk.EnumerateInstanceExtensionProperties(nil, &count, nil) != .SUCCESS || count == 0 {
        return false
    }

    props, alloc_err := make([]vk.ExtensionProperties, int(count), context.temp_allocator)
    if alloc_err != nil {
        return false
    }
    if vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(props)) != .SUCCESS {
        return false
    }
    for i in 0 ..< len(props) {
        if fixed_string(props[i].extensionName[:]) == name {
            return true
        }
    }
    return false
}

vk_pick_physical_device :: proc(ctx: ^Vk_Context, configured_ceiling_fraction: f32) -> bool {
    count: u32
    if vk.EnumeratePhysicalDevices(ctx.instance, &count, nil) != .SUCCESS || count == 0 {
        ctx.caps = vk_make_placeholder_caps(configured_ceiling_fraction)
        write_fixed_string(ctx.caps.adapter_name[:], "No Vulkan physical devices found")
        return false
    }

    devices, alloc_err := make([]vk.PhysicalDevice, int(count), context.temp_allocator)
    if alloc_err != nil {
        return false
    }
    if vk.EnumeratePhysicalDevices(ctx.instance, &count, raw_data(devices)) != .SUCCESS {
        return false
    }

    for device in devices {
        props: vk.PhysicalDeviceProperties
        vk.GetPhysicalDeviceProperties(device, &props)
        if props.apiVersion < vk_make_version(1, 3, 0) {
            continue
        }
        if !vk_device_supports_required_13_features(device) {
            continue
        }
        indices := vk_find_queue_families(device, ctx.surface)
        if indices.graphics >= 0 &&
           indices.compute >= 0 &&
           indices.present >= 0 &&
           vk_device_extension_available(device, vk.KHR_SWAPCHAIN_EXTENSION_NAME) {
            ctx.physical_device = device
            ctx.caps.queue_families = indices
            vk_fill_device_caps(ctx, configured_ceiling_fraction)
            return true
        }
    }

    ctx.caps = vk_make_placeholder_caps(configured_ceiling_fraction)
    write_fixed_string(
        ctx.caps.adapter_name[:],
        "Vulkan 1.3 with graphics, compute, present, and swapchain is required",
    )
    return false
}

vk_device_supports_required_13_features :: proc(device: vk.PhysicalDevice) -> bool {
    features11 := vk.PhysicalDeviceVulkan11Features {
        sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
    }
    features13 := vk.PhysicalDeviceVulkan13Features {
        sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
    }
    features11.pNext = &features13
    features2 := vk.PhysicalDeviceFeatures2 {
        sType = .PHYSICAL_DEVICE_FEATURES_2,
        pNext = &features11,
    }
    vk.GetPhysicalDeviceFeatures2(device, &features2)
    return(
        features11.shaderDrawParameters == true &&
        features13.dynamicRendering == true &&
        features13.synchronization2 == true \
    )
}

vk_find_queue_families :: proc(device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> Vk_Queue_Family_Indices {
    indices := Vk_Queue_Family_Indices{-1, -1, -1}
    count: u32
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
    if count == 0 {
        return indices
    }

    props, alloc_err := make([]vk.QueueFamilyProperties, int(count), context.temp_allocator)
    if alloc_err != nil {
        return indices
    }
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(props))

    found_graphics_present := false
    for i in 0 ..< int(count) {
        queue := props[i]
        if indices.graphics < 0 && .GRAPHICS in queue.queueFlags {
            indices.graphics = i32(i)
        }
        if indices.compute < 0 && .COMPUTE in queue.queueFlags {
            indices.compute = i32(i)
        }
        supported: b32
        if vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), surface, &supported) == .SUCCESS && supported {
            if indices.present < 0 {
                indices.present = i32(i)
            }
            if !found_graphics_present && .GRAPHICS in queue.queueFlags {
                indices.graphics = i32(i)
                indices.present = i32(i)
                found_graphics_present = true
            }
        }
    }
    return indices
}

vk_device_extension_available :: proc(device: vk.PhysicalDevice, name: string) -> bool {
    count: u32
    if vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) != .SUCCESS || count == 0 {
        return false
    }
    props, alloc_err := make([]vk.ExtensionProperties, int(count), context.temp_allocator)
    if alloc_err != nil {
        return false
    }
    if vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(props)) != .SUCCESS {
        return false
    }
    for i in 0 ..< len(props) {
        if fixed_string(props[i].extensionName[:]) == name {
            return true
        }
    }
    return false
}

vk_create_logical_device :: proc(ctx: ^Vk_Context) -> bool {
    priority := f32(1)
    unique: [3]u32
    unique_count: u32
    vk_push_unique_queue(&unique, &unique_count, u32(ctx.caps.queue_families.graphics))
    vk_push_unique_queue(&unique, &unique_count, u32(ctx.caps.queue_families.compute))
    vk_push_unique_queue(&unique, &unique_count, u32(ctx.caps.queue_families.present))

    queue_infos: [3]vk.DeviceQueueCreateInfo
    for i in 0 ..< unique_count {
        queue_infos[i] = vk.DeviceQueueCreateInfo {
            sType            = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = unique[i],
            queueCount       = 1,
            pQueuePriorities = &priority,
        }
    }

    extensions: [3]cstring
    extension_count: u32
    extensions[extension_count] = vk.KHR_SWAPCHAIN_EXTENSION_NAME
    extension_count += 1
    if vk_device_extension_available(ctx.physical_device, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME) {
        extensions[extension_count] = vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME
        extension_count += 1
    }
    supports_device_fault := vk_device_extension_available(ctx.physical_device, vk.EXT_DEVICE_FAULT_EXTENSION_NAME)
    if supports_device_fault {
        extensions[extension_count] = vk.EXT_DEVICE_FAULT_EXTENSION_NAME
        extension_count += 1
    }
    queried_features11 := vk.PhysicalDeviceVulkan11Features {
        sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
    }
    queried_features13 := vk.PhysicalDeviceVulkan13Features {
        sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
    }
    queried_fault := vk.PhysicalDeviceFaultFeaturesEXT {
        sType = .PHYSICAL_DEVICE_FAULT_FEATURES_EXT,
        pNext = &queried_features13,
    }
    queried_features11.pNext = &queried_fault
    features2 := vk.PhysicalDeviceFeatures2 {
        sType = .PHYSICAL_DEVICE_FEATURES_2,
        pNext = &queried_features11,
    }
    vk.GetPhysicalDeviceFeatures2(ctx.physical_device, &features2)
    if !queried_features11.shaderDrawParameters ||
       !queried_features13.dynamicRendering ||
       !queried_features13.synchronization2 {
        write_fixed_string(
            ctx.caps.adapter_name[:],
            "Vulkan shaderDrawParameters, dynamicRendering, and synchronization2 are required",
        )
        return false
    }
    enabled_features11 := vk.PhysicalDeviceVulkan11Features {
        sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
        shaderDrawParameters = true,
    }
    enabled_features13 := vk.PhysicalDeviceVulkan13Features {
        sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        dynamicRendering = true,
        synchronization2 = true,
    }
    enabled_fault := vk.PhysicalDeviceFaultFeaturesEXT {
        sType       = .PHYSICAL_DEVICE_FAULT_FEATURES_EXT,
        pNext       = &enabled_features13,
        deviceFault = b32(supports_device_fault && queried_fault.deviceFault == true),
    }
    enabled_features11.pNext = &enabled_fault
    create_info := vk.DeviceCreateInfo {
        sType                   = .DEVICE_CREATE_INFO,
        pNext                   = &enabled_features11,
        queueCreateInfoCount    = unique_count,
        pQueueCreateInfos       = raw_data(queue_infos[:]),
        enabledExtensionCount   = extension_count,
        ppEnabledExtensionNames = raw_data(extensions[:]),
    }
    if vk.CreateDevice(ctx.physical_device, &create_info, nil, &ctx.device) != .SUCCESS {
        return false
    }

    vk.GetDeviceQueue(ctx.device, u32(ctx.caps.queue_families.graphics), 0, &ctx.graphics_queue)
    vk.GetDeviceQueue(ctx.device, u32(ctx.caps.queue_families.compute), 0, &ctx.compute_queue)
    vk.GetDeviceQueue(ctx.device, u32(ctx.caps.queue_families.present), 0, &ctx.present_queue)
    ctx.caps.supports_dynamic_rendering = true
    ctx.caps.supports_synchronization2 = true
    ctx.caps.supports_device_fault = enabled_fault.deviceFault == true
    return true
}

vk_set_debug_name :: proc(ctx: ^Vk_Context, object_type: vk.ObjectType, object_handle: u64, name: string) {
    if ctx == nil || ctx.device == nil || !ctx.supports_debug_utils || vk.SetDebugUtilsObjectNameEXT == nil {
        return
    }
    if object_handle == 0 || len(name) == 0 do return
    name_cstr := strings.clone_to_cstring(name, context.temp_allocator)
    info := vk.DebugUtilsObjectNameInfoEXT {
        sType        = .DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
        objectType   = object_type,
        objectHandle = object_handle,
        pObjectName  = name_cstr,
    }
    _ = vk.SetDebugUtilsObjectNameEXT(ctx.device, &info)
}
