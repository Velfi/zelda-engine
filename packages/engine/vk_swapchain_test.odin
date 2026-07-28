package engine

import "core:testing"
import vk "vendor:vulkan"

@(test)
vk_present_mode_selection_respects_vsync_policy :: proc(t: ^testing.T) {
    modes := [3]vk.PresentModeKHR{.MAILBOX, .FIFO, .IMMEDIATE}
    testing.expect_value(t, vk_select_present_mode(modes[:], true), vk.PresentModeKHR.FIFO)
    testing.expect_value(t, vk_select_present_mode(modes[:], false), vk.PresentModeKHR.IMMEDIATE)

    without_immediate := [2]vk.PresentModeKHR{.FIFO, .MAILBOX}
    testing.expect_value(t, vk_select_present_mode(without_immediate[:], false), vk.PresentModeKHR.MAILBOX)

    fifo_only := [1]vk.PresentModeKHR{.FIFO}
    testing.expect_value(t, vk_select_present_mode(fifo_only[:], false), vk.PresentModeKHR.FIFO)
    testing.expect_value(t, vk_select_present_mode(fifo_only[:0], false), vk.PresentModeKHR.FIFO)
}

@(test)
vk_runtime_vsync_change_schedules_swapchain_recreation :: proc(t: ^testing.T) {
    ctx := Vk_Context {
        initialized   = true,
        vsync_enabled = true,
    }
    vk_set_vsync_enabled(&ctx, false)
    testing.expect(t, !ctx.vsync_enabled)
    testing.expect(t, ctx.needs_swapchain_recreate)

    ctx.needs_swapchain_recreate = false
    vk_set_vsync_enabled(&ctx, false)
    testing.expect(t, !ctx.needs_swapchain_recreate)
}
