package engine

import vk "vendor:vulkan"

vk_pipeline_rendering_info :: proc(format: ^vk.Format) -> vk.PipelineRenderingCreateInfo {
	return vk.PipelineRenderingCreateInfo {
		sType = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount = 1,
		pColorAttachmentFormats = format,
	}
}

vk_cmd_begin_rendering :: proc(
	ctx: ^Vk_Context,
	cmd: vk.CommandBuffer,
	view: vk.ImageView,
	extent: vk.Extent2D,
	layout: vk.ImageLayout,
	load_op: vk.AttachmentLoadOp,
	store_op: vk.AttachmentStoreOp,
	clear: vk.ClearValue,
) {
	attachment := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = view,
		imageLayout = layout,
		loadOp = load_op,
		storeOp = store_op,
		clearValue = clear,
	}
	info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &attachment,
	}
	vk.CmdBeginRendering(cmd, &info)
	ctx.command_shape.rendering_scope_count += 1
}

vk_cmd_end_rendering :: proc(cmd: vk.CommandBuffer) {
	vk.CmdEndRendering(cmd)
}

vk_cmd_image_barrier2 :: proc(
	ctx: ^Vk_Context,
	cmd: vk.CommandBuffer,
	image: vk.Image,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	src_access, dst_access: vk.AccessFlags2,
	old_layout, new_layout: vk.ImageLayout,
	aspect := vk.ImageAspectFlags{.COLOR},
) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = src_stage,
		srcAccessMask = src_access,
		dstStageMask = dst_stage,
		dstAccessMask = dst_access,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {aspectMask = aspect, baseMipLevel = 0, levelCount = 1, baseArrayLayer = 0, layerCount = 1},
	}
	dependency := vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &barrier}
	vk.CmdPipelineBarrier2(cmd, &dependency)
	ctx.command_shape.pipeline_barrier_count += 1
}

vk_cmd_buffer_barrier2 :: proc(
	ctx: ^Vk_Context,
	cmd: vk.CommandBuffer,
	buffer: vk.Buffer,
	offset, size: vk.DeviceSize,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	src_access, dst_access: vk.AccessFlags2,
) {
	barrier := vk.BufferMemoryBarrier2 {
		sType = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask = src_stage,
		srcAccessMask = src_access,
		dstStageMask = dst_stage,
		dstAccessMask = dst_access,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer = buffer,
		offset = offset,
		size = size,
	}
	dependency := vk.DependencyInfo{sType = .DEPENDENCY_INFO, bufferMemoryBarrierCount = 1, pBufferMemoryBarriers = &barrier}
	vk.CmdPipelineBarrier2(cmd, &dependency)
	ctx.command_shape.pipeline_barrier_count += 1
}

vk_cmd_pipeline_barrier2 :: proc(
	cmd: vk.CommandBuffer,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	dependency_flags: vk.DependencyFlags,
	memory_count: u32,
	memory_barriers: [^]vk.MemoryBarrier2,
	buffer_count: u32,
	buffer_barriers: [^]vk.BufferMemoryBarrier2,
	image_count: u32,
	image_barriers: [^]vk.ImageMemoryBarrier2,
) {
	memory2: [16]vk.MemoryBarrier2
	buffer2: [16]vk.BufferMemoryBarrier2
	image2: [16]vk.ImageMemoryBarrier2
	assert(memory_count <= len(memory2) && buffer_count <= len(buffer2) && image_count <= len(image2))
	for i in 0 ..< memory_count {
		old := memory_barriers[i]
		memory2[i] = old
		memory2[i].srcStageMask = src_stage
		memory2[i].dstStageMask = dst_stage
	}
	for i in 0 ..< buffer_count {
		old := buffer_barriers[i]
		buffer2[i] = old
		buffer2[i].srcStageMask = src_stage
		buffer2[i].dstStageMask = dst_stage
	}
	for i in 0 ..< image_count {
		old := image_barriers[i]
		image2[i] = old
		image2[i].srcStageMask = src_stage
		image2[i].dstStageMask = dst_stage
	}
	dependency := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		dependencyFlags = dependency_flags,
		memoryBarrierCount = memory_count,
		pMemoryBarriers = memory_count > 0 ? raw_data(memory2[:]) : nil,
		bufferMemoryBarrierCount = buffer_count,
		pBufferMemoryBarriers = buffer_count > 0 ? raw_data(buffer2[:]) : nil,
		imageMemoryBarrierCount = image_count,
		pImageMemoryBarriers = image_count > 0 ? raw_data(image2[:]) : nil,
	}
	vk.CmdPipelineBarrier2(cmd, &dependency)
}
