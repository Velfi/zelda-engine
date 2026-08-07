package render3d

import vk "vendor:vulkan"
import engine "zelda_engine:engine"

COLOR_PIPELINE_FORMAT_COUNT :: 2
COLOR_PIPELINE_SAMPLE_COUNT :: 3
COLOR_PIPELINE_VARIANT_COUNT :: COLOR_PIPELINE_FORMAT_COUNT * COLOR_PIPELINE_SAMPLE_COUNT

color_pipeline_variant_index :: proc(format: vk.Format, samples: vk.SampleCountFlags) -> int {
    format_index := format == .R16G16B16A16_SFLOAT ? 1 : 0
    sample_index := 0
    if ._2 in samples do sample_index = 1
    if ._4 in samples do sample_index = 2
    return sample_index * COLOR_PIPELINE_FORMAT_COUNT + format_index
}

create_color_pipeline_variants :: proc(
    ctx: ^engine.Vk_Context,
    info: ^vk.GraphicsPipelineCreateInfo,
    depth_format: vk.Format,
    pipelines: ^[COLOR_PIPELINE_VARIANT_COUNT]vk.Pipeline,
) -> bool {
    formats := [COLOR_PIPELINE_FORMAT_COUNT]vk.Format{ctx.swapchain_format, .R16G16B16A16_SFLOAT}
    sample_counts := [COLOR_PIPELINE_SAMPLE_COUNT]vk.SampleCountFlags{{._1}, {._2}, {._4}}
    original_multisample := info.pMultisampleState
    for samples, sample_index in sample_counts {
        multisample := original_multisample^
        multisample.rasterizationSamples = samples
        info.pMultisampleState = &multisample
        for &format, format_index in formats {
            index := sample_index * COLOR_PIPELINE_FORMAT_COUNT + format_index
            rendering := engine.vk_pipeline_rendering_info(&format)
            rendering.depthAttachmentFormat = depth_format
            info.pNext = &rendering
            if vk.CreateGraphicsPipelines(ctx.device, vk.PipelineCache(0), 1, info, nil, &pipelines[index]) !=
               .SUCCESS {
                info.pMultisampleState = original_multisample
                return false
            }
            engine.vk_set_debug_name(ctx, .PIPELINE, auto_cast pipelines[index], "3D graphics pipeline")
        }
    }
    info.pMultisampleState = original_multisample
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
