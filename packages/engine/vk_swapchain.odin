package engine

import vk "vendor:vulkan"

vk_create_swapchain :: proc(ctx: ^Vk_Context, width, height: i32) -> bool {
	caps: vk.SurfaceCapabilitiesKHR
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface, &caps) != .SUCCESS {
		return false
	}

	format := vk_choose_surface_format(ctx.physical_device, ctx.surface)
	present_mode := vk_choose_present_mode(ctx.physical_device, ctx.surface, ctx.capture_enabled)
	extent := vk_choose_extent(caps, width, height)
	usage := vk_swapchain_image_usage(ctx, caps)

	image_count := caps.minImageCount + 1
	if caps.maxImageCount > 0 && image_count > caps.maxImageCount {
		image_count = caps.maxImageCount
	}
	if image_count > MAX_SWAPCHAIN_IMAGES {
		image_count = MAX_SWAPCHAIN_IMAGES
	}
	log_debug("vk_create_swapchain: surface current_extent=", caps.currentExtent.width, "x", caps.currentExtent.height, " min_extent=", caps.minImageExtent.width, "x", caps.minImageExtent.height, " max_extent=", caps.maxImageExtent.width, "x", caps.maxImageExtent.height)
	log_debug("vk_create_swapchain: requested=", width, "x", height, " chosen_extent=", extent.width, "x", extent.height, " min_images=", caps.minImageCount, " max_images=", caps.maxImageCount, " requested_images=", image_count)
	log_debug("vk_create_swapchain: format=", format.format, " color_space=", format.colorSpace, " present_mode=", present_mode, " usage=", usage, " supported_usage=", caps.supportedUsageFlags, " capture_enabled=", ctx.capture_enabled)

	queue_indices := [?]u32{u32(ctx.caps.queue_families.graphics), u32(ctx.caps.queue_families.present)}
	sharing_mode := vk.SharingMode.EXCLUSIVE
	queue_index_count: u32
	queue_index_ptr: [^]u32
	if ctx.caps.queue_families.graphics != ctx.caps.queue_families.present {
		sharing_mode = .CONCURRENT
		queue_index_count = 2
		queue_index_ptr = raw_data(queue_indices[:])
	}

	create_info := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = ctx.surface,
		minImageCount = image_count,
		imageFormat = format.format,
		imageColorSpace = format.colorSpace,
		imageExtent = extent,
		imageArrayLayers = 1,
		imageUsage = usage,
		imageSharingMode = sharing_mode,
		queueFamilyIndexCount = queue_index_count,
		pQueueFamilyIndices = queue_index_ptr,
		preTransform = caps.currentTransform,
		compositeAlpha = {.OPAQUE},
		presentMode = present_mode,
		clipped = true,
	}
	create_result := vk.CreateSwapchainKHR(ctx.device, &create_info, nil, &ctx.swapchain)
	log_debug("vk_create_swapchain: CreateSwapchainKHR result=", create_result)
	if create_result != .SUCCESS {
		return false
	}

	actual_count: u32
	get_count_result := vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain, &actual_count, nil)
	log_debug("vk_create_swapchain: GetSwapchainImages count result=", get_count_result, " count=", actual_count)
	if get_count_result != .SUCCESS {
		return false
	}
	if actual_count > MAX_SWAPCHAIN_IMAGES {
		actual_count = MAX_SWAPCHAIN_IMAGES
	}
	get_images_result := vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain, &actual_count, raw_data(ctx.swapchain_images[:]))
	log_debug("vk_create_swapchain: GetSwapchainImages data result=", get_images_result, " stored_count=", actual_count)
	if get_images_result != .SUCCESS {
		return false
	}

	ctx.swapchain_image_count = actual_count
	ctx.swapchain_format = format.format
	ctx.swapchain_extent = extent
	ctx.caps.swapchain_format = format.format
	ctx.caps.present_mode = present_mode
	ctx.caps.swapchain_extent = extent

	for i in 0 ..< actual_count {
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = ctx.swapchain_images[i],
			viewType = .D2,
			format = ctx.swapchain_format,
			components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}
			view_result := vk.CreateImageView(ctx.device, &view_info, nil, &ctx.swapchain_image_views[i])
			log_debug("vk_create_swapchain: image_view index=", i, " result=", view_result)
			if view_result != .SUCCESS {
				return false
			}
		}

		log_debug("vk_create_swapchain: ready image_count=", ctx.swapchain_image_count, " extent=", ctx.swapchain_extent.width, "x", ctx.swapchain_extent.height)

		return true
	}

vk_swapchain_image_usage :: proc(ctx: ^Vk_Context, caps: vk.SurfaceCapabilitiesKHR) -> vk.ImageUsageFlags {
	usage := vk.ImageUsageFlags{.COLOR_ATTACHMENT, .TRANSFER_DST}
	transfer_src := vk.ImageUsageFlags{.TRANSFER_SRC}
	ctx.swapchain_supports_transfer_src = false
	if transfer_src <= caps.supportedUsageFlags {
		usage += transfer_src
		ctx.swapchain_supports_transfer_src = true
	}
	return usage
}

vk_create_frame_resources :: proc(ctx: ^Vk_Context) -> bool {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		frame := &ctx.frames[i]
		pool_info := vk.CommandPoolCreateInfo {
			sType = .COMMAND_POOL_CREATE_INFO,
			flags = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = u32(ctx.caps.queue_families.graphics),
		}
		if vk.CreateCommandPool(ctx.device, &pool_info, nil, &frame.command_pool) != .SUCCESS {
			return false
		}
		alloc_info := vk.CommandBufferAllocateInfo {
			sType = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool = frame.command_pool,
			level = .PRIMARY,
			commandBufferCount = 1,
		}
		if vk.AllocateCommandBuffers(ctx.device, &alloc_info, &frame.command_buffer) != .SUCCESS {
			return false
		}
		semaphore_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
		if vk.CreateSemaphore(ctx.device, &semaphore_info, nil, &frame.image_available) != .SUCCESS {
			return false
		}
		if vk.CreateSemaphore(ctx.device, &semaphore_info, nil, &frame.render_finished) != .SUCCESS {
			return false
		}
		fence_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		if vk.CreateFence(ctx.device, &fence_info, nil, &frame.in_flight) != .SUCCESS {
			return false
		}
	}
	upload_pool_info := vk.CommandPoolCreateInfo {
		sType = .COMMAND_POOL_CREATE_INFO,
		flags = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = u32(ctx.caps.queue_families.graphics),
	}
	if vk.CreateCommandPool(ctx.device, &upload_pool_info, nil, &ctx.upload_command_pool) != .SUCCESS {
		return false
	}
	upload_alloc_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = ctx.upload_command_pool,
		level = .PRIMARY,
		commandBufferCount = 1,
	}
	if vk.AllocateCommandBuffers(ctx.device, &upload_alloc_info, &ctx.upload_command_buffer) != .SUCCESS {
		return false
	}
	ctx.frame_resources_ready = true
	return true
}

vk_destroy_frame_resources :: proc(ctx: ^Vk_Context) {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		frame := &ctx.frames[i]
		if frame.in_flight != vk.Fence(0) {
			vk.DestroyFence(ctx.device, frame.in_flight, nil)
		}
		if frame.render_finished != vk.Semaphore(0) {
			vk.DestroySemaphore(ctx.device, frame.render_finished, nil)
		}
		if frame.image_available != vk.Semaphore(0) {
			vk.DestroySemaphore(ctx.device, frame.image_available, nil)
		}
		if frame.command_pool != vk.CommandPool(0) {
			vk.DestroyCommandPool(ctx.device, frame.command_pool, nil)
		}
		frame^ = {}
	}
	if ctx.upload_command_pool != vk.CommandPool(0) {
		vk.DestroyCommandPool(ctx.device, ctx.upload_command_pool, nil)
		ctx.upload_command_pool = vk.CommandPool(0)
		ctx.upload_command_buffer = nil
	}
	ctx.frame_resources_ready = false
}

vk_destroy_swapchain_resources :: proc(ctx: ^Vk_Context) {
	for i in 0 ..< ctx.swapchain_image_count {
		if ctx.swapchain_image_views[i] != vk.ImageView(0) {
			vk.DestroyImageView(ctx.device, ctx.swapchain_image_views[i], nil)
			ctx.swapchain_image_views[i] = vk.ImageView(0)
		}
	}
	if ctx.swapchain != vk.SwapchainKHR(0) {
		vk.DestroySwapchainKHR(ctx.device, ctx.swapchain, nil)
		ctx.swapchain = vk.SwapchainKHR(0)
	}
	ctx.swapchain_image_count = 0
}

vk_choose_surface_format :: proc(device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> vk.SurfaceFormatKHR {
	count: u32
	_ = vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, nil)
	if count == 0 {
		return {format = .B8G8R8A8_UNORM, colorSpace = .SRGB_NONLINEAR}
	}
	formats, alloc_err := make([]vk.SurfaceFormatKHR, int(count), context.temp_allocator)
	if alloc_err != nil {
		return {format = .B8G8R8A8_UNORM, colorSpace = .SRGB_NONLINEAR}
	}
	_ = vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, raw_data(formats))
	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}
	return formats[0]
}

vk_choose_present_mode :: proc(device: vk.PhysicalDevice, surface: vk.SurfaceKHR, profiling_capture: bool) -> vk.PresentModeKHR {
	count: u32
	_ = vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &count, nil)
	if count == 0 {
		return .FIFO
	}
	modes, alloc_err := make([]vk.PresentModeKHR, int(count), context.temp_allocator)
	if alloc_err != nil {
		return .FIFO
	}
	if vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &count, raw_data(modes)) != .SUCCESS {
		return .FIFO
	}
	if profiling_capture {
		for mode in modes {
			if mode == .FIFO {
				return .FIFO
			}
		}
	}
	for mode in modes {
		if mode == .MAILBOX {
			return .MAILBOX
		}
	}
	for mode in modes {
		if mode == .IMMEDIATE {
			return .IMMEDIATE
		}
	}
	return modes[0]
}

vk_present_mode_name :: proc(mode: vk.PresentModeKHR) -> string {
	#partial switch mode {
	case .IMMEDIATE:
		return "IMMEDIATE"
	case .MAILBOX:
		return "MAILBOX"
	case .FIFO:
		return "FIFO"
	case .FIFO_RELAXED:
		return "FIFO_RELAXED"
	}
	return "UNKNOWN"
}

vk_cmd_count_compute_dispatch :: proc(ctx: ^Vk_Context) {
	if ctx != nil {
		ctx.command_shape.compute_dispatch_count += 1
	}
}

vk_cmd_count_draw :: proc(ctx: ^Vk_Context) {
	if ctx != nil {
		ctx.command_shape.draw_count += 1
	}
}

vk_cmd_count_pipeline_bind :: proc(ctx: ^Vk_Context) {
	if ctx != nil {
		ctx.command_shape.pipeline_bind_count += 1
	}
}

vk_cmd_count_descriptor_bind :: proc(ctx: ^Vk_Context) {
	if ctx != nil {
		ctx.command_shape.descriptor_bind_count += 1
	}
}

vk_cmd_count_pipeline_barrier :: proc(ctx: ^Vk_Context, count: u32 = 1) {
	if ctx != nil {
		ctx.command_shape.pipeline_barrier_count += count
	}
}

vk_cmd_count_transfer_copy :: proc(ctx: ^Vk_Context) {
	if ctx != nil {
		ctx.command_shape.transfer_copy_count += 1
	}
}

vk_cmd_count_ui_batches :: proc(ctx: ^Vk_Context, count: u32) {
	if ctx != nil {
		ctx.command_shape.ui_batch_count += count
	}
}

vk_cmd_count_backdrop_blur_pass :: proc(ctx: ^Vk_Context) {
	if ctx != nil {
		ctx.command_shape.backdrop_blur_pass_count += 1
	}
}

vk_choose_extent :: proc(caps: vk.SurfaceCapabilitiesKHR, width, height: i32) -> vk.Extent2D {
	if caps.currentExtent.width != 0xffffffff {
		return caps.currentExtent
	}
	w := u32(max(width, 1))
	h := u32(max(height, 1))
	w = min(max(w, caps.minImageExtent.width), caps.maxImageExtent.width)
	h = min(max(h, caps.minImageExtent.height), caps.maxImageExtent.height)
	return {width = w, height = h}
}

vk_make_version :: proc(major, minor, patch: u32) -> u32 {
	return (major << 22) | (minor << 12) | patch
}

gpu_memory_budget_from_heaps :: proc(
	sizes: []u64,
	usages: []u64,
	budgets: []u64,
	has_budget: bool,
	override_fraction: f32,
) -> Gpu_Memory_Budget {
	result: Gpu_Memory_Budget
	result.heap_count = min(len(sizes), MAX_GPU_HEAPS)
	result.uses_memory_budget_ext = has_budget
	result.override_fraction = override_fraction

	for i in 0 ..< result.heap_count {
		heap := &result.heaps[i]
		heap.size = sizes[i]
		if i < len(usages) {
			heap.usage = usages[i]
		}
		if has_budget && i < len(budgets) {
			heap.budget = budgets[i]
		} else {
			heap.budget = heap.size
		}
		heap.has_budget = has_budget

		fraction := override_fraction
		if fraction <= 0 {
			fraction = has_budget ? DEFAULT_REPORTED_BUDGET_CEILING : DEFAULT_HEAP_SIZE_CEILING
		}
		if fraction > 1 {
			fraction = 1
		}

		base := heap.budget
		if !has_budget {
			base = heap.size
		}
		heap.ceiling = u64(f64(base) * f64(fraction) + 0.5)
		result.total_ceiling += heap.ceiling
	}

	return result
}
