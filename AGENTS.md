# zelda-engine contributor notes

- Keep this repository reusable and product-neutral.
- Do not import VizzaOdin product, application, or renderer-adapter packages.
- Keep serializable application settings and presets in consuming products.
- Runtime state, Vulkan resources, UI focus, and transient buffers belong here
  only when their behavior is reusable across products.
- `packages/ui` must remain renderer-neutral and must not import `engine`.
- When modifying Vulkan code, name every created or acquired Vulkan object immediately
  with `vk.SetDebugUtilsObjectNameEXT` (through the shared helper when available); for
  objects created before device-level function loading, name them at the first possible point.
