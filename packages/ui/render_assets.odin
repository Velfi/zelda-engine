package ui

// Stable semantic IDs shared by renderer-neutral UI commands and renderer
// adapters. The Vulkan backend owns the textures; UI and product code only
// refer to these IDs and atlas slots.
UI_EXAMPLE_SCREENSHOT_TEXTURE_ID :: 1
UI_CONTROLLER_ICON_ATLAS_TEXTURE_ID :: 9
UI_KENNEY_INPUT_ATLAS_TEXTURE_ID :: 10

UI_CONTROLLER_ICON_COUNT :: 21
UI_KENNEY_INPUT_ICONS_PER_STYLE :: 6
UI_KENNEY_INPUT_STYLE_COUNT :: 3
UI_KENNEY_INPUT_ICON_COUNT :: UI_KENNEY_INPUT_ICONS_PER_STYLE * UI_KENNEY_INPUT_STYLE_COUNT
UI_FONT_ATLAS_LOGICAL_WIDTH :: 16

// Values match the horizontal order in the controller icon atlas.
Ui_Controller_Icon :: enum {
	Player_Play,
	Palette,
	Brush,
	Motion,
	Awareness,
	Trails,
	World,
	Birth,
	Capture,
	Presets,
	Pattern,
	Mask,
	Camera,
	Forces,
	Physics,
	Population,
	Advanced,
	Field,
	Particles,
	Sites,
	Flow,
}
