#+build !js
package markov

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

main :: proc() {
    // Initialize console logger
    context.logger = log.create_console_logger(.Info)

    // Get model filter from command line args
    args := os.args
    filter: string = ""
    if len(args) > 1 {
        filter = args[1]
    }

    // Load palette
    palette := load_palette("resources/palette.xml")
    fmt.println("Loaded palette with", len(palette), "colors")

    // Load models list
    models := load_models_list("models.xml")
    fmt.println("Found", len(models), "models")

    // Create output directory
    os.make_directory("output_odin")

    // Process each model
    for config in models {
        // Filter by name if specified
        if len(filter) > 0 && !strings.contains(config.name, filter) {
            continue
        }
        fmt.println("\nProcessing:", config.name)

        // Load model
        model_path := fmt.tprintf("models/%s.xml", config.name)
        ip, ok := load_model(model_path, config.size)
        if !ok {
            fmt.eprintln("  Failed to load model")
            continue
        }

        // Determine seeds to use
        seeds: [dynamic]int
        if len(config.seeds) > 0 {
            seeds = config.seeds
        } else {
            seeds = make([dynamic]int, context.temp_allocator)
            for i in 0 ..< config.amount {
                append(&seeds, i)
            }
        }

        // Run for each seed
        for seed_idx in 0 ..< len(seeds) {
            seed := seeds[seed_idx]
            start_time := time.now()

            frames := run(ip, seed, config.steps, config.gif)

            elapsed := time.duration_seconds(time.diff(start_time, time.now()))
            fmt.printf("  Seed %d: %d frames in %.3fs\n", seed, len(frames), elapsed)

            if len(frames) == 0 {
                frames_destroy(&frames)
                continue
            }

            // Get final frame
            final_frame := frames[len(frames) - 1]

            // Merge global palette with per-model overrides.
            custom_palette := make(map[u8]i32, len(palette) + len(config.colors), context.temp_allocator)
            for ch, color in palette {
                custom_palette[ch] = color
            }
            for ch, color in config.colors {
                custom_palette[ch] = color
            }

            // Build color array from final frame's character set
            colors := make([]i32, 256, context.temp_allocator)
            for i in 0 ..< 256 {
                colors[i] = BACKGROUND
            }
            for i in 0 ..< len(final_frame.chars) {
                ch := final_frame.chars[i]
                if ch in custom_palette {
                    colors[i] = custom_palette[ch]
                }
            }

            // Render and save
            if final_frame.m.z == 1 || config.iso {
                // 2D output or isometric 3D
                bitmap, size := render(final_frame.state, final_frame.m, colors[:], config.pixel_size, 0)
                output_path := fmt.tprintf("output_odin/%s_%d.png", config.name, seed)
                if save_bitmap(bitmap, size, output_path) {
                    fmt.println("  Saved:", output_path)
                } else {
                    fmt.eprintln("  Failed to save:", output_path)
                }
            } else {
                // 3D output - save as VOX
                output_path := fmt.tprintf("output_odin/%s_%d.vox", config.name, seed)
                if save_vox(final_frame.state, final_frame.m, colors[:], output_path) {
                    fmt.println("  Saved:", output_path)
                } else {
                    fmt.eprintln("  Failed to save:", output_path)
                }
            }
            frames_destroy(&frames)
        }
        interpreter_destroy(ip)
    }

    fmt.println("\nDone!")
}
