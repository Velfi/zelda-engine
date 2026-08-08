# zelda-engine

Reusable Odin game-framework packages extracted from VizzaOdin.

## Prerequisites

- [Odin](https://odin-lang.org/) on `PATH`.
- A C/C++ toolchain, CMake 3.20 or newer, Git, and `pkg-config`.
- HarfBuzz and FreeType development packages for the UI text bridge.
- The Vulkan SDK when using the Vulkan-backed engine packages.
- [Git LFS](https://git-lfs.com/) for cloning source asset files.

After cloning, fetch LFS objects and build the native archives that
`packages/ui` and `packages/canvas2d` link:

```sh
git lfs install
git lfs pull
make textshape-build
make canvas-signposts-build
```

Starting a game on top of the engine? See
[Starting a new game](#starting-a-new-game) for the full consumer checklist.

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
- `packages/capture`: screenshot-harness sequencing only. Window creation,
  rendering, and screenshot delivery stay consumer callbacks.
- `packages/cgltf`: the vendored cgltf C parser and its Odin bindings, used by
  `packages/gltf`. Consumers link the prebuilt archive under `cgltf/lib`.
- `packages/spy`: leveled logging, log filtering, a tracking allocator, and
  spans. `packages/engine` logs through it, so it is always linked in.
- `packages/back`: backtraces and a backtrace-attributing allocator, used to
  attribute leaks and crashes.
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

## Starting a new game

A `canvas2d` consumer must supply four things. Miss any one and the failure
shows up at `InitWindow`, not at compile time, so do them in this order.

### 1. Build the two native archives

`packages/ui` links the HarfBuzz/FreeType text bridge, and `packages/canvas2d`
links a small C shim that emits GPU signposts. Both live here and are excluded
from Git, so a fresh clone must build them:

```sh
make textshape-build          # third_party/textshape/libtextshape.a
make canvas-signposts-build   # build/libgfx_signposts.a
```

A consumer may compile `packages/canvas2d/gfx_signposts.c` into its own build
directory instead; the archive is one object file and has no engine dependency.

### 2. Link against them

The collection alone is not enough — the archives above and the C++ runtime
have to reach the linker:

```sh
odin build src \
  -collection:zelda_engine=/absolute/path/to/zelda-engine/packages \
  -out:build/game \
  -extra-linker-flags:"$(pkg-config --libs harfbuzz freetype2) \
    /path/to/zelda-engine/third_party/textshape/libtextshape.a \
    -Lbuild -lgfx_signposts -lc++ \
    -Wl,-no_warn_duplicate_libraries -framework Cocoa"
```

`-framework Cocoa` and `-Wl,-no_warn_duplicate_libraries` are macOS only.

### 3. Provide the four canvas shader entry points

`canvas2d` owns Vulkan setup but never the shader source. A consumer supplies
one module with four entry points, named through
`render2d.Renderer_Descriptor`:

| Entry point | Stage | Purpose |
| --- | --- | --- |
| `vertex_main` | vertex | Canvas batches: pixel coordinates to NDC |
| `fragment_main` | fragment | Canvas batches: solid, textured, and glyph pages |
| `post_vertex` | vertex | Full-screen triangle for the post pass |
| `post_fragment` | fragment | Post pass; pass the scene through when unused |

The push-constant block must match `canvas2d.Push` exactly — eight `float4`s,
128 bytes, enforced by `#assert(size_of(Push) == 128)`. `fragment_main` must
branch on `push.texture_hatch.x`: above `1.5` is a glyph page whose alpha comes
from the texel's red channel, above `0.5` is a textured quad, otherwise solid.
Text renders as blank rectangles when that branch is missing.

Compile each entry point to its own `.spv`:

```sh
slangc canvas.slang -entry vertex_main -stage vertex \
  -target spirv -profile spirv_1_5 -o build/shaders/canvas.vert.spv
```

The descriptor names a manifest key and a fallback path; the fallback is
resolved relative to the working directory, so the compiled modules belong in
`shaders/` beside the executable.

### 4. Stage the runtime assets

`canvas2d` builds one atlas holding both font planes and, optionally, a UI icon
sheet. It reads them from paths relative to the **working directory**, so run
the game from its build directory:

```
assets/fonts/<body>.ttf       required, set via SetBodyFontPath
assets/fonts/<display>.ttf    required, set via SetDisplayFontPath
assets/icons/<sheet>.png      optional, set via SetIconAtlasPath
```

Both fonts are required — the atlas rasterizes an ASCII page from each. All
three setters must be called before `InitWindow`, which is when the backend
builds the atlas.

The icon sheet has no default. A consumer that never names one draws no icons
and boots without it, and `DrawIcon` becomes a no-op. Name one and it is packed
into the tail of the atlas, addressed by `DrawIcon` as an `ICON_COLUMNS` x
`ICON_ROWS` grid in row-major order:

```odin
_ = canvas2d.SetIconAtlasPath("assets/icons/my-icons.png")
canvas2d.DrawIcon(0, {40, 40, 64, 64})
```

A sheet named here and missing at startup fails `InitWindow` and names the path
it tried, along with the working directory it resolved against.

### A minimal consumer

This is the whole of a working app. It boots a window, draws a rectangle and a
line of text, and exits.

```odin
package main

import "core:fmt"
import "core:os"
import canvas2d "zelda_engine:canvas2d"
import render2d "zelda_engine:render2d"

RENDERER_DESCRIPTOR := render2d.Renderer_Descriptor {
    pipeline = {
        vertex = {"assets/shaders/canvas.vert", .Vertex, "main", "shaders/canvas.vert"},
        fragment = {"assets/shaders/canvas.frag", .Fragment, "main", "shaders/canvas.frag"},
        post_vertex = {"assets/shaders/canvas-post.vert", .Vertex, "main", "shaders/canvas-post.vert"},
        post_fragment = {"assets/shaders/canvas-post.frag", .Fragment, "main", "shaders/canvas-post.frag"},
        push_constant_size = size_of(canvas2d.Push),
    },
}

main :: proc() {
    canvas2d.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
    _ = canvas2d.SetBodyFontPath("assets/fonts/NotoSans-Regular.ttf")
    _ = canvas2d.SetDisplayFontPath("assets/fonts/NotoSerif-Regular.ttf")
    if !canvas2d.SetRendererDescriptor(RENDERER_DESCRIPTOR) {
        fmt.eprintln("error: SetRendererDescriptor failed")
        os.exit(1)
    }
    if !canvas2d.InitWindow(960, 600, "hello") {
        fmt.eprintln("error: InitWindow failed")
        os.exit(1)
    }
    defer canvas2d.CloseWindow()

    for !canvas2d.WindowShouldClose() {
        canvas2d.BeginDrawing()
        canvas2d.ClearBackground({18, 18, 22, 255})
        canvas2d.DrawRectangleRec({40, 40, 220, 120}, {220, 180, 90, 255})
        // A zero Font with ready = true selects the configured body font.
        canvas2d.DrawTextEx(canvas2d.Font{ready = true}, "hello", {40, 200}, 32, 1, {236, 232, 224, 255})
        canvas2d.EndDrawing()
        free_all(context.temp_allocator)
    }
}
```

`SetRendererDescriptor` and the font paths must be set **before**
`InitWindow` — the backend reads them while building its pipelines and atlas.

### Screenshots

`TakeScreenshot` requests a readback that a later presented frame completes.
Requesting one and exiting immediately writes no file. Draw a few more frames
after the request, then exit:

```odin
draw()
canvas2d.TakeScreenshot("smoke.png")
draw()
draw()
```

This makes a good self-test for a consumer: boot, advance, capture, exit.

### When it fails

| Symptom | Cause |
| --- | --- |
| `canvas font atlas: body font failed to load` | The named font does not resolve from the working directory; the message prints both paths |
| `canvas font atlas: icon sheet failed to load` | A sheet was named through `SetIconAtlasPath` but is not there. Leave the path unset to boot without icons |
| `canvas backend initialization failed during graphics pipelines` | A `.spv` named by the descriptor is missing beside the executable, or an entry point failed to compile |
| Undefined symbols for `gfx_signpost_*` | `libgfx_signposts.a` not built or not on the link line |
| Undefined symbols for `hb_*` or `FT_*` | `libtextshape.a` or the `pkg-config` libraries missing from `-extra-linker-flags` |
| Text draws as blank rectangles | `fragment_main` does not branch on `push.texture_hatch.x > 1.5` for glyph pages |
| Geometry is misplaced or the window is black | `push_constant_size` disagrees with `canvas2d.Push`, or the shader's `Push` block is not the same eight `float4`s |

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

`canvas2d` is that reusable Vulkan adapter plus an immediate drawing vocabulary:

```odin
import canvas2d "zelda_engine:canvas2d"
```

Consumer-specific effects use `effect_payload` with `draw_effect_quad` or
`draw_effect_quad_points`. The canvas batches the opaque bytes and forwards the
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
