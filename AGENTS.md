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

## Consumer contract

- Anything a consumer must supply to boot — a native archive on the link line, a
  shader entry point, a file read from the working directory — belongs in the
  README's "Starting a new game" checklist. These fail at runtime rather than at
  compile time, so an undocumented one costs a consumer an afternoon.
- Adding a new package means adding it to the README package list in the same
  change.
- A path to a product asset must not be compiled into a package. Take it through
  a descriptor field or a setter, the way `SetBodyFontPath` and
  `SetIconAtlasPath` do.
- An asset only some products use should default to unset and degrade to a
  no-op, not fail startup. Fail only on an asset a consumer named itself, and
  name the path and the working directory when doing so.
