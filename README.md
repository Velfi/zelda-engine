# zelda-engine

Reusable Odin game-framework packages extracted from VizzaOdin.

## Prerequisites

- [Odin](https://odin-lang.org/) on `PATH`.
- A C/C++ toolchain, CMake 3.20 or newer, Git, and `pkg-config`.
- HarfBuzz and FreeType development packages for the UI text bridge.
- The Vulkan SDK when using the Vulkan-backed engine packages.
- [Git LFS](https://git-lfs.com/) for cloning source asset files.

After cloning, fetch LFS objects and build the native text bridge:

```sh
git lfs install
git lfs pull
make textshape-build
```

## Packages

- `packages/math`: dependency-neutral vector types shared by engine packages.
- `packages/engine`: Vulkan 1.3 context, swapchain and resource helpers, queues,
  logging, GPU profiling, screenshots, shader-manifest lookup, and fixed-string
  utilities.
- `packages/render_resources`: reusable Vulkan images, depth targets, samplers,
  and RGBA texture uploads built on the engine context.
- `packages/benchmark`: deterministic sample sorting, percentile indices, and
  summary statistics without product-specific budgets or report schemas.
- `packages/jobs`: bounded indexed worker execution with caller-owned inputs
  and result storage.
- `packages/jsonlines`: JSON-lines framing over caller-selected OS handles.
- `packages/render2d`: product-neutral 2D renderer contracts, primitive data,
  camera transforms, deterministic geometry generation, clipping, and input
  transitions. Consumers supply shader manifest keys and effect payload encoders.
- `packages/canvas2d`: SDL/Vulkan immediate-mode 2D canvas, batching, dynamic
  textures, font atlases, world-pass composition, HDR resolve, screenshots,
  and renderer metrics. Consumer assets provide the shader implementation and
  interpret bounded opaque effect payloads.
- `packages/render3d`: reusable Vulkan 3D pipeline and frame-resource helpers;
  consumers retain meshes, shader interfaces, scene semantics, and draw policy.
- `packages/gltf`: GLB 2.0 meshes, materials, scene transforms, skinning, and
  animation loading with consumer-supplied material classification policy.
- `packages/ui`: renderer-neutral input, focus, layout, widgets, text, styling,
  semantic UI documents, draw commands, and animated rich-text span state.
- `packages/physics`: Jolt-backed rigid-body worlds, primitive bodies, forces,
  transforms, and ray queries behind an Odin-native API.
- `third_party`: the small native text-shaping bridge required by `packages/ui`.

The framework contains transient runtime mechanisms only. Product settings,
presets, simulations, feature registries, and product-specific Vulkan adapters
remain in the consuming application.

## Consuming from Odin

Register the `packages` directory as an Odin collection:

```sh
odin check src -collection:zelda_engine=/absolute/path/to/zelda-engine/packages
```

Then import the packages a consumer needs:

```odin
import engine "zelda_engine:engine"
import ui "zelda_engine:ui"
import physics "zelda_engine:physics"
import gltf "zelda_engine:gltf"
import render_resources "zelda_engine:render_resources"
import render2d "zelda_engine:render2d"
import canvas2d "zelda_engine:canvas2d"
import render3d "zelda_engine:render3d"
```

## 2D renderer boundary

`render2d.Renderer_Descriptor` describes shader modules by source identity,
push-constant and per-batch payload sizes, and an optional consumer payload
encoder. Consumers provide source, stage, entry point, and fallback base paths;
the adapter resolves the shader manifest before the fallback. The package never
assumes product shader paths or effect names.

The renderer owns only resources marked `.Owned` in
`render2d.Resource_Ownership`; borrowed windows, Vulkan contexts, UI contexts,
textures, attachments, transient buffers, and effect data remain the caller's
responsibility. A renderer must finish in-flight device work before destroying
owned GPU resources. Consumer effect payload storage must remain valid for any
frame that references it.

Generic solid/textured geometry and platform-input state belong in `render2d`.
Focus, widgets, semantics, typography, and layout remain in `ui`. Product
effects, authored presets, simulations, and serializable presentation settings
remain in the consuming repository.

`render2d.Runtime` enforces create, resize, begin/submit, dynamic texture update,
screenshot request, and teardown ordering over an injected backend. SDL event
translation and frame metrics (draw calls, batches, upload bytes, and screenshot
latency) are reusable mechanisms in this package; a Vulkan adapter can report
them even when GPU timestamps are unavailable.

`canvas2d` is that reusable Vulkan adapter plus an immediate drawing vocabulary.
Applications may keep a familiar short alias while importing it from the engine:

```odin
import rl "zelda_engine:canvas2d"
```

Consumer-specific effects use `EffectPayload` with `DrawEffectQuad` or
`DrawEffectQuadPoints`. The canvas batches the opaque bytes and forwards the
batch to the renderer descriptor's payload encoder; effect names, configuration
types, shader sentinels, and HDR policy remain in the consuming application.

### UI typography and rhythm

Use semantic roles instead of copying style fields into widgets. `gui_typography`
resolves `Display`, `Heading`, `Body`, and `Small` into the current viewport-scaled
font metrics. `gui_space` resolves the shared `Quarter` through `Three` spacing
scale, while `gui_rhythm` accepts a custom non-negative multiple.

```odin
heading := ui.gui_typography(ctx.style, .Heading)
section_gap := ui.gui_space(ctx.style, .One)
two_lines := ui.gui_text_block_height(ctx.style, .Body, 2)
ui.gui_rhythm_spacer(&ctx, .Half)
```

`gui_text_inset_y` centers a role in an arbitrary box and
`gui_text_line_inset_y` aligns glyphs within that role's own line box. These
helpers preserve the vertical grid when UI scale or viewport metrics change.

## Physics

Jolt Physics 5.4.0 is pinned by the bootstrap script and exposed through a
small, stable C ABI. Build it once before importing `physics`:

```sh
make physics-build
make physics-test
```

`make physics-build` downloads the pinned Jolt source checkout into
`third_party/JoltPhysics` and writes all generated native libraries locally.
Those reproducible files are intentionally excluded from Git and Git LFS.

A world owns all of its bodies. Call `destroy_world` when finished. Lengths
are meters, mass is kilograms, time is seconds, and quaternions use XYZW
component order. Static bodies ignore mass; dynamic bodies require positive
mass and dimensions.

VizzaOdin defaults `ZELDA_ENGINE_ROOT` to `../zelda-engine`; override that Make
variable when the repositories are not sibling directories.

## Development

Run the dependency-free GLTF tests and the UI tests with:

```sh
make test
```

Use `make physics-test` for the separately bootstrapped physics package and
`make clean` to remove generated native build products.

Binary source assets such as textures, fonts, audio, video, and GLB files are
tracked with Git LFS. Install Git LFS before adding or committing those files.
