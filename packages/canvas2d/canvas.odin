package canvas2d

// Product-neutral immediate 2D canvas backed by zelda-engine's Vulkan context.
// Consumers provide shaders and retain authored presentation policy.

import "core:image"
import _ "core:image/png"
import "core:math"
import "core:mem"
import "core:os"
import "core:time"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
import engine "zelda_engine:engine"
import render2d "zelda_engine:render2d"
import resources "zelda_engine:render_resources"
import ui "zelda_engine:ui"

// Compatibility aliases preserve the existing drawing vocabulary while making
// engine-owned renderer data usable directly by migrating callers.
Vector2 :: render2d.Vector2
Rectangle :: render2d.Rectangle
Color :: render2d.Color
Font :: struct {
	ready: bool,
}
Texture :: render2d.Texture
Button_Interaction :: struct {
	activated, hovered, focused: bool,
}
Camera2D :: render2d.Camera2D
MouseButton :: enum {
	LEFT,
	MIDDLE,
	RIGHT,
	COUNT,
}
KeyboardKey :: enum {
	ESCAPE,
	ENTER,
	TAB,
	LEFT_SHIFT,
	RIGHT_SHIFT,
	BACKSPACE,
	W,
	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	S,
	Q,
	R,
	T,
	U,
	V,
	Y,
	Z,
	X,
	UP,
	DOWN,
	LEFT,
	RIGHT,
	ONE,
	TWO,
	THREE,
	FOUR,
	SPACE,
	COUNT,
}
Gamepad_Button :: enum {
	South,
	East,
	West,
	North,
	Left_Shoulder,
	Right_Shoulder,
	Dpad_Up,
	Dpad_Down,
	Dpad_Left,
	Dpad_Right,
	Start,
	Count,
}; Gamepad_Axis :: enum {
	Left_X,
	Left_Y,
	Right_X,
	Right_Y,
	Left_Trigger,
	Right_Trigger,
}
// SDL_SCANCODE_COUNT is 512. The Odin SDL3 binding reserves values through
// 511 but omits the C header's terminal COUNT enumerator.
SDL_SCANCODE_COUNT :: 512
ConfigFlag :: enum {
	WINDOW_RESIZABLE,
	WINDOW_HIGHDPI,
	VSYNC_HINT,
	WINDOW_NOT_FOCUSABLE,
}
ConfigFlags :: bit_set[ConfigFlag]

World_Pass_Context :: struct {
	ctx:                ^engine.Vk_Context,
	frame:              engine.Vk_Frame,
	color_view:         vk.ImageView,
	color_format:       vk.Format,
	depth_view:         vk.ImageView,
	framebuffer_extent: vk.Extent2D,
	logical_extent:     [2]i32,
}
World_Pass_Callback :: #type proc(pass: ^World_Pass_Context, user_data: rawptr)

Vertex :: render2d.Vertex
Push :: struct {
	viewport:      [4]f32,
	texture_hatch: [4]f32,
	hatch_shape:   [4]f32,
	hatch_tone:    [4]f32,
	hatch_offset:  [4]f32,
	hatch_angles:  [4]f32,
	hatch_levels:  [4]f32,
}
#assert(size_of(Push) == 112)
Hatch_Filter :: enum {
	Aliased,
	Anti_Aliased,
}
Hatch_Config :: struct {
	enabled:                     bool,
	filter:                      Hatch_Filter,
	invert:                      bool,
	spacing, line_width:         f32,
	softness, strength:          f32,
	contrast, brightness:        f32,
	rotation:                    f32,
	edge_softness, irregularity: f32,
	offset:                      Vector2,
	layer_count:                 int,
	angles, thresholds:          [4]f32,
}
HATCH_DISABLED :: Hatch_Config{}

// Presentation-level multiplier for authored hatch spacing. Values above one
// make marks sparser; values below one make them denser without flattening the
// authored differences in line weight, layering, or irregularity.
HatchSpacingScale: f32 = 1

Screen_Effect :: enum {
	None,
	Trinitron,
}

screen_effect: Screen_Effect
screen_effect_reduced_motion: bool

SetScreenEffect :: proc(effect: Screen_Effect, reduced_motion := false) {
	screen_effect = effect
	screen_effect_reduced_motion = reduced_motion
}

SetHatchDensity :: proc(spacing_scale: f32) {
	HatchSpacingScale = clamp(spacing_scale, f32(.5), f32(2))
}

default_hatch :: Hatch_Config {
	enabled       = true,
	filter        = .Anti_Aliased,
	spacing       = 8,
	line_width    = 1.1,
	softness      = 1,
	strength      = .9,
	contrast      = 1.15,
	edge_softness = .1,
	irregularity  = .12,
	layer_count   = 4,
	angles        = {-.7853982, .7853982, 0, 1.5707963},
	thresholds    = {.18, .38, .58, .78},
}
MAX_EFFECT_PAYLOAD_SIZE :: 256
Effect_Payload :: struct {
	kind:         u32,
	size:         int,
	bytes:        [MAX_EFFECT_PAYLOAD_SIZE]u8,
	hdr_required: bool,
}

EffectPayload :: proc(kind: u32, value: ^$T, hdr_required := false) -> Effect_Payload {
	result := Effect_Payload {
		kind = kind,
		size = size_of(T),
		hdr_required = hdr_required,
	}
	assert(result.size <= MAX_EFFECT_PAYLOAD_SIZE)
	mem.copy_non_overlapping(raw_data(result.bytes[:]), value, result.size)
	return result
}

Batch :: struct {
	first, count:     u32,
	texture:          int,
	hatch:            Hatch_Config,
	effect:           Effect_Payload,
	clip_enabled:     bool,
	clip:             Rectangle,
}

// Dense procedural plates, stipple, and crosshatching can place hundreds of
// thousands of vertices in one frame. Keep enough mapped capacity for large
// verification sheets to finish instead of silently truncating the viewport.
MAX_VERTICES :: 786432
MAX_INDICES :: MAX_VERTICES / 4 * 6
FONT_FIRST :: 32
FONT_LAST :: 126
FONT_COUNT :: FONT_LAST - FONT_FIRST + 1
// Common UI symbols are rasterized from the bundled Noto Sans Symbols 2 face.
// Keep this compact: the primary Iosevka atlas remains the source for text.
FONT_FALLBACK_RUNES :: [?]rune{'◆', '◇', '✓', '✕', '⚠'}
FONT_FALLBACK_COUNT :: len(FONT_FALLBACK_RUNES)
FONT_COLUMNS :: 16
// Keep the UI atlas at 2x its logical 28 px design size. Large display type
// otherwise upscales a 28 px bitmap and visibly softens while the rest of the
// interface remains sharp. Iosevka's monospace advance fits comfortably in
// the doubled cell without bleeding into adjacent glyphs.
FONT_CELL_W :: 40
FONT_CELL_H :: 64
FONT_ROWS :: (FONT_COUNT + FONT_FALLBACK_COUNT + FONT_COLUMNS - 1) / FONT_COLUMNS
FONT_ATLAS_W :: FONT_CELL_W * FONT_COLUMNS
FONT_ATLAS_H :: FONT_CELL_H * FONT_ROWS
ICON_COLUMNS :: 6
ICON_ROWS :: 6
MAX_TEXTURES :: 16

State :: struct {
	renderer_descriptor:                       render2d.Renderer_Descriptor,
	config_flags:                              ConfigFlags,
	window:                                    ^sdl.Window,
	platform_window:                           render2d.SDL_Window_Runtime,
	ctx:                                       engine.Vk_Context,
	textures:                                  [MAX_TEXTURES]resources.Image,
	dynamic_staging:                           [MAX_TEXTURES][engine.MAX_FRAMES_IN_FLIGHT]engine.Vk_Buffer,
	dynamic_pixels:                            [MAX_TEXTURES][dynamic]u8,
	dynamic_pending:                           [MAX_TEXTURES]bool,
	depth:                                     resources.Image,
	texture_count:                             int,
	texture_width, texture_height:             int,
	icon_y, icon_width, icon_height:           int,
	font_advance_em:                           f32,
	descriptor_layout:                         vk.DescriptorSetLayout,
	descriptor_pool:                           vk.DescriptorPool,
	descriptors:                               [MAX_TEXTURES]vk.DescriptorSet,
	pipeline_layout:                           vk.PipelineLayout,
	pipeline:                                  vk.Pipeline,
	hdr_pipeline, post_pipeline:               vk.Pipeline,
	hdr_scene:                                 resources.Image,
	vertex:                                    [engine.MAX_FRAMES_IN_FLIGHT]engine.Vk_Buffer,
	index:                                     [engine.MAX_FRAMES_IN_FLIGHT]engine.Vk_Buffer,
	capture_buffer:                            engine.Vk_Buffer,
	capture_state:                             engine.Screenshot_State,
	capture_path:                              string,
	capture_requested:                         bool,
	capture_started:                           time.Tick,
	vertices:                                  [dynamic]Vertex,
	indices:                                   [dynamic]u32,
	batches:                                   [dynamic]Batch,
	width, height:                             i32,
	framebuffer_width, framebuffer_height:     i32,
	running, initialized:                      bool,
	mouse:                                     Vector2,
	mouse_delta:                               Vector2,
	mouse_wheel:                               f32,
	mouse_pinch_scale:                         f32,
	mouse_down, mouse_pressed, mouse_released: [int(MouseButton.COUNT)]bool,
	keys_pressed:                              [SDL_SCANCODE_COUNT]bool,
	keys_down:                                 [SDL_SCANCODE_COUNT]bool,
	gamepad:                                   ^sdl.Gamepad,
	gamepad_id:                                sdl.JoystickID,
	gamepad_down, gamepad_pressed:             [int(Gamepad_Button.Count)]bool,
	platform_input:                            render2d.SDL_Input_State,
	metrics:                                   render2d.Metrics,
	clear:                                     Color,
	camera:                                    Camera2D,
	camera_active:                             bool,
	clip:                                      Rectangle,
	clip_enabled:                              bool,
	start:                                     time.Tick,
	gui:                                       ui.Gui_Context,
	world_pass:                                World_Pass_Callback,
	world_pass_user_data:                      rawptr,
	gfx_frame_signpost:                        u64,
}
state: State
