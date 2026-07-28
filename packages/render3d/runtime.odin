package render3d

import vk "vendor:vulkan"
import engine "zelda_engine:engine"

COLOR_PIPELINE_VARIANT_COUNT :: 2

create_color_pipeline_variants :: proc(
    ctx: ^engine.Vk_Context,
    info: ^vk.GraphicsPipelineCreateInfo,
    depth_format: vk.Format,
    pipelines: ^[COLOR_PIPELINE_VARIANT_COUNT]vk.Pipeline,
) -> bool {
    formats := [COLOR_PIPELINE_VARIANT_COUNT]vk.Format{ctx.swapchain_format, .R16G16B16A16_SFLOAT}
    for &format, index in formats {
        rendering := engine.vk_pipeline_rendering_info(&format)
        rendering.depthAttachmentFormat = depth_format
        info.pNext = &rendering
        if vk.CreateGraphicsPipelines(ctx.device, vk.PipelineCache(0), 1, info, nil, &pipelines[index]) != .SUCCESS {
            return false
        }
        engine.vk_set_debug_name(ctx, .PIPELINE, auto_cast pipelines[index], "3D graphics pipeline")
    }
    return true
}

destroy_color_pipeline_variants :: proc(
    ctx: ^engine.Vk_Context,
    pipelines: ^[COLOR_PIPELINE_VARIANT_COUNT]vk.Pipeline,
) {
    for &pipeline in pipelines {
        if pipeline != vk.Pipeline(0) do vk.DestroyPipeline(ctx.device, pipeline, nil)
        pipeline = vk.Pipeline(0)
    }
}
