package engine

import "core:os"
import vk "vendor:vulkan"

GPU_PROFILE_PASS_COUNT :: 10
GPU_PROFILE_MAX_OCCURRENCES :: 16
GPU_PROFILE_QUERY_COUNT :: GPU_PROFILE_PASS_COUNT * GPU_PROFILE_MAX_OCCURRENCES * 2

Gpu_Profile_Pass :: enum u32 {
	Frame,
	Simulation_Step,
	Simulation_Present,
	Ui_Overlay,
	Pellets_Grid_Clear,
	Pellets_Grid_Build,
	Pellets_Physics,
	Pellets_Density,
	Pellets_Particle_Draw,
	Pellets_Grid_Scatter,
}

Gpu_Profile_Sample :: struct {
	supported: bool,
	enabled: bool,
	frame_ms: f64,
	simulation_step_ms: f64,
	simulation_present_ms: f64,
	ui_overlay_ms: f64,
	pellets_grid_clear_ms: f64,
	pellets_grid_build_ms: f64,
	pellets_physics_ms: f64,
	pellets_density_ms: f64,
	pellets_particle_draw_ms: f64,
	pellets_grid_scatter_ms: f64,
}

Gpu_Profile_Frame_State :: struct {
	query_pool: vk.QueryPool,
	has_pending_results: bool,
	pass_occurrences: [GPU_PROFILE_PASS_COUNT]u32,
	active_occurrences: [GPU_PROFILE_PASS_COUNT]u32,
}

Gpu_Profiler :: struct {
	frames: [MAX_FRAMES_IN_FLIGHT]Gpu_Profile_Frame_State,
	timestamp_period: f32,
	supported: bool,
	enabled: bool,
	last_sample: Gpu_Profile_Sample,
}

gpu_profiler_init :: proc(ctx: ^Vk_Context) -> bool {
	ctx.gpu_profiler = {}
	ctx.gpu_profiler.supported = ctx.caps.supports_timestamp_queries && ctx.caps.timestamp_period > 0 && vk.CreateQueryPool != nil && vk.GetQueryPoolResults != nil && vk.CmdWriteTimestamp != nil && vk.CmdResetQueryPool != nil
	ctx.gpu_profiler.last_sample.supported = ctx.gpu_profiler.supported
	if !ctx.gpu_profiler.supported {
		return true
	}

	if !gpu_profiler_env_enabled() {
		ctx.gpu_profiler.supported = false
		ctx.gpu_profiler.enabled = false
		ctx.gpu_profiler.last_sample.supported = false
		return true
	}

	ctx.gpu_profiler.timestamp_period = ctx.caps.timestamp_period
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		info := vk.QueryPoolCreateInfo {
			sType = .QUERY_POOL_CREATE_INFO,
			queryType = .TIMESTAMP,
			queryCount = GPU_PROFILE_QUERY_COUNT,
		}
		if vk.CreateQueryPool(ctx.device, &info, nil, &ctx.gpu_profiler.frames[i].query_pool) != .SUCCESS {
			log_warn("gpu_profiler_init: timestamp query pool creation failed; disabling GPU profiling")
			gpu_profiler_destroy(ctx)
			ctx.gpu_profiler.supported = false
			ctx.gpu_profiler.enabled = false
			ctx.gpu_profiler.last_sample.supported = false
			return true
		}
	}
	ctx.gpu_profiler.enabled = true
	ctx.gpu_profiler.last_sample.enabled = true
	log_info("gpu_profiler_init: enabled timestamp_period_ns=", ctx.gpu_profiler.timestamp_period)
	return true
}

gpu_profiler_env_enabled :: proc() -> bool {
	buf: [16]u8
	value := os.get_env_buf(buf[:], "VIZZA_GPU_PROFILER")
	switch value {
	case "1", "true", "TRUE", "True", "on", "ON", "On", "yes", "YES", "Yes":
		return true
	}
	return false
}

gpu_profiler_destroy :: proc(ctx: ^Vk_Context) {
	if ctx.device != nil {
		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
			pool := ctx.gpu_profiler.frames[i].query_pool
			if pool != vk.QueryPool(0) {
				vk.DestroyQueryPool(ctx.device, pool, nil)
			}
		}
	}
	ctx.gpu_profiler = {}
}

gpu_profiler_collect_frame :: proc(ctx: ^Vk_Context, frame_slot: u32) {
	if !ctx.gpu_profiler.enabled || frame_slot >= MAX_FRAMES_IN_FLIGHT {
		return
	}
	frame := &ctx.gpu_profiler.frames[frame_slot]
	if !frame.has_pending_results || frame.query_pool == vk.QueryPool(0) {
		return
	}

	sample := Gpu_Profile_Sample{supported = true, enabled = true}
	pass_values: [GPU_PROFILE_PASS_COUNT]f64
	for pass_index in 0 ..< GPU_PROFILE_PASS_COUNT {
		for occurrence in 0 ..< frame.pass_occurrences[pass_index] {
			values: [2]u64
			first_query := gpu_profiler_query_index(Gpu_Profile_Pass(pass_index), occurrence, true)
			result := vk.GetQueryPoolResults(ctx.device, frame.query_pool, first_query, 2, size_of(values), raw_data(values[:]), vk.DeviceSize(size_of(u64)), {._64})
			if result != .SUCCESS do return
			pass_values[pass_index] += gpu_profiler_delta_ms(ctx, values[0], values[1])
		}
	}
	sample.frame_ms = pass_values[int(Gpu_Profile_Pass.Frame)]
	sample.simulation_step_ms = pass_values[int(Gpu_Profile_Pass.Simulation_Step)]
	sample.simulation_present_ms = pass_values[int(Gpu_Profile_Pass.Simulation_Present)]
	sample.ui_overlay_ms = pass_values[int(Gpu_Profile_Pass.Ui_Overlay)]
	sample.pellets_grid_clear_ms = pass_values[int(Gpu_Profile_Pass.Pellets_Grid_Clear)]
	sample.pellets_grid_build_ms = pass_values[int(Gpu_Profile_Pass.Pellets_Grid_Build)]
	sample.pellets_physics_ms = pass_values[int(Gpu_Profile_Pass.Pellets_Physics)]
	sample.pellets_density_ms = pass_values[int(Gpu_Profile_Pass.Pellets_Density)]
	sample.pellets_particle_draw_ms = pass_values[int(Gpu_Profile_Pass.Pellets_Particle_Draw)]
	sample.pellets_grid_scatter_ms = pass_values[int(Gpu_Profile_Pass.Pellets_Grid_Scatter)]
	ctx.gpu_profiler.last_sample = sample
	frame.has_pending_results = false
}

gpu_profiler_begin_frame :: proc(ctx: ^Vk_Context, frame: Vk_Frame) {
	if !ctx.gpu_profiler.enabled {
		return
	}
	slot := frame.frame_index
	if slot >= MAX_FRAMES_IN_FLIGHT {
		return
	}
	pool := ctx.gpu_profiler.frames[slot].query_pool
	if pool == vk.QueryPool(0) {
		return
	}
	vk.CmdResetQueryPool(frame.command_buffer, pool, 0, GPU_PROFILE_QUERY_COUNT)
	ctx.gpu_profiler.frames[slot].pass_occurrences = {}
	ctx.gpu_profiler.frames[slot].active_occurrences = {}
	gpu_profiler_write(ctx, frame.command_buffer, slot, .Frame, true)
}

gpu_profiler_end_frame :: proc(ctx: ^Vk_Context, frame: Vk_Frame) {
	if !ctx.gpu_profiler.enabled {
		return
	}
	slot := frame.frame_index
	if slot >= MAX_FRAMES_IN_FLIGHT {
		return
	}
	gpu_profiler_write(ctx, frame.command_buffer, slot, .Frame, false)
	ctx.gpu_profiler.frames[slot].has_pending_results = true
}

gpu_profiler_begin_pass :: proc(ctx: ^Vk_Context, cmd: vk.CommandBuffer, frame: Vk_Frame, pass: Gpu_Profile_Pass) {
	gpu_profiler_write(ctx, cmd, frame.frame_index, pass, true)
}

gpu_profiler_end_pass :: proc(ctx: ^Vk_Context, cmd: vk.CommandBuffer, frame: Vk_Frame, pass: Gpu_Profile_Pass) {
	gpu_profiler_write(ctx, cmd, frame.frame_index, pass, false)
}

gpu_profiler_last_sample :: proc(ctx: ^Vk_Context) -> Gpu_Profile_Sample {
	sample := ctx.gpu_profiler.last_sample
	sample.supported = ctx.gpu_profiler.supported
	sample.enabled = ctx.gpu_profiler.enabled
	return sample
}

gpu_profiler_write :: proc(ctx: ^Vk_Context, cmd: vk.CommandBuffer, frame_slot: u32, pass: Gpu_Profile_Pass, begin: bool) {
	if !ctx.gpu_profiler.enabled || frame_slot >= MAX_FRAMES_IN_FLIGHT {
		return
	}
	pool := ctx.gpu_profiler.frames[frame_slot].query_pool
	if pool == vk.QueryPool(0) {
		return
	}
	pass_index := int(pass)
	occurrence: u32
	if begin {
		occurrence = ctx.gpu_profiler.frames[frame_slot].pass_occurrences[pass_index]
		if occurrence >= GPU_PROFILE_MAX_OCCURRENCES do return
		ctx.gpu_profiler.frames[frame_slot].active_occurrences[pass_index] = occurrence
		ctx.gpu_profiler.frames[frame_slot].pass_occurrences[pass_index] = occurrence + 1
	} else {
		if ctx.gpu_profiler.frames[frame_slot].pass_occurrences[pass_index] == 0 do return
		occurrence = ctx.gpu_profiler.frames[frame_slot].active_occurrences[pass_index]
	}
	query := gpu_profiler_query_index(pass, occurrence, begin)
	stage := vk.PipelineStageFlags2{.TOP_OF_PIPE}
	if !begin {
		stage = {.BOTTOM_OF_PIPE}
	}
	vk.CmdWriteTimestamp2(cmd, stage, pool, query)
}

gpu_profiler_query_index :: proc(pass: Gpu_Profile_Pass, occurrence: u32, begin: bool) -> u32 {
	query := (u32(pass) * GPU_PROFILE_MAX_OCCURRENCES + occurrence) * 2
	if !begin do query += 1
	return query
}

gpu_profiler_delta_ms :: proc(ctx: ^Vk_Context, start, finish: u64) -> f64 {
	if finish <= start {
		return 0
	}
	ns := f64(finish - start) * f64(ctx.gpu_profiler.timestamp_period)
	return ns / 1000000.0
}

vk_cmd_label_begin :: proc(ctx: ^Vk_Context, cmd: vk.CommandBuffer, name: cstring) {
	if !ctx.supports_debug_utils || vk.CmdBeginDebugUtilsLabelEXT == nil {
		return
	}
	label := vk.DebugUtilsLabelEXT {
		sType = .DEBUG_UTILS_LABEL_EXT,
		pLabelName = name,
		color = {0.35, 0.62, 1.0, 1.0},
	}
	vk.CmdBeginDebugUtilsLabelEXT(cmd, &label)
}

vk_cmd_label_end :: proc(ctx: ^Vk_Context, cmd: vk.CommandBuffer) {
	if !ctx.supports_debug_utils || vk.CmdEndDebugUtilsLabelEXT == nil {
		return
	}
	vk.CmdEndDebugUtilsLabelEXT(cmd)
}
