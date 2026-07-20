# zelda-engine contributor notes

- Keep this repository reusable and product-neutral.
- Do not import VizzaOdin product, application, or renderer-adapter packages.
- Keep serializable application settings and presets in consuming products.
- Runtime state, Vulkan resources, UI focus, and transient buffers belong here
  only when their behavior is reusable across products.
- `packages/ui` must remain renderer-neutral and must not import `engine`.
