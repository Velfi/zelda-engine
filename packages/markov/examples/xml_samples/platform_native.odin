#+build !js
package example

import "core:fmt"
import "core:os"

import mk "../.."

RESOURCE_SENTINEL_RULE :: "resources/rules/BasicDijkstraRoom.png"
RESOURCE_SENTINEL_MODEL :: "models/Basic.xml"

candidate_path :: proc(base, rel: string) -> string {
    if base == "." {
        return rel
    }
    return fmt.tprintf("%s/%s", base, rel)
}

ensure_markov_root :: proc() -> bool {
    // Keep native behavior: allow running the example from several common cwd locations.
    candidates: []string = {
        ".",
        "..",
        "../..",
        "../../..",
        "rt/markov",
        "../rt/markov",
        "../../rt/markov",
        "../../../rt/markov",
    }
    for base in candidates {
        rule_path := candidate_path(base, RESOURCE_SENTINEL_RULE)
        model_path := candidate_path(base, RESOURCE_SENTINEL_MODEL)
        if !os.exists(rule_path) || !os.exists(model_path) {
            continue
        }

        if base != "." {
            if err := os.set_working_directory(base); err != nil {
                continue
            }
        }
        return true
    }
    return false
}

load_example_palette :: proc() -> mk.Palette {
    palette := mk.load_palette("resources/palette.xml")
    if len(palette) == 0 {
        palette = mk.load_palette("../resources/palette.xml")
    }
    return palette
}

initial_model_name :: proc() -> string {
    args := os.args
    if len(args) > 1 {
        return args[1]
    }
    return "Basic"
}

compile_failure_status :: proc(name: string) -> string {
    // Add cwd context on native to preserve existing troubleshooting detail.
    cwd, err := os.get_working_directory(context.temp_allocator)
    if err != nil {
        return fmt.tprintf("compile failed: %s", name)
    }
    return fmt.tprintf("compile failed: %s (cwd=%s)", name, cwd)
}
