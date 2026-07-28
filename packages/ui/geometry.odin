package ui

import "core:math"

Gui_Overlay_Direction :: enum {
    Above,
    Below,
    Left,
    Right,
}

GUI_SPOTLIGHT_MAX_FOCI :: 4
GUI_SPOTLIGHT_MAX_CELLS :: (GUI_SPOTLIGHT_MAX_FOCI * 2 + 1) * (GUI_SPOTLIGHT_MAX_FOCI * 2 + 1)

// Partitions a viewport into rectangles outside up to four focus bounds. A
// renderer can dim the returned cells while leaving the original UI visible
// through the holes; tutorial policy and overlay styling remain product-owned.
gui_spotlight_layout :: proc(
    focuses: []Rect,
    viewport: Rect,
    padding: f32,
    out: ^[GUI_SPOTLIGHT_MAX_CELLS]Rect,
) -> int {
    if viewport.w <= 0 || viewport.h <= 0 do return 0
    count := min(len(focuses), GUI_SPOTLIGHT_MAX_FOCI)
    if count == 0 { out[0] = viewport; return 1 }
    expanded: [GUI_SPOTLIGHT_MAX_FOCI]Rect
    xs, ys: [GUI_SPOTLIGHT_MAX_FOCI * 2 + 2]f32
    left, top := viewport.x, viewport.y
    right, bottom := viewport.x + viewport.w, viewport.y + viewport.h
    xs[0], xs[1], ys[0], ys[1] = left, right, top, bottom
    xn, yn := 2, 2
    for focus, i in focuses[:count] {
        x0 := clamp(focus.x - padding, left, right)
        y0 := clamp(focus.y - padding, top, bottom)
        x1 := clamp(focus.x + focus.w + padding, left, right)
        y1 := clamp(focus.y + focus.h + padding, top, bottom)
        expanded[i] = {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
        xs[xn], xs[xn + 1] = x0, x1
        ys[yn], ys[yn + 1] = y0, y1
        xn += 2; yn += 2
    }
    for i in 1 ..< xn { value := xs[i]; j := i; for j > 0 && xs[j - 1] > value { xs[j] = xs[j - 1]; j -= 1 }; xs[j] = value }
    for i in 1 ..< yn { value := ys[i]; j := i; for j > 0 && ys[j - 1] > value { ys[j] = ys[j - 1]; j -= 1 }; ys[j] = value }
    emitted := 0
    for yi in 0 ..< yn - 1 do for xi in 0 ..< xn - 1 {
        x0, x1, y0, y1 := xs[xi], xs[xi + 1], ys[yi], ys[yi + 1]
        if x1 <= x0 || y1 <= y0 do continue
        cx, cy := (x0 + x1) / 2, (y0 + y1) / 2
        inside := false
        for box in expanded[:count] do if cx >= box.x && cx <= box.x + box.w && cy >= box.y && cy <= box.y + box.h do inside = true
        if !inside { out[emitted] = {x0, y0, x1 - x0, y1 - y0}; emitted += 1 }
    }
    return emitted
}

gui_rect_normalized :: proc(a, b: Vec2) -> Rect {
    return {min(a.x, b.x), min(a.y, b.y), math.abs(b.x - a.x), math.abs(b.y - a.y)}
}

gui_rects_overlap :: proc(a, b: Rect) -> bool {
    return a.x <= b.x + b.w && a.x + a.w >= b.x && a.y <= b.y + b.h && a.y + a.h >= b.y
}

gui_segment_intersects_rect :: proc(a, b: Vec2, rect: Rect) -> bool {
    if gui_contains(rect, a) || gui_contains(rect, b) {
        return true
    }
    dx, dy := b.x - a.x, b.y - a.y
    p := [4]f32{-dx, dx, -dy, dy}
    q := [4]f32{a.x - rect.x, rect.x + rect.w - a.x, a.y - rect.y, rect.y + rect.h - a.y}
    t0, t1 := f32(0), f32(1)
    for i in 0 ..< 4 {
        if p[i] == 0 {
            if q[i] < 0 do return false
            continue
        }
        ratio := q[i] / p[i]
        if p[i] < 0 do t0 = max(t0, ratio)
        else do t1 = min(t1, ratio)
        if t0 > t1 do return false
    }
    return true
}

gui_place_overlay :: proc(
    anchor: Rect,
    size: Vec2,
    viewport: Rect,
    preferred := Gui_Overlay_Direction.Above,
    gap: f32 = 6,
) -> Rect {
    result := Rect{}
    result.w, result.h = max(size.x, 0), max(size.y, 0)
    switch preferred {
    case .Above:
        result.x = anchor.x + (anchor.w - result.w) * 0.5
        result.y = anchor.y - result.h - gap
        if result.y < viewport.y do result.y = anchor.y + anchor.h + gap
    case .Below:
        result.x = anchor.x + (anchor.w - result.w) * 0.5
        result.y = anchor.y + anchor.h + gap
        if result.y + result.h > viewport.y + viewport.h do result.y = anchor.y - result.h - gap
    case .Left:
        result.x = anchor.x - result.w - gap
        result.y = anchor.y + (anchor.h - result.h) * 0.5
        if result.x < viewport.x do result.x = anchor.x + anchor.w + gap
    case .Right:
        result.x = anchor.x + anchor.w + gap
        result.y = anchor.y + (anchor.h - result.h) * 0.5
        if result.x + result.w > viewport.x + viewport.w do result.x = anchor.x - result.w - gap
    }
    result.x = clamp(result.x, viewport.x, max(viewport.x, viewport.x + viewport.w - result.w))
    result.y = clamp(result.y, viewport.y, max(viewport.y, viewport.y + viewport.h - result.h))
    return result
}

// gui_image_contain_rect centers a source image inside bounds without cropping.
gui_image_contain_rect :: proc(bounds: Rect, source_size: Vec2) -> Rect {
    if bounds.w <= 0 || bounds.h <= 0 || source_size.x <= 0 || source_size.y <= 0 {
        return {bounds.x, bounds.y, 0, 0}
    }
    source_aspect := source_size.x / source_size.y
    box_aspect := bounds.w / bounds.h
    w, h := bounds.w, bounds.h
    if source_aspect > box_aspect {
        h = bounds.w / source_aspect
    } else {
        w = bounds.h * source_aspect
    }
    return {bounds.x + (bounds.w - w) * 0.5, bounds.y + (bounds.h - h) * 0.5, w, h}
}

// gui_image_cover_uv returns the centered source UV region that fills bounds.
gui_image_cover_uv :: proc(bounds: Rect, source_size: Vec2) -> Rect {
    if bounds.w <= 0 || bounds.h <= 0 || source_size.x <= 0 || source_size.y <= 0 {
        return {0, 0, 0, 0}
    }
    source_aspect := source_size.x / source_size.y
    box_aspect := bounds.w / bounds.h
    uv := Rect{0, 0, 1, 1}
    if source_aspect > box_aspect {
        uv.w = box_aspect / source_aspect
        uv.x = (1 - uv.w) * 0.5
    } else {
        uv.h = source_aspect / box_aspect
        uv.y = (1 - uv.h) * 0.5
    }
    return uv
}

gui_cubic_point :: proc(a, b, c, d: Vec2, t: f32) -> Vec2 {
    u := 1 - t
    uu, tt := u * u, t * t
    return {
        a.x * uu * u + 3 * b.x * uu * t + 3 * c.x * u * tt + d.x * tt * t,
        a.y * uu * u + 3 * b.y * uu * t + 3 * c.y * u * tt + d.y * tt * t,
    }
}

gui_cubic_tangent :: proc(a, b, c, d: Vec2, t: f32) -> Vec2 {
    u := 1 - t
    return {
        3 * u * u * (b.x - a.x) + 6 * u * t * (c.x - b.x) + 3 * t * t * (d.x - c.x),
        3 * u * u * (b.y - a.y) + 6 * u * t * (c.y - b.y) + 3 * t * t * (d.y - c.y),
    }
}

gui_point_segment_distance :: proc(point, a, b: Vec2) -> f32 {
    dx, dy := b.x - a.x, b.y - a.y
    length_squared := dx * dx + dy * dy
    if length_squared <= 0.001 {
        return math.sqrt((point.x - a.x) * (point.x - a.x) + (point.y - a.y) * (point.y - a.y))
    }
    t := clamp(((point.x - a.x) * dx + (point.y - a.y) * dy) / length_squared, 0, 1)
    x, y := a.x + t * dx, a.y + t * dy
    return math.sqrt((point.x - x) * (point.x - x) + (point.y - y) * (point.y - y))
}

gui_cubic_hit :: proc(point, a, b, c, d: Vec2, tolerance: f32 = 8, samples: int = 32) -> bool {
    if tolerance < 0 || samples < 1 {
        return false
    }
    previous := a
    for sample in 1 ..= samples {
        current := gui_cubic_point(a, b, c, d, f32(sample) / f32(samples))
        if gui_point_segment_distance(point, previous, current) <= tolerance {
            return true
        }
        previous = current
    }
    return false
}

gui_smooth_path_controls :: proc(points: []Vec2, segment: int) -> (a, b, c, d: Vec2, ok: bool) {
    if segment < 0 || segment + 1 >= len(points) {
        return {}, {}, {}, {}, false
    }
    p0 := segment > 0 ? points[segment - 1] : points[segment]
    p1, p2 := points[segment], points[segment + 1]
    p3 := segment + 2 < len(points) ? points[segment + 2] : points[segment + 1]
    b = {p1.x + (p2.x - p0.x) / 6, p1.y + (p2.y - p0.y) / 6}
    c = {p2.x - (p3.x - p1.x) / 6, p2.y - (p3.y - p1.y) / 6}
    return p1, b, c, p2, true
}

gui_smooth_path_hit :: proc(point: Vec2, points: []Vec2, tolerance: f32 = 8, samples_per_segment: int = 32) -> bool {
    if len(points) < 2 {
        return false
    }
    for segment in 0 ..< len(points) - 1 {
        a, b, c, d, ok := gui_smooth_path_controls(points, segment)
        if ok && gui_cubic_hit(point, a, b, c, d, tolerance, samples_per_segment) {
            return true
        }
    }
    return false
}

gui_cubic_segment_count :: proc(a, b, c, d: Vec2) -> int {
    control_length :=
        math.sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)) +
        math.sqrt((c.x - b.x) * (c.x - b.x) + (c.y - b.y) * (c.y - b.y)) +
        math.sqrt((d.x - c.x) * (d.x - c.x) + (d.y - c.y) * (d.y - c.y))
    return clamp(int(control_length / 9), 8, 64)
}

gui_cubic :: proc(ctx: ^Gui_Context, a, b, c, d: Vec2, color: Color, width: f32, segments: int = 0) {
    count := segments
    if count <= 0 {
        count = gui_cubic_segment_count(a, b, c, d)
    }
    previous := a
    for i in 1 ..= count {
        point := gui_cubic_point(a, b, c, d, f32(i) / f32(count))
        gui_line(ctx, previous, point, color, width)
        previous = point
    }
}

gui_smooth_path :: proc(ctx: ^Gui_Context, points: []Vec2, color: Color, width: f32) {
    if len(points) < 2 {
        return
    }
    for segment in 0 ..< len(points) - 1 {
        a, b, c, d, ok := gui_smooth_path_controls(points, segment)
        if ok {
            gui_cubic(ctx, a, b, c, d, color, width)
        }
    }
}
