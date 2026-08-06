package example

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:time"

import mk ".."
import dr "../../drift"

DEFAULT_STEP_CAP :: 4000
UI_FONT_SIZE :: f32(22)
UI_PADDING :: 12
UI_LINES :: 5

RESOURCE_SENTINEL_RULE :: "resources/rules/BasicDijkstraRoom.png"
RESOURCE_SENTINEL_MODEL :: "models/Basic.xml"

Viewer_State :: struct {
    index:       int,
    seed:        int,
    step_cap:    int,
    frame:       mk.Frame,
    cfg:         Model_Config,
    model_name:  string,
    status:      string,
    palette_lut: [256]dr.Color,
}

free_frame :: proc(frame: ^mk.Frame) {
    if len(frame.state) > 0 {
        delete(frame.state)
    }
    if len(frame.chars) > 0 {
        delete(frame.chars)
    }
    frame.state = nil
    frame.chars = nil
}

argb_to_color :: proc(argb: i32) -> dr.Color {
    c := cast(u32)argb
    a := f32((c >> 24) & 0xff) / 255.0
    r := f32((c >> 16) & 0xff) / 255.0
    g := f32((c >> 8) & 0xff) / 255.0
    b := f32(c & 0xff) / 255.0
    return {r, g, b, a}
}

resolve_color :: proc(model_name: string, ch: u8, palette: map[u8]i32) -> i32 {
    if color, ok := model_override_color(model_name, ch); ok {
        return color
    }
    if color, ok := palette[ch]; ok {
        return color
    }
    return mk.BACKGROUND
}

build_palette_lut :: proc(frame: mk.Frame, model_name: string, palette: map[u8]i32) -> [256]dr.Color {
    lut: [256]dr.Color
    for i in 0 ..< len(lut) {
        lut[i] = dr.DARKGRAY
    }
    for i in 0 ..< len(frame.chars) {
        lut[i] = argb_to_color(resolve_color(model_name, frame.chars[i], palette))
    }
    return lut
}

find_model_index :: proc(name: string) -> int {
    query := name
    if query == "BasicDjikstraDungeon" {
        query = "BasicDijkstraDungeon"
    }
    for model, i in MODEL_NAMES {
        if model == query {
            return i
        }
    }
    return -1
}

candidate_path :: proc(base, rel: string) -> string {
    if base == "." {
        return rel
    }
    return fmt.tprintf("%s/%s", base, rel)
}

ensure_markov_root :: proc() -> bool {
    candidates := []string {
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
            if err := os.set_current_directory(base); err != nil {
                continue
            }
        }
        return true
    }
    return false
}

reload :: proc(state: ^Viewer_State, palette: map[u8]i32) {
    name := MODEL_NAMES[state.index]
    model_root, ok := load_model_node(name)
    if !ok {
        state.status = fmt.tprintf("failed to load procedural model: %s", name)
        return
    }

    cfg, cfg_ok := default_model_config(name)
    if !cfg_ok {
        state.status = fmt.tprintf("missing config for model: %s", name)
        return
    }

    steps := cfg.steps
    if steps <= 0 || steps > state.step_cap {
        steps = state.step_cap
    }

    start := time.now()
    ip, ip_ok := mk.load_model_proc(model_root, cfg.size)
    if !ip_ok {
        cwd := os.get_current_directory(context.temp_allocator)
        state.status = fmt.tprintf("compile failed: %s (cwd=%s)", name, cwd)
        return
    }

    frames := mk.run(ip, state.seed, steps, false)
    if len(frames) == 0 {
        state.status = fmt.tprintf("no frames produced: %s", name)
        return
    }

    free_frame(&state.frame)
    state.frame = frames[len(frames) - 1]

    for i in 0 ..< len(frames) - 1 {
        delete(frames[i].state)
        delete(frames[i].chars)
    }
    delete(frames)

    state.cfg = cfg
    state.model_name = name
    state.palette_lut = build_palette_lut(state.frame, name, palette)
    elapsed_ms := time.duration_milliseconds(time.since(start))
    state.status = fmt.tprintf(
        "seed=%d steps=%d size=%dx%dx%d in %.1fms",
        state.seed,
        steps,
        cfg.size.x,
        cfg.size.y,
        cfg.size.z,
        elapsed_ms,
    )
}

ui_height :: proc(font: dr.Font, size: f32) -> f32 {
    return UI_PADDING + f32(UI_LINES) * dr.text_line(font, size = size) + UI_PADDING
}

main :: proc() {
    ensure_markov_root()

    palette := mk.load_palette("resources/palette.xml")
    if len(palette) == 0 {
        palette = mk.load_palette("../resources/palette.xml")
    }

    start_model := "Basic"
    args := os.args
    if len(args) > 1 {
        start_model = args[1]
    }

    state: Viewer_State
    state.step_cap = DEFAULT_STEP_CAP
    if idx := find_model_index(start_model); idx >= 0 {
        state.index = idx
    }
    reload(&state, palette)

    dr.window_init("Markov Procedural Examples")
    dr.init()
    defer {
        free_frame(&state.frame)
        dr.window_delete()
    }

    font := dr.default_font()
    for !dr.window_should_close() {
        if dr.keycode_pressed(.right) {
            state.index = (state.index + 1) % len(MODEL_NAMES)
            state.seed = 0
            reload(&state, palette)
        }
        if dr.keycode_pressed(.left) {
            state.index = (state.index - 1 + len(MODEL_NAMES)) % len(MODEL_NAMES)
            state.seed = 0
            reload(&state, palette)
        }
        if dr.keycode_pressed(.r) {
            reload(&state, palette)
        }
        if dr.keycode_pressed(.n) {
            state.seed += 1
            reload(&state, palette)
        }
        if dr.keycode_pressed(.space) {
            state.seed = int(rand.uint64())
            reload(&state, palette)
        }
        if dr.keycode_pressed(.up) {
            state.step_cap += 1000
            reload(&state, palette)
        }
        if dr.keycode_pressed(.down) {
            state.step_cap -= 1000
            if state.step_cap < 500 {
                state.step_cap = 500
            }
            reload(&state, palette)
        }

        dr.begin_draw()
        defer dr.end_draw()
        dr.clear_bg()

        dr.draw_text(
            font,
            {UI_PADDING, UI_PADDING},
            fmt.tprintf("Model [%d/%d]: %s", state.index + 1, len(MODEL_NAMES), state.model_name),
            UI_FONT_SIZE,
            align = .topleft,
        )
        line_h := dr.text_line(font, size = UI_FONT_SIZE)
        dr.draw_text(font, {UI_PADDING, UI_PADDING + line_h}, state.status, UI_FONT_SIZE, align = .topleft)
        dr.draw_text(
            font,
            {UI_PADDING, UI_PADDING + line_h * 2},
            fmt.tprintf("step cap: %d", state.step_cap),
            UI_FONT_SIZE,
            align = .topleft,
        )
        dr.draw_text(
            font,
            {UI_PADDING, UI_PADDING + line_h * 3},
            "left/right: model  n: next seed  space: random seed  r: rerun",
            UI_FONT_SIZE,
            align = .topleft,
        )
        dr.draw_text(
            font,
            {UI_PADDING, UI_PADDING + line_h * 4},
            "up/down: adjust step cap",
            UI_FONT_SIZE,
            align = .topleft,
        )

        if len(state.frame.state) == 0 {
            continue
        }

        m := state.frame.m
        layer_z := m.z / 2
        win := dr.window_size()
        grid_top := ui_height(font, UI_FONT_SIZE)
        grid_h := max(1.0, win.y - grid_top)
        cell := math.floor(min(win.x / f32(m.x), grid_h / f32(m.y)))
        cell = max(cell, 1.0)

        total_w := f32(m.x) * cell
        total_h := f32(m.y) * cell
        ox := (win.x - total_w) * 0.5
        oy := grid_top + (grid_h - total_h) * 0.5

        for y in 0 ..< m.y {
            for x in 0 ..< m.x {
                i := x + y * m.x + layer_z * m.x * m.y
                color := state.palette_lut[state.frame.state[i]]
                dr.draw_rect({{ox + f32(x) * cell, oy + f32(y) * cell}, cell}, color)
            }
        }
    }
}
