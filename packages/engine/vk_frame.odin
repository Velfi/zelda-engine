package engine

import "core:time"
import vk "vendor:vulkan"

vk_begin_frame :: proc(ctx: ^Vk_Context) -> (Vk_Frame, bool) {
	frame: Vk_Frame
	if !ctx.initialized || !ctx.frame_resources_ready || ctx.needs_swapchain_recreate {
		if ctx.debug_acquire_log_count < VK_DEBUG_FRAME_LOG_LIMIT {
			log_debug("vk_begin_frame: skipped initialized=", ctx.initialized, " frame_resources_ready=", ctx.frame_resources_ready, " needs_swapchain_recreate=", ctx.needs_swapchain_recreate)
			ctx.debug_acquire_log_count += 1
		}
		return frame, false
	}

	frame_index := ctx.current_frame % MAX_FRAMES_IN_FLIGHT
	state := &ctx.frames[frame_index]
	ctx.last_cpu_timings = {}
	ctx.command_shape = {}
	wait_start := time.tick_now()
	_ = vk.WaitForFences(ctx.device, 1, &state.in_flight, true, 0xffffffffffffffff)
	ctx.last_cpu_timings.wait_fence_ms = vk_elapsed_ms(wait_start)
	gpu_profiler_collect_frame(ctx, frame_index)

	image_index: u32
	acquire_start := time.tick_now()
	acquire_result := vk.AcquireNextImageKHR(ctx.device, ctx.swapchain, 0xffffffffffffffff, state.image_available, vk.Fence(0), &image_index)
	ctx.last_cpu_timings.acquire_ms = vk_elapsed_ms(acquire_start)
	if ctx.debug_acquire_log_count < VK_DEBUG_FRAME_LOG_LIMIT {
		log_debug("vk_begin_frame: frame_slot=", frame_index, " acquire_result=", acquire_result, " image_index=", image_index, " wait_ms=", ctx.last_cpu_timings.wait_fence_ms, " acquire_ms=", ctx.last_cpu_timings.acquire_ms)
		ctx.debug_acquire_log_count += 1
	}
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		log_warn("vk_begin_frame: acquire out of date")
		ctx.needs_swapchain_recreate = true
		return frame, false
	}
	if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		log_error("vk_begin_frame: acquire failed result=", acquire_result)
		if acquire_result == .ERROR_DEVICE_LOST do vk_record_device_loss(ctx, "acquiring the next swapchain image")
		return frame, false
	}
	if acquire_result == .SUBOPTIMAL_KHR {
		log_warn("vk_begin_frame: acquire suboptimal")
		ctx.needs_swapchain_recreate = true
	}

	command_begin_start := time.tick_now()
	_ = vk.ResetCommandPool(ctx.device, state.command_pool, {})

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(state.command_buffer, &begin_info) != .SUCCESS {
		log_error("vk_begin_frame: BeginCommandBuffer failed")
		return frame, false
	}
	ctx.last_cpu_timings.command_begin_ms = vk_elapsed_ms(command_begin_start)

	frame = {
		state = state,
		command_buffer = state.command_buffer,
		image_index = image_index,
		frame_index = frame_index,
	}
	gpu_profiler_begin_frame(ctx, frame)
	return frame, true
}

vk_end_frame :: proc(ctx: ^Vk_Context, frame: Vk_Frame) -> bool {
	gpu_profiler_end_frame(ctx, frame)
	end_command_start := time.tick_now()
	end_result := vk.EndCommandBuffer(frame.command_buffer)
	if end_result != .SUCCESS {
		log_error("vk_end_frame: EndCommandBuffer failed result=", end_result, " image_index=", frame.image_index, " frame_slot=", frame.frame_index)
		return false
	}
	ctx.last_cpu_timings.end_command_ms = vk_elapsed_ms(end_command_start)

	wait := vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = frame.state.image_available, stageMask = {.COLOR_ATTACHMENT_OUTPUT}}
	command := vk.CommandBufferSubmitInfo{sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = frame.command_buffer, deviceMask = 1}
	signal := vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = frame.state.render_finished, stageMask = {.ALL_COMMANDS}}
	submit := vk.SubmitInfo2 {
		sType = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount = 1,
		pWaitSemaphoreInfos = &wait,
		commandBufferInfoCount = 1,
		pCommandBufferInfos = &command,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos = &signal,
	}
	submit_start := time.tick_now()
	// Reset only once the frame is guaranteed to be submitted; resetting in
	// vk_begin_frame left the fence unsignaled forever when recording failed,
	// deadlocking the next frame's WaitForFences.
	_ = vk.ResetFences(ctx.device, 1, &frame.state.in_flight)
	submit_result := vk.QueueSubmit2(ctx.graphics_queue, 1, &submit, frame.state.in_flight)
	ctx.last_cpu_timings.queue_submit_ms = vk_elapsed_ms(submit_start)
	if ctx.debug_present_log_count < VK_DEBUG_FRAME_LOG_LIMIT {
		log_debug("vk_end_frame: frame_slot=", frame.frame_index, " image_index=", frame.image_index, " submit_result=", submit_result, " end_cmd_ms=", ctx.last_cpu_timings.end_command_ms, " submit_ms=", ctx.last_cpu_timings.queue_submit_ms)
	}
	if submit_result != .SUCCESS {
		log_error("vk_end_frame: QueueSubmit failed result=", submit_result)
		if submit_result == .ERROR_DEVICE_LOST do vk_record_device_loss(ctx, "submitting GPU work")
		return false
	}

	image_index := frame.image_index
	present := vk.PresentInfoKHR {
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &frame.state.render_finished,
		swapchainCount = 1,
		pSwapchains = &ctx.swapchain,
		pImageIndices = &image_index,
	}
	present_start := time.tick_now()
	present_result := vk.QueuePresentKHR(ctx.present_queue, &present)
	ctx.last_cpu_timings.queue_present_ms = vk_elapsed_ms(present_start)
	ctx.last_command_shape = ctx.command_shape
	queue_idle_result := vk.Result.SUCCESS
	if ctx.debug_present_log_count < VK_DEBUG_FRAME_LOG_LIMIT {
		log_debug("vk_end_frame: frame_slot=", frame.frame_index, " image_index=", frame.image_index, " present_result=", present_result, " queue_idle_result=", queue_idle_result, " present_ms=", ctx.last_cpu_timings.queue_present_ms)
		ctx.debug_present_log_count += 1
	}
	if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR {
		log_warn("vk_end_frame: present requires swapchain recreate result=", present_result)
		ctx.needs_swapchain_recreate = true
	} else if present_result != .SUCCESS {
		log_error("vk_end_frame: QueuePresent failed result=", present_result)
		if present_result == .ERROR_DEVICE_LOST do vk_record_device_loss(ctx, "presenting the rendered frame")
		return false
	}
	ctx.current_frame = (ctx.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	return true
}

// One-off uploads must use this dedicated command buffer: recycling a frame's
// command pool mid-recording silently invalidates the in-flight frame command
// buffer (MoltenVK reports it as NOT_READY from vkEndCommandBuffer).
vk_begin_upload_commands :: proc(ctx: ^Vk_Context) -> (vk.CommandBuffer, bool) {
	if ctx.upload_command_buffer == nil {
		return nil, false
	}
	_ = vk.ResetCommandPool(ctx.device, ctx.upload_command_pool, {})
	begin := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(ctx.upload_command_buffer, &begin) != .SUCCESS {
		return nil, false
	}
	return ctx.upload_command_buffer, true
}

vk_submit_upload_commands :: proc(ctx: ^Vk_Context) -> bool {
	if vk.EndCommandBuffer(ctx.upload_command_buffer) != .SUCCESS {
		return false
	}
	command := vk.CommandBufferSubmitInfo{sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = ctx.upload_command_buffer, deviceMask = 1}
	submit := vk.SubmitInfo2{sType = .SUBMIT_INFO_2, commandBufferInfoCount = 1, pCommandBufferInfos = &command}
	if vk.QueueSubmit2(ctx.graphics_queue, 1, &submit, vk.Fence(0)) != .SUCCESS {
		return false
	}
	_ = vk.QueueWaitIdle(ctx.graphics_queue)
	return true
}

vk_elapsed_ms :: proc(start: time.Tick) -> f64 {
	return time.duration_seconds(time.tick_diff(start, time.tick_now())) * 1000.0
}

vk_cmd_begin_swapchain_render_pass :: proc(ctx: ^Vk_Context, frame: Vk_Frame, clear_color: $Color) {
	clear := vk.ClearValue{color = {float32 = {clear_color.r, clear_color.g, clear_color.b, clear_color.a}}}
	vk_cmd_begin_rendering(ctx, frame.command_buffer, ctx.swapchain_image_views[frame.image_index], ctx.swapchain_extent, .COLOR_ATTACHMENT_OPTIMAL, .CLEAR, .STORE, clear)
}

vk_cmd_begin_swapchain_render_pass_load :: proc(ctx: ^Vk_Context, frame: Vk_Frame) {
	vk_cmd_begin_rendering(ctx, frame.command_buffer, ctx.swapchain_image_views[frame.image_index], ctx.swapchain_extent, .COLOR_ATTACHMENT_OPTIMAL, .LOAD, .STORE, {})
}

vk_cmd_end_swapchain_render_pass :: proc(frame: Vk_Frame) {
	vk_cmd_end_rendering(frame.command_buffer)
}

vk_recreate_swapchain :: proc(ctx: ^Vk_Context, width, height: i32) -> bool {
	if ctx.device == nil {
		return false
	}
	_ = vk.DeviceWaitIdle(ctx.device)
	vk_destroy_swapchain_resources(ctx)
	if !vk_create_swapchain(ctx, width, height) {
		ctx.needs_swapchain_recreate = true
		return false
	}
	ctx.needs_swapchain_recreate = false
	return true
}

vk_push_unique_queue :: proc(values: ^[3]u32, count: ^u32, value: u32) {
	for i in 0 ..< count^ {
		if values[i] == value {
			return
		}
	}
	values[count^] = value
	count^ += 1
}

vk_fill_device_caps :: proc(ctx: ^Vk_Context, configured_ceiling_fraction: f32) {
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(ctx.physical_device, &props)
	ctx.caps.api_version = props.apiVersion
	write_fixed_string(ctx.caps.adapter_name[:], fixed_string(props.deviceName[:]))
	write_fixed_string(ctx.caps.adapter_type[:], vk_device_type_name(props.deviceType))
	ctx.caps.supports_timestamp_queries = props.limits.timestampComputeAndGraphics == true && props.limits.timestampPeriod > 0
	ctx.caps.timestamp_period = props.limits.timestampPeriod
	ctx.caps.supports_memory_budget_ext = vk_device_extension_available(ctx.physical_device, vk.EXT_MEMORY_BUDGET_EXTENSION_NAME)
	ctx.caps.memory = vk_query_memory_budget(ctx.physical_device, ctx.caps.supports_memory_budget_ext, configured_ceiling_fraction)
}

vk_device_type_name :: proc(t: vk.PhysicalDeviceType) -> string {
	#partial switch t {
	case .DISCRETE_GPU:
		return "Discrete GPU"
	case .INTEGRATED_GPU:
		return "Integrated GPU"
	case .VIRTUAL_GPU:
		return "Virtual GPU"
	case .CPU:
		return "CPU"
	}
	return "Other"
}

vk_query_memory_budget :: proc(device: vk.PhysicalDevice, has_budget: bool, configured_ceiling_fraction: f32) -> Gpu_Memory_Budget {
	mem_props: vk.PhysicalDeviceMemoryProperties
	budget_props: vk.PhysicalDeviceMemoryBudgetPropertiesEXT

	if has_budget && vk.GetPhysicalDeviceMemoryProperties2 != nil {
		budget_props.sType = .PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT
		props2 := vk.PhysicalDeviceMemoryProperties2 {
			sType = .PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
			pNext = &budget_props,
		}
		vk.GetPhysicalDeviceMemoryProperties2(device, &props2)
		mem_props = props2.memoryProperties
	} else {
		vk.GetPhysicalDeviceMemoryProperties(device, &mem_props)
	}

	sizes: [MAX_GPU_HEAPS]u64
	usages: [MAX_GPU_HEAPS]u64
	budgets: [MAX_GPU_HEAPS]u64
	heap_count := min(int(mem_props.memoryHeapCount), MAX_GPU_HEAPS)
	for i in 0 ..< heap_count {
		sizes[i] = u64(mem_props.memoryHeaps[i].size)
		if has_budget {
			usages[i] = u64(budget_props.heapUsage[i])
			budgets[i] = u64(budget_props.heapBudget[i])
		}
	}
	return gpu_memory_budget_from_heaps(sizes[:heap_count], usages[:heap_count], budgets[:heap_count], has_budget, configured_ceiling_fraction)
}
